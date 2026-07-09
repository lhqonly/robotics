/* motor_control.c — latest target, TTL, clamp, and safe-state core (M2) */

#include "motor_control.h"

#include <stddef.h>

#ifndef EXO_CONTROL_LOOP_HZ
#  define EXO_CONTROL_LOOP_HZ 1000u
#endif

#ifndef EXO_MOTOR_MAX_ABS_POSITION_MRAD
#  define EXO_MOTOR_MAX_ABS_POSITION_MRAD 500
#endif

#ifndef EXO_MOTOR_MAX_ABS_VELOCITY_MRAD_S
#  define EXO_MOTOR_MAX_ABS_VELOCITY_MRAD_S 500
#endif

#ifndef EXO_MOTOR_MAX_ABS_TORQUE_MNM
#  define EXO_MOTOR_MAX_ABS_TORQUE_MNM 500
#endif

#ifndef EXO_MOTOR_MAX_TARGET_TTL_US
#  define EXO_MOTOR_MAX_TARGET_TTL_US 100000u
#endif

#if EXO_CONTROL_LOOP_HZ < 1u
#  error "EXO_CONTROL_LOOP_HZ must be >= 1"
#endif

static volatile motor_control_target_t g_targets[2];
static volatile uint32_t g_target_active;
static volatile uint32_t g_target_age_us;
static volatile bool g_has_target;

static volatile motor_control_state_t g_state;
static volatile motor_control_health_t g_health;

static int32_t clamp_i32(int32_t value, int32_t low, int32_t high, bool *clamped)
{
    if (value < low) {
        *clamped = true;
        return low;
    }
    if (value > high) {
        *clamped = true;
        return high;
    }
    return value;
}

static int32_t abs_limit_from_target(int32_t requested, int32_t hard_limit)
{
    if (requested <= 0 || requested > hard_limit) {
        return hard_limit;
    }
    return requested;
}

static uint32_t effective_ttl_us(uint32_t requested)
{
    if (requested == 0u) {
        return 0u;
    }
    if (requested > EXO_MOTOR_MAX_TARGET_TTL_US) {
        return EXO_MOTOR_MAX_TARGET_TTL_US;
    }
    return requested;
}

static bool mode_can_enable(uint8_t mode)
{
    return mode == MOTOR_CONTROL_MODE_ZERO_TORQUE ||
           mode == MOTOR_CONTROL_MODE_TORQUE ||
           mode == MOTOR_CONTROL_MODE_VELOCITY ||
           mode == MOTOR_CONTROL_MODE_POSITION ||
           mode == MOTOR_CONTROL_MODE_IMPEDANCE ||
           mode == MOTOR_CONTROL_MODE_TRAJECTORY ||
           mode == MOTOR_CONTROL_MODE_CALIBRATION;
}

static bool mode_is_valid(uint8_t mode)
{
    return mode <= MOTOR_CONTROL_MODE_RAW_VENDOR;
}

static uint32_t control_period_us(void)
{
    return (1000000u + EXO_CONTROL_LOOP_HZ - 1u) / EXO_CONTROL_LOOP_HZ;
}

static void publish_safe_state(uint32_t fault_bits)
{
    g_state.seq++;
    g_state.control_mode = MOTOR_CONTROL_MODE_DISABLED;
    g_state.position_mrad = 0;
    g_state.velocity_mrad_s = 0;
    g_state.torque_mnm = 0;
    g_state.fault_bits = fault_bits;
    g_state.target_fresh = false;
    g_state.enabled = false;
}

void motor_control_init(void)
{
    g_target_active = 0u;
    g_target_age_us = 0u;
    g_has_target = false;

    g_state.seq = 0u;
    g_state.last_target_seq = 0u;
    g_state.joint_id = 0u;
    g_state.control_mode = MOTOR_CONTROL_MODE_DISABLED;
    g_state.position_mrad = 0;
    g_state.velocity_mrad_s = 0;
    g_state.torque_mnm = 0;
    g_state.sample_age_us = 0u;
    g_state.fault_bits = MOTOR_FAULT_NO_TARGET;
    g_state.target_fresh = false;
    g_state.enabled = false;

    g_health.control_ticks = 0u;
    g_health.targets_received = 0u;
    g_health.targets_applied = 0u;
    g_health.stale_ticks = 0u;
    g_health.clamped_ticks = 0u;
    g_health.invalid_mode_ticks = 0u;
    g_health.reconciles = true;
}

