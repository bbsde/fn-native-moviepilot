# MoviePilot fnOS 应用 v3 改造方案

> 状态：方案定稿（讨论共识版），待实施
> 日期：2026-08-20
> 范围：v3 分支（新建）；main 分支的 v2 打包层冻结、最终移除

---

## 1. 目标

将「NAS 安装时联网拉取上游源码现场构建」的模式，改为「GitHub Actions 线上全量构建、fpk 自包含分发、NAS 零网络安装」：

- 安装/升级全程不依赖外网（不访问 GitHub / PyPI / npm，不需要任何镜像加速）
- 移除 gh-proxy 及全部加速机制（curl shim、pip/npm 镜像、Node 镜像下载）
- 版本自动跟随上游 MoviePilot v3 release，流水线无人值守出包
- x86_64 与 aarch64 双架构 fpk，同一 release 挂双资产
- 拆包即用：SSD 卷安装约 1 分钟级，无网络变量

## 2. 已定决策总表

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 分发模型 | Actions 全量构建，fpk 自包含，NAS 端零网络 |
| 2 | Node 运行时 | `install_dep_apps=nodejs_v24`（fnOS 应用中心依赖，`/var/apps/nodejs_v24/target/bin`） |
| 3 | Python | 飞牛内置 `/usr/bin/python3`（3.11），设备端建 venv |
| 4 | venv 策略 | 方案 A：构建期备 wheels + lock，设备端离线 `pip --no-index` 安装；不用预构建 venv（规避重定位/ABI 风险） |
| 5 | ensurepip 兜底 | 预检真建测试 venv；失败回退 `--without-pip` + 随包 pip wheel 自举 |
| 6 | 版本线 | v2/v3 隔离、不做迁移；本仓库新建 v3 分支唯一活跃，仅 v3 接自动流水线；v2 冻结待移除 |
| 7 | appname | 沿用 `moviepilot`；端口 3000/3001、网关前缀 `/app/moviepilot`、共享区 `moviepilot/config`、`moviepilot/data` 均不变 |
| 8 | 版本号 | 上游三段 + 打包递增第四段（如 `3.0.0.1`）；上游段变 → 第四段重置 1；fnpack 已验证接受四段式 |
| 9 | 自更新 | 关闭：安装时写死 `MOVIEPILOT_AUTO_UPDATE=false`，向导删该项；唯一更新通道 = 安装新 fpk |
| 10 | 加速体系 | 全部移除（gh-proxy 二进制、curl shim、insteadOf、PIP/NPM 镜像、Node 镜像下载、HTTP/1.1 降级 clone） |
| 11 | 双架构 | matrix 双腿（x86: `ubuntu-latest`；arm: `ubuntu-24.04-arm` 原生 runner）；每 fpk 单架构，manifest `platform` 对应 |
| 12 | CloakBrowser | 按架构锁版本：x86_64 = `146.0.7680.177.5`，aarch64 = `146.0.7680.177.3`（均 v146 免费线） |
| 13 | payload 形态 | **单一大 tar（不压缩）放 `app/payload.tar`**，不散装平铺；安装时 `tar -xf` 流式释放到 var，一遍落盘；成功后删除回收 |
| 14 | 升级语义 | `upgrade_callback` 按「任何历史 var 内容可丢弃重铺」编写；venv 按 lock 哈希决定重建/复用；存量 v2 残留被自然消化 |

## 3. 目标架构

