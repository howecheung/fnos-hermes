#!/bin/bash
# 预置 node/npm → $HERMES_HOME/tools/（hermes pm 的登记目录）
# 并对齐前端产物的 build receipt（dashboard 启动门禁）
#
# 为什么需要（2026-10-15 实测，官方 v0.22.0 起）：
#   hermes pm 靠 node 跑 `scripts/build/freshness.mjs` 核对前端产物
#   （hermes_cli/source_build.py: source_product_current）。拿不到 node 就
#   直接 return False → dashboard 认定产物过期 → 每次启动重建 → 重建又走
#   pm → 死循环，9220 永不监听。
#   而 pm 下载 node 前会探测系统库 libatomic.so.1，缺则调 `sudo apt-get`
#   —— fnOS 上应用用户没有免密 sudo，装不上，pm 就此卡死。
#
# 解法：① 构建期把 node/npm 压进包，装完直接放进 pm 的目录并登记 facts.json；
#       ② C 段把 receipt 改写为装机实况（免网络、秒级），再用 pm 的 node
#          实跑 freshness 断言必须为 true。两段都幂等。
#
# 幂等：已存在且可执行就跳过。
set -uo pipefail

DATA_DIR="${TRIM_PKGHOME:-/vol1/@apphome/fnos-hermes}/data"
APP_DIR="${TRIM_APPDEST:-/var/apps/fnos-hermes}"
SRC_DIR="${APP_DIR}/pm-tools"
TOOLS="${DATA_DIR}/tools"
LOG="${TRIM_PKGVAR:-/vol1/@appdata/fnos-hermes}/info.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - [pm-tools] $*" >> "$LOG" 2>/dev/null || true; }

# 借用了包内 libatomic 时，必须让后续所有跑 node 的进程（monitor 拉起的
# dashboard 会触发 freshness 检查）也能找到它，否则只在本次脚本里生效。
write_ld_path_hook() {
    local envfile="${DATA_DIR}/.pm-tools-env"
    printf 'HERMES_BUNDLED_LIB=%s\nLD_LIBRARY_PATH=%s\n' "${DATA_DIR}/lib" "${DATA_DIR}/lib" > "$envfile" 2>/dev/null || true
    log "  已写入 ${envfile}（monitor/dashboard 启动时 source 即可带上）"
}

[ -d "$SRC_DIR" ] || { log "包内无 pm-tools（$SRC_DIR），跳过"; exit 0; }

node_bin="$(ls -d "$TOOLS"/node-*-linux-*/bin/node 2>/dev/null | head -1)"
if [ -n "$node_bin" ] && [ -x "$node_bin" ] && "$node_bin" --version >/dev/null 2>&1; then
    # 已就位且能跑 → 跳过解包与登记，但仍要走到下面的 C 段
    # （C 段修 build receipt，这是 dashboard 反复重建的根因）
    log "node 已在位: $node_bin ($("$node_bin" --version 2>/dev/null))"
