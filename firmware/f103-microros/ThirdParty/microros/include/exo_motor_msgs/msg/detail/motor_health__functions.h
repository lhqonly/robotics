// generated from rosidl_generator_c/resource/idl__functions.h.em
// with input from exo_motor_msgs:msg/MotorHealth.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_motor_msgs/msg/motor_health.h"


#ifndef EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__FUNCTIONS_H_
#define EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__FUNCTIONS_H_

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdbool.h>
#include <stdlib.h>

#include "rosidl_runtime_c/action_type_support_struct.h"
#include "rosidl_runtime_c/message_type_support_struct.h"
#include "rosidl_runtime_c/service_type_support_struct.h"
#include "rosidl_runtime_c/type_description/type_description__struct.h"
#include "rosidl_runtime_c/type_description/type_source__struct.h"
#include "rosidl_runtime_c/type_hash.h"
#include "rosidl_runtime_c/visibility_control.h"
#include "exo_motor_msgs/msg/rosidl_generator_c__visibility_control.h"

#include "exo_motor_msgs/msg/detail/motor_health__struct.h"

/// Initialize msg/MotorHealth message.
/**
 * If the init function is called twice for the same message without
 * calling fini inbetween previously allocated memory will be leaked.
 * \param[in,out] msg The previously allocated message pointer.
 * Fields without a default value will not be initialized by this function.
 * You might want to call memset(msg, 0, sizeof(
 * exo_motor_msgs__msg__MotorHealth
 * )) before or use
 * exo_motor_msgs__msg__MotorHealth__create()
 * to allocate and initialize the message.
 * \return true if initialization was successful, otherwise false
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__init(exo_motor_msgs__msg__MotorHealth * msg);

/// Finalize msg/MotorHealth message.
/**
 * \param[in,out] msg The allocated message pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
void
exo_motor_msgs__msg__MotorHealth__fini(exo_motor_msgs__msg__MotorHealth * msg);

/// Create msg/MotorHealth message.
/**
 * It allocates the memory for the message, sets the memory to zero, and
 * calls
 * exo_motor_msgs__msg__MotorHealth__init().
 * \return The pointer to the initialized message if successful,
 * otherwise NULL
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
exo_motor_msgs__msg__MotorHealth *
exo_motor_msgs__msg__MotorHealth__create(void);

/// Destroy msg/MotorHealth message.
/**
 * It calls
 * exo_motor_msgs__msg__MotorHealth__fini()
 * and frees the memory of the message.
 * \param[in,out] msg The allocated message pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
void
exo_motor_msgs__msg__MotorHealth__destroy(exo_motor_msgs__msg__MotorHealth * msg);

/// Check for msg/MotorHealth message equality.
/**
 * \param[in] lhs The message on the left hand size of the equality operator.
 * \param[in] rhs The message on the right hand size of the equality operator.
 * \return true if messages are equal, otherwise false.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__are_equal(const exo_motor_msgs__msg__MotorHealth * lhs, const exo_motor_msgs__msg__MotorHealth * rhs);

/// Copy a msg/MotorHealth message.
/**
 * This functions performs a deep copy, as opposed to the shallow copy that
 * plain assignment yields.
 *
 * \param[in] input The source message pointer.
 * \param[out] output The target message pointer, which must
 *   have been initialized before calling this function.
 * \return true if successful, or false if either pointer is null
 *   or memory allocation fails.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__copy(
  const exo_motor_msgs__msg__MotorHealth * input,
  exo_motor_msgs__msg__MotorHealth * output);

/// Retrieve pointer to the hash of the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
const rosidl_type_hash_t *
exo_motor_msgs__msg__MotorHealth__get_type_hash(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
const rosidl_runtime_c__type_description__TypeDescription *
exo_motor_msgs__msg__MotorHealth__get_type_description(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the single raw source text that defined this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
const rosidl_runtime_c__type_description__TypeSource *
exo_motor_msgs__msg__MotorHealth__get_individual_type_description_source(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the recursive raw sources that defined the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
const rosidl_runtime_c__type_description__TypeSource__Sequence *
exo_motor_msgs__msg__MotorHealth__get_type_description_sources(
  const rosidl_message_type_support_t * type_support);

/// Initialize array of msg/MotorHealth messages.
/**
 * It allocates the memory for the number of elements and calls
 * exo_motor_msgs__msg__MotorHealth__init()
 * for each element of the array.
 * \param[in,out] array The allocated array pointer.
 * \param[in] size The size / capacity of the array.
 * \return true if initialization was successful, otherwise false
 * If the array pointer is valid and the size is zero it is guaranteed
 # to return true.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__Sequence__init(exo_motor_msgs__msg__MotorHealth__Sequence * array, size_t size);

/// Finalize array of msg/MotorHealth messages.
/**
 * It calls
 * exo_motor_msgs__msg__MotorHealth__fini()
 * for each element of the array and frees the memory for the number of
 * elements.
 * \param[in,out] array The initialized array pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
void
exo_motor_msgs__msg__MotorHealth__Sequence__fini(exo_motor_msgs__msg__MotorHealth__Sequence * array);

/// Create array of msg/MotorHealth messages.
/**
 * It allocates the memory for the array and calls
 * exo_motor_msgs__msg__MotorHealth__Sequence__init().
 * \param[in] size The size / capacity of the array.
 * \return The pointer to the initialized array if successful, otherwise NULL
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
exo_motor_msgs__msg__MotorHealth__Sequence *
exo_motor_msgs__msg__MotorHealth__Sequence__create(size_t size);

/// Destroy array of msg/MotorHealth messages.
/**
 * It calls
 * exo_motor_msgs__msg__MotorHealth__Sequence__fini()
 * on the array,
 * and frees the memory of the array.
 * \param[in,out] array The initialized array pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
void
exo_motor_msgs__msg__MotorHealth__Sequence__destroy(exo_motor_msgs__msg__MotorHealth__Sequence * array);

/// Check for msg/MotorHealth message array equality.
/**
 * \param[in] lhs The message array on the left hand size of the equality operator.
 * \param[in] rhs The message array on the right hand size of the equality operator.
 * \return true if message arrays are equal in size and content, otherwise false.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__Sequence__are_equal(const exo_motor_msgs__msg__MotorHealth__Sequence * lhs, const exo_motor_msgs__msg__MotorHealth__Sequence * rhs);

/// Copy an array of msg/MotorHealth messages.
/**
 * This functions performs a deep copy, as opposed to the shallow copy that
 * plain assignment yields.
 *
 * \param[in] input The source array pointer.
 * \param[out] output The target array pointer, which must
 *   have been initialized before calling this function.
 * \return true if successful, or false if either pointer
 *   is null or memory allocation fails.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_motor_msgs
bool
exo_motor_msgs__msg__MotorHealth__Sequence__copy(
  const exo_motor_msgs__msg__MotorHealth__Sequence * input,
  exo_motor_msgs__msg__MotorHealth__Sequence * output);

#ifdef __cplusplus
}
#endif

#endif  // EXO_MOTOR_MSGS__MSG__DETAIL__MOTOR_HEALTH__FUNCTIONS_H_
