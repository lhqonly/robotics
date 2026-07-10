#!/usr/bin/env python3
"""Publish one M2 JointTarget and capture the matching JointState quickly."""

from __future__ import annotations

import argparse
import sys
import time


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def write_state(path: str, msg) -> None:
    with open(path, "w", encoding="utf-8") as out:
        out.write("header:\n")
        out.write("  stamp:\n")
        out.write(f"    sec: {msg.header.stamp.sec}\n")
        out.write(f"    nanosec: {msg.header.stamp.nanosec}\n")
        out.write(f"  frame_id: '{msg.header.frame_id}'\n")
        out.write(f"seq: {msg.seq}\n")
        out.write(f"joint_id: {msg.joint_id}\n")
        out.write(f"control_mode: {msg.control_mode}\n")
        out.write(f"position_rad: {msg.position_rad}\n")
        out.write(f"velocity_rad_s: {msg.velocity_rad_s}\n")
        out.write(f"torque_est_nm: {msg.torque_est_nm}\n")
        out.write(f"current_a: {msg.current_a}\n")
        out.write(f"bus_voltage_v: {msg.bus_voltage_v}\n")
        out.write(f"temperature_c: {msg.temperature_c}\n")
        out.write(f"fault_bits: {msg.fault_bits}\n")
        out.write(f"vendor_fault_bits: {msg.vendor_fault_bits}\n")
        out.write(f"last_target_seq: {msg.last_target_seq}\n")
        out.write(f"sample_age_us: {msg.sample_age_us}\n")
        out.write(f"target_fresh: {bool_text(msg.target_fresh)}\n")
        out.write(f"enabled: {bool_text(msg.enabled)}\n")
        out.write("---\n")


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seq", type=int, required=True)
    parser.add_argument("--joint-id", type=int, default=0)
    parser.add_argument("--control-mode", type=int, required=True)
    parser.add_argument("--position-rad", type=float, default=0.0)
    parser.add_argument("--velocity-rad-s", type=float, default=0.0)
    parser.add_argument("--torque-nm", type=float, default=0.0)
    parser.add_argument("--kp-nm-per-rad", type=float, default=0.0)
    parser.add_argument("--kd-nm-s-per-rad", type=float, default=0.0)
    parser.add_argument("--max-torque-nm", type=float, default=0.2)
    parser.add_argument("--max-velocity-rad-s", type=float, default=0.5)
    parser.add_argument("--max-position-rad", type=float, default=0.5)
    parser.add_argument("--min-position-rad", type=float, default=-0.5)
    parser.add_argument("--ttl-us", type=int, default=100000)
    parser.add_argument("--flags", type=int, default=0)
    parser.add_argument("--frame-id", default="")
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--timeout-s", type=float, default=2.0)
    parser.add_argument("--discovery-wait-s", type=float, default=0.5)
    parser.add_argument(
        "--state-qos-reliability",
        default="best_effort",
        choices=("best_effort", "reliable"),
    )
    parser.add_argument("--state-qos-depth", type=int, default=1)
    parser.add_argument("--require-fresh", action="store_true")
    parsed = parser.parse_args(args)
    if parsed.seq < 0:
        parser.error("--seq must be >= 0")
    if parsed.ttl_us <= 0:
        parser.error("--ttl-us must be > 0")
    if parsed.timeout_s <= 0.0:
        parser.error("--timeout-s must be > 0")
    if parsed.discovery_wait_s < 0.0:
        parser.error("--discovery-wait-s must be >= 0")
    if parsed.state_qos_depth < 1:
        parser.error("--state-qos-depth must be >= 1")
    return parsed


def main(args=None) -> int:
    parsed = parse_args(args)

    import rclpy
    from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
    from exo_motor_msgs.msg import JointState, JointTarget

    latest_state = None

    rclpy.init()
    node = rclpy.create_node("motor_m2_target_capture")
    target_qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=1,
        reliability=ReliabilityPolicy.BEST_EFFORT,
    )
    state_reliability = (
        ReliabilityPolicy.RELIABLE
        if parsed.state_qos_reliability == "reliable"
        else ReliabilityPolicy.BEST_EFFORT
    )
    state_qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=parsed.state_qos_depth,
        reliability=state_reliability,
    )

    def on_state(msg):
        nonlocal latest_state
        latest_state = msg

    pub = node.create_publisher(JointTarget, "/motor/tp_joint_target", target_qos)
    node.create_subscription(JointState, "/motor/tp_joint_state", on_state, state_qos)

    warmup_deadline = time.monotonic() + parsed.discovery_wait_s
    while rclpy.ok() and time.monotonic() < warmup_deadline:
        rclpy.spin_once(node, timeout_sec=0.01)

    msg = JointTarget()
    msg.header.frame_id = parsed.frame_id
    msg.seq = parsed.seq
    msg.joint_id = parsed.joint_id
    msg.control_mode = parsed.control_mode
    msg.position_rad = parsed.position_rad
    msg.velocity_rad_s = parsed.velocity_rad_s
    msg.torque_nm = parsed.torque_nm
    msg.kp_nm_per_rad = parsed.kp_nm_per_rad
    msg.kd_nm_s_per_rad = parsed.kd_nm_s_per_rad
    msg.max_torque_nm = parsed.max_torque_nm
    msg.max_velocity_rad_s = parsed.max_velocity_rad_s
    msg.max_position_rad = parsed.max_position_rad
    msg.min_position_rad = parsed.min_position_rad
    msg.ttl_us = parsed.ttl_us
    msg.flags = parsed.flags
    pub.publish(msg)

    deadline = time.monotonic() + parsed.timeout_s
    matched = None
    while rclpy.ok() and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.005)
        if latest_state is None or latest_state.last_target_seq != parsed.seq:
            continue
        if parsed.require_fresh and not latest_state.target_fresh:
            continue
        matched = latest_state
        break

    node.destroy_node()
    rclpy.shutdown()

    if matched is None:
        print(
            f"ERROR: no matching JointState for seq {parsed.seq} "
            f"within {parsed.timeout_s:g}s",
            file=sys.stderr,
        )
        return 1
    write_state(parsed.state_out, matched)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
