"""
Application-level CRC for the exo_msgs envelope (contract §7.9 / Q4).

This is NOT a link-error guard -- the frame layer (CRC-16) plus RELIABLE QoS
already cover wire corruption. This is a self-check switch to catch
application packing / serialization bugs (e.g. a struct field written to the
wrong offset, a byte-order mismatch between the two ends). Default disabled
(crc_enabled=False); developers may turn it on.

Canonical coverage (when enabled), fixed by the contract so the two ends agree
byte-for-byte:

  * compute over the concatenation  seq || stamp_mono_ns || payload
  * with the ``crc`` field itself set to 0 (avoid CRC self-reference)
  * each field serialized little-endian at its wire width:
      seq            -> uint32  (4 bytes, LE)
      stamp_mono_ns  -> uint64  (8 bytes, LE)
      payload        -> int32   (4 bytes, LE, two's complement)
  * algorithm = CRC-32 (zlib.crc32), matching the 32-bit ``crc`` field width.

M-A delivers only the WSL-side Python implementation of this canonical recipe;
making the F103 firmware compute the identical bytes is an M-B integration task.
"""

import struct
import zlib

# little-endian: uint32 seq, uint64 stamp, int32 payload (crc held at 0).
_PACK = struct.Struct('<IQi')


def compute_crc(seq: int, stamp_mono_ns: int, payload: int) -> int:
    """
    Return the CRC-32 over the canonical seq||stamp||payload byte stream.

    The ``crc`` field is treated as 0 and not part of the stream (it is the
    value being computed). Result is a uint32 (0 .. 2^32-1).
    """
    data = _PACK.pack(seq & 0xFFFFFFFF, stamp_mono_ns & 0xFFFFFFFFFFFFFFFF,
                      payload)
    return zlib.crc32(data) & 0xFFFFFFFF
