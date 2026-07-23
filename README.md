# fn-native-moviepilot

基于飞牛 fnOS Native 框架封装的 [MoviePilot](https://github.com/jxxghp/MoviePilot) 应用，以原生进程方式在 fnOS 上运行，提供资源搜索、订阅、整理、刮削、转移与通知等自动化媒体管理能力。

## 应用信息

| 项 | 值 |
| --- | --- |
| appname | `moviepilot` |
| 运行模式 | Native 进程 |
| 平台 | x86 |
| 服务端口 | `3000`（前端入口；后端 API 在 3001） |
| 数据共享 | `moviepilot/config`、`moviepilot/data` |
| 运行用户 | `moviepilot`（package） |
| 依赖 | `nodejs_v24`（安装时自动拉取） |

管理员账号在安装向导中设置。若未通过向导安装，默认账号 `admin`，密码 `moviepilot123`，首次登录后请及时修改。

## 工作原理

MoviePilot v2 自带完整的本地（非 Docker）安装与运行系统（`scripts/local_setup.py` + `moviepilot` CLI）。本应用是对它的**薄封装**：

- **安装**：`install_callback` 用 git clone 拉取 v2 分支源码，调用上游 `moviepilot setup` 完成虚拟环境、Python 依赖、CloakBrowser 内核、前端、资源配置
- **运行**：`cmd/main` 委托 `moviepilot` CLI 管理进程（后端 Python/FastAPI :3001 + 前端 Node/express :3000）
- **更新**：git 部署，支持通过 MoviePilot 网页或 `moviepilot update` 在线更新

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
│   ├── ui/config         # 桌面入口（端口服务模式）
│   └── bin/              # 随包脚本
│       ├── curl-github-mirror      # curl 包装器，GitHub 下载走镜像
│       └── github-mirror-probe     # 多镜像自动探测
├── wizard/install        # 安装向导（设置管理员账号密码）
├── ICON.PNG / ICON_256.PNG
└── README.md
```

## 国内加速

安装全程走国内镜像源（不修改 MoviePilot 源码）：

| 下载环节 | 镜像 |
| --- | --- |
| Python 依赖 | 清华 PyPI |
| npm 依赖 | npmmirror |
| GitHub（源码/前端/资源） | 多镜像自动探测（v4.gh-proxy.org 等），不可用时回退直连 |
| CloakBrowser 内核 | GitHub Release（走镜像加速），失败回退 cloakbrowser.dev 官方源 |

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
