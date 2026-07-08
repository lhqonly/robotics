"""
Launch only the WSL command node.

Use this when the other end of the loopback is the real MCU (Phase B) or the
micro-ROS agent, i.e. when you do NOT want the local simulator.

Run:
    ros2 launch com_bringup pc_cmd.launch.py

Performance baseline:
    ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=20 qos_depth:=1
Stress target:
    ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=200 qos_depth:=1
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    log_level = LaunchConfiguration('log_level')
    cmd_rate_hz = LaunchConfiguration('cmd_rate_hz')
    qos_depth = LaunchConfiguration('qos_depth')

    return LaunchDescription([
        DeclareLaunchArgument(
            'log_level',
            default_value='info',
            description='rclpy/RCL log level (e.g. debug, info, warn).'),
        DeclareLaunchArgument(
            'cmd_rate_hz',
            default_value='20.0',
            description='PC command publish rate in Hz.'),
        DeclareLaunchArgument(
            'qos_depth',
            default_value='1',
            description='KEEP_LAST depth for high-rate /com/* endpoints.'),

        Node(
            package='exo_cmd',
            executable='exo_cmd_node',
            name='node_com_cmd',
            output='screen',
            parameters=[{
                'cmd_rate_hz': ParameterValue(cmd_rate_hz, value_type=float),
                'qos_depth': ParameterValue(qos_depth, value_type=int),
                'sweep_period_s': 0.005,
                'rtt_warn_ms': 10.0,
                'rtt_deadline_ms': 50.0,
            }],
            arguments=['--ros-args', '--log-level', log_level],
        ),
    ])
