# Target command for one logical joint on /motor/tp_joint_target.
#
# Control mode values:
# DISABLED=0: joint output disabled.
# ZERO_TORQUE=1: enabled but torque command is zero.
# TORQUE=2: torque_nm is the primary command.
# VELOCITY=3: velocity_rad_s is the primary command.
# POSITION=4: position_rad is the primary command.
# IMPEDANCE=5: position, velocity, kp, kd, and feed-forward torque are used.
# TRAJECTORY=6: target is one point in a trajectory stream.
# CALIBRATION=7: calibration or homing behavior.
# RAW_VENDOR=8: reserved escape hatch; public fields still stay normalized.
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
float64 torque_nm
float64 kp_nm_per_rad
float64 kd_nm_s_per_rad
float64 max_torque_nm
float64 max_velocity_rad_s
float64 max_position_rad
float64 min_position_rad
uint32 ttl_us
uint32 flags
