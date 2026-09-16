#!/usr/bin/env bash
# ============================================================================
# apply-identity.sh — 把上游打包树（veenyi/fnos-hermes-agent）改写为本仓库身份
#
# 背景：本仓库的打包骨架源自 https://github.com/veenyi/fnos-hermes-agent
#      （其本身是 iranee/fnos-hermes-agent 的 fork，GPL-3.0）。
#      改写目的：让本包以 appname = fnos-hermes 与官方 hermes-agent 包【并存】安装，
#      互不干扰（独立数据目录 / 独立端口 / 独立 socket / 进程清理只杀自己）。
#
# 用法（在仓库根目录执行）：
#   bash tools/apply-identity.sh            # 就地改写整棵打包树
#   bash tools/apply-identity.sh --dry-run  # 只列出将被改写的文件
#
# 前提：改写前先把 veenyi 的打包树同步进来（不含 app/hermes-src，源码由 CI 拉取）：
#   git clone --depth 1 https://github.com/veenyi/fnos-hermes-agent.git /tmp/upstream
#   rsync -a --exclude .git --exclude app/hermes-src /tmp/upstream/ ./
#
# 注意：**不要**改写以下字符串（它们是官方 Python 包名 / 官方仓库地址）：
#   hermes-agent (pip/pypi 包名)、hermes_cli、NousResearch/hermes-agent、
#   hermes-agent.nousresearch.com、setup.hermes-agent.nousresearch.com
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

APPNAME="fnos-hermes"
GH_OWNER="howecheung"
GH_REPO="fnos-hermes"
PORT_UI=8660
PORT_GATEWAY=8743
PORT_DASHBOARD=9220
WORKFLOW_FILE="build-fpk.yml"

# 目标文件范围：只处理文本类打包文件；跳过大体积压缩产物与 git 目录
TARGETS=(
  manifest hot-patch.json README.md .gitignore
  cmd config/privilege config/resource config/bootstrap config/prompts
  app/bin app/ui app/server app/package.json
  wizard preview skills
  .github/workflows
)
# 明确排除：官方 web UI 的压缩补丁（数十万行 minified，无身份引用，避免误伤）
EXCLUDES=(
  --exclude-dir=.git --exclude-dir=node_modules
  --exclude='index-hermes-*-patched.js'
)

# sed 规则集（顺序敏感：长路径优先，identity 专用串先于通用串）
SED_RULES=(
  # ── 路径改写 ──
  "s#/vol1/@apphome/hermes-agent#/vol1/@apphome/${APPNAME}#g"
  "s#/vol3/@apphome/hermes-agent#/vol3/@apphome/${APPNAME}#g"
  "s#/vol1/@appdata/hermes-agent#/vol1/@appdata/${APPNAME}#g"
  "s#/var/apps/hermes-agent#/var/apps/${APPNAME}#g"
  "s#/app/hermes-agent#/app/${APPNAME}#g"
  "s#/proxy/hermes-agent#/proxy/${APPNAME}#g"
  # ── socket / 身份串 ──
  "s#hermes-agent\\.sock#${APPNAME}.sock#g"
  "s#hermes-agent-update\\.fpk#${APPNAME}-update.fpk#g"
  "s#hermes-appcenter-sudoers#${APPNAME}-appcenter-sudoers#g"
  "s#app_name='hermes-agent'#app_name='${APPNAME}'#g"
  "s#hermes-agent:hermes-agent#${APPNAME}:${APPNAME}#g"
  "s#hermes-agent ALL=(root)#${APPNAME} ALL=(root)#g"
  "s#l\\.includes(\"hermes-agent\")#l.includes(\"${APPNAME}\")#g"
  # ── 进程清理：只杀本应用自己的进程（关键！否则会误杀官方 hermes-agent 实例）──
  # 注意 BRE 转义：文件里是字面量 hermes-agent/.+(gateway|dashboard)，其中 + 、( 、| 在 BRE 中本就是字面量
  "s#hermes-agent/\.+(gateway|dashboard)#${APPNAME}/.+(gateway|dashboard)#g"
  "s#hermes-agent/\.+dashboard#${APPNAME}/.+dashboard#g"
  "s#\"hermes\\.\*gateway\"#\"${APPNAME}/.+gateway\"#g"
  "s#\"hermes\\.\*dashboard\"#\"${APPNAME}/.+dashboard\"#g"
  "s#node\.\*monitor\\\.js#${APPNAME}.*monitor.js#g"
  "s#bun\.\*monitor\\\.js#${APPNAME}.*monitor.js#g"
  # ── 上游仓库 / 自更新通道指向本仓库 ──
  "s#veenyi/fnos-hermes-agent#${GH_OWNER}/${GH_REPO}#g"
  "s#iranee/fnos-hermes-agent#${GH_OWNER}/${GH_REPO}#g"
  "s#Build_fnos-hermes-agent\\.yml#${WORKFLOW_FILE}#g"
  "s#fnos-hermes-agent_v#${APPNAME}_v#g"
  "s#\"User-Agent\": \"fnos-hermes-agent\"#\"User-Agent\": \"${APPNAME}\"#g"
  # ── 端口错开（官方包占 8650/8742/9219）──
  "s#\\b8650\\b#${PORT_UI}#g"
  "s#\\b8742\\b#${PORT_GATEWAY}#g"
  "s#\\b9219\\b#${PORT_DASHBOARD}#g"
)

