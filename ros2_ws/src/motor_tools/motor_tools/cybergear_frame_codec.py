"""Pure CyberGear frame codec for the M0 PC-side adapter."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Dict


class CyberGearCodecError(ValueError):
    """Raised when a CyberGear frame cannot be encoded or decoded."""


class CyberGearCommand(IntEnum):
    """CyberGear communication types kept inside the adapter boundary."""

    CONTROL = 1
    FEEDBACK = 2
    ENABLE = 3
    STOP = 4
    SET_ZERO = 6
    PARAM_WRITE = 18


class CyberGearRunMode(IntEnum):
    """CyberGear run modes kept inside the adapter boundary."""

    MOTION = 0
    POSITION = 1
    VELOCITY = 2
    CURRENT = 3


FAULT_UNDERVOLTAGE = 1 << 0
FAULT_OVERCURRENT = 1 << 1
FAULT_OVERTEMPERATURE = 1 << 2
FAULT_MAGNETIC_ENCODER = 1 << 3
FAULT_HALL_ENCODER = 1 << 4
FAULT_UNCALIBRATED = 1 << 5

P_MIN_RAD = -12.5
P_MAX_RAD = 12.5
V_MIN_RAD_S = -30.0
V_MAX_RAD_S = 30.0
T_MIN_NM = -12.0
T_MAX_NM = 12.0
KP_MIN = 0.0
KP_MAX = 500.0
KD_MIN = 0.0
KD_MAX = 5.0
TEMP_SCALE_C = 10.0

RUN_MODE_PARAM_INDEX = 0x7005
CURRENT_REF_PARAM_INDEX = 0x7006
VELOCITY_REF_PARAM_INDEX = 0x700A
POSITION_REF_PARAM_INDEX = 0x7016


@dataclass(frozen=True)
class CyberGearFrame:
    """A transport-neutral CAN frame value used only by the adapter."""

    arbitration_id: int
    data: bytes
    is_extended_id: bool = True


@dataclass(frozen=True)
class CyberGearStatus:
    """Decoded CyberGear status, still confined to codec/backend internals."""

    motor_id: int
    host_id: int
    position_rad: float
    velocity_rad_s: float
    torque_nm: float
    temperature_c: float
    fault_bits: int
    raw_fault_bits: int


def make_enable_frame(motor_id: int, host_id: int) -> CyberGearFrame:
    """Encode an enable command frame."""
    return _make_frame(CyberGearCommand.ENABLE, motor_id, host_id, bytes(8))


def make_disable_frame(motor_id: int, host_id: int, clear_fault: bool = False) -> CyberGearFrame:
    """Encode a disable/stop command frame."""
    data = bytes([1 if clear_fault else 0]) + bytes(7)
    return _make_frame(CyberGearCommand.STOP, motor_id, host_id, data)


def make_stop_frame(motor_id: int, host_id: int, clear_fault: bool = False) -> CyberGearFrame:
    """Encode an explicit stop command frame."""
    return make_disable_frame(motor_id, host_id, clear_fault=clear_fault)


def make_set_zero_frame(motor_id: int, host_id: int) -> CyberGearFrame:
    """Encode a set-mechanical-zero command frame."""
    return _make_frame(CyberGearCommand.SET_ZERO, motor_id, host_id, bytes([1]) + bytes(7))


def make_motion_frame(
        motor_id: int,
        host_id: int,
        torque_nm: float,
        position_rad: float,
        velocity_rad_s: float,
        kp: float,
        kd: float) -> CyberGearFrame:
    """Encode CyberGear motion-control values into one command frame."""
    torque_u16 = float_to_uint(torque_nm, T_MIN_NM, T_MAX_NM, 16)
    data = b''.join([
        _u16_to_be(float_to_uint(position_rad, P_MIN_RAD, P_MAX_RAD, 16)),
        _u16_to_be(float_to_uint(velocity_rad_s, V_MIN_RAD_S, V_MAX_RAD_S, 16)),
        _u16_to_be(float_to_uint(kp, KP_MIN, KP_MAX, 16)),
        _u16_to_be(float_to_uint(kd, KD_MIN, KD_MAX, 16)),
    ])
    return _make_frame(CyberGearCommand.CONTROL, motor_id, torque_u16, data)


def make_position_frame(motor_id: int, host_id: int, position_rad: float) -> CyberGearFrame:
    """Encode run-mode setup plus a position reference write frame."""
    return make_param_write_frame(
        motor_id, host_id, POSITION_REF_PARAM_INDEX, float(position_rad))


def make_velocity_frame(motor_id: int, host_id: int, velocity_rad_s: float) -> CyberGearFrame:
    """Encode run-mode setup plus a velocity reference write frame."""
    return make_param_write_frame(
        motor_id, host_id, VELOCITY_REF_PARAM_INDEX, float(velocity_rad_s))


def make_current_frame(motor_id: int, host_id: int, current_a: float) -> CyberGearFrame:
    """Encode run-mode setup plus a current reference write frame."""
    return make_param_write_frame(
        motor_id, host_id, CURRENT_REF_PARAM_INDEX, float(current_a))


def make_torque_frame(
        motor_id: int,
        host_id: int,
        torque_nm: float,
        torque_constant_nm_per_a: float = 0.18) -> CyberGearFrame:
    """Encode torque as a CyberGear current reference write frame."""
    if torque_constant_nm_per_a <= 0.0:
        raise CyberGearCodecError('torque constant must be positive')
    return make_current_frame(motor_id, host_id, torque_nm / torque_constant_nm_per_a)


def make_run_mode_frame(
        motor_id: int,
        host_id: int,
        run_mode: CyberGearRunMode) -> CyberGearFrame:
    """Encode a CyberGear run-mode parameter write."""
    return make_u8_param_write_frame(motor_id, host_id, RUN_MODE_PARAM_INDEX, int(run_mode))


def make_param_write_frame(
        motor_id: int,
        host_id: int,
        index: int,
        value: float) -> CyberGearFrame:
    """Encode a CyberGear float parameter write."""
    import struct

    data = _u16_to_le(index) + bytes(2) + struct.pack('<f', float(value))
    return _make_frame(CyberGearCommand.PARAM_WRITE, motor_id, host_id, data)


def make_u8_param_write_frame(
        motor_id: int,
        host_id: int,
        index: int,
        value: int) -> CyberGearFrame:
    """Encode a CyberGear uint8 parameter write."""
    _check_u8(value, 'param value')
    data = int(index).to_bytes(4, 'little') + bytes([int(value)]) + bytes(3)
    return _make_frame(CyberGearCommand.PARAM_WRITE, motor_id, host_id, data)


def parse_status_frame(frame: CyberGearFrame) -> CyberGearStatus:
    """Decode a CyberGear feedback frame into internal status fields."""
    command, motor_id, data_field = split_extended_id(frame.arbitration_id)
    if command != CyberGearCommand.FEEDBACK:
        raise CyberGearCodecError('not a CyberGear feedback frame')
    if len(frame.data) != 8:
        raise CyberGearCodecError('feedback frame must carry 8 bytes')
    raw_fault_bits = (data_field >> 8) & 0x3F
    host_id = data_field & 0xFF
    return CyberGearStatus(
        motor_id=motor_id,
        host_id=host_id,
        position_rad=uint_to_float(_be_to_u16(frame.data[0:2]), P_MIN_RAD, P_MAX_RAD, 16),
        velocity_rad_s=uint_to_float(_be_to_u16(frame.data[2:4]), V_MIN_RAD_S, V_MAX_RAD_S, 16),
        torque_nm=uint_to_float(_be_to_u16(frame.data[4:6]), T_MIN_NM, T_MAX_NM, 16),
        temperature_c=_be_to_u16(frame.data[6:8]) / TEMP_SCALE_C,
        fault_bits=decode_fault_bits(raw_fault_bits),
        raw_fault_bits=raw_fault_bits,
    )


def decode_fault_bits(raw_fault_bits: int) -> int:
    """Map CyberGear fault feedback bits into adapter-local fault bits."""
    value = 0
    mapping: Dict[int, int] = {
        0: FAULT_UNDERVOLTAGE,
        1: FAULT_OVERCURRENT,
        2: FAULT_OVERTEMPERATURE,
        3: FAULT_MAGNETIC_ENCODER,
        4: FAULT_HALL_ENCODER,
        5: FAULT_UNCALIBRATED,
    }
    for raw_bit, fault_bit in mapping.items():
        if raw_fault_bits & (1 << raw_bit):
            value |= fault_bit
    return value


def make_extended_id(command: CyberGearCommand, motor_id: int, data_field: int) -> int:
    """Pack the CyberGear extended arbitration id."""
    _check_u8(motor_id, 'motor_id')
    if not 0 <= int(data_field) <= 0xFFFF:
        raise CyberGearCodecError('data_field must fit in 16 bits')
    return ((int(command) & 0x1F) << 24) | ((int(data_field) & 0xFFFF) << 8) | int(motor_id)


def split_extended_id(arbitration_id: int):
    """Unpack the CyberGear extended arbitration id."""
    if not 0 <= int(arbitration_id) <= 0x1FFFFFFF:
        raise CyberGearCodecError('arbitration_id must fit in 29 bits')
    command_value = (int(arbitration_id) >> 24) & 0x1F
    try:
        command = CyberGearCommand(command_value)
    except ValueError as exc:
        raise CyberGearCodecError(
            f'unknown CyberGear command {command_value}') from exc
    data_field = (int(arbitration_id) >> 8) & 0xFFFF
    motor_id = int(arbitration_id) & 0xFF
    return command, motor_id, data_field


def float_to_uint(value: float, lower: float, upper: float, bits: int) -> int:
    """Convert a bounded float to an unsigned integer field."""
    if lower >= upper:
        raise CyberGearCodecError('lower bound must be smaller than upper bound')
    max_int = (1 << bits) - 1
    clamped = min(max(float(value), lower), upper)
    return int(round((clamped - lower) * max_int / (upper - lower)))


def uint_to_float(value: int, lower: float, upper: float, bits: int) -> float:
    """Convert an unsigned integer field to a bounded float."""
    if not 0 <= int(value) <= (1 << bits) - 1:
        raise CyberGearCodecError('integer value outside encoded range')
    return float(value) * (upper - lower) / float((1 << bits) - 1) + lower


def _make_frame(
        command: CyberGearCommand,
        motor_id: int,
        data_field: int,
        data: bytes) -> CyberGearFrame:
    if len(data) != 8:
        raise CyberGearCodecError('CyberGear frames must carry 8 data bytes')
    return CyberGearFrame(make_extended_id(command, motor_id, data_field), bytes(data), True)


def _check_u8(value: int, name: str):
    if not 0 <= int(value) <= 0xFF:
        raise CyberGearCodecError(f'{name} must fit in 8 bits')


def _u16_to_be(value: int) -> bytes:
    return int(value).to_bytes(2, 'big')


def _u16_to_le(value: int) -> bytes:
    return int(value).to_bytes(2, 'little')


def _be_to_u16(value: bytes) -> int:
    return int.from_bytes(value, 'big')
