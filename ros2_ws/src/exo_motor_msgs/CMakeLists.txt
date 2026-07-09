cmake_minimum_required(VERSION 3.8)
project(exo_motor_msgs)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/JointTarget.msg"
  "msg/JointState.msg"
  "msg/MotorHealth.msg"
  "srv/EnableJoint.srv"
  "srv/DisableJoint.srv"
  "srv/ClearMotorFault.srv"
  "srv/SetJointZero.srv"
  "srv/SetJointMode.srv"
  "srv/GetMotorParam.srv"
  "srv/SetMotorParam.srv"
  DEPENDENCIES std_msgs
)

ament_export_dependencies(rosidl_default_runtime)

ament_package()
