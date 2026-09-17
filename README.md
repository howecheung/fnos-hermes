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

---

# 构建

## 快速开始

```bash
git clone https://github.com/howecheung/fnos-hermes.git && cd fnos-hermes

# 1) 改版本坐标（就这三行：HERMES_TAG / HERMES_VERSION / PKG_VERSION）
vim config/bootstrap/hermes-version.env

# 2) 一条命令到底：拉源码 → 前端预构建 → 身份改写 → 图标 → fnpack → 出厂自检
bash tools/build-local.sh          # 冷构建约 120 秒；同 tag 重打 27~35 秒

# 3) 升版本判卷：外壳与新版内核是否还对得上（1 秒，红了不要发版）
bash tools/check-upstream-compat.sh

# 4) 发布（幂等，同名 Release 复用、同名资产先删再传）
bash tools/publish-release.sh
```

产物：`dist/fnos-hermes_v<版本>.fpk`（约 58MB）。

## 六步流水线（`tools/build-local.sh` 内部做的事）

| # | 步骤 | 细节 |
|---|---|---|
| 1 | **取官方源码** | 优先 `https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/<tag>`（比 `git clone` 快数倍），断点续传 + 重试 + `gzip -t` 完整性校验，缓存为 `tools/.cache/hermes-src-<tag>.tgz`；解开到 `app/hermes-src/`，删掉运行时无关的 `tests/`、`website/`（约省 70MB），写标记文件 `.fnos-src-tag` |
| 2 | **前端预构建** | 上游把前端产物（`hermes_cli/web_dist`、`ui-tui/dist/entry.js`）`.gitignore` 掉了，必须现场构建：`npm install` → `npm run build --workspace web`（Vite）→ `npm run build --workspace ui-tui`（先 `build:ink`）。**用仓库外的 npm**（见坑 1） |
| 3 | **应用身份改写** | `tools/apply-identity.sh`：appname、显示名、端口（8660/8743/9220）、系统用户、socket、data-share、`/usr/local/bin` 软链、`pkill/pgrep` 路径限定，全部换成 `fnos-hermes` 身份 |
| 4 | **铺配置与版本** | `config/bootstrap/hermes-version.env` 写入本次 tag/版本；`config/prompts/` 的 SOUL/AGENTS/config.yaml/skills 铺进包内，安装时落到应用数据目录 |
| 5 | **图标 + 打包** | `tools/make-icons.py` 一次生成整套图标（`ICON.PNG` 512×512、`ICON_256.PNG` 256×256、`ui/images/icon_64.png` 64、`icon_256.png` 256）；干净暂存目录打包（排除 `.git`、`node_modules`）→ `fnpack build` → 出包后追加小写 `icon.png` |
| 6 | **自检 + 兼容体检** | 构建末尾自动跑 `tools/verify-fpk.py`（**37 项**断言，红了直接退出不发版）；升版本另跑 `tools/check-upstream-compat.sh`（6 节）+ 结构指纹比对 |

## 缓存与「真·从零构建」

缓存只是加速手段，**绝不作为正确性依赖** —— 清空全部缓存后 `bash tools/build-local.sh --rebuild-src` 实测 exit 0、**119 秒**跑通。

| 缓存 | 位置 | 省掉 |
|---|---|---|
| 官方源码包 | `tools/.cache/hermes-src-<tag>.tgz`（68MB） | 每次重下 68MB |
| npm 依赖 | `app/hermes-src/node_modules`（368MB，**不进包**） | 每次 `npm install`（数分钟） |
| 前端产物 | `app/hermes-src/hermes_cli/web_dist`、`ui-tui/dist` | 同 tag 重打时省一次 Vite 构建（**换 tag 必重建**） |
| 工具 | `tools/.cache/fnpack`、`tools/.cache/npm-compat` | 工具本身重复下载 |

缓存全部按 tag 命名 → 换版本自动失效。实测：冷构建 **119s**、同 tag 常规重建 **27s**、`--rebuild-src`（重解源码、复用依赖与产物）**35s**。

> 真零缓存验收口径：连机器全局 npm 缓存也绕开（`npm_config_cache` 指向空目录），才算「只有系统 + Node 运行时」的从零构建。

## 出厂自检：`tools/verify-fpk.py`（37 项）

解包核对，只读、不动运行中的进程，退出码 0 = 可发版：

