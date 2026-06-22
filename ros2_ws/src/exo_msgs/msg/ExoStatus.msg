ExoHeader header      # MCU 回填：seq 原样回填收到的 cmd.header.seq；stamp/crc 为回填方重新生成
int32 payload         # 本阶段=原样回填 cmd.payload（回环校验）
