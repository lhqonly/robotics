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
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    log_level = LaunchConfiguration('log_level')
    cmd_rate_hz = LaunchConfiguration('cmd_rate_hz')
    qos_depth = LaunchConfiguration('qos_depth')
    qos_reliability = LaunchConfiguration('qos_reliability')

    return LaunchDescription([
        DeclareLaunchArgument(
            'log_level',
            default_value='info',
            description='rclpy/RCL log level (e.g. debug, info, warn).'),
        DeclareLaunchArgument(
            'cmd_rate_hz',
            default_value='10.0',
            description='PC command publish rate in Hz.'),
        DeclareLaunchArgument(
            'qos_depth',
            default_value='10',
            description='KEEP_LAST depth for /com/* endpoints.'),
        DeclareLaunchArgument(
            'qos_reliability',
            default_value='reliable',
            description="QoS reliability: 'reliable' or 'best_effort'."),

        Node(
            package='exo_cmd',
            executable='exo_cmd_node',
            name='node_com_cmd',
            output='screen',
            parameters=[{
                'cmd_rate_hz': ParameterValue(cmd_rate_hz, value_type=float),
                'qos_depth': ParameterValue(qos_depth, value_type=int),
                'qos_reliability': qos_reliability,
            }],
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
