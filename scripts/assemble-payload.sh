#!/usr/bin/env bash
#
# assemble-payload.sh — 组装 v3 payload.tar（构建期，本地/CI 通用）
#
# 用法：scripts/assemble-payload.sh <upstream-tag> <arch>
#   upstream-tag  上游 release tag（如 v3.0.0）
#   arch          x86_64 | aarch64
#
# 产物：build/payload-<arch>.tar（未压缩；内容皆已压缩格式，再压收益极小）
# 布局（释放到 TRIM_PKGVAR 后）：
#   MoviePilot/               上游源码快照 + public/ 前端成品 + app/application/site/ 资源
#   wheels/                   pip wheels（设备端 --no-index 离线安装）
#   payload.lock              精确依赖清单（name==version，由 wheels 文件名生成）
#   payload.meta              元信息（KERNEL_VERSION/LOCK_SHA256/...，安装/升级脚本消费）
#   kernel/chromium-<v>.tar   CloakBrowser 内核（重组为 chromium-<v>/ 前缀裸 tar）
#
# 缓存：cache/（gitignore，不入库）
#   upstream/<tag>.tar.gz     上游源码包（codeload）
#   frontend/<fv>/            组装好的前端 public/
#   wheels/<tag>-<arch>/      wheels + payload.lock（按 tag+arch 锁定一次）
#   kernel/<plat>/            官方内核包 + 重组后的 chromium-<v>.tar
#   resources/                MoviePilot-Resources main.zip + 过滤产物
#
# 关键设计：
#   - 前端在构建期组装成品（dist + service.js + express node_modules），跳过上游
#     install frontend（其必然查询 api.github.com，设备端不可用）
#   - service.js 模板从上游 scripts/local_setup.py 中提取（单一事实源，上游改了
#     我们自动跟随；提取失败即构建失败，不会静默漂移）
#   - CloakBrowser 内核版本从随包 cloakbrowser wheel 的 PLATFORM_CHROMIUM_VERSIONS
#     解析（内核与 wrapper 版本严格自洽，不硬编码）
#   - requirements.in 过滤 Windows-only marker 行（本地 Windows 构建时 pip 的
#     platform_system 仍取宿主值，会把 pywin32 拉进 lock，设备端安装必炸）

set -euo pipefail

TAG="${1:?用法: assemble-payload.sh <upstream-tag> <arch>}"
ARCH="${2:?用法: assemble-payload.sh <upstream-tag> <arch>}"
case "${ARCH}" in
    x86_64)  CB_PLAT="linux-x64" ;;
    aarch64) CB_PLAT="linux-arm64" ;;
    *) echo "不支持的架构：${ARCH}（仅 x86_64 / aarch64）" >&2; exit 1 ;;
esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${MP_CACHE:-${REPO_DIR}/cache}"
BUILD="${MP_BUILD:-${REPO_DIR}/build}"
PYV="${MP_PYTHON_VERSION:-311}"

log() { echo "[payload] $*"; }
die() { echo "[payload][ERROR] $*" >&2; exit 1; }

# pip/uv 一律直连 PyPI 本尊：镜像源存在同步滞后，uv 解析出的最新版可能
# 在镜像上还不存在（实测 langgraph-sdk）。特殊网络环境可用 MP_PYPI_INDEX 覆盖。
PYPI_INDEX="${MP_PYPI_INDEX:-https://pypi.org/simple}"
export PIP_INDEX_URL="${PYPI_INDEX}"

# python 命令名（Windows: python，Linux: python3）
PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

require_tools() {
    local t
    for t in curl tar npm node uv "${PY}"; do
        command -v "$t" >/dev/null 2>&1 || die "缺少工具：$t（uv 可经 pip install uv 安装）"
    done
    "${PY}" -c 'import sys; assert sys.version_info >= (3, 8), "需要 Python 3.8+"' || die "Python 版本过低"
    "${PY}" -m pip --version >/dev/null 2>&1 || die "pip 不可用"
}

# --------------------------------------------------------------------------
# 1. 上游源码包（codeload tag 快照，非 git，无 .git）
# --------------------------------------------------------------------------
fetch_source() {
    mkdir -p "${CACHE}/upstream"
    local archive="${CACHE}/upstream/${TAG}.tar.gz"
    if [ ! -f "${archive}" ]; then
        log "下载上游源码 ${TAG} ..."
        curl -fSL --retry 3 --connect-timeout 20 -o "${archive}" \
            "https://codeload.github.com/jxxghp/MoviePilot/tar.gz/refs/tags/${TAG}" \
            || die "上游源码下载失败：${TAG}"
    else
        log "上游源码已缓存：${archive}"
    fi
    SRC_ARCHIVE="${archive}"
}

