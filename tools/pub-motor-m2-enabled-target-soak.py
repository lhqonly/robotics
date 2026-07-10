#!/usr/bin/env python3
"""Publish an enabled M2 JointTarget stream with monotonically increasing seq."""

from __future__ import annotations

import argparse
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


def write_health(path: str, msg) -> None:
    with open(path, "w", encoding="utf-8") as out:
        out.write("header:\n")
        out.write("  stamp:\n")
        out.write(f"    sec: {msg.header.stamp.sec}\n")
        out.write(f"    nanosec: {msg.header.stamp.nanosec}\n")
        out.write(f"  frame_id: '{msg.header.frame_id}'\n")
        out.write(f"bus_id: {msg.bus_id}\n")
        out.write(f"joint_count: {msg.joint_count}\n")
        out.write(f"targets_received: {msg.targets_received}\n")
        out.write(f"targets_applied: {msg.targets_applied}\n")
        out.write(f"stale_targets: {msg.stale_targets}\n")
        out.write(f"motor_tx: {msg.motor_tx}\n")
        out.write(f"motor_rx: {msg.motor_rx}\n")
        out.write(f"motor_timeout: {msg.motor_timeout}\n")
        out.write(f"motor_fault: {msg.motor_fault}\n")
        out.write(f"target_apply_latency_p99_ms: {msg.target_apply_latency_p99_ms}\n")
        out.write(f"can_gap_p99_ms: {msg.can_gap_p99_ms}\n")
        out.write(f"reconciles: {bool_text(msg.reconciles)}\n")
        out.write("---\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hz", type=float, default=200.0)
    parser.add_argument("--duration-s", type=float, default=2.0)
    parser.add_argument("--start-seq", type=int, default=1000)
    parser.add_argument("--joint-id", type=int, default=0)
    parser.add_argument("--control-mode", type=int, default=1)
    parser.add_argument("--ttl-us", type=int, default=100000)
    parser.add_argument(
        "--qos-reliability",
        default="best_effort",
        choices=("best_effort", "reliable"),
    )
    parser.add_argument("--qos-depth", type=int, default=1)
    parser.add_argument(
        "--telemetry-qos-reliability",
        default="best_effort",
        choices=("best_effort", "reliable"),
    )
    parser.add_argument("--telemetry-qos-depth", type=int, default=1)
    parser.add_argument("--discovery-wait-s", type=float, default=1.0)
    parser.add_argument("--post-spin-s", type=float, default=0.25)
    parser.add_argument("--state-mid-out")
    parser.add_argument("--health-mid-out")
    parser.add_argument("--state-after-out")
    parser.add_argument("--health-after-out")
    args = parser.parse_args()

    if args.hz <= 0.0:
        parser.error("--hz must be > 0")
    if args.duration_s <= 0.0:
        parser.error("--duration-s must be > 0")
    if args.start_seq < 0:
        parser.error("--start-seq must be >= 0")
    if args.ttl_us <= 0:
        parser.error("--ttl-us must be > 0")
    if args.qos_depth < 1:
        parser.error("--qos-depth must be >= 1")
    if args.telemetry_qos_depth < 1:
        parser.error("--telemetry-qos-depth must be >= 1")
    if args.discovery_wait_s < 0.0:
        parser.error("--discovery-wait-s must be >= 0")
    if args.post_spin_s < 0.0:
        parser.error("--post-spin-s must be >= 0")

    import rclpy
    from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
    from exo_motor_msgs.msg import JointState, JointTarget, MotorHealth

    count = max(1, int(round(args.hz * args.duration_s)))
    period_s = 1.0 / args.hz
    last_seq = args.start_seq + count - 1
    latest_state = None
    latest_health = None
    mid_state = None
    mid_health = None
    after_state = None

    rclpy.init()
    node = rclpy.create_node("motor_m2_enabled_target_soak_pub")
    reliability = (
        ReliabilityPolicy.RELIABLE
        if args.qos_reliability == "reliable"
        else ReliabilityPolicy.BEST_EFFORT
    )
    target_qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=args.qos_depth,
        reliability=reliability,
    )
    telemetry_reliability = (
        ReliabilityPolicy.RELIABLE
        if args.telemetry_qos_reliability == "reliable"
        else ReliabilityPolicy.BEST_EFFORT
    )
    telemetry_qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=args.telemetry_qos_depth,
        reliability=telemetry_reliability,
    )

    def on_state(msg):
        nonlocal latest_state, after_state
        latest_state = msg
        if msg.last_target_seq == last_seq and msg.target_fresh:
            after_state = msg

    def on_health(msg):
        nonlocal latest_health
        latest_health = msg

    pub = node.create_publisher(JointTarget, "/motor/tp_joint_target", target_qos)
    node.create_subscription(JointState, "/motor/tp_joint_state", on_state, telemetry_qos)
    node.create_subscription(MotorHealth, "/motor/tp_motor_health", on_health, telemetry_qos)

    warmup_deadline = time.monotonic() + args.discovery_wait_s
    while rclpy.ok() and time.monotonic() < warmup_deadline:
        rclpy.spin_once(node, timeout_sec=0.01)

    started_at = time.monotonic()
    deadline = time.monotonic()
    mid_at = started_at + (args.duration_s / 2.0)
    mid_captured = False
    for offset in range(count):
        msg = JointTarget()
        msg.header.frame_id = ""
        msg.seq = args.start_seq + offset
        msg.joint_id = args.joint_id
        msg.control_mode = args.control_mode
        msg.position_rad = 0.0
        msg.velocity_rad_s = 0.0
        msg.torque_nm = 0.0
        msg.kp_nm_per_rad = 0.0
        msg.kd_nm_s_per_rad = 0.0
        msg.max_torque_nm = 0.2
        msg.max_velocity_rad_s = 0.5
        msg.max_position_rad = 0.5
        msg.min_position_rad = -0.5
        msg.ttl_us = args.ttl_us
        msg.flags = 0
        pub.publish(msg)
        rclpy.spin_once(node, timeout_sec=0.0)
        if not mid_captured and time.monotonic() >= mid_at:
            mid_state = latest_state
            mid_health = latest_health
            mid_captured = True
        deadline += period_s
        sleep_s = deadline - time.monotonic()
        if sleep_s > 0.0:
            time.sleep(sleep_s)
    if not mid_captured:
        mid_state = latest_state
        mid_health = latest_health
    elapsed_s = time.monotonic() - started_at
    actual_hz = count / elapsed_s if elapsed_s > 0.0 else 0.0

    post_deadline = time.monotonic() + args.post_spin_s
    while rclpy.ok() and time.monotonic() < post_deadline:
        rclpy.spin_once(node, timeout_sec=0.005)
        if after_state is not None and latest_health is not None:
            break

    if args.state_mid_out and mid_state is not None:
        write_state(args.state_mid_out, mid_state)
    if args.health_mid_out and mid_health is not None:
        write_health(args.health_mid_out, mid_health)
    if args.state_after_out:
        state_to_write = after_state if after_state is not None else latest_state
        if state_to_write is not None:
            write_state(args.state_after_out, state_to_write)
    if args.health_after_out and latest_health is not None:
        write_health(args.health_after_out, latest_health)

    node.destroy_node()
    rclpy.shutdown()

    print(f"enabled_soak_requested_hz={args.hz:.6f}")
    print(f"enabled_soak_target_hz={actual_hz:.6f}")
    print(f"enabled_soak_duration_s={elapsed_s:.6f}")
    print(f"enabled_soak_qos_reliability={args.qos_reliability}")
    print(f"enabled_soak_qos_depth={args.qos_depth}")
    print(f"enabled_soak_telemetry_qos_reliability={args.telemetry_qos_reliability}")
    print(f"enabled_soak_telemetry_qos_depth={args.telemetry_qos_depth}")
    print(f"enabled_soak_discovery_wait_s={args.discovery_wait_s:.6f}")
    print(f"enabled_soak_post_spin_s={args.post_spin_s:.6f}")
    print(f"enabled_soak_targets_sent={count}")
    print(f"enabled_soak_first_target_seq={args.start_seq}")
    print(f"enabled_soak_last_target_seq={last_seq}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
