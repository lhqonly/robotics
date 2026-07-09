// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_motor_msgs:msg/JointTarget.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_motor_msgs/msg/joint_target.h"


#ifndef EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_TARGET__STRUCT_H_
#define EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_TARGET__STRUCT_H_

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Constants defined in the message

/// Constant 'CONTROL_MODE_DISABLED'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_DISABLED = 0
};

/// Constant 'CONTROL_MODE_ZERO_TORQUE'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_ZERO_TORQUE = 1
};

/// Constant 'CONTROL_MODE_TORQUE'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_TORQUE = 2
};

/// Constant 'CONTROL_MODE_VELOCITY'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_VELOCITY = 3
};

/// Constant 'CONTROL_MODE_POSITION'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_POSITION = 4
};

/// Constant 'CONTROL_MODE_IMPEDANCE'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_IMPEDANCE = 5
};

/// Constant 'CONTROL_MODE_TRAJECTORY'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_TRAJECTORY = 6
};

/// Constant 'CONTROL_MODE_CALIBRATION'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_CALIBRATION = 7
};

/// Constant 'CONTROL_MODE_RAW_VENDOR'.
enum
{
  exo_motor_msgs__msg__JointTarget__CONTROL_MODE_RAW_VENDOR = 8
};

// Include directives for member types
// Member 'header'
#include "std_msgs/msg/detail/header__struct.h"

/// Struct defined in msg/JointTarget in the package exo_motor_msgs.
/**
  * Target command for one logical joint on /motor/tp_joint_target.
  *
  * Control mode values:
  * DISABLED=0: joint output disabled.
  * ZERO_TORQUE=1: enabled but torque command is zero.
  * TORQUE=2: torque_nm is the primary command.
  * VELOCITY=3: velocity_rad_s is the primary command.
  * POSITION=4: position_rad is the primary command.
  * IMPEDANCE=5: position, velocity, kp, kd, and feed-forward torque are used.
  * TRAJECTORY=6: target is one point in a trajectory stream.
  * CALIBRATION=7: calibration or homing behavior.
  * RAW_VENDOR=8: reserved escape hatch; public fields still stay normalized.
 */
typedef struct exo_motor_msgs__msg__JointTarget
{
  std_msgs__msg__Header header;
  uint32_t seq;
  uint8_t joint_id;
  uint8_t control_mode;
  double position_rad;
  double velocity_rad_s;
  double torque_nm;
  double kp_nm_per_rad;
  double kd_nm_s_per_rad;
  double max_torque_nm;
  double max_velocity_rad_s;
  double max_position_rad;
  double min_position_rad;
  uint32_t ttl_us;
  uint32_t flags;
} exo_motor_msgs__msg__JointTarget;

// Struct for a sequence of exo_motor_msgs__msg__JointTarget.
typedef struct exo_motor_msgs__msg__JointTarget__Sequence
{
  exo_motor_msgs__msg__JointTarget * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_motor_msgs__msg__JointTarget__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_TARGET__STRUCT_H_
