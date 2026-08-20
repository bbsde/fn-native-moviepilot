# MoviePilot fnOS 原生应用 — 开发环境备忘

> 本文件供 AI 助手（ZCode/Claude）读取，记录本项目的开发/测试环境信息，
> 避免每次会话重复询问。敏感信息（密码）不写这里。

## 测试 NAS（部署目标机）

- **地址**：`192.168.0.31`
- **系统**：fnOS（基于 Debian 12 bookworm，内核 trim 定制）
- **SSH 别名**：`nas31`（已配在本机 `~/.ssh/config`，免密 key 认证）
- **SSH 用户**：`李承龙`（fnOS 管理员，uid=1000，在 Administrators 组）
- **登录方式**：`ssh nas31` 即可，无需密码（ed25519 key 已装）

> 注：SSH 访问配置在**本机**（开发机）的 `~/.ssh/config`，换开发机需重装 key。
> key 文件：`~/.ssh/id_ed25519`（私钥）+ `~/.ssh/id_ed25519.pub`（公钥）。

## 应用部署路径（NAS 上）

fnOS 应用统一目录约定（以 `moviepilot` 应用为例）：

| 变量 | 实际路径 | 含义 |
|------|---------|------|
| `TRIM_APPDEST` | `/vol1/@appcenter/moviepilot` | 应用包解压目录（含 bin/、cmd/） |
| `TRIM_PKGVAR` | `/vol1/@appdata/moviepilot` | 应用运行数据（源码、日志、PID） |
| `TRIM_PKGHOME` | `/vol1/@apphome/moviepilot` | 应用 home 目录（Node、.local/bin） |
| 共享 config | `/vol1/@appshare/moviepilot/share/config` | MoviePilot app.env 所在 |

### 关键文件路径

- **网关桥**：`${TRIM_APPDEST}/bin/gateway-bridge.js`
- **桥日志**：`${TRIM_PKGVAR}/gateway-bridge.log`
- **应用日志**：`${TRIM_PKGVAR}/info.log`
- **安装日志**：`${TRIM_PKGVAR}/install.log`
- **MoviePilot 源码**：`${TRIM_PKGVAR}/MoviePilot/`
- **app.env**：`/vol1/@appshare/moviepilot/share/config/app.env`
- **网关 socket**：`${TRIM_APPDEST}/app.sock`

## 端口

- `:3001` — MoviePilot 后端（FastAPI/uvicorn）
- `:3000` — MoviePilot 前端（Node service.js，静态文件 + API 代理）
- 桥只监听 Unix socket，无 TCP 端口

## 访问入口

- **fnOS 网关**：`http://192.168.0.31:5666/app/moviepilot`（经桥，免登录）
- **局域网直连**：`http://192.168.0.31:3000`（前端，需手动登录）

## 开发常用命令（在 NAS 上）

```bash
# 看桥日志（免登录 + 转发）
tail -100 /vol1/@appdata/moviepilot/gateway-bridge.log

# 看应用日志
tail -100 /vol1/@appdata/moviepilot/info.log

# 查进程
ps aux | grep -E 'MoviePilot|service\.js|gateway-bridge'

# 查端口
ss -lntp | grep -E '3000|3001'

# 重启应用（fnOS 应用中心操作，或）
sudo systemctl restart trim-app-moviepilot 2>/dev/null || true

# curl 测试（经网关 socket）
curl --unix-socket /vol1/@appcenter/moviepilot/app.sock http://localhost/
curl http://127.0.0.1:3000/version.txt   # 前端健康
curl http://127.0.0.1:3001/api/v1/system/global?token=moviepilot  # 后端健康
```

## fnOS 应用打包（在开发机上）

```bash
cd /x/Projects/fn-native-moviepilot
fnpack build    # 产出 .fpk
# 安装到 NAS：fnOS 应用中心 → 添加本地应用 → 上传 .fpk
```