- **结构**：manifest 的 `icon` 所指文件存在、`cmd/*` 与 `app/bin/*` 可执行位、app.tgz 的 MD5 == manifest `checksum`
- **图标**：`ICON.PNG` 512×512、`ICON_256.PNG` 256×256、`ui/images/icon_64.png` 64×64、`icon_256.png` 256×256、`ui/config` 模板能解析到真实文件（尺寸不对直接 FAIL）
- **身份隔离**：端口只用 8660/8743/9220（不出现主实例的 8650/8742/9219）、socket 名、`/app/fnos-hermes` 前缀、运行用户、data-share、软链指向、无 `fnos-fnos` 重复前缀残留
- **不误杀主实例**：把包内所有 `pkill/pgrep` 模式提取出来，对机器上**正在跑的进程** `pgrep -f` 实跑一遍，断言主实例 PID 不在命中结果里

## 跟进上游新版本（升版本三步）

外层外壳（`cmd/*`、`app/server`、`app/ui`）咬住内核的 6 处接口与布局，所以每跟一次上游都要过一遍「兼容性考试」：

```bash
# 1) 改版本坐标（就这三行）
vim config/bootstrap/hermes-version.env      # HERMES_TAG / HERMES_VERSION / PKG_VERSION

# 2) 构建
bash tools/build-local.sh

# 3) 判卷（1 秒，绿了才能发版）
bash tools/check-upstream-compat.sh
```

**兼容性检查 6 节**：① CLI 入口名 ② 子命令 `gateway`/`dashboard` ③ 前端产物路径与 TUI bundle ④ 包名与运行时前提（Python / Node / npm engines）⑤ 数据面 `config.yaml` / `sessions/` / `state.db` ⑥ 结构指纹基线比对。

结构指纹（`tools/upstream-fingerprint.py` + `tools/upstream-fingerprint.json`）记录内核的接口与布局事实：

- **标量项**（包名、`requires-python`、vite `outDir`、产物存在性）：值变了 → FAIL
- **列表项**（CLI 入口、extras、workspace 构建脚本名、外壳引用的顶层锚点）：少一项 → FAIL，多一项 → INFO（纯增量不用改外壳）
- **参考项**（各目录文件数）：变化只提示，不拦

确认新版真机跑通（装包并验证）后，用 `python3 tools/upstream-fingerprint.py --update` 把基线推进到新版本。

> 什么时候需要动外壳：上游动**功能**（模型目录、prompt、工具、bug 修复）不用管；上游动**接口和布局**（CLI 入口/子命令、目录与产物路径、包名、数据面结构、运行前提）才要改。判据看第 6 节输出。
>
> 已装好的实例**不会**因为上游发新版而失效：内核源码（123MB）与前端产物都随包内置，版本锁死；应用中心「检查更新」走的是**本仓库**的 Release 通道。

## 发布 Release

`tools/publish-release.sh` 幂等发版：tag 取 `config/bootstrap/hermes-version.env` 的 `PKG_VERSION`，同名 Release 复用、同名资产先删再传。61MB 经代理上传约 50~85 秒。

三个必须遵守的点（脚本里已固化，照抄别改）：

1. 资产必须 POST 到 Release API 返回的 `upload_url`（`uploads.github.com`）—— 打 `api.github.com/.../releases/<id>/assets` 会 **404**，而且 61MB 传完才报错
2. 上传加 `--http1.1`：走代理时 HTTP/2 容易 `curl: (92) PROTOCOL_ERROR`
3. **必须校验 HTTP 码（201）+ `jq -e '.browser_download_url'`**：`curl` 不加 `-f` 时拿到的是错误 JSON，`jq -r .name` 对空对象照样退出 0，会误报「上传完成: null」

## 目录结构

```
manifest                      fnOS 应用元数据（appname/版本/依赖）
config/privilege|resource     运行用户、data-share、/usr/local/bin 软链
config/bootstrap/             内置源码版本（构建脚本覆写）
config/prompts/               安装时铺到数据目录的 SOUL/AGENTS/config.yaml/skills
cmd/                          fnOS 生命周期：install/upgrade/uninstall/config/main
app/server/                   监控守护进程 + Web API + 平台连接器（Node）
app/ui/                       定制的 Web 控制台
app/bin/fnos-hermes           CLI 包装（等价于 venv 里的 hermes）
app/hermes-src/               官方源码（构建时拉取，不入库）
wizard/ preview/ ICON*.PNG    安装向导、预览图、图标
tools/apply-identity.sh       应用身份改写脚本（把上游骨架改名为本包身份）
tools/build-local.sh          本机构建入口（拉源码 → 前端预构建 → fnpack，含缓存复用）
tools/check-upstream-compat.sh 升版本前的兼容性检查（6 节，红则不要发版）
tools/upstream-fingerprint.py  结构指纹基线生成/比对（--update / --check）
tools/verify-fpk.py           出厂自检（37 项，构建末尾自动跑）
tools/publish-release.sh      幂等发 GitHub Release
tools/actions/build-fpk.yml   GitHub Actions 工作流（因 PAT 缺 workflow scope 暂存此处，见坑 20）
```

