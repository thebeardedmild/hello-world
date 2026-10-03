/*
 * CSI Lite node firmware (ESP-IDF 5.x, ESP32 / ESP32-S3 / ESP32-C3).
 *
 * Each node joins the router as a station and measures CSI on two kinds of
 * frames:
 *   - ICMP echo replies from the router  -> link "router -> this node"
 *   - ESP-NOW broadcasts from the peer   -> link "peer node -> this node"
 *
 * Every CSI capture is forwarded to the host server as one UDP datagram
 * (see csi_pkt_hdr_t). The server controls the node over a small text
 * protocol on CONFIG_CSI_CONTROL_PORT:
 *   HELLO <port>   server announces itself; node replies "NODE <id> <mac>"
 *   START          begin sounding + streaming
 *   STOP           stop sounding + streaming
 *   RATE <hz>      change sounding rate
 */
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_now.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "lwip/sockets.h"
#include "lwip/ip_addr.h"
#include "ping/ping_sock.h"

static const char *TAG = "csi_node";

#define CSI_MAGIC       0x4C495343u /* "CSIL" little-endian */
#define CSI_VERSION     1
#define CSI_MAX_LEN     384
#define CSI_QUEUE_LEN   32
#define ESPNOW_MAGIC    0xC5u

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint8_t  version;
    uint8_t  node_id;
    uint8_t  self_mac[6];
    uint8_t  src_mac[6];
    int8_t   rssi;
    int8_t   noise_floor;
    uint8_t  channel;
    uint8_t  src_kind;      /* 0 = router (AP), 1 = peer node (ESP-NOW) */
    uint32_t seq;
    uint32_t timestamp_us;
    uint16_t csi_len;
} csi_pkt_hdr_t; /* 32 bytes, followed by csi_len bytes of int8 [imag, real] pairs */

typedef struct {
    csi_pkt_hdr_t hdr;
    int8_t buf[CSI_MAX_LEN];
} csi_item_t;

static QueueHandle_t s_csi_queue;
static uint8_t s_self_mac[6];
static uint8_t s_ap_bssid[6];
static uint8_t s_peer_mac[6];
static volatile bool s_have_ap;
static volatile bool s_have_peer;
static volatile bool s_streaming;
static volatile uint32_t s_rate_hz = CONFIG_CSI_DEFAULT_RATE_HZ;
static uint32_t s_seq;

static esp_ip4_addr_t s_gateway;
static esp_ping_handle_t s_ping;

static struct sockaddr_in s_server;
static volatile bool s_have_server;

/* ------------------------------------------------------------------ CSI */

static void csi_rx_cb(void *ctx, wifi_csi_info_t *info)
{
    if (!s_streaming || !info || !info->buf || info->len <= 0) {
        return;
    }
    /* Only keep frames from the two transmitters we care about. */
    bool from_ap = s_have_ap && memcmp(info->mac, s_ap_bssid, 6) == 0;
    bool from_peer = s_have_peer && memcmp(info->mac, s_peer_mac, 6) == 0;
    if (!from_ap && !from_peer) {
        return;
    }

    csi_item_t item;
    uint16_t len = info->len > CSI_MAX_LEN ? CSI_MAX_LEN : info->len;
    item.hdr.magic = CSI_MAGIC;
    item.hdr.version = CSI_VERSION;
    item.hdr.node_id = CONFIG_CSI_NODE_ID;
    memcpy(item.hdr.self_mac, s_self_mac, 6);
    memcpy(item.hdr.src_mac, info->mac, 6);
    item.hdr.rssi = info->rx_ctrl.rssi;
    item.hdr.noise_floor = info->rx_ctrl.noise_floor;
    item.hdr.channel = info->rx_ctrl.channel;
    item.hdr.src_kind = from_ap ? 0 : 1;
    item.hdr.seq = s_seq++;
    item.hdr.timestamp_us = info->rx_ctrl.timestamp;
    item.hdr.csi_len = len;
    memcpy(item.buf, info->buf, len);
    xQueueSend(s_csi_queue, &item, 0); /* drop if the sender falls behind */
}

