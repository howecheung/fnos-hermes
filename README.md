# fnOS Hermes

把 [Nous Research 的 Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成**飞牛 fnOS 可安装的 .fpk**：内置官方源码、跟随上游版本、可在应用中心一键安装。

打包骨架源自 [veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)（→ [iranee/fnos-hermes-agent](https://github.com/iranee/fnos-hermes-agent)），本仓库做了**应用身份隔离**改造，可与官方社区包并存运行。详见 [ATTRIBUTION.md](ATTRIBUTION.md)。

## 目录

- [1. 这是什么](#1-这是什么)
  - [1.1 与社区包的关系](#11-与社区包的关系)
- [2. 安装](#2-安装)
  - [2.1 安装步骤](#21-安装步骤)
  - [2.2 首次启动](#22-首次启动)
- [3. 构建](#3-构建)
  - [3.1 环境前提](#31-环境前提)
  - [3.2 四条命令](#32-四条命令)
  - [3.3 流水线六步](#33-流水线六步)
  - [3.4 缓存策略与「真·从零构建」](#34-缓存策略与真从零构建)
- [4. 验证](#4-验证)
  - [4.1 出厂自检：37 项](#41-出厂自检37-项)
  - [4.2 升版本判卷](#42-升版本判卷)
- [5. 发布](#5-发布)
  - [5.1 三条铁律](#51-三条铁律)
  - [5.2 发版验收清单](#52-发版验收清单)
- [6. 踩坑速查](#6-踩坑速查)
  - [6.1 构建](#61-构建) ｜ [6.2 打包](#62-打包) ｜ [6.3 安装](#63-安装) ｜ [6.4 发布与交付](#64-发布与交付)
- [7. 仓库导览](#7-仓库导览)
  - [7.1 目录结构](#71-目录结构)
  - [7.2 CI：可选路径](#72-ci可选路径)
- [8. 致谢与许可](#8-致谢与许可)

---

## 1. 这是什么

一个**跟随上游**的打包仓库：每次官方发新版，改三行版本坐标、跑两条命令，就能产出一个可在飞牛应用中心安装/升级的 `.fpk`。内核源码与前端产物随包内置，因此已装实例不会因上游发新版而失效，「检查更新」走本仓库的 Release 通道。

### 1.1 与社区包的关系

| | 社区包 `hermes-agent` | 本包 `fnos-hermes` |
|---|---|---|
| 显示名 / 应用名 | Hermes Agent / `hermes-agent` | fnOS Hermes / `fnos-hermes` |
| 控制台 / Gateway / Dashboard | 8650 / 8742 / 9219 | **8660 / 8743 / 9220** |
| 运行用户、数据目录 | `hermes-agent`、`/vol1/@apphome/hermes-agent/data` | `fnos-hermes`、`/vol1/@apphome/fnos-hermes/data` |
| 进程清理范围 | — | `fnos-hermes/.+(gateway\|dashboard)`（**路径限定，不会误杀其他实例**） |

两包独立端口、独立用户、独立数据目录，互不干扰，可同时运行。

## 2. 安装

### 2.1 安装步骤

1. 到 [Releases](../../releases) 下载 `fnos-hermes_v<版本>.fpk`
2. 应用中心 → 手动安装 → 选择该 fpk（会自动装依赖 `nodejs_v24`）
3. 等待首次安装完成：在线执行 `uv venv` + `uv pip install -e "hermes-src[all]"`，需几分钟、约 750MB~1.5GB 磁盘

### 2.2 首次启动

打开「fnOS Hermes」控制台，配置模型 API Key 即可开始使用。控制台、Gateway、Dashboard 三个端口见 [1.1](#11-与社区包的关系)。

> 若提示「请先卸载应用中心版本的 XX 后再操作手动安装」，先看 `/var/apps/<appname>/manifest` 里的 `version` —— 该提示的真实含义是「已装同版本或更高版本」，并非真的要卸载（详见 [6.3](#63-安装)）。

## 3. 构建

### 3.1 环境前提

- fnOS x86_64，能访问 `codeload.github.com` / `registry.npmjs.org` / `github.com`
- Node 24 + npm（**用仓库外的受支持版本**，原因见 [6.1](#61-构建)）
- 磁盘：源码 + `node_modules` 约 500MB，出包约 58MB

### 3.2 四条命令

```bash
git clone https://github.com/howecheung/fnos-hermes.git && cd fnos-hermes

vim config/bootstrap/hermes-version.env   # 改版本坐标：HERMES_TAG / HERMES_VERSION / PKG_VERSION
bash tools/build-local.sh                 # 一条命令到底（冷构建 ~120s，同 tag 重打 ~30s）
bash tools/check-upstream-compat.sh       # 升版本判卷，红了不要发版
bash tools/publish-release.sh             # 幂等发 GitHub Release
```

产物 `dist/fnos-hermes_v<版本>.fpk`（约 58MB）。

### 3.3 流水线六步

| # | 步骤 | 关键点 |
|---|---|---|
| 1 | 取官方源码 | codeload tar.gz（比 git clone 快）→ 断点续传 + `gzip -t` 校验 → 缓存 `tools/.cache/hermes-src-<tag>.tgz` → 删 `tests/`、`website/`（省 ~70MB） |
| 2 | 前端预构建 | 上游 gitignore 了 `hermes_cli/web_dist`、`ui-tui/dist`，必须现构建（npm `build --workspace web` / `ui-tui`）；**用仓库外受支持的 npm**，见 [6.1](#61-构建) |
| 3 | 身份改写 | `tools/apply-identity.sh`：appname / 端口 / 用户 / socket / data-share / 软链 / pkill 限定 |
| 4 | 铺配置与版本 | 写 `config/bootstrap/hermes-version.env`；`config/prompts/` 的 SOUL / AGENTS / config.yaml / skills 进包 |
| 5 | 图标 + 打包 | `tools/make-icons.py` 生成全套图标 → `fnpack build` → 出包后追加小写 `icon.png` |
| 6 | 自检 + 兼容体检 | `tools/verify-fpk.py` **37 项**（红则不发版）；升版本另跑 `check-upstream-compat.sh`（6 节）+ 结构指纹 |

### 3.4 缓存策略与「真·从零构建」

**缓存只加速，绝不作为正确性依赖** —— 清空全部缓存、并绕开机器全局 npm 缓存后 `bash tools/build-local.sh --rebuild-src` 实测 **exit 0 / 119 秒**。

| 缓存（全部按 tag 命名，换版本自动失效） | 省掉 |
|---|---|
| `tools/.cache/hermes-src-<tag>.tgz`（68MB） | 重下源码 |
| `app/hermes-src/node_modules`（368MB，**不进包**） | `npm install` |
| `hermes_cli/web_dist`、`ui-tui/dist` | 同 tag 省一次前端构建 |
| `tools/.cache/fnpack`、`tools/.cache/npm-compat` | 工具重复下载 |

实测：冷构建 119s / 同 tag 重建 27s / `--rebuild-src` 35s —— 瓶颈全在下载，打包本身仅 15~18s。

## 4. 验证

### 4.1 出厂自检：37 项

`tools/verify-fpk.py` 只读、不动运行中的进程，退出码 0 = 可发版。覆盖：manifest 与版本坐标一致、执行位、app.tgz MD5、图标尺寸、身份隔离（端口 / 用户 / socket / data-share / 软链 / 无重复前缀），以及 —— 把包内所有 `pkill/pgrep` 模式对机器上**正在跑的进程**实跑，断言主实例 PID 不在命中结果里。

### 4.2 升版本判卷

- `tools/check-upstream-compat.sh`（6 节，1 秒）：① CLI 入口名 ② 子命令 `gateway`/`dashboard` ③ 前端产物路径与 TUI bundle ④ 包名与运行前提（Python / Node / npm engines）⑤ 数据面 `config.yaml`/`sessions`/`state.db` ⑥ 结构指纹基线
- `tools/upstream-fingerprint.py`：标量项变值 = FAIL；列表项少一项 = FAIL、多一项 = INFO（纯增量不用改外壳）
- **判据**：上游动*功能*（模型目录、prompt、工具、修 bug）不用管；动*接口与布局*（CLI 入口与子命令、目录与产物路径、包名、数据面、运行前提）才要改外壳
- 真机装包跑通后 `python3 tools/upstream-fingerprint.py --update` 推进基线

## 5. 发布

### 5.1 三条铁律

`tools/publish-release.sh` 幂等发版（同名 Release 复用、同名资产先删再传）。三条必须遵守：

1. 资产必须 POST 到 Release API 返回的 **`upload_url`**（`uploads.github.com`）—— 打 `api.github.com/.../assets` 会 404，且 61MB 传完才报错
2. 上传加 `--http1.1`：走代理 HTTP/2 易 `curl: (92) PROTOCOL_ERROR`
3. **必须校验 HTTP 201 + `jq -e '.browser_download_url'`**：否则空对象也让 `jq` 退出 0，会误报「上传完成: null」

### 5.2 发版验收清单

1. `python3 tools/verify-fpk.py` → 37 项全绿（构建末尾已自动跑）
2. `bash tools/check-upstream-compat.sh` → 退出码 0（仅升版本时）
3. Release 资产上传成功（HTTP 201 + 下载链接可访问）
4. 真机装包：`/var/apps/fnos-hermes/manifest` 版本正确、`ss -tlnp` 见 8660/8743/9220、**主实例 `hermes-agent` 不受影响**

## 6. 踩坑速查

### 6.1 构建

| 坑 | 解法 |
|---|---|
| 上游 `engines.npm` 是**排除区间**（`<11.10.0 \|\| >=11.17.0`），npm 对 root 项目硬失败 → `EBADENGINE` | 仓库外临时装受支持的 npm，把其 `node_modules/.bin` 前置 `PATH`（装进仓库内会被同一道门拦） |
| 官方自 v0.20.0 停发 PyPI wheel | 源码内置 + `uv pip install -e "hermes-src[all,voice]"` |
| 上游 gitignore 了前端产物 | 打包前现场构建；参照仓库的 CI 就缺这一步 |
| 下载通道速度差异极大 | 每次测速再选（实测：codeload 200KB/s、npmjs 180KB/s、git clone 55KB/s、npmmirror 347B/s 不可用） |

### 6.2 打包

| 坑 | 解法 |
|---|---|
| `usr-local-linker` 收相对 `bin/xxx`，目标必须真实存在 | venv 里 `bin/hermes`（pip console script）**绝不能改名** |
| 重叠 sed 造出双重前缀（`/tmp/fnos-fnos-fnos-hermes-…`） | 改完与上游原文全树 diff；sed BRE 里 `\.` 是字面点、`\+` 是字面量，写错会**静默不匹配** |
| 参照仓库 `cmd/*`、`app/bin/*` 常是 100644 | 打包前 `chmod 755` |
| 安装布局易搞错 | `app.tgz` 内容**直接解到 `/vol1/@appcenter/<appname>/`**（与 `cmd/` 同级），不是套一层 `app/` |

### 6.3 安装

| 坑 | 解法 |
|---|---|
| 「请先卸载应用中心版本…」提示是**误导文案** | 真实判定是「已装同版本或更高版本」，看 `/var/apps/<appname>/manifest` 的 `version` 即可，**别卸载** |
| trim-cli 装 fpk 报 `requires license confirmation` / wizard 参数 | 加 `--accept-license --custom-parameters '[]' --volume-id 1 --yes` |

### 6.4 发布与交付

| 坑 | 解法 |
|---|---|
| PAT 缺 `workflow` scope 推不了 `.github/workflows/**` | 工作流暂存 `tools/actions/build-fpk.yml`，补 scope 后 `git mv` 回去 |
| 交付副本权限 | 拷贝后 `chmod 644` + `stat -c '%A %U:%G %s %n'` 复核（`ls` 显示 `----------` 是 TrimACL 假象） |

> 上传本身的三个坑（`upload_url` / `--http1.1` / 校验返回码）见 [5.1](#51-三条铁律)。

## 7. 仓库导览

### 7.1 目录结构

```
manifest / config/            fnOS 元数据、用户与 data-share、/usr/local/bin 软链
config/bootstrap/             内置源码版本（构建脚本覆写）
config/prompts/               安装时铺到数据目录的 SOUL / AGENTS / config.yaml / skills
cmd/                          fnOS 生命周期：install/upgrade/uninstall/config/main
app/server/  app/ui/          监控守护进程 + Web API + 连接器 / 定制控制台
app/bin/fnos-hermes           CLI 包装（等价于 venv 里的 hermes）
app/hermes-src/               官方源码（构建时拉取，不入库）
tools/                        构建、自检、兼容体检、发布脚本（见上）
tools/actions/build-fpk.yml   GitHub Actions 工作流（因 PAT 缺 workflow scope 暂存此处）
```

### 7.2 CI：可选路径

`tools/actions/build-fpk.yml` 是完整可用的工作流（含参照仓库缺的**拉源码**与**生成图标**两步），因 PAT 缺 `workflow` scope 暂存普通目录。补 scope 后：

```bash
git mv tools/actions/build-fpk.yml .github/workflows/build-fpk.yml && git commit -m "启用 CI" && git push
```

**本机构建才是当前主路径**，CI 为可选补充。

## 8. 致谢与许可

- 打包骨架：[veenyi/fnos-hermes-agent](https://github.com/veenyi/fnos-hermes-agent)（→ [iranee/fnos-hermes-agent](https://github.com/iranee/fnos-hermes-agent)），见 [ATTRIBUTION.md](ATTRIBUTION.md)
- 内置内核：[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)（**MIT**，版权归 Nous Research）
- 打包代码：**GPL-3.0**，见 [LICENSE](LICENSE)