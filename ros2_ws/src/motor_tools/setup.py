from setuptools import find_packages, setup

package_name = 'motor_tools'

setup(
    name=package_name,
    version='0.1.0',
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
    description='M0 PC-side motor bring-up helpers.',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'motor_cybergear_probe = motor_tools.motor_cybergear_probe:main',
            'motor_cybergear_benchtop = motor_tools.motor_cybergear_benchtop:main',
        ],
    },
)
