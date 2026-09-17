#!/usr/bin/env python3
"""fnos-hermes fpk 出厂自检：解包核对身份隔离、权限、产物与「不误杀主实例」。

用法：
    python3 tools/verify-fpk.py                      # 自动取 dist/ 里最新的 fpk
    python3 tools/verify-fpk.py dist/xxx.fpk

退出码 0 = 全部通过（可发版）；1 = 存在 FAIL。
只读操作：仅解到内存/临时目录，不动 NAS 上任何运行中的进程。
"""
import argparse
import glob
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile

APPNAME = "fnos-hermes"
DISPLAY = "fnOS Hermes"
PORTS = ["8660", "8743", "9220"]          # 本包应使用的端口
FOREIGN_PORTS = ["8650", "8742", "9219"]  # 主实例（hermes-agent）端口，出现在本包 = 隐患
R = {"pass": 0, "fail": [], "info": []}


def ok(msg):
    R["pass"] += 1
    print(f"  \033[32mPASS\033[0m {msg}")


def bad(msg, hint=""):
    R["fail"].append(msg)
    print(f"  \033[31mFAIL\033[0m {msg}")
    if hint:
        print(f"       \033[2m→ {hint}\033[0m")


def info(msg):
    R["info"].append(msg)
    print(f"  \033[33mINFO\033[0m {msg}")


