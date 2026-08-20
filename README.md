# fn-native-moviepilot

基于飞牛 fnOS Native 框架封装的 [MoviePilot](https://github.com/jxxghp/MoviePilot) 应用，以原生进程方式在 fnOS 上运行，提供资源搜索、订阅、整理、刮削、转移与通知等自动化媒体管理能力。

## 应用信息

| 项 | 值 |
| --- | --- |
| appname | `moviepilot` |
| 运行模式 | Native 进程 |
| 平台 | x86 |
| 访问方式 | fnOS 统一网关 `/app/moviepilot` |
| 数据共享 | `moviepilot/config`、`moviepilot/data` |
| 运行用户 | `moviepilot`（package） |
| 依赖 | `nodejs_v24`（安装时自动拉取） |

管理员账号在安装向导中设置。若未通过向导安装，默认账号 `admin`，密码 `moviepilot123`，首次登录后请及时修改。

## 工作原理

MoviePilot v2 自带完整的本地（非 Docker）安装与运行系统（`scripts/local_setup.py` + `moviepilot` CLI）。本应用是对它的**薄封装**：

- **安装**：`install_callback` 用 git clone 拉取 v2 分支源码，调用上游 `moviepilot setup` 完成虚拟环境、Python 依赖、CloakBrowser 内核、前端、资源配置
- **运行**：`cmd/main` 委托 `moviepilot` CLI 管理进程（后端 Python/FastAPI :3001 + 前端 Node/express :3000），随后启动 `gateway-bridge.js` 监听 fnOS 网关 Unix Socket
- **访问**：通过 fnOS 统一网关 `/app/moviepilot`（浏览器 → fnOS 网关 → Unix Socket → 网关桥剥前缀 → 前端）
- **更新**：git 部署，支持通过 MoviePilot 网页或 `moviepilot update` 在线更新（网关桥位于应用 target 目录，上游更新不会触碰它）

### 网桥免登录

通过 fnOS 桌面应用图标打开 MoviePilot 时**自动以管理员账号登录**，无需手动输密码。局域网直连 `http://<NAS-IP>:3000` 仍需手动登录。

**实现原理**（零源码 patch，全程不修改 MoviePilot 前后端代码）：

1. 安装向导收集的 `wizard_superuser` / `wizard_password` 由 `moviepilot setup` 写入 `app.env` 的 `SUPERUSER` / `SUPERUSER_PASSWORD`
2. `cmd/main` 启动网关桥时从 `app.env` 读取这两个字段，注入为 `BRIDGE_LOGIN_USER` / `BRIDGE_LOGIN_PASS` 环境变量
3. 网关桥（`gateway-bridge.js`）收到 HTML 入口请求时，用该凭据 `POST /api/v1/login/access-token` 换取完整登录态（JWT + 用户信息，8 天有效，缓存复用）
4. 桥把登录态以 inline `<script>` 注入 `index.html` 的 `<head>`，浏览器执行后同时写入 localStorage 的两个 pinia store：
   - `auth` store：`{ token }`（JWT，供路由守卫 + API 请求 `Authorization: Bearer` 头）
   - `user` store：`{ superUser, userID, userName, permissions, ... }`（供权限/菜单/身份判断）
5. SPA 路由守卫读到 token → 跳过登录页；读 `userStore.superUser=true` → 进管理员 dashboard

**为什么必须同时写两个 store**：前端路由 `if (!authStore.token) return '/login'; return userStore.superUser ? '/dashboard' : '/apps'`——只有 token 没 user 信息会被判定为匿名普通用户，进不了管理员页面。前端无"启动时按 token 自动拉 user/current"的自愈机制，必须由桥把 user 信息一并注入。

**为什么不伪造 JWT**：MoviePilot 的 `SECRET_KEY` 每次启动随机生成（`secrets.token_urlsafe(32)`），不写 `app.env`，无法离线签名。**为什么不用 API 令牌**：API 令牌（`X-API-KEY`）只在后端 `verify_token` 依赖里现造一个内存中的 superuser payload，不会签发 JWT，前端 SPA 完全感知不到"已登录"——仍是匿名状态。

**改绑账号**：fnOS 应用设置页（`wizard/config` 向导）可修改免登录账号密码。注意：若在 MoviePilot 网页内改了密码，需在此同步更新，否则免登录失效。

**安全边界**：
- 免登录 JWT 仅经 Unix Socket（fnOS 网关路径 `/app/moviepilot`）注入，局域网直连 :3000 不注入
- JWT 缓存在网关桥进程内存，8 天有效，过期后刷新页面自动重新登录
- 已手动登录的浏览器（localStorage 有 token）不会被覆盖，保留用户当前会话

## 目录结构

```
fn-native-moviepilot/
├── manifest              # 应用元数据
├── config/
│   ├── privilege         # 运行权限（run-as: package）
│   └── resource          # 数据共享声明
├── cmd/                  # 生命周期脚本
│   ├── main              # start / stop / status
│   ├── install_callback  # 安装：git clone + setup
│   ├── upgrade_callback  # 升级：git pull + setup
│   ├── uninstall_callback
│   └── *_init / config_* 
├── app/
│   ├── ui/config         # 桌面入口（统一网关模式）
│   └── bin/              # 随包脚本
│       ├── gateway-bridge.js       # 网关桥：Unix Socket → 剥前缀 → 免登录注入 → 前端 :3000
│       └── gh-proxy                # GitHub 加速工具（git insteadOf + 文件下载）
├── wizard/
│   ├── install          # 安装向导（设置管理员账号密码，同时用于免登录）
│   └── config           # 应用设置向导（改绑免登录账号密码）
├── ICON.PNG / ICON_256.PNG
└── README.md
```

## 国内加速

安装全程走国内镜像源（不修改 MoviePilot 源码）：

| 下载环节 | 镜像 |
| --- | --- |
| Python 依赖 | 清华 PyPI |
| npm 依赖 | npmmirror |
| GitHub（源码/前端/资源） | 随包 [`gh-proxy`](https://gitee.com/rexond/gh-proxy)：多镜像并行测速选最快 + 失败回退直连 |
| CloakBrowser 内核 | GitHub Release（走 gh-proxy 加速），失败回退 cloakbrowser.dev 官方源 |

> `gh-proxy` 同时承担源码 clone/pull 加速（`gh-proxy clone`：替换 URL 走镜像竞速，clone 完自动还原官方 origin + 配 `insteadOf` 让后续 fetch/pull 透明走代理）与文件下载（`gh-proxy download`）。

## 打包与安装

```bash
# 打包为 .fpk（内核不再内置，安装时从 GitHub Release 下载）
fnpack build

# 安装到 fnOS 设备
appcenter-cli install-fpk moviepilot.fpk
```

## 相关

- MoviePilot 上游：<https://github.com/jxxghp/MoviePilot>
- 飞牛 fnOS 应用开发：<https://help.fnnas.com>
