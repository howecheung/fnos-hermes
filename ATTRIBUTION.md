# 归属与来源说明（ATTRIBUTION）

本仓库（howecheung/fnos-hermes）是一个 **fnOS 打包工程**，不自研 Hermes Agent 本体，代码来源如下。

## 1. Hermes Agent 本体

- 上游：https://github.com/NousResearch/hermes-agent
- 版权：Nous Research，许可 **MIT**
- 分发方式：**不随 git 仓库分发**（`app/hermes-src/` 在 `.gitignore` 中）。构建时由 GitHub Actions 按指定 tag 从官方仓库 clone，随 `.fpk` 安装包分发源码，安装脚本以 `uv pip install -e "hermes-src[all]"` editable 安装。

## 2. fnOS 打包骨架

- 直接来源：https://github.com/veenyi/fnos-hermes-agent （许可 **GPL-3.0**）
- 上游来源：https://github.com/iranee/fnos-hermes-agent （veenyi 仓库的前身）
- 复用范围：`manifest` 结构、`cmd/*` fnOS 生命周期脚本、`app/server/*`（Node 监控守护 + Web API + 平台连接器）、`app/ui/*`（定制 Web 控制台）、`config/*`（privilege/resource/prompts 模板）、`wizard/`、`preview/`、`ICON*.PNG`、原 `build-slim.sh` 思路与 CI 流程。
- 本仓库的改动：应用身份隔离（见下），以及若干共存安全修正；改动脚本见 `tools/apply-identity.sh`，逐条保留原仓库对应代码的语义。

## 3. 本仓库相对上游骨架的改动（逐条）

| 项 | 上游骨架 | 本仓库 | 原因 |
|---|---|---|---|
| appname | `hermes-agent` | `fnos-hermes` | 与官方社区包并存安装 |
| display_name | Hermes Agent | fnOS Hermes | 区分两个包 |
| 运行用户 | hermes-agent | fnos-hermes | 独立系统用户，避免卸载互相影响 |
| Web / Gateway / Dashboard 端口 | 8650 / 8742 / 9219 | **8660 / 8743 / 9220** | 避免与官方包端口冲突 |
| 数据目录 | `@apphome/hermes-agent/data` | `@apphome/fnos-hermes/data` | 独立数据 |
| Monitor socket | `hermes-agent.sock` | `fnos-hermes.sock` | 独立 IPC |
| `/usr/local/bin` 软链 | `hermes` | `fnos-hermes` | 不覆盖官方包的 `hermes` 命令 |
| 进程清理模式 | `pkill -f "hermes.*gateway"` 等 **无路径限定** | `pkill -f "fnos-hermes/.+(gateway\|dashboard)"` | **安全修正**：原写法会误杀同机其他 Hermes 实例的进程 |
| 自更新通道 | veenyi/fnos-hermes-agent | howecheung/fnos-hermes | 指向本仓库 Releases |
| 应用中心状态同步 | `app_name='hermes-agent'` | `app_name='fnos-hermes'` | 对应本应用记录 |
| CI 源码获取 | 无（依赖本地 Windows 构建） | CI 内 clone 官方 tag | 上游 0.20.0 起源码发行，CI 构建可复现 |

## 4. 免责

本仓库为社区第三方打包，与 Nous Research 官方、飞牛官方均无隶属关系。使用风险自负。若打包骨架原作者（iranee / veenyi）对本仓库的复用方式有异议，请提 issue，我们会配合调整或移除相关内容。