```
GitHub Actions（三个 workflow 分工，参考 fn-native-deepseek-harness 已验证结构）
  ├─ build-fpk.yml：可复用构建（workflow_call，inputs = appver/upstream），
  │                 matrix 双腿，出 fpk artifact；不负责发布
  ├─ release.yml：手动 dispatch / 推 tag v* → 调 build-fpk → 建 Release 挂双 fpk
  └─ auto-follow.yml（第 5 步启用）：定时 check → 变更则**先构建**，
      成功后才 tag + 建 Release；构建失败不产生任何仓库变更，
      下次定时重试；concurrency 组互斥；全程 GITHUB_TOKEN 无需 PAT

  ├─ check：上游 v3 最新 release tag vs 本仓库最新 release tag（逐段数字比较）
  │         上游段更新 → 构建 <T>.1；相同 → 跳过（手动可强制升打包段 <T>.<n+1>）
  ├─ 各架构腿独立自组装（v1 不拆独立 prep 作业，简单优先；前端重复组装约 1min 可接受）：
  │     上游 tag 源码快照（非 git）→ 读 version.py 的 FRONTEND_VERSION
  │     → 下载 MoviePilot-Frontend 对应 dist.zip
  │     → 组装成品 public/：dist + version.txt + package.json(express,
  │       express-http-proxy) + npm install --omit=dev + 写本地版 service.js
  │     （跳过上游 install frontend，规避其 api.github.com 强制查询）
  └─ build matrix（每腿先装 fnpack 静态二进制：static2.fnnas.com/fnpack/fnpack-<ver>-linux-{amd64|arm}）：
        x86_64 腿                                aarch64 腿
        ubuntu-latest                            ubuntu-24.04-arm（原生）
        wheels: pip download                     wheels: pip download（本机平台）
          --platform manylinux2014_x86_64          （aarch64 manylinux）
          --python-version 311 --only-binary
        uv 生成 lock（--python-platform 按目标平台求值 marker）
        CloakBrowser 内核 .5                     内核 .3
        resources.v3 按 x86_64+cp311 过滤         按 aarch64+cp311 过滤
        组装 payload → tar -cf payload.tar（裸 tar）
        build/src/ = 仓库 src/ + payload.tar + manifest 改写
        fnpack build → moviepilot_<ver>_x86.fpk        → moviepilot_<ver>_arm.fpk
  └─ release：同一 tag v<ver> 挂双 fpk（<appname>_<ver>_<arch>.fpk）+ sha256，
              notes = 上游 changelog + 打包层备注

NAS 安装（install_callback，零网络）
  预检：TRIM_*、nodejs_v24 可用且主版本 24、python3 ≥3.11、真建测试 venv 验 pip
  释放：tar -xf ${TRIM_APPDEST}/payload.tar -C var/MoviePilot（一遍流式落盘）
  Node：symlink .runtime/node/bin/node → /var/apps/nodejs_v24/target/bin/node
  venv：python3 -m venv（失败→ --without-pip + 随包 pip wheel 自举）
        pip install --no-index --find-links wheels -r payload.lock
  内核：释放到 CLOAKBROWSER_CACHE_DIR/chromium-<ver>/
  配置：.moviepilot.env（CONFIG_DIR=共享区）、app.env 写 MOVIEPILOT_AUTO_UPDATE=false
  init：moviepilot init --superuser .. --superuser-password .. --config-dir ..
  收尾：删 wheels、删 payload.tar、悬空 symlink 清扫（见 §7）、chown -R
```

运行链路不变：`cmd/main` → `moviepilot` CLI（后端 :3001 + 前端 :3000）→ `gateway-bridge.js` 监听 `${TRIM_APPDEST}/app.sock` 剥前缀转发（Node 改用 nodejs_v24）。

## 4. fpk 载荷与体积（x86 实测，2026-08-20 v3.0.0）

| 组成 | 实测 |
|---|---|
| payload.tar（未压缩总载荷） | 987MB / 3501 条目 |
| └ pip wheels（174 个 + lock 174 项，含 pip/wheel 兜底） | 183MB |
| └ CloakBrowser 内核裸 tar（chromium-146.0.7680.177.5） | 729MB |
| └ 前端 public/（dist + express node_modules）+ 源码 + 资源 | ~75MB |
| **fpk 成品（外层 gzip 压缩后）** | **423MB** |

- 估算期担心 fpk≈载荷总和（600~750MB），实测 fnpack 外层 gzip 把 987MB 压到 423MB（ELF 内核压缩率高，wheels 已压缩收益小）
- NAS 落盘：var 稳定约 2.4GB（payload 释放 ~990MB + venv ~1.5GB + 内核解压 ~750MB；wheels 用完即删）
- 每架构一个 fpk，互不包含；同一 release 双资产
- 安装时长：SSD 卷 ~1 分钟级（释放 + venv 装配 + init）；无网络变量

## 5. 版本方案与状态管理

