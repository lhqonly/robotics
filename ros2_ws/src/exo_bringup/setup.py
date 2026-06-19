import os
from glob import glob

from setuptools import find_packages, setup

package_name = 'exo_bringup'

setup(
    name=package_name,
    version='1.0.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        # Install all launch files under share/<pkg>/launch.
        (os.path.join('share', package_name, 'launch'),
            glob('launch/*.launch.py')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Tom',
    maintainer_email='lhqonly@users.noreply.github.com',
    description='Launch files for the exoskeleton serial loopback.',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [],
    },
)
