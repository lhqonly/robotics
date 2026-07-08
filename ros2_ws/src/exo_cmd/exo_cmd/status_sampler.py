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

from exo_cmd.link_health import forward_distance
from exo_cmd.qos import make_exo_qos
from exo_msgs.msg import ExoStatus
import rclpy
from rclpy.node import Node

TOPIC_STATUS = '/com/tp_mcu_status'


class StatusStats:
    """Small rclpy-free accumulator for status timing and seq-step stats."""

    def __init__(self):
        self.first_s = None
        self.last_s = None
        self.count = 0
        self.min_gap_s = math.inf
        self.max_gap_s = 0.0
        self.sum_gap_s = 0.0
        self.sum_gap_sq_s = 0.0
        self.first_seq = None
        self.last_seq = None
        self.seq_delta_count = 0
        self.seq_delta_min = None
        self.seq_delta_max = None
        self.seq_delta_sum = 0

    def add(self, now_s: float, seq: int) -> None:
        if self.first_s is None:
            self.first_s = now_s
            self.first_seq = seq
        if self.last_s is not None:
            gap_s = now_s - self.last_s
            self.min_gap_s = min(self.min_gap_s, gap_s)
            self.max_gap_s = max(self.max_gap_s, gap_s)
            self.sum_gap_s += gap_s
            self.sum_gap_sq_s += gap_s * gap_s
        if self.last_seq is not None:
            delta = forward_distance(self.last_seq, seq)
            self.seq_delta_count += 1
            self.seq_delta_sum += delta
            self.seq_delta_min = (
                delta if self.seq_delta_min is None
                else min(self.seq_delta_min, delta))
            self.seq_delta_max = (
                delta if self.seq_delta_max is None
                else max(self.seq_delta_max, delta))
        self.last_s = now_s
        self.last_seq = seq
        self.count += 1

    def summary(self) -> str:
        if self.count < 2 or self.first_s is None or self.last_s is None:
            return ('status_sampler: count=%d rate_hz=0.000 min_gap_s=0.000 '
                    'max_gap_s=0.000 std_gap_s=0.000 duration_s=0.000 '
                    'seq_rate_hz=0.000 seq_delta_avg=0.000 '
                    'seq_delta_min=0 seq_delta_max=0'
                    % self.count)
        samples = self.count - 1
        duration_s = self.last_s - self.first_s
        rate_hz = samples / duration_s if duration_s > 0.0 else 0.0
        mean_gap_s = self.sum_gap_s / samples
        variance = max((self.sum_gap_sq_s / samples) -
                       (mean_gap_s * mean_gap_s), 0.0)
        if self.seq_delta_count and duration_s > 0.0:
            seq_span = forward_distance(self.first_seq, self.last_seq)
            seq_rate_hz = seq_span / duration_s
            seq_delta_avg = self.seq_delta_sum / self.seq_delta_count
            seq_delta_min = self.seq_delta_min
            seq_delta_max = self.seq_delta_max
        else:
            seq_rate_hz = 0.0
            seq_delta_avg = 0.0
            seq_delta_min = 0
            seq_delta_max = 0
        return ('status_sampler: count=%d rate_hz=%.3f min_gap_s=%.3f '
                'max_gap_s=%.3f std_gap_s=%.5f duration_s=%.3f '
                'seq_rate_hz=%.3f seq_delta_avg=%.3f '
                'seq_delta_min=%d seq_delta_max=%d'
                % (self.count, rate_hz, self.min_gap_s, self.max_gap_s,
                   math.sqrt(variance), duration_s, seq_rate_hz,
                   seq_delta_avg, seq_delta_min, seq_delta_max))


class StatusSampler(Node):
    def __init__(self, duration_s: float, qos_depth: int,
                 qos_reliability: str):
        super().__init__('node_com_status_sampler')
        self._duration_s = duration_s
        self._start_s = time.monotonic()
        self._stats = StatusStats()
        qos = make_exo_qos(qos_depth, qos_reliability)
        self.create_subscription(ExoStatus, TOPIC_STATUS, self._on_status, qos)

    def _on_status(self, msg: ExoStatus) -> None:
        self._stats.add(time.monotonic(), msg.header.seq)

    @property
    def done(self) -> bool:
        return (time.monotonic() - self._start_s) >= self._duration_s

    def summary(self) -> str:
        return self._stats.summary()


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
