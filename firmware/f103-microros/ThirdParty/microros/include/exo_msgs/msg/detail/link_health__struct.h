// NOLINT: This file starts with a BOM since it contain non-ASCII characters
// generated from rosidl_generator_c/resource/idl__struct.h.em
// with input from exo_msgs:msg/LinkHealth.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_msgs/msg/link_health.h"


#ifndef EXO_MSGS__MSG__DETAIL__LINK_HEALTH__STRUCT_H_
#define EXO_MSGS__MSG__DETAIL__LINK_HEALTH__STRUCT_H_

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

/// Struct defined in msg/LinkHealth in the package exo_msgs.
typedef struct exo_msgs__msg__LinkHealth
{
  /// 标准 Header（wall-clock stamp）：诊断/bag 时间轴，不参与 §7.1 RTT
  std_msgs__msg__Header header;
  uint64_t sent;
  uint64_t matched;
  uint64_t lost;
  uint64_t duplicate;
  uint64_t stale_duplicate;
  /// 应用级 CRC 自检失配累计（§7.9）：crc_enabled=False 时恒 0；旁路观测量，不入 reconciles 对账等式
  uint64_t crc_mismatch;
  uint32_t inflight;
  double rtt_last_ms;
  double rtt_p95_ms;
  double rtt_max_ms;
  /// sent==matched+lost+inflight，一眼看链路是否在悄悄掉东西
  bool reconciles;
} exo_msgs__msg__LinkHealth;

// Struct for a sequence of exo_msgs__msg__LinkHealth.
typedef struct exo_msgs__msg__LinkHealth__Sequence
{
  exo_msgs__msg__LinkHealth * data;
  /// The number of valid items in data
  size_t size;
  /// The number of allocated items in data
  size_t capacity;
} exo_msgs__msg__LinkHealth__Sequence;

#ifdef __cplusplus
}
#endif

#endif  // EXO_MSGS__MSG__DETAIL__LINK_HEALTH__STRUCT_H_
