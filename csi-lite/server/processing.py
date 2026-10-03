"""CSI feature extraction.

Three links are measured:
    RA  router -> node A      (node A receives the router's ping replies)
    RB  router -> node B      (node B receives the router's ping replies)
    AB  node A <-> node B     (each node receives the other's ESP-NOW frames)

Each (link, receiving node) pair is a *stream*. AB therefore has two streams
whose features are averaged; keeping them separate stops the two radios'
different hardware phase responses from inflating the phase statistics.

Per stream, every packet is turned into
    amp_db[52]  AGC-compensated amplitude: the ESP32's automatic gain control
                rescales every packet, so the CSI *shape* is kept and its total
                power is pinned to the packet RSSI.
    phase[52]   sanitized phase: unwrapped across subcarriers, then the linear
                term (sampling-time offset) and constant term (carrier
                frequency/phase offset) are removed.

Every UI tick, the last `window_s` seconds of each stream are reduced to
per-subcarrier features (the browser averages over whatever subcarriers the
user selects):
    amp_atten   baseline amp_db - window mean amp_db     [dB]   shadowing
    amp_std     std of amp_db over the window             [dB]   motion
    phase_std   circular std of sanitized phase           [rad]  motion
    motion      mean |packet-to-packet change| of amp_db  [dB]   fast motion
The last three are reported as the excess over their empty-room level
(measured during calibration), so an idle link reads ~0 instead of its
noise floor.
and one scalar:
    rssi_atten  baseline RSSI - window mean RSSI          [dB]
"""
import time
from collections import deque

import numpy as np

from protocol import SUBCARRIERS, CsiPacket

LINKS = ("RA", "RB", "AB")
VAR_KEYS = ("amp_std", "phase_std", "motion")
_K = SUBCARRIERS.astype(np.float64)


def link_for(pkt: CsiPacket) -> str:
    if pkt.src_kind == 1:
        return "AB"
    return "RA" if pkt.node_id == 0 else "RB"


def sanitize_phase(h: np.ndarray) -> np.ndarray:
    phi = np.unwrap(np.angle(h).astype(np.float64))
    slope = (phi[-1] - phi[0]) / (_K[-1] - _K[0])
    phi = phi - slope * _K
    return phi - phi.mean()


def agc_amp_db(h: np.ndarray, rssi: int) -> np.ndarray:
    mag = np.abs(h).astype(np.float64) + 1e-3
    rms = np.sqrt(np.mean(mag ** 2))
    return 20 * np.log10(mag / rms) + rssi


