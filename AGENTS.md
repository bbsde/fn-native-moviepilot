# fn-native-moviepilot

基于飞牛 fnOS Native 框架封装的 [MoviePilot](https://github.com/jxxghp/MoviePilot) 应用，以原生进程方式在 fnOS 上运行，提供资源搜索、订阅、整理、刮削、转移与通知等自动化媒体管理能力。

## 应用信息

| 项 | 值 |
| --- | --- |
| appname | `moviepilot` |
| 运行模式 | Native 进程 |
| 平台 | x86 |
| 访问方式 | fnOS 统一网关 `/app/moviepilot`（Unix Socket） |
| 内部端口 | 前端 `:3000`（Node/express）+ 后端 API `:3001`（FastAPI），仅本机 |
| 数据共享 | `moviepilot/config`、`moviepilot/data` |
| 运行用户 | `moviepilot`（package） |
| 依赖 | `nodejs_v24`（安装时自动拉取） |

管理员账号在安装向导中设置。若未通过向导安装，默认账号 `admin`，密码 `moviepilot123`，首次登录后请及时修改。

## 工作原理

MoviePilot v2 自带完整的本地（非 Docker）安装与运行系统（`scripts/local_setup.py` + `moviepilot` CLI）。本应用是对它的**薄封装**：

- **安装**：`install_callback` 用 git clone 拉取 v2 分支源码，调用上游 `moviepilot setup` 完成虚拟环境、Python 依赖、CloakBrowser 内核、前端、资源配置
- **运行**：`cmd/main` 委托 `moviepilot` CLI 管理进程（后端 Python/FastAPI :3001 + 前端 Node/express :3000），随后启动 `gateway-bridge.js` 监听 fnOS 网关 Unix Socket
- **访问**：浏览器 → fnOS 网关 `/app/moviepilot/` → Unix Socket → `gateway-bridge.js`（剥前缀）→ 前端 `:3000`
- **更新**：git 部署，支持通过 MoviePilot 网页或 `moviepilot update` 在线更新（不触碰网关桥，桥位于 `${TRIM_APPDEST}/bin/`，上游更新只重写 `${MP_ROOT}/public/`）

### 网关桥（gateway-bridge.js）

上游前端 `public/service.js` 只监听 TCP 且假设根路径，无 Unix Socket / 前缀剥离能力，且 `moviepilot update` 会强制覆写它。为不修改上游任何文件，`src/app/bin/gateway-bridge.js`（零第三方依赖，纯 Node 内置模块）充当翻译层：监听 `${TRIM_APPDEST}/app.sock`，剥掉 `/app/moviepilot` 前缀，转发 HTTP / WebSocket 到前端 `:3000`。

## 目录结构

```
fn-native-moviepilot/
├── src/                    # fnOS 应用包内容
│   ├── app/ui/             # 应用 UI 配置（icon、url 定义）
│   ├── app/bin/            # 随包脚本（网关桥、镜像加速等）
│   ├── cmd/                # 应用生命周期脚本（install/start/stop/uninstall）
│   ├── config/             # 权限与资源映射配置
│   ├── wizard/             # 安装向导（管理员账号设置）
│   ├── manifest            # 应用元信息（版本、描述等）
│   ├── ICON.PNG            # 应用图标（128x128）
│   └── ICON_256.PNG        # 应用图标（256x256）
├── develop/                # 构建环境
│   └── build.sh            # 构建脚本
├── dist/                   # 构建产物（.fpk）
├── README.md               # 中文说明
└── README.en.md            # 英文说明
```

## 构建

```bash
cd develop && bash build.sh
```

## 依赖

- `fnpack`（fnOS 应用打包工具）
- `nodejs_v24`（运行时，安装时从 fnOS 应用中心拉取）

## 上游

- [jxxghp/MoviePilot](https://github.com/jxxghp/MoviePilot) — 核心引擎
- [fnOS Native 框架](https://www.fnation.cn) — 飞牛原生应用标准
