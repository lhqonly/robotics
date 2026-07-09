# Measured or estimated state for one logical joint on /motor/tp_joint_state.
#
# Control mode values mirror JointTarget:
# DISABLED=0, ZERO_TORQUE=1, TORQUE=2, VELOCITY=3, POSITION=4, IMPEDANCE=5,
# TRAJECTORY=6, CALIBRATION=7, RAW_VENDOR=8.
uint8 CONTROL_MODE_DISABLED=0
uint8 CONTROL_MODE_ZERO_TORQUE=1
uint8 CONTROL_MODE_TORQUE=2
uint8 CONTROL_MODE_VELOCITY=3
uint8 CONTROL_MODE_POSITION=4
uint8 CONTROL_MODE_IMPEDANCE=5
uint8 CONTROL_MODE_TRAJECTORY=6
uint8 CONTROL_MODE_CALIBRATION=7
uint8 CONTROL_MODE_RAW_VENDOR=8

std_msgs/Header header
uint32 seq
uint8 joint_id
uint8 control_mode
float64 position_rad
float64 velocity_rad_s
float64 torque_est_nm
float64 current_a
float64 bus_voltage_v
float64 temperature_c
uint32 fault_bits
uint32 vendor_fault_bits
uint32 last_target_seq
uint32 sample_age_us
bool target_fresh
bool enabled
