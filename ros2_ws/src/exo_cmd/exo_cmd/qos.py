"""
Shared QoS profile for the exoskeleton minimal serial loopback.

The interface contract (docs/01-ros2-microros-serial/01-接口契约.md, v1.0)
fixes the QoS for BOTH topics (/exo/cmd_heartbeat and /exo/mcu_status):

    Reliability = RELIABLE
    History     = KEEP_LAST
    Depth       = 10

Keeping it in one place guarantees the MacBook-side nodes here and any future
contributor use exactly the same settings. The MCU (micro-ROS) side must
match this profile or DDS endpoint matching will silently fail.
"""

from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy

# Single source of truth for the contract QoS. Use this for every
# publisher/subscriber on /exo/* topics.
EXO_QOS = QoSProfile(
    reliability=ReliabilityPolicy.RELIABLE,
    history=HistoryPolicy.KEEP_LAST,
    depth=10,
)


def qos_summary(endpoint) -> str:
    """
    Return the LOCAL, actually-applied QoS of a pub/sub as a string.

    Reads reliability/history/depth straight off the endpoint's qos_profile
    (publisher.qos_profile / subscription.qos_profile). This is the ground
    truth of what this process set, INDEPENDENT of DDS discovery.

    Why this matters: `ros2 topic info -v` reports History/Depth as UNKNOWN
    for remote endpoints, because most DDS RMW implementations do NOT
    propagate History or history-depth over discovery (only Reliability,
    Durability, Liveliness, etc. are propagated). So UNKNOWN there does NOT
    mean the depth is unset -- it means the CLI cannot see it. This helper
    prints the real local value as verifiable evidence for QoS review.
    """
    q = endpoint.qos_profile
    return (
        'reliability=%s history=%s depth=%d'
        % (q.reliability.name, q.history.name, q.depth))
