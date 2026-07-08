"""
Launch the PC command node with the high-rate latest-target preset.

Use this only when the MCU firmware was built with the matching performance
profile, typically:

    EXO_QOS_BEST_EFFORT=ON
    EXO_STATUS_EVERY_N=40

Run:
    ros2 launch com_bringup pc_latest_target.launch.py
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    log_level = LaunchConfiguration('log_level')
    cmd_rate_hz = LaunchConfiguration('cmd_rate_hz')
    status_every_n = LaunchConfiguration('status_every_n')
    sample_window = LaunchConfiguration('sample_window')
    rtt_warn_ms = LaunchConfiguration('rtt_warn_ms')
    rtt_deadline_ms = LaunchConfiguration('rtt_deadline_ms')
    sweep_period_s = LaunchConfiguration('sweep_period_s')
    summary_period_s = LaunchConfiguration('summary_period_s')
    link_health_period_s = LaunchConfiguration('link_health_period_s')
    startup_grace_s = LaunchConfiguration('startup_grace_s')
    executor_threads = LaunchConfiguration('executor_threads')
    log_sent_commands = LaunchConfiguration('log_sent_commands')
    rtt_warn_log_period_s = LaunchConfiguration('rtt_warn_log_period_s')
    launch_prefix = LaunchConfiguration('launch_prefix')

    return LaunchDescription([
        DeclareLaunchArgument(
            'log_level',
            default_value='info',
            description='rclpy/RCL log level (e.g. debug, info, warn).'),
        DeclareLaunchArgument(
            'cmd_rate_hz',
            default_value='200.0',
            description='PC latest-target command publish rate in Hz.'),
        DeclareLaunchArgument(
            'status_every_n',
            default_value='40',
            description='MCU status decimation factor used by sampled monitor.'),
        DeclareLaunchArgument(
            'sample_window',
            default_value='1024',
            description='Recent sent seq window for sampled status matching.'),
        DeclareLaunchArgument(
            'rtt_warn_ms',
            default_value='10.0',
            description='Soft RTT warning threshold in milliseconds.'),
        DeclareLaunchArgument(
            'rtt_deadline_ms',
            default_value='120.0',
            description='Hard sampled-status deadline in milliseconds.'),
        DeclareLaunchArgument(
            'sweep_period_s',
            default_value='0.02',
            description='Deadline sweep period in seconds.'),
        DeclareLaunchArgument(
            'summary_period_s',
            default_value='1.0',
            description='Link-health summary log period in seconds.'),
        DeclareLaunchArgument(
            'link_health_period_s',
            default_value='5.0',
            description=(
                '/com/tp_link_health publish period in seconds. Keep slower '
                'than command publish for high-rate latest-target runs.')),
        DeclareLaunchArgument(
            'startup_grace_s',
            default_value='3.0',
            description=(
                'Startup seconds to publish commands without counting '
                'link-health.')),
        DeclareLaunchArgument(
            'executor_threads',
            default_value='0',
            description='MultiThreadedExecutor threads. 0 lets rclpy auto-pick.'),
        DeclareLaunchArgument(
            'log_sent_commands',
            default_value='false',
            description='Print every sent command at DEBUG for troubleshooting.'),
        DeclareLaunchArgument(
            'rtt_warn_log_period_s',
            default_value='1.0',
            description='Throttle soft RTT warning logs; 0 disables throttling.'),
        DeclareLaunchArgument(
            'launch_prefix',
            default_value='',
            description=(
                'Optional process prefix for host scheduling experiments, '
                'for example "taskset -c 2" or "chrt -f 20".')),

        Node(
            package='exo_cmd',
            executable='exo_cmd_node',
            name='node_com_cmd',
            output='screen',
            prefix=launch_prefix,
            parameters=[{
                'cmd_rate_hz': ParameterValue(cmd_rate_hz, value_type=float),
                'cmd_catchup_max': 1,
                'qos_depth': 1,
                'qos_reliability': 'best_effort',
                'tracking_mode': 'sampled',
                'status_every_n': ParameterValue(status_every_n, value_type=int),
                'sample_window': ParameterValue(sample_window, value_type=int),
                'sweep_period_s': ParameterValue(sweep_period_s, value_type=float),
                'summary_period_s': ParameterValue(
                    summary_period_s, value_type=float),
                'link_health_period_s': ParameterValue(
                    link_health_period_s, value_type=float),
                'startup_grace_s': ParameterValue(
                    startup_grace_s, value_type=float),
                'rtt_warn_ms': ParameterValue(rtt_warn_ms, value_type=float),
                'rtt_deadline_ms': ParameterValue(rtt_deadline_ms, value_type=float),
                'executor_threads': ParameterValue(
                    executor_threads, value_type=int),
                'log_matched_events': False,
                'log_sent_commands': ParameterValue(
                    log_sent_commands, value_type=bool),
                'rtt_warn_log_period_s': ParameterValue(
                    rtt_warn_log_period_s, value_type=float),
            }],
            arguments=['--ros-args', '--log-level', log_level],
        ),
    ])