else
    log "从包内预置件恢复 node/npm → $TOOLS"
    mkdir -p "$TOOLS" || { log "创建 $TOOLS 失败，跳过恢复"; node_bin=""; }

    for archive in "$SRC_DIR"/*.tar.gz; do
        [ -f "$archive" ] || continue
        entry="$(basename "$archive" .tar.gz)"
        if [ -n "$(ls -A "$TOOLS/$entry" 2>/dev/null)" ]; then
            log "  · $entry 已存在"
            continue
        fi
        tmp="$(mktemp -d "$TOOLS/.pmt.XXXXXX")"
        if tar -xzf "$archive" -C "$tmp" 2>/dev/null && [ -n "$(ls -A "$tmp/$entry" 2>/dev/null)" ]; then
            mv "$tmp/$entry" "$TOOLS/$entry"
            chmod -R u+rwX "$TOOLS/$entry" 2>/dev/null || true
            log "  ✓ $entry（$(du -sh "$TOOLS/$entry" 2>/dev/null | cut -f1)）"
        else
            log "  ✗ $entry 解包失败"
        fi
        rm -rf "$tmp"
    done

    # 登记进 facts.json（pm 靠它认定「已安装」；digest 与构建时一致才通过校验）
    "${DATA_DIR}/venv/bin/python3" - "$SRC_DIR" "$TOOLS" >> "$LOG" 2>&1 <<'PY'
import json, os, sys
src_dir, tools = sys.argv[1], sys.argv[2]
facts_p = os.path.join(tools, "facts.json")
stamp_p = os.path.join(src_dir, "facts.seed.json")

facts = {}
if os.path.exists(facts_p):
    try:
        facts = json.load(open(facts_p))
    except Exception:
        facts = {}
facts.setdefault("packages", {})
facts.setdefault("schema", 1)

if os.path.exists(stamp_p):
    for name, meta in json.load(open(stamp_p)).get("packages", {}).items():
        entry = meta.get("entry")
        if entry and os.path.isdir(os.path.join(tools, entry)):
            facts["packages"][name] = meta
            print(f"    登记 {name} -> {entry}")
        else:
            print(f"    跳过 {name}（{entry} 未落盘）")

json.dump(facts, open(facts_p, "w"), indent=2, sort_keys=True)
print("    facts.json 已更新")
PY

    node_bin="$(ls -d "$TOOLS"/node-*-linux-*/bin/node 2>/dev/null | head -1)"
fi
if [ -n "$node_bin" ] && [ -x "$node_bin" ]; then
    v="$("$node_bin" --version 2>/dev/null || echo FAIL)"
    # node 缺 libatomic.so.1 时会直接 exit 127。系统里没有就用包内预置的那份
    # （官方 pm/libatomic.py 只会 apt-get，需要 root；fnOS 应用用户没有免密 sudo）。
    if [ "$v" = "FAIL" ] && [ -f "$SRC_DIR/lib/libatomic.so.1" ]; then
        log "  node 无法直接执行，尝试用包内预置的 libatomic.so.1"
        mkdir -p "$DATA_DIR/lib"
        cp -f "$SRC_DIR/lib/libatomic.so.1" "$DATA_DIR/lib/" 2>/dev/null || true
        if v="$(LD_LIBRARY_PATH="$DATA_DIR/lib" "$node_bin" --version 2>/dev/null)" && [ "$v" != "FAIL" ]; then
            log "  ✓ 借包内 libatomic 启动成功：$v（已设于 $DATA_DIR/lib）"
            write_ld_path_hook
            # 不再 exit：node 能跑就要继续走 C 段做指纹断言（旧版此处 exit 会整段跳过）
            export LD_LIBRARY_PATH="$DATA_DIR/lib"
        fi
    fi
    if [ "$v" != "FAIL" ]; then
        log "恢复完成，node = $v"
    else
        log "⚠ node 存在但无法执行，且包内 libatomic 兜底失败 → 需 root: apt-get install -y libatomic1"
        exit 0
    fi
else
    log "⚠ 未能恢复 node，跳过前端对齐（dashboard 可能不可用）"
    exit 0
fi