- 版本 = `<上游三段>.<打包段>`，如 `3.0.0.1`
- 上游段更新（数字逐段比较，非字符串）→ 打包段重置为 1
- 打包层自身修复（上游未动）→ 手动触发「升打包段」→ `3.0.0.2`、`3.0.0.3` …
- 状态载体：本仓库 release tag（`v3.0.0.1` 式），流水线据此比较，**不回写仓库**（dsh 的 pin 文件 + bump 提交模式是备选，若日后需要更强状态再加）
- manifest `version` 由流水线改写；`changelog` 拼上游 release 说明 + 打包层备注
- 触发：初期 `workflow_dispatch` 手动为主（v3.0.0 首日质量，等 3.0.x 稳定后开 `schedule` 每日定时）+ push（打包层改动重建同版本）
- 自动跟版安全语义（auto-follow）：check 出新版 → **先构建双架构，全部成功后**才 tag + 建 Release；任一腿失败则零仓库变更、零发布，等待下次定时重试

## 6. 仓库与分支结构

```
main 分支（v2，冻结）：现结构不动，移除自动化；最终下线
v3 分支（新建，唯一活跃）：
├── .github/workflows/
│   ├── build-fpk.yml             # 可复用双架构矩阵构建（workflow_call）
│   ├── release.yml               # 手动 dispatch / tag v* → 构建 + 发布
│   └── auto-follow.yml           # 定时自动跟版（第 5 步启用）
├── build.sh                      # 本地构建入口（与流水线同一路径；
│                                  #   MP_ARCHS / MP_APPVER / MP_UPSTREAM 参数化）
├── scripts/
│   ├── assemble-payload.sh       # 源码快照/前端/wheels/内核/资源 → payload.tar
│   └── …（前端组装、lock 生成等拆分脚本）
├── src/
│   ├── app/bin/gateway-bridge.js # 保留；gh-proxy 删除
│   ├── app/ui/                   # 不变（顺带清理 icon_{0}.png 残留）
│   ├── cmd/                      # install/main/upgrade/uninstall 改写（见 §7）
│   ├── config/                   # privilege / resource 不变
│   ├── wizard/install            # 精简（见 §8）
│   ├── manifest                  # 流水线改写 version/platform/changelog；
│   │                             # 固定新增 install_dep_apps=nodejs_v24；
│   │                             # 仓库内默认 platform=x86（构建时按腿 stamp）
│   └── ICON.PNG / ICON_256.PNG
└── docs/v3-build-plan.md         # 本方案
```

**payload.tar 不入库**：仓库 src/ 保持轻量；`.gitignore` 增补 `build/`、`payload*.tar`、`cache/`；流水线（或本地 build.sh）在临时目录组装 `build/src/ = src/ + payload.tar + manifest 改写` 后 fnpack，fnpack 前清理 src/app 下任何残留 tar（dsh 实测踩坑：双架构 tar 同入包，白送 60MB+ 死重）。

## 7. 生命周期脚本改写清单

### install_callback（~600 行 → ~250 行）

删除：`install_node`/NODE_* 全套、`deploy_source`（gh-proxy clone + HTTP/1.1 降级）、`install_github_mirror_shim`、`probe_github_mirror`、PIP_MIRROR/NPM_REGISTRY、`deploy_cloakbrowser_binary` 的下载逻辑、`write_auto_update` 的向导读取。

新版流程（见 §3 安装段），关键点：

- 预检三层：环境变量 / nodejs_v24（`node -v` 主版本 24）/ Python（≥3.11 + `mktemp` 建真 venv 验 `pip --version`，非 `--help` 式弱检查）
- venv 兜底：`python3 -m venv venv` 失败或 venv/bin/pip 缺失 → `--without-pip` 重建 + `venv/bin/python wheels/pip-*.whl/pip install --no-index --find-links wheels pip` 自举
- 安装依赖绕开上游 `install deps`（其 uv 兼容层需联网装 uv），自建 venv + 原生 pip 从 lock 安装；`moviepilot` 包装脚本只认 `venv/bin/python` 存在即可
- 资源随 payload 就位（resources.v3 → 目标目录），`init` 传 `--skip-resources`
- 写死 `MOVIEPILOT_AUTO_UPDATE=false` 到 app.env
- 成功后删 wheels 与 target 的 payload.tar（失败则保留 payload.tar 供原地重试）
- **悬空 symlink 清扫**：`find "$TRIM_PKGVAR" -xtype l -delete`——appcenter 在回调返回后会 chown 遍历 var，一个 dangling symlink 就会 ENOENT 中止整个安装/升级（dsh 实战观察：应用树被清 + APP_CRASH 循环）；install/upgrade 回调出口都必须保证 var 无悬空链接

