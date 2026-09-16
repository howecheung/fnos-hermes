# 更新说明

> 本文件随包分发，应用内「更新说明」页面读取它（按 `## vX.Y.Z` 分段）。

## v0.21.3-1

首个版本（本仓库自建打包）。

- 内置官方 Hermes Agent 源码 **v0.21.3（tag v2026.9.14）**，安装时 editable 安装
- 应用名 **fnos-hermes**，显示名「fnOS Hermes」
- 独立数据目录 `/vol1/@apphome/fnos-hermes/data`，独立系统用户 `fnos-hermes`
- 独立端口：Web 8660 / Gateway 8743 / Dashboard 9220
- 独立 Monitor socket：`fnos-hermes.sock`；CLI 软链 `/usr/local/bin/fnos-hermes`
- **可与官方社区包 hermes-agent 并存运行**，互不影响
- 安全修正：所有进程清理（pkill/pgrep）模式限定在本应用路径内，不会误杀其他 Hermes 实例
- 自更新通道指向本仓库 Releases

### 打包骨架来源

fnOS 生命周期脚本 / Web 控制台 / 监控守护等骨架复用自 [veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)（GPL-3.0），详见 ATTRIBUTION.md。