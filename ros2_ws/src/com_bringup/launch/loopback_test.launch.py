"""
Hardware-free self-test launch (Phase A).

Brings up BOTH:
  - node_com_cmd      : publishes /com/tp_cmd_heartbeat, checks /com/tp_mcu_status
  - node_com_loopback : MCU simulator, echoes tp_cmd_heartbeat back to tp_mcu_status

Run:
    ros2 launch com_bringup loopback_test.launch.py

Then in another sourced terminal:
    ros2 topic echo /com/tp_mcu_status
    ros2 topic info -v /com/tp_cmd_heartbeat

You should see /com/tp_mcu_status carrying the same monotonically increasing
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
            name='node_com_cmd',
            output='screen',
            arguments=['--ros-args', '--log-level', log_level],
        ),
        Node(
            package='exo_cmd',
            executable='loopback_node',
            name='node_com_loopback',
            output='screen',
            arguments=['--ros-args', '--log-level', log_level],
        ),
    ])