### cmd/main

- `NODE_RUNTIME_BIN` → `/var/apps/nodejs_v24/target/bin`
- 删 `LOCAL_BIN_DIR` PATH 段与 curl shim 引用；删 `MOVIEPILOT_AUTO_UPDATE` 运行时读取/export 段
- 其余保留：start/stop/status、网关桥启停与免登录凭据、端口预检/强清/等待释放

### upgrade_callback

- 保留：chown target、清 app.sock
- 新增：释放新 payload 覆盖 MP_ROOT（dsh 同款语义：`rm -rf` + 重解包，任何历史内容可丢弃——存量 v2 的 git 检出/旧 venv 自然被替换）；lock 哈希对比决定 venv 重建或复用；删旧 wheels/payload.tar；悬空 symlink 清扫（同 install，chown 遍历陷阱在升级路径同样存在）
- 删除：curl shim 补装块

### uninstall_callback

- 基本不变（停网关桥、`moviepilot stop` 兜底、清 var）；去掉 @apphome/nodejs 引用

## 8. 向导与 manifest 变更

**wizard/install**：

- 删 `wizard_auto_update` 字段
- tips 改写：离线安装说明（约 1~5 分钟，无需外网）+「应用更新方式 = 下载安装新版 fpk」
- 保留 `wizard_superuser` / `wizard_password`

**manifest**：

- 固定：`install_dep_apps=nodejs_v24`、`os_min_version=1.1.3100`、`desktop_uidir=ui` 等
- 流水线改写：`version`、`platform`（x86/arm 按腿）、`changelog`

## 9. 真机验证清单

| # | 项目 | 说明 |
|---|---|---|
| 1 | x86 全新安装 | SSD 与 HDD 卷各测一次，记录时长 |
| 2 | 断网安装 | 拔外网装 fpk，应成功 |
| 3 | 四段版本 | fnOS 应用中心对 `3.0.0.1` 的显示与升级排序 |
| 4 | 错架构拒装 | x86 设备装 arm fpk 的行为 |
| 5 | 升级链路 | 同 lock（venv 复用快路径）/ 变 lock（重建）各测一次 |
| 6 | 存量 v2 原地升 v3 包 | 验证不炸（不做迁移；config 共享区由上游 alembic 处理，行为以观察为准） |
| 7 | ARM 设备 | 应用中心是否提供 nodejs_v24；内置 Python 是否 3.11；安装+运行全链路 |
| 8 | 网页内更新入口 | 点击应得到无害报错（非 git 快照），确认无半更新状态 |

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| 个别依赖缺 aarch64 wheel（sdist-only） | 构建期 `--only-binary` 即时暴露；兜底：bookworm 容器内构建 wheel（流水线预留步骤） |
| fnOS 系统更新将内置 Python 升到 3.12+ | wheels 全线 cp311 失效：安装期 pip 明确报错（非运行期炸）；流水线参数化 Python 版本重出 cp312 |
| fnOS 对 ~700MB fpk 的安装体验（下载进度/超时） | 真机验证项 #1；GitHub Release 分发本身无 2GB 限制 |
| v3 上游本身不稳定（3.0.0 首日质量） | 初期手动触发发布；等 3.0.x 稳定后开定时自动跟版 |
| 上游 v3 打包机制再变（local_setup 结构调整） | 流水线对上游的耦合集中在 prep 阶段，单点可修 |

## 11. 实施顺序

1. **脚本改写**：新建 v3 分支；改 install_callback / cmd/main / upgrade_callback / uninstall_callback / wizard / manifest（本阶段不依赖流水线，可用最小假 payload 本地 fnpack 验证结构与 fnpack 大包行为）
2. **payload 组装脚本化**：scripts/assemble-payload.sh + build.sh（源码/前端/wheels/内核/资源的抓取与组装），本地可跑（x86）
3. **流水线 v1**：build-fpk.yml（先 x86 单腿）+ release.yml（workflow_dispatch 手动发布）；CI 内 fnpack 用 static2.fnnas.com 静态二进制；跑通后以真实产物精确化体积表
4. **真机验证**：§9 清单 #1~#6、#8
5. **arm 腿 + release 自动化**：matrix 补 aarch64；auto-follow.yml（先构建后提交语义 + concurrency）；按稳定情况开 schedule
6. **收尾**：README/AGENTS.md 更新；main 分支 v2 冻结声明（下线时间另行决定）

