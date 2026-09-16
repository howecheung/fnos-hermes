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

## 跟进上游新版本

1. 看官方 [releases](https://github.com/NousResearch/hermes-agent/releases) 拿到新 tag 与版本号
2. 手动触发工作流，`hermes_tag=vYYYY.M.D`、`pkg_version=<源码版本>-1`
3. 首次构建若失败，多半是上游前端构建方式变化（`web`/`ui-tui` workspace 的构建命令或产物路径），按报错调整 workflow 的 prebuild 步骤

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
```

## License

打包代码沿用上游骨架的 **GPL-3.0**（见 [LICENSE](LICENSE)）；内置的 Hermes Agent 官方源码为 **MIT**（随包分发，版权归 Nous Research）。