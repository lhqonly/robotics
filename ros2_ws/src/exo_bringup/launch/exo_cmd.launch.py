"""Launch only the WSL exo_cmd node.

Use this when the other end of the loopback is the real MCU (Phase B) or the
micro-ROS agent, i.e. when you do NOT want the local simulator.

Run:
    ros2 launch exo_bringup exo_cmd.launch.py
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
    ])
