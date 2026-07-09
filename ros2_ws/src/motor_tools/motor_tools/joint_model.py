"""Vendor-neutral joint target/state structures used before exo_motor_msgs."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import IntEnum
import math
from typing import Dict


class ControlMode(IntEnum):
    """Vendor-neutral control modes for the M0 PC tools."""

    DISABLED = 0
    ZERO_TORQUE = 1
    TORQUE = 2
    VELOCITY = 3
    POSITION = 4
    IMPEDANCE = 5
    CALIBRATION = 6


FAULT_TTL_EXPIRED = 1 << 0
FAULT_POSITION_LIMITED = 1 << 1
FAULT_VELOCITY_LIMITED = 1 << 2
FAULT_TORQUE_LIMITED = 1 << 3
FAULT_LIMITS_REQUIRED = 1 << 4
FAULT_INJECTED = 1 << 16

TARGET_FLAG_INJECT_FAULT = 1 << 0
TARGET_FLAG_CLEAR_FAULT = 1 << 1


@dataclass(frozen=True)
class JointTarget:
    """M0 joint target fields aligned with the future /motor contract."""

    seq: int
    joint_id: int
    control_mode: ControlMode
    position_rad: float = 0.0
    velocity_rad_s: float = 0.0
    torque_nm: float = 0.0
    kp_nm_per_rad: float = 0.0
    kd_nm_s_per_rad: float = 0.0
    max_torque_nm: float = 0.0
    max_velocity_rad_s: float = 0.0
    min_position_rad: float = 0.0
    max_position_rad: float = 0.0
    ttl_us: int = 0
    flags: int = 0

    def normalized(self) -> 'JointTarget':
        """Return a target with integer enum fields coerced to ControlMode."""
        return JointTarget(
            seq=int(self.seq),
            joint_id=int(self.joint_id),
            control_mode=ControlMode(int(self.control_mode)),
            position_rad=float(self.position_rad),
            velocity_rad_s=float(self.velocity_rad_s),
            torque_nm=float(self.torque_nm),
            kp_nm_per_rad=float(self.kp_nm_per_rad),
            kd_nm_s_per_rad=float(self.kd_nm_s_per_rad),
            max_torque_nm=float(self.max_torque_nm),
            max_velocity_rad_s=float(self.max_velocity_rad_s),
            min_position_rad=float(self.min_position_rad),
            max_position_rad=float(self.max_position_rad),
            ttl_us=int(self.ttl_us),
            flags=int(self.flags),
        )


@dataclass(frozen=True)
class JointState:
    """M0 joint state fields aligned with the future /motor contract."""

    seq: int
    joint_id: int
    control_mode: ControlMode
    position_rad: float
    velocity_rad_s: float
    torque_est_nm: float
    current_a: float
    bus_voltage_v: float
    temperature_c: float
    fault_bits: int
    vendor_fault_bits: int
    last_target_seq: int
    sample_age_us: int
    enabled: bool
    target_fresh: bool

    def as_joint_dict(self) -> Dict[str, object]:
        """Return a JSON-friendly joint-level structure for tools/tests."""
        value = asdict(self)
        value['control_mode'] = int(self.control_mode)
        return value


def has_explicit_motion_limits(target: JointTarget) -> bool:
    """Return whether a target carries all safety limits required for motion."""
    values = (
        target.max_torque_nm,
        target.max_velocity_rad_s,
        target.min_position_rad,
        target.max_position_rad,
    )
    if not all(math.isfinite(float(value)) for value in values):
        return False
    return (
        float(target.max_torque_nm) > 0.0
        and float(target.max_velocity_rad_s) > 0.0
        and float(target.min_position_rad) < float(target.max_position_rad)
    )
