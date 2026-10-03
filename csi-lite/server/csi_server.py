"""CSI Lite host server.

    python csi_server.py              # live: talk to the two ESP32 nodes
    python csi_server.py --simulate   # no hardware: synthetic CSI

Then open http://localhost:8080
"""
import argparse
import asyncio
import json
import socket
import time
from pathlib import Path

from aiohttp import WSMsgType, web

import protocol
from processing import Engine
from simulator import NODE_MAC, Simulator

HERE = Path(__file__).parent
CONFIG_PATH = HERE / "config.json"
DEFAULT_CONFIG = {
    "d_ra": 3.0,           # router <-> node A distance (m)
    "d_rb": 3.0,           # router <-> node B distance (m)
    "d_ab": 3.0,           # node A <-> node B distance (m)
    "channel": 6,          # router's 2.4 GHz channel (sets wavelength)
    "rate_hz": 100,        # sounding rate per node
    "window_s": 1.0,       # feature window
    "fresnel_m": 0.25,     # excess-path width used to weight the map
    "baseline_tau_s": 60,  # running-baseline time constant before calibration
    "calib_s": 5,          # calibration duration
}
TICK_S = 0.1


def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        try:
            cfg.update({k: v for k, v in json.loads(CONFIG_PATH.read_text()).items()
                        if k in DEFAULT_CONFIG})
        except (OSError, ValueError):
            pass
    return cfg


def validate_config(new: dict, old: dict) -> dict:
    cfg = dict(old)
    for k, v in new.items():
        if k in DEFAULT_CONFIG:
            cfg[k] = type(DEFAULT_CONFIG[k])(v)
    a, b, c = cfg["d_ra"], cfg["d_rb"], cfg["d_ab"]
    if min(a, b, c) <= 0:
        raise ValueError("distances must be positive")
    if a + b <= c or a + c <= b or b + c <= a:
        raise ValueError("those three distances can't form a triangle")
    if not 1 <= cfg["channel"] <= 14:
        raise ValueError("channel must be 1-14")
    if not 1 <= cfg["rate_hz"] <= 500:
        raise ValueError("rate must be 1-500 Hz")
    cfg["window_s"] = min(max(cfg["window_s"], 0.2), 10.0)
    cfg["fresnel_m"] = min(max(cfg["fresnel_m"], 0.02), 2.0)
    return cfg


class CsiUdp(asyncio.DatagramProtocol):
    def __init__(self, app):
        self.app = app

    def datagram_received(self, data, addr):
        st = self.app["state"]
        if data.startswith(b"NODE"):
            # "NODE <id> <mac> <streaming> <rate>"
            parts = data.decode(errors="replace").split()
            if len(parts) >= 3:
                st.see_node(int(parts[1]), addr[0], parts[2])
            return
        pkt = protocol.parse(data)
        if pkt is None:
            return
        st.see_node(pkt.node_id, addr[0], pkt.self_mac)
        if st.running:
            st.engine.ingest(pkt)


class State:
    def __init__(self, simulate: bool, data_port: int, control_port: int):
        self.cfg = load_config()
        self.engine = Engine()
        self.running = False
        self.simulate = simulate
        self.sim = Simulator(self.cfg) if simulate else None
        self.data_port, self.control_port = data_port, control_port
        self.nodes: dict[int, dict] = {}
        self.clients: set[web.WebSocketResponse] = set()
        self.transport: asyncio.DatagramTransport | None = None

    def see_node(self, node_id: int, ip: str, mac: str):
        n = self.nodes.setdefault(node_id, {"pkts": 0})
        n.update(ip=ip, mac=mac, last_seen=time.monotonic())
        n["pkts"] += 1

    def send_nodes(self, msg: str):
        if self.simulate or self.transport is None:
            return
        data = msg.encode()
        targets = {(n["ip"], self.control_port) for n in self.nodes.values()}
        targets.add(("255.255.255.255", self.control_port))
        for t in targets:
            try:
                self.transport.sendto(data, t)
            except OSError:
                pass

    def status(self) -> dict:
        now = time.monotonic()
        nodes = {}
        for i in (0, 1):
            n = self.nodes.get(i)
            if self.simulate:
                nodes["AB"[i]] = {"online": True, "ip": "simulated",
                                  "mac": protocol.mac_str(NODE_MAC[i])}
            elif n:
                nodes["AB"[i]] = {"online": now - n["last_seen"] < 5, "ip": n["ip"], "mac": n["mac"]}
            else:
                nodes["AB"[i]] = {"online": False, "ip": None, "mac": None}
        remaining = max(0.0, self.engine.calib_until - now) if self.engine.calibrating else 0.0
        return {"type": "status", "running": self.running, "simulate": self.simulate,
                "calibrating": self.engine.calibrating, "calib_remaining": round(remaining, 1),
                "config": self.cfg, "nodes": nodes}

    async def broadcast(self, msg: dict):
        if not self.clients:
            return
        text = json.dumps(msg)
        for ws in list(self.clients):
            try:
                await ws.send_str(text)
            except (ConnectionError, RuntimeError):
                self.clients.discard(ws)

    # ---- commands from the UI
    async def command(self, msg: dict):
        cmd = msg.get("cmd")
        if cmd == "start":
            self.engine.reset()
            self.running = True
            self.send_nodes(f"RATE {self.cfg['rate_hz']}")
            self.send_nodes("START")
        elif cmd == "stop":
            self.running = False
            self.send_nodes("STOP")
        elif cmd == "calibrate":
            self.engine.start_calibration(self.cfg["calib_s"])
        elif cmd == "config":
            old = self.cfg
            self.cfg = validate_config(msg.get("config", {}), self.cfg)
            CONFIG_PATH.write_text(json.dumps(self.cfg, indent=2))
            geometry_changed = any(self.cfg[k] != old[k] for k in ("d_ra", "d_rb", "d_ab", "channel"))
            if geometry_changed:
                # The rig moved/changed: old baselines no longer apply.
                self.engine.reset()
                if self.sim:
                    self.sim.configure(self.cfg)
            if self.cfg["rate_hz"] != old["rate_hz"]:
                self.send_nodes(f"RATE {self.cfg['rate_hz']}")
        await self.broadcast(self.status())