# --------------------------------------------------------------------------
# 2. 释放源码到组装目录（--strip-components=1 去掉顶层 MoviePilot-<ver>/）
# --------------------------------------------------------------------------
stage_source() {
    log "释放源码 → ${BUILD}/payload/MoviePilot"
    # 清空组装目录。目录本体可能被本机 shell 占为 CWD（Windows 句柄）删不掉，
    # 退化为清空内容——顶层目录保留不影响后续（tar 释放进既有目录即可）。
    # 顺序必须「清空 → 删壳 → 建」：mkdir 之后再 find 会把新目录又删掉
    find "${BUILD}/payload" -mindepth 1 -delete 2>/dev/null || true
    rm -rf "${BUILD}/payload" 2>/dev/null || true
    mkdir -p "${BUILD}/payload/MoviePilot"
    tar -xzf "${SRC_ARCHIVE}" -C "${BUILD}/payload/MoviePilot" --strip-components=1
    [ -f "${BUILD}/payload/MoviePilot/requirements.in" ] || die "源码包缺少 requirements.in（tag 异常？）"
    [ -f "${BUILD}/payload/MoviePilot/scripts/local_setup.py" ] || die "源码包缺少 scripts/local_setup.py"

    # 补丁 1：上游 v3.0.0 首日 bug——local_setup.py 的 _ensure_superuser_account_inner
    # 引用不存在的 app.application.security.access（get_password_hash 实际在
    # app.application.security.token），init --superuser 必炸。上游修复/改动此行后
    # sed 自然失效（仅记录，不阻断）。
    if grep -q 'from app.application.security.access import get_password_hash' \
        "${BUILD}/payload/MoviePilot/scripts/local_setup.py"; then
        sed -i 's|from app.application.security.access import get_password_hash|from app.application.security.token import get_password_hash|' \
            "${BUILD}/payload/MoviePilot/scripts/local_setup.py"
        log "已修正上游 v3.0.0 security.access 错误导入（→ security.token）"
    else
        log "上游 security.access 导入已不存在（上游已修复或结构变化），跳过补丁"
    fi

    # 补丁 2：上游 v3.0.0 事件绑定缺陷——ModuleManager 订阅了自己的
    # handle_config_changed，但其注册的 resolver 只匹配受管模块类（app/modules/*），
    # 不认 ModuleManager 本身 → 处理器被事件系统永久跳过 → 配置变更从不触发模块
    # 重建（媒体服务器/下载器改配置后坏实例滞留、必须重启才生效的根因）。
    # 补丁：resolver 先识别自身类。上游修复后锚点消失，补丁自动停用。
    # 锚点分级（auto-follow 友好）：上游已用等价写法自修 → 干净跳过；
    # 锚点在但结构性重构 → 构建 die（fail-closed，宁停摆不无补丁发布）。
    if grep -q 'owner_class is type(self)' \
        "${BUILD}/payload/MoviePilot/app/runtime/extensions/module_manager.py"; then
        log "上游已自带等价修复（owner_class is type(self)），跳过补丁"
    elif grep -q '按 canonical class identity 绑定当前 generation' \
        "${BUILD}/payload/MoviePilot/app/runtime/extensions/module_manager.py"; then
        (cd "${BUILD}/payload/MoviePilot/app/runtime/extensions" && "${PY}" - <<'PYEOF' || die "module_manager 补丁失败"
import io
path = "module_manager.py"
src = io.open(path, encoding="utf-8").read()
anchor = '        """按 canonical class identity 绑定当前 generation，停止态阻断 fallback 构造。"""\n'
patch = anchor + (
    "        # fn-native-moviepilot 补丁：本类自身订阅的 handle_config_changed 也由\n"
    "        # 本 resolver 绑定（上游实现只匹配受管模块类，本类处理器被事件系统\n"
    "        # 跳过，配置变更因此从不触发模块重建）\n"
    "        if owner_class is type(self):\n"
    "            return EventHandlerBinding(\n"
    "                instance=self,\n"
    "                owner_name=\"ModuleManager\",\n"
    "                run_sync_in_threadpool=True,\n"
    "            )\n"
)
if "fn-native-moviepilot 补丁" not in src:
    if anchor not in src:
        raise SystemExit("锚点未找到，上游结构已变化，需人工复核")
    io.open(path, "w", encoding="utf-8", newline="").write(src.replace(anchor, patch, 1))
print("module_manager resolver 补丁已应用")
PYEOF
)
        log "已修补 ModuleManager resolver 自身识别（配置变更可触发模块重建）"
    else
        log "module_manager 锚点不存在（上游已修复或重构），跳过补丁"
    fi

    # 补丁 3：Bangumi API 域名可配置。上游硬编码 https://api.bgm.tv/，
    # 该域名在国内被 DNS 污染 + SNI 重置双重封锁（裸 TCP 通、ClientHello 带
    # SNI 即 RST），无梯子不可用；社区镜像（如 api.bangumi.lol，Mirrox 项目）
    # 国内直连可用且自动改写返回 JSON 中的图片域。补丁新增 BANGUMI_API_DOMAIN
    # 配置（默认仍官方域名），三处引用同步改造。上游若自行支持则锚点消失自动停用。
    if ! grep -q 'BANGUMI_API_DOMAIN' \
        "${BUILD}/payload/MoviePilot/app/runtime/config.py"; then
        (cd "${BUILD}/payload/MoviePilot/app/modules" && "${PY}" - <<'PYEOF' || die "bangumi 域名补丁失败"
import io

def apply(path, replacements, marker="fn-native-moviepilot 补丁"):
    src = io.open(path, encoding="utf-8").read()
    if marker in src:
        print(f"{path}: 已有补丁标记，跳过")
        return
    for anchor, patch in replacements:
        if anchor not in src:
            raise SystemExit(f"{path}: 锚点未找到，上游结构已变化，需人工复核")
        src = src.replace(anchor, patch, 1)
    io.open(path, "w", encoding="utf-8", newline="").write(src)
    print(f"{path}: 补丁已应用")

# 1) config.py 新增配置字段（默认仍官方域名，不改变上游行为）
apply(
    "../runtime/config.py",
    [(
        '    TMDB_API_KEY: str = "db55323b8d3e4154498498a75642b381"\n',
        '    TMDB_API_KEY: str = "db55323b8d3e4154498498a75642b381"\n'
        '    # fn-native-moviepilot 补丁：Bangumi API地址（api.bgm.tv 在部分地区被\n'
        '    # SNI 层封锁，可配置镜像域名如 api.bangumi.lol）\n'
        '    BANGUMI_API_DOMAIN: str = "api.bgm.tv"\n',
    )],
)

# 2) bangumi.py 实例化时读取配置（CONFIG_WATCH 触发模块重建后即时生效；
#    类属性保留官方域名作参照，self._base_url 在 __invoke 中优先命中）。
#    锚点只锚 def 行——方法体变动不断锚
apply(
    "bangumi/bangumi.py",
    [(
        "    def __init__(self):\n",
        "    def __init__(self):\n"
        "        # fn-native-moviepilot 补丁：API 域名可配置\n"
        "        self._base_url = f\"https://{settings.BANGUMI_API_DOMAIN}/\"\n",
    )],
)

# 3) 模块 CONFIG_WATCH + 连通性测试同步使用配置域名。
#    CONFIG_WATCH 锚「开括号」子串——上游往集合加键不断锚
#    （替换产生的重复元素在 set 字面量中无害）
apply(
    "bangumi/__init__.py",
    [
        (
            "    CONFIG_WATCH = {",
            "    # fn-native-moviepilot 补丁：域名变更加入热重建监听\n"
            '    CONFIG_WATCH = {"PROXY_HOST", "BANGUMI_API_DOMAIN", ',
        ),
        (
            'get_res("https://api.bgm.tv/")',
            'get_res(f"https://{settings.BANGUMI_API_DOMAIN}/")',
        ),
    ],
)
PYEOF
)
        log "已应用 Bangumi API 域名可配置补丁（默认官方，可切镜像）"
    else
        log "上游已支持 BANGUMI_API_DOMAIN（或结构变化），跳过补丁"
    fi

    # 补丁 4：AniList 中文数据集经 GITHUB_PROXY 加速。上游硬编码
    # raw.githubusercontent.com 直连拉取 854KB 的 anilist-chinese.json（中文
    # 标题数据），该域名国内间歇性重置（实测 3.6~14.8s，运气差卡满读超时），
    # 拖慢探索页 AniList 源首次加载。补丁：设置 GITHUB_PROXY 时前缀拼接
    # （与上游 resource.py 对 raw 域的用法一致），留空则保持直连。
    if ! grep -q 'GITHUB_PROXY' \
        "${BUILD}/payload/MoviePilot/app/modules/anilist/anilist.py"; then
        (cd "${BUILD}/payload/MoviePilot/app/modules/anilist" && "${PY}" - <<'PYEOF' || die "anilist 数据集补丁失败"
import io

def apply(path, replacements, marker="fn-native-moviepilot 补丁"):
    src = io.open(path, encoding="utf-8").read()
    if marker in src:
        print(f"{path}: 已有补丁标记，跳过")
        return
    for anchor, patch in replacements:
        if anchor not in src:
            raise SystemExit(f"{path}: 锚点未找到，上游结构已变化，需人工复核")
        src = src.replace(anchor, patch, 1)
    io.open(path, "w", encoding="utf-8", newline="").write(src)
    print(f"{path}: 补丁已应用")

# 1) 数据集 URL 改为实例属性：设置 GITHUB_PROXY 时前缀拼接（空值保持直连）。
#    RHS 读的是类属性——上游换数据集地址自动跟随，不复制 URL（防静默漂移 404）
apply(
    "anilist.py",
    [(
        "    def __init__(self) -> None:\n",
        "    def __init__(self) -> None:\n"
        "        # fn-native-moviepilot 补丁：中文数据集经 GITHUB_PROXY 加速（raw 直连间歇重置）\n"
        "        self._translations_url = f\"{settings.GITHUB_PROXY or ''}{self._translations_url}\"\n",
    )],
)
# 2) GITHUB_PROXY 变更加入热重建监听（锚「开括号」子串，上游加键不断锚）
apply(
    "__init__.py",
    [(
        "    CONFIG_WATCH = {",
        "    # fn-native-moviepilot 补丁：GITHUB_PROXY 变更后重建以更新数据集地址\n"
        '    CONFIG_WATCH = {"PROXY_HOST", "GITHUB_PROXY", ',
    )],
)
PYEOF
)
        log "已应用 AniList 数据集 GITHUB_PROXY 加速补丁"
    else
        log "上游 anilist 已引用 GITHUB_PROXY（或结构变化），跳过补丁"
    fi

    # 补丁 5：fnOS 授权目录虚拟浏览。fnOS「配置访问权限」对授权目录本体授
    # 读写（trimacl 内核层生效），但祖先层仅穿透权（--x）；posix ACL 在
    # trimacl 卷上不被内核执行，setfacl 开不了祖先层的列举权 → 应用用户在
    # 网页目录浏览器中永远点不开 /volN 层（iterdir 抛 PermissionError）。
    # 补丁：LocalStorage.list 捕获列举无权限（不再 500），并在当前目录是
    # 授权目录的祖先时合成「下一跳」虚拟子目录（授权清单由生命周期脚本维护
    # 于配置目录 fnos_grants.txt），浏览器得以逐级展开到授权目录本体（其内
    # 为原生真实读写）。上游重构 list/create_folder（锚点消失）→ 构建 die。
    if ! grep -q '__fnos_grant_view' \
        "${BUILD}/payload/MoviePilot/app/modules/filemanager/storages/local.py"; then
        (cd "${BUILD}/payload/MoviePilot/app/modules/filemanager/storages" && "${PY}" - <<'PYEOF' || die "fnOS 授权目录虚拟浏览补丁失败"
import io

path = "local.py"
src = io.open(path, encoding="utf-8").read()
if "fn-native-moviepilot 补丁" in src:
    print("local.py: 已有补丁标记，跳过")
    raise SystemExit(0)

list_anchor = (
    "        # 扁历所有目录\n"
    "        for item in SystemUtils.list_sub_directory(path_obj):\n"
    "            ret_items.append(self.__get_diritem(item))\n"
    "\n"
    "        # 遍历所有文件，不含子目录\n"
    "        for item in SystemUtils.list_sub_file(path_obj):\n"
    "            ret_items.append(self.__get_fileitem(item))\n"
    "        return ret_items\n"
)
list_patched = (
    "        # 扁历所有目录\n"
    "        try:\n"
    "            for item in SystemUtils.list_sub_directory(path_obj):\n"
    "                ret_items.append(self.__get_diritem(item))\n"
    "\n"
    "            # 遍历所有文件，不含子目录\n"
    "            for item in SystemUtils.list_sub_file(path_obj):\n"
    "                ret_items.append(self.__get_fileitem(item))\n"
    "        except PermissionError:\n"
    "            # fn-native-moviepilot 补丁：fnOS trimacl 卷未授权层可穿透不可\n"
    "            # 列举，不再向上抛 500，交由下方授权目录虚拟浏览处理\n"
    "            pass\n"
    "        # fn-native-moviepilot 补丁：授权目录虚拟浏览（祖先层只显示授权链，\n"
    "        # 授权目录内真实列举 + 无权限子项过滤）\n"
    "        ret_items = self.__fnos_grant_view(path, ret_items)\n"
    "        return ret_items\n"
)
methods_anchor = "    def create_folder(self, fileitem: _SchemaFileItem, name: str) -> Optional[_SchemaFileItem]:\n"
methods_patched = '''    def __fnos_filter_accessible(self, items: List[_SchemaFileItem]) -> List[_SchemaFileItem]:
        """
        fn-native-moviepilot 补丁：过滤当前应用用户无权访问的子项——
        无列举权的目录点开即空、无读权的文件不可用，提前隐藏。
        必须在 __fnos_grant_hop 之前执行：虚拟跳层本身「可穿不可列」，
        会被本过滤器误杀。
        """
        ret = []
        for it in items:
            try:
                if it.type == "dir":
                    if os.access(it.path, os.R_OK | os.X_OK):
                        ret.append(it)
                elif os.access(it.path, os.R_OK):
                    ret.append(it)
            except OSError:
                continue
        return ret

    def __fnos_granted_roots(self) -> List[str]:
        """
        fn-native-moviepilot 补丁：fnOS「配置访问权限」授权目录清单
        （生命周期脚本维护于配置目录 fnos_grants.txt，一行一个绝对路径）
        """
        grants_file = Path(settings.CONFIG_DIR or "") / "fnos_grants.txt"
        try:
            return [
                line.strip()
                for line in grants_file.read_text(encoding="utf-8").splitlines()
                if line.strip().startswith("/")
            ]
        except OSError:
            return []

    def __fnos_hop_items(self, base: str, hops) -> List[_SchemaFileItem]:
        """
        构造下一跳虚拟目录项。child 拼接必须规避双斜杠：base 为 / 时
        f"{base}/{hop}" 会得到 //volN，前端原样展示且点击后路径失配。
        """
        ret = []
        for hop in hops:
            child = f"{base}/{hop}" if base != "/" else f"/{hop}"
            try:
                ret.append(self.__get_diritem(Path(child)))
            except OSError:
                ret.append(_SchemaFileItem(
                    storage=self.schema.value, type="dir",
                    path=child + "/", name=hop, basename=hop,
                ))
        return ret

    def __fnos_grant_view(self, path: str, items: List[_SchemaFileItem]) -> List[_SchemaFileItem]:
        """
        fn-native-moviepilot 补丁：授权目录虚拟浏览。
        当前目录是某授权目录的祖先（含 / 本身）且不是授权目录时，只返回
        授权链的下一跳虚拟目录——应用用户在这些层无列举权（fnOS trimacl），
        也不应看到与授权无关的内容；授权目录本体及内部则返回真实列举
        （过滤无权限子项），并补上更深授权的下一跳（按路径去重）。
        """
        base = (path or "/").rstrip("/") or "/"
        prefix = "/" if base == "/" else base + "/"
        roots = [r.rstrip("/") for r in self.__fnos_granted_roots()]
        if not roots:
            return items
        hops = sorted({root[len(prefix):].split("/", 1)[0]
                       for root in roots if root.startswith(prefix)})
        if not hops:
            return self.__fnos_filter_accessible(items)
        if base not in roots:
            return self.__fnos_hop_items(base, hops)
        items = self.__fnos_filter_accessible(items)
        existing = {it.path.rstrip("/") for it in items}
        for hop in hops:
            child = f"{base}/{hop}" if base != "/" else f"/{hop}"
            if child not in existing:
                items.extend(self.__fnos_hop_items(base, [hop]))
        return items

'''
if list_anchor not in src:
    raise SystemExit("local.py: list() 遍历锚点未找到，上游结构已变化，需人工复核")
if methods_anchor not in src:
    raise SystemExit("local.py: create_folder 锚点未找到，上游结构已变化，需人工复核")
src = src.replace(list_anchor, list_patched, 1)
src = src.replace(methods_anchor, methods_patched + methods_anchor, 1)
io.open(path, "w", encoding="utf-8", newline="").write(src)
print("local.py: fnOS 授权目录虚拟浏览补丁已应用")
PYEOF
)
        log "已应用 fnOS 授权目录虚拟浏览补丁（目录浏览器可达授权目录）"
    else
        log "local.py 已含虚拟浏览补丁（或结构变化），跳过"
    fi

    FRONTEND_VERSION="$("${PY}" -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^FRONTEND_VERSION\s*=\s*[\"\x27]([^\"\x27]+)[\"\x27]", src, re.M)
