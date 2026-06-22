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
            # WSL command node: pub /exo/cmd_heartbeat, sub /exo/mcu_status
            'exo_cmd_node = exo_cmd.exo_cmd_node:main',
            # Local MCU simulator: sub /exo/cmd_heartbeat -> pub /exo/mcu_status
            'loopback_node = exo_cmd.loopback_node:main',
        ],
    },
)
