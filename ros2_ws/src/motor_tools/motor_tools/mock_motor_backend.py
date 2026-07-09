"""Hardware-free motor backend for validating the /motor joint contract."""

from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Optional, Tuple

from motor_tools.joint_model import (
    ControlMode,
    FAULT_INJECTED,
    FAULT_LIMITS_REQUIRED,
    FAULT_POSITION_LIMITED,
    FAULT_TORQUE_LIMITED,
    FAULT_TTL_EXPIRED,
    FAULT_VELOCITY_LIMITED,
    JointState,
    JointTarget,
    TARGET_FLAG_CLEAR_FAULT,
    TARGET_FLAG_INJECT_FAULT,
    has_explicit_motion_limits,
)


def monotonic_us() -> int:
    """Return a monotonic timestamp in microseconds."""
    return time.monotonic_ns() // 1000


def _clamp(value: float, lower: float, upper: float) -> Tuple[float, bool]:
    if lower > upper:
        lower, upper = upper, lower
    limited = value < lower or value > upper
    return min(max(value, lower), upper), limited


@dataclass(frozen=True)
class MockMotorConfig:
    """Physical-ish limits for the M0 mock backend."""

    joint_id: int = 0
    bus_voltage_v: float = 24.0
    temperature_c: float = 32.0
    torque_constant_nm_per_a: float = 0.18


class MockMotorBackend:
    """A deterministic, side-effect-free-ish backend for M0 self-tests."""

    def __init__(self, config: Optional[MockMotorConfig] = None):
        self.config = config or MockMotorConfig()
        self._target: Optional[JointTarget] = None
        self._target_time_us = 0
        self._state_seq = 0
        self._position_rad = 0.0
        self._velocity_rad_s = 0.0
        self._torque_nm = 0.0
        self._fault_bits = 0
        self._last_target_seq = 0

    @property
    def fault_bits(self) -> int:
        """Return currently latched mock fault bits."""
        return self._fault_bits

    def apply_target(self, target: JointTarget, now_us: Optional[int] = None):
        """Accept a joint-level target and latch mock fault injection flags."""
        now = monotonic_us() if now_us is None else int(now_us)
        clean = target.normalized()
        if clean.flags & TARGET_FLAG_CLEAR_FAULT:
            self._fault_bits = 0
        if clean.flags & TARGET_FLAG_INJECT_FAULT:
            self._fault_bits |= FAULT_INJECTED
        self._target = clean
        self._target_time_us = now
        self._last_target_seq = clean.seq

    def step(self, now_us: Optional[int] = None) -> JointState:
        """Advance the mock backend one sample and return a JointState."""
        now = monotonic_us() if now_us is None else int(now_us)
        target, fresh, age_us = self._fresh_target(now)
        mode = ControlMode.DISABLED if target is None else target.control_mode
        enabled = fresh and mode != ControlMode.DISABLED
        if self._fault_bits & FAULT_INJECTED:
            enabled = False
            fresh = False
        if enabled and not has_explicit_motion_limits(target):
            self._fault_bits |= FAULT_LIMITS_REQUIRED
            enabled = False

        if target is None or not enabled:
            self._velocity_rad_s = 0.0
            self._torque_nm = 0.0
        else:
            self._apply_limited_target(target)

        self._state_seq = (self._state_seq + 1) % (2 ** 32)
        return JointState(
            seq=self._state_seq,
            joint_id=self.config.joint_id if target is None else target.joint_id,
            control_mode=mode,
            position_rad=self._position_rad,
            velocity_rad_s=self._velocity_rad_s,
            torque_est_nm=self._torque_nm,
            current_a=self._current_from_torque(self._torque_nm),
            bus_voltage_v=self.config.bus_voltage_v,
            temperature_c=self.config.temperature_c,
            fault_bits=self._fault_bits,
            vendor_fault_bits=0,
            last_target_seq=self._last_target_seq,
            sample_age_us=age_us,
            enabled=enabled,
            target_fresh=fresh,
        )

    def _fresh_target(self, now_us: int):
        if self._target is None:
            return None, False, 0
        age_us = max(0, now_us - self._target_time_us)
        fresh = self._target.ttl_us <= 0 or age_us <= self._target.ttl_us
        if not fresh:
            self._fault_bits |= FAULT_TTL_EXPIRED
        return self._target, fresh, age_us

    def _apply_limited_target(self, target: JointTarget):
        min_pos = target.min_position_rad
        max_pos = target.max_position_rad
        max_vel = abs(target.max_velocity_rad_s)
        max_torque = abs(target.max_torque_nm)

        wanted_pos = target.position_rad
        wanted_vel = target.velocity_rad_s
        wanted_torque = target.torque_nm

        limited_pos, did_pos = _clamp(wanted_pos, min_pos, max_pos)
        limited_vel, did_vel = _clamp(wanted_vel, -max_vel, max_vel)
        limited_torque, did_torque = _clamp(wanted_torque, -max_torque, max_torque)
        if did_pos:
            self._fault_bits |= FAULT_POSITION_LIMITED
        if did_vel:
            self._fault_bits |= FAULT_VELOCITY_LIMITED
        if did_torque:
            self._fault_bits |= FAULT_TORQUE_LIMITED

        if target.control_mode == ControlMode.POSITION:
            self._position_rad = limited_pos
            self._velocity_rad_s = limited_vel
            self._torque_nm = limited_torque
        elif target.control_mode == ControlMode.VELOCITY:
            self._velocity_rad_s = limited_vel
            self._position_rad = _clamp(
                self._position_rad + limited_vel * 0.02, min_pos, max_pos)[0]
            self._torque_nm = limited_torque
        elif target.control_mode == ControlMode.TORQUE:
            self._torque_nm = limited_torque
            self._velocity_rad_s = limited_vel
        elif target.control_mode == ControlMode.ZERO_TORQUE:
            self._torque_nm = 0.0
            self._velocity_rad_s = 0.0

    def _current_from_torque(self, torque_nm: float) -> float:
        kt = self.config.torque_constant_nm_per_a
        if kt <= 0.0:
            return 0.0
        return torque_nm / kt
