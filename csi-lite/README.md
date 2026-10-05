# CSI Lite

A stripped-down, RuView-style WiFi sensing rig: **one WiFi router + two or more
ESP32 boards** (up to 16) at fixed positions, a small Python server that turns
the boards' Channel State Information (CSI) into features, and a browser UI
that shows where disturbances are relative to the antennas, live and over time.

## What you need

- **One WiFi router** (2.4 GHz). All boards join its network. No second router.
- **Two or more ESP32 boards** (ESP32, ESP32-S3 or ESP32-C3). Each one is
  flashed with the same firmware and a different Node ID.
- **A computer on the same network** for the server: Linux, macOS, Windows,
  Raspberry Pi or a Jetson Orin Nano. It needs Python 3.10+, `numpy` and
  `aiohttp`. No Rust, no Docker, and no build step for the UI.

```
        Node D ─ ─ ─ ─ Node C          Links with a router R and nodes A, B, C, ...
        │      ╲    ╱   │                R-A, R-B, ...  router → node: each node pings the
        │        ╳      │                               router and measures CSI on the replies
        │      ╱    ╲   │                A-B, A-C, ...  node ↔ node: every node sends ESP-NOW
     Router ─────────Node A                             broadcasts and the others measure CSI
        │                                               on them (both directions are averaged)
     Node B
```

N nodes give N router links plus N(N-1)/2 node-to-node links: 3 links with
2 nodes, 10 with 4, 21 with 6. More links crossing the area mean better
localization.

The antennas stay in one fixed layout (for example, mounted on a frame). You
can move the whole frame. After you move it, re-calibrate, because the room
around it has changed.

## What it computes

Each CSI packet gives 52 complex subcarrier values (L-LTF, HT20). For each packet:

| Step | Why |
|---|---|
| **AGC-compensated amplitude**: keep the CSI's shape and set its total power to the packet RSSI | The ESP32's automatic gain control rescales every packet, so raw amplitudes jump around |
| **Sanitized phase**: unwrap across subcarriers, then remove the linear and constant terms | Removes the timing-offset slope (STO) and carrier frequency/phase offset (CFO), which are random on every packet |

Over a sliding window (default 1 s), each link produces the **CSI components**
you can select in the UI:

| Component | Meaning | Good for | Default threshold |
|---|---|---|---|
| Amplitude attenuation (dB) | baseline minus current amplitude, per subcarrier | a body standing in or near the link (shadowing) | 2 dB |
| RSSI drop (dB) | wide-band power vs baseline | a coarse version of the above | 2 dB |
| Amplitude variability (dB) | std. dev. of amplitude, above its empty-room level | movement near the link | 2.5 dB |
| Phase variability (rad) | circular std. dev. of sanitized phase, above its empty-room level | small movements (needs real multipath; nearly flat in the simulator) | 0.08 rad |
| Motion energy (dB) | mean packet-to-packet amplitude change, above its empty-room level | fast movement | 1 dB |

The thresholds were tuned in the simulator. Adjust them for your room under
**Localization → Detection**.

### Localization

Each link has a **zone**: an ellipse around its line of sight, with the two
antennas as foci. Its weight falls off with excess path length (*Link zone
width*) and fades out right next to the antennas. Every link touching an
antenna overlaps there, which would otherwise pull every estimate onto the
antennas.

- **Tomographic image** (default): the regularized least-squares picture that
  best explains all link readings at once, `img = Wᵀ (W Wᵀ + αI)⁻¹ y`. A spot
  covered by several links isn't counted twice. *Regularization* sets α:
  higher is smoother and more cautious.
- **Backprojection**: each link paints its value over its zone, and overlaps
  add up. Simpler, but blurrier.
- Before imaging, the median link value is subtracted, so drift or
  interference that lifts every link at once doesn't paint the whole room.
- A **disturbance** is marked when any enabled link exceeds the threshold. Its
  position is the weighted centroid of the image's peak.

In the simulator, with 4 nodes over a 3 × 4.5 m area and amplitude
attenuation, the median position error is about 0.7 m while someone is inside
a link zone. Accuracy depends on how many links cross the spot. Position
*along* a single link is the weakest direction.

## UI

- **Start / Stop**: starts or stops sounding on all nodes and starts or stops processing.
- **Calibrate baseline**: clear the area and click. It records 5 s of
  empty-room baseline. Until you calibrate, a slow running baseline (60 s) is used.
- **Antennas**: x/y position of the router and each node, in metres. You can:
  - type positions in,
  - turn on **Move antennas** and drag them on the map, or
  - use **Place a node from two measured distances** (tape-measure from two
    placed antennas and pick which side).

  **+ Add node** adds the next node ID. A board that's online but not placed
  shows up with a *Place* button. Click **Apply** to save.
