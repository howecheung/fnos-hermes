#!/usr/bin/env bash
# ============================================================================
# build-local.sh — 在 fnOS 本机（或任何 Linux x86_64）直接构建 fnos-hermes.fpk
#
# 与 .github/workflows/build-fpk.yml（tools/actions/build-fpk.yml）等价的本地流程：
#   1. 按 config/bootstrap/hermes-version.env 里的 HERMES_TAG 拉官方源码到 app/hermes-src
#   2. npm 预构建 hermes_cli/web_dist（Vite）+ ui-tui/dist/entry.js
#   3. 清理 node_modules / __pycache__
#   4. 写 manifest 版本
#   5. 用 fnpack 出包，追加小写 icon.png，输出到 dist/
#
# 用法：bash tools/build-local.sh [--rebuild-src]
#   --rebuild-src  强制重新 clone 官方源码（默认已存在则复用）
# 环境变量：
#   NODE_BIN_DIR   node/npm 所在目录（默认 /var/apps/nodejs_v24/target/bin）
#   FNPACK         fnpack 可执行文件路径（默认 tools/.cache/fnpack）
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

REBUILD_SRC=0
[ "${1:-}" = "--rebuild-src" ] && REBUILD_SRC=1

NODE_BIN_DIR="${NODE_BIN_DIR:-/var/apps/nodejs_v24/target/bin}"
export PATH="${NODE_BIN_DIR}:${PATH}"
FNPACK="${FNPACK:-${REPO_DIR}/tools/.cache/fnpack}"
APPNAME="fnos-hermes"
UPSTREAM="https://github.com/NousResearch/hermes-agent.git"

# shellcheck disable=SC1091
. ./config/bootstrap/hermes-version.env
: "${HERMES_TAG:?config/bootstrap/hermes-version.env 缺少 HERMES_TAG}"
: "${PKG_VERSION:?config/bootstrap/hermes-version.env 缺少 PKG_VERSION}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "0/6 环境检查"
command -v node >/dev/null || { echo "找不到 node（设置 NODE_BIN_DIR）"; exit 1; }
echo "node $(node -v) / npm $(npm -v) / 目录 $REPO_DIR"
echo "官方 tag: ${HERMES_TAG}  包版本: ${PKG_VERSION}"
df -h "$REPO_DIR" | tail -1

# ── 1. 官方源码 ────────────────────────────────────────────────────────────
say "1/6 获取官方源码 ${HERMES_TAG}"
# 说明：走代理时 git 协议只有 ~55KB/s，codeload 压缩包约 200KB/s（实测），优先用后者；
# 失败时回退 git clone。tests/ website/ .github/ 运行时与打包都不需要，直接瘦身（约 70MB）。
fetch_tarball() {
  local url="https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/${HERMES_TAG}"
  local tgz="${REPO_DIR}/tools/.cache/hermes-src-${HERMES_TAG}.tgz"
  mkdir -p "${REPO_DIR}/tools/.cache"
  echo "下载 $url"
  curl -fL --retry 3 --retry-delay 5 --no-progress-meter -o "$tgz" "$url" || return 1
  rm -rf app/hermes-src && mkdir -p app/hermes-src
  tar -xzf "$tgz" -C app/hermes-src --strip-components=1 || return 1
  rm -f "$tgz"
}
if [ "$REBUILD_SRC" = "1" ] || [ ! -f app/hermes-src/pyproject.toml ]; then
  rm -rf app/hermes-src
  if ! fetch_tarball; then
    echo "codeload 下载失败，回退 git clone"
    rm -rf app/hermes-src
    git clone --depth 1 --branch "${HERMES_TAG}" "$UPSTREAM" app/hermes-src
  fi
  rm -rf app/hermes-src/.git app/hermes-src/.github app/hermes-src/tests app/hermes-src/website
else
  echo "复用已有 app/hermes-src（加 --rebuild-src 可强制重拉）"
