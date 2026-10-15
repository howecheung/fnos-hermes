#!/bin/bash
# 上游官方源码的已知 bug 补丁（幂等；每条注明 bug 出处与影响）
#
# 原则：只在确认是上游缺陷时打补丁，绝不改官方行为逻辑。
# 每条补丁都要能被 verify-fpk.py 或装包后实测验证。
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/app/hermes-src"
[ -d "$SRC" ] || { echo "  源码目录不存在，跳过"; exit 0; }

patched=0
skipped=0

# ─────────────────────────────────────────────────────────────────────────
# [P0] v0.22.0：tui_gateway/methods_onboarding.py 漏 import Path
#
# 现象：hermes dashboard 启动即崩，日志
#     NameError: name 'Path' is not defined
#     def _shared_nous_store() -> tuple[Path, ...]:
#     → ERROR: Application startup failed. Exiting.
#     → 9220 端口永不监听，面板「概览 → 打开 Dashboard」打不开
#
# 根因：文件里第 64 行的函数体已在用 Path(_profile_home(...))，函数体上方还有一处
#       `from pathlib import ...` 的局部 import，但模块顶部从未 import Path；
#       `_shared_nous_store()` 的返回注解在函数定义时求值 → NameError。
#
# 影响：仅 dashboard / TUI gateway；messaging gateway 与飞书链路不受影响。
# ─────────────────────────────────────────────────────────────────────────
f="$SRC/tui_gateway/methods_onboarding.py"
if [ -f "$f" ]; then
  if grep -qE '^from pathlib import .*\bPath\b' "$f"; then
    skipped=$((skipped+1))
    echo "  · methods_onboarding.py: Path 已导入，跳过"
  elif grep -qE '^import threading$' "$f" && ! grep -qE '^from pathlib import' "$f"; then
    python3 - "$f" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new = s.replace(
    "import threading\n",
    "import threading\nfrom pathlib import Path  # patch: 上游 v0.22.0 漏 import，致 _shared_nous_store() 注解求值 NameError、dashboard 起不来\n",
    1,
)
if new != s:
    open(p, "w", encoding="utf-8").write(new)
    print("  ✓ methods_onboarding.py: 补上 from pathlib import Path")
PYEOF
    patched=$((patched+1))
  else
    echo "  ⚠ methods_onboarding.py: 顶部结构与预期不符，请人工核对"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# 后续上游 bug 放这里，格式照上：
#   [P0] <版本>：<文件> <一句话现象>
#   现象 / 根因 / 影响 / 修法
# ─────────────────────────────────────────────────────────────────────────

echo "  上游补丁：应用 $patched 条，已存在跳过 $skipped 条"
exit 0