print(m.group(1) if m else "")
' "${BUILD}/payload/MoviePilot/version.py")"
    [ -n "${FRONTEND_VERSION}" ] || die "version.py 中未找到 FRONTEND_VERSION"
    log "FRONTEND_VERSION=${FRONTEND_VERSION}"
}

# --------------------------------------------------------------------------
# 3. 前端成品（缓存 cache/frontend/<fv>/public）
# dist.zip → public/；package.json（镜像上游 RUNTIME_PACKAGE 常量）；version.txt；
# service.js 从 local_setup.py 提取；npm install --omit=dev。
#--------------------------------------------------------------------------
prepare_frontend() {
    local fe_dir="${CACHE}/frontend/${FRONTEND_VERSION}"
    local public="${fe_dir}/public"
    if [ -f "${public}/service.js" ] && [ -f "${public}/package.json" ] \
       && [ -d "${public}/node_modules/express" ]; then
        log "前端已缓存：${public}"
    else
        log "组装前端 ${FRONTEND_VERSION} ..."
        rm -rf "${fe_dir}"
        mkdir -p "${fe_dir}"
        curl -fSL --retry 3 --connect-timeout 20 -o "${fe_dir}/dist.zip" \
            "https://github.com/jxxghp/MoviePilot-Frontend/releases/download/${FRONTEND_VERSION}/dist.zip" \
            || die "前端 dist.zip 下载失败：${FRONTEND_VERSION}"
        # 注意：python 用「cd + 相对路径」取文件——原生 Windows Python 不识别
        # MSYS 的 /d/... 绝对路径（Linux CI 下同样兼容）
        (cd "${fe_dir}" && "${PY}" -c 'import zipfile; zipfile.ZipFile("dist.zip").extractall("extract")')
        [ -d "${fe_dir}/extract/dist" ] || die "dist.zip 中未找到 dist/ 目录"
        mv "${fe_dir}/extract/dist" "${public}"

        # package.json：镜像上游 local_setup.py 的 RUNTIME_PACKAGE（express 服务依赖）
        cat > "${public}/package.json" <<EOF
{
  "name": "moviepilot-frontend-runtime",
  "version": "${FRONTEND_VERSION}",
  "private": true,
  "license": "UNLICENSED",
  "dependencies": {
    "express": "^4.18.2",
    "express-http-proxy": "^2.0.0"
  }
}
EOF
        printf '%s\n' "${FRONTEND_VERSION}" > "${public}/version.txt"

        # service.js：从上游 local_setup.py 提取 LOCAL_FRONTEND_SERVICE_SCRIPT 模板
        # （textwrap.dedent 处理缩进，与上游写入行为一致；stdout 重定向由 bash 处理）
        (cd "${BUILD}/payload/MoviePilot/scripts" && "${PY}" - local_setup.py) > "${public}/service.js" <<'PYEOF' || die "service.js 提取失败（上游模板结构变化？）"
import re, sys, textwrap
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(
    r"LOCAL_FRONTEND_SERVICE_SCRIPT\s*=\s*textwrap\.dedent\(\s*\"\"\"(.*?)\"\"\"\s*\)",
    src, re.S)
if not m:
    sys.stderr.write("未匹配到 LOCAL_FRONTEND_SERVICE_SCRIPT 模板\n")
    sys.exit(1)
sys.stdout.write(textwrap.dedent(m.group(1)).lstrip())
PYEOF
        [ -s "${public}/service.js" ] || die "service.js 提取结果为空"

        (cd "${public}" && npm install --no-fund --no-audit --omit=dev) \
            || die "前端 npm install 失败"
    fi

    log "前端就位 → payload/MoviePilot/public"
    rm -rf "${BUILD}/payload/MoviePilot/public"
    cp -a "${public}" "${BUILD}/payload/MoviePilot/public"
}

