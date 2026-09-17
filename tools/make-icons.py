#!/usr/bin/env python3
"""按 fnOS 规格生成 fnos-hermes 的整套图标（幂等，可重复跑，不依赖缓存）。

素材：assets/hermes-icon.png
      官方仓库 NousResearch/hermes-agent 的桌面端图标 apps/desktop/assets/icon.png（1024×1024，
      这是上游自带的品牌图标）。素材缺失时会尝试从 app/hermes-src 里取一份并补进 assets/。

产出（尺寸被 tools/verify-fpk.py 逐项断言，改这里必须同步改断言）：
    ICON.PNG                     512×512   ← 应用中心「应用详情页」大图标
                                             ⚠️ 必须是 512×512：256×256 会被 fnOS 判为不合格，
                                             详情页 fallback 成灰色包裹占位图（2026-09-17 真机实测）
    ICON_256.PNG                 256×256   ← 应用中心列表小图标
    icon.png                     256×256   ← fnpack 只收大写文件名，出包后由构建脚本追加进包
    app/ui/images/icon_64.png     64×64    ← 桌面/UI 入口（fnOS 按 ui/config 的 images/icon_{0}.png 取）
    app/ui/images/icon_256.png   256×256
    app/ui/images/64.png          64×64    ← 兼容旧的 images/{0}.png 写法
    app/ui/images/256.png        256×256
    app/ui/images/icon-64.png     64×64    ← 兼容连字符命名
    app/ui/images/icon-256.png   256×256

用法：python3 tools/make-icons.py        （需要 Pillow；本机用 hermes venv 的 python）
"""
import hashlib
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(REPO, "assets", "hermes-icon.png")
UPSTREAM_MASTER = os.path.join(REPO, "app", "hermes-src", "apps", "desktop", "assets", "icon.png")

# (输出路径, 边长, 用途)
TARGETS = [
    ("ICON.PNG", 512, "应用中心详情页大图标"),
    ("ICON_256.PNG", 256, "应用中心列表小图标"),
    ("icon.png", 256, "出包后追加的小写图标"),
    ("app/ui/images/icon_64.png", 64, "桌面入口 64"),
    ("app/ui/images/icon_256.png", 256, "桌面入口 256"),
    ("app/ui/images/64.png", 64, "兼容 images/{0}.png"),
    ("app/ui/images/256.png", 256, "兼容 images/{0}.png"),
    ("app/ui/images/icon-64.png", 64, "兼容连字符命名"),
    ("app/ui/images/icon-256.png", 256, "兼容连字符命名"),
]


def ensure_master():
    if os.path.isfile(MASTER):
        return MASTER
    if os.path.isfile(UPSTREAM_MASTER):
        os.makedirs(os.path.dirname(MASTER), exist_ok=True)
        shutil.copy2(UPSTREAM_MASTER, MASTER)
        print(f"素材缺失 → 从官方源码补一份: {UPSTREAM_MASTER}")
        return MASTER
    return None


def main():
    master = ensure_master()
    if not master:
        print(f"找不到图标素材（{MASTER}），先把它提交进仓库", file=sys.stderr)
        return 1
    try:
        from PIL import Image
    except ImportError:
        print("需要 Pillow（pip install pillow / uv pip install pillow）", file=sys.stderr)
        return 1

    src = Image.open(master).convert("RGBA")
    if src.width < 512:
        print(f"素材太小（{src.width}px），无法生成 512×512 的 ICON.PNG", file=sys.stderr)
        return 1
    print(f"素材 {os.path.relpath(master, REPO)}  {src.width}×{src.height}")

    for rel, size, note in TARGETS:
        out = os.path.join(REPO, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        img = src.resize((size, size), Image.LANCZOS)
        img.save(out, "PNG", optimize=True)
        data = open(out, "rb").read()
        got = Image.open(out).size
        assert got == (size, size), f"{rel} 尺寸 {got} != {size}"
        print(f"  {size:>3}×{size:<3} {rel:28s} {len(data):>7} bytes  "
              f"sha256:{hashlib.sha256(data).hexdigest()[:12]}  {note}")
    print("图标已按 fnOS 规格生成（ICON.PNG 512×512 是应用中心详情页能显示图标的关键）")
    return 0


if __name__ == "__main__":
    sys.exit(main())