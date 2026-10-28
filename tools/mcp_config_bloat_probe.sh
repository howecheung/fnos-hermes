#!/usr/bin/env bash
# config.yaml 膨胀探针：判定「是不是 monitor.js 的 MCP 自愈写回把配置写爆了」
#
# 背景（2026-10-28 事故）：
#   fnOS 外壳 app/server/monitor.js 每 180 秒把 mcp_servers 段写回 config.yaml，
#   解析侧取 YAML 原文、写回侧再 JSON.stringify 一次 → 转义层数每轮 +1、
#   字符数指数翻倍 → 14KB 涨到 268MB → Hermes 报 YAML 格式错误 →
#   网关启动看门狗 exit 75 自杀重启 → supervisor 无限重拉。
#
# 本脚本做两件事：
#   ① 报告 config.yaml 当前体积与元凶行号（>1MB 即中招）
#   ② 抽出 monitor.js 的真实函数跑 30 轮仿真，对比「原始版 vs 已打补丁版」
#      —— 直接给出「这个 bug 还在不在」的判决，而不是靠读代码猜。
#
# 用法：
#   bash scripts/mcp_config_bloat_probe.sh              # 只体检当前 config
#   bash scripts/mcp_config_bloat_probe.sh --sim        # 额外跑 30 轮仿真
#   bash scripts/mcp_config_bloat_probe.sh --sim-only   # 只跑仿真，不体检
#
# 退出码：0 = 正常；1 = 发现膨胀或补丁缺失；2 = 环境缺失（无法判定）
set -uo pipefail

DATA="${HERMES_HOME:-/vol1/@apphome/fnos-hermes/data}"
CFG="$DATA/config.yaml"
LIMIT=$((1024 * 1024))
INSTALLED_MON="/vol1/@appcenter/fnos-hermes/server/monitor.js"
REPO_MON="$DATA/workspace/fnos-hermes/app/server/monitor.js"
NODE_BIN="${NODE_BIN:-$DATA/node/bin/node}"
SIM_DIR="$DATA/cache/scratch/bloat-probe"

DO_CHECK=1
DO_SIM=0
for a in "$@"; do
  case "$a" in
    --sim) DO_SIM=1 ;;
    --sim-only) DO_SIM=1; DO_CHECK=0 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done

echo "════ config.yaml 膨胀探针 ════"
RC=0

# ── ① 体检当前 config ────────────────────────────────────────────────────
if [ "$DO_CHECK" = "1" ]; then
  if [ ! -f "$CFG" ]; then
    echo "✗ 找不到 $CFG"; exit 2
  fi
  SIZE=$(stat -c%s "$CFG")
  if [ "$SIZE" -ge "$LIMIT" ]; then
    echo "✗ config.yaml 已膨胀：$SIZE 字节（约 $((SIZE / 1024 / 1024))MB，阈值 1MB）"
    awk 'length($0)>1000 {printf "  元凶：第 %d 行长度 %d 字符\n", NR, length($0)}' "$CFG" | head -3
    echo "  处置：删掉 mcp_servers 里对应条目让写回回到小文件；"
    echo "        或从 backups/config/config.yaml.good.* 恢复一份正常体积的 config。"
    RC=1
  else
    echo "✓ config.yaml 体积正常：$SIZE 字节"
  fi

  # YAML 可解析性
  if [ -x "$DATA/venv/bin/python3" ]; then
    "$DATA/venv/bin/python3" - "$CFG" <<'PYEOF' || RC=1
import sys
try:
    import yaml
except ImportError:
    print("  (跳过 YAML 校验：本机无 pyyaml)")
    sys.exit(0)
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
    print(f"✓ YAML 可解析，{len(d)} 个顶层键，mcp_servers={d.get('mcp_servers')}")
except Exception as exc:
    # 解析错误信息里可能夹带文件里那行超长 blob —— 必须截断，否则刷屏
    msg = str(exc).replace("\n", " ")
    if len(msg) > 160:
        msg = msg[:160] + " …(已截断)"
    print(f"✗ YAML 解析失败：{msg}")
    sys.exit(1)
PYEOF
  fi
fi

# ── ② 补丁状态 ───────────────────────────────────────────────────────────
check_patch() {
  local f="$1" label="$2"
  if [ ! -f "$f" ]; then
    echo "  ? $label：文件不存在（$f）"
    return 2
  fi
  if grep -q "MCP 自愈写回转义幂等修复" "$f"; then
    echo "  ✓ $label：幂等补丁在位"
    return 0
  fi
  echo "  ✗ $label：补丁缺失！装 MCP 后 config.yaml 会再次指数膨胀"
  return 1
}
echo "── 补丁状态 ──"
check_patch "$INSTALLED_MON" "装机目录 monitor.js" || RC=1
check_patch "$REPO_MON" "仓库 monitor.js" || RC=1

