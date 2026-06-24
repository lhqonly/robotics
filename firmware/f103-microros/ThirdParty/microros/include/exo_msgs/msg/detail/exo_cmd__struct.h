// NOLINT: This file starts with a BOM since it contain non-ASCII characters
// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_msgs:msg/ExoCmd.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_msgs/msg/exo_cmd.h"


#ifndef EXO_MSGS__MSG__DETAIL__EXO_CMD__STRUCT_H_
#define EXO_MSGS__MSG__DETAIL__EXO_CMD__STRUCT_H_

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
#include "exo_msgs/msg/detail/exo_header__struct.h"

/// Struct defined in msg/ExoCmd in the package exo_msgs.
typedef struct exo_msgs__msg__ExoCmd
{
  exo_msgs__msg__ExoHeader header;
  /// 本阶段=心跳/回环值（与 header.seq 解耦）
  int32_t payload;
} exo_msgs__msg__ExoCmd;

// Struct for a sequence of exo_msgs__msg__ExoCmd.
typedef struct exo_msgs__msg__ExoCmd__Sequence
{
  exo_msgs__msg__ExoCmd * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_msgs__msg__ExoCmd__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MSGS__MSG__DETAIL__EXO_CMD__STRUCT_H_
