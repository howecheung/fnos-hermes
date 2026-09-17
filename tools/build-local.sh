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
#   --rebuild-src  强制重解官方源码（默认 tag 一致则复用；tarball 有缓存，不重复下载）
# 环境变量：
#   NODE_BIN_DIR   node/npm 所在目录（默认 /var/apps/nodejs_v24/target/bin）
#   FNPACK         fnpack 可执行文件路径（默认 tools/.cache/fnpack）
#   SKIP_VERIFY    =1 跳过出包后的出厂自检（tools/verify-fpk.py）
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

LAST_T=$(date +%s); TOTAL_T0=$LAST_T; STEP_NAME=""
say() {
  local now; now=$(date +%s)
  [ -n "$STEP_NAME" ] && printf '   \033[2m（上一步「%s」耗时 %ss）\033[0m\n' "$STEP_NAME" "$((now - LAST_T))"
  STEP_NAME="$*"; LAST_T=$now
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

say "0/7 环境检查"
command -v node >/dev/null || { echo "找不到 node（设置 NODE_BIN_DIR）"; exit 1; }
echo "node $(node -v) / npm $(npm -v) / 目录 $REPO_DIR"
echo "官方 tag: ${HERMES_TAG}  包版本: ${PKG_VERSION}"
df -h "$REPO_DIR" | tail -1

# ── 1. 官方源码 ────────────────────────────────────────────────────────────
say "1/7 获取官方源码 ${HERMES_TAG}"
# 说明：走代理时 git 协议只有 ~55KB/s，codeload 压缩包约 200KB/s（实测），优先用后者；
# 失败时回退 git clone。tests/ website/ .github/ 运行时与打包都不需要，直接瘦身（约 70MB）。
CACHE_DIR="${REPO_DIR}/tools/.cache"
TGZ="${CACHE_DIR}/hermes-src-${HERMES_TAG}.tgz"
STAMP="app/hermes-src/.fnos-src-tag"
CUR_TAG="$(cat "$STAMP" 2>/dev/null || true)"
# 跨 tag 复用的 JS 依赖（node_modules 与版本无关，重装一次几分钟，白扔可惜）
KEEP_DIRS=(node_modules web/node_modules ui-tui/node_modules
           ui-tui/packages/hermes-ink/node_modules apps/shared/node_modules)
# 同 tag 重解时前端产物仍然有效（省一次 Vite 构建）；换 tag 必须丢弃重建
if [ "$CUR_TAG" = "$HERMES_TAG" ]; then
  KEEP_DIRS+=(hermes_cli/web_dist ui-tui/dist)
fi
fetch_tarball() {
  mkdir -p "$CACHE_DIR"
  if [ -s "$TGZ" ] && [ "$(stat -c%s "$TGZ")" -gt 10000000 ]; then
    echo "命中源码缓存 ${TGZ}（$(du -h "$TGZ" | cut -f1)）——跳过下载"
    return 0
  fi
  local url="https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/${HERMES_TAG}"
  echo "下载 $url"
  rm -f "$TGZ"
  curl -fL --retry 3 --retry-delay 5 --no-progress-meter -o "$TGZ" "$url" || { rm -f "$TGZ"; return 1; }
  echo "已缓存到 ${TGZ}（$(du -h "$TGZ" | cut -f1)，同 tag 再构建直接复用）"
}
extract_src() {
  local keep d; keep="$(mktemp -d "${REPO_DIR}/../src-keep.XXXXXX")"
  for d in "${KEEP_DIRS[@]}"; do                      # 硬链接暂存（同文件系统，秒级、零拷贝）
    [ -d "app/hermes-src/$d" ] || continue
    mkdir -p "$keep/$(dirname "$d")"
    cp -al "app/hermes-src/$d" "$keep/$d" 2>/dev/null || cp -a "app/hermes-src/$d" "$keep/$d"
  done
  rm -rf app/hermes-src && mkdir -p app/hermes-src
  tar -xzf "$TGZ" -C app/hermes-src --strip-components=1 || return 1
  rm -rf app/hermes-src/.git app/hermes-src/.github app/hermes-src/tests app/hermes-src/website
  for d in "${KEEP_DIRS[@]}"; do                      # node_modules 归位；前端产物不归位（必须按新源码重建）
    [ -d "$keep/$d" ] || continue
    mkdir -p "app/hermes-src/$(dirname "$d")"
    rm -rf "app/hermes-src/$d"
    mv "$keep/$d" "app/hermes-src/$d"
  done
  rm -rf "$keep"
  echo "$HERMES_TAG" > "$STAMP"
}
if [ "$REBUILD_SRC" = "1" ] || [ ! -f app/hermes-src/pyproject.toml ] || [ "$CUR_TAG" != "$HERMES_TAG" ]; then
  echo "需重解源码（当前 tag=${CUR_TAG:-无} → 目标 ${HERMES_TAG}）"
  if fetch_tarball; then
    extract_src
  else
    echo "codeload 不可用，回退 git clone（慢，可能 50 分钟以上）"
    rm -rf app/hermes-src
    git clone --depth 1 --branch "${HERMES_TAG}" "$UPSTREAM" app/hermes-src
    rm -rf app/hermes-src/.git app/hermes-src/.github app/hermes-src/tests app/hermes-src/website
    echo "$HERMES_TAG" > "$STAMP"
  fi
else
  echo "复用已有 app/hermes-src（tag 一致：${CUR_TAG}；加 --rebuild-src 强制重解）"
fi
UP_VER="$(grep -m1 '^version' app/hermes-src/pyproject.toml | sed -E 's/.*"([^"]+)".*/\1/')"
echo "上游源码版本: ${UP_VER}"

# ── 2. 预构建前端 ──────────────────────────────────────────────────────────
say "2/7 预构建 web_dist + TUI bundle（首次约 5-15 分钟）"
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
# 只在依赖真的变了（lockfile 比已安装的隐藏锁新）时才重装，否则直接复用上次的 node_modules
if [ ! -f node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
  echo "依赖有变化或未安装 → npm install（web + ui-tui workspace）"
  npm install --workspace web --workspace ui-tui --no-audit --no-fund
else
  echo "依赖未变 → 复用已有 node_modules，跳过 npm install"
fi
if [ ! -f hermes_cli/web_dist/index.html ]; then
  npm run build --workspace web
fi
if [ ! -f ui-tui/dist/entry.js ]; then
  npm run build:ink --workspace ui-tui || true
  npm run build --workspace ui-tui
fi
test -f hermes_cli/web_dist/index.html || { echo "web_dist 未生成"; exit 1; }
test -f ui-tui/dist/entry.js || { echo "ui-tui/dist/entry.js 未生成"; exit 1; }
ls -la hermes_cli/web_dist | head -4
ls -la ui-tui/dist | head -4
cd "$REPO_DIR"

# ─ 3. 清理依赖 ────────────────────────────────────────────────────────────
say "3/7 清理 __pycache__（node_modules 不再删除：打包时按名排除，留作下次复用）"
find app/hermes-src -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "node_modules 现状（不进包，仅供复用）："
du -sh app/hermes-src/node_modules 2>/dev/null || echo "  （无）"
du -sh app/hermes-src

# ── 4. 写版本 ─────────────────────────────────────────────────────────────
say "4/7 写入版本号"
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
say "5/7 fnpack 打包"
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
say "6/7 追加小写 icon 并核对"
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

# ─ 7. 出厂自检（身份隔离 / 权限 / 产物 / 不误杀主实例）──────────────────────
if [ "${SKIP_VERIFY:-0}" != "1" ] && [ -f tools/verify-fpk.py ]; then
  say "7/7 出厂自检 verify-fpk.py"
  python3 tools/verify-fpk.py "$FPK"
else
  STEP_NAME=""
fi

NOW_T=$(date +%s)
printf '\n\033[1;36m总耗时 %ss\033[0m（最后一步「%s」%ss）\n产物: %s\n' \
  "$((NOW_T - TOTAL_T0))" "$STEP_NAME" "$((NOW_T - LAST_T))" "$FPK"