# 更新日志

本项目（MoviePilot for fnOS，v3 线）的打包版本记录。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

版本号规则：`<上游三段>.<打包段>`（如 `3.0.0.9` = 上游 v3.0.0 + 第 9 次打包修订）。早期 v2 线（1.x）已冻结，由本线全面取代。

---

## [3.0.0.18] - 2026-09-10

### 修复

- **飞牛统一网关路径网页端全接口失效（设置全空、持续「服务器无响应」）**：fnOS 1.2.x 统一网关（今晨重启补丁热应用后观测到）对携带 JWT 形状 `Authorization: Bearer` 的请求会误判为飞牛会话令牌做校验，失败即短路返回 HTTP 200 的 13 字节纯文本 `invalid token`——请求根本不到达应用。MoviePilot 前端 axios 恰好给每个 API 请求都带该头，于是经 `/app/moviepilot` 的所有数据接口全挂；`/api/v1/system/message` SSE 因只认资源 Cookie 成为唯一到达后端的请求，其 Cookie 过期后即用户看到的 403。已在真实飞牛会话浏览器内完成三组对照实验钉死（Bearer JWT 被拦 / Bearer 非 JWT 放行 / 无认证头放行），后端、数据库、外网连通性全程正常

### 变更

- **补丁 #7（后端）**：`app/adapters/web/security/access.py` 的 `verify_token` 新增 `X-MoviePilot-Token` 头依赖，在 Authorization 缺席时回退读取并按同一 JWT 语义校验；Authorization 优先级不变，非网关直连与第三方集成（`X-API-KEY`/`apikey`/`token`）不受影响
- **补丁 #8（前端）**：`public/assets/*.js` 中 axios 两处 `Authorization: Bearer ${token}` 改发 `X-MoviePilot-Token`（按内容模式匹配 minified 产物，不写死 hash 文件名；上游换版后模式失效则记录跳过）
- **新增「MoviePilot 直连」桌面入口**（`moviepilot.direct`，端口服务模式，跟随向导前端端口）：绕过统一网关直连前端，作为网关行为再度变化的兜底；直连路径仍需手动登录（无网关免登录）

## [3.0.0.17] - 2026-08-26

### 修复

- **修复 3.0.0.16 仍安装失败（同函数第二处上游缺陷）**：`_ensure_superuser_account_inner` 里 `user.update(user_oper._db, update_payload)` 把 `None` 传给模型 `Base.update`——runner 查询（`get_by_name`）在独占会话中完成后关闭，返回的 user 是游离态，`Base.update` 检测到 detached 即调 `db.add(self)` → `'NoneType' object has no attribute 'add'` → init 崩。补丁 #6 追加第二处替换：update 调用改经 `run_sync_transaction` 事务包裹（独占会话 + 提交，与上游架构语义一致）。`UserOper.add`/`get_by_name` 本就走 runner 路径，无需处理

## [3.0.0.16] - 2026-08-26

### 修复

- **修复 3.0.0.15 安装必败**：上游 v3.0.0 正式版 `local_setup.py` 的 sync-superuser 路径未注册事务执行器——`UserOper()` 无会话构造时委托 `run_sync_transaction`，而它依赖组合根先行 `configure_transaction_runners`（`app.startup` 组合根与测试引导都配了，唯独 init 路径漏配）→ `moviepilot init` 必抛「同步事务执行器尚未配置」→ 安装失败。新增构建期补丁 #6：按上游测试引导（`app/testing/bootstrap.py`）的模式在 `_ensure_superuser_account_inner` 导入 Oper 前注册 `TransactionalWriteRunner`
- init 失败时自动把 MoviePilot 运行日志尾部（含真实 traceback）附加进 install.log，便于事后排查（此前 wrapper 吞掉 Python 异常栈，弹窗只见「init 失败」）

## [3.0.0.15] - 2026-08-26

### 变更

- **跟进上游 v3.0.0 正式版**：上游于 2026-08-25 将 `v3.0.0` tag 移至正式发布代码（较 3.0.0.14 构建时的新 429 个提交）：依赖管理从 `requirements.in` 迁至 `pyproject.toml` + `uv.lock`，`requires-python >= 3.14`
- **fpk 内置 CPython 3.14 运行时**（python-build-standalone 3.14.7+20260825，双架构）：上游要求 Python ≥ 3.14，飞牛内置 Python 3.11 不再可用；设备端 venv 改由随包运行时创建（`install_callback`/`upgrade_callback` 同步改造，不再依赖系统 Python）
- **依赖锁定自上游 uv.lock**：构建管线改为 `uv export --frozen` 导出精确版本 + 按目标平台求值 marker（构建机 uv 版本须与上游 required-version 一致：0.12.5）；wheels 全面升级 cp314
- 站点资源 `.so` 跟随升级 cpython-314；构建期补丁 #1（security.access 错误导入）上游已修复自动停用，#2~#5 锚点核对全部有效

