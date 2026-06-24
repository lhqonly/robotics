// generated from rosidl_generator_c/resource/idl__functions.h.em
// with input from exo_msgs:msg/ExoCmd.idl
// generated code does not contain a copyright notice

// IWYU pragma: private, include "exo_msgs/msg/exo_cmd.h"


#ifndef EXO_MSGS__MSG__DETAIL__EXO_CMD__FUNCTIONS_H_
#define EXO_MSGS__MSG__DETAIL__EXO_CMD__FUNCTIONS_H_

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
#include "exo_msgs/msg/rosidl_generator_c__visibility_control.h"

#include "exo_msgs/msg/detail/exo_cmd__struct.h"

/// Initialize msg/ExoCmd message.
/**
 * If the init function is called twice for the same message without
 * calling fini inbetween previously allocated memory will be leaked.
 * \param[in,out] msg The previously allocated message pointer.
 * Fields without a default value will not be initialized by this function.
 * You might want to call memset(msg, 0, sizeof(
 * exo_msgs__msg__ExoCmd
 * )) before or use
 * exo_msgs__msg__ExoCmd__create()
 * to allocate and initialize the message.
 * \return true if initialization was successful, otherwise false
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__init(exo_msgs__msg__ExoCmd * msg);

/// Finalize msg/ExoCmd message.
/**
 * \param[in,out] msg The allocated message pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
void
exo_msgs__msg__ExoCmd__fini(exo_msgs__msg__ExoCmd * msg);

/// Create msg/ExoCmd message.
/**
 * It allocates the memory for the message, sets the memory to zero, and
 * calls
 * exo_msgs__msg__ExoCmd__init().
 * \return The pointer to the initialized message if successful,
 * otherwise NULL
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
exo_msgs__msg__ExoCmd *
exo_msgs__msg__ExoCmd__create(void);

/// Destroy msg/ExoCmd message.
/**
 * It calls
 * exo_msgs__msg__ExoCmd__fini()
 * and frees the memory of the message.
 * \param[in,out] msg The allocated message pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
void
exo_msgs__msg__ExoCmd__destroy(exo_msgs__msg__ExoCmd * msg);

/// Check for msg/ExoCmd message equality.
/**
 * \param[in] lhs The message on the left hand size of the equality operator.
 * \param[in] rhs The message on the right hand size of the equality operator.
 * \return true if messages are equal, otherwise false.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__are_equal(const exo_msgs__msg__ExoCmd * lhs, const exo_msgs__msg__ExoCmd * rhs);

/// Copy a msg/ExoCmd message.
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
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__copy(
  const exo_msgs__msg__ExoCmd * input,
  exo_msgs__msg__ExoCmd * output);

/// Retrieve pointer to the hash of the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
const rosidl_type_hash_t *
exo_msgs__msg__ExoCmd__get_type_hash(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
const rosidl_runtime_c__type_description__TypeDescription *
exo_msgs__msg__ExoCmd__get_type_description(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the single raw source text that defined this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
const rosidl_runtime_c__type_description__TypeSource *
exo_msgs__msg__ExoCmd__get_individual_type_description_source(
  const rosidl_message_type_support_t * type_support);

/// Retrieve pointer to the recursive raw sources that defined the description of this type.
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
const rosidl_runtime_c__type_description__TypeSource__Sequence *
exo_msgs__msg__ExoCmd__get_type_description_sources(
  const rosidl_message_type_support_t * type_support);

/// Initialize array of msg/ExoCmd messages.
/**
 * It allocates the memory for the number of elements and calls
 * exo_msgs__msg__ExoCmd__init()
 * for each element of the array.
 * \param[in,out] array The allocated array pointer.
 * \param[in] size The size / capacity of the array.
 * \return true if initialization was successful, otherwise false
 * If the array pointer is valid and the size is zero it is guaranteed
 # to return true.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__Sequence__init(exo_msgs__msg__ExoCmd__Sequence * array, size_t size);

/// Finalize array of msg/ExoCmd messages.
/**
 * It calls
 * exo_msgs__msg__ExoCmd__fini()
 * for each element of the array and frees the memory for the number of
 * elements.
 * \param[in,out] array The initialized array pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
void
exo_msgs__msg__ExoCmd__Sequence__fini(exo_msgs__msg__ExoCmd__Sequence * array);

/// Create array of msg/ExoCmd messages.
/**
 * It allocates the memory for the array and calls
 * exo_msgs__msg__ExoCmd__Sequence__init().
 * \param[in] size The size / capacity of the array.
 * \return The pointer to the initialized array if successful, otherwise NULL
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
exo_msgs__msg__ExoCmd__Sequence *
exo_msgs__msg__ExoCmd__Sequence__create(size_t size);

/// Destroy array of msg/ExoCmd messages.
/**
 * It calls
 * exo_msgs__msg__ExoCmd__Sequence__fini()
 * on the array,
 * and frees the memory of the array.
 * \param[in,out] array The initialized array pointer.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
void
exo_msgs__msg__ExoCmd__Sequence__destroy(exo_msgs__msg__ExoCmd__Sequence * array);

/// Check for msg/ExoCmd message array equality.
/**
 * \param[in] lhs The message array on the left hand size of the equality operator.
 * \param[in] rhs The message array on the right hand size of the equality operator.
 * \return true if message arrays are equal in size and content, otherwise false.
 */
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__Sequence__are_equal(const exo_msgs__msg__ExoCmd__Sequence * lhs, const exo_msgs__msg__ExoCmd__Sequence * rhs);

/// Copy an array of msg/ExoCmd messages.
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
ROSIDL_GENERATOR_C_PUBLIC_exo_msgs
bool
exo_msgs__msg__ExoCmd__Sequence__copy(
  const exo_msgs__msg__ExoCmd__Sequence * input,
  exo_msgs__msg__ExoCmd__Sequence * output);

#ifdef __cplusplus
}
#endif

#endif  // EXO_MSGS__MSG__DETAIL__EXO_CMD__FUNCTIONS_H_