# 待处理文件 = 全部 cmd/* + 关键身份文件（无条件处理，sed 不匹配则无副作用）
#              ∪ grep 命中的其余文件（monitor.js/custom_routes.js/ui/prompts/skills 等）
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  {
    find cmd config/privilege config/resource config/bootstrap app/bin manifest -type f 2>/dev/null
    grep -rlE "hermes-agent|[^0-9](8650|8742|9219)[^0-9]|hermes\.\*" "${EXCLUDES[@]}" "${TARGETS[@]}" 2>/dev/null
  } | sort -u
)

echo "== apply-identity: appname=${APPNAME} 端口 UI=${PORT_UI}/gateway=${PORT_GATEWAY}/dashboard=${PORT_DASHBOARD}"
echo "== 待改写文件数: ${#FILES[@]}"
printf '   %s\n' "${FILES[@]}"

if [ "$DRY" = "1" ]; then echo "== dry-run，未写入"; exit 0; fi

SED_ARGS=()
for r in "${SED_RULES[@]}"; do SED_ARGS+=(-e "$r"); done

for f in "${FILES[@]}"; do
  sed -i "${SED_ARGS[@]}" "$f"
done

# ── 特殊文件：privilege / resource / manifest / ui config（非行内通用改写）──
echo "== 改写 privilege / resource / ui config"
python3 - <<'PY'
import json, pathlib, re
root = pathlib.Path(".")
# config/privilege：应用以独立 Linux 用户运行（fnOS 每个应用一个用户）
p = root / "config/privilege"
if p.exists():
    txt = p.read_text()
    txt = re.sub(r'"username"\s*:\s*"[^"]+"', '"username": "fnos-hermes"', txt)
    txt = re.sub(r'"groupname"\s*:\s*"[^"]+"', '"groupname": "fnos-hermes"', txt)
    p.write_text(txt)
    print("  -", p)
# config/resource：共享目录名 + usr-local-linker 命令名（避免与官方包 /usr/local/bin/hermes 冲突）
p = root / "config/resource"
if p.exists():
    d = json.loads(p.read_text())
    res = d.get("resource", d)
    shares = res.get("data-share", {}).get("shares") if "data-share" in res else None
    txt = p.read_text().replace('"name": "hermes-agent"', '"name": "fnos-hermes"')
    txt = txt.replace('"bin/hermes"', '"bin/fnos-hermes"')
    p.write_text(txt)
    print("  -", p)
# app/ui/config：桌面应用入口名 + 网关 socket / 前缀
p = root / "app/ui/config"
if p.exists():
    def fix(o):
        if isinstance(o, dict):
            return {(k.replace("hermes-agent", "fnos-hermes") if isinstance(k, str) else k): fix(v) for k, v in o.items()}
        if isinstance(o, list):
            return [fix(x) for x in o]
        if isinstance(o, str):
            return o.replace("hermes-agent", "fnos-hermes")
        return o
    d = fix(json.loads(p.read_text()))
    for k, v in list(d.get(".url", {}).items()):
        if isinstance(v, dict) and "title" in v:
            v["title"] = "fnOS Hermes"
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    print("  -", p)
PY

echo "== 完成。请用以下命令复核残留身份引用："
echo "   grep -rn 'hermes-agent' cmd app/bin app/ui/config manifest config/privilege config/resource | grep -v 'pip \\|pypi\\|simple/index'"