## CI（GitHub Actions）

`tools/actions/build-fpk.yml` 是一份完整可用的工作流（含**拉官方源码**与**生成图标**两个参照仓库缺失的步骤）。它没放在 `.github/workflows/` 是因为当前 PAT 没有 `workflow` scope，GitHub 会拒绝推送该目录下的文件。给 PAT 补上 `workflow` scope 后：

```bash
git mv tools/actions/build-fpk.yml .github/workflows/build-fpk.yml && git commit -m "启用 CI" && git push
```

**本机构建（`tools/build-local.sh`）才是当前主路径**，CI 只是可选补充。

---

# 踩过的坑

## 构建

1. **上游 `package.json` 的 `engines.npm` 是排除区间，npm 会硬失败**。hermes-agent 写的是 `<11.10.0 || >=11.17.0`，而 npm 对 **root 项目**的 engines 是硬门（依赖只 warn）：本机 npm 11.12.1 正好落在排除段 → `npm error code EBADENGINE`，前端构建第一步就死。**不要改上游源码**，改为在**仓库外**的临时目录装一个受支持的 npm（`npm init -y && npm install npm@11.19.1`）并把它的 `node_modules/.bin` 前置进 `PATH`；装进仓库内会被同一道门拦下（鸡生蛋）。`Unknown project config min-release-age-exclude` 只是噪音，别当根因。
2. **官方自 v0.20.0 起停发 PyPI wheel**，无法 `pip install hermes-agent`，只能把源码整包内置并 `uv pip install -e "hermes-src[all,voice]"`（editable 安装不触发 `bdist_wheel` 守卫）。
3. **前端产物被上游 `.gitignore` 忽略**（`hermes_cli/web_dist`、`ui-tui/dist/entry.js`），必须打包前现场构建；`ui-tui` 要先跑 `build:ink` 再 `build`。这也是本仓库 CI 必须补的那一步——参照仓库的 workflow 里就没有拉源码与构建产物。
4. **下载通道每次实测再选**：实测 `git clone` 走代理约 55KB/s、`codeload` tar.gz 约 200KB/s、`registry.npmjs.org` 约 180KB/s，而 `registry.npmmirror.com` 反而只有 347B/s。别记死结论，用 15~20 秒探针测速。
5. **别默认参照仓库的 CI 能用**：它缺拉源码步骤、`app/hermes-src/` 被 `.gitignore` 排除、`ICON.PNG` 未提交 → 从零跑必然出不了包。

## 打包

6. **`ICON.PNG` 缺失 fnpack 直接失败**（`Required file ICON.PNG is missing`）：manifest 的 `icon` 所指文件必须真实存在。参照仓库就是漏提交了它（本地有、没入库），所以构建脚本里做了自愈 `[ -f ICON.PNG ] || cp ICON_256.PNG ICON.PNG`，同时把 `ICON.PNG` 提交进本仓库。
7. **fnpack 只收大写图标**：`ICON.PNG` / `ICON_256.PNG`。小写 `icon.png` 由构建脚本在出包后追加进 `app.tgz` 再打回。
8. **`config/resource` 的 `usr-local-linker` 按相对 bin 路径建软链**（`bin/fnos-hermes` → `/usr/local/bin/fnos-hermes`）：改名后 `app/bin/fnos-hermes` 必须真实存在，否则软链落空。同时 venv 里的 `bin/hermes`（pip console script）**绝不能改名**——它是内核的 CLI 入口。
9. **重叠 sed 会造出双重前缀**：宽泛的 `hermes`→新名 规则叠加命中，把 `/tmp/hermes-appcenter-sudoers` 改成了 `/tmp/fnos-fnos-fnos-hermes-appcenter-sudoers`。改完必须与上游原文做全树 diff 审计 + `grep -rnE 'fnos-fnos|hermes-hermes'` 自查。另外 **sed BRE 里 `\\.` 是字面点、`\+`/`(`/`|` 本就是字面量**，写成 `\\.\+` 会变成「一个或多个点」并**静默不匹配**。
10. **参照仓库的 `cmd/*`、`app/bin/*` 常是 100644**（Windows 侧产出的仓不保执行位）→ 打包前统一 `chmod 755`（自检脚本已断言）。
11. **`ui/images` 用下划线命名且尺寸要精确**：`icon_64.png`（不是 `icon-64.png`）、`icon_256.png`，尺寸错了或被连字符命名都不会显示；`app/ui/config` 里写 `"icon": "images/icon_{0}.png"`，`{0}` 会被替换成 `64`/`256`。
12. **真实安装布局别搞错**：`app.tgz` 的内容**直接解到 `/vol1/@appcenter/<appname>/` 根目录（与 `cmd/` 同级）**，不是套一层 `app/`。自己写模拟安装验证时按这个布局，否则 `cmd/main` 会 `MODULE_NOT_FOUND`。

