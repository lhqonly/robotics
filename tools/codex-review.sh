#!/usr/bin/env bash
# Codex(GPT)对抗性第二意见 —— 供测试工程师 Gill 调用
#
# 作用:用一个不同厂商的模型(OpenAI Codex / gpt-5.5)独立审查 Tom(Claude)的实现,
#       作为交叉验证的第二路证据。
#
# 特性:
#   - read-only 只读沙箱:Codex 只能读文件、不能改任何东西,安全。
#   - 复用 ~/.codex 的 ChatGPT 订阅登录态,无需额外配置 API key。
#   - 可在 prompt 里用相对路径引用仓库文件,Codex 会自行读取。
#
# 用法:
#   tools/codex-review.sh "请对抗性审查 src/comm/foo.c:这段代码在并发/急停场景下有什么缺陷?"
#
# 建议从仓库根目录运行,以便 Codex 能按相对路径读到源码。
set -euo pipefail

PROMPT="${1:-}"
if [[ -z "$PROMPT" ]]; then
  echo "用法: tools/codex-review.sh \"<对抗性审查 prompt>\"" >&2
  exit 2
fi

exec codex exec \
  --sandbox read-only \
  --skip-git-repo-check \
  "$PROMPT" < /dev/null
