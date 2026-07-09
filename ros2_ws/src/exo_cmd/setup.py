from setuptools import find_packages, setup

package_name = 'exo_cmd'

setup(
    name=package_name,
    version='1.7.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Tom',
    maintainer_email='lhqonly@users.noreply.github.com',
    description='WSL-side pub/sub nodes for the exoskeleton serial loopback.',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            # WSL command node: pub /com/tp_cmd_heartbeat, sub /com/tp_mcu_status
            'exo_cmd_node = exo_cmd.exo_cmd_node:main',
            # Local MCU simulator: sub /com/tp_cmd_heartbeat -> pub /com/tp_mcu_status
            'loopback_node = exo_cmd.loopback_node:main',
            # Hardware perf helper: direct rclpy sampler for /com/tp_mcu_status
            'status_sampler = exo_cmd.status_sampler:main',
        ],
    },
)