# ---------------------------------------------------------------------------
# C. 前端产物指纹对齐（build receipt，免网络改写）
#
# 判定实现在 ${SRC_TREE}/scripts/build/freshness.mjs 的 productCurrent()：
#   ① receipt 的 node 必须等于「跑判定的那个 node」= pm 自己的 node（版本随 pm 走）
#   ② 用 receipt 里 inputs.prepared[].path 重新读盘算目录 hash，必须与记录值一致
#      treeHash() 只把「相对名 + 文件内容」喂进 sha256，绝对路径不参与 —— 所以
#      内容不变、只换路径时，改写 path 即可对齐（实测：改完 hash 与记录值相同）
#
# 构建机与装机机的绝对路径不同（构建机 node 也不是 pm 那个），故两项都必然失配：
#   node: 构建用机器上的 nodejs_v24 (24.15.0) vs pm 预置 node (26.7.0) → hostReceipt 直接 null
#   web 的 prepared「icons」路径指向构建工作副本 → 装机机上不存在 → hash 记成 missing
# （tui 的 prepared 为空数组，只有 node 一项要改）
#
# 改写后用 pm 的 node 实跑 freshness 断言输出 true 才算收工；失败只记日志、不阻塞
# 安装（gateway/面板/记忆不受影响，仅 dashboard 会尝试重建一次）。
# 注意：**不能**回落「在装机路径下重跑前端构建」——那要 node_modules + npm 联网，
# 装机机上必失败，等于 dashboard 永远起不来。
# ---------------------------------------------------------------------------
SRC_TREE="$(readlink -f "${APP_DIR}/hermes-src" 2>/dev/null)"
[ -n "$SRC_TREE" ] || SRC_TREE="${APP_DIR}/hermes-src"

if [ ! -d "$SRC_TREE" ]; then
    log "⚠ 无源码目录 ${SRC_TREE}，跳过前端指纹对齐"
    exit 0
fi

log "对齐前端产物 build receipt（免网络改写）…"
"${DATA_DIR}/venv/bin/python3" - "$SRC_TREE" "$node_bin" >> "$LOG" 2>&1 <<'PY'
import json, os, subprocess, sys

src_tree, node = sys.argv[1], sys.argv[2]
# product → (产物相对路径, prepared 项的落点相对源码根)
products = [("web", "hermes_cli/web_dist", {"icons": "web/public"}),
            ("tui", "ui-tui/dist", {})]

try:
    node_ver = subprocess.run([node, "--version"], capture_output=True, text=True).stdout.strip().lstrip("v")
except OSError as exc:
    print(f"⚠ 无法执行 pm node（{exc}），跳过 receipt 对齐")
    raise SystemExit(0)
if not node_ver:
    print("⚠ 拿不到 pm node 版本，跳过 receipt 对齐")
    raise SystemExit(0)

results = []
for product, out_rel, prepared_rel in products:
    out = os.path.join(src_tree, out_rel)
    receipt = os.path.join(out, "hermes-build.json")
    if not os.path.isfile(receipt):
        print(f"  · {product}: 无 receipt，跳过")
        continue

    data = json.load(open(receipt))
    changed = []
    if data.get("node") != node_ver:
        changed.append(f"node {data.get('node')} → {node_ver}")
        data["node"] = node_ver
    for entry in (data.get("inputs") or {}).get("prepared") or []:
        rel = prepared_rel.get(entry.get("name"))
        if not rel:
            continue
        want = os.path.join(src_tree, rel)
        if os.path.isdir(want) and entry.get("path") != want:
            changed.append(f"prepared[{entry.get('name')}].path → {want}")
            entry["path"] = want
    if changed:
        # 只改字段值、不改键序：freshness 侧是 JSON.parse 后 stringify 比对的
        with open(receipt, "w") as fh:
            json.dump(data, fh)
        print(f"  ✓ {product}: 已改写（{'; '.join(changed)}）")
    else:
        print(f"  ✓ {product}: receipt 已对齐，无需改写")

    proc = subprocess.run(
        [node, os.path.join(src_tree, "scripts/build/freshness.mjs"),
         "--source", src_tree, "--product", product, "--out", out],
        cwd=src_tree, capture_output=True, text=True)
    verdict = (proc.stdout or "").strip()
    ok = verdict == "true"
    results.append((product, ok))
    detail = verdict or (proc.stderr or "").strip()[:300]
    print(f"  {'✓' if ok else '✗'} {product}: freshness = {detail}")

bad = [name for name, ok in results if not ok]
if not results:
    print("无可核对产物。")
elif bad:
    print(f"⚠ 仍失配：{bad} → dashboard 启动时会尝试重建（联网，很可能失败）")
else:
    print("全部通过：dashboard 启动不再重建前端。")
PY
exit 0
