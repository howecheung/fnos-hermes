#!/usr/bin/env bash
# ============================================================================
# publish-release.sh — 把 dist/ 里的 fpk 发布到 GitHub Release（幂等，可重复跑）
#
#   * 版本号取自 config/bootstrap/hermes-version.env 的 PKG_VERSION
#   * tag = v<PKG_VERSION>；同名 Release 已存在则复用，同名资产先删再传
#   * token：环境变量 GITHUB_TOKEN 优先，否则读 /vol1/@apphome/hermes-agent/data/.env
#
# 用法：bash tools/publish-release.sh
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck disable=SC1091
. ./config/bootstrap/hermes-version.env

OWNER_REPO="${OWNER_REPO:-howecheung/fnos-hermes}"
API="https://api.github.com/repos/${OWNER_REPO}"
TAG="v${PKG_VERSION}"
FPK="dist/fnos-hermes_v${PKG_VERSION}.fpk"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /vol1/@apphome/hermes-agent/data/.env ]; then
  TOKEN="$(grep -m1 '^GITHUB_TOKEN=' /vol1/@apphome/hermes-agent/data/.env | cut -d= -f2- | tr -d '"'"'"' \r')"
fi
[ -n "$TOKEN" ] || { echo "缺少 GITHUB_TOKEN"; exit 1; }
[ -f "$FPK" ] || { echo "找不到 $FPK，先跑 tools/build-local.sh"; exit 1; }

SHA="$(sha256sum "$FPK" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$FPK")"
echo "发布 $TAG ← $FPK（$((SIZE / 1048576)) MB, sha256:${SHA:0:12}）"

NOTES="$(cat <<EOF
fnOS 原生安装的第三方打包版 Hermes Agent（跟随上游 NousResearch/hermes-agent）。

**本版变更：修复应用中心图标**
- 根因：\`ICON.PNG\` 只有 256×256，fnOS 应用中心要求 512×512，尺寸不合格 → 详情页显示灰色包裹占位图
- 现在按规格生成整套图标（512 / 256 / 64），桌面入口一并修正
- 出包自动自检新增图标尺寸断言，尺寸不对直接拦下不给发版

**坐标**
- 包版本：\`${PKG_VERSION}\`　内置上游内核：\`${HERMES_VERSION}\`（tag \`${HERMES_TAG}\`）
- 可与官方 \`hermes-agent\` 包并存：独立 appname / 端口 8660·8743·9220 / 数据目录 / CLI \`fnos-hermes\`

**安装**
- fnOS 应用中心 → 手动安装 → 选本 fpk（已装旧版会走升级流程）
- 或命令行：\`trim-cli\` 安装本地 fpk

**校验**
\`\`\`
sha256  ${SHA}
size    ${SIZE} bytes
\`\`\`
EOF
)"

REL_ID="$(curl -sS -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" \
          "${API}/releases/tags/${TAG}" | jq -r '.id // empty')"

if [ -z "$REL_ID" ]; then
  echo "新建 Release ${TAG}"
  REL_ID="$(jq -n --arg tag "$TAG" --arg name "${TAG} — 应用中心图标修复" --arg body "$NOTES" \
            '{tag_name:$tag, target_commitish:"main", name:$name, body:$body, draft:false, prerelease:false}' \
            | curl -sS -X POST -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" \
                   -H "Content-Type: application/json" --data-binary @- "${API}/releases" | jq -r '.id // empty')"
else
  echo "Release ${TAG} 已存在（id=${REL_ID}），复用"
fi
[ -n "$REL_ID" ] || { echo "创建 Release 失败"; exit 1; }

# 同名资产先删（重跑时替换）
OLD_ASSET="$(curl -sS -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" \
             "${API}/releases/${REL_ID}/assets" | jq -r --arg n "$(basename "$FPK")" \
             '.[] | select(.name==$n) | .id' | head -1)"
[ -n "$OLD_ASSET" ] && { echo "删除旧资产 ${OLD_ASSET}"; curl -sS -X DELETE \
  -H "Authorization: token ${TOKEN}" "${API}/releases/assets/${OLD_ASSET}" >/dev/null; }

echo "上传资产（可能较慢，取决于网络；强制 HTTP/1.1 规避代理 HTTP/2 PROTOCOL_ERROR）…"
UP="$(curl -sS --http1.1 --retry 5 --retry-delay 5 --retry-all-errors \
      -X POST \
      -H "Authorization: token ${TOKEN}" -H "Content-Type: application/octet-stream" \
      --data-binary @"${FPK}" \
      "${API}/releases/${REL_ID}/assets?name=$(basename "$FPK")")"
echo "$UP" | jq -r '"上传完成: \(.name)  \(.size) bytes  \(.browser_download_url)"' \
  || { echo "上传疑似失败：$UP" | head -c 600; exit 1; }
echo "Release 页面：https://github.com/${OWNER_REPO}/releases/tag/${TAG}"