## 12. 参考实现：fn-native-deepseek-harness

同作者仓库 `D:\projects\fn-native-deepseek-harness`（DeepSeek Harness fpk，已上架），与本项目改造高度同构，以下模式直接借鉴（均已实战验证）：

| 模式 | 出处 | 本方案落点 |
|---|---|---|
| workflow 三件套：可复用 build-fpk（workflow_call + matrix）/ release（tag + dispatch）/ auto-follow（定时） | `.github/workflows/*.yml` | §3、§11 步骤 3/5 |
| auto-follow「先构建、后提交」：全部成功才 tag + Release，失败零变更下次重试；GITHUB_TOKEN 即可，无 PAT；concurrency 互斥；错峰 cron | `auto-follow.yml` | §5 |
| fnpack 静态安装：`https://static2.fnnas.com/fnpack/fnpack-<ver>-linux-{amd64\|arm}` | `build-fpk.yml` | §3 build 段 |
| 单文件 tar 载荷：33k 文件平铺使 fnOS 安装分钟级（逐文件校验 + ACL），单 tar 数秒装完、释放 <1min | `src/app/runtime.tar.gz` + `pack-runtime.mjs` | 决策 #13 的独立佐证 |
| 释放即全量覆盖：`rm -rf` + 重解包，var 无条件重铺 | `install_callback` / `upgrade_callback` | 决策 #14 |
| 悬空 symlink 致 appcenter chown 遍历 ENOENT 中止（树被清 + APP_CRASH 循环）：回调出口 `find -xtype l -delete` | `upgrade_callback` 注释 | §7 |
| fnpack 前清理 src/app 残留 tar（曾双架构 tar 同入双包，白送 60MB+） | `build.sh` | §6 |
| 仓库内 manifest 默认 `platform=x86`，构建按腿 stamp、构建后还原 | `build.sh` | §6 |
| 四段版本先例：`version=0.1.0-rc.7.15` 已上架运行 | `src/manifest` | 决策 #8 |
| fpk 命名 `<appname>_<appver>_<arch>.fpk` + `.info.txt` 边车 | `build.sh` | §3 |
| build.sh 本地/CI 单一入口，`APPVER/UPSTREAM/ARCHS` 环境变量参数化 | `build.sh` | §6 |
| Windows 本地构建：GNU tar 把 `D:/...` 当 `host:path` 远程语法，必须相对路径 + cwd | `pack-runtime.mjs` | 步骤 2 本地调试注意 |

差异点（不照搬）：dsh 用 package.json `dshVersion` pin + bump 提交回写仓库，本方案按既定决策用 release tag 作唯一状态、不回写（§5）；dsh 载荷 gzip（`tar xzf`），本方案 payload.tar 不压缩（内容皆已压缩格式，省一遍设备端解压 CPU）。

## 13. 构建实测备忘（2026-08-20 首跑踩坑，均已在 assemble-payload.sh 固化）

