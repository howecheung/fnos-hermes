# fnOS Hermes

把 [Nous Research 的 Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成**飞牛 fnOS 可直接安装的 .fpk**，跟随官方上游源码构建，可在应用中心一键安装/升级。

> 打包骨架（fnOS 生命周期脚本、Web 控制台、监控守护进程、连接器等）**源自 [veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)**（其本身 fork 自 [iranee/fnos-hermes-agent](https://github.com/iranee/fnos-hermes-agent)）。本仓库做了应用身份隔离改造，使其可与官方 `hermes-agent` 包**并存运行**。详见 [ATTRIBUTION.md](ATTRIBUTION.md)。

## 这个包和你已有的 hermes-agent 包什么关系

| | 官方社区包 `hermes-agent` | 本包 `fnos-hermes` |
|---|---|---|
| 应用名 | hermes-agent | **fnos-hermes**（显示名「fnOS Hermes」） |
| 数据目录 | `/vol1/@apphome/hermes-agent/data` | `/vol1/@apphome/fnos-hermes/data` |
| Web 控制台 | 8650 | **8660** |
| Gateway | 8742 | **8743** |
| Dashboard | 9219 | **9220** |
| 运行用户 | hermes-agent | fnos-hermes |
| 进程清理范围 | `hermes-agent/.+(gateway\|dashboard)` | `fnos-hermes/.+(gateway\|dashboard)` |

两包**互不干扰**：独立数据目录、独立端口、独立系统用户，且所有 `pkill` 模式都限定在本应用路径内（上游骨架里的写法是 `pkill -f "hermes.*gateway"`，会误杀同机其他 Hermes 实例，本仓库已修正为路径限定）。

## 安装

1. 到 [Releases](../../releases) 下载 `fnos-hermes_v<版本>.fpk`
2. 飞牛 **应用中心 → 手动安装**，选择该 fpk
3. 依赖 `nodejs_v24`（应用中心会自动装）
4. 首次安装会在线执行 `uv venv` + `uv pip install -e "hermes-src[all]"`，需要几分钟（约 750MB~1.5GB 磁盘）

装好后从桌面/应用中心打开「fnOS Hermes」，在 Web 控制台里配置模型 API Key 即可。

## 构建（GitHub Actions）

推 tag 或手动触发 `.github/workflows/build-fpk.yml`：

- `hermes_tag`：官方源码 tag，例如 `v2026.9.14`
- `pkg_version`：本包版本号，例如 `0.21.3-1`

工作流做的事：

```
checkout 本仓库
  → git clone 官方 tag 到 app/hermes-src（该目录不进 git）
  → npm 构建 hermes_cli/web_dist（Vite）+ ui-tui/dist/entry.js
  → 清理 node_modules / __pycache__
  → 写 manifest 版本 + config/bootstrap/hermes-version.env
  → fnpack build 出包 + 追加小写 icon.png
  → 发布 Release（fnos-hermes_v<版本>.fpk）
```

## 跟进上游新版本（升版本三步）

外层外壳（`cmd/*`、`app/server`、`app/ui`）咬住内核的 6 处接口与布局，所以每跟一次上游都要过一遍「兼容性考试」：

```bash
# 1) 改版本坐标（就这三行）
vim config/bootstrap/hermes-version.env      # HERMES_TAG / HERMES_VERSION / PKG_VERSION

# 2) 构建：拉源码 → 建前端 → 改写身份 → 打包 → 出厂自检，一条命令到底
bash tools/build-local.sh        # 冷机构建约 100 秒；同 tag 重打约 30 秒

# 3) 判卷：外壳与新版内核是否还对得上（1 秒，绿了才能发版）
bash tools/check-upstream-compat.sh
```

构建末尾会自动跑 `tools/verify-fpk.py`（30 项：manifest 与版本坐标、脚本可执行位、`bin/` 指向、前端产物、端口/用户/socket/共享目录隔离、无重复前缀残留，以及**清理进程的模式会不会误杀主实例**）——最后一项是拿机器上正在跑的进程实测的，红了说明这个包会杀掉你的 `hermes-agent`，绝不能发。手动复核随时可跑：`python3 tools/verify-fpk.py [某个.fpk]`。

**构建缓存**（按 tag 命名，换 tag 自动失效；可随时删）：

| 缓存 | 位置 | 省掉 |
|---|---|---|
| 官方源码包 | `tools/.cache/hermes-src-<tag>.tgz`（68MB） | 每次重下 68MB |
| npm 依赖 | `app/hermes-src/node_modules`（368MB，**不进包**） | 每次 `npm install`（数分钟） |
| 前端产物 | `app/hermes-src/hermes_cli/web_dist`、`ui-tui/dist` | 同 tag 重打时省一次 Vite 构建（换 tag 必重建） |
| 工具 | `tools/.cache/fnpack`、`tools/.cache/npm-compat` | 工具本身重复下载 |

实测（v0.21.3）：冷构建 **99s**、同 tag 常规重建 **27s**、`--rebuild-src`（重解源码但复用依赖与产物）**35s**。

**兼容性检查包含 6 节**：① CLI 入口名 ② 子命令 `gateway`/`dashboard` ③ 前端产物路径与 TUI bundle ④ 包名与运行时前提（Python / Node / npm engines）⑤ 数据面 `config.yaml` / `sessions/` / `state.db` ⑥ **结构指纹基线比对**。

结构指纹（`tools/upstream-fingerprint.py` + `tools/upstream-fingerprint.json`）记录内核的接口与布局事实：

- **标量项**（包名、`requires-python`、vite `outDir`、产物存在性）：值变了 → FAIL
- **列表项**（CLI 入口、extras、workspace 构建脚本名、外壳引用的顶层锚点）：少一项 → FAIL，多一项 → INFO（纯增量不用改外壳）
- **参考项**（各目录文件数）：变化只提示，不拦

确认新版真机跑通（装包并验证）后，用 `python3 tools/upstream-fingerprint.py --update` 把基线推进到新版本。

> 什么时候需要动外壳：上游动**功能**（模型目录、prompt、工具、bug 修复）不用管；上游动**接口和布局**（CLI 入口/子命令、目录与产物路径、包名、数据面结构、运行前提）才要改。判据看上面第 6 节输出。

## 目录结构

```
manifest                      fnOS 应用元数据（appname/版本/依赖）
config/privilege|resource     运行用户、data-share、/usr/local/bin 软链
config/bootstrap/             内置源码版本（CI 覆写）
config/prompts/               安装时铺到数据目录的 SOUL/AGENTS/config.yaml/skills
cmd/                          fnOS 生命周期：install/upgrade/uninstall/config/main
app/server/                   监控守护进程 + Web API + 平台连接器（Node）
app/ui/                       定制的 Web 控制台
app/bin/fnos-hermes           CLI 包装（等价于 venv 里的 hermes）
app/hermes-src/               官方源码（CI 拉取，不入库）
wizard/ preview/ ICON*.PNG    安装向导、预览图、图标
tools/apply-identity.sh       应用身份改写脚本（把上游骨架改名为本包身份）
tools/build-local.sh          本机构建入口（拉源码 → 前端预构建 → fnpack，含缓存复用）
tools/check-upstream-compat.sh 升版本前的兼容性检查（6 节，红则不要发版）
tools/upstream-fingerprint.py  结构指纹基线生成/比对（--update / --check）
```

## License

打包代码沿用上游骨架的 **GPL-3.0**（见 [LICENSE](LICENSE)）；内置的 Hermes Agent 官方源码为 **MIT**（随包分发，版权归 Nous Research）。