# --------------------------------------------------------------------------
# 4. 站点资源（MoviePilot-Resources main 分支 resources.v3）
# 上游 _filter_resources_files 规则：user.sites.v3.bin + sites.cpython-311-<arch>-linux-gnu.so
# --------------------------------------------------------------------------
stage_resources() {
    local res_cache="${CACHE}/resources"
    local main_zip="${res_cache}/main.zip"
    if [ ! -f "${main_zip}" ]; then
        log "下载 MoviePilot-Resources main.zip ..."
        mkdir -p "${res_cache}"
        curl -fSL --retry 3 --connect-timeout 20 -o "${main_zip}" \
            "https://github.com/jxxghp/MoviePilot-Resources/archive/refs/heads/main.zip" \
            || die "MoviePilot-Resources 下载失败"
    fi
    local extract="${res_cache}/extracted"
    if [ ! -d "${extract}/MoviePilot-Resources-main/resources.v3" ]; then
        rm -rf "${extract}"
        mkdir -p "${extract}"
        (cd "${res_cache}" && "${PY}" -c 'import zipfile; zipfile.ZipFile("main.zip").extractall("extracted")') \
            || die "resources main.zip 解压失败"
    fi
    local v3dir="${extract}/MoviePilot-Resources-main/resources.v3"
    [ -d "${v3dir}" ] || die "main.zip 中未找到 resources.v3 目录（上游结构变化？）"

    local site_dir="${BUILD}/payload/MoviePilot/app/application/site"
    mkdir -p "${site_dir}"
    cp -f "${v3dir}/user.sites.v3.bin" "${site_dir}/" || die "缺少 user.sites.v3.bin"
    local sites_so
    sites_so="$(ls "${v3dir}" | grep "cpython-311" | grep "${ARCH}" | grep "linux-gnu" | head -1 || true)"
    [ -n "${sites_so}" ] || die "未找到匹配 ${ARCH}+cpython-311 的 sites 资源（目录内容：$(ls "${v3dir}" | tr '\n' ' '))"
    cp -f "${v3dir}/${sites_so}" "${site_dir}/"
    log "站点资源就位：user.sites.v3.bin + ${sites_so}"
}

