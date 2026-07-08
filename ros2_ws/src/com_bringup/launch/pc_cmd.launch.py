"""
Launch only the WSL command node.

Use this when the other end of the loopback is the real MCU (Phase B) or the
micro-ROS agent, i.e. when you do NOT want the local simulator.

Run:
    ros2 launch com_bringup pc_cmd.launch.py

Performance baseline:
    ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=20 qos_depth:=2
Stress target:
    ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=200 qos_depth:=1
    ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=200 qos_reliability:=best_effort
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    log_level = LaunchConfiguration('log_level')
    cmd_rate_hz = LaunchConfiguration('cmd_rate_hz')
    cmd_catchup_max = LaunchConfiguration('cmd_catchup_max')
    qos_depth = LaunchConfiguration('qos_depth')
    qos_reliability = LaunchConfiguration('qos_reliability')
    tracking_mode = LaunchConfiguration('tracking_mode')
    status_every_n = LaunchConfiguration('status_every_n')
    sample_window = LaunchConfiguration('sample_window')
    rtt_warn_ms = LaunchConfiguration('rtt_warn_ms')
    rtt_deadline_ms = LaunchConfiguration('rtt_deadline_ms')
    sweep_period_s = LaunchConfiguration('sweep_period_s')
    summary_period_s = LaunchConfiguration('summary_period_s')
    link_health_period_s = LaunchConfiguration('link_health_period_s')
    startup_grace_s = LaunchConfiguration('startup_grace_s')
    executor_threads = LaunchConfiguration('executor_threads')
    log_matched_events = LaunchConfiguration('log_matched_events')
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
            default_value='20.0',
            description='PC command publish rate in Hz.'),
        DeclareLaunchArgument(
            'cmd_catchup_max',
            default_value='0',
            description='Max extra commands to publish when the timer is late.'),
        DeclareLaunchArgument(
            'qos_depth',
            default_value='2',
            description='KEEP_LAST depth for /com/* endpoints.'),
        DeclareLaunchArgument(
            'qos_reliability',
            default_value='reliable',
            description="QoS reliability: 'reliable' or 'best_effort'."),
        DeclareLaunchArgument(
            'tracking_mode',
            default_value='echo',
            description="Link monitor mode: 'echo' or 'sampled'."),
        DeclareLaunchArgument(
            'status_every_n',
            default_value='1',
            description='In sampled mode, track one status for every N commands.'),
        DeclareLaunchArgument(
            'sample_window',
            default_value='4096',
            description='Recent sent seq window for sampled status matching.'),
        DeclareLaunchArgument(
            'rtt_warn_ms',
            default_value='10.0',
            description='Soft RTT warning threshold in milliseconds.'),
        DeclareLaunchArgument(
            'rtt_deadline_ms',
            default_value='120.0',
            description='Hard echo deadline in milliseconds before LOST.'),
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
            default_value='1.0',
            description='/com/tp_link_health publish period in seconds.'),
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
            'log_matched_events',
            default_value='false',
            description='Print every matched echo at INFO. False keeps it DEBUG.'),
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
                'cmd_catchup_max': ParameterValue(
                    cmd_catchup_max, value_type=int),
                'qos_depth': ParameterValue(qos_depth, value_type=int),
                'qos_reliability': qos_reliability,
                'tracking_mode': tracking_mode,
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
                'log_matched_events': ParameterValue(
                    log_matched_events, value_type=bool),
                'log_sent_commands': ParameterValue(
                    log_sent_commands, value_type=bool),
                'rtt_warn_log_period_s': ParameterValue(
                    rtt_warn_log_period_s, value_type=float),
            }],
            arguments=['--ros-args', '--log-level', log_level],
        ),
    ])