fi
UP_VER="$(grep -m1 '^version' app/hermes-src/pyproject.toml | sed -E 's/.*"([^"]+)".*/\1/')"
echo "上游源码版本: ${UP_VER}"

# ── 2. 预构建前端 ──────────────────────────────────────────────────────────
say "2/6 预构建 web_dist + TUI bundle（首次约 5-15 分钟）"
# npm 版本门：上游 package.json engines 明确排除 npm 11.10.0–11.16.x（该区间有已知问题），
# 而本机随 node24 自带 npm 11.12.1 正好落在排除区间 → npm 会以 EBADENGINE 直接退出。
# 解法：在仓库外（无 engines 约束的目录）装一个受支持的 npm 供构建期使用，不改上游源码。
NPM_COMPAT_DIR="${REPO_DIR}/tools/.cache/npm-compat"
NPM_COMPAT_VER="${NPM_COMPAT_VER:-11.19.1}"
if [ ! -x "${NPM_COMPAT_DIR}/node_modules/.bin/npm" ]; then
  mkdir -p "$NPM_COMPAT_DIR"
  (cd "$NPM_COMPAT_DIR" && npm init -y >/dev/null 2>&1 \
     && npm install --no-audit --no-fund "npm@${NPM_COMPAT_VER}") || { echo "安装兼容 npm 失败"; exit 1; }
fi
export PATH="${NPM_COMPAT_DIR}/node_modules/.bin:${PATH}"
echo "构建用 npm: $(npm -v)（node $(node -v)）"
cd app/hermes-src
if [ ! -f hermes_cli/web_dist/index.html ]; then
  npm install --workspace web --no-audit --no-fund
  npm run build --workspace web
fi
if [ ! -f ui-tui/dist/entry.js ]; then
  npm install --workspace ui-tui --no-audit --no-fund
  npm run build:ink --workspace ui-tui || true
  npm run build --workspace ui-tui
fi
test -f hermes_cli/web_dist/index.html || { echo "web_dist 未生成"; exit 1; }
test -f ui-tui/dist/entry.js || { echo "ui-tui/dist/entry.js 未生成"; exit 1; }
ls -la hermes_cli/web_dist | head -4
ls -la ui-tui/dist | head -4
cd "$REPO_DIR"

# ─ 3. 清理依赖 ────────────────────────────────────────────────────────────
say "3/6 清理 node_modules / __pycache__"
rm -rf app/hermes-src/node_modules app/hermes-src/web/node_modules \
       app/hermes-src/ui-tui/node_modules app/hermes-src/ui-tui/packages/hermes-ink/node_modules \
       app/hermes-src/apps/shared/node_modules
find app/hermes-src -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
du -sh app/hermes-src

# ── 4. 写版本 ─────────────────────────────────────────────────────────────
say "4/6 写入版本号"
sed -i -E "s/^version[[:space:]]*=.*/version               = ${PKG_VERSION}/" manifest
python3 - "$UP_VER" <<'PY'
import re, sys
ver = sys.argv[1]
p = "config/bootstrap/hermes-version.env"
t = open(p).read()
t = re.sub(r'^HERMES_VERSION=.*$', f'HERMES_VERSION={ver}', t, flags=re.M)
open(p, 'w').write(t)
PY
grep -E '^(version|display_name|appname)' manifest
grep -E '^HERMES_(VERSION|TAG)=' config/bootstrap/hermes-version.env

# ── 5. 打包（用干净暂存目录，避免 .git 进包）────────────────────────────────
say "5/6 fnpack 打包"
mkdir -p tools/.cache dist
# 坑：fnpack 强制要求 manifest 的 icon 所指文件存在，而参照仓库漏提交了 ICON.PNG
# （只有 ICON_256.PNG 和 icon.png，内容相同）→ 这里自愈补齐，避免打包中断。
[ -f ICON.PNG ] || cp ICON_256.PNG ICON.PNG
if [ ! -x "$FNPACK" ]; then
  echo "下载 fnpack ..."
  curl -fsSL "https://static2.fnnas.com/fnpack/fnpack-1.0.4-linux-amd64" -o "$FNPACK"
  chmod +x "$FNPACK"
fi
STAGE="$(mktemp -d "${REPO_DIR}/../fpk-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -C "$REPO_DIR" --exclude='./.git' --exclude='./dist' --exclude='./tools/.cache' \
    --exclude='./fpk-stage*' --exclude='*.fpk' --exclude='node_modules' --exclude='__pycache__' \
    -cf - . | tar -C "$STAGE" -xf -
"$FNPACK" build --directory "$STAGE"
[ -f "${APPNAME}.fpk" ] || { echo "fnpack 未生成 ${APPNAME}.fpk"; ls -la; exit 1; }
mv "${APPNAME}.fpk" "dist/fnos-hermes_v${PKG_VERSION}.fpk"

# ── 6. 追加小写 icon.png ──────────────────────────────────────────────────
say "6/6 追加小写 icon 并核对"
FPK="dist/fnos-hermes_v${PKG_VERSION}.fpk"
[ -f icon.png ] || cp ICON.PNG icon.png
WORKDIR="$(mktemp -d)"
tar -xzf "$FPK" -C "$WORKDIR"
cp icon.png "$WORKDIR/icon.png"
tar -czf "$FPK" --owner=0 --group=0 -C "$WORKDIR" $(ls -A "$WORKDIR")
rm -rf "$WORKDIR"

echo
echo "======== 产物 ========"
ls -lh dist/
echo "fpk 内条目数: $(tar -tzf "$FPK" | wc -l)"
tar -tzf "$FPK" | grep -iE '^\.?/?(manifest|icon)' | head
echo "SHA256: $(sha256sum "$FPK" | cut -d' ' -f1)"