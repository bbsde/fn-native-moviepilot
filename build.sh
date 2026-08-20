#!/usr/bin/env bash
#
# build.sh — v3 fpk 构建入口（本地 / CI 单一路径）
#
# 用法：./build.sh [upstream-tag|latest]
#   不带参数 = latest（GitHub API 解析上游最新 v3 tag）
#
# 环境变量：
#   MP_ARCHS          目标架构列表，空格分隔（默认 x86_64；CI 双架构传 "x86_64 aarch64"）
#   MP_APPVER         fpk 完整版本号（默认 <上游三段>.1，如 3.0.0.1）
#   MP_UPSTREAM       上游 tag（与位置参数等价，CI 注入用）
#   MP_SKIP_ASSEMBLE  =1 时复用 build/payload-<arch>.tar，跳过组装（快速重打 fpk）
#
# 流程：解析上游 tag → 逐架构组装 payload（scripts/assemble-payload.sh，缓存于 cache/）
#       → 临时目录组包（src/ 副本 + app/payload.tar + manifest 版本/平台 stamp）
#       → fnpack build → dist/moviepilot_<ver>_<x86|arm>.fpk（+ .sha256 + .info.txt）
# 仓库内 src/manifest 不被修改（版本/平台 stamp 只发生在 build/ 副本上）。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${REPO_DIR}/src"
BUILD_DIR="${REPO_DIR}/build"
DIST_DIR="${REPO_DIR}/dist"

g() { printf '\033[32m%s\033[0m\n' "$1"; }
y() { printf '\033[33m%s\033[0m\n' "$1"; }
r() { printf '\033[31m%s\033[0m\n' "$1"; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# --------------------------------------------------------------------------
# 解析上游 tag：位置参数 > MP_UPSTREAM > latest（GitHub API，只接受 v3.x tag）
# --------------------------------------------------------------------------
resolve_tag() {
    local tag="${1:-${MP_UPSTREAM:-}}"
    if [ -z "${tag}" ] || [ "${tag}" = "latest" ]; then
        log "解析上游最新 v3 release ..."
        local releases
        releases="$(curl -fsSL --retry 3 --connect-timeout 20 \
            "https://api.github.com/repos/jxxghp/MoviePilot/releases?per_page=20")" \
            || die "GitHub API 不可达（可显式指定 tag：./build.sh v3.0.0）"
        tag="$(printf '%s' "${releases}" | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/"tag_name": *"//;s/"//' | grep -E '^v3\.' | head -1 || true)"
        [ -n "${tag}" ] || die "未在最近 release 中找到 v3.x tag"
    fi
    echo "${tag}"
}

die() { r "[ERROR] $*"; exit 1; }

# fpk 版本：<上游三段>.<打包段>（上游段去 v 前缀；四段式如 3.0.0.1）
default_appver() {
    local bare="${1#v}"
    echo "${bare}.1"
}

# --------------------------------------------------------------------------
# 单架构构建
# --------------------------------------------------------------------------
build_arch() {
    local arch="$1" tag="$2" appver="$3"
    local plat suffix
    case "${arch}" in
        x86_64)  plat="x86";  suffix="x86" ;;
        aarch64) plat="arm";  suffix="arm" ;;
        *) die "不支持的架构：${arch}" ;;
    esac

    log "=== 构建架构 ${arch}（platform=${plat}）==="

    # 1. payload 组装（可复用缓存）
    local payload="${BUILD_DIR}/payload-${arch}.tar"
    if [ "${MP_SKIP_ASSEMBLE:-0}" = "1" ] && [ -f "${payload}" ]; then
        log "复用已组装 payload：${payload}（MP_SKIP_ASSEMBLE=1）"
    else
        bash "${REPO_DIR}/scripts/assemble-payload.sh" "${tag}" "${arch}"
    fi
    [ -f "${payload}" ] || die "payload 缺失：${payload}"

    # 2. 组包目录：src/ 副本 + payload.tar + manifest stamp（不触碰仓库 src/）
    local stage="${BUILD_DIR}/src-${arch}"
    rm -rf "${stage}"
    cp -a "${SRC_DIR}" "${stage}"
    # dsh 实战教训：fnpack 打包整个 app 目录，残留的其他架构 tar 会成为死重
    rm -f "${stage}"/app/payload*.tar
    cp -f "${payload}" "${stage}/app/payload.tar"
    sed -i -E "s|^version=.*|version=${appver}|" "${stage}/manifest"
    sed -i -E "s|^platform=.*|platform=${plat}|" "${stage}/manifest"

    # 3. fnpack（产物输出到 CWD，在 dist/ 内执行；日志落 dist/build.log）
    #    产物名固定为 <appname>.fpk（moviepilot.fpk），先清掉旧产物避免误判。
    mkdir -p "${DIST_DIR}"
    local pack_log="${DIST_DIR}/build.log"
    : > "${pack_log}"
    rm -f "${DIST_DIR}/moviepilot.fpk"
    if ! (cd "${DIST_DIR}" && fnpack build --directory "${stage}") >> "${pack_log}" 2>&1; then
        r "fnpack 构建失败，详见 ${pack_log}"
        exit 1
    fi

    # 4. 找到产出的 fpk（正常即 moviepilot.fpk；兜底取最新 fpk），重命名为规范名
    local produced="${DIST_DIR}/moviepilot.fpk"
    if [ ! -f "${produced}" ]; then
        produced="$(ls -t "${DIST_DIR}"/*.fpk 2>/dev/null | head -1 || true)"
    fi
    [ -n "${produced}" ] && [ -f "${produced}" ] || die "fnpack 未产出 fpk（详见 ${pack_log}）"
    local out="${DIST_DIR}/moviepilot_${appver}_${suffix}.fpk"
    mv -f "${produced}" "${out}"

    # 5. sha256 + 构建信息边车
    (cd "${DIST_DIR}" && sha256sum "$(basename "${out}")" > "${out}.sha256")
    {
        echo "app: moviepilot"
        echo "version: ${appver}"
        echo "upstream: ${tag}"
        echo "arch: ${arch}"
        echo "platform: ${plat}"
        echo "built: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "size: $(du -h "${out}" | cut -f1)"
    } > "${out}.info.txt"

    g "✓ ${out} ($(du -h "${out}" | cut -f1))"
}

main() {
    command -v fnpack >/dev/null 2>&1 || die "未找到 fnpack（本地安装或 CI 内先下载静态二进制）"
    [ -d "${SRC_DIR}" ] || die "src/ 目录不存在"

    local tag
    tag="$(resolve_tag "${1:-}")"
    local appver="${MP_APPVER:-$(default_appver "${tag}")}"
    local archs="${MP_ARCHS:-x86_64}"

    log "上游：${tag}   版本：${appver}   架构：${archs}"

    local arch
    for arch in ${archs}; do
        build_arch "${arch}" "${tag}" "${appver}"
    done

    g "完成。产物："
    ls -1 "${DIST_DIR}"/moviepilot_*_"${appver}"_*.fpk 2>/dev/null || true
}

main "$@"
