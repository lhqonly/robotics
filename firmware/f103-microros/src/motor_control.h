/* motor_control.h — MCU-side motor target cache and safety core (M2)
 *
 * This module is intentionally independent from micro-ROS and any vendor CAN
 * driver. ROS callbacks convert JointTarget messages into this fixed-point
 * contract, and the 1kHz-10kHz control tick consumes only the latest target.
 */
#ifndef MOTOR_CONTROL_H
#define MOTOR_CONTROL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MOTOR_CONTROL_MODE_DISABLED = 0,
    MOTOR_CONTROL_MODE_ZERO_TORQUE = 1,
    MOTOR_CONTROL_MODE_TORQUE = 2,
    MOTOR_CONTROL_MODE_VELOCITY = 3,
    MOTOR_CONTROL_MODE_POSITION = 4,
    MOTOR_CONTROL_MODE_IMPEDANCE = 5,
    MOTOR_CONTROL_MODE_TRAJECTORY = 6,
    MOTOR_CONTROL_MODE_CALIBRATION = 7,
    MOTOR_CONTROL_MODE_RAW_VENDOR = 8,
};

enum {
    MOTOR_FAULT_NONE = 0u,
    MOTOR_FAULT_NO_TARGET = 1u << 0,
    MOTOR_FAULT_STALE_TARGET = 1u << 1,
    MOTOR_FAULT_LIMIT_CLAMPED = 1u << 2,
    MOTOR_FAULT_INVALID_MODE = 1u << 3,
};

typedef struct {
    uint32_t seq;
    uint8_t joint_id;
    uint8_t control_mode;
    int32_t position_mrad;
    int32_t velocity_mrad_s;
    int32_t torque_mnm;
    int32_t kp_mnm_per_rad;
    int32_t kd_mnm_s_per_rad;
    int32_t max_torque_mnm;
    int32_t max_velocity_mrad_s;
    int32_t max_position_mrad;
    int32_t min_position_mrad;
    uint32_t ttl_us;
    uint32_t flags;
} motor_control_target_t;

typedef struct {
    uint32_t seq;
    uint32_t last_target_seq;
    uint8_t joint_id;
    uint8_t control_mode;
    int32_t position_mrad;
    int32_t velocity_mrad_s;
    int32_t torque_mnm;
    uint32_t sample_age_us;
    uint32_t fault_bits;
    bool target_fresh;
    bool enabled;
} motor_control_state_t;

typedef struct {
    uint64_t control_ticks;
    uint64_t targets_received;
    uint64_t targets_applied;
    uint64_t stale_ticks;
    uint64_t clamped_ticks;
    uint64_t invalid_mode_ticks;
    bool reconciles;
} motor_control_health_t;

void motor_control_init(void);
void motor_control_submit_target(const motor_control_target_t *target);
void motor_control_tick(void);
void motor_control_get_state(motor_control_state_t *out);
void motor_control_get_health(motor_control_health_t *out);

uint32_t motor_control_tick_count(void);
uint32_t motor_control_latest_seq(void);

#ifdef __cplusplus
}
#endif

#endif /* MOTOR_CONTROL_H */
