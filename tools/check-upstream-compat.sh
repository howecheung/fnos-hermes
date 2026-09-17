#!/usr/bin/env bash
# 上游兼容性检查：确认外壳（app/server、app/ui、cmd/*）与 kernel（app/hermes-src）的
# 5 类耦合点仍然成立。跟上游升版本时先跑本脚本，全绿再打包发版。
#
# 用法：bash tools/check-upstream-compat.sh [源码目录]
#   源码目录默认 app/hermes-src（由 tools/build-local.sh 拉取/缓存）
# 退出码：0 = 全绿；1 = 有 FAIL（外壳可能失配，不要发版）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="${1:-app/hermes-src}"
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
head2() { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }

if [ ! -d "$SRC" ]; then
    echo "找不到源码目录：$SRC（先跑 tools/build-local.sh 把上游源码拉下来）" >&2
    exit 2
fi

KV=$(grep -E '^(PKG_VERSION|HERMES_TAG|HERMES_VERSION)=' config/bootstrap/hermes-version.env 2>/dev/null | tr '\n' ' ')
VER=$(sed -nE 's/^version *= *"([^"]+)".*/\1/p' "$SRC/pyproject.toml" | head -1)
printf '外壳耦合检查 · 源码 %s · pyproject 版本 %s · %s\n' "$SRC" "${VER:-?}" "$KV"

head2 '1. CLI 入口名（外壳调用 venv/bin/hermes）'
grep -qE '^hermes *= *"hermes_cli[.:]main' "$SRC/pyproject.toml" \
    && pass 'pyproject [project.scripts] 仍有 hermes = "hermes_cli.main:main"' \
    || fail 'CLI 入口名变了（bin/hermes）→ cmd/* 与 monitor.js 的 hermes 调用需同步改'

head2 '2. CLI 子命令 gateway / dashboard（外壳靠它起核心）'
for sub in gateway dashboard; do
    if grep -rqE "\"$sub\"" "$SRC/hermes_cli/main.py" 2>/dev/null; then
        pass "子命令 $sub 仍注册"
    else
        fail "子命令 $sub 在 hermes_cli/main.py 里找不到了 → monitor.js 启动/守护会失效"
    fi
done

head2 '3. 前端产物路径（网页控制台 + 对话 TUI）'
if grep -rqE 'outDir *: *"\.\./hermes_cli/web_dist"' "$SRC/web/vite.config.ts" 2>/dev/null; then
    pass 'web 构建输出仍为 hermes_cli/web_dist'
else
    fail 'web/vite.config.ts 的 outDir 变了 → app/ui 与 monitor.js 找 web_dist/index.html 会落空'
fi
if [ -f "$SRC/ui-tui/dist/entry.js" ]; then
    pass "对话 TUI 预构建产物存在（$(stat -c%s "$SRC/ui-tui/dist/entry.js") bytes）"
else
    fail 'ui-tui/dist/entry.js 缺失 → 构建脚本的 ui-tui 构建步骤需调整'
fi

head2 '4. Python 包名与运行时约束'
[ -d "$SRC/hermes_cli" ] \
    && pass '包目录 hermes_cli 存在（monitor.js 用 hermes_cli.__file__ 探测）' \
    || fail '包目录改名了 → monitor.js 的路径探测与 pip 装出的 CLI 都要跟着改'
RP=$(sed -nE 's/^requires-python *= *"([^"]+)".*/\1/p' "$SRC/pyproject.toml" | head -1)
PV=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')
case "$RP" in
    *"$PV"*|"") pass "requires-python=${RP:-未声明}，本机 python $PV 在范围内" ;;
    *) fail "requires-python=${RP}，本机 python $PV 不在范围 → 装不上（venv 需换版本）" ;;
esac
NPM_RANGE=$(sed -nE '/"engines"/,/}/p' "$SRC/package.json" 2>/dev/null | sed -nE 's/.*"npm" *: *"([^"]+)".*/\1/p' | head -1)
NPM_COMPAT="${NPM_COMPAT_VER:-$(sed -nE 's/^NPM_COMPAT_VER="\$\{NPM_COMPAT_VER:-([0-9.]+)\}".*/\1/p' tools/build-local.sh | head -1)}"
if [ -z "$NPM_RANGE" ]; then
    pass '上游未声明 npm engines 约束（构建期任意 npm 可用）'
elif [ -z "$NPM_COMPAT" ]; then
    printf '  \033[33mINFO\033[0m 上游 npm engines=%s；未读到构建脚本的 NPM_COMPAT_VER，请确认构建期 npm 满足该范围\n' "$NPM_RANGE"
else
    SEMVER=$(find "$SRC" -maxdepth 6 -type d -name semver -path '*node_modules*' 2>/dev/null | head -1)
    if [ -n "$SEMVER" ] && command -v node >/dev/null 2>&1; then
        if node -e "process.exit(require('$SEMVER').satisfies('$NPM_COMPAT','$NPM_RANGE')?0:1)" 2>/dev/null; then
            pass "构建期 npm $NPM_COMPAT 满足上游 engines npm: $NPM_RANGE"
        else
            fail "构建期 npm $NPM_COMPAT 不满足上游 engines npm: $NPM_RANGE → 调整 build-local.sh 的 NPM_COMPAT_VER"
        fi
    else
        printf '  \033[33mINFO\033[0m 上游 npm engines=%s，构建期 npm=%s（无 semver 可校验，人工确认）\n' "$NPM_RANGE" "$NPM_COMPAT"
    fi
fi

head2 '5. 数据面路径（config.yaml / sessions / state.db）'
for pat in 'config\.yaml' 'sessions' 'state\.db'; do
    n=$(grep -rlE "$pat" "$SRC/hermes_cli" 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] \
        && pass "上游仍使用 $pat（$n 个文件）" \
        || fail "$pat 在上游代码里消失 → 外壳读写的数据面可能已迁移，需人工核对"
done

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[1;32m全部通过：外壳与内核 v%s 兼容，可以打包发版。\033[0m\n' "${VER:-?}"
else
    printf '\033[1;31m存在 FAIL：外壳适配点已失配，先修 app/server、app/ui、cmd/* 再发版。\033[0m\n'
fi
exit "$FAIL"