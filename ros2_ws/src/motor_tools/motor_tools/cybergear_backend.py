"""Guarded python-can backend for M0 CyberGear PC direct bring-up."""

from __future__ import annotations

from dataclasses import dataclass
import math
import time

from motor_tools import cybergear_frame_codec as codec


class CyberGearBackendError(RuntimeError):
    """Raised for clear no-hardware / unsafe-hardware failures."""


@dataclass(frozen=True)
class CyberGearCanConfig:
    """CAN transport config for a single CyberGear motor."""

    interface: str = 'pcan'
    channel: str = 'PCAN_USBBUS1'
    bitrate: int = 1000000
    motor_id: int = 127
    host_id: int = 253


class CyberGearCanBackend:
    """Small python-can adapter used by the M0 probe/benchtop tools."""

    def __init__(self, config: CyberGearCanConfig):
        self.config = config
        self._bus = None

    def __enter__(self) -> 'CyberGearCanBackend':
        self.open()
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        self.close()

    def open(self):
        """Open the configured CAN channel or raise a clear failure."""
        try:
            import can
        except ImportError as exc:
            raise CyberGearBackendError(
                'python-can is not installed; install it before hardware probe') from exc
        try:
            self._bus = can.interface.Bus(
                interface=self.config.interface,
                channel=self.config.channel,
                bitrate=self.config.bitrate,
            )
        except Exception as exc:
            raise CyberGearBackendError(
                f'failed to open motor transport {self.config.interface}:'
                f'{self.config.channel} at {self.config.bitrate} bps') from exc

    def close(self):
        """Close the CAN channel if it was opened."""
        if self._bus is not None:
            shutdown = getattr(self._bus, 'shutdown', None)
            if shutdown is not None:
                shutdown()
            self._bus = None

    def probe(self, timeout_s: float = 0.25) -> codec.CyberGearStatus:
        """Read one motor status frame; never reports success without a reply."""
        self._require_open()
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            msg = self._bus.recv(timeout=max(0.0, deadline - time.monotonic()))
            if msg is None:
                break
            frame = codec.CyberGearFrame(
                arbitration_id=int(msg.arbitration_id),
                data=bytes(msg.data),
                is_extended_id=bool(msg.is_extended_id),
            )
            try:
                status = codec.parse_status_frame(frame)
            except codec.CyberGearCodecError:
                continue
            if status.motor_id == self.config.motor_id:
                return status
        raise CyberGearBackendError(
            'no motor status response observed; check power, wiring, bitrate, '
            'termination, and motor id')

    def send_disable(self):
        """Send a best-effort disable frame for emergency/manual cleanup."""
        self._send_frame(codec.make_disable_frame(
            self.config.motor_id, self.config.host_id, clear_fault=False))

    def send_enable(self):
        """Send an enable frame after the caller has completed preflight."""
        self._send_frame(codec.make_enable_frame(
            self.config.motor_id, self.config.host_id))

    def send_stop(self):
        """Send a best-effort stop frame."""
        self._send_frame(codec.make_stop_frame(
            self.config.motor_id, self.config.host_id, clear_fault=False))

    def send_run_mode(self, run_mode: codec.CyberGearRunMode):
        """Set the CyberGear run mode."""
        self._send_frame(codec.make_run_mode_frame(
            self.config.motor_id, self.config.host_id, run_mode))

    def send_position_reference(self, position_rad: float):
        """Send a position reference parameter write."""
        self._send_frame(codec.make_position_frame(
            self.config.motor_id, self.config.host_id, position_rad))

    def send_velocity_reference(self, velocity_rad_s: float):
        """Send a velocity reference parameter write."""
        self._send_frame(codec.make_velocity_frame(
            self.config.motor_id, self.config.host_id, velocity_rad_s))

    def send_torque_reference(self, torque_nm: float):
        """Send a torque reference parameter write."""
        self._send_frame(codec.make_torque_frame(
            self.config.motor_id, self.config.host_id, torque_nm))

    def preflight(
            self,
            max_torque_nm: float,
            max_velocity_rad_s: float,
            min_position_rad: float,
            max_position_rad: float):
        """Verify transport, limits, readability, and no fault before enable."""
        limits = (
            max_torque_nm,
            max_velocity_rad_s,
            min_position_rad,
            max_position_rad,
        )
        if (
                not all(math.isfinite(float(value)) for value in limits)
                or max_torque_nm <= 0.0
                or max_velocity_rad_s <= 0.0
                or min_position_rad >= max_position_rad):
            raise CyberGearBackendError(
                'explicit positive torque/velocity limits and valid position '
                'bounds are required before enable')
        status = self.probe()
        if status.fault_bits:
            raise CyberGearBackendError('motor reports a fault; clear and inspect before enable')
        return status

    def _send_frame(self, frame: codec.CyberGearFrame):
        self._require_open()
        try:
            import can
        except ImportError as exc:
            raise CyberGearBackendError('python-can is not installed') from exc
        msg = can.Message(
            arbitration_id=frame.arbitration_id,
            data=frame.data,
            is_extended_id=frame.is_extended_id,
        )
        self._bus.send(msg, timeout=0.1)

    def _require_open(self):
        if self._bus is None:
            raise CyberGearBackendError('motor transport is not open')
