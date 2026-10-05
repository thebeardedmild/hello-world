"""CSI feature extraction.

With one router (R) and nodes A, B, C, ... the links are
    R-A, R-B, ...   router -> node   (each node receives the router's ping replies)
    A-B, A-C, ...   node <-> node    (each node receives the others' ESP-NOW frames)

Each (link, receiving node) pair is a *stream*. A node-to-node link therefore
has two streams (A hears B, B hears A) whose features are averaged; keeping
them separate stops the two radios' different hardware phase responses from
inflating the phase statistics.

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
noise floor. Plus one scalar:
    rssi_atten  baseline RSSI - window mean RSSI          [dB]
"""
import time

import numpy as np

from protocol import SRC_ROUTER, SUBCARRIERS, CsiPacket, node_name

VAR_KEYS = ("amp_std", "phase_std", "motion")
_K = SUBCARRIERS.astype(np.float64)
_NSC = len(SUBCARRIERS)


def link_for(pkt: CsiPacket) -> str:
    rx = node_name(pkt.node_id)
    if pkt.src_node == SRC_ROUTER:
        return f"R-{rx}"
    return "-".join(sorted((rx, node_name(pkt.src_node))))


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
    CAP = 1024  # samples kept per stream (~10 s at 100 Hz)

    def __init__(self):
        self.t = np.full(self.CAP, -np.inf)
        self.amp = np.zeros((self.CAP, _NSC), np.float32)
        self.phase = np.zeros((self.CAP, _NSC), np.float32)
        self.rssi = np.zeros(self.CAP, np.float32)
        self.i = 0                # next write slot
        self.base_amp = None      # (52,) dB
        self.base_rssi = None
        self.base_var = None      # empty-room level of the variability features
        self.calibrated = False
        self._calib = []
        self._calib_var = []

    def add(self, t: float, pkt: CsiPacket, calibrating: bool):
        if not np.any(pkt.csi):
            return
        j = self.i % self.CAP
        amp = agc_amp_db(pkt.csi, pkt.rssi)
        self.t[j] = t
        self.amp[j] = amp
        self.phase[j] = sanitize_phase(pkt.csi)
        self.rssi[j] = pkt.rssi
        self.i += 1
        if calibrating:
            self._calib.append((amp, pkt.rssi))

    def window(self, now: float, window_s: float):
        n = int(np.count_nonzero(self.t >= now - window_s))
        if n < 3:
            return None
        idx = np.arange(self.i - n, self.i) % self.CAP  # oldest -> newest
        return self.t[idx], self.amp[idx], self.phase[idx], self.rssi[idx]

    def start_calibration(self):
        self._calib = []
        self._calib_var = []

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
        t, amp, phase, rssi = w
        amp_mean = amp.mean(axis=0)
        rssi_mean = float(rssi.mean())

        a = min(1.0, dt / max(tau_s, 1e-3))
        if self.base_amp is None:
            self.base_amp, self.base_rssi = amp_mean.astype(np.float64), rssi_mean
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
            self.base_var = {k: v.astype(np.float64) for k, v in var.items()}
        elif not self.calibrated:
            # Until calibrated, treat the quietest level seen as the floor.
            for k in VAR_KEYS:
                b = self.base_var[k]
                self.base_var[k] = np.where(var[k] < b, var[k], b + a * (var[k] - b))
        span = t[-1] - t[0]
        return {
            "amp_atten": self.base_amp - amp_mean,
            **{k: var[k] - self.base_var[k] for k in VAR_KEYS},
            "rssi_atten": self.base_rssi - rssi_mean,
            "rssi": rssi_mean,
            "rate": (len(t) - 1) / span if span > 0 else 0.0,
        }


class Engine:
    VECTOR_KEYS = ("amp_atten",) + VAR_KEYS
    SCALAR_KEYS = ("rssi_atten", "rssi")

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
            s.start_calibration()
        self.calib_until = time.monotonic() + seconds

    def ingest(self, pkt: CsiPacket, t: float | None = None):
        key = (link_for(pkt), pkt.node_id)
        s = self.streams.get(key)
        if s is None:
            s = self.streams[key] = Stream()
        s.add(time.monotonic() if t is None else t, pkt, self.calibrating)

    def tick(self, window_s: float, tau_s: float, now: float | None = None) -> dict:
        now = time.monotonic() if now is None else now
        dt = 0.1 if self.last_tick is None else now - self.last_tick
        self.last_tick = now

        if self.calib_until and now >= self.calib_until:
            self.calib_until = 0.0
            for s in self.streams.values():
                s.finish_calibration()

        by_link: dict[str, list] = {}
        calibrated: dict[str, bool] = {}
        for (link, _rx), s in self.streams.items():
            f = s.features(now, window_s, dt, tau_s, self.calibrating)
            calibrated[link] = calibrated.get(link, True) and s.calibrated
            if f:
                by_link.setdefault(link, []).append(f)

        out = {}
        for link, feats in sorted(by_link.items()):
            d = {k: np.round(np.mean([f[k] for f in feats], axis=0), 3).tolist()
                 for k in self.VECTOR_KEYS}
            d.update({k: round(float(np.mean([f[k] for f in feats])), 3)
                      for k in self.SCALAR_KEYS})
            d["rate"] = round(sum(f["rate"] for f in feats), 1)
            d["calibrated"] = calibrated[link]
            out[link] = d
        return out