| 坑 | 现象 | 固化的对策 |
|---|---|---|
| pip 跨平台下载不重算 marker | `--platform/--python-version` 只影响 wheel 标签匹配，环境 marker（sys_platform/platform_system）仍按**宿主**求值：Windows 构建机把 docker 的 `pywin32; sys_platform=="win32"` 传递依赖拉进来且无 Linux wheel | lock 用 `uv pip compile --python-platform x86_64-unknown-linux-gnu --python-version 3.11` 生成（marker 按目标平台求值） |
| pip download 会对 lock 重走依赖图 | 即便版本全钉死，`pip download -r lock` 仍解析传递依赖 → 宿主 marker 问题复现 | 批量下载加 `--no-deps`（uv lock 已是完整闭包，按清单取 wheel 即可） |
| 镜像源同步滞后 | uv 解析出的 langgraph-sdk 0.4.3 在阿里云镜像上还不存在 | pip/uv 一律直连 pypi.org（`MP_PYPI_INDEX` 可覆盖） |
| sdist-only 纯 Python 依赖 | anitopy/crcmod/http-ece/oss2/pinyin2hanzi 等只发 sdist，`--only-binary` 直接失败 | 批量失败 → 逐项回退：本地 `pip wheel` 建轮，产物 plat=any 才收（C 扩展 sdist-only 明确报错走 CI Linux 腿） |
| MSYS(noacl) 执行位 | Windows 构建机 chmod 对 ELF 无效（仅 shebang 文件自动获得执行位），内核 chrome 进 tar 变 644 | 内核树打包 `tar --mode=755` 强制统一模式 + 内层 tar 断言；moviepilot wrapper 靠 shebang 特性天然带 rwx，同样有断言兜底 |
| 原生 Windows 工具不认 MSYS 路径 | python/uv 收到 `/d/...` 路径直接 FileNotFoundError | 所有 python/uv 调用一律「cd + 相对路径」 |
| lock 先写会被误判缓存完整 | 解析产物先落盘，下载中断后重跑命中「已缓存」跳过 | lock 先写 `lock.staging`，下载闭包完整后才转正 |
| 上游 v3.0.0 init 缺陷 | `local_setup.py:2504` 引用不存在的 `app.application.security.access`（实际在 `security.token`），`init --superuser` 必炸（Docker 用户不跑 local_setup 故上游未察觉） | 构建期 sed 修正（stage_source 内，上游修复后自动失效） |
| appcenter 上下文 venv 静默失败 | appcenter 安装环境里 `python3 -m venv` 两种模式均无输出失败（手动 root / moviepilot 用户 / 精简 PATH 均正常，成因未明） | venv 三级兜底：标准 → `--without-pip` → **手工构建**（pyvenv.cfg + bin/python 链接，不依赖 venv 模块）；手工路径已在真机验证；失败时记录 user/HOME/TMPDIR/PATH 快照 |
| 上游 v3.0.0 媒体服务器实例缓存缺陷 | 配置错误时创建的模块实例以失败状态被缓存，改对配置后不重建 → library/sync 全部 502「媒体服务器请求失败」。根因：ModuleManager 订阅了自身 `handle_config_changed`，但其注册的事件 resolver 只匹配受管模块类（app/modules/*），不认自身类 → 处理器被事件系统永久跳过（Emby/Jellyfin/下载器同理） | **构建期补丁已修复**（3.0.0.4）：resolver 先识别自身类；真机端到端验证坏密码→502、改回→立即 200 无需重启。上游修复后锚点消失自动停用 |
| 上游密钥不持久化 | `SECRET_KEY`/`RESOURCE_SECRET_KEY` 默认每次进程启动随机生成 → 重启后所有 JWT 与图片签名失效，被迫重新登录 | install/upgrade 回调首生成后写入 app.env（已有值绝不覆盖）；真机验证 token 跨重启存活 |
| 上游数据源国内可达性分层（2026-08 真机实测，拆梯子状态） | api.themoviedb.org：DNS 污染（解析到 Facebook/Dropbox 网段，TCP 不通）；**api.tmdb.org（TMDB 官方别名）：直连 0.7s 可用**；raw.githubusercontent.com：间歇性重置（4 测 2 断）→ 插件市场时好时坏；graphql.anilist.co：直连可用（首访慢是模块先试 trace.moe 中文代理被 403 再回退官方，非故障）；api.bgm.tv：DNS 污染 + **SNI 重置**双重封锁（裸 TCP 连 Cloudflare IP 通、带 SNI 的 ClientHello 立即 RST），且 bangumi 模块 `_base_url` 硬编码无自定义地址口 → 无梯子不可用 | install/upgrade 回调默认写入 `TMDB_API_DOMAIN='api.tmdb.org'` 与 `GITHUB_PROXY='https://ghproxy.net/'`（仅缺失时写入，用户已改的值绝不覆盖，3.0.0.5）；ghproxy.net 为当日实测最快镜像（ghfast.top 黑名单 / ghproxy.cn 返回插页 / mirror.ghproxy.com 超时），镜像失效时 设定→高级设置→网络 清除或更换即自动回退直连策略；探索页番剧需求用 AniList/豆瓣替代 Bangumi；另注：MP 内置 DoH 默认解析器（1.1.1.1/9.9.9.9 等）在国内本身不可达，勿指望它救污染域名 |
| 桥看门狗自杀后需正规启停 | 前端长时间不可达时网关桥主动退出（等 fnOS 拉起）；若用 moviepilot CLI 直接重启后端绕过 fnOS，桥不会复活 → 网关 Bad Gateway | 设备侧操作一律走 `sudo appcenter-cli stop/start moviepilot`，勿直接 CLI 重启后端 |
