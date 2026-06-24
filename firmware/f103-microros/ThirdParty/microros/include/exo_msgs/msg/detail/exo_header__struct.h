// NOLINT: This file starts with a BOM since it contain non-ASCII characters
// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_msgs:msg/ExoHeader.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_msgs/msg/exo_header.h"


#ifndef EXO_MSGS__MSG__DETAIL__EXO_HEADER__STRUCT_H_
#define EXO_MSGS__MSG__DETAIL__EXO_HEADER__STRUCT_H_

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Constants defined in the message

/// Struct defined in msg/ExoHeader in the package exo_msgs.
typedef struct exo_msgs__msg__ExoHeader
{
  /// §7.6 序列号，mod 2^32 回绕；回环用精确相等配对
  uint32_t seq;
  /// 发送方单调时钟纳秒（§7.1：禁 wall clock）；仅同发送方内可比
  uint64_t stamp_mono_ns;
  /// 应用级 CRC（默认 0 / 默认不强校验，开发期可开，抓打包 bug）
  uint32_t crc;
} exo_msgs__msg__ExoHeader;

// Struct for a sequence of exo_msgs__msg__ExoHeader.
typedef struct exo_msgs__msg__ExoHeader__Sequence
{
  exo_msgs__msg__ExoHeader * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_msgs__msg__ExoHeader__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MSGS__MSG__DETAIL__EXO_HEADER__STRUCT_H_
