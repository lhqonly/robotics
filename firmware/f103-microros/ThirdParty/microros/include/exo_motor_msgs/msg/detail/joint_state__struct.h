// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_motor_msgs:msg/JointState.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_motor_msgs/msg/joint_state.h"


#ifndef EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_STATE__STRUCT_H_
#define EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_STATE__STRUCT_H_

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
  exo_motor_msgs__msg__JointState__CONTROL_MODE_DISABLED = 0
};

/// Constant 'CONTROL_MODE_ZERO_TORQUE'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_ZERO_TORQUE = 1
};

/// Constant 'CONTROL_MODE_TORQUE'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_TORQUE = 2
};

/// Constant 'CONTROL_MODE_VELOCITY'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_VELOCITY = 3
};

/// Constant 'CONTROL_MODE_POSITION'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_POSITION = 4
};

/// Constant 'CONTROL_MODE_IMPEDANCE'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_IMPEDANCE = 5
};

/// Constant 'CONTROL_MODE_TRAJECTORY'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_TRAJECTORY = 6
};

/// Constant 'CONTROL_MODE_CALIBRATION'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_CALIBRATION = 7
};

/// Constant 'CONTROL_MODE_RAW_VENDOR'.
enum
{
  exo_motor_msgs__msg__JointState__CONTROL_MODE_RAW_VENDOR = 8
};

// Include directives for member types
// Member 'header'
#include "std_msgs/msg/detail/header__struct.h"

/// Struct defined in msg/JointState in the package exo_motor_msgs.
/**
  * Measured or estimated state for one logical joint on /motor/tp_joint_state.
  *
  * Control mode values mirror JointTarget:
  * DISABLED=0, ZERO_TORQUE=1, TORQUE=2, VELOCITY=3, POSITION=4, IMPEDANCE=5,
  * TRAJECTORY=6, CALIBRATION=7, RAW_VENDOR=8.
 */
typedef struct exo_motor_msgs__msg__JointState
{
  std_msgs__msg__Header header;
  uint32_t seq;
  uint8_t joint_id;
  uint8_t control_mode;
  double position_rad;
  double velocity_rad_s;
  double torque_est_nm;
  double current_a;
  double bus_voltage_v;
  double temperature_c;
  uint32_t fault_bits;
  uint32_t vendor_fault_bits;
  uint32_t last_target_seq;
  uint32_t sample_age_us;
  bool target_fresh;
  bool enabled;
} exo_motor_msgs__msg__JointState;

// Struct for a sequence of exo_motor_msgs__msg__JointState.
typedef struct exo_motor_msgs__msg__JointState__Sequence
{
  exo_motor_msgs__msg__JointState * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_motor_msgs__msg__JointState__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MOTOR_MSGS__MSG__DETAIL__JOINT_STATE__STRUCT_H_
