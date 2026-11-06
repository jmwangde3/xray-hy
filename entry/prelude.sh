#!/bin/sh
# ===========================================================================
# xray-hy —— 单文件安装 / 管理脚本
#
# 【这一段必须是 POSIX sh】Alpine 官方镜像不带 bash，用户会用
#     wget -qO- <url> | sh
# 直接跑它。等 bash 装好后 exec 自己，下面全部是 bash。
#
# 用法（三选一）：
#     bash <(curl -fsSL <url>)     有 bash + curl 的机器（Debian/Ubuntu/RHEL）
#     wget -qO- <url> | sh         全新 Alpine，busybox 就够
#     sh install.sh                已经下载到本地
#
# 环境变量：
#     XHY_APP_DIR       脚本安装目录，默认 /usr/local/lib/xray-hy
#     XHY_INSTALL_URL   自安装 / 自更新使用的地址
#     XHY_PKG_TIMEOUT   单次包操作上限秒数，默认 180
# ===========================================================================

XHY_APP_DIR="${XHY_APP_DIR:-/usr/local/lib/xray-hy}"
XHY_INSTALL_URL="${XHY_INSTALL_URL:-https://github.com/jmwangde3/xray-hy/releases/latest/download/install.sh}"
export XHY_APP_DIR XHY_INSTALL_URL

_xhy_say() { printf '%s\n' "$*"; }
_xhy_err() { printf '%s\n' "$*" >&2; }
_xhy_die() { _xhy_err "[x] $*"; exit 1; }

# curl 优先，busybox wget 兜底。两者都没有返回 127，由调用方给出提示。
_xhy_dl() {
    _u="$1"; _o="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 -m 300 "$_u" -o "$_o"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$_o" "$_u"
    else
        return 127
    fi
}

if [ -z "${BASH_VERSION:-}" ]; then
    # timeout 在极简镜像上可能没有；没有就直接跑，不要假装自己会超时。
    _xhy_run_lim() {
        _t="$1"; shift
        if command -v timeout >/dev/null 2>&1; then timeout "$_t" "$@"; else "$@"; fi
    }

    if ! command -v bash >/dev/null 2>&1; then
        _xhy_say "[*] 未检测到 bash，先安装（最多等 180 秒）..."
        if command -v apk >/dev/null 2>&1; then
            _xhy_run_lim 180 apk add --no-cache bash || {
                _xhy_err "[x] apk add bash 失败或超时。按顺序排查："
                _xhy_err "    1) 软件源/DNS 不通：apk update; cat /etc/resolv.conf"
                _xhy_err "    2) 另一个 apk 进程占锁（云厂商初始化脚本常见）：ps w | grep apk"
                _xhy_err "    3) 换源：sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories"
                _xhy_err "    4) 手动装齐依赖后重跑：apk add bash curl ca-certificates openssl coreutils"
                exit 1
            }
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive _xhy_run_lim 180 apt-get install -y bash || exit 1
        elif command -v dnf >/dev/null 2>&1; then
            _xhy_run_lim 180 dnf install -y bash || exit 1
        elif command -v yum >/dev/null 2>&1; then
            _xhy_run_lim 180 yum install -y bash || exit 1
        fi
    fi
    command -v bash >/dev/null 2>&1 || {
        _xhy_err "[x] xray-hy 需要 bash，但系统没有包管理器或安装失败。"
        _xhy_err "    Alpine: apk add bash    Debian/Ubuntu: apt-get install -y bash"
        exit 1
    }

    # 找一个可用的脚本本体。
    #   sh install.sh        -> $0 是真实文件，直接交给 bash
    #   curl ... | sh        -> $0 是 "sh"，stdin 已被吃过大半，只能按原地址重取
    #   bash <(curl ...)     -> 根本不会走到这里（BASH_VERSION 已设）
    _xhy_self="$0"
    case "$_xhy_self" in
        ""|sh|dash|ash|bash|-sh|-dash|-ash|/dev/fd/*|/proc/self/fd/*) _xhy_self="" ;;
    esac
    if [ -n "$_xhy_self" ] && [ -f "$_xhy_self" ]; then
        exec bash "$_xhy_self" "$@"
    fi

    _xhy_tmp="${TMPDIR:-/tmp}/xhy-install.$$"
    _xhy_say "[*] stdin 被管道占用，重新取一份脚本到 $_xhy_tmp ..."
    _xhy_dl "$XHY_INSTALL_URL" "$_xhy_tmp" \
        || _xhy_die "下载失败：$XHY_INSTALL_URL
    先装 curl（apk add curl / apt-get install -y curl），
    或本地下载后执行 sh install.sh"
    [ -s "$_xhy_tmp" ] || _xhy_die "下载到的文件是空的：$XHY_INSTALL_URL"

    # 管道喂进来时 stdin 已不可用于交互，优先接回终端，菜单和 confirm 才能用。
    if [ -t 0 ]; then
        exec bash "$_xhy_tmp" "$@"
    fi
    if [ -r /dev/tty ]; then
        exec bash "$_xhy_tmp" "$@" </dev/tty
    fi
    exec bash "$_xhy_tmp" "$@"
fi

# ===========================================================================
# 以下全部是 bash。上面那段在 bash 下会被整体跳过，但**不会**被解析执行。
# ===========================================================================
set -Eeuo pipefail

XHY_VERSION="1.4.1"
XHY_BUILD="__XHY_BUILD__"

# XHY_TRACE=1 xhy install —— 逐行打印，用来定位卡在哪一步。
if [[ "${XHY_TRACE:-0}" == "1" ]]; then
    PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

# 当前正在运行的文件。`bash <(curl ...)` 时 BASH_SOURCE 是 /dev/fd/63（管道，
# 不是普通文件），此时留空，install_self 会改为按 XHY_INSTALL_URL 重新下载。
XHY_RUNNING=""
if [[ -f "${BASH_SOURCE[0]}" ]]; then
    XHY_RUNNING="${BASH_SOURCE[0]}"
fi
