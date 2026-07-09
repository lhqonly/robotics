#include "motor_control.h"

#include <assert.h>
#include <stdbool.h>

static motor_control_target_t base_target(void)
{
    motor_control_target_t target = {0};
    target.seq = 42u;
    target.joint_id = 1u;
    target.control_mode = MOTOR_CONTROL_MODE_POSITION;
    target.position_mrad = 120;
    target.velocity_mrad_s = 30;
    target.torque_mnm = 10;
    target.max_torque_mnm = 500;
    target.max_velocity_mrad_s = 500;
    target.max_position_mrad = 500;
    target.min_position_mrad = -500;
    target.ttl_us = 10000u;
    return target;
}

static void assert_fresh_target_is_applied(void)
{
    motor_control_init();
    motor_control_target_t target = base_target();
    motor_control_submit_target(&target);
    motor_control_tick();

    motor_control_state_t state;
    motor_control_health_t health;
    motor_control_get_state(&state);
    motor_control_get_health(&health);

    assert(state.last_target_seq == 42u);
    assert(state.joint_id == 1u);
    assert(state.target_fresh == true);
    assert(state.enabled == true);
    assert(state.position_mrad == 120);
    assert((state.fault_bits & MOTOR_FAULT_STALE_TARGET) == 0u);
    assert(health.targets_received == 1u);
    assert(health.targets_applied == 1u);
}

static void assert_limits_are_clamped(void)
{
    motor_control_init();
    motor_control_target_t target = base_target();
    target.seq = 43u;
    target.position_mrad = 2000;
    target.velocity_mrad_s = -2000;
    target.torque_mnm = 2000;
    target.max_torque_mnm = 100;
    target.max_velocity_mrad_s = 100;
    target.max_position_mrad = 100;
    target.min_position_mrad = -100;

    motor_control_submit_target(&target);
    motor_control_tick();

    motor_control_state_t state;
    motor_control_health_t health;
    motor_control_get_state(&state);
    motor_control_get_health(&health);

    assert(state.position_mrad == 100);
    assert(state.velocity_mrad_s == -100);
    assert(state.torque_mnm == 100);
    assert((state.fault_bits & MOTOR_FAULT_LIMIT_CLAMPED) != 0u);
    assert(health.clamped_ticks == 1u);
}

static void assert_ttl_expires_to_safe_state(void)
{
    motor_control_init();
    motor_control_target_t target = base_target();
    target.seq = 44u;
    target.ttl_us = 1000u;

    motor_control_submit_target(&target);
    motor_control_tick();
    motor_control_tick();
    motor_control_tick();

    motor_control_state_t state;
    motor_control_health_t health;
    motor_control_get_state(&state);
    motor_control_get_health(&health);

    assert(state.last_target_seq == 44u);
    assert(state.target_fresh == false);
    assert(state.enabled == false);
    assert(state.control_mode == MOTOR_CONTROL_MODE_DISABLED);
    assert((state.fault_bits & MOTOR_FAULT_STALE_TARGET) != 0u);
    assert(health.stale_ticks >= 1u);
}

int main(void)
{
    assert_fresh_target_is_applied();
    assert_limits_are_clamped();
    assert_ttl_expires_to_safe_state();
    return 0;
}
