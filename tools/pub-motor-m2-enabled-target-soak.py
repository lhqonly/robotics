#!/usr/bin/env python3
"""Publish an enabled M2 JointTarget stream with monotonically increasing seq."""

from __future__ import annotations

import argparse
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hz", type=float, default=200.0)
    parser.add_argument("--duration-s", type=float, default=2.0)
    parser.add_argument("--start-seq", type=int, default=1000)
    parser.add_argument("--joint-id", type=int, default=0)
    parser.add_argument("--control-mode", type=int, default=1)
    parser.add_argument("--ttl-us", type=int, default=100000)
    args = parser.parse_args()

    if args.hz <= 0.0:
        parser.error("--hz must be > 0")
    if args.duration_s <= 0.0:
        parser.error("--duration-s must be > 0")
    if args.start_seq < 0:
        parser.error("--start-seq must be >= 0")
    if args.ttl_us <= 0:
        parser.error("--ttl-us must be > 0")

    import rclpy
    from exo_motor_msgs.msg import JointTarget

    count = max(1, int(round(args.hz * args.duration_s)))
    period_s = 1.0 / args.hz
    last_seq = args.start_seq + count - 1

    rclpy.init()
    node = rclpy.create_node("motor_m2_enabled_target_soak_pub")
    pub = node.create_publisher(JointTarget, "/motor/tp_joint_target", 10)

    deadline = time.monotonic()
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
        deadline += period_s
        sleep_s = deadline - time.monotonic()
        if sleep_s > 0.0:
            time.sleep(sleep_s)

    node.destroy_node()
    rclpy.shutdown()

    print(f"enabled_soak_target_hz={args.hz:.6f}")
    print(f"enabled_soak_duration_s={args.duration_s:.6f}")
    print(f"enabled_soak_targets_sent={count}")
    print(f"enabled_soak_first_target_seq={args.start_seq}")
    print(f"enabled_soak_last_target_seq={last_seq}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
