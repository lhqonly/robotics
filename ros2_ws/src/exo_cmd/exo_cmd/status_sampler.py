"""
Standalone /com/tp_mcu_status rate sampler.

This is a deliberately small rclpy subscriber used by hardware perf runs. It
measures receive intervals inside a normal ROS node, so it gives us a second
view beside the `ros2 topic hz` CLI, whose own scheduling can occasionally add
long gaps.
"""

import argparse
import math
import time

from exo_cmd.qos import make_exo_qos
from exo_msgs.msg import ExoStatus
import rclpy
from rclpy.node import Node

TOPIC_STATUS = '/com/tp_mcu_status'


class StatusSampler(Node):
    def __init__(self, duration_s: float, qos_depth: int,
                 qos_reliability: str):
        super().__init__('node_com_status_sampler')
        self._duration_s = duration_s
        self._start_s = time.monotonic()
        self._first_s = None
        self._last_s = None
        self._count = 0
        self._min_gap_s = math.inf
        self._max_gap_s = 0.0
        self._sum_gap_s = 0.0
        self._sum_gap_sq_s = 0.0
        qos = make_exo_qos(qos_depth, qos_reliability)
        self.create_subscription(ExoStatus, TOPIC_STATUS, self._on_status, qos)

    def _on_status(self, _msg: ExoStatus) -> None:
        now_s = time.monotonic()
        if self._first_s is None:
            self._first_s = now_s
        if self._last_s is not None:
            gap_s = now_s - self._last_s
            self._min_gap_s = min(self._min_gap_s, gap_s)
            self._max_gap_s = max(self._max_gap_s, gap_s)
            self._sum_gap_s += gap_s
            self._sum_gap_sq_s += gap_s * gap_s
        self._last_s = now_s
        self._count += 1

    @property
    def done(self) -> bool:
        return (time.monotonic() - self._start_s) >= self._duration_s

    def summary(self) -> str:
        if self._count < 2 or self._first_s is None or self._last_s is None:
            return ('status_sampler: count=%d rate_hz=0.000 min_gap_s=0.000 '
                    'max_gap_s=0.000 std_gap_s=0.000 duration_s=0.000'
                    % self._count)
        samples = self._count - 1
        duration_s = self._last_s - self._first_s
        rate_hz = samples / duration_s if duration_s > 0.0 else 0.0
        mean_gap_s = self._sum_gap_s / samples
        variance = max((self._sum_gap_sq_s / samples) -
                       (mean_gap_s * mean_gap_s), 0.0)
        return ('status_sampler: count=%d rate_hz=%.3f min_gap_s=%.3f '
                'max_gap_s=%.3f std_gap_s=%.5f duration_s=%.3f'
                % (self._count, rate_hz, self._min_gap_s, self._max_gap_s,
                   math.sqrt(variance), duration_s))


def parse_args(args=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--duration-s', type=float, default=10.0)
    parser.add_argument('--qos-depth', type=int, default=1)
    parser.add_argument('--qos-reliability', default='reliable',
                        choices=('reliable', 'best_effort'))
    return parser.parse_args(args)


def main(args=None):
    parsed = parse_args(args)
    rclpy.init()
    node = StatusSampler(parsed.duration_s, parsed.qos_depth,
                         parsed.qos_reliability)
    try:
        while rclpy.ok() and not node.done:
            rclpy.spin_once(node, timeout_sec=0.05)
        print(node.summary(), flush=True)
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
