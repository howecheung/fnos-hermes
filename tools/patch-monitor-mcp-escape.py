#!/usr/bin/env python3
"""monitor.js 的 MCP 自愈写回补丁：修「转义层数每轮 +1 → config.yaml 指数膨胀」。

背景（2026-10-28 事故，已复现）
--------------------------------
monitor.js 里的 MCP 自愈循环（`_moduleLevelAutoRegisterMcp`，每 180 秒跑一次）
由两处配合出错：

  解析侧 `_moduleParseMcpServers`：用正则把 YAML **原文**切出来
      out[cur][vm[1]] = vm[2].trim();      // 含引号与反斜杠
  写回侧 build block：对同一个值再 `JSON.stringify()` 一次
      let out = "  " + n + ":\n    command: " + JSON.stringify(cmd) + "\n";

于是每跑一轮，转义层数 +1、字符数指数翻倍：
    14KB → 16MB → 33MB → 67MB → 134MB → 268MB
最终超过 V8 单字符串上限，`JSON.stringify` 抛 `RangeError: Invalid string length`。

deepwiki 只是引信：它是 http 型远程 MCP，天生只有 url、没有 command，
writer 却无条件给每个条目补一行 `command:`，于是第一轮写下 `command: ""`，
之后每轮翻倍。任何 MCP 条目都会触发。

后果链：config.yaml 涨到 268MB → Hermes 报 "formatting error at line 653"
→ 网关启动读+写 268MB YAML 超时 → 启动看门狗 exit code 75 自杀重启 → 无限循环。

修法（三处，缺一不可）
----------------------
1. 写回前把「已经是 JSON 字符串字面量」的值先解包再序列化 → 幂等，转义层数不再增长。
2. http 型条目（有 url、无 command）不再被塞空 `command:` 行 → 不再破坏用户手写的
   正确配置，也不再让 Hermes 持续告警 "has both 'url' and 'command'"。
3. config.yaml 体积守卫（读侧 + 写侧）→ 万一将来再出同类 bug，不会把配置写爆。

幂等：重复运行只会检测到已应用并跳过。锚点缺失 → 直接失败（fail-fast），
绝不「猜着改」——上游改版后应由人确认，而不是悄悄改坏。

用法：python3 tools/patch-monitor-mcp-escape.py [monitor.js 路径]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "patch: MCP 自愈写回转义幂等修复"

# ── 目标代码块（写回侧）────────────────────────────────────────────────────
NEW_BLOCK = '''      block = "mcp_servers:\\n" + names.map(function (n) {
        const e = merged[n];
        // ── ''' + MARKER + ''' ──────────────────────────────
        // 解析侧（_moduleParseMcpServers）用正则取的是 YAML 原文（含引号与反斜杠），
        // 写回侧若直接再 JSON.stringify 一次，转义层数每轮 +1、字符数指数翻倍，
        // 最终超过 V8 单字符串上限报 "Invalid string length"，config.yaml 涨到数百 MB，
        // 拖垮网关启动（看门狗 exit 75 自杀重启）。
        // 修法：① 写回前先解包「已是 JSON 字符串字面量」的值，保证幂等；
        //      ② http 型条目（有 url、无 command）不再被塞空 command 行。
        let cmd = e.command || e.command_cmd || "";
        if (typeof cmd === "string" && cmd.length >= 2 && cmd.charAt(0) === '"' && cmd.charAt(cmd.length - 1) === '"') {
          try { const decoded = JSON.parse(cmd); if (typeof decoded === "string") cmd = decoded; } catch (e) {}
        }
        const isHttp = !!e.url;
        const args = Array.isArray(e.args) ? e.args : [];
        let out = "  " + n + ":\\n";
        if (!isHttp || cmd !== "") out += "    command: " + JSON.stringify(cmd) + "\\n";
        if (args.length) out += "    args:\\n" + args.map(function (a) {
          let av = a;
          if (typeof av === "string" && av.length >= 2 && av.charAt(0) === '"' && av.charAt(av.length - 1) === '"') {
            try { const d = JSON.parse(av); if (typeof d === "string") av = d; } catch (e) {}
          }
          return "      - " + JSON.stringify(av);
        }).join("\\n") + "\\n";
        Object.keys(e).forEach(function (k2) {
          if (k2 === "command" || k2 === "args" || k2 === "command_cmd") return;
          out += "    " + k2 + ": " + e[k2] + "\\n";
        });
        return out.replace(/\\n$/, "");
      }).join("\\n");
'''

# 写回侧：整块替换（从 block 赋值到 .join("\n")）
BLOCK_RE = re.compile(
    r'      block = "mcp_servers:\\n" \+ names\.map\(function \(n\) \{.*?\}\)\.join\("\\n"\);\n',
    re.S,
)

# 函数绑定锚点：补丁必须落在 _moduleLevelAutoRegisterMcp 这个函数体内。
# 只靠 block 正则不够 —— 上游若重命名函数，block 构造可能被搬到别处，
# 那时正则仍会命中，但补丁就贴错了地方。必须两者同时成立才算锚点存在。
FUNC_RE = re.compile(r'function\s+_moduleLevelAutoRegisterMcp\s*\(')

# 读侧守卫：在 readFileSync(HERMES_CONFIG) 前加体积检查
READ_GUARD = '''    let yml = "";
    // ── ''' + MARKER + ''' · 读侧体积守卫 ──────────────────────────────
    // config.yaml 若已被同类 bug 撑到几十上百 MB，读进来会吃掉大量内存且无法修复。
    // 超过上限直接跳过本次自愈（不读不写），保住现有文件并留下日志线索。
    const CONFIG_MAX_BYTES = 1024 * 1024;
    try {
      if (existsSync(HERMES_CONFIG)) {
        const st = fs.statSync(HERMES_CONFIG);
        if (st.size > CONFIG_MAX_BYTES) {
          log("[MCP-BRIDGE] auto-register skipped: config.yaml 体积 " + st.size + " bytes 超过 1MB 上限，疑似写回放大 bug；本次不读不写");
          return;
        }
        yml = readFileSync(HERMES_CONFIG, "utf8");
      }
    } catch (e) {}
'''

READ_RE = re.compile(
    r'    let yml = "";\n'
    r'    try \{ if \(existsSync\(HERMES_CONFIG\)\) yml = readFileSync\(HERMES_CONFIG, "utf8"\); \} catch \(e\) \{\}\n'
)

# 写侧守卫：writeFileSync(HERMES_CONFIG) 前加体积检查
WRITE_GUARD = '''    yml = _replaceTopLevelKey(yml, "mcp_servers", block);
    // ── ''' + MARKER + ''' · 写侧体积守卫 ──────────────────────────────
    // 生成结果超过上限说明写回逻辑又出 bug（转义再次开始累积）。此时拒绝写入，
    // 宁可让自愈不生效，也不能把 config.yaml 写爆拖垮网关。
    if (Buffer.byteLength(yml, "utf8") > CONFIG_MAX_BYTES) {
      log("[MCP-BRIDGE] auto-register aborted: 待写入 config.yaml 超过 1MB 上限，疑似写回放大 bug；已放弃本次写入");
      return;
    }
    try { writeFileSync(HERMES_CONFIG, yml, { mode: 0o644 }); } catch (e) {}
'''

WRITE_RE = re.compile(
    r'    yml = _replaceTopLevelKey\(yml, "mcp_servers", block\);\n'
    r'    try \{ writeFileSync\(HERMES_CONFIG, yml, \{ mode: 0o644 \}\); \} catch \(e\) \{\}\n'
)


def patch(path: Path) -> int:
    src = path.read_text(encoding="utf-8")
    orig = src

    # 1) 写回侧整块
    if MARKER in src:
        print(f"  · {path.name}: 写回侧已打过补丁")
    else:
        fm = FUNC_RE.search(src)
        if not fm:
            print(f"  ✗ {path.name}: 找不到函数 _moduleLevelAutoRegisterMcp —— "
                  f"外壳结构已变，拒绝盲改，请人工确认", file=sys.stderr)
            return 1
        m = BLOCK_RE.search(src, fm.start())
        if not m:
            print(f"  ✗ {path.name}: 在 _moduleLevelAutoRegisterMcp 内找不到写回侧锚点"
                  f"（block 构造）——结构已变，拒绝盲改，请人工确认", file=sys.stderr)
            return 1
        src = src[:m.start()] + NEW_BLOCK + src[m.end():]
        print(f"  ✓ {path.name}: 写回侧已加幂等解包 + http 型不写空 command")

    # 2) 读侧守卫
    if "CONFIG_MAX_BYTES" in src and "auto-register skipped" in src:
        print(f"  · {path.name}: 读侧守卫已在")
    else:
        fm = FUNC_RE.search(src)
        m = READ_RE.search(src, fm.start()) if fm else None
        if not m:
            print(f"  ✗ {path.name}: 在 _moduleLevelAutoRegisterMcp 内找不到读侧锚点"
                  f"（readFileSync(HERMES_CONFIG)）——拒绝盲改", file=sys.stderr)
            return 1
        src = src[:m.start()] + READ_GUARD + src[m.end():]
        print(f"  ✓ {path.name}: 读侧体积守卫已加")

    # 3) 写侧守卫
    if "auto-register aborted" in src:
        print(f"  · {path.name}: 写侧守卫已在")
    else:
        fm = FUNC_RE.search(src)
        m = WRITE_RE.search(src, fm.start()) if fm else None
        if not m:
            print(f"  ✗ {path.name}: 在 _moduleLevelAutoRegisterMcp 内找不到写侧锚点"
                  f"（writeFileSync(HERMES_CONFIG)）——拒绝盲改", file=sys.stderr)
            return 1
        src = src[:m.start()] + WRITE_GUARD + src[m.end():]
        print(f"  ✓ {path.name}: 写侧体积守卫已加")

    if src != orig:
        # 保持原文件权限（补丁不应顺手改 mode，否则 git 里会出现无关的 mode 变更）
        try:
            mode = path.stat().st_mode & 0o7777
            path.write_text(src, encoding="utf-8")
            path.chmod(mode)
        except OSError:
            path.write_text(src, encoding="utf-8")
    return 0


def main() -> int:
    if len(sys.argv) > 1:
        targets = [Path(p) for p in sys.argv[1:]]
    else:
        here = Path(__file__).resolve().parent.parent
        targets = [here / "app" / "server" / "monitor.js"]
    rc = 0
    for t in targets:
        if not t.is_file():
            print(f"  ✗ 找不到 {t}", file=sys.stderr)
            rc = 1
            continue
        rc |= patch(t)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
