# CSI Lite

A stripped-down, RuView-style WiFi sensing rig: **one WiFi router + two ESP32
boards** at fixed spacing, a small Python server that turns the boards' Channel
State Information (CSI) into features, and a browser UI that shows where along
the three radio links the signal is being attenuated, both live and as a
scrolling history.

```
            Node B
           /      \
   R→B   /          \  A↔B        3 links, 4 measured streams:
        /            \              R→A  router ping replies, received by A
   Router ────────── Node A         R→B  router ping replies, received by B
             R→A                    A↔B  ESP-NOW broadcasts, each node hears the other
```

The router, A and B stay in one fixed configuration (for example, mounted on a
frame). You can move the whole frame. After you move it, re-calibrate, because
the room around it has changed.

## What it computes

Each CSI packet gives 52 complex subcarrier values (L-LTF, HT20). For each packet:

| Step | Why |
|---|---|
| **AGC-compensated amplitude**: keep the CSI's shape and set its total power to the packet RSSI | The ESP32's automatic gain control rescales every packet, so raw amplitudes jump around |
| **Sanitized phase**: unwrap across subcarriers, then remove the linear and constant terms | Removes the timing-offset slope (STO) and carrier frequency/phase offset (CFO), which are random on every packet |

Over a sliding window (default 1 s), each link produces the **CSI components**
you can select in the UI:

| Component | Meaning | Good for |
|---|---|---|
| Amplitude attenuation (dB) | baseline minus current amplitude, per subcarrier | a body standing in or near the link (shadowing) |
| RSSI drop (dB) | wide-band power vs baseline | a coarse version of the above |
| Amplitude variability (dB) | std. dev. of amplitude, above its empty-room level | movement near the link |
| Phase variability (rad) | circular std. dev. of sanitized phase, above its empty-room level | small movements |
| Motion energy (dB) | mean packet-to-packet amplitude change, above its empty-room level | fast movement |

**Spatial map.** Each link spreads its value over an ellipse whose foci are the
link's two ends (a Fresnel-zone style weight `exp(-½(excess_path/width)²)`).
Values from overlapping links add up. This is radio-tomographic backprojection.
With only three links the image is coarse. It shows *which link(s)* and
*roughly where along them* something is happening. It does not give a precise
position.

## UI

- **Start / Stop**: starts or stops sounding on both nodes and starts or stops processing.
- **Calibrate baseline**: clear the area and click. It records 5 s of empty-room
  baseline. Until you calibrate, a slow running baseline (60 s) is used.
- **Rig geometry**: enter the router↔A, router↔B and A↔B distances in metres
  (antenna to antenna) and the router's WiFi channel. The UI solves the
  triangle and shows the wavelength and Fresnel zone sizes.
- **CSI component**: pick the metric, toggle links on or off, and choose a
  subcarrier range. You can type the range or drag across the per-subcarrier chart.
- **Spatial attenuation**: the live map, plus a numeric readout per link.
- **Per-subcarrier**: a live bar for every subcarrier on every link, which shows
  how the attenuation varies across frequency.
- **History**: a scrolling bar graph of the selected metric over the last 30 s,
  one lane per link. Shaded spans are calibration periods.

## Run it without hardware

```bash
cd csi-lite/server
pip install -r requirements.txt
python csi_server.py --simulate
# open http://localhost:8080 and click Start
```

The simulator walks a virtual person around the rig and adds the ESP32's real
impairments: random phase offset, STO slope, AGC jumps and int8 quantization.
It sends everything through the same packet decoder as live data. While you
calibrate, the simulated person steps out of the area.

## Run it with hardware

### 1. Flash the two ESP32s (ESP-IDF 5.x)

Tested targets: ESP32, ESP32-S3, ESP32-C3.

```bash
cd csi-lite/firmware/csi_node
idf.py set-target esp32
idf.py menuconfig      # "CSI Lite Node": SSID, password, Node ID
idf.py -p /dev/ttyUSB0 flash monitor
```

Flash the first board with **Node ID 0 (node A)** and the second with **Node ID 1 (node B)**.
Leave *Server IP* blank. The server broadcasts a `HELLO` every 2 s and the
nodes reply to whichever machine sent it. The server computer must be on the
same network as the router.

### 2. Start the server

```bash
cd csi-lite/server
python csi_server.py          # UI on :8080, CSI in on UDP :5500, control out on UDP :5501
```

Open the UI. When both node pills turn green, enter the distances, click
**Start**, clear the area, then click **Calibrate baseline**.

### Placement tips

- Put the boards at about chest height with a clear line of sight. Sensitivity
  is highest on and near the line between each pair.
- 2–5 m spacing works well. At 2.4 GHz the first Fresnel zone at the middle of
  a 3 m link has a radius of about 30 cm.
- Keep the boards and router rigid relative to each other. Bumping one changes
  the baseline.
- Some routers rate-limit ICMP. If the R→A or R→B pkt/s readout is far below
  the sounding rate, lower the rate or use a different router.

## Layout

```
csi-lite/
  firmware/csi_node/   ESP-IDF project (one firmware, node ID set in menuconfig)
  server/
    csi_server.py      aiohttp web/WebSocket server, UDP I/O, node control
    protocol.py        packet format shared with the firmware
    processing.py      phase/amplitude cleaning and feature extraction
    simulator.py       synthetic CSI source
    static/            UI (plain HTML/CSS/JS, no build step)
```

### Packet format (node → server, UDP 5500)

32-byte little-endian header, followed by `csi_len` bytes of int8 `[imag, real]` pairs.

| field | type | |
|---|---|---|
| magic | u32 | `0x4C495343` ("CSIL") |
| version, node_id | u8, u8 | |
| self_mac, src_mac | 6 B, 6 B | |
| rssi, noise_floor | i8, i8 | dBm |
| channel, src_kind | u8, u8 | src_kind 0 = router, 1 = peer node |
| seq, timestamp_us | u32, u32 | |
| csi_len | u16 | 128 for L-LTF |

Control (server → node, UDP 5501, text): `HELLO <port>`, `START`, `STOP`, `RATE <hz>`.
