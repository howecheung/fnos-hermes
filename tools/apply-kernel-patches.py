#!/usr/bin/env python3
"""对解包后的官方 Hermes 内核源码打本地补丁（幂等 + fail-fast）。

背景（2026-10-27 实测）：
    tools/mcp_tool.py 的 _ensure_mcp_sdk() 用 _MCP_SDK_IMPORT_ATTEMPTED 做「只试一次」，
    但该标志是无条件置位的（在 and 分支之外）。若首次符号导入在 SDK 半初始化状态下失败，
    _MCP_HTTP_AVAILABLE 会永远为 False，此后所有远程 HTTP 型 MCP 都报
    「requires HTTP transport but mcp.client.streamable_http is not available」
    ——该报错极具误导性：真机上 HTTP 支持与远端服务均正常。

    本补丁把 HTTP 符号探测从「仅在 and 分支成功时执行」改为「独立执行一次」，
    两处都补：早退分支（attempted 已置位时）与锁内末尾。

    上游若已修复（早退分支内已含 HTTP 补探测），本脚本会识别并跳过。

用法：python3 tools/apply-kernel-patches.py [hermes_src_dir]
退出码：0 = 已打或已上游修复；1 = 锚点缺失（构建必须中止，避免静默丢补丁）。
"""
import os
import py_compile
import sys

MARK = "# fnos-local-patch: mcp-http-ensure-retry"

EARLY_OLD = """    if _MCP_SDK_IMPORT_ATTEMPTED or ClientSession is not None:
        return _MCP_AVAILABLE
"""

EARLY_NEW = """    if _MCP_SDK_IMPORT_ATTEMPTED or ClientSession is not None:
        if not _MCP_HTTP_AVAILABLE:
            """ + MARK + """
            # 首次 ensure 若在 SDK 半初始化状态下失败，_MCP_SDK_IMPORT_ATTEMPTED 会被
            # 无条件置位，HTTP 符号探测将永不重试 → 远程 HTTP 型 MCP 永久不可用。
            _MCP_NEW_HTTP = _import_sdk_names("mcp.client.streamable_http", ("streamable_http_client",))
            _MCP_LEGACY_HTTP = _import_sdk_names("mcp.client.streamable_http", ("streamablehttp_client",))
            _MCP_HTTP_AVAILABLE = _MCP_NEW_HTTP or _MCP_LEGACY_HTTP
        return _MCP_AVAILABLE
"""

LOCK_OLD = """        _MCP_LOGGING_CALLBACK_SUPPORTED = _client_session_accepts("logging_callback")
        _MCP_SDK_IMPORT_ATTEMPTED = True
"""

LOCK_NEW = """        _MCP_LOGGING_CALLBACK_SUPPORTED = _client_session_accepts("logging_callback")
        if not _MCP_HTTP_AVAILABLE:
            """ + MARK + """
            # 独立于上面的 and 分支：即使 ClientSession/stdio 导入失败，HTTP 符号也必须
            # 单独探测一次，否则远程 HTTP 型 MCP 连不上。
            _MCP_NEW_HTTP = _import_sdk_names("mcp.client.streamable_http", ("streamable_http_client",))
            _MCP_LEGACY_HTTP = _import_sdk_names("mcp.client.streamable_http", ("streamablehttp_client",))
            _MCP_HTTP_AVAILABLE = _MCP_NEW_HTTP or _MCP_LEGACY_HTTP
        _MCP_SDK_IMPORT_ATTEMPTED = True
"""


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "app/hermes-src"
    target = os.path.join(root, "tools", "mcp_tool.py")
    if not os.path.isfile(target):
        print(f"[kernel-patch] 找不到 {target}，跳过（可能不是 Hermes 源码树）")
        return 0

    src = open(target, encoding="utf-8").read()

    if MARK in src:
        print("[kernel-patch] 已打过补丁，跳过")
        return 0

    # 上游已修：早退分支里已经有 HTTP 补探测
    if EARLY_OLD in src and "if not _MCP_HTTP_AVAILABLE:" in src.split(EARLY_OLD, 1)[1][:600]:
        print("[kernel-patch] 上游已修复该问题，跳过")
        return 0

    changed = False
    for old, new, label in ((EARLY_OLD, EARLY_NEW, "早退分支"), (LOCK_OLD, LOCK_NEW, "锁内末尾")):
        if old not in src:
            if new.split(MARK)[0].split("\n")[0] in src:
                print(f"[kernel-patch] {label} 已含补丁，跳过该处")
                continue
            print(f"[kernel-patch] 错误：{label} 锚点未找到 —— 上游结构已变，需人工核对")
            return 1
        src = src.replace(old, new, 1)
        changed = True
        print(f"[kernel-patch] {label} 已打补丁")

    if not changed:
        print("[kernel-patch] 无改动")
        return 0

    open(target, "w", encoding="utf-8").write(src)
    try:
        py_compile.compile(target, doraise=True)
    except py_compile.PyCompileError as exc:
        print(f"[kernel-patch] 错误：补丁后语法校验失败，已回滚: {exc}")
        git = os.path.join(os.path.dirname(target), "..", ".git")
        print("[kernel-patch] 请检查", target)
        return 1
    print("[kernel-patch] 完成，语法校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