- **CSI component**: pick the metric, show or hide router links and
  node-to-node links, and choose a subcarrier range. You can type the range or
  drag across the per-subcarrier chart.
- **Spatial map**: the reconstruction image, every link (solid = router,
  dashed = node-to-node), the estimated disturbance with a 10-second trail, and
  a range line to the reference antenna. Click a link to highlight it and its
  zone. In simulator mode, a ◇ marks the simulated person's true position.
- **Relative to antenna**: a radar view centred on any antenna you pick, with
  range rings, bearing (0° = up on the map, clockwise) and the trail. Next to
  it is the distance from every antenna and which link zones the disturbance
  is inside.
- **Links**: every link sorted by current value, with packet rate, RSSI and
  baseline state. Untick a link to leave it out of the map.
- **Per-subcarrier**: a heatmap with one row per link and one column per
  subcarrier. It shows how the effect varies across frequency.
- **History**: the last 30 s. The top lane is the disturbance's distance from
  the reference antenna. Below it is one lane per link, as bars, or as a
  heatmap once there are many links. Shaded spans are calibration periods.

## Run it without hardware

```bash
cd csi-lite/server
pip install -r requirements.txt
python csi_server.py --simulate
# open http://localhost:8080 and click Start
```

The simulator uses whatever antennas you configure. It walks a virtual person
around the rig and adds the ESP32's real impairments: random phase offset, STO
slope, AGC jumps and int8 quantization. It sends everything through the same
packet decoder as live data. While you calibrate, the simulated person steps
out of the area. With many nodes, the simulator lowers its own rate to save
CPU, and the UI says when it does.

## Run it with hardware

### 1. Flash the ESP32s (ESP-IDF 5.x)

Tested targets: ESP32, ESP32-S3, ESP32-C3.

```bash
cd csi-lite/firmware/csi_node
idf.py set-target esp32
idf.py menuconfig      # "CSI Lite Node": SSID, password, Node ID
idf.py -p /dev/ttyUSB0 flash monitor
```

Flash each board with a different **Node ID**: 0 = A, 1 = B, … 15 = P.
Leave *Server IP* blank. The server broadcasts a `HELLO` every 2 s and the
nodes reply to whichever machine sent it. The server computer must be on the
same network as the router.

### 2. Start the server

```bash
cd csi-lite/server
python csi_server.py          # UI on :8080, CSI in on UDP :5500, control out on UDP :5501
```

Open the UI. When the node pills turn green, place the antennas and click
**Apply**, then **Start**. Clear the area and click **Calibrate baseline**.

### Placement tips

- Put the boards at about chest height with a clear line of sight. Sensitivity
  is highest on and near the line between each pair.
- Put nodes around the area you want to watch, not in a line, so links cross
  it from several directions.
- 2–5 m spacing works well. At 2.4 GHz the first Fresnel zone at the middle of
  a 3 m link has a radius of about 30 cm.
- Keep the boards and router rigid relative to each other. Bumping one changes
  the baseline.
- Every node hears every other node, so traffic grows with the square of the
  node count: about N² × rate packets/s in total. 4 nodes at 100 Hz is about
  1,600/s, which is fine. For 6 or more nodes, lower the rate to about 50 Hz,
  especially on a small server like a Raspberry Pi or Orin Nano.
- Some routers rate-limit ICMP. If the router links' pkt/s is far below the
  sounding rate, lower the rate or use a different router.

## Layout

```
csi-lite/
  firmware/csi_node/   ESP-IDF project (one firmware, node ID 0-15 set in menuconfig)
  server/
    csi_server.py      aiohttp web/WebSocket server, UDP I/O, node control
    protocol.py        packet format shared with the firmware
    processing.py      phase/amplitude cleaning and feature extraction
    simulator.py       synthetic CSI source (any number of nodes)
    static/            UI (plain HTML/CSS/JS, no build step)
```

### Packet format (node → server, UDP 5500)

32-byte little-endian header, followed by `csi_len` bytes of int8 `[imag, real]` pairs.

| field | type | |
|---|---|---|
| magic | u32 | `0x4C495343` ("CSIL") |
| version, node_id | u8, u8 | version 2; node_id 0-15 |
| self_mac, src_mac | 6 B, 6 B | |
| rssi | i8 | dBm |
| src_node | u8 | transmitting node ID, 255 = router (version 1: noise floor) |
| channel, src_kind | u8, u8 | src_kind 0 = router, 1 = another node |
| seq, timestamp_us | u32, u32 | |
| csi_len | u16 | 128 for L-LTF |

The server still accepts version 1 packets from boards flashed with the
original two-node firmware.

Control (server → node, UDP 5501, text): `HELLO <port>`, `START`, `STOP`, `RATE <hz>`.
