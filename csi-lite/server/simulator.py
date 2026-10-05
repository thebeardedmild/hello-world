"""Synthetic CSI source so the whole pipeline runs without hardware.

A person walks a Lissajous path around the rig. Each link's channel is a
direct path plus a few fixed reflectors; the person shadows the direct path
when they stand inside its Fresnel zone and adds their own scattered path.
The output then gets the same impairments the ESP32 produces (random phase
offset, timing-offset phase slope, AGC gain jumps, int8 quantization) and is
encoded with the firmware's wire format.
"""
import math
import time

import numpy as np

from protocol import NODE_LETTERS, SRC_ROUTER, SUBCARRIERS, encode

C = 299_792_458.0
ROUTER_MAC = bytes.fromhex("02c51e000001")
MAX_SIM_PACKETS_S = 1500  # keep the simulator from eating a whole CPU core


def node_mac(node_id: int) -> bytes:
    return bytes.fromhex("02c51e0000") + bytes([0xA0 + node_id])


def channel_freq(ch: int) -> float:
    return 2.484e9 if ch == 14 else 2.407e9 + 5e6 * ch


class Simulator:
    def __init__(self, cfg: dict, seed: int = 7):
        self.rng = np.random.default_rng(seed)
        self.seq = 0
        self.t0 = time.monotonic()
        self.person_present = True
        self.configure(cfg)

    def configure(self, cfg: dict):
        self.cfg = dict(cfg)
        self.pos = {name: np.array(p, dtype=float) for name, p in cfg["devices"].items()}
        self.node_ids = sorted(NODE_LETTERS.index(n) for n in self.pos if n != "R")
        self.f = channel_freq(cfg["channel"]) + SUBCARRIERS * 312.5e3
        pts = np.array(list(self.pos.values()))
        self.center = pts.mean(axis=0)
        self.span = (pts.max(axis=0) - pts.min(axis=0)).clip(1.0, None)
        lo, hi = pts.min(axis=0) - 1.5, pts.max(axis=0) + 1.5
        self.reflectors = self.rng.uniform(lo, hi, size=(4, 2))
        self.refl_gain = self.rng.uniform(0.15, 0.4, size=4)
        # (rx node id, tx name, rx name, src node id)
        self.streams = []
        for rx in self.node_ids:
            rxn = NODE_LETTERS[rx]
            self.streams.append((rx, "R", rxn, SRC_ROUTER))
            for tx in self.node_ids:
                if tx != rx:
                    self.streams.append((rx, NODE_LETTERS[tx], rxn, tx))
        self.static = {(tx, rx): self._static(tx, rx) for _, tx, rx, _ in self.streams}

    def effective_rate(self, rate_hz: float) -> float:
        return min(rate_hz, MAX_SIM_PACKETS_S / max(len(self.streams), 1))

    def person(self, t: float) -> np.ndarray:
        x = self.center[0] + 0.75 * self.span[0] * math.sin(2 * math.pi * t / 23.0)
        y = self.center[1] + 0.75 * self.span[1] * math.sin(2 * math.pi * t / 17.0 + 0.6)
        return np.array([x, y])

    def _path(self, d: float) -> np.ndarray:
        return np.exp(-2j * math.pi * self.f * d / C) / max(d, 0.3)

    def _static(self, tx: str, rx: str) -> np.ndarray:
        ptx, prx = self.pos[tx], self.pos[rx]
        h = np.zeros(len(self.f), complex)
        for q, g in zip(self.reflectors, self.refl_gain):
            h += g * self._path(float(np.linalg.norm(ptx - q) + np.linalg.norm(q - prx)))
        return h

    def channel(self, tx: str, rx: str, p: np.ndarray | None) -> np.ndarray:
        ptx, prx = self.pos[tx], self.pos[rx]
        d = float(np.linalg.norm(ptx - prx))
        los = self._path(d)
        h = self.static[(tx, rx)].copy()
        if p is not None:
            d1, d2 = float(np.linalg.norm(ptx - p)), float(np.linalg.norm(p - prx))
            excess = d1 + d2 - d
            shadow_db = 9.0 * math.exp(-(excess / 0.18) ** 2)
            los = los * 10 ** (-shadow_db / 20)
            h += 0.35 * self._path(d1 + d2)
        return h + los

    def _impair(self, h: np.ndarray) -> tuple[np.ndarray, int]:
        rssi = -38 + 20 * math.log10(np.sqrt(np.mean(np.abs(h) ** 2)) + 1e-9) \
            + self.rng.normal(0, 0.7)
        h = h * np.exp(1j * (self.rng.uniform(-math.pi, math.pi)
                             + 2 * math.pi * self.rng.uniform(-0.03, 0.03) * SUBCARRIERS))
        gain = 32 * 10 ** (self.rng.normal(0, 1.2) / 20) / np.sqrt(np.mean(np.abs(h) ** 2))
        h = h * gain
        h += self.rng.normal(0, 0.8, h.shape) + 1j * self.rng.normal(0, 0.8, h.shape)
        return h, int(round(rssi))

    def packets(self, n_per_stream: int) -> list[bytes]:
        """One burst: n packets for every stream."""
        t = time.monotonic() - self.t0
        p = self.person(t) if self.person_present else None
        out = []
        for node, tx, rx, src in self.streams:
            src_mac = ROUTER_MAC if src == SRC_ROUTER else node_mac(src)
            for _ in range(n_per_stream):
                jitter = None if p is None else p + self.rng.normal(0, 0.01, 2)
                h, rssi = self._impair(self.channel(tx, rx, jitter))
                self.seq += 1
                out.append(encode(node, node_mac(node), src_mac, rssi, self.cfg["channel"],
                                  src, self.seq, int(t * 1e6), h))
        return out
