# Copyright 2026 Tom
#
# Licensed under the MIT License.

"""
Application-level CRC recipe (contract §7.9 / Q4).

Logic-layer tests for exo_cmd.crc.compute_crc: deterministic, canonical
little-endian coverage of seq || stamp_mono_ns || payload (crc held at 0,
CRC-32). No ROS dependency.
"""

import struct
import zlib

from exo_cmd.crc import compute_crc


def test_crc_matches_canonical_little_endian_stream():
    """compute_crc equals zlib.crc32 of the canonical LE byte stream."""
    seq, stamp, payload = 0x01020304, 0x1122334455667788, -5
    expected = zlib.crc32(struct.pack('<IQi', seq, stamp, payload)) & 0xFFFFFFFF
    assert compute_crc(seq, stamp, payload) == expected


def test_crc_is_deterministic():
    """Same inputs -> same CRC (a self-check must be stable)."""
    assert compute_crc(7, 123456789, 42) == compute_crc(7, 123456789, 42)


def test_crc_changes_when_any_field_changes():
    """A change in any covered field flips the CRC (it covers all three)."""
    base = compute_crc(10, 1000, 3)
    assert compute_crc(11, 1000, 3) != base       # seq changed
    assert compute_crc(10, 1001, 3) != base       # stamp changed
    assert compute_crc(10, 1000, 4) != base       # payload changed


def test_crc_handles_negative_payload_two_complement():
    """Negative int32 payload is packed two's-complement, not rejected."""
    # struct '<i' accepts -1; CRC must compute without error and be in range.
    c = compute_crc(0, 0, -1)
    assert 0 <= c < 2 ** 32


def test_crc_in_uint32_range():
    """Result always fits the uint32 crc field."""
    for seq, stamp, payload in [(0, 0, 0), (2 ** 32 - 1, 2 ** 64 - 1,
                                            2 ** 31 - 1),
                                (123, 456, -2 ** 31)]:
        c = compute_crc(seq, stamp, payload)
        assert 0 <= c < 2 ** 32