async def ws_handler(request):
    st: State = request.app["state"]
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    st.clients.add(ws)
    await ws.send_str(json.dumps(st.status()))
    try:
        async for m in ws:
            if m.type != WSMsgType.TEXT:
                continue
            try:
                await st.command(json.loads(m.data))
            except (ValueError, TypeError) as e:
                await ws.send_str(json.dumps({"type": "error", "message": str(e)}))
    finally:
        st.clients.discard(ws)
    return ws


async def tick_loop(app):
    st: State = app["state"]
    last_status = 0.0
    while True:
        await asyncio.sleep(TICK_S)
        if st.running:
            links = st.engine.tick(st.cfg["window_s"], st.cfg["baseline_tau_s"])
            await st.broadcast({"type": "frame", "t": time.time(), "links": links,
                                "calibrating": st.engine.calibrating})
        if time.monotonic() - last_status > 1.0:
            last_status = time.monotonic()
            await st.broadcast(st.status())


async def discovery_loop(app):
    st: State = app["state"]
    while True:
        st.send_nodes(f"HELLO {st.data_port}")
        await asyncio.sleep(2.0)


async def sim_loop(app):
    st: State = app["state"]
    period = 0.02
    carry = 0.0
    while True:
        await asyncio.sleep(period)
        if not st.running:
            continue
        st.sim.person_present = not st.engine.calibrating  # "step out" for calibration
        carry += st.cfg["rate_hz"] * period
        n, carry = int(carry), carry - int(carry)
        if n:
            for data in st.sim.packets(n):
                pkt = protocol.parse(data)
                st.see_node(pkt.node_id, "sim", pkt.self_mac)
                st.engine.ingest(pkt)


async def on_startup(app):
    st: State = app["state"]
    loop = asyncio.get_running_loop()
    if not st.simulate:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("0.0.0.0", st.data_port))
        st.transport, _ = await loop.create_datagram_endpoint(lambda: CsiUdp(app), sock=sock)
        app["tasks"] = [asyncio.create_task(discovery_loop(app))]
    else:
        app["tasks"] = [asyncio.create_task(sim_loop(app))]
    app["tasks"].append(asyncio.create_task(tick_loop(app)))


async def on_cleanup(app):
    st: State = app["state"]
    if st.running:
        st.send_nodes("STOP")
    for t in app["tasks"]:
        t.cancel()
    if st.transport:
        st.transport.close()


async def index(_request):
    return web.FileResponse(HERE / "static" / "index.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--simulate", action="store_true", help="generate synthetic CSI instead of listening for nodes")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080, help="web UI port")
    ap.add_argument("--data-port", type=int, default=5500, help="UDP port nodes send CSI to")
    ap.add_argument("--control-port", type=int, default=5501, help="UDP port nodes listen on")
    args = ap.parse_args()

    app = web.Application()
    app["state"] = State(args.simulate, args.data_port, args.control_port)
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static", HERE / "static")
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    print(f"CSI Lite: http://localhost:{args.port}  ({'simulated' if args.simulate else 'live'} mode)")
    web.run_app(app, host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()