def head(t):
    print(f"\n\033[1;36m== {t}\033[0m")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fpk", nargs="?", default=None)
    a = ap.parse_args()
    path = a.fpk
    if not path:
        cands = sorted(glob.glob("dist/*.fpk"))
        if not cands:
            print("dist/ 下没有 fpk，先跑 tools/build-local.sh")
            return 1
        path = cands[-1]
    print(f"\033[1m核对 {path}\033[0m")

    raw = open(path, "rb").read()
    print(f"文件大小 {len(raw)/1048576:.1f} MB   SHA256 {hashlib.sha256(raw).hexdigest()}")
    fpk = tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz")

    # ---------- 1. manifest ----------
    head("1. manifest 元数据与身份")
    try:
        man = fpk.extractfile("manifest").read().decode("utf-8")
    except KeyError:
        bad("fpk 内没有 manifest")
        return 1
    kv = dict(re.findall(r"^(\w+)\s*=\s*(.*)$", man, re.M))
    (ok if kv.get("appname") == APPNAME else bad)(
        f"appname = {kv.get('appname')}" + ("" if kv.get("appname") == APPNAME else f"（应为 {APPNAME}）"))
    (ok if kv.get("display_name") == DISPLAY else bad)(f"display_name = {kv.get('display_name')}")
    ver = kv.get("version", "")
    ok(f"version = {ver}")
    icon = kv.get("icon", "")
    names = fpk.getnames()
    (ok if icon in names else bad)(f"manifest.icon = {icon} 在包内存在")
    (ok if "nodejs_v24" in kv.get("install_dep_apps", "") else bad)(
        f"install_dep_apps = {kv.get('install_dep_apps')}")
    for key in ("appname", "display_name", "desc", "distributor"):
        if "hermes-agent" in kv.get(key, "") and key != "desc":
            bad(f"manifest.{key} 里混入了 hermes-agent 身份：{kv.get(key)}")
    print(f"  \033[32mPASS\033[0m 图标文件：{[n for n in names if n.lower().endswith(('.png', '.jpg'))]}")

    # ---------- 2. cmd/ 权限 ----------
    head("2. cmd/* 生命周期脚本可执行")
    cmds = [m for m in fpk.getmembers() if m.name.startswith("cmd/") and m.isfile()]
    badmode = [m.name for m in cmds if not (m.mode & 0o111)]
    (ok if not badmode else bad)(f"{len(cmds)} 个 cmd 脚本均可执行" if not badmode else f"不可执行：{badmode}")
    for m in cmds:
        print(f"       {m.name} mode={oct(m.mode)[-3:]}  {m.size} bytes")

    # ---------- 3. app.tgz ----------
    head("3. 应用载荷 app.tgz")
    app = tarfile.open(fileobj=io.BytesIO(fpk.extractfile("app.tgz").read()), mode="r:gz")
    anames = app.getnames()
    ok(f"app.tgz 条目 {len(anames)} 个")

    def have(p):
        return any(n == p or n.startswith(p.rstrip("/") + "/") for n in anames)

    def size_of(p):
        try:
            return app.getmember(p).size
        except KeyError:
            return 0

    for p, label in [("bin/fnos-hermes", "CLI 包装 bin/fnos-hermes"),
                     ("bin/monitor-api", "Monitor API 客户端 bin/monitor-api")]:
        if have(p):
            m = app.getmember(p)
            (ok if m.mode & 0o111 else bad)(f"{label} 存在且可执行（{m.size} bytes）")
        else:
            bad(f"{label} 缺失")
    try:
        cli = app.extractfile("bin/fnos-hermes").read().decode("utf-8", "replace")
        (ok if APPNAME in cli else bad)(f"bin/fnos-hermes 指向本应用（{'命中' if APPNAME in cli else '未命中'} {APPNAME}）")
    except KeyError:
        pass

    # 前端产物：内核页面 + 对话 TUI
    for p in ("hermes-src/hermes_cli/web_dist/index.html", "hermes-src/ui-tui/dist/entry.js"):
        if have(p):
            s = app.getmember(p).size
            (ok if s > 1000 else bad)(f"{p} 存在（{s} bytes）")
        else:
            bad(f"{p} 缺失", "前端未预构建：检查 build-local.sh 第 2 步")
    # 核心源码实体
    srcfiles = [n for n in anames if n.startswith("hermes-src/")]
    ok(f"内置官方源码 {len(srcfiles)} 个文件")

    # 身份改写残留（历史缺陷：重叠 sed 产生 fnos-fnos-fnos-hermes-… 临时名）
    dup = [n for n in anames + names if "fnos-fnos" in n]
    (ok if not dup else bad)(f"无重复前缀残留（fnos-fnos）" if not dup else f"重复前缀残留：{dup[:5]}")

    # ---------- 4. 身份隔离（端口 / socket / 路径 / CLI 软链） ----------
    head("4. 身份隔离：端口与路径")
    blob_names = [n for n in anames if n.startswith(("server/", "ui/", "config/", "cmd/"))]
    blob = b""
    for n in blob_names:
        try:
            m = app.getmember(n)
            if m.isfile() and m.size < 3_000_000:
                blob += app.extractfile(n).read()
        except Exception:
            pass
    text = blob.decode("utf-8", "replace")
    for p in PORTS:
        (ok if p in text else bad)(f"使用本包端口 {p}")
    foreign = sorted({p for p in FOREIGN_PORTS if re.search(rf"(?<!\d){p}(?!\d)", text)})
    if foreign:
        info(f"出现主实例端口 {foreign} —— 若在注释里属正常，需人工确认（不得作为默认监听端口）")
    else:
        ok("未把主实例端口（8650/8742/9219）当默认端口")
    for pat, label in [(f"{APPNAME}.sock", "socket 名"), ("/app/" + APPNAME, "fnOS 应用路径前缀")]:
        (ok if pat in text else bad)(f"{label} = {pat}")
    # 外壳绝不能读写主实例的数据目录 / 应用路径（否则两包互相踩）
    clash = sorted({m.group(0) for m in re.finditer(r"@apphome/hermes-agent|/app/hermes-agent(?!-)", text)})
    (ok if not clash else bad)(f"外壳未引用主实例目录" if not clash
                              else f"外壳引用了主实例目录 {clash} —— 会与 hermes-agent 包互相干扰")

    # fnOS 元数据：resource 里写相对 bin 路径（fnOS 自己拼 /usr/local/bin/），privilege 定应用用户
    def _json(p):
        import json
        try:
            return json.loads(app.extractfile(p).read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            bad(f"{p} 不可解析：{e}")
            return {}

    res, priv = _json("config/resource"), _json("config/privilege")
    bins = res.get("usr-local-linker", {}).get("bin", [])
    (ok if bins == ["bin/" + APPNAME] else bad)(
        f"usr-local-linker → {bins}（fnOS 会软链为 /usr/local/bin/{APPNAME}，不覆盖现有 hermes 命令）")
    shares = [s.get("name") for s in res.get("data-share", {}).get("shares", [])]
    (ok if shares == [APPNAME] else bad)(f"data-share 共享目录 = {shares}")
    (ok if priv.get("username") == APPNAME and priv.get("groupname") == APPNAME else bad)(
        f"运行用户/组 = {priv.get('username')}/{priv.get('groupname')}，默认 run-as={priv.get('defaults', {}).get('run-as')}")

    # ---------- 5. 不误杀主实例 ----------
    head("5. 进程清理模式（绝不能误杀主实例）")
    pats = set()
    for n in anames:
        if n.startswith("hermes-src/") or not n.endswith((".js", ".sh", ".py")) or n.startswith("cmd/"):
            continue
        try:
            m = app.getmember(n)
            if not m.isfile() or m.size > 2_000_000:
                continue
            body = app.extractfile(n).read().decode("utf-8", "replace")
        except Exception:
            continue
        for mm in re.finditer(r"(?:pkill|pgrep)[^\n]{0,120}", body):
            for pm in re.findall(r"[\"']([^\"']*(?:hermes|Hermes)[^\"']*)[\"']", mm.group(0)):
                pats.add((n, pm))
    if not pats:
        info("未发现 pkill/pgrep 模式（可能已不用 shell 清理）")
    for n, pm in sorted(pats):
        scoped = APPNAME in pm and re.search(r"\(|\.\+", pm) and "hermes-agent" not in pm
        (ok if scoped else bad)(f"{n}: pkill 模式 {pm!r}" + ("" if scoped else " 未限定本应用路径，会误杀其他 Hermes 实例"))

    # 真机模拟：拿模式去匹配当前正在跑的进程，主实例 PID 绝不能命中
    try:
        main_pids = set(subprocess.run(["pgrep", "-f", "hermes-agent"], capture_output=True, text=True)
                        .stdout.split())
    except Exception:
        main_pids = set()
    if main_pids:
        hits = set()
        for _n, pm in pats:
            got = subprocess.run(["pgrep", "-f", pm], capture_output=True, text=True).stdout.split()
            hits |= set(got) & main_pids
        if hits:
            bad(f"清理模式会命中主实例进程 {sorted(hits)}", "把 pkill 模式改成只匹配本应用路径")
        else:
            ok(f"实测：{len(pats)} 条清理模式均不命中主实例（{len(main_pids)} 个 hermes-agent 进程）")
    else:
        info("当前没有其它 hermes-agent 进程在跑，跳过误杀实测")

    # ---------- 6. 版本一致性 ----------
    head("6. 版本坐标一致性")
    try:
        env = app.extractfile("config/bootstrap/hermes-version.env").read().decode("utf-8", "replace")
        ev = dict(re.findall(r"^(\w+)=(.*)$", env, re.M))
        (ok if ev.get("PKG_VERSION") == ver else bad)(
            f"包版本一致：manifest {ver} ↔ hermes-version.env {ev.get('PKG_VERSION')}")
        core = ev.get("HERMES_VERSION", "")
        (ok if ver.split("-")[0] == core else bad)(f"内置内核版本 v{core} ↔ 包版本 {ver}")
        (ok if ev.get("HERMES_TAG") else bad)(f"上游 tag = {ev.get('HERMES_TAG')}")
    except KeyError:
        bad("包内缺 config/bootstrap/hermes-version.env")

    # ---------- 汇总 ----------
    print()
    if R["fail"]:
        print(f"\033[1;31m{len(R['fail'])} 项 FAIL（{R['pass']} 项通过）：不要发版\033[0m")
        for f in R["fail"]:
            print(f"  · {f}")
        return 1
    print(f"\033[1;32m全部通过：{R['pass']} 项检查绿，可发版（{len(R['info'])} 条提示）\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())