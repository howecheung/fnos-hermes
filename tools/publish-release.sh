#!/usr/bin/env bash
# ============================================================================
# publish-release.sh — 把 dist/ 里的 fpk 发布到 GitHub Release（幂等，可重复跑）
#
#   * 版本号取自 config/bootstrap/hermes-version.env 的 PKG_VERSION
#   * tag = v<PKG_VERSION>；同名 Release 已存在则复用，同名资产先删再传
#   * 上传必须打 release 的 upload_url（uploads.github.com）：
#     打 api.github.com/repos/.../releases/<id>/assets 会 404，
#     而且整个文件都白传完才 404（2026-09-17 实测，61MB 传了 82s 才报错）
#   * 上传强制 HTTP/1.1：走代理时 HTTP/2 会 PROTOCOL_ERROR 断流
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
ASSET="$(basename "$FPK")"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /vol1/@apphome/hermes-agent/data/.env ]; then
  TOKEN="$(grep -m1 '^GITHUB_TOKEN=' /vol1/@apphome/hermes-agent/data/.env | cut -d= -f2- | tr -d '"'"'"' \r')"
fi
[ -n "$TOKEN" ] || { echo "缺少 GITHUB_TOKEN"; exit 1; }
[ -f "$FPK" ] || { echo "找不到 $FPK，先跑 tools/build-local.sh"; exit 1; }

SHA="$(sha256sum "$FPK" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$FPK")"
echo "发布 $TAG ← $FPK（$((SIZE / 1048576)) MB, sha256:${SHA:0:12}）"

AUTH=(-H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json")

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

**校验**
\`\`\`
sha256  ${SHA}
size    ${SIZE} bytes
\`\`\`
EOF
)"

# ---------- 1. 取或建 Release，拿到 id 与 upload_url ----------
REL_JSON="$(mktemp)"
curl -sS --http1.1 "${AUTH[@]}" -o "$REL_JSON" "${API}/releases/tags/${TAG}" || true
if ! jq -e '.id' "$REL_JSON" >/dev/null 2>&1; then
  echo "新建 Release ${TAG}"
  jq -n --arg tag "$TAG" --arg name "${TAG} — 应用中心图标修复" --arg body "$NOTES" \
     '{tag_name:$tag, target_commitish:"main", name:$name, body:$body, draft:false, prerelease:false}' > "${REL_JSON}.req"
  curl -sS --http1.1 "${AUTH[@]}" -H "Content-Type: application/json" \
       --data-binary @"${REL_JSON}.req" -o "$REL_JSON" "${API}/releases" || true
  rm -f "${REL_JSON}.req"
else
  echo "Release ${TAG} 已存在（id=$(jq -r .id "$REL_JSON")），复用"
fi
jq -e '.id' "$REL_JSON" >/dev/null 2>&1 || { echo " 取/建 Release 失败：$(head -c 500 "$REL_JSON")"; rm -f "$REL_JSON"; exit 1; }
REL_ID="$(jq -r '.id' "$REL_JSON")"
UP_URL="$(jq -r '.upload_url' "$REL_JSON" | sed 's/{[^}]*}//')"
rm -f "$REL_JSON"

# ---------- 2. 同名资产先删（重跑时替换） ----------
OLD_ASSET="$(curl -sS --http1.1 "${AUTH[@]}" "${API}/releases/${REL_ID}/assets" \
             | jq -r --arg n "$ASSET" '.[] | select(.name==$n) | .id' | head -1)"
[ -n "$OLD_ASSET" ] && { echo "删除旧资产 ${OLD_ASSET}"; curl -sS --http1.1 -X DELETE "${AUTH[@]}" \
  "${API}/releases/assets/${OLD_ASSET}" >/dev/null; }

# ---------- 3. 上传（打 upload_url，不是 api.github.com） ----------
echo "上传资产（HTTP/1.1，可能较慢，取决于网络）…"
TMP_UP="$(mktemp)"
CODE="$(curl -sS --http1.1 --retry 3 --retry-delay 5 --retry-all-errors -X POST \
      "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
      --data-binary @"${FPK}" -o "$TMP_UP" -w '%{http_code}' \
      "${UP_URL}?name=${ASSET}")" || CODE=000
if [ "$CODE" != "201" ] && [ "$CODE" != "200" ]; then
  echo "❌ 上传失败（HTTP ${CODE}）：$(head -c 600 "$TMP_UP")"
  rm -f "$TMP_UP"; exit 1
fi
# 校验返回值，别把"空响应/错误对象"当成功（2026-09-17 踩坑：jq 对空对象也退出 0，误报上传完成）
jq -e '.browser_download_url' "$TMP_UP" >/dev/null 2>&1 || { echo "❌ 响应异常：$(head -c 600 "$TMP_UP")"; rm -f "$TMP_UP"; exit 1; }
jq -r '"✅ 上传完成: \(.name)  \(.size) bytes\n\(.browser_download_url)"' "$TMP_UP"
rm -f "$TMP_UP"
echo "Release 页面：https://github.com/${OWNER_REPO}/releases/tag/${TAG}"