## [3.0.0.14] - 2026-08-20

### 新增

- **安装/配置向导支持自定义前后端端口**：前端网页（`NGINX_PORT`，默认 3000）与后端 API（`PORT`，默认 3001）冲突时可改——上游原生从 app.env 读这两个键，本封装补齐向导入口与联动：安装向导新增「端口设置」步骤；配置向导可改（留空不修改，变更后自动全量重启生效）；网关桥上游转发、启动端口预检、健康探活全部跟随配置端口。前后端端口相同会被拒绝

## [3.0.0.13] - 2026-08-20

### 修复

- **修复「配置访问权限授权后，网页目录浏览器仍点不开 /volN 层」**：fnOS 卷以 trimacl（btrfs 自定义 ACL）挂载，posix ACL（setfacl）在卷上不被内核执行——getfacl 可见、实际不生效，3.0.0.10~.12 的「祖先链 r-x」方案整体无效。现改为构建期补丁 #5（MP 目录浏览接口虚拟浏览）：未授权祖先层（含根目录 /）只显示授权链的下一跳虚拟目录（应用用户在这些层无列举权，也不应看到无关内容）；授权目录本体及内部返回真实列举，并过滤无权限子项（点开即空的目录/文件不再显示）

### 变更

- 授权目录数据流：config_callback 把 TRIM_DATA_ACCESSIBLE_PATHS 写入配置目录 fnos_grants.txt，授权变更即时生效、无需重启；升级时自动清理 ≤3.0.0.12 写入的无效 posix ACL 残留

## [3.0.0.12] - 2026-08-20

### 修复

- **修复 3.0.0.11 启动失败（启动即回滚）**：网关桥 pid 文件读取竞态——降权启动链（runuser 会话）建立有延迟，主脚本立即读 pid 文件拿到空值，`kill -0` 空串失败被误判为「桥已退出」，触发启动回滚把每次都成功启动的 MoviePilot 停掉。现轮询等待 pid 文件写出（最多 10s）
- 启动回滚路径同步清理可能已拉起的桥进程，不再残留孤儿桥
- **配置访问权限变更不再触发应用重启**：fnOS 配置回调会原样回传面板存量的向导字段，原逻辑「非空即视为已改」导致每次授权变更都重写 app.env 并全量重启应用（实测约 45 秒）。现与 app.env 现值比对，未变化时不动应用（授权本身零重启需求）；凭据真变化时也仅重启网关桥（秒级、网页瞬断）——MoviePilot 前后端不读该凭据（密码在数据库），无需重启

### 变更

- **网关桥降权改用 setpriv（exec 式）**：原 runuser 会作为常驻父进程挂在 node 上，且其命令行携带免登录密码——`/proc/<pid>/cmdline` 全局可读，系统内任意本地用户均可从 ps 读到明文密码。setpriv 进程自我降权后一路 exec 成 node，无常驻包装进程，凭据不再出现在任何进程命令行

## [3.0.0.11] - 2026-08-20

### 变更

- **生命周期提权 root + 服务降权**（privilege run-as root）：`cmd/main` 以 root 运行负责特权准备；MoviePilot 前后端（runuser 同步调用）与网关桥一律降权到 moviepilot 用户运行（fnOS 推荐姿势：长期对外服务保持非特权）
- **目录授权对接 fnOS 原生「配置访问权限」**：在应用设置中授权目录后，系统钩子（config_callback，`TRIM_DATA_ACCESSIBLE_PATHS`）实时同步授权目录祖先链 r-x（仅浏览可见，不开放越权读写），授权即生效、无需重启；安装/升级重放授权记录，卸载统一回收
- 取代 3.0.0.10 的向导目录授权字段方案（fnOS 面板新字段不随配置回传，该方案不可行）

## [3.0.0.10] - 2026-08-20

### 变更

