"""Wire format shared with firmware/csi_node/main/main.c."""
import struct
from dataclasses import dataclass

import numpy as np

CSI_MAGIC = 0x4C495343  # "CSIL"
HDR = struct.Struct("<IBB6s6sbBBBIIH")  # 32 bytes, mirrors csi_pkt_hdr_t

SRC_ROUTER = 0xFF
NODE_LETTERS = "ABCDEFGHIJKLMNOP"  # node ID 0..15 -> display name


def node_name(node_id: int) -> str:
    return NODE_LETTERS[node_id] if 0 <= node_id < len(NODE_LETTERS) else f"N{node_id}"


# ESP32 L-LTF buffer: 64 subcarriers stored in FFT order (0..31, -32..-1),
# each as int8 [imag, real]. Of those, -26..-1 and 1..26 carry energy.
SUBCARRIERS = np.array([k for k in range(-26, 27) if k != 0])  # 52
_FFT_POS = np.where(SUBCARRIERS >= 0, SUBCARRIERS, SUBCARRIERS + 64)


@dataclass
class CsiPacket:
    node_id: int
    self_mac: str
    src_mac: str
    rssi: int
    channel: int
    src_kind: int  # 0 = router -> node, 1 = other node -> node
    src_node: int  # transmitting node ID, or SRC_ROUTER
    seq: int
    timestamp_us: int
    csi: np.ndarray  # complex64, shape (52,), ordered by SUBCARRIERS


def mac_str(b: bytes) -> str:
    return ":".join(f"{x:02x}" for x in b)


def parse(data: bytes) -> CsiPacket | None:
    if len(data) < HDR.size:
        return None
    (magic, ver, node_id, self_mac, src_mac, rssi, src_node, ch, kind,
     seq, ts, n) = HDR.unpack_from(data)
    if magic != CSI_MAGIC or n < 128 or len(data) < HDR.size + n:
        return None
    raw = np.frombuffer(data, dtype=np.int8, count=128, offset=HDR.size)
    raw = raw.reshape(64, 2).astype(np.float32)
    h = (raw[:, 1] + 1j * raw[:, 0])[_FFT_POS].astype(np.complex64)
    if kind == 0:
        src_node = SRC_ROUTER
    elif ver < 2:
        src_node = 1 - node_id  # v1 firmware: two nodes only, byte was noise floor
    return CsiPacket(node_id, mac_str(self_mac), mac_str(src_mac), rssi,
                     ch, kind, src_node, seq, ts, h)


def encode(node_id: int, self_mac: bytes, src_mac: bytes, rssi: int,
           channel: int, src_node: int, seq: int, ts_us: int, h: np.ndarray) -> bytes:
    """Build a packet exactly as the firmware does (used by the simulator)."""
    buf = np.zeros((64, 2), dtype=np.int8)
    q = np.clip(np.round(h), -127, 127)
    buf[_FFT_POS, 0] = q.imag.astype(np.int8)
    buf[_FFT_POS, 1] = q.real.astype(np.int8)
    src_kind = 0 if src_node == SRC_ROUTER else 1
    hdr = HDR.pack(CSI_MAGIC, 2, node_id, self_mac, src_mac, int(rssi), src_node,
                   channel, src_kind, seq & 0xFFFFFFFF, ts_us & 0xFFFFFFFF, 128)
    return hdr + buf.tobytes()
