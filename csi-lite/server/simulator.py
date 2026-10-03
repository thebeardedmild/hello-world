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

from protocol import SUBCARRIERS, encode

C = 299_792_458.0
ROUTER_MAC = bytes.fromhex("02c51e000001")
NODE_MAC = (bytes.fromhex("02c51e00000a"), bytes.fromhex("02c51e00000b"))


def channel_freq(ch: int) -> float:
    return 2.484e9 if ch == 14 else 2.407e9 + 5e6 * ch


def triangle(d_ra: float, d_rb: float, d_ab: float):
    """Router at the origin, node A on +x, node B above the x axis."""
    ax = d_ra
    bx = (d_ra ** 2 + d_rb ** 2 - d_ab ** 2) / (2 * d_ra)
    by = math.sqrt(max(d_rb ** 2 - bx ** 2, 0.0))
    return np.array([0.0, 0.0]), np.array([ax, 0.0]), np.array([bx, by])


class Simulator:
    def __init__(self, cfg: dict, seed: int = 7):
        self.rng = np.random.default_rng(seed)
        self.seq = 0
        self.t0 = time.monotonic()
        self.person_present = True
        self.configure(cfg)

    def configure(self, cfg: dict):
        self.cfg = dict(cfg)
        r, a, b = triangle(cfg["d_ra"], cfg["d_rb"], cfg["d_ab"])
        self.pos = {"R": r, "A": a, "B": b}
        self.f = channel_freq(cfg["channel"]) + SUBCARRIERS * 312.5e3
        pts = np.array([r, a, b])
        self.center = pts.mean(axis=0)
        self.span = (pts.max(axis=0) - pts.min(axis=0)).clip(1.0, None)
        lo, hi = pts.min(axis=0) - 1.5, pts.max(axis=0) + 1.5
        self.reflectors = self.rng.uniform(lo, hi, size=(4, 2))
        self.refl_gain = self.rng.uniform(0.15, 0.4, size=4)

    def person(self, t: float) -> np.ndarray:
        x = self.center[0] + 0.75 * self.span[0] * math.sin(2 * math.pi * t / 23.0)
        y = self.center[1] + 0.75 * self.span[1] * math.sin(2 * math.pi * t / 17.0 + 0.6)
        return np.array([x, y])

    def _path(self, d: float) -> np.ndarray:
        return np.exp(-2j * math.pi * self.f * d / C) / max(d, 0.3)

    def channel(self, tx: str, rx: str, p: np.ndarray | None) -> np.ndarray:
        ptx, prx = self.pos[tx], self.pos[rx]
        d = float(np.linalg.norm(ptx - prx))
        los = self._path(d)
        h = np.zeros_like(los)
        for q, g in zip(self.reflectors, self.refl_gain):
            h += g * self._path(float(np.linalg.norm(ptx - q) + np.linalg.norm(q - prx)))
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
        """One burst: n packets for each of the four streams."""
        t = time.monotonic() - self.t0
        p = self.person(t) if self.person_present else None
        out = []
        # (rx node id, tx name, rx name, src_kind, src mac)
        streams = ((0, "R", "A", 0, ROUTER_MAC), (1, "R", "B", 0, ROUTER_MAC),
                   (0, "B", "A", 1, NODE_MAC[1]), (1, "A", "B", 1, NODE_MAC[0]))
        for node, tx, rx, kind, src in streams:
            for _ in range(n_per_stream):
                jitter = None if p is None else p + self.rng.normal(0, 0.01, 2)
                h, rssi = self._impair(self.channel(tx, rx, jitter))
                self.seq += 1
                out.append(encode(node, NODE_MAC[node], src, rssi, self.cfg["channel"],
                                  kind, self.seq, int(t * 1e6), h))
        return out
