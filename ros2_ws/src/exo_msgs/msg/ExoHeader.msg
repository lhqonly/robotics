uint32 seq            # §7.6 序列号，mod 2^32 回绕；回环用精确相等配对
uint64 stamp_mono_ns  # 发送方单调时钟纳秒（§7.1：禁 wall clock）；仅同发送方内可比
uint32 crc            # 应用级 CRC（默认 0 / 默认不强校验，开发期可开，抓打包 bug）
