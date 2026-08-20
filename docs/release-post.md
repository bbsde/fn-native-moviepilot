# 【应用分享】MoviePilot v3 — 全自动追剧/观影神器，飞牛 fnOS 原生封装版

![MoviePilot for fnOS](https://ghproxy.net/https://raw.githubusercontent.com/bbsde/fn-native-moviepilot/main/src/app/ui/images/icon_64.png)

> 基于 [jxxghp/MoviePilot](https://github.com/jxxghp/MoviePilot) v3.0.0，以 fnOS Native 原生进程方式封装。
> 资源搜索、订阅追更、下载整理、刮削入库、媒体库同步、消息通知，一条龙全自动。

![MoviePilot 仪表盘](https://ghproxy.net/https://raw.githubusercontent.com/bbsde/fn-native-moviepilot/main/docs/demo.png)

> 仪表盘：媒体统计 · 整理记录 · 后台任务 · 快捷操作

## 一句话介绍

订阅你想看的剧集和电影，MoviePilot 自动搜索资源、挂下载、识别改名、刮削海报、整理进媒体库，再通知你「可以看了」。配合飞牛影视/Emby/Jellyfin 食用体验最佳。

## 为什么用这个版本

**1. 真·离线安装，不用折腾命令行**

安装包自包含全部依赖（上游源码 + 前端 + 174 个 Python wheel + 内置浏览器内核），应用中心装完即用，全程**无需外网、无需 SSH、无需 Python 环境**，通常 1~5 分钟完成。安装向导里设置管理员账号密码即可。

**2. 不配梯子也能正常用（重点优化）**

对国内网络做了逐项实测和默认值调优，开箱即用：

| 数据源 | 状态 | 说明 |
|---|---|---|
| TheMovieDb | ✅ 直连 | 默认走官方别名域名，0.7 秒响应 |
| 豆瓣 | ✅ 直连 | 原生可用 |
| AniList | ✅ 直连 | 官方 API 直连，中文标题数据集走加速 |
| Bangumi | ✅ 默认镜像 | 官方域名被双重封锁，默认走社区镜像，可一键换回 |
| 插件市场 | ✅ 默认加速 | GitHub 加速默认已配好，市场秒开 |

所有加速/镜像地址都可以在设置里自行更换或清空，不影响已有配置。

**3. 修好了几个上游的坑**

- 重启后不再强制重新登录（登录态已持久化）
- 媒体服务器改配置后立即生效，不再需要重启应用（上游配置变更不重建模块的问题已在打包层修复）
- 首次安装的账号初始化缺陷已修复

**4. fnOS 深度整合**

- 桌面图标点开**自动免登录**直进 MoviePilot（局域网直连端口仍可手动登录）
- 自带**飞牛影视**媒体服务器对接：整理完成的媒体自动同步进飞牛影视的媒体库
- 配置目录落在共享区，文件管理器里可直接查看管理
- 依赖 nodejs_v24 运行时，安装时自动拉取

## 安装

### 下载

**[→ GitHub Releases（始终指向最新版）](https://github.com/bbsde/fn-native-moviepilot/releases/latest)**

| 架构 | 直连下载 | 加速下载（国内推荐） |
|---|---|---|
| x86 | [moviepilot_3.0.0.9_x86.fpk](https://github.com/bbsde/fn-native-moviepilot/releases/download/v3.0.0.9/moviepilot_3.0.0.9_x86.fpk) | [ghproxy.net 加速](https://ghproxy.net/https://github.com/bbsde/fn-native-moviepilot/releases/download/v3.0.0.9/moviepilot_3.0.0.9_x86.fpk) |
| arm | [moviepilot_3.0.0.9_arm.fpk](https://github.com/bbsde/fn-native-moviepilot/releases/download/v3.0.0.9/moviepilot_3.0.0.9_arm.fpk) | [ghproxy.net 加速](https://ghproxy.net/https://github.com/bbsde/fn-native-moviepilot/releases/download/v3.0.0.9/moviepilot_3.0.0.9_arm.fpk) |

> 加速前缀使用公共镜像 ghproxy.net，失效时可直连或自行更换前缀；Release 内附带 `.sha256` 校验值，下载后建议核对。

### 步骤

1. fnOS **应用中心 → 手动安装**，选择对应架构的 fpk 文件
2. 向导中设置管理员用户名和密码（密码 ≥8 位，至少含字母/数字/特殊字符中两类）
3. 等待安装完成，桌面点开 MoviePilot 图标即可（自动免登录）

> 系统要求：fnOS ≥ 1.1.3100，支持 x86 / arm 双架构。

## 首次配置建议

1. **目录授权**：应用中心 → MoviePilot → 设置 →「目录授权」，填入媒体库、下载目录的绝对路径（逗号分隔）。MoviePilot 以专用应用用户运行，不授权则无法浏览/读写这些目录
2. **设定 → 服务**：添加下载器（qBittorrent/Transmission 等）
3. **设定 → 媒体服务器**：添加媒体服务器，飞牛影视地址填 `http://你的NAS_IP:5666`，账号密码为 fnOS 登录账号
4. **设定 → 站点**：导入站点认证资源（支持 CookieCloud 同步）
5. **订阅**：添加想追的剧集/电影，或使用「豆瓣想看」等插件自动同步

## 关于更新

- **更新方式 = 下载新版 fpk，应用中心手动安装覆盖**，配置、账号、订阅全部保留；同版本依赖升级通常一分钟内完成
- MoviePilot 网页内的「自动更新」已停用：在线更新会破坏本封装内置的补丁与依赖锁定，因此面板和网页里的更新开关均已移除/失效，这是有意为之
- 每个版本的更新内容见应用更新日志

## 常见问题

**Q：升级会丢配置吗？**
不会。配置、数据库、账号都在共享区，覆盖升级原样保留。

**Q：添加目录时 /vol1、/vol2 下的目录读不出来？**
应用以专用用户运行，默认无权访问用户共享目录。应用中心 → MoviePilot → 设置 →「目录授权」，填入需要的目录路径（逗号分隔），提交后立即生效；卸载应用时授权自动回收。

**Q：在 MoviePilot 网页里改了密码，桌面图标打开不进去了？**
应用中心 → MoviePilot → 设置，在「网桥免登录账号」里同步填一次新密码即可。

**Q：不信任第三方镜像怎么办？**
Bangumi/GitHub 加速均为第三方公共服务，只经手公开的元数据查询。介意的话：GitHub 加速在 设定→高级设置→网络 清空；Bangumi 在 `config/app.env` 里把 `BANGUMI_API_DOMAIN` 改回 `api.bgm.tv`（需要自备网络环境）。

**Q：探索页某个数据源一直转圈？**
切换到其他源试试；首访会有几秒的中文数据加载。若镜像服务失效，按上一条更换或清空配置即可回退直连。

**Q：局域网直连 3000 端口和网关入口有区别吗？**
功能一致；桌面图标走统一网关并自动免登录，直连 `http://NAS_IP:3000` 需手动登录。两者可同时使用。

## 版本记录（v3 线）

| 版本 | 内容 |
|---|---|
| 3.0.0.2 | 首个可用版：init 缺陷修复、venv 三级兜底 |
| 3.0.0.3 | 登录态持久化，重启不再掉登录 |
| 3.0.0.4 | 配置变更热重建模块（媒体服务器改配置立即生效） |
| 3.0.0.5 | 无梯子直连默认值（TMDB 官方别名 + GitHub 加速） |
| 3.0.0.6 | Bangumi 域名可配置，默认社区镜像 |
| 3.0.0.7 | AniList 中文数据集加速，首访提速 |
| 3.0.0.8 | 构建补丁锚点加固（无行为变化） |
| 3.0.0.9 | 应用图标更新；移除配置面板自动更新开关，在线自更新彻底关闭 |

## 致谢

- 上游核心引擎：[jxxghp/MoviePilot](https://github.com/jxxghp/MoviePilot) 及其贡献者
- Bangumi 数据：[Bangumi 番组计划](https://bgm.tv) / [Mirrox](https://bangumi.lol) 社区镜像
- 运行时：fnOS Native 框架、nodejs_v24

> 仅供学习交流，请于下载后 24 小时内删除；请支持正版，尊重版权。