static void csi_init(void)
{
    wifi_csi_config_t cfg = {
        .lltf_en = true,           /* legacy LTF: 64 subcarriers, present on every OFDM frame */
        .htltf_en = false,
        .stbc_htltf2_en = false,
        .ltf_merge_en = true,
        .channel_filter_en = false,
        .manu_scale = false,
        .shift = 0,
    };
    ESP_ERROR_CHECK(esp_wifi_set_csi_config(&cfg));
    ESP_ERROR_CHECK(esp_wifi_set_csi_rx_cb(csi_rx_cb, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_csi(true));
}

static void csi_send_task(void *arg)
{
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    csi_item_t item;
    while (1) {
        if (xQueueReceive(s_csi_queue, &item, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        if (!s_have_server) {
            continue;
        }
        sendto(sock, &item, sizeof(item.hdr) + item.hdr.csi_len, 0,
               (struct sockaddr *)&s_server, sizeof(s_server));
    }
}

/* ------------------------------------------------------- sounding traffic */

static void ping_stop(void)
{
    if (s_ping) {
        esp_ping_stop(s_ping);
        esp_ping_delete_session(s_ping);
        s_ping = NULL;
    }
}

static void ping_start(void)
{
    ping_stop();
    if (s_gateway.addr == 0) {
        return;
    }
    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    ip_addr_set_ip4_u32(&cfg.target_addr, s_gateway.addr);
    cfg.count = ESP_PING_COUNT_INFINITE;
    cfg.interval_ms = s_rate_hz ? 1000 / s_rate_hz : 10;
    cfg.timeout_ms = 1000;
    cfg.data_size = 1;
    cfg.task_stack_size = 3072;
    esp_ping_callbacks_t cbs = { 0 };
    if (esp_ping_new_session(&cfg, &cbs, &s_ping) == ESP_OK) {
        esp_ping_start(s_ping);
    }
}

/* The peer measures CSI on these broadcasts, giving the node A <-> node B link. */
static void espnow_task(void *arg)
{
    uint8_t payload[4] = { ESPNOW_MAGIC, CONFIG_CSI_NODE_ID, 0, 0 };
    static const uint8_t bcast[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    while (1) {
        uint32_t rate = s_rate_hz ? s_rate_hz : 1;
        if (s_streaming) {
            esp_now_send(bcast, payload, sizeof(payload));
        }
        vTaskDelay(pdMS_TO_TICKS(1000 / rate) ? pdMS_TO_TICKS(1000 / rate) : 1);
    }
}

static void espnow_recv_cb(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (len >= 2 && data[0] == ESPNOW_MAGIC && data[1] != CONFIG_CSI_NODE_ID) {
        memcpy(s_peer_mac, info->src_addr, 6);
        s_have_peer = true;
    }
}

static void espnow_init(void)
{
    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_recv_cb(espnow_recv_cb));
    esp_now_peer_info_t peer = { 0 };
    memset(peer.peer_addr, 0xff, 6);
    peer.channel = 0; /* follow the router's channel */
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    ESP_ERROR_CHECK(esp_now_add_peer(&peer));
}

/* ------------------------------------------------------------- control */

static void set_streaming(bool on)
{
    s_streaming = on;
    if (on) {
        ping_start();
    } else {
        ping_stop();
    }
    ESP_LOGI(TAG, "streaming %s at %lu Hz", on ? "ON" : "OFF", (unsigned long)s_rate_hz);
}

static void control_task(void *arg)
{
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(CONFIG_CSI_CONTROL_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    bind(sock, (struct sockaddr *)&addr, sizeof(addr));

    char buf[64];
    while (1) {
        struct sockaddr_in from;
        socklen_t flen = sizeof(from);
        int n = recvfrom(sock, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &flen);
        if (n <= 0) {
            continue;
        }
        buf[n] = 0;

        if (strncmp(buf, "HELLO", 5) == 0) {
            int port = atoi(buf + 5);
            s_server.sin_family = AF_INET;
            s_server.sin_addr = from.sin_addr;
            s_server.sin_port = htons(port > 0 ? port : CONFIG_CSI_SERVER_PORT);
            s_have_server = true;
            char reply[64];
            int r = snprintf(reply, sizeof(reply), "NODE %d " MACSTR " %d %lu",
                             CONFIG_CSI_NODE_ID, MAC2STR(s_self_mac),
                             s_streaming ? 1 : 0, (unsigned long)s_rate_hz);
            sendto(sock, reply, r, 0, (struct sockaddr *)&s_server, sizeof(s_server));
        } else if (strncmp(buf, "START", 5) == 0) {
            set_streaming(true);
        } else if (strncmp(buf, "STOP", 4) == 0) {
            set_streaming(false);
        } else if (strncmp(buf, "RATE", 4) == 0) {
            int hz = atoi(buf + 4);
            if (hz >= 1 && hz <= 500) {
                s_rate_hz = hz;
                if (s_streaming) {
                    ping_start();
                }
            }
        }
    }
}

/* ---------------------------------------------------------------- WiFi */

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_have_ap = false;
        ping_stop();
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *ev = (ip_event_got_ip_t *)data;
        s_gateway = ev->ip_info.gw;
        wifi_ap_record_t ap;
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            memcpy(s_ap_bssid, ap.bssid, 6);
            s_have_ap = true;
        }
        ESP_LOGI(TAG, "got ip " IPSTR ", gw " IPSTR ", bssid " MACSTR,
                 IP2STR(&ev->ip_info.ip), IP2STR(&s_gateway), MAC2STR(s_ap_bssid));
        if (s_streaming) {
            ping_start();
        }
    }
}

static void wifi_init(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));

    wifi_config_t cfg = { 0 };
    strlcpy((char *)cfg.sta.ssid, CONFIG_CSI_WIFI_SSID, sizeof(cfg.sta.ssid));
    strlcpy((char *)cfg.sta.password, CONFIG_CSI_WIFI_PASSWORD, sizeof(cfg.sta.password));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_ERROR_CHECK(esp_wifi_get_mac(WIFI_IF_STA, s_self_mac));
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    s_csi_queue = xQueueCreate(CSI_QUEUE_LEN, sizeof(csi_item_t));

    if (strlen(CONFIG_CSI_SERVER_IP) > 0) {
        s_server.sin_family = AF_INET;
        s_server.sin_port = htons(CONFIG_CSI_SERVER_PORT);
        inet_pton(AF_INET, CONFIG_CSI_SERVER_IP, &s_server.sin_addr);
        s_have_server = true;
    }

    wifi_init();
    espnow_init();
    csi_init();

    xTaskCreate(csi_send_task, "csi_send", 4096, NULL, 5, NULL);
    xTaskCreate(control_task, "csi_ctrl", 4096, NULL, 4, NULL);
    xTaskCreate(espnow_task, "csi_espnow", 3072, NULL, 4, NULL);

    ESP_LOGI(TAG, "node %d ready, mac " MACSTR, CONFIG_CSI_NODE_ID, MAC2STR(s_self_mac));
    if (CONFIG_CSI_AUTOSTART) {
        set_streaming(true);
    }
}
