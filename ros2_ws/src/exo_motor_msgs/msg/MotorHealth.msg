# Bus-level health counters on /motor/tp_motor_health.

std_msgs/Header header
uint8 bus_id
uint8 joint_count
uint64 targets_received
uint64 targets_applied
uint64 stale_targets
uint64 motor_tx
uint64 motor_rx
uint64 motor_timeout
uint64 motor_fault
float64 target_apply_latency_p99_ms
float64 can_gap_p99_ms
bool reconciles
