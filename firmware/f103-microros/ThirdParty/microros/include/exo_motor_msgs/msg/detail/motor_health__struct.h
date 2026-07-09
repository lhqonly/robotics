// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_motor_msgs:msg/MotorHealth.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_motor_msgs/msg/motor_health.h"


#ifndef EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__STRUCT_H_
#define EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__STRUCT_H_

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Constants defined in the message

// Include directives for member types
// Member 'header'
#include "std_msgs/msg/detail/header__struct.h"

/// Struct defined in msg/MotorHealth in the package exo_motor_msgs.
/**
  * Bus-level health counters on /motor/tp_motor_health.
 */
typedef struct exo_motor_msgs__msg__MotorHealth
{
  std_msgs__msg__Header header;
  uint8_t bus_id;
  uint8_t joint_count;
  uint64_t targets_received;
  uint64_t targets_applied;
  uint64_t stale_targets;
  uint64_t motor_tx;
  uint64_t motor_rx;
  uint64_t motor_timeout;
  uint64_t motor_fault;
  double target_apply_latency_p99_ms;
  double can_gap_p99_ms;
  bool reconciles;
} exo_motor_msgs__msg__MotorHealth;

// Struct for a sequence of exo_motor_msgs__msg__MotorHealth.
typedef struct exo_motor_msgs__msg__MotorHealth__Sequence
{
  exo_motor_msgs__msg__MotorHealth * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_motor_msgs__msg__MotorHealth__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__STRUCT_H_
