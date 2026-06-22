std_msgs/Header header   # 标准 Header（wall-clock stamp）：诊断/bag 时间轴，不参与 §7.1 RTT
uint64 sent
uint64 matched
uint64 lost
uint64 duplicate
uint64 stale_duplicate
uint32 inflight
float64 rtt_last_ms
float64 rtt_p95_ms
float64 rtt_max_ms
bool reconciles          # sent==matched+lost+inflight，一眼看链路是否在悄悄掉东西