## 图标

13. **图标显示不出来，先怀疑客户端缓存，不是图标规格**（本项目最大的一处误判）：
    - 应用中心详情页的图标 URL 是 `/app-center-static/icon/<appName>/icon.png`，该路由**把 `/var/apps/<appName>/ICON.PNG` 原样返回**（无缩放无缓存）——把日志里各应用该路由的响应字节数与磁盘上 `ICON.PNG` 的 `stat -c %s` 逐一比对即可证明，9 个应用全部精确相等。
    - 该路由需要登录态：未登录 curl 会先 80 端口 302 到 5666、再在 5666 上返回 **401**（不是 404），别当成打包缺陷反复排查。
    - **512×512 不是「显示得出」的必要条件**：256×256 的 `hermes-agent` 显示正常。规格照官方做（512/256/64），但**验证图标一律用浏览器打开网页版控制台**；手机端飞牛 App 会缓存旧灰占位图，杀掉重开也未必刷新，清缓存后才恢复。
14. **图标规格表**（`tools/make-icons.py` 一次生成，幂等）：

    | 文件 | 尺寸 |
    |---|---|
    | `ICON.PNG` | 512×512 |
    | `ICON_256.PNG` | 256×256 |
    | `icon.png`（小写，出包后追加） | 256×256 |
    | `app/ui/images/icon_64.png` | 64×64 |
    | `app/ui/images/icon_256.png` | 256×256 |

## 安装

15. **「请先卸载应用中心版本的 fnos-hermes 后再操作手动安装」这句提示是假的**：fnOS 前端真实判定是 `if (installed && !installedInfo?.canUpgrade)` → 即**已装同版本或更高版本**，文案由 `installedInfo.manualInstall` 分支决定，跟来源没关系。先 `head -60 /var/apps/<appname>/manifest` 看 `version`，若已等于目标版本，说明升级早就成功了，**不用卸载**。（文案 key：`/usr/trim/www/locales/zh-CN/apps/app-center.json` 的 `manualInstall.cannotInstallContent2`）
16. **手动装 fpk 的两个确认门槛**（用 trim-cli 装时）：报 `requires license confirmation` → 加 `--accept-license`；报 `requires custom wizard parameters; install from UI` → 加 `--custom-parameters '[]'`（向导全是 tips、无输入项时给空数组即可，不必去 UI）。完整命令：`trim-cli app install-fpk <fpk> --volume-id 1 --accept-license --custom-parameters '[]' --yes`。
17. **绝不能误杀主实例**：与另一个 Hermes 实例同机并存时，任何 `pkill/pgrep` 都要带本应用路径前缀。自检里有一条是拿机器上**正在跑的进程**实测模式命中集的——`verify-fpk.py` 报绿才敢发版。

## 发布与交付

18. **Release 资产上传打错端点会白传**（见上文「发布 Release」三条）。
19. **PAT 缺 `workflow` scope 时推不了 `.github/workflows/**`**（GitHub 直接 reject：`refusing to allow a Personal Access Token to create or update workflow`）→ 工作流 YAML 先放普通目录 `tools/actions/` 推上去，补 scope 后再 `git mv` 回 `.github/workflows/`。
20. **交付副本权限**：把 fpk 拷到用户目录（如 `/vol1/1000/Hermes Work Place/`）后必须 `chmod 644`，并用 `stat -c '%A %U:%G %s %n'` 复核 —— 该目录下 `ls` 会把同级目录显示成 `----------`（TrimACL 假象），`stat` 才是真权限。

## License

打包代码沿用上游骨架的 **GPL-3.0**（见 [LICENSE](LICENSE)）；内置的 Hermes Agent 官方源码为 **MIT**（随包分发，版权归 Nous Research）。