class Stream:
    MAX_SAMPLES = 2000

    def __init__(self):
        self.t = deque(maxlen=self.MAX_SAMPLES)
        self.amp = deque(maxlen=self.MAX_SAMPLES)
        self.phase = deque(maxlen=self.MAX_SAMPLES)
        self.rssi = deque(maxlen=self.MAX_SAMPLES)
        self.base_amp = None   # (52,) dB
        self.base_rssi = None
        self.calibrated = False
        self._calib = []
        self.base_var = None   # empty-room level of the variability features
        self._calib_var = []

    def add(self, t: float, pkt: CsiPacket, calibrating: bool):
        if not np.any(pkt.csi):
            return
        amp = agc_amp_db(pkt.csi, pkt.rssi)
        self.t.append(t)
        self.amp.append(amp)
        self.phase.append(sanitize_phase(pkt.csi))
        self.rssi.append(pkt.rssi)
        if calibrating:
            self._calib.append((amp, pkt.rssi))

    def window(self, now: float, window_s: float):
        n = 0
        for ts in reversed(self.t):
            if now - ts > window_s:
                break
            n += 1
        if n < 3:
            return None
        sl = slice(len(self.t) - n, len(self.t))
        amp = np.array(list(self.amp)[sl])
        phase = np.array(list(self.phase)[sl])
        rssi = np.array(list(self.rssi)[sl], dtype=np.float64)
        return amp, phase, rssi

    def finish_calibration(self):
        if self._calib:
            self.base_amp = np.mean([a for a, _ in self._calib], axis=0)
            self.base_rssi = float(np.mean([r for _, r in self._calib]))
            self.calibrated = True
        if self._calib_var:
            self.base_var = {k: np.mean([v[k] for v in self._calib_var], axis=0)
                             for k in VAR_KEYS}
        self._calib = []
        self._calib_var = []

    def features(self, now: float, window_s: float, dt: float, tau_s: float,
                 calibrating: bool = False):
        w = self.window(now, window_s)
        if w is None:
            return None
        amp, phase, rssi = w
        amp_mean = amp.mean(axis=0)
        rssi_mean = float(rssi.mean())

        a = min(1.0, dt / max(tau_s, 1e-3))
        if self.base_amp is None:
            self.base_amp, self.base_rssi = amp_mean.copy(), rssi_mean
        elif not self.calibrated:
            # No explicit calibration yet: track a slow running baseline so
            # the display still shows *changes*.
            self.base_amp += a * (amp_mean - self.base_amp)
            self.base_rssi += a * (rssi_mean - self.base_rssi)

        r = np.abs(np.mean(np.exp(1j * phase), axis=0))
        var = {
            "amp_std": amp.std(axis=0),
            "phase_std": np.sqrt(-2 * np.log(np.clip(r, 1e-6, 1.0))),
            "motion": np.abs(np.diff(amp, axis=0)).mean(axis=0),
        }
        if calibrating:
            self._calib_var.append(var)
        if self.base_var is None:
            # Until calibrated, assume the quietest level seen so far is the floor.
            self.base_var = {k: v.copy() for k, v in var.items()}
        elif not self.calibrated:
            for k in VAR_KEYS:
                b = self.base_var[k]
                self.base_var[k] = np.where(var[k] < b, var[k], b + a * (var[k] - b))
        span = self.t[-1] - self.t[-len(amp)]
        return {
            "amp_atten": self.base_amp - amp_mean,
            **{k: var[k] - self.base_var[k] for k in VAR_KEYS},
            "amp": amp[-1],
            "base_amp": self.base_amp.copy(),
            "rssi_atten": self.base_rssi - rssi_mean,
            "rssi": rssi_mean,
            "rate": (len(amp) - 1) / span if span > 0 else 0.0,
        }


class Engine:
    VECTOR_KEYS = ("amp_atten", "amp_std", "phase_std", "motion", "amp", "base_amp")
    SCALAR_KEYS = ("rssi_atten", "rssi", "rate")

    def __init__(self):
        self.streams: dict[tuple[str, int], Stream] = {}
        self.calib_until = 0.0
        self.last_tick = None

    @property
    def calibrating(self) -> bool:
        return time.monotonic() < self.calib_until

    def reset(self):
        self.streams.clear()

    def start_calibration(self, seconds: float):
        for s in self.streams.values():
            s._calib = []
            s._calib_var = []
        self.calib_until = time.monotonic() + seconds

    def ingest(self, pkt: CsiPacket, t: float | None = None):
        key = (link_for(pkt), pkt.node_id)
        s = self.streams.get(key)
        if s is None:
            s = self.streams[key] = Stream()
        s.add(time.monotonic() if t is None else t, pkt, self.calibrating)

    def tick(self, window_s: float, tau_s: float) -> dict:
        now = time.monotonic()
        dt = 0.1 if self.last_tick is None else now - self.last_tick
        self.last_tick = now

        if self.calib_until and now >= self.calib_until:
            self.calib_until = 0.0
            for s in self.streams.values():
                s.finish_calibration()

        out = {}
        for link in LINKS:
            feats = [f for (l, _), s in self.streams.items() if l == link
                     for f in [s.features(now, window_s, dt, tau_s, self.calibrating)] if f]
            if not feats:
                continue
            d = {k: np.mean([f[k] for f in feats], axis=0).round(3).tolist()
                 for k in self.VECTOR_KEYS}
            d.update({k: round(float(np.mean([f[k] for f in feats])), 3)
                      for k in self.SCALAR_KEYS})
            d["rate"] = round(sum(f["rate"] for f in feats), 1)
            d["calibrated"] = all(s.calibrated for (l, _), s in self.streams.items() if l == link)
            out[link] = d
        return out