# --------------------------------------------------------------------------
# 5. pip wheels（跨平台下载：--python-version/--platform 定向 cp311+manylinux）
# lock 由 wheels 文件名生成（name==version），缓存在 cache/wheels/<tag>-<arch>/
# 额外携带 pip + wheel 两个 wheel（设备端 ensurepip 缺失时自举用）。
# --------------------------------------------------------------------------
fetch_wheels() {
    local wheel_cache="${CACHE}/wheels/${TAG}-${ARCH}-cp${PYV}"
    mkdir -p "${wheel_cache}"
    if [ -f "${wheel_cache}/payload.lock" ]; then
        log "wheels 已缓存：${wheel_cache}"
    else
        log "解析依赖（uv，按目标平台 ${ARCH} cp${PYV} 求值 marker）..."
        # pip 的跨平台下载只影响 wheel 标签匹配，环境 marker（sys_platform/
        # platform_system）仍按宿主求值——Windows 宿主会把 docker 的
        # pywin32 传递依赖拉进来且无 Linux wheel 可下。uv 的 --python-platform
        # 按目标平台正确求值 marker，产出的 lock 设备端可直接 pip -r 安装。
        local triple
        case "${ARCH}" in
            x86_64)  triple="x86_64-unknown-linux-gnu" ;;
            aarch64) triple="aarch64-unknown-linux-gnu" ;;
        esac
        # uv 为原生二进制，路径须相对形式（同 python 的 MSYS 路径问题）
        if ! (cd "${BUILD}" && uv pip compile "payload/MoviePilot/requirements.in" \
                --default-index "${PYPI_INDEX}" \
                --python-platform "${triple}" \
                --python-version "3.11" \
                --no-header --quiet \
                --output-file payload.lock.raw) ; then
            die "uv 依赖解析失败"
        fi
        # 去掉 '# via' 注释行，lock 只留 name==version（pip/wheel 为设备端
        # 自举与运行时兜底额外附带）；先写 staging，全部下载成功后才转正，
        # 避免中断后被「已缓存」分支误判为完整
        grep -E '^[a-zA-Z0-9._-]+==' "${BUILD}/payload.lock.raw" \
            > "${wheel_cache}/lock.staging" \
            || die "uv lock 输出异常（无 name==version 行）"
        printf 'pip\nwheel\n' >> "${BUILD}/payload.lock.raw"
        (cd "${BUILD}" && uv pip compile payload.lock.raw \
                --default-index "${PYPI_INDEX}" \
                --python-platform "${triple}" --python-version "3.11" \
                --no-header --quiet --output-file payload.lock.boot) \
            || die "uv 解析 pip/wheel 兜底失败"
        grep -E '^[a-zA-Z0-9._-]+==' "${BUILD}/payload.lock.boot" >> "${wheel_cache}/lock.staging"
        sort -u -o "${wheel_cache}/lock.staging" "${wheel_cache}/lock.staging"
        log "lock 就绪：$(wc -l < "${wheel_cache}/lock.staging") 项"

        log "下载 wheels（${ARCH} cp${PYV}，~300-450MB，首次较慢）..."
        # 批量下载（快路径）。--no-deps：uv lock 已是完整闭包，禁止 pip 重走
        # 依赖图——否则宿主 marker（Windows 下 sys_platform=="win32"）会把
        # docker 的 pywin32 传递依赖重新拉进来且无 Linux wheel 可下；
        # --find-links 让回退阶段本地构建的 wheel 可被复用
        if ! "${PY}" -m pip download \
                -r "${wheel_cache}/lock.staging" \
                --no-deps \
                --only-binary=:all: \
                --python-version "${PYV}" \
                --implementation cp \
                --abi "cp${PYV}" \
                --platform "manylinux2014_${ARCH}" \
                --platform "manylinux_2_17_${ARCH}" \
                --platform "manylinux_2_28_${ARCH}" \
                --find-links "${wheel_cache}" \
                --dest "${wheel_cache}" ; then
            # 回退：逐依赖排查。sdist-only 的纯 Python 包（如 anitopy）本地
            # 构建 py3-none-any wheel 即可跨平台；C 扩展 sdist-only 则本机
            # 跨平台建不出合法 wheel，明确报错（需 CI Linux 腿或容器构建）
            log "[WARN] 批量下载存在 sdist-only 依赖，进入逐项回退 ..."
            local req
            while IFS= read -r req; do
                [ -n "${req}" ] || continue
                if "${PY}" -m pip download "${req}" --no-deps \
                        --only-binary=:all: \
                        --python-version "${PYV}" --implementation cp \
                        --abi "cp${PYV}" \
                        --platform "manylinux2014_${ARCH}" \
                        --platform "manylinux_2_17_${ARCH}" \
                        --platform "manylinux_2_28_${ARCH}" \
                        --find-links "${wheel_cache}" \
                        --dest "${wheel_cache}" >/dev/null 2>&1; then
                    continue
                fi
                log "  sdist-only：${req} → 本地构建 wheel"
                local wtmp="${wheel_cache}/.build"
                rm -rf "${wtmp}"
                mkdir -p "${wtmp}"
                "${PY}" -m pip wheel "${req}" --no-deps -w "${wtmp}" \
                    || die "本地构建 wheel 失败：${req}"
                local w w_base plat
                local host_arch=""
                if [ "$(uname -s)" = "Linux" ]; then
                    case "$(uname -m)" in
                        x86_64|amd64)  host_arch="x86_64" ;;
                        aarch64|arm64) host_arch="aarch64" ;;
                    esac
                fi
                for w in "${wtmp}"/*.whl; do
                    w_base="$(basename "${w}" .whl)"
                    plat="${w_base##*-}"
                    if [ "${plat}" = "any" ]; then
                        mv -f "${w}" "${wheel_cache}/"
                        log "    纯 Python wheel：$(basename "${w}")"
                    elif [ "${host_arch}" = "${ARCH}" ]; then
                        # 本机架构与目标一致的 Linux 主机（CI 原生腿）：原生构建出的
                        # linux_<arch> / manylinux*_<arch> 轮就是设备可直接使用的产物
                        # （ubuntu x86_64 构 crcmod 得 linux_x86_64 轮、arm64 腿得
                        # linux_aarch64 轮）。无编译器的 Windows 本机 pip 会静默降级
                        # 纯 Python 构建，自然走上面的 any 分支——本地与 CI 两条路都通。
                        case "${plat}" in
                            linux_${ARCH}|manylinux*_${ARCH})
                                mv -f "${w}" "${wheel_cache}/"
                                log "    原生 C 扩展 wheel：$(basename "${w}")"
                                ;;
                            *)
                                die "${req} 构建出的 wheel 平台标签异常：${plat}（目标 ${ARCH}）"
                                ;;
                        esac
                    else
                        die "${req} 为 C 扩展 sdist-only，本机（$(uname -m)）无法构建 ${ARCH} wheel（请在对应架构的 Linux CI 腿构建，或容器内 manylinux 化）"
                    fi
                done
                rm -rf "${wtmp}"
            done < "${wheel_cache}/lock.staging"
            # 回退补齐后重跑批量（已下载/已构建的会被跳过），确保闭包完整。
            # --platform 追加 linux_${ARCH}：原生腿构建的 C 扩展轮
            # （crcmod 等 sdist-only）标签是 linux_<arch>，不在 manylinux
            # 兼容集内，缺了它 pip 解析阶段就判「无匹配发行版」（纯 Python
            # any 轮不受影响，任意平台标签都兼容）。
            "${PY}" -m pip download \
                -r "${wheel_cache}/lock.staging" \
                --no-deps \
                --only-binary=:all: \
                --python-version "${PYV}" \
                --implementation cp \
                --abi "cp${PYV}" \
                --platform "manylinux2014_${ARCH}" \
                --platform "manylinux_2_17_${ARCH}" \
                --platform "manylinux_2_28_${ARCH}" \
                --platform "linux_${ARCH}" \
                --find-links "${wheel_cache}" \
                --dest "${wheel_cache}" \
                || die "pip download 回退重试仍失败"
        fi
        # 下载闭包完整后才把 lock 转正（缓存命中判定依据）
        mv -f "${wheel_cache}/lock.staging" "${wheel_cache}/payload.lock"
    fi

    rm -rf "${BUILD}/payload/wheels"
    cp -a "${wheel_cache}" "${BUILD}/payload/wheels"
    rm -f "${BUILD}/payload/wheels/payload.lock" "${BUILD}/payload/wheels/lock.staging"
    cp -f "${wheel_cache}/payload.lock" "${BUILD}/payload/payload.lock"
    log "wheels 就位：$(ls "${BUILD}/payload/wheels" | wc -l) 个文件，lock $(wc -l < "${BUILD}/payload/payload.lock") 项"
}

# --------------------------------------------------------------------------
# 6. CloakBrowser 内核（版本从随包 cloakbrowser wheel 解析，严格自洽）
# 官方包解压 flatten 后重组为 chromium-<v>/ 前缀的裸 tar（设备端直接解到缓存根）。
# --------------------------------------------------------------------------
prepare_kernel() {
    local cb_wheel cb_name
    cb_wheel="$(ls "${BUILD}/payload/wheels"/cloakbrowser-*.whl 2>/dev/null | head -1 || true)"
    [ -n "${cb_wheel}" ] || die "wheels 中未找到 cloakbrowser wheel（依赖解析异常）"
    cb_name="$(basename "${cb_wheel}")"
    CLOAKBROWSER_VERSION="$(cd "${BUILD}/payload/wheels" && "${PY}" -c '
import sys, zipfile, re
z = zipfile.ZipFile(sys.argv[1])
src = z.read("cloakbrowser/config.py").decode("utf-8")
m = re.search(r"PLATFORM_CHROMIUM_VERSIONS[^{]*\{(.*?)\}", src, re.S)
d = dict(re.findall(r"[\"\x27]([^\"\x27]+)[\"\x27]\s*:\s*[\"\x27]([^\"\x27]+)[\"\x27]", m.group(1)))
print(d[sys.argv[2]])
' "${cb_name}" "${CB_PLAT}")" || die "cloakbrowser 内核版本解析失败"
    [ -n "${CLOAKBROWSER_VERSION}" ] || die "cloakbrowser wheel 中未解析到 ${CB_PLAT} 内核版本"
    log "CloakBrowser ${CLOAKBROWSER_VERSION} 内核版本解析自 wheel（${CB_PLAT}）"

    local kernel_cache="${CACHE}/kernel/${CB_PLAT}"
    local kernel_tar="${kernel_cache}/chromium-${CLOAKBROWSER_VERSION}.tar"
    mkdir -p "${kernel_cache}"
    if [ ! -f "${kernel_tar}" ]; then
        local official="${kernel_cache}/cloakbrowser-${CB_PLAT}.tar.gz"
        if [ ! -f "${official}" ]; then
            log "下载 CloakBrowser 内核（~200MB）..."
            curl -fSL --retry 3 --connect-timeout 20 -o "${official}" \
                "https://github.com/CloakHQ/cloakbrowser/releases/download/chromium-v${CLOAKBROWSER_VERSION}/cloakbrowser-${CB_PLAT}.tar.gz" \
                || die "CloakBrowser 内核下载失败（chromium-v${CLOAKBROWSER_VERSION}）"
        fi
        log "重组内核 → chromium-${CLOAKBROWSER_VERSION}.tar"
        local tmp="${kernel_cache}/.repack"
        rm -rf "${tmp}"
        mkdir -p "${tmp}/extract" "${tmp}/stage"
        tar -xzf "${official}" -C "${tmp}/extract"
        # 官方包为单顶层目录结构（_extract_archive 的 flatten 规则）；兼容已 flat 的包
        local top
        top="$(ls "${tmp}/extract" | head -1)"
        if [ "$(ls "${tmp}/extract" | wc -l)" = "1" ] && [ -d "${tmp}/extract/${top}" ]; then
            mv "${tmp}/extract/${top}" "${tmp}/stage/chromium-${CLOAKBROWSER_VERSION}"
        else
            mv "${tmp}/extract" "${tmp}/stage/chromium-${CLOAKBROWSER_VERSION}"
        fi
        local chrome="chromium-${CLOAKBROWSER_VERSION}/chrome"
        [ -f "${tmp}/stage/${chrome}" ] || die "内核包中未找到 chrome 可执行文件（结构变化？）"
        # MSYS(noacl) 下 chmod 对 ELF 无效（仅 shebang 文件自动获得执行位），
        # 用 tar --mode 强制内核树统一 755（应用私有目录，数据文件带执行位无害；
        # Linux CI 上行为一致）；设备端 install_callback 释放后还会显式 chmod 兜底
        # 相对路径 + cwd 打包（Windows GNU tar 把 D:/... 当 host:path 远程语法）
        (cd "${tmp}/stage" && tar --mode=755 -cf "${kernel_tar}" "chromium-${CLOAKBROWSER_VERSION}")
        tar -tvf "${kernel_tar}" "${chrome}" | grep -q '^[-]rwx' \
            || die "内核 tar 中 chrome 缺少执行位"
        rm -rf "${tmp}"
    else
        log "内核已缓存：${kernel_tar}"
    fi

    mkdir -p "${BUILD}/payload/kernel"
    cp -f "${kernel_tar}" "${BUILD}/payload/kernel/"
}

# --------------------------------------------------------------------------
# 7. payload.meta + 总打包
# --------------------------------------------------------------------------
pack_payload() {
    local lock_sha
    lock_sha="$(cd "${BUILD}/payload" && "${PY}" -c 'import hashlib; print(hashlib.sha256(open("payload.lock","rb").read()).hexdigest())')"
    cat > "${BUILD}/payload/payload.meta" <<EOF
UPSTREAM_TAG=${TAG}
ARCH=${ARCH}
PYTHON_TAG=cp${PYV}
FRONTEND_VERSION=${FRONTEND_VERSION}
CLOAKBROWSER_VERSION=${CLOAKBROWSER_VERSION}
KERNEL_VERSION=${CLOAKBROWSER_VERSION}
LOCK_SHA256=${lock_sha}
BUILT=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    # 上游 wrapper 必须可执行（MSYS 下 shebang 文件自动带执行位，tar 会保留）
    chmod +x "${BUILD}/payload/MoviePilot/moviepilot" 2>/dev/null || true

    log "打包 payload.tar（未压缩）..."
    local out_rel="../payload-${ARCH}.tar"
    (cd "${BUILD}/payload" && tar -cf "${out_rel}" \
        MoviePilot wheels payload.lock payload.meta kernel)

    local out="${BUILD}/payload-${ARCH}.tar"
    # 校验关键执行位在 tar 中确实为 rwx（MSYS 权限映射异常时在此拦截）；
    # chrome 的执行位在内层 kernel tar 中（prepare_kernel 已单独断言）
    tar -tvf "${out}" | grep -E 'MoviePilot/moviepilot$' | grep -q '^[-]rwx' \
        || die "tar 中 moviepilot wrapper 缺少执行位（MSYS 权限映射异常）"

    log "完成：${out}（$(du -h "${out}" | cut -f1)）"
    log "  源码 ${TAG} / 前端 ${FRONTEND_VERSION} / 内核 chromium-${CLOAKBROWSER_VERSION} / lock ${lock_sha:0:12}..."
}

require_tools
fetch_source
stage_source
prepare_frontend
stage_resources
fetch_wheels
prepare_kernel
pack_payload