void motor_control_submit_target(const motor_control_target_t *target)
{
    if (target == NULL) {
        return;
    }

    uint32_t next = (g_target_active ^ 1u) & 1u;
    g_targets[next] = *target;
    __asm volatile ("" ::: "memory");
    g_target_age_us = 0u;
    g_target_active = next;
    g_has_target = true;
    g_health.targets_received++;
}

void motor_control_tick(void)
{
    g_health.control_ticks++;

    if (!g_has_target) {
        g_state.sample_age_us = 0u;
        publish_safe_state(MOTOR_FAULT_NO_TARGET);
        g_health.reconciles = g_health.targets_applied <= g_health.targets_received;
        return;
    }

    uint32_t active = g_target_active & 1u;
    motor_control_target_t target = g_targets[active];
    uint32_t age = g_target_age_us;
    uint32_t period = control_period_us();
    if (UINT32_MAX - age > period) {
        g_target_age_us = age + period;
    } else {
        g_target_age_us = UINT32_MAX;
    }

    g_state.last_target_seq = target.seq;
    g_state.joint_id = target.joint_id;
    g_state.sample_age_us = age;

    uint32_t ttl = effective_ttl_us(target.ttl_us);
    if (ttl == 0u || age > ttl) {
        g_health.stale_ticks++;
        publish_safe_state(MOTOR_FAULT_STALE_TARGET);
        g_health.reconciles = g_health.targets_applied <= g_health.targets_received;
        return;
    }

    uint32_t faults = MOTOR_FAULT_NONE;
    if (!mode_is_valid(target.control_mode)) {
        faults |= MOTOR_FAULT_INVALID_MODE;
        g_health.invalid_mode_ticks++;
        publish_safe_state(faults);
        g_health.reconciles = g_health.targets_applied <= g_health.targets_received;
        return;
    }

    bool clamped = false;
    int32_t abs_pos = EXO_MOTOR_MAX_ABS_POSITION_MRAD;
    int32_t abs_vel = abs_limit_from_target(
        target.max_velocity_mrad_s, EXO_MOTOR_MAX_ABS_VELOCITY_MRAD_S);
    int32_t abs_torque = abs_limit_from_target(
        target.max_torque_mnm, EXO_MOTOR_MAX_ABS_TORQUE_MNM);

    int32_t min_pos = -abs_pos;
    int32_t max_pos = abs_pos;
    if (target.min_position_mrad <= target.max_position_mrad) {
        min_pos = clamp_i32(target.min_position_mrad, -abs_pos, abs_pos, &clamped);
        max_pos = clamp_i32(target.max_position_mrad, -abs_pos, abs_pos, &clamped);
        if (min_pos > max_pos) {
            int32_t tmp = min_pos;
            min_pos = max_pos;
            max_pos = tmp;
            clamped = true;
        }
    }

    int32_t position = clamp_i32(target.position_mrad, min_pos, max_pos, &clamped);
    int32_t velocity = clamp_i32(target.velocity_mrad_s, -abs_vel, abs_vel, &clamped);
    int32_t torque = clamp_i32(target.torque_mnm, -abs_torque, abs_torque, &clamped);

    if (clamped) {
        faults |= MOTOR_FAULT_LIMIT_CLAMPED;
        g_health.clamped_ticks++;
    }

    g_state.seq++;
    g_state.control_mode = target.control_mode;
    g_state.position_mrad = position;
    g_state.velocity_mrad_s = velocity;
    g_state.torque_mnm = torque;
    g_state.fault_bits = faults;
    g_state.target_fresh = true;
    g_state.enabled = mode_can_enable(target.control_mode);

    if (g_state.enabled) {
        g_health.targets_applied++;
    }
    g_health.reconciles = g_health.targets_applied <= g_health.control_ticks;
}

void motor_control_get_state(motor_control_state_t *out)
{
    if (out != NULL) {
        *out = g_state;
    }
}

void motor_control_get_health(motor_control_health_t *out)
{
    if (out != NULL) {
        *out = g_health;
    }
}

uint32_t motor_control_tick_count(void)
{
    return (uint32_t)g_health.control_ticks;
}

uint32_t motor_control_latest_seq(void)
{
    return g_state.last_target_seq;
}
