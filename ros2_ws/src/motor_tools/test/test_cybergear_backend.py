import pytest

from motor_tools import cybergear_frame_codec as codec
from motor_tools.cybergear_backend import (
    CyberGearBackendError,
    CyberGearCanBackend,
    CyberGearCanConfig,
)


class _FakeMessage:
    def __init__(self, arbitration_id, data=b'\x00' * 8, is_extended_id=True):
        self.arbitration_id = arbitration_id
        self.data = data
        self.is_extended_id = is_extended_id


class _FakeBus:
    def __init__(self, messages):
        self._messages = list(messages)

    def recv(self, timeout):
        del timeout
        if self._messages:
            return self._messages.pop(0)
        return None


def test_probe_ignores_unknown_and_non_feedback_frames_until_clear_failure():
    unknown_command_id = (31 << 24) | (253 << 8) | 127
    non_feedback_id = codec.make_enable_frame(127, 253).arbitration_id
    backend = CyberGearCanBackend(CyberGearCanConfig(motor_id=127))
    backend._bus = _FakeBus([
        _FakeMessage(unknown_command_id),
        _FakeMessage(non_feedback_id),
    ])

    with pytest.raises(CyberGearBackendError, match='no motor status response observed'):
        backend.probe(timeout_s=0.001)