- 目录授权：向导新增目录授权字段（逗号分隔路径列表），配置时以 root 逐目录授 ACL（目标目录 rwx + 默认继承，祖先链 r-x），卸载回收
- （3.0.0.11 起被原生「配置访问权限」对接方案取代）

## [3.0.0.9] - 2026-08-20

### 变更

- **应用图标全新设计**，全套尺寸（16~256px）按母图重新生成精确规格
- **移除应用配置面板中的「自动更新」开关**，并在启动层无条件关闭在线自更新（`MOVIEPILOT_AUTO_UPDATE=false` 强制生效，MoviePilot 网页内的更新勾选框同时失效）：
  在线更新会用上游原版文件覆盖本封装内置的构建期补丁，且会与离线装配的依赖锁定（payload.lock）脱钩，唯一安全更新通道 = 安装新版 fpk

## [3.0.0.8] - 2026-08-20

### 变更

- 构建期补丁锚点加固（面向上游自动跟随）：外层识别上游已采纳/已修复即自动退役；内层锚点降级到低频变动锚（`def __init__` 行、`CONFIG_WATCH` 开括号子串、数据集 URL 由类属性派生）；结构性重构时构建失败止损（fail-closed）
- 本版本无设备侧行为变化

## [3.0.0.7] - 2026-08-20

### 新增

- **AniList 中文标题数据集经 GITHUB_PROXY 加速**：上游硬编码 raw.githubusercontent.com 直连拉取 854KB 数据集，国内间歇性重置（实测 3.6~14.8 秒，失败时卡满读超时），是探索页 AniList 源首访慢的主因；现跟随 GITHUB_PROXY 设置加速拉取（留空保持直连），探索页 AniList 首访从 10~60 秒降至约 5 秒

## [3.0.0.6] - 2026-08-20

### 新增

- **Bangumi API 域名可配置**（`BANGUMI_API_DOMAIN`，默认社区镜像 `api.bangumi.lol`）：官方域名 api.bgm.tv 在国内被 DNS 污染 + SNI 重置双重封锁，真 IP 直连也被重置；默认镜像直连可用且自动改写返回内容中的图片域。介意第三方镜像者可在 `config/app.env` 改回官方域名（需自备网络环境）

## [3.0.0.5] - 2026-08-20

### 新增

- **国内网络免代理默认值**（仅首次安装缺失时写入，用户已配置的值绝不覆盖）：
  - `TMDB_API_DOMAIN=api.tmdb.org`（官方别名域名，未被污染，直连 0.7 秒）
  - `GITHUB_PROXY=https://ghproxy.net/`（插件市场/资源包加速，失效可清空回退直连）

## [3.0.0.4] - 2026-08-20

### 修复

- **配置变更后模块实例不重建**（上游缺陷）：媒体服务器/下载器改配置后坏实例滞留，接口持续 502，必须重启才生效。构建期补丁 ModuleManager 的事件 resolver 识别自身，配置变更即时热重建

## [3.0.0.3] - 2026-08-20

### 修复

- **重启后强制重新登录**：上游 `SECRET_KEY`/`RESOURCE_SECRET_KEY` 每次进程启动随机生成，登录态与图片签名全部失效。现首次安装生成并持久化到 app.env，重启/升级均保持登录

## [3.0.0.2] - 2026-08-20

### 修复

- 上游 v3.0.0 `init --superuser` 崩溃（错误导入 `security.access`，实际为 `security.token`），构建期修正
- appcenter 安装上下文中 `python3 -m venv` 静默失败：venv 三级兜底（标准 → `--without-pip` → 手工构建）

## [3.0.0.1] - 2026-08-20

### 新增

- **首个 v3 线版本**，基于上游 MoviePilot v3.0.0，整体架构与 v2 线不兼容：
  - fpk 自包含离线安装：上游源码（含构建期补丁）、前端、174 个 Python wheel（uv 按目标平台锁定）、CloakBrowser 内核、站点资源全部内置，安装无需外网、无需 SSH，1~5 分钟完成
  - CI 线上全量构建（GitHub Actions 双架构），本地与 CI 同一构建入口
  - 网关桥（gateway-bridge.js）监听 fnOS 统一网关 Unix Socket，桌面图标打开自动免登录
  - 飞牛影视（trimemedia）媒体服务器对接
  - 配置/数据落共享区，文件管理器可见

---

## v2 线（1.x，已冻结）

v2 线（1.0.0，2026-08-02）基于上游 v2 分支的 git clone + 在线安装方案，已被 v3 自包含离线方案全面取代，不再维护。