# ── ③ 30 轮仿真 ──────────────────────────────────────────────────────────
if [ "$DO_SIM" = "1" ]; then
  echo "── 30 轮仿真 ──"
  if [ ! -x "$NODE_BIN" ]; then
    echo "  ? 找不到 node（$NODE_BIN），跳过仿真"
  else
    mkdir -p "$SIM_DIR"
    HARNESS="$SIM_DIR/harness.js"
    # 抽出真实函数 + 打桩调用
    python3 - "$INSTALLED_MON" "$HARNESS" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("function _moduleParseMcpServers(yml) {")
k = src.index("function _moduleLevelAutoRegisterMcp() {")
end = src.index("\n}\n", k) + 3
extract = src[i:end]
harness = '''const fs = require('fs');
const path = require('path');
const { existsSync, readFileSync, writeFileSync, statSync } = fs;
__EXTRACT__
const CFG = process.env.TEST_CFG;
const HERMES_CONFIG = CFG;
const CONNECTORS_STATE = path.join(path.dirname(CFG), "connectors.json");
const CONNECTOR_CATALOG = [];
const MCP_BRIDGE_SCRIPT = "/tmp/bridge.js";
const resolvedNodeBin = "/usr/bin/node";
function log(m) {}
function _replaceTopLevelKey(yml, key, block) {
  const re = new RegExp("^" + key + ":[\\\\s\\\\S]*?(?=^[a-zA-Z_][a-zA-Z0-9_-]*:)", "m");
  if (re.test(yml)) return yml.replace(re, block + "\\n");
  return yml.replace(/^mcp_servers:[\\s\\S]*$/m, block);
}
const S = {
  http:  "model:\\n  provider: x\\nmcp_servers:\\n  deepwiki:\\n    url: https://mcp.deepwiki.com/mcp\\n    enabled: true\\n",
  stdio: "model:\\n  provider: x\\nmcp_servers:\\n  local:\\n    command: npx\\n    args:\\n      - -y\\n",
  conn:  "model:\\n  provider: x\\nmcp_servers:\\n  conn-gmail:\\n    command: /usr/bin/node\\n    args:\\n      - /path/bridge.js\\n",
};
const RES = [];
for (const name of Object.keys(S)) {
  fs.writeFileSync(CFG, S[name]);
  let maxSize = fs.statSync(CFG).size, err = null;
  try { for (let i=1;i<=30;i++){ _moduleLevelAutoRegisterMcp(); maxSize = Math.max(maxSize, fs.statSync(CFG).size);} }
  catch(e){ err = e.message; }
  RES.push({s: name, final: fs.statSync(CFG).size, max: maxSize, thrown: err ? err.slice(0,40) : ""});
}
console.log("PROBE" + JSON.stringify(RES));
'''.replace("__EXTRACT__", extract)
open(sys.argv[2], "w", encoding="utf-8").write(harness)
PYEOF
    if [ $? -ne 0 ]; then
      echo "  ? 构造 harness 失败（monitor.js 结构可能已变），跳过仿真"
    else
      OUT=$(TEST_CFG="$SIM_DIR/probe.yaml" "$NODE_BIN" "$HARNESS" 2>/dev/null)
      echo "$OUT" | grep -o 'PROBE.*' | sed 's/^PROBE//' | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    print('  ? 仿真输出无法解析'); sys.exit(0)
bad = 0
for r in rows:
    flag = ''
    if r['max'] > 1024 * 1024 or r['thrown']:
        flag = '  ✗ 膨胀！'; bad = 1
    else:
        flag = '  ✓ 稳定'
    print(f\"  {r['s']:6} final={r['final']:>10} max={r['max']:>10} {flag}\" + (f\"  thrown={r['thrown']}\" if r['thrown'] else ''))
sys.exit(bad)
"
      [ $? -ne 0 ] && RC=1
      rm -rf "$SIM_DIR"
    fi
  fi
fi

echo
if [ "$RC" = "0" ]; then
  echo "✓ 全部正常：config 体积健康、补丁在位、写回幂等。"
else
  echo "✗ 发现问题（见上方）。修法见技能 hermes-ops-runbook → references/mcp-install-and-triage.md。"
fi
exit "$RC"
