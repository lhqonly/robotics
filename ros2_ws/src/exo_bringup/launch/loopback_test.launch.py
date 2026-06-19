"""Hardware-free self-test launch (Phase A).

Brings up BOTH:
  - exo_cmd      : publishes /exo/cmd_heartbeat, checks /exo/mcu_status
  - exo_loopback : MCU simulator, echoes cmd_heartbeat back to mcu_status

Run:
    ros2 launch exo_bringup loopback_test.launch.py

Then in another sourced terminal:
    ros2 topic echo /exo/mcu_status
    ros2 topic info -v /exo/cmd_heartbeat

You should see /exo/mcu_status carrying the same monotonically increasing
values exo_cmd publishes, and exo_cmd logging "round-trip OK".
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    log_level = LaunchConfiguration('log_level')

    return LaunchDescription([
        DeclareLaunchArgument(
            'log_level',
            default_value='info',
            description='rclpy/RCL log level (e.g. debug, info, warn).'),

        Node(
            package='exo_cmd',
            executable='exo_cmd_node',
            name='exo_cmd',
            output='screen',
            arguments=['--ros-args', '--log-level', log_level],
        ),
        Node(
            package='exo_cmd',
            executable='loopback_node',
            name='exo_loopback',
            output='screen',
            arguments=['--ros-args', '--log-level', log_level],
        ),
    ])
