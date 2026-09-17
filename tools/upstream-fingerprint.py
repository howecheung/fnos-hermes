#!/usr/bin/env python3
"""上游结构指纹：记录/比对内核的「接口与布局」基线。

外壳（cmd/*、app/server、app/ui）只依赖内核的两类东西：接口（CLI 入口名、子命令、
包名、extras、HTTP 产物路径）与布局（顶层模块、前端目录、构建脚本名）。本工具把
这些事实抽成指纹存基线，升版本时一比对就知道上游动了什么：

  S: 标量——值变了就是「接口改了」，直接 FAIL（要改外壳）
  L: 列表——少一项 FAIL（被删/改名），多一项 INFO（新增，一般无害）
  R: 运行前提——标量，且额外校验本机运行时是否满足

用法：
  python3 tools/upstream-fingerprint.py --update          # 用当前源码覆盖基线（确认新版可跑后再执行）
  python3 tools/upstream-fingerprint.py --check           # 比对基线，退出码 0=兼容 / 1=有破坏性变化
  可选 --src <dir>（默认 app/hermes-src）、--baseline <file>、--quiet
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

GREEN, RED, YELLOW, BOLD, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[2m", "\033[0m"

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


# 外壳（cmd/*、app/server/monitor.js、custom_routes.js、app/ui）真正引用的内核锚点。
# 只对这些名字做「消失即 FAIL」，避免上游删个无关模块就报红。
RELEVANT = {
    "hermes_cli": [
        "dashboard_auth", "config.py", "cron.py", "curator.py", "doctor.py", "gateway.py",
        "local_runtime", "main.py", "model_catalog.py", "observability", "plugins_loader.py",
        "proxy", "pty_bridge.py", "sessions_cmd.py", "setup.py", "skills_hub.py",
        "subcommands", "update_cmd.py", "web_dist", "web_routers", "web_server.py",
        "web_server_dashboard.py", "web_server_gateway.py", "web_server_sessions.py",
    ],
    "web": ["index.html", "package.json", "public", "src", "vite.config.ts"],
    "ui-tui": ["dist", "package.json", "src"],
}


# ---------- 指纹采集 ----------

def _listdir(path: str) -> list[str]:
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def _read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def _pkg_scripts(path: str) -> list[str]:
    return sorted(_read_json(path).get("scripts", {}).keys())


def _relevant(path: str, names: list[str]) -> list[str]:
    """只保留实际存在的锚点（消失的锚点由基线比对负责报红）。"""
    present = set(_listdir(path))
    return sorted(n for n in names if n in present)


def collect(src: str) -> dict[str, tuple[str, str]]:
    """返回 {key: (类型, 值)}；类型 S=标量 L=列表 R=运行前提。"""
    facts: dict[str, tuple[str, str]] = {}

    def add(kind: str, key: str, value) -> None:
        facts[key] = (kind, value if isinstance(value, str) else json.dumps(value, ensure_ascii=False))

    # --- pyproject：CLI 入口、包名、Python 前提、extras ---
    py = {}
    if tomllib:
        try:
            with open(os.path.join(src, "pyproject.toml"), "rb") as fh:
                py = tomllib.load(fh)
        except OSError:
            py = {}
    proj = py.get("project", {})
    add("S", "pyproject.name", proj.get("name", ""))
    add("R", "pyproject.requires-python", proj.get("requires-python", ""))
    add("L", "pyproject.scripts", sorted(proj.get("scripts", {}).keys()))
    add("L", "pyproject.extras", sorted(proj.get("optional-dependencies", {}).keys()))

    # --- package.json：workspaces / engines / 构建脚本名 ---
    root_pkg = _read_json(os.path.join(src, "package.json"))
    add("L", "root.workspaces", sorted(root_pkg.get("workspaces", []) or []))
    add("R", "root.engines.node", root_pkg.get("engines", {}).get("node", ""))
    add("R", "root.engines.npm", root_pkg.get("engines", {}).get("npm", ""))
    add("L", "root.scripts", _pkg_scripts(os.path.join(src, "package.json")))
    add("L", "web.scripts", _pkg_scripts(os.path.join(src, "web", "package.json")))
    add("L", "ui-tui.scripts", _pkg_scripts(os.path.join(src, "ui-tui", "package.json")))

    # --- 前端产物落点（外壳靠这些路径找页面/TUI） ---
    add("S", "web.vite.outDir", _vite_outdir(os.path.join(src, "web", "vite.config.ts")))

    # --- 顶层布局：只记外壳引用的锚点（消失 = FAIL）；全量规模只作参考（永不 FAIL） ---
    for name, anchors in RELEVANT.items():
        add("L", f"{name}.anchors", _relevant(os.path.join(src, name), anchors))
    add("I", "info.hermes_cli.files", str(len(_listdir(os.path.join(src, "hermes_cli")))))
    add("I", "info.web.files", str(len(_listdir(os.path.join(src, "web")))))
    add("I", "info.ui-tui.files", str(len(_listdir(os.path.join(src, "ui-tui")))))

    # --- 关键产物存在性 ---
    add("S", "artifact.web_dist", "yes" if os.path.isfile(os.path.join(src, "hermes_cli", "web_dist", "index.html")) else "no")
    add("S", "artifact.ui_tui_entry", "yes" if os.path.isfile(os.path.join(src, "ui-tui", "dist", "entry.js")) else "no")

    return facts


def _vite_outdir(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.search(r'outDir:\s*["\']([^"\']+)["\']', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return ""


# ---------- 版式范围判定（用于运行前提） ----------

def _tup(v: str) -> tuple[int, int, int]:
    nums = [int(x) for x in re.findall(r"\d+", v)[:3]]
    nums += [0] * (3 - len(nums))
    return tuple(nums[:3])  # type: ignore[return-value]


def satisfies(version: str, rng: str) -> bool:
    """支持 ^x.y.z / >=a,<b / 纯版本，以及用 || 分隔的备选。"""
    if not rng or not version:
        return True
    v = _tup(version)
    for alt in rng.split("||"):
        alt = alt.strip()
        m = re.match(r"^\^(\d+)(?:\.(\d+))?(?:\.(\d+))?$", alt)
        if m:
            major = int(m.group(1))
            lo = (major, int(m.group(2) or 0), int(m.group(3) or 0))
            hi = (major + 1, 0, 0)
            if v >= lo and v < hi:
                return True
            continue
        ok = True
        for part in [p.strip() for p in alt.split(",") if p.strip()]:
            mm = re.match(r"^(>=|<=|>|<|=)?\s*(\d+(?:\.\d+)*)$", part)
            if not mm:
                ok = False
                break
            op, t = mm.group(1) or "=", _tup(mm.group(2))
            if not {"<=": v <= t, "<": v < t, ">=": v >= t, ">": v > t, "=": v == t}[op]:
                ok = False
                break
        if ok:
            return True
    return False


def local_runtimes() -> dict[str, str]:
    out = {"python": "%d.%d" % sys.version_info[:2], "node": ""}
    for cand in ("node", "/var/apps/nodejs_v24/target/bin/node"):
        try:
            raw = subprocess.run([cand, "--version"], capture_output=True, text=True, timeout=10).stdout
            if raw.strip():
                out["node"] = raw.strip().lstrip("v")
                break
        except (OSError, subprocess.SubprocessError):
            continue
    return out


# ---------- 主流程 ----------

def main() -> int:
    ap = argparse.ArgumentParser(description="上游结构指纹基线比对")
    ap.add_argument("--src", default="app/hermes-src")
    ap.add_argument("--baseline", default="tools/upstream-fingerprint.json")
    ap.add_argument("--update", action="store_true", help="用当前源码覆盖基线")
    ap.add_argument("--check", action="store_true", help="与基线比对")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.src):
        print(f"{RED}找不到源码目录：{args.src}{RESET}", file=sys.stderr)
        return 2
    if not (args.update or args.check):
        ap.error("需要 --update 或 --check")

    facts = collect(args.src)

    if args.update:
        py = {}
        if tomllib:
            try:
                with open(os.path.join(args.src, "pyproject.toml"), "rb") as fh:
                    py = tomllib.load(fh)
            except OSError:
                py = {}
        payload = {
            "version": py.get("project", {}).get("version", "unknown"),
            "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "source": args.src,
            "facts": {k: {"kind": v[0], "value": v[1]} for k, v in facts.items()},
        }
        os.makedirs(os.path.dirname(args.baseline) or ".", exist_ok=True)
        with open(args.baseline, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
        print(f"{GREEN}基线已写入{RESET} {args.baseline}（内核 v{payload['version']}，{len(facts)} 项结构事实）")
        return 0

    base = _read_json(args.baseline)
    bfacts = base.get("facts", {})
    if not bfacts:
        print(f"{YELLOW}基线为空（{args.baseline}）→ 先跑 --update 生成{RESET}")
        return 0

    same = 0
    breaks: list[str] = []
    infos: list[str] = []

    for key, meta in sorted(bfacts.items()):
        kind, old = meta.get("kind", "S"), meta.get("value", "")
        kind_new, new = facts.get(key, ("S", ""))
        if key not in facts:
            breaks.append(f"{key} 整项消失（基线为 {old}）")
            continue
        if new == old:
            same += 1
            continue
        if kind == "I":
            infos.append(f"{key}: {old} → {new}（仅供参考，不影响兼容）")
        elif kind == "L":
            old_set, new_set = set(json.loads(old)), set(json.loads(new))
            gone, added = sorted(old_set - new_set), sorted(new_set - old_set)
            if gone:
                breaks.append(f"{key} 少了 {', '.join(gone)}")
            if added:
                infos.append(f"{key} 新增 {', '.join(added)}")
        else:
            breaks.append(f"{key}: {old} → {new}")

    # 未在基线里的新键（上游新增结构）
    for key in sorted(set(facts) - set(bfacts)):
        infos.append(f"{key} 为新增结构项: {facts[key][1]}")

    hints = {
        "pyproject.scripts": "→ cmd/* 与 monitor.js 里调用 bin/<入口> 的地方要同步",
        "pyproject.name": "→ 包名/metadata 变了，monitor.js 的路径探测要跟着改",
        "python": "→ venv 基础解释器版本要换（见 install_callback 的 python 检测）",
        "node": "→ manifest 的 install_dep_apps 与 node 运行时版本要核对",
        "npm": "→ 调整 build-local.sh 的 NPM_COMPAT_VER",
        "artifacts": "→ install_callback / monitor.js 找前端产物路径要改",
        "top": "→ 顶层模块增删：核对 monitor.js 探测的目录名与 custom_routes.js 的代理",
        "anchors": "→ 外壳引用的锚点消失：核对 monitor.js 探测的目录名与 custom_routes.js 的代理目标",
        "scripts": "→ 构建脚本名变了，build-local.sh 的 npm run 目标要同步",
        "extras": "→ install_callback 的 uv pip install -e \"hermes-src[...]\" 要同步",
    }

    def hint_for(msg: str) -> str:
        for kind, tip in hints.items():
            if kind in msg:
                return tip
        return ""

    if not args.quiet:
        print(f"{BOLD}== 结构指纹比对（基线 = 内核 v{base.get('version', '?')}，"
              f"{base.get('generated_at', '?')}）{RESET}")
        if breaks:
            for b in breaks:
                tip = hint_for(b)
                print(f"  {RED}FAIL{RESET} {b}" + (f"\n       {DIM}{tip}{RESET}" if tip else ""))
        for i in infos:
            print(f"  {YELLOW}INFO{RESET} {i}")
        if not breaks and not infos:
            print(f"  {GREEN}PASS{RESET} {same} 项结构事实与基线完全一致（顶层布局、CLI 接口、产物路径都没动）")
        elif not breaks:
            print(f"  {GREEN}PASS{RESET} {same} 项一致，另有 {len(infos)} 项新增（纯增量，外壳无需改）")

    # 运行前提单独校验（本机能否满足新版要求）
    rt = local_runtimes()
    rt_fail = []
    for key, ver_key in (("pyproject.requires-python", "python"), ("root.engines.node", "node"), ("root.engines.npm", "")):
        kind, rng = facts.get(key, ("R", ""))
        if not rng:
            continue
        if ver_key == "npm":
            continue  # npm 由构建脚本按需另装，不构成失败
        ver = rt.get(ver_key, "")
        if ver and not satisfies(ver, rng):
            rt_fail.append(f"本机 {ver_key} {ver} 不满足上游要求 {rng}（{key}）")
    if not args.quiet:
        if rt_fail:
            for m in rt_fail:
                print(f"  {RED}FAIL{RESET} {m}")
        else:
            print(f"  {GREEN}PASS{RESET} 本机运行时满足：python {rt['python']}、node {rt['node'] or '未装'}")

    fails = len(breaks) + len(rt_fail)
    if not args.quiet:
        print()
        if fails:
            print(f"{RED}共 {fails} 项破坏性变化：先改外壳（app/server、app/ui、cmd/*）再发版{RESET}")
        else:
            print(f"{GREEN}指纹兼容：可发版（新增项仅为纯增量）{RESET}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())