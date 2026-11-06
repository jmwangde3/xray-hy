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

XHY_VERSION="1.0.0"
XHY_BUILD="00e638285083"

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

# ===================== lib/common.sh =====================
# xray-hy / common helpers. Sourced by the entrypoint, never executed directly.

XHY_VERSION="${XHY_VERSION:-1.0.0}"
# 单文件发布时由 build.sh 写入真实构建号；仓库内运行就是 dev。
XHY_BUILD="${XHY_BUILD:-dev}"

# 单文件发布后，"脚本目录"只有两种含义：
#   已安装 -> /usr/local/lib/xray-hy（软链 /usr/local/bin/xhy 指过去）
#   仓库内 -> 仓库根（xhy 是开发入口，直接 source lib/）
# 测试会显式给出 XHY_SCRIPT_DIR，因此这里全部用「已存在就不覆盖」的写法。
XHY_SCRIPT_DIR="${XHY_SCRIPT_DIR:-${XHY_APP_DIR:-/usr/local/lib/xray-hy}}"
XHY_APP_DIR="${XHY_APP_DIR:-$XHY_SCRIPT_DIR}"
XHY_SELF="${XHY_SELF:-$XHY_APP_DIR/xhy}"
XHY_HOME="${XHY_HOME:-$XHY_APP_DIR}"
XHY_ETC="${XHY_ETC:-/etc/xray-hy}"
XHY_CONFDIR="$XHY_ETC/confs"
XHY_NODES="$XHY_ETC/nodes"
XHY_STATE="$XHY_ETC/state.env"
XHY_BACKUP="$XHY_ETC/backups"
XHY_SNAPSHOTS="$XHY_ETC/snapshots"
XHY_CERTS="$XHY_ETC/certs"
XHY_LOGDIR="${XHY_LOGDIR:-/var/log/xray-hy}"

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ASSET="${XRAY_ASSET:-/usr/local/share/xray}"
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"

# Two upstream boundaries pull in opposite directions:
#   >= v26.9.8    REALITY server requires X25519MLKEM768 in the ClientHello.
#                 sing-box / mihomo uTLS cannot send it, so those clients fail
#                 with "reality verification failed" (SagerNet/sing-box#4520).
#   >= v26.10.31  Xray disables MPTCP by default (XTLS#7291 / CVE-2026-98432,
#                 CVSS 9.8): Go 1.24+ otherwise exposes a remotely root-able
#                 MPTCP listener.
# We pin v26.3.27 by default for client compatibility and mitigate the MPTCP
# exposure at the kernel level with net.mptcp.enabled=0 (hardening.sh).
XHY_PINNED_VERSION="v26.3.27"
XHY_PQ_BREAK_VERSION="v26.9.8"
XHY_MPTCP_FIXED_VERSION="v26.10.31"
XHY_RELEASE_DL="https://github.com/XTLS/Xray-core/releases/download"
XHY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases"
XHY_CF_DL="https://github.com/cloudflare/cloudflared/releases/latest/download"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
debug() { [[ "${XHY_DEBUG:-0}" == "1" ]] && printf '%s[dbg]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; return 0; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Progress banner. Every slow step must announce itself: a stalled download or
# package install with no output is indistinguishable from a hung script, and
# that is the single most common "the script does nothing" report.
stage() { printf '\n%s==> [%s/%s]%s %s\n' "$C_BLUE" "$1" "$2" "$C_RESET" "$3"; }

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限运行，请使用 sudo 或切换到 root。"
}

# Read a single line from stdin with an optional default and 60s timeout.
ask() {
    local prompt="$1" default="${2:-}" reply=""
    if [[ -n "$default" ]]; then
        read -r -t 60 -p "$prompt [$default]: " reply || reply=""
    else
        read -r -t 60 -p "$prompt: " reply || reply=""
    fi
    printf '%s' "${reply:-$default}"
}

confirm() {
    local prompt="$1" default="${2:-n}" reply
    reply="$(ask "$prompt (y/n)" "$default")"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

init_dirs() {
    mkdir -p "$XHY_ETC" "$XHY_CONFDIR" "$XHY_LOGDIR" "$XHY_BACKUP" "$XHY_NODES" "$XHY_SNAPSHOTS" "$XHY_CERTS"
    chmod 0755 "$XHY_ETC" "$XHY_CONFDIR" "$XHY_LOGDIR" "$XHY_BACKUP" 2>/dev/null || true
    chmod 0700 "$XHY_NODES" "$XHY_SNAPSHOTS" "$XHY_CERTS" 2>/dev/null || true
    [[ -f "$XHY_STATE" ]] || : >"$XHY_STATE"
    chmod 0600 "$XHY_STATE" 2>/dev/null || true
}

# Serialize every config-mutating command. Without this, two concurrent `xhy`
# invocations can interleave fragment writes and silently lose a node.
# Idea borrowed from 0xdabiaoge/singbox-lite's cross-script shared lock.
XHY_LOCK_MODE=""
acquire_lock() {
    local i
    init_dirs
    if have_cmd flock; then
        exec 9>"$XHY_ETC/.lock"
        for ((i = 0; i < 15; i++)); do
            if flock -n 9 2>/dev/null; then XHY_LOCK_MODE="flock"; return 0; fi
            if (( i == 0 )); then
                info "另一个 xhy 实例正持有配置锁，等待最多 15 秒..."
            fi
            sleep 1
        done
        die "另一个 xhy 实例正在修改配置（锁: $XHY_ETC/.lock）。先确认它已退出：ps w | grep -c '[x]hy'"
    fi
    for ((i = 0; i < 15; i++)); do
        if mkdir "$XHY_ETC/.lock.d" 2>/dev/null; then XHY_LOCK_MODE="dir"; return 0; fi
        if (( i == 0 )); then
            info "另一个 xhy 实例正持有目录锁，等待最多 15 秒..."
        fi
        sleep 1
    done
    die "无法取得配置锁，若确认无其它实例请删除 $XHY_ETC/.lock.d"
}

release_lock() {
    if [[ "${XHY_LOCK_MODE:-}" == "dir" ]]; then
        rmdir "$XHY_ETC/.lock.d" 2>/dev/null || true
    fi
    XHY_LOCK_MODE=""
}

# Atomic write from stdin: printf '%s' "$content" | atomic_write <path> <mode>
atomic_write() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
    if ! cat >"$tmp"; then rm -f "$tmp" || true; return 1; fi
    if ! install -m "$mode" "$tmp" "$dest"; then rm -f "$tmp" || true; return 1; fi
    # The write already succeeded; a failing cleanup must not be reported as a
    # failed write (that produced misleading "配置生成失败" aborts).
    rm -f "$tmp" || true
    return 0
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$XHY_BACKUP"
    cp -a "$f" "$XHY_BACKUP/$(basename "$f").$(date +%Y%m%d%H%M%S).bak"
}

state_get() {
    local key="$1" default="${2:-}" val=""
    if [[ -f "$XHY_STATE" ]]; then
        val="$(grep -m1 "^${key}=" "$XHY_STATE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    printf '%s' "${val:-$default}"
}

state_set() {
    local key="$1" value="$2" tmp
    init_dirs
    tmp="$(mktemp)"
    if [[ -f "$XHY_STATE" ]]; then
        grep -v "^${key}=" "$XHY_STATE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    install -m 0600 "$tmp" "$XHY_STATE"
    rm -f "$tmp" || true
    return 0
}

state_del() {
    local key="$1" tmp
    [[ -f "$XHY_STATE" ]] || return 0
    tmp="$(mktemp)"
    grep -v "^${key}=" "$XHY_STATE" >"$tmp" || true
    install -m 0600 "$tmp" "$XHY_STATE"
    rm -f "$tmp" || true
    return 0
}

rand_hex() {
    local n="${1:-8}"
    if [[ -r /dev/urandom ]]; then
        head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$n"
    else
        openssl rand -hex 32 | cut -c1-"$n"
    fi
}

rand_path() { printf '/%s' "$(rand_hex 16)"; }

uuid_gen() {
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" uuid 2>/dev/null | tr -d '\r' | head -1
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

url_encode() {
    local s="$1" out="" i c o
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; out+="$o" ;;
        esac
    done
    printf '%s' "$out"
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_busy() {
    local p="$1"
    if have_cmd ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif have_cmd netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 1
    fi
}

public_ip() {
    local ip=""
    ip="$(curl -fsS -m 8 -4 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -fsS -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1 || true)"
    printf '%s' "${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
}

# IPv6 出口。结果缓存在 XHY_IP6_CACHE（含空值）：无 v6 的机器上每次调用都要
# 等一次完整超时，而 link/check 会多次调用。无 v6 路由时 curl -6 立即报
# "Network unreachable"，所以首次探测在有路由的机器上也是快的。
public_ip6() {
    if [[ -n "${XHY_IP6_CACHE+x}" ]]; then printf '%s' "$XHY_IP6_CACHE"; return 0; fi
    local ip=""
    ip="$(curl -fsS -m 5 -6 https://api64.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -fsS -m 5 -6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1 || true)"
    XHY_IP6_CACHE="$ip"
    printf '%s' "$ip"
}

public_country() {
    local cc=""
    cc="$(curl -fsS -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=//p' | head -1 || true)"
    [[ -z "$cc" ]] && cc="$(curl -fsS -m 8 "https://ipapi.co/country" 2>/dev/null | tr -d '\r\n' | head -c 2 || true)"
    printf '%s' "${cc^^}"
}

# Fetch with retries. Never pipes remote content into a shell.
# --speed-time/--speed-limit turn a stalled connection into a fast failure:
# without them a blackholed route just sits there for the full timeout and the
# caller looks hung. Exit codes are translated so the report is actionable.
fetch() {
    local url="$1" dest="$2" rc=0
    debug "fetch $url"
    curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 \
        --speed-time 30 --speed-limit 1024 -m 300 -sS "$url" -o "$dest" || rc=$?
    if (( rc != 0 )); then
        err "下载失败 (curl 退出码 $rc): $url"
        case "$rc" in
            6)      err "  6  = 域名解析失败 → 检查 /etc/resolv.conf、DNS、IPv6" ;;
            7)      err "  7  = 连不上主机 → 出网被拦 / 端口被封 / 只解析到不可用地址" ;;
            28)     err "  28 = 超时或速度过低 → 线路不通；先 curl -I <url> 验证" ;;
            22)     err "  22 = HTTP 4xx/5xx → 版本号或路径不存在（404），或私有仓库未授权" ;;
            35|60)  err "  $rc = TLS 握手/证书问题 → 装 ca-certificates、校准时间" ;;
        esac
        return "$rc"
    fi
    return 0
}

sha256_file() {
    if have_cmd sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif have_cmd openssl; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        die "缺少 sha256sum / openssl，无法校验下载内容"
    fi
}

# Force-verified download of an Xray release archive.
# Xray publishes <asset>.dgst files containing the SHA-256 of each archive.
verify_release_digest() {
    local dgst="$1" archive="$2" expected actual
    expected="$(grep -Eio 'SHA2?-?256[^A-Za-z0-9]*=?[[:space:]]*[0-9a-fA-F]{64}' "$dgst" 2>/dev/null \
        | grep -Eio '[0-9a-fA-F]{64}' | head -1 | tr 'A-F' 'a-f' || true)"
    [[ -n "$expected" ]] || { err "无法从 .dgst 解析 SHA-256，拒绝继续。"; return 1; }
    actual="$(sha256_file "$archive" | tr 'A-F' 'a-f')"
    if [[ "$expected" != "$actual" ]]; then
        err "SHA-256 校验失败：期望 $expected，实际 $actual"
        return 1
    fi
    ok "SHA-256 校验通过 (${actual:0:16}...)"
}

# ===================== lib/platform.sh =====================
# xray-hy / distribution, init system and architecture detection.

XHY_DISTRO="unknown"
XHY_DISTRO_VER=""
XHY_INIT="unknown"
XHY_PKG="unknown"
XHY_ARCH=""
XHY_SSH_PORT="22"

detect_platform() {
    local id="" arch=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"
        XHY_DISTRO_VER="${VERSION_ID:-}"
    fi
    case "$id" in
        debian|ubuntu|devuan|linuxmint|raspbian|pop)
            XHY_DISTRO="debian"; XHY_PKG="apt" ;;
        alpine)
            XHY_DISTRO="alpine"; XHY_PKG="apk" ;;
        centos|rhel|rocky|almalinux|fedora)
            XHY_DISTRO="rhel"; XHY_PKG="dnf" ;;
        *)
            if have_cmd apt-get;      then XHY_DISTRO="debian"; XHY_PKG="apt"
            elif have_cmd apk;        then XHY_DISTRO="alpine"; XHY_PKG="apk"
            elif have_cmd dnf;        then XHY_DISTRO="rhel";   XHY_PKG="dnf"
            elif have_cmd yum;        then XHY_DISTRO="rhel";   XHY_PKG="yum"
            else die "未识别的发行版 ($id)，仅支持 Debian/Ubuntu、Alpine、RHEL 系。"; fi ;;
    esac

    if [[ -d /run/systemd/system ]] && have_cmd systemctl; then
        XHY_INIT="systemd"
    elif have_cmd rc-service && have_cmd rc-update; then
        XHY_INIT="openrc"
    else
        die "未识别的 init 系统（需要 systemd 或 OpenRC）。"
    fi

    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  XHY_ARCH="64" ;;
        aarch64|arm64) XHY_ARCH="arm64-v8a" ;;
        armv7l|armv6l) XHY_ARCH="arm32-v7a" ;;
        i386|i686)     XHY_ARCH="32" ;;
        *) die "不支持的 CPU 架构: $arch" ;;
    esac

    detect_ssh_port
    debug "platform: distro=$XHY_DISTRO init=$XHY_INIT pkg=$XHY_PKG arch=$XHY_ARCH ssh=$XHY_SSH_PORT"
}

# Read the current SSH port. This script NEVER edits sshd_config: changing it
# remotely is the single most common way to lock oneself out of a VPS.
detect_ssh_port() {
    local p="" f
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -r "$f" ]] || continue
        # 每个 grep 都可能无匹配（Alpine 出厂 sshd_config 全是注释行）；
        # 在 set -euo pipefail 下，管道里任何一个非零都会把整个脚本无声杀掉，
        # 这正是「install 一行输出都没有」的根因，所以一律 || true 兜底。
        p="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" 2>/dev/null | head -1 | awk '{print $2}' || true)"
        [[ -n "$p" ]] && break
    done
    if [[ -z "$p" ]] && have_cmd ss; then
        p="$(ss -H -ltnp 2>/dev/null | grep -iE 'sshd|dropbear' | head -1 \
            | awk '{print $4}' | sed -E 's/.*[:.]//' || true)"
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p="22"
    XHY_SSH_PORT="$p"
}

# Every package operation is bounded. An unreachable mirror otherwise blocks
# for minutes with no output, which users report as "the script does nothing".
XHY_PKG_TIMEOUT="${XHY_PKG_TIMEOUT:-180}"

run_lim() { # run_lim <seconds> <cmd...>
    local t="$1"; shift
    if have_cmd timeout; then timeout "$t" "$@"; else "$@"; fi
}

pkg_hint() {
    warn "软件源操作失败或超时（上限 ${XHY_PKG_TIMEOUT}s）。按顺序排查："
    case "$XHY_PKG" in
        apk) warn "  1) 网络/DNS：apk update；cat /etc/resolv.conf"
             warn "  2) 换源：sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories"
             warn "  3) 锁：ps w | grep apk（云厂商 cloud-init 常占锁）"
             warn "  4) 手动装：apk add bash curl ca-certificates openssl coreutils unzip iptables ip6tables" ;;
        apt) warn "  1) 网络/DNS：apt-get update；cat /etc/resolv.conf"
             warn "  2) 锁：ps aux | grep -E 'apt|dpkg'"
             warn "  3) 手动装：apt-get install -y bash curl ca-certificates openssl coreutils unzip iptables" ;;
        *)   warn "  检查网络、DNS 与软件源配置" ;;
    esac
}

pkg_update() {
    case "$XHY_PKG" in
        apt) DEBIAN_FRONTEND=noninteractive run_lim "$XHY_PKG_TIMEOUT" apt-get update -qq ;;
        apk) run_lim "$XHY_PKG_TIMEOUT" apk update -q ;;
        dnf) run_lim "$XHY_PKG_TIMEOUT" dnf -q makecache ;;
        yum) run_lim "$XHY_PKG_TIMEOUT" yum -q makecache ;;
    esac
}

pkg_install() {
    case "$XHY_PKG" in
        apt) DEBIAN_FRONTEND=noninteractive run_lim "$XHY_PKG_TIMEOUT" apt-get install -y -qq --no-install-recommends "$@" ;;
        apk) run_lim "$XHY_PKG_TIMEOUT" apk add --no-cache "$@" ;;
        dnf) run_lim "$XHY_PKG_TIMEOUT" dnf install -y -q "$@" ;;
        yum) run_lim "$XHY_PKG_TIMEOUT" yum install -y -q "$@" ;;
    esac
}

# Minimal dependency set. Xray is a static binary; no glibc compatibility layer.
ensure_deps() {
    local missing=() want=(bash ca-certificates curl openssl coreutils)
    case "$XHY_DISTRO" in
        alpine) want+=(iptables ip6tables unzip) ;;
        debian) want+=(iptables unzip procps) ;;
        rhel)   want+=(iptables unzip procps-ng) ;;
    esac
    local c
    for c in "${want[@]}"; do
        case "$c" in
            coreutils) have_cmd sha256sum || missing+=("$c") ;;
            procps|procps-ng) have_cmd ss || missing+=("$c") ;;
            *) have_cmd "$c" || missing+=("$c") ;;
        esac
    done
    if (( ${#missing[@]} > 0 )); then
        info "缺少依赖: ${missing[*]}"
        info "刷新软件源（上限 ${XHY_PKG_TIMEOUT}s，无输出时多半卡在这里）..."
        pkg_update || { warn "软件源刷新失败，继续尝试安装。"; pkg_hint; }
        info "安装中（上限 ${XHY_PKG_TIMEOUT}s）..."
        pkg_install "${missing[@]}" || { pkg_hint; die "依赖安装失败: ${missing[*]}"; }
    fi
    have_cmd bash || die "缺少 bash，无法继续（apk add bash / apt-get install -y bash）。"
    have_cmd unzip || have_cmd busybox || die "缺少 unzip/busybox，无法解压 Xray。"
}

# Optional helpers, installed only when the user asks for them.
ensure_optional() {
    case "$1" in
        qrencode)
            if ! have_cmd qrencode; then
                case "$XHY_DISTRO" in
                    alpine) pkg_install libqrencode libqrencode-tools 2>/dev/null || true ;;
                    debian) pkg_install qrencode 2>/dev/null || true ;;
                    rhel)   pkg_install qrencode 2>/dev/null || true ;;
                esac
            fi ;;
        logrotate)
            if ! have_cmd logrotate; then
                case "$XHY_DISTRO" in
                    alpine) pkg_install logrotate 2>/dev/null || true ;;
                    debian) pkg_install logrotate 2>/dev/null || true ;;
                    rhel)   pkg_install logrotate 2>/dev/null || true ;;
                esac
            fi ;;
    esac
}

platform_summary() {
    printf '发行版   : %s %s\n' "$XHY_DISTRO" "$XHY_DISTRO_VER"
    printf 'Init     : %s\n' "$XHY_INIT"
    printf '架构     : %s (Xray asset: Xray-linux-%s.zip)\n' "$(uname -m)" "$XHY_ARCH"
    printf 'SSH 端口 : %s (只读，脚本不会修改 sshd_config)\n' "$XHY_SSH_PORT"
}

# ===================== lib/core.sh =====================
# xray-hy / Xray core download, version channels, key generation, cloudflared.

xray_channel() { state_get XRAY_CHANNEL "pinned"; }

# Compare vX.Y.Z without relying on `sort -V` (absent in busybox).
version_num() {
    local v="${1#v}"; v="${v%%-*}"
    local IFS='.' p=()
    read -r -a p <<<"$v"
    printf '%d%03d%03d\n' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}"
}
version_lt() { (( $(version_num "$1") < $(version_num "$2") )); }

xray_set_channel() {
    case "$1" in
        pinned|latest|v[0-9]*) state_set XRAY_CHANNEL "$1" ;;
        *) die "版本通道只能是 pinned / latest / vX.Y.Z，收到: $1" ;;
    esac
    local target mptcp
    target="$(xray_resolve_version)"
    [[ "$target" == v* ]] || { warn "无法确认目标版本，跳过兼容性检查"; return 0; }
    if ! version_lt "$target" "$XHY_PQ_BREAK_VERSION"; then
        warn "兼容性: $target >= $XHY_PQ_BREAK_VERSION，REALITY 服务端会要求 ClientHello 带 X25519MLKEM768。"
        warn "sing-box / mihomo 客户端将报 reality verification failed (SagerNet/sing-box#4520)。"
        warn "若使用这些客户端，请保持 pinned ($XHY_PINNED_VERSION)。"
    fi
    if version_lt "$target" "$XHY_MPTCP_FIXED_VERSION"; then
        mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo unknown)"
        warn "安全: $target < $XHY_MPTCP_FIXED_VERSION，Xray 默认启用 MPTCP (CVE-2026-98432)。"
        if [[ "$mptcp" == "0" ]]; then
            ok "  已由内核 net.mptcp.enabled=0 缓解（xhy bbr on 可重新设置）。"
        else
            warn "  内核 MPTCP=$mptcp，请执行 xhy bbr on 关闭它。"
        fi
    fi
}

xray_resolve_version() {
    local ch tag=""
    ch="$(xray_channel)"
    case "$ch" in
        pinned)  printf '%s' "$XHY_PINNED_VERSION"; return 0 ;;
        v[0-9]*) printf '%s' "$ch"; return 0 ;;
        latest)  ;;
    esac
    tag="$(curl -fsSL -m 15 "$XHY_RELEASE_API/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ ! "$tag" =~ ^v[0-9] ]]; then
        warn "无法从 GitHub API 获取最新版本，回退到 $XHY_PINNED_VERSION"
        tag="$XHY_PINNED_VERSION"
    fi
    printf '%s' "$tag"
}

xray_installed_version() {
    [[ -x "$XRAY_BIN" ]] || { printf '未安装'; return; }
    "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r' || true
}

# Download a pinned-or-latest Xray release. The .dgst checksum is MANDATORY:
# unlike most one-key scripts, a missing digest aborts instead of continuing.
xray_install() {
    local ver="$1" asset tmp unpack f oldver
    # Keep the currently working binary before replacing it. A failed download
    # never reaches this point; a failed post-install check can still roll back.
    if [[ -x "$XRAY_BIN" ]]; then
        oldver="$(xray_installed_version)"
        install -d -m 0700 "$XHY_BACKUP"
        cp -a "$XRAY_BIN" "$XHY_BACKUP/xray-${oldver//[^0-9A-Za-z._-]/_}-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    asset="Xray-linux-${XHY_ARCH}.zip"
    tmp="$(mktemp -d)" || die "无法创建临时目录"
    unpack="$tmp/unpack"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    info "下载 Xray $ver ($asset)"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}" "$tmp/$asset" \
        || die "Xray 压缩包下载失败（版本 $ver 是否存在？架构 $XHY_ARCH 是否受支持？）"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}.dgst" "$tmp/$asset.dgst" \
        || die "SHA-256 摘要文件下载失败。出于安全考虑拒绝安装未校验的二进制。"
    verify_release_digest "$tmp/$asset.dgst" "$tmp/$asset" || die "校验失败，已中止。"

    mkdir -p "$unpack"
    if have_cmd unzip; then
        unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    else
        busybox unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    fi
    [[ -f "$unpack/xray" ]] || die "压缩包中缺少 xray 二进制"

    install -d -m 0755 "$(dirname "$XRAY_BIN")" "$XRAY_ASSET"
    install -m 0755 "$unpack/xray" "$XRAY_BIN"
    for f in geoip.dat geosite.dat; do
        [[ -s "$unpack/$f" ]] && install -m 0644 "$unpack/$f" "$XRAY_ASSET/$f"
    done

    # Older/newer release archives occasionally omit geodata. geoip:private
    # routing rules need it, so fetch the community dat files as a fallback.
    for f in geoip.dat geosite.dat; do
        if [[ ! -s "$XRAY_ASSET/$f" ]]; then
            info "补充下载 $f"
            fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" \
                "$XRAY_ASSET/$f" || warn "$f 下载失败，相关路由规则将不生效"
        fi
    done

    local got
    got="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r' || true)"
    [[ -n "$got" ]] || die "下载的 Xray 无法运行（架构或依赖不匹配）"
    if [[ "v$got" != "$ver" ]]; then
        warn "版本校验: 请求 $ver，实际 v$got（预发布版或镜像差异时可能不同，请确认）"
    fi
    ok "Xray v$got 安装完成，SHA-256 校验通过"
}

x25519_keypair() {
    local out priv pub
    out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" x25519 2>/dev/null)" \
        || { err "xray x25519 执行失败"; return 1; }
    # v26 changed "Password" to "Password (PublicKey)"; match both.
    priv="$(printf '%s\n' "$out" | grep -iE '^PrivateKey|^Private[ _]key' | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r\n' || true)"
    pub="$(printf '%s\n' "$out" | grep -iE '^Password|^PublicKey|^Public[ _]key' | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r\n' || true)"
    [[ -n "$priv" && -n "$pub" ]] || { err "无法解析 x25519 输出: $out"; return 1; }
    printf '%s %s\n' "$priv" "$pub"
}

short_ids() { printf '%s %s\n' "$(rand_hex 8)" "$(rand_hex 16)"; }

cloudflared_install() {
    local cfarch url tmp
    case "$XHY_ARCH" in
        64)        cfarch="amd64" ;;
        arm64-v8a) cfarch="arm64" ;;
        *) die "Cloudflare Tunnel 不支持当前架构 ($XHY_ARCH)" ;;
    esac
    url="${XHY_CF_DL}/cloudflared-linux-${cfarch}"
    tmp="$(mktemp)" || die "无法创建临时文件"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    info "下载 cloudflared ($cfarch)"
    fetch "$url" "$tmp" || die "cloudflared 下载失败"
    # Cloudflare does not publish checksums for these raw binaries. At minimum
    # verify the ELF magic and that the binary actually runs before installing.
    [[ "$(head -c 4 "$tmp")" == $'\x7fELF' ]] || die "cloudflared 下载内容不是 ELF 二进制，已中止"
    chmod 0755 "$tmp"
    "$tmp" --version >/dev/null 2>&1 || die "下载的 cloudflared 无法运行"
    install -m 0755 "$tmp" "$CF_BIN"
    warn "cloudflared 官方 raw 二进制不提供校验和，已做 ELF + 版本自检（无法做到密码学验证）"
    ok "cloudflared 已安装: $("$CF_BIN" --version 2>&1 | head -1)"
}

core_status() {
    local ch ver
    ch="$(xray_channel)"
    ver="$(xray_installed_version)"
    printf '版本通道 : %s\n' "$ch"
    case "$ch" in
        pinned) printf '钉死版本 : %s\n' "$XHY_PINNED_VERSION" ;;
        latest) printf '目标版本 : %s\n' "$(xray_resolve_version)" ;;
        *)      printf '自定义版本: %s\n' "$ch" ;;
    esac
    printf '已装版本 : %s\n' "$ver"
    printf '二进制   : %s\n' "$XRAY_BIN"
    printf 'Geodata  : %s\n' "$XRAY_ASSET"
    [[ -s "$XRAY_ASSET/geoip.dat" ]] && printf '  geoip.dat   %s bytes\n' "$(stat -c%s "$XRAY_ASSET/geoip.dat" 2>/dev/null || echo '?')"
    [[ -s "$XRAY_ASSET/geosite.dat" ]] && printf '  geosite.dat %s bytes\n' "$(stat -c%s "$XRAY_ASSET/geosite.dat" 2>/dev/null || echo '?')"
    [[ -x "$CF_BIN" ]] && printf 'cloudflared: %s\n' "$("$CF_BIN" --version 2>&1 | head -1)"
}

# Xray-core gained a native Hysteria2 inbound in v26.3.27 (protocol name is
# "hysteria", version must be 2). It requires a TLS certificate. Generate a
# self-signed one and pin its SHA-256 in the share link so clients verify it
# instead of blindly using insecure=1.
# Echo: <crt path> <key path> <pin base64> <pin hex>
hy2_gen_cert() {
    local port="$1" sni="$2" crt key pin_b64 pin_hex
    crt="$XHY_CERTS/hy2_${port}.crt"
    key="$XHY_CERTS/hy2_${port}.key"
    install -d -m 0700 "$XHY_CERTS"
    have_cmd openssl || die "生成 Hysteria2 证书需要 openssl"
    if ! openssl req -x509 -nodes -newkey ec \
            -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$key" -out "$crt" -subj "/CN=${sni}" \
            -addext "subjectAltName=DNS:${sni}" -days 3650 >/dev/null 2>&1; then
        rm -f "$crt" "$key"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$key" -out "$crt" -subj "/CN=${sni}" \
            -days 3650 >/dev/null 2>&1 || die "自签证书生成失败"
    fi
    chmod 0600 "$key" "$crt"
    pin_b64="$(openssl x509 -in "$crt" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n')"
    pin_hex="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/.*=//;s/://g' | tr 'A-F' 'a-f')"
    [[ -n "$pin_b64" ]] || die "无法计算证书 SHA-256 指纹"
    printf '%s %s %s %s\n' "$crt" "$key" "$pin_b64" "$pin_hex"
}

# ===================== lib/service.sh =====================
# xray-hy / service management for systemd and OpenRC.

SVC_XRAY="xray-hy"
SVC_CF="xray-hy-tunnel"
SVC_FW="xray-hy-firewall"

svc_enable() {
    local n="$1"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable "$n" >/dev/null 2>&1
    else
        rc-update add "$n" default >/dev/null 2>&1
    fi
}

svc_disable() {
    local n="$1" rl
    if [[ "$XHY_INIT" == "systemd" ]]; then
        systemctl disable "$n" >/dev/null 2>&1 || true
    else
        # The firewall unit is registered in the *boot* runlevel while ordinary
        # services live in *default*. Removing only "default" left the firewall
        # chain being rebuilt at every boot after `xhy firewall off`.
        for rl in default boot; do
            rc-update del "$n" "$rl" >/dev/null 2>&1 || true
        done
    fi
}

# Close fd 9 (the global config lock) on every service command. OpenRC forks
# daemons from the calling shell: if Xray inherits the lock fd, the lock stays
# held for the lifetime of the service and every later `xhy` call deadlocks.
# Same pattern as singbox-lite's explicit `9>&- 219>&-` on service actions.
svc_start()   { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl start "$1" 9>&-;   else rc-service "$1" start 9>&-;   fi; }
svc_stop()    { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl stop "$1" 9>&- >/dev/null 2>&1 || true; else rc-service "$1" stop 9>&- >/dev/null 2>&1 || true; fi; }
svc_restart() { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl restart "$1" 9>&-; else rc-service "$1" restart 9>&-; fi; }
svc_status()  { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl status "$1" --no-pager -l 9>&-; else rc-service "$1" status 9>&-; fi; }
svc_active()  { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl is-active --quiet "$1" 9>&-; else rc-service "$1" status 9>&- >/dev/null 2>&1; fi; }

# Bound the Go runtime heap on small VPS / memory-limited containers. singbox-lite
# does this via GOMEMLIMIT; without it a 128-256MB box can OOM-kill Xray.
compute_gomemlimit() {
    local kb cg mb f
    kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    # cgroup v2 exposes both a hard limit (memory.max) and a soft throttle
    # (memory.high); take the smaller of the two, then min() with physical RAM.
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high \
             /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$f" ]] || continue
        cg="$(cat "$f" 2>/dev/null || echo max)"
        [[ "$cg" =~ ^[0-9]+$ ]] || continue
        cg=$((cg / 1024))
        if (( cg > 0 && cg < kb )); then kb="$cg"; fi
    done
    mb=$((kb / 1024 / 4))
    (( mb < 32 )) && mb=32
    (( mb > 512 )) && mb=512
    printf '%sMiB' "$mb"
}

# Unbounded append-logs eventually fill a small VPS disk. Install a rotation
# policy whenever logrotate is available; never fail installation without it.
install_logrotate() {
    local cfg="/etc/logrotate.d/xray-hy" restart_cmd
    if ! have_cmd logrotate; then
        ensure_optional logrotate
        have_cmd logrotate || {
            warn "未安装 logrotate：$XHY_LOGDIR 下日志不会自动轮转，请手动 apt/apk install logrotate";
            return 0;
        }
    fi
    if [[ "$XHY_INIT" == "systemd" ]]; then
        restart_cmd="systemctl restart xray-hy >/dev/null 2>&1 || true"
    else
        restart_cmd="rc-service xray-hy restart >/dev/null 2>&1 || true"
    fi
    install -d -m 0755 /etc/logrotate.d "$XHY_LOGDIR"
    backup_file "$cfg"
    cat >"$cfg" <<EOF
${XHY_LOGDIR}/*.log {
    weekly
    rotate 4
    maxsize 32M
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    sharedscripts
    postrotate
        $restart_cmd
    endscript
}
EOF
    if [[ "$XHY_DISTRO" == "alpine" ]]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
    ok "日志轮转已配置 ($cfg)"
}

install_xray_service() {
    local memlimit
    memlimit="$(compute_gomemlimit)"
    backup_file "$XHY_ETC/config.json"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy.service <<EOF
[Unit]
Description=xray-hy Xray multi-node service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XHY_ETC}/config.json
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET}
Environment=GOMEMLIMIT=${memlimit}
# Defence in depth for pinned Xray < v26.10.31: Go 1.24+ listeners ask the
# kernel for MPTCP by default. Force plain TCP even if the sysctl is reset.
Environment=GODEBUG=multipathtcp=0
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=append:${XHY_LOGDIR}/xray.log
StandardError=append:${XHY_LOGDIR}/xray.err

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat >/etc/init.d/xray-hy <<'EOF'
#!/sbin/openrc-run
name="xray-hy"
description="xray-hy Xray multi-node service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray-hy/config.json"
command_background=true
pidfile="/run/xray-hy.pid"
output_log="/var/log/xray-hy/xray.log"
error_log="/var/log/xray-hy/xray.err"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
export GOMEMLIMIT="MEMLIMIT"
export GODEBUG="multipathtcp=0"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root /var/log/xray-hy
    XRAY_LOCATION_ASSET="/usr/local/share/xray" \
        "$command" run -test -c /etc/xray-hy/config.json || return 1
}
EOF
        chmod 0755 /etc/init.d/xray-hy
        sed -i "s|MEMLIMIT|${memlimit}|" /etc/init.d/xray-hy
    fi
    svc_enable "$SVC_XRAY"
    install_logrotate
    ok "Xray 服务已安装并设为开机自启 ($XHY_INIT, GOMEMLIMIT=${memlimit})"
}

install_cf_service() {
    # A tiny wrapper reads the root-only token file and execs cloudflared.
    # Keeping this out of the unit avoids shell-quoting differences between
    # systemd and OpenRC. The token is still visible in `ps` by design of
    # cloudflared's token mode; the file itself stays mode 0600.
    install -d -m 0755 /usr/local/lib/xray-hy "$XHY_LOGDIR"
    cat >/usr/local/lib/xray-hy/tunnel-run <<EOF
#!/bin/sh
set -e
[ -s ${XHY_ETC}/tunnel.token ] || { echo "missing tunnel.token" >&2; exit 1; }
TOKEN="\$(cat ${XHY_ETC}/tunnel.token)"
exec ${CF_BIN} tunnel --no-autoupdate run --token "\$TOKEN"
EOF
    chmod 0755 /usr/local/lib/xray-hy/tunnel-run
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy-tunnel.service <<EOF
[Unit]
Description=xray-hy Cloudflare Tunnel connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/lib/xray-hy/tunnel-run
Restart=on-failure
RestartSec=5
StandardOutput=append:${XHY_LOGDIR}/cloudflared.log
StandardError=append:${XHY_LOGDIR}/cloudflared.err

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat >/etc/init.d/xray-hy-tunnel <<'EOF'
#!/sbin/openrc-run
name="xray-hy-tunnel"
description="xray-hy Cloudflare Tunnel connector"
command="/usr/local/lib/xray-hy/tunnel-run"
command_background=true
pidfile="/run/xray-hy-tunnel.pid"
output_log="/var/log/xray-hy/cloudflared.log"
error_log="/var/log/xray-hy/cloudflared.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root /var/log/xray-hy
}
EOF
        chmod 0755 /etc/init.d/xray-hy-tunnel
    fi
    svc_enable "$SVC_CF"
}

remove_cf_service() {
    svc_stop "$SVC_CF" 2>/dev/null || true
    svc_disable "$SVC_CF"
    rm -f /etc/systemd/system/xray-hy-tunnel.service /etc/init.d/xray-hy-tunnel
    [[ "$XHY_INIT" == "systemd" ]] && systemctl daemon-reload
}

# Validate the fully rendered config before it is ever handed to the service.
xray_config_test() {
    local cfg="${1:-$XHY_ETC/config.json}"
    [[ -s "$cfg" ]] || { err "配置文件为空或不存在: $cfg"; return 1; }
    XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" run -test -c "$cfg" 2>&1
}

config_reload() {
    if ! xray_config_test; then
        err "配置校验失败，保持原有运行配置不变。"
        return 1
    fi
    svc_restart "$SVC_XRAY" || { err "Xray 重启失败，查看 $XHY_LOGDIR/xray.err"; return 1; }
    ok "配置已重载"
}

# ===================== lib/hardening.sh =====================
# xray-hy / kernel tuning (BBR + MPTCP), dual-stack firewall, SSH guard.
# Both iptables and ip6tables get the SAME policy: an IPv6 hole would let an
# attacker bypass every IPv4-only rate limit (sshd usually listens on :::22).

FW_CHAIN="XHY-IN"

in_container() {
    [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qE '^container=|^lxc'
}

# Alpine does not load tcp_bbr / sch_fq at boot and its sysctl service lives in
# the *boot* runlevel. Debian only needs sysctl.d. Containers get a graceful skip.
tune_bbr() {
    local avail="" sysctl_file="/etc/sysctl.d/90-xray-hy.conf"
    if in_container; then
        warn "检测到容器环境，内核参数通常不可写；跳过 BBR（宿主侧才需要设置）。"
        state_set BBR_STATUS "container-skip"
        return 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ "$avail" != *bbr* ]]; then
        warn "当前内核未提供 tcp_bbr ($avail)。Alpine 请确认使用带 BBR 的内核；OpenVZ/LXC 无法开启。"
        state_set BBR_STATUS "unavailable"
        return 1
    fi

    if [[ "$XHY_DISTRO" == "alpine" ]]; then
        install -d -m 0755 /etc/modules-load.d
        printf 'tcp_bbr\nsch_fq\n' >/etc/modules-load.d/xray-hy.conf
        rc-update add sysctl boot >/dev/null 2>&1 || true
        sed -i -e '/net.core.default_qdisc/d' -e '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >>/etc/sysctl.conf
    fi

    install -d -m 0755 /etc/sysctl.d
    backup_file "$sysctl_file"
    cat >"$sysctl_file" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.ip_forward = 0
EOF
    # XTLS#7291 / CVE-2026-98432: Go 1.24+ enables MPTCP on listeners by
    # default. Disable it system-wide when the kernel exposes the knob.
    if [[ -e /proc/sys/net/mptcp/enabled ]]; then
        printf '\n# CVE-2026-98432 / XTLS#7291\nnet.mptcp.enabled = 0\n' >>"$sysctl_file"
        sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1 || true
        state_set MPTCP_STATUS "disabled"
    else
        state_set MPTCP_STATUS "kernel-key-absent"
    fi
    # CVE-2026-98432 also has a request-socket-migration path.
    if [[ -e /proc/sys/net/ipv4/tcp_migrate_req ]]; then
        printf '\n# CVE-2026-98432 secondary path\nnet.ipv4.tcp_migrate_req = 0\n' >>"$sysctl_file"
        sysctl -w net.ipv4.tcp_migrate_req=0 >/dev/null 2>&1 || true
    fi
    if sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1; then
        state_set BBR_STATUS "on"
        ok "BBR 已启用 ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
    else
        warn "内核参数写入成功但即时应用失败，重启后通常会生效。请执行 xhy check 复查。"
        state_set BBR_STATUS "pending-reboot"
    fi
}

bbr_status() {
    printf '拥塞控制 : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    printf 'qdisc    : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    printf '可用算法 : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
    printf 'MPTCP    : %s (应为 0)\n' "$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf 'migrate_req: %s (应为 0)\n' "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo '内核未暴露')"
    printf '脚本状态 : %s\n' "$(state_get BBR_STATUS 'unset')"
}

# Collect public TCP ports from the node registry. Tunnel nodes bind to
# 127.0.0.1 (PUBLIC=0) and are intentionally not exposed.
firewall_node_ports() {
    local f p public proto
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        public="$(grep -m1 '^PUBLIC=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$public" == "0" ]] && continue
        proto="$(grep -m1 '^PROTO=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$proto" == "udp" ]] && continue
        p="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | sort -un
}

# Hysteria2 / QUIC nodes are UDP-only; forgetting this is the #1 reason a
# freshly created hy2 node looks "up" but never connects.
firewall_udp_ports() {
    local f p public proto
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        public="$(grep -m1 '^PUBLIC=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$public" == "0" ]] && continue
        proto="$(grep -m1 '^PROTO=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$proto" == "udp" ]] || continue
        p="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | sort -un
}

# Build our own chain for one address family. We never flush INPUT, so
# pre-existing admin rules stay intact. Two recent windows are used: a short
# one for bursts and an hourly one that catches slow brute force.
_apply_family() {
    local ipt="$1" mode="$2" guard="$3" tag p ok_recent=1
    have_cmd "$ipt" || return 1
    if [[ "$ipt" == "ip6tables" ]]; then tag="XHYSSH6"; else tag="XHYSSH"; fi

    if ! "$ipt" -w -N "$FW_CHAIN" >/dev/null 2>&1; then
        "$ipt" -w -F "$FW_CHAIN" >/dev/null 2>&1 \
            || { warn "无法创建/清空 $ipt 的 $FW_CHAIN 链"; return 1; }
    fi
    while "$ipt" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        "$ipt" -w -D INPUT -j "$FW_CHAIN" || break
    done

    "$ipt" -w -A "$FW_CHAIN" -i lo -j ACCEPT
    "$ipt" -w -A "$FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [[ "$ipt" == "ip6tables" ]]; then
        "$ipt" -w -A "$FW_CHAIN" -p ipv6-icmp -j ACCEPT
    else
        "$ipt" -w -A "$FW_CHAIN" -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT
    fi

    if [[ "$guard" == "on" ]]; then
        # 阈值按「正常人的使用量」定，不是按攻击者：VS Code Remote / scp 批量 /
        # 运维工具一轮就是 5-10 个新连接。攻击者的特征是每小时成百上千次。
        # 爆发窗口 10 次/60s，慢速窗口 25 次/小时 —— 误伤远小于拦截损失。
        if "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "$tag" >/dev/null 2>&1; then
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --update --seconds 60 --hitcount 10 --name "$tag" -j DROP 2>/dev/null || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "${tag}_SLOW" >/dev/null 2>&1 || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --update --seconds 3600 --hitcount 25 --name "${tag}_SLOW" -j DROP 2>/dev/null || ok_recent=0
        else
            ok_recent=0
        fi
        (( ok_recent == 1 )) || warn "$ipt: xt_recent 不可用，SSH 防爆破未完全生效"
    fi

    "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -j ACCEPT
    while read -r p; do
        [[ -n "$p" ]] && "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$p" -j ACCEPT
    done < <(firewall_node_ports)
    while read -r p; do
        [[ -n "$p" ]] && "$ipt" -w -A "$FW_CHAIN" -p udp --dport "$p" -j ACCEPT
    done < <(firewall_udp_ports)

    if [[ "$mode" == "strict" ]]; then
        "$ipt" -w -A "$FW_CHAIN" -p tcp -j DROP
        "$ipt" -w -A "$FW_CHAIN" -p udp -j DROP
    fi
    "$ipt" -w -A "$FW_CHAIN" -j RETURN
    "$ipt" -w -I INPUT 1 -j "$FW_CHAIN" || return 1
    return 0
}

firewall_apply() {
    local mode="${1:-$(state_get FIREWALL_MODE safe)}" quiet="${2:-}" guard
    have_cmd iptables || { warn "未安装 iptables，跳过防火墙配置"; return 1; }
    guard="$(state_get SSH_GUARD on)"
    install -d -m 0700 "$XHY_BACKUP"
    iptables-save >"$XHY_BACKUP/iptables.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || true
    if have_cmd ip6tables; then
        ip6tables-save >"$XHY_BACKUP/ip6tables.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || true
    fi

    _apply_family iptables "$mode" "$guard" || return 1
    if have_cmd ip6tables; then
        if ! _apply_family ip6tables "$mode" "$guard"; then
            warn "IPv6 规则应用失败：请检查 ip6tables，否则 SSH 可经 IPv6 绕过限速。"
        fi
    else
        warn "系统无 ip6tables；若 sshd 监听 IPv6，请自行确认 IPv6 无暴露。"
    fi
    state_set FIREWALL_MODE "$mode"
    state_set SSH_GUARD_STATUS "$([[ "$guard" == on ]] && echo on || echo off)"
    # At boot this runs *from* the unit below; rewriting the unit and calling
    # rc-update from inside its own start() is pointless and can race.
    [[ "${XHY_FW_NO_INSTALL:-0}" == "1" ]] || install_firewall_service
    [[ "$quiet" == "--quiet" ]] || ok "防火墙已应用 (模式: $mode, 双栈, SSH: $XHY_SSH_PORT, 节点端口: $(firewall_node_ports | tr '\n' ' '))"
}

# Boot persistence re-runs the idempotent chain builder instead of restoring a
# full rules dump, so rules added later by the admin are never overwritten.
install_firewall_service() {
    local runner="/usr/local/bin/xhy"
    [[ -x "$runner" ]] || runner="$XHY_SELF"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy-firewall.service <<EOF
[Unit]
Description=xray-hy dual-stack firewall rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=XHY_FW_NO_INSTALL=1
ExecStart=${runner} firewall apply --quiet

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray-hy-firewall >/dev/null 2>&1 || true
    else
        cat >/etc/init.d/xray-hy-firewall <<'EOF'
#!/sbin/openrc-run
name="xray-hy-firewall"
description="xray-hy dual-stack firewall rules"
depend() { need net; after iptables; before xray-hy; }
start() { XHY_FW_NO_INSTALL=1 RUNNER firewall apply --quiet; }
stop()  { for t in iptables ip6tables; do
            $t -w -D INPUT -j XHY-IN >/dev/null 2>&1 || true
            $t -w -F XHY-IN >/dev/null 2>&1 || true
            $t -w -X XHY-IN >/dev/null 2>&1 || true
          done; }
EOF
        sed -i "s|RUNNER|${runner}|" /etc/init.d/xray-hy-firewall
        chmod 0755 /etc/init.d/xray-hy-firewall
        rc-update add xray-hy-firewall boot >/dev/null 2>&1 || true
    fi
}

_clear_family() {
    local ipt="$1"
    have_cmd "$ipt" || return 0
    while "$ipt" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        "$ipt" -w -D INPUT -j "$FW_CHAIN" || break
    done
    "$ipt" -w -F "$FW_CHAIN" >/dev/null 2>&1 || true
    "$ipt" -w -X "$FW_CHAIN" >/dev/null 2>&1 || true
}

firewall_off() {
    _clear_family iptables
    _clear_family ip6tables
    svc_disable "$SVC_FW"
    state_set FIREWALL_MODE "off"
    ok "xray-hy 双栈防火墙链已移除，系统原有规则未改动"
}

firewall_status() {
    printf '工作模式 : %s\n' "$(state_get FIREWALL_MODE safe)"
    printf 'SSH 防爆破: %s (端口 %s，60s/5 次 + 1h/8 次 双窗口)\n' "$(state_get SSH_GUARD_STATUS '?')" "$XHY_SSH_PORT"
    printf '节点端口(TCP): %s\n' "$(firewall_node_ports | tr '\n' ' ')"
    printf '节点端口(UDP): %s\n' "$(firewall_udp_ports | tr '\n' ' ')"
    if have_cmd iptables; then
        printf '\n%s\n' "IPv4 自定义链："
        iptables -w -L "$FW_CHAIN" -n --line-numbers 2>/dev/null || printf '  (未创建)\n'
    fi
    if have_cmd ip6tables; then
        printf '\n%s\n' "IPv6 自定义链："
        ip6tables -w -L "$FW_CHAIN" -n --line-numbers 2>/dev/null || printf '  (未创建)\n'
    else
        warn "未找到 ip6tables，IPv6 侧未受本脚本保护"
    fi
}

# ===================== lib/target.sh =====================
# xray-hy / REALITY camouflage site selection and live validation.

TARGETS_FILE="${XHY_SCRIPT_DIR:-$XHY_HOME}/conf/targets.tsv"

# 单文件发布没有 conf/ 目录：数据内嵌在脚本里，首次用到时落盘。
# 落盘的好处是管理员仍可直接编辑该文件增删候选，行为与仓库内一致。
targets_ensure() {
    [[ -s "$TARGETS_FILE" ]] && return 0
    mkdir -p "$(dirname "$TARGETS_FILE")" 2>/dev/null || return 1
    targets_tsv >"$TARGETS_FILE" || return 1
    chmod 0644 "$TARGETS_FILE" 2>/dev/null || true
}

# 仓库内运行时的占位实现；build.sh 会用 conf/targets.tsv 的内嵌副本覆盖它。
targets_tsv() {
    die "缺少伪装站数据文件 $TARGETS_FILE（仓库内请保留 conf/targets.tsv）"
}

target_rows() {
    targets_ensure || die "找不到伪装站数据文件: $TARGETS_FILE"
    [[ -r "$TARGETS_FILE" ]] || die "找不到伪装站数据文件: $TARGETS_FILE"
    # Strip any UTF-8 BOM *before* filtering: a BOM keeps the leading "#" from
    # matching the comment filter, and the header line would then be listed as a
    # region by `xhy target` and parsed as a data row.
    tr -d '\357\273\277' <"$TARGETS_FILE" | grep -vE '^[[:space:]]*(#|$)' || true
}

target_list_regions() {
    target_rows | cut -d'|' -f1 | sort -u | tr '\n' ' '
}

# Verify a candidate really speaks TLS 1.3 + HTTP/2, does not redirect and is
# not sitting behind a CDN. Xray itself warns that a CDN-fronted target turns
# the node into an open port forwarder.
target_validate() {
    local host="$1" tls_out="" hdr="" rc=0
    [[ -n "$host" ]] || return 1
    host="${host%%:*}"

    if [[ -x "$XRAY_BIN" ]] && XRAY_LOCATION_ASSET="$XRAY_ASSET" \
            "$XRAY_BIN" tls ping "${host}:443" >/tmp/xhy-tlsping.$$ 2>&1; then
        tls_out="$(cat /tmp/xhy-tlsping.$$)"
    else
        tls_out="$(printf 'Q' | openssl s_client -connect "${host}:443" \
            -servername "$host" -tls1_3 2>/dev/null | grep -iE 'Protocol|Cipher' | head -5)"
    fi
    rm -f "/tmp/xhy-tlsping.$$"

    if [[ -n "$tls_out" ]] && ! grep -qiE 'TLS ?v?1\.3|TLS_AES|TLS_CHACHA' <<<"$tls_out"; then
        warn "  $host : 未确认 TLS 1.3"; rc=1
    fi

    hdr="$(curl -sS -I --http2 -m 12 "https://${host}/" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$hdr" ]]; then
        warn "  $host : 无法建立 HTTPS 连接"; return 1
    fi
    grep -qiE '^HTTP/2( |$)' <<<"$hdr" || { warn "  $host : 不支持 HTTP/2"; rc=1; }
    if grep -qiE '^location:' <<<"$hdr"; then
        warn "  $host : 会重定向，不适合作为 target"; rc=1
    fi
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' <<<"$hdr"; then
        warn "  $host : 位于 CDN 之后，不推荐作为 REALITY target"; rc=1
    fi
    (( rc == 0 )) && ok "  $host : TLS 1.3 / H2 / 无跳转 / 非 CDN"
    return "$rc"
}

target_region() { state_get TARGET_REGION "auto"; }

# Echo "<target> <sni> <label>". Resolution order:
#   1) explicit custom target from state
#   2) region chosen by the admin
#   3) auto: match the VPS egress country code
pick_target() {
    local region candidate="" cc="" line r c label tgt sni
    local custom_t custom_s
    custom_t="$(state_get TARGET_CUSTOM '')"
    custom_s="$(state_get TARGET_SNI '')"
    if [[ -n "$custom_t" ]]; then
        printf '%s %s %s\n' "$custom_t" "${custom_s:-${custom_t%%:*}}" "custom"
        return 0
    fi

    region="$(target_region)"
    if [[ "$region" == "auto" ]]; then
        cc="$(public_country)"
        # All diagnostics MUST go to stderr: stdout is the machine-readable
        # "<target> <sni> <label>" triple consumed by the caller.
        info "VPS 出口国家: ${cc:-未知}，按地区匹配伪装站" >&2
        line="$(target_rows | awk -F'|' -v c="${cc:-__}" 'tolower($2)==tolower(c) {print; exit}')"
        region="$(printf '%s' "$line" | cut -d'|' -f1)"
        [[ -z "$region" ]] && region="other"
    fi

    # Two passes: the region's own candidates first, then the generic
    # auto/other fallbacks. A single pass let the `auto` row (line 1 of the
    # table) win over every region-specific entry, because it is validated
    # first and the loop returns on the first success.
    local pass found=""
    for pass in 1 2; do
        while IFS='|' read -r r c label tgt sni; do
            [[ -z "$tgt" ]] && continue
            if (( pass == 1 )); then
                [[ "$r" == "$region" ]] || continue
            else
                [[ "$r" == "auto" || "$r" == "other" ]] || continue
            fi
            if target_validate "$tgt" >&2; then
                found="$tgt|${sni:-${tgt%%:*}}|$label"
                break
            fi
            [[ -z "$candidate" ]] && candidate="$tgt|${sni:-${tgt%%:*}}|$label"
        done < <(target_rows)
        [[ -n "$found" ]] && break
    done

    if [[ -n "$found" ]]; then
        printf '%s\n' "${found//|/ }"
        return 0
    fi
    if [[ -n "$candidate" ]]; then
        warn "该地区候选均未通过完整校验，回退使用第一个（请自行确认可用性）" >&2
        printf '%s\n' "${candidate//|/ }"
        return 0
    fi
    die "没有可用的伪装站候选，请用 xhy target custom <域名> 手动指定。"
}

target_show() {
    local t s
    t="$(state_get TARGET_CUSTOM '')"
    s="$(state_get TARGET_SNI '')"
    printf '地区     : %s (可选: %s)\n' "$(target_region)" "$(target_list_regions)"
    if [[ -n "$t" ]]; then
        printf '自定义   : %s  SNI=%s\n' "$t" "${s:-${t%%:*}}"
    else
        printf '自定义   : 未设置（使用地区自动匹配）\n'
    fi
}

target_menu() {
    while true; do
        printf '\n'
        target_show
        cat <<'EOF'
  1) 按地区自动匹配（按 VPS 出口国家）
  2) 指定地区
  3) 手动指定 target / SNI
  4) 清除自定义设置
  5) 校验指定域名
  0) 返回
EOF
        case "$(ask '选择' '0')" in
            1) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto
               info "已设为自动匹配"; pick_target ;;
            2) local r; r="$(ask '地区代码' "$(target_region)")"
               target_rows | grep -q "^${r}|" || { warn "可用地区: $(target_list_regions)"; continue; }
               state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION "$r"; pick_target ;;
            3) local h s
               h="$(ask 'target 域名(可带 :443，SNI 不同才加 ,sni=其他域名)')"
               [[ -n "$h" ]] || continue
               s="${h#*,sni=}"; [[ "$s" == "$h" ]] && s=""
               h="${h%%,*}"
               [[ "$h" == *:* ]] || h="${h}:443"
               s="${s:-${h%%:*}}"
               target_validate "$h" || confirm '校验未完全通过，仍要使用？' 'n' || continue
               state_set TARGET_CUSTOM "$h"; state_set TARGET_SNI "$s"
               ok "已固定 target=$h SNI=$s" ;;
            4) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto; ok "已清除" ;;
            5) local v; v="$(ask '要校验的域名')"; [[ -n "$v" ]] && target_validate "$v" ;;
            0) return 0 ;;
        esac
    done
}

limit_fallback_json() {
    # Mitigation for the upstream REALITY warning: unauthenticated traffic is
    # forwarded to the target. Rate-limit that fallback path.
    cat <<'EOF'
        "limitFallbackUpload":   { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
        "limitFallbackDownload": { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
EOF
}

# ===================== lib/nodes.sh =====================
# xray-hy / node registry, inbound rendering and full-config rebuild.
# Design: one .env per node (credentials) + one JSON fragment per node
# (a single inbound object). `rebuild_config` merges fragments into a single
# config.json so `xray run -test -c` can validate the whole thing atomically.

node_file()   { printf '%s/%s_%s.env' "$XHY_NODES" "$1" "$2"; }
node_frag()   { printf '%s/%s_%s.json' "$XHY_CONFDIR" "$1" "$2"; }
node_exists() { [[ -f "$(node_file "$1" "$2")" ]]; }
node_count()  { find "$XHY_NODES" -maxdepth 1 -name '*.env' -type f 2>/dev/null | wc -l; }

# A port must be unique across ALL modes, not just within one mode.
port_used_by_node() {
    local p="$1" f v
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        v="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        if [[ "$v" == "$p" ]]; then basename "$f" .env; return 0; fi
    done
    return 1
}

# "::" listens on both v4 and v6 (when bindv6only=0). Opt-in because some VPS
# ship with IPv6 disabled, where "::" would fail to bind at all.
listen_addr() {
    if [[ "$(state_get DUAL_STACK off)" == "on" ]]; then printf '::'; else printf '0.0.0.0'; fi
}

node_load() {
    local f="$1" line key val
    MODE=""; PORT=""; PUBLIC=""; UUID=""; NODE_PATH=""; NODE_HOST=""
    SNI=""; TARGET=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    FP=""; CF_DOMAIN=""; CF_TOKEN_SET=""; SECURITY="none"; CREATED=""
    PROTO="tcp"; AUTH=""; CERT_FILE=""; KEY_FILE=""; PIN_B64=""; PIN_HEX=""
    MASQ_URL=""; BRUTAL_UP=""; BRUTAL_DOWN=""
    while IFS= read -r line; do
        # Keys may contain digits (PIN_B64, BRUTAL_UP); [A-Z_]+ would silently
        # skip them and produce an empty pinSHA256 in the share link.
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            MODE|PORT|PUBLIC|UUID|NODE_PATH|NODE_HOST|SNI|TARGET|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|FP|CF_DOMAIN|CF_TOKEN_SET|SECURITY|CREATED|PROTO|AUTH|CERT_FILE|KEY_FILE|PIN_B64|PIN_HEX|MASQ_URL|BRUTAL_UP|BRUTAL_DOWN)
                printf -v "$key" '%s' "$val" ;;
        esac
    done <"$f"
}

node_save() {
    local f="$1"; shift
    local kv
    {
        for kv in "$@"; do printf '%s\n' "$kv"; done
    } | atomic_write "$f" 0600
}

log_json() {
    local lvl dir
    lvl="$(state_get LOG_LEVEL warning)"
    [[ "$lvl" == "none" ]] && { printf '{"loglevel":"none"}'; return; }
    dir="$(json_escape "$XHY_LOGDIR")"
    printf '{"loglevel":"%s","access":"%s/xray-access.log","error":"%s/xray-error.log"}' \
        "$lvl" "$dir" "$dir"
}

dns_json() {
    case "$(state_get DNS_PROVIDER cloudflare)" in
        cloudflare) printf '{"servers":["https+local://1.1.1.1/dns-query","localhost"]}' ;;
        quad9)      printf '{"servers":["https+local://dns.quad9.net/dns-query","localhost"]}' ;;
        dns-sb)     printf '{"servers":["https+local://doh.dns.sb/dns-query","localhost"]}' ;;
        system)     printf '{"servers":["localhost"]}' ;;
        *)          printf '{"servers":["https+local://1.1.1.1/dns-query","localhost"]}' ;;
    esac
}

routing_json() {
    local rules=()
    [[ "$(state_get BLOCK_BT on)" == "on" ]] && \
        rules+=('{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_PRIVATE on)" == "on" ]] && \
        rules+=('{"type":"field","ip":["geoip:private"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_CN off)" == "on" ]] && \
        rules+=('{"type":"field","ip":["geoip:cn"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_ADS off)" == "on" ]] && \
        rules+=('{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}')
    local joined="" sep=""
    local r
    for r in "${rules[@]}"; do joined+="$sep$r"; sep=","; done
    printf '{"domainStrategy":"IPIfNonMatch","rules":[%s]}' "$joined"
}

outbounds_json() {
    printf '[{"protocol":"freedom","tag":"direct","settings":{}},{"protocol":"blackhole","tag":"block"}]'
}

# Snapshot the *source of truth* only: node registry, config fragments, hy2
# certificates and settings. config.json is deliberately excluded because it is
# derived from those files -- archiving it alongside a post-delete registry
# (node_del removes the .env first, then rebuilds) would capture a config that
# references a node whose credentials no longer exist. A restore always
# re-renders fragments from the registry, so any snapshot is self-healing.
snapshot_state() {
    local snap f n=0
    [[ -d "$XHY_NODES" ]] || return 0
    snap="$XHY_SNAPSHOTS/state.$(date +%Y%m%d%H%M%S).tar.gz"
    # `cd` instead of `tar -C`: a path containing ":" is read as host:path by
    # GNU tar, which silently produced empty snapshots in mixed environments.
    if ( cd "$XHY_ETC" && tar czf "$snap" confs nodes certs state.env ) 2>/dev/null; then
        chmod 600 "$snap" 2>/dev/null || true
    else
        rm -f "$snap"
        warn "状态快照创建失败（$XHY_ETC）；xhy rollback 将没有可用快照"
        return 0
    fi
    while IFS= read -r f; do
        n=$((n + 1))
        if (( n > 5 )); then rm -f "$f"; fi
    done < <(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null)
}

rebuild_config() {
    local joined="" sep="" f
    init_dirs
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    for f in "$XHY_CONFDIR"/*.json; do
        [[ -s "$f" ]] || continue
        joined+="$sep$(cat "$f")"
        sep=","
    done
    {
        printf '{\n  "log": %s,\n' "$(log_json)"
        printf '  "inbounds": [%s],\n' "$joined"
        printf '  "dns": %s,\n' "$(dns_json)"
        printf '  "routing": %s,\n' "$(routing_json)"
        printf '  "outbounds": %s\n}\n' "$(outbounds_json)"
    } | atomic_write "$XHY_ETC/config.json" 0600
    ok "配置已重建: $XHY_ETC/config.json ($(node_count) 个节点)"
}

sniffing_json() {
    printf '"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
}

# ---------------------------------------------------------------------------
# inbound fragment renderers. Each reads the corresponding .env file.
# ---------------------------------------------------------------------------

render_inbound() {
    local env="$1" mode
    node_load "$env"
    mode="$MODE"
    case "$mode" in
        direct)  render_direct ;;
        tunnel)  render_tunnel ;;
        reality) render_reality ;;
        xhttp)   render_xhttp ;;
        hy2)     render_hy2 ;;
        *) err "未知节点类型: $mode"; return 1 ;;
    esac
}

render_direct() {
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-direct-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "direct-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}" }
  },
  $(sniffing_json)
}
EOF
}

render_tunnel() {
    cat <<EOF
{
  "listen": "127.0.0.1", "port": ${PORT}, "protocol": "vless",
  "tag": "in-tunnel-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "tunnel-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "${NODE_PATH}", "host": "${CF_DOMAIN}" }
  },
  $(sniffing_json)
}
EOF
}

render_reality() {
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-reality-${PORT}",
  "settings": {
    "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "reality-${PORT}" } ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "${TARGET}",
      "serverNames": [ "${SNI}" ],
      "privateKey": "${PRIVATE_KEY}",
      "shortIds": [ "${SHORT_ID}" ],
$(limit_fallback_json)
      "xver": 0
    }
  },
  $(sniffing_json)
}
EOF
}

render_xhttp() {
    local sec_block="" reality_block=""
    if [[ "${SECURITY:-none}" == "reality" ]]; then
        sec_block='"security": "reality",'
        reality_block=$(cat <<EOF
    "realitySettings": {
      "show": false,
      "target": "${TARGET}",
      "serverNames": [ "${SNI}" ],
      "privateKey": "${PRIVATE_KEY}",
      "shortIds": [ "${SHORT_ID}" ],
$(limit_fallback_json)
      "xver": 0
    },
EOF
)
    else
        sec_block='"security": "none",'
    fi
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-xhttp-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "xhttp-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp", ${sec_block}
${reality_block}
    "xhttpSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}", "mode": "auto" }
  },
  $(sniffing_json)
}
EOF
}

# Xray's native Hysteria2 inbound (v26.3.27+). Verified with `xray run -test`:
# protocol "hysteria", version 2, network "hysteria", security "tls", alpn h3.
render_hy2() {
    local qp="" masq
    [[ -n "$BRUTAL_UP" ]] && qp="\"brutalUp\": \"${BRUTAL_UP}\""
    if [[ -n "$BRUTAL_DOWN" ]]; then
        [[ -n "$qp" ]] && qp+=", "
        qp+="\"brutalDown\": \"${BRUTAL_DOWN}\""
    fi
    masq="$(json_escape "$MASQ_URL")"
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "hysteria",
  "tag": "in-hy2-${PORT}",
  "settings": {
    "version": 2,
    "clients": [ { "auth": "${AUTH}", "email": "hy2-${PORT}" } ]
  },
  "streamSettings": {
    "network": "hysteria", "security": "tls",
    "hysteriaSettings": {
      "version": 2,
      "masquerade": { "type": "proxy", "url": "${masq}", "rewriteHost": true }
    },
    "tlsSettings": {
      "alpn": [ "h3" ],
      "certificates": [ { "certificateFile": "${CERT_FILE}", "keyFile": "${KEY_FILE}" } ]
    },
    "finalmask": { "quicParams": { ${qp} } }
  },
  $(sniffing_json)
}
EOF
}

write_fragment() {
    local env="$1" m p frag content
    # Resolve the destination BEFORE rendering: in a pipeline both sides are
    # expanded concurrently, so $MODE/$PORT would still be unset here.
    node_load "$env"
    m="$MODE"; p="$PORT"
    frag="$(node_frag "$m" "$p")"
    content="$(render_inbound "$env")" || return 1
    printf '%s\n' "$content" | atomic_write "$frag" 0644
}

# ---------------------------------------------------------------------------
# node creation
# ---------------------------------------------------------------------------

# node_add MODE PORT [--host H] [--path P] [--sni S] [--target T]
#                    [--token TOKEN] [--domain D] [--reality] [--uuid U]
node_add() {
    local mode="$1" port="$2"; shift 2
    local host="" path="" sni="" target="" token="" domain="" uuid="" with_reality="0"
    local masq="" up="" down=""
    while (( $# > 0 )); do
        case "$1" in
            --host)   host="$2"; shift 2 ;;
            --path)   path="$2"; shift 2 ;;
            --sni)    sni="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            --token)  token="$2"; shift 2 ;;
            --domain) domain="$2"; shift 2 ;;
            --uuid)   uuid="$2"; shift 2 ;;
            --masq)   masq="$2"; shift 2 ;;
            --up)     up="$2"; shift 2 ;;
            --down)   down="$2"; shift 2 ;;
            --reality) with_reality="1"; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    case "$mode" in
        direct|tunnel|reality|xhttp|hy2) ;;
        *) die "模式只能是 direct / tunnel / reality / xhttp / hy2" ;;
    esac
    valid_port "$port" || die "端口不合法: $port"
    local clash
    clash="$(port_used_by_node "$port")" || true
    [[ -n "$clash" ]] && die "端口 $port 已被节点 ${clash} 占用（不同模式也不能共用端口）"
    need_root
    init_dirs
    [[ -x "$XRAY_BIN" ]] || die "尚未安装 Xray，请先运行: xhy install"

    if port_busy "$port"; then
        warn "端口 $port 已被占用，请确认不是其它服务。"
        confirm "仍要继续？" "n" || return 1
    fi

    uuid="${uuid:-$(uuid_gen)}"
    path="${path:-$(rand_path)}"
    host="${host:-$(public_ip)}"
    [[ "$path" == /* ]] || path="/$path"

    local public=1 priv="" pub="" sid="" tgt="" t_sni="" label="" security="none"
    local pairs=() picked="" kp=""
    if [[ -n "$target" && "$target" != *:* ]]; then target="${target}:443"; fi

    case "$mode" in
        reality)
            if [[ -n "$target" ]]; then
                tgt="$target"; t_sni="${sni:-${target%%:*}}"
                target_validate "$tgt" || confirm "校验未通过，仍要使用？" "n" || return 1
            else
                picked="$(pick_target)" || return 1
                [[ -n "$picked" ]] || { err "伪装站选择失败"; return 1; }
                read -r tgt t_sni label <<<"$picked"
                [[ -n "$sni" ]] && t_sni="$sni"
            fi
            kp="$(x25519_keypair)" || return 1
            read -r priv pub <<<"$kp"
            [[ -n "$priv" && -n "$pub" ]] || { err "x25519 密钥生成失败"; return 1; }
            sid="$(rand_hex 8)"
            pairs=(
                "MODE=reality" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=$t_sni" "TARGET=$tgt"
                "PRIVATE_KEY=$priv" "PUBLIC_KEY=$pub" "SHORT_ID=$sid"
                "FP=chrome" "SECURITY=reality" "CREATED=$(date -Is)"
            ) ;;
        xhttp)
            if [[ "$with_reality" == "1" || -n "$target" ]]; then
                security="reality"
                if [[ -n "$target" ]]; then
                    tgt="$target"; t_sni="${sni:-${target%%:*}}"
                else
                    picked="$(pick_target)" || return 1
                    [[ -n "$picked" ]] || { err "伪装站选择失败"; return 1; }
                    read -r tgt t_sni label <<<"$picked"
                    [[ -n "$sni" ]] && t_sni="$sni"
                fi
                kp="$(x25519_keypair)" || return 1
                read -r priv pub <<<"$kp"
                [[ -n "$priv" && -n "$pub" ]] || { err "x25519 密钥生成失败"; return 1; }
                sid="$(rand_hex 8)"
            fi
            pairs=(
                "MODE=xhttp" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=${t_sni:-$host}" "TARGET=${tgt:-}"
                "PRIVATE_KEY=${priv:-}" "PUBLIC_KEY=${pub:-}" "SHORT_ID=${sid:-}"
                "FP=chrome" "SECURITY=$security" "CREATED=$(date -Is)"
            ) ;;
        direct)
            pairs=(
                "MODE=direct" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SECURITY=none" "CREATED=$(date -Is)"
            ) ;;
        tunnel)
            public=0
            domain="${domain:-}"
            [[ -n "$domain" ]] || die "tunnel 模式需要 --domain <CF 公开主机名>"
            token="${token:-}"
            if [[ -n "$token" ]]; then
                printf '%s' "$token" | atomic_write "$XHY_ETC/tunnel.token" 0600
            fi
            [[ -s "$XHY_ETC/tunnel.token" ]] || die "tunnel 模式需要 --token <Cloudflare Tunnel Token>（也可预先写入 $XHY_ETC/tunnel.token）"
            [[ -x "$CF_BIN" ]] || cloudflared_install
            install_cf_service
            svc_restart "$SVC_CF" || warn "cloudflared 启动失败，请在 CF 控制台确认 Tunnel 配置"
            pairs=(
                "MODE=tunnel" "PORT=$port" "PUBLIC=0" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$domain" "CF_DOMAIN=$domain" "CF_TOKEN_SET=1"
                "SECURITY=none" "CREATED=$(date -Is)"
            ) ;;
        hy2)
            local hy2sni masq_url crt key pin64 pinhex
            hy2sni="${sni:-www.bing.com}"
            masq_url="${masq:-https://www.bing.com/}"
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$port" "$hy2sni")"
            [[ -s "$crt" && -s "$key" ]] || die "Hysteria2 自签证书生成失败"
            pairs=(
                "MODE=hy2" "PORT=$port" "PUBLIC=1" "PROTO=udp"
                "UUID=$uuid" "AUTH=$uuid" "NODE_HOST=$host"
                "SNI=$hy2sni" "CERT_FILE=$crt" "KEY_FILE=$key"
                "PIN_B64=$pin64" "PIN_HEX=$pinhex" "MASQ_URL=$masq_url"
                "BRUTAL_UP=$up" "BRUTAL_DOWN=$down"
                "SECURITY=tls" "CREATED=$(date -Is)"
            )
            info "Hysteria2 走 UDP $port，防火墙会自动放行 UDP；客户端需支持 hy2（sing-box / mihomo / v2rayN）" ;;
    esac

    local envf
    envf="$(node_file "$mode" "$port")"
    # Snapshot BEFORE the registry changes, so a snapshot always represents a
    # state you can go back to (an "after add" snapshot would be useless).
    snapshot_state
    node_save "$envf" "${pairs[@]}"

    # Roll back cleanly if the generated JSON is invalid.
    if ! write_fragment "$envf"; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        die "inbound 配置生成失败，已回滚"
    fi
    if ! XHY_SKIP_SNAPSHOT=1 rebuild_config || ! xray_config_test; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null
        err "配置校验失败，新节点已回滚，原有节点不受影响。"
        return 1
    fi

    if [[ "$mode" == "tunnel" ]]; then
        info "Cloudflare 控制台请把 Public Hostname 的 Service 指向 http://127.0.0.1:${port}，路径与 WS path 一致: ${path}"
    fi
    config_reload || { err "服务重启失败，节点配置已写入但未生效"; return 1; }
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    fi
    ok "节点 ${mode}_${port} 已添加"
    link_from_env "$envf"
}

node_del() {
    local mode="$1" port="$2" envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    need_root
    backup_file "$envf"
    snapshot_state          # before the registry changes: undoable delete
    rm -f "$envf" "$(node_frag "$mode" "$port")"
    if [[ "$mode" == "hy2" ]]; then
        rm -f "$XHY_CERTS/hy2_${port}.crt" "$XHY_CERTS/hy2_${port}.key"
        info "已清理该 Hysteria2 节点的自签证书"
    fi
    if [[ "$mode" == "tunnel" ]] && ! find "$XHY_NODES" -name 'tunnel_*.env' | grep -q .; then
        remove_cf_service
        rm -f "$XHY_ETC/tunnel.token"
        info "已无 tunnel 节点，cloudflared 服务与 token 已清理"
    fi
    XHY_SKIP_SNAPSHOT=1 rebuild_config
    xray_config_test && config_reload
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "节点 ${mode}_${port} 已删除（凭据备份在 $XHY_BACKUP，可用 xhy snapshots 回滚整套状态）"
}

node_list() {
    local f mode port uuid sec created
    printf '%-10s %-7s %-6s %-38s %-10s %s\n' "模式" "端口" "公网" "UUID" "安全" "创建时间"
    printf '%s\n' "--------------------------------------------------------------------------------------------"
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        node_load "$f"
        printf '%-10s %-7s %-6s %-38s %-10s %s\n' \
            "$MODE" "$PORT" "$([[ "$PUBLIC" == 1 ]] && echo yes || echo no)" \
            "$UUID" "${SECURITY:-none}" "${CREATED:-?}"
    done
    (( $(node_count) > 0 )) || printf '(暂无节点)\n'
}

node_rebuild_all() {
    local f
    need_root
    init_dirs
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        write_fragment "$f" || die "重建 ${f##*/} 失败"
    done
    rebuild_config
    xray_config_test || { err "重建后的配置校验失败"; return 1; }
    config_reload || warn "配置已写入，但服务未能重启（尚未 install 或服务未启用？）"
}

list_snapshots() {
    local f
    if ! ls "$XHY_SNAPSHOTS"/state.*.tar.gz >/dev/null 2>&1; then
        warn "暂无快照"; return 0
    fi
    for f in $(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null || true); do
        printf '%s  (%s bytes)\n' "$f" "$(stat -c%s "$f" 2>/dev/null || echo '?')"
    done
}

rollback_config() {
    local target="${1:-}" pre
    need_root
    if [[ -z "$target" ]]; then
        target="$(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | head -1 || true)"
    fi
    [[ -s "$target" ]] || die "没有可用的状态快照（快照格式：state.*.tar.gz）"
    # Save the state we are about to replace, so the rollback itself is undoable.
    pre="$XHY_SNAPSHOTS/state.pre-rollback.$(date +%s).tar.gz"
    ( cd "$XHY_ETC" && tar czf "$pre" confs nodes certs state.env ) 2>/dev/null || true
    chmod 600 "$pre" 2>/dev/null || true
    # Clear first: files that exist now but not in the snapshot must disappear,
    # otherwise the restore produces a union of two states.
    rm -f "$XHY_NODES"/*.env "$XHY_CONFDIR"/*.json
    ( cd "$XHY_ETC" && tar xzf "$target" ) || die "快照解包失败，当前状态已另存为 $pre"
    chmod 700 "$XHY_NODES" "$XHY_CERTS" 2>/dev/null || true
    # Re-render every fragment from the restored registry, then validate and
    # reload. Older snapshots that still carry config.json are handled the same
    # way: the file is simply overwritten by the rebuild.
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all || die "回滚后的配置校验失败（当前状态备份: $pre）"
    ok "已回滚整套状态到 $target（节点注册表、配置分片、证书均已恢复并重新渲染）"
}

# ===================== lib/links.sh =====================
# xray-hy / vless:// share-link generation (VLESS share-link standard).

_link_host() {
    local h="$1"
    if [[ "$h" == *:* && "$h" != \[* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

link_uri() {
    local envf="$1" host_ov="${2:-}" host="" q="" name=""
    node_load "$envf"
    # host_ov：生成 IPv6 变体链接时覆盖连接地址（不影响 vless ws 的 Host 头，
    # 那个必须保持真实域名/源地址，否则回源或伪装会错）。
    [[ -n "$host_ov" ]] && NODE_HOST="$host_ov"
    name="xray-hy-${MODE}-${PORT}"
    case "$MODE" in
        direct)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&security=none&type=ws&host=$(url_encode "$NODE_HOST")&path=$(url_encode "$NODE_PATH")"
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        tunnel)
            host="$(_link_host "$CF_DOMAIN")"
            q="encryption=none&security=tls&type=ws&host=$(url_encode "$CF_DOMAIN")&path=$(url_encode "$NODE_PATH")&sni=$(url_encode "$CF_DOMAIN")&fp=chrome"
            printf 'vless://%s@%s:443?%s#%s\n' "$UUID" "$host" "$q" "$name" ;;
        reality)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$SNI")&fp=chrome&pbk=$(url_encode "$PUBLIC_KEY")&sid=$(url_encode "$SHORT_ID")&type=tcp"
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        xhttp)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&type=xhttp&path=$(url_encode "$NODE_PATH")&host=$(url_encode "$NODE_HOST")&mode=auto"
            if [[ "${SECURITY:-none}" == "reality" ]]; then
                q="encryption=none&security=reality&type=xhttp&path=$(url_encode "$NODE_PATH")&host=$(url_encode "$NODE_HOST")&mode=auto&sni=$(url_encode "$SNI")&fp=chrome&pbk=$(url_encode "$PUBLIC_KEY")&sid=$(url_encode "$SHORT_ID")"
            fi
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        hy2)
            host="$(_link_host "$NODE_HOST")"
            # Self-signed cert: pin its SHA-256 instead of insecure=1.
            q="pinSHA256=$(url_encode "$PIN_B64")&sni=$(url_encode "$SNI")"
            printf 'hysteria2://%s@%s:%s?%s#%s\n' \
                "$(url_encode "$AUTH")" "$host" "$PORT" "$q" "$name" ;;
        *) err "未知模式: $MODE"; return 1 ;;
    esac
}

link_from_env() {
    local envf="$1" uri uri6=""
    node_load "$envf"
    uri="$(link_uri "$envf")"
    # IPv6 变体：仅当节点地址是 IPv4 字面量、服务器有 v6 出口、且节点确实
    # 双栈监听（DUAL_STACK=on -> bind ::）时才有意义；域名本身有 AAAA 的话
    # 同一条链接就覆盖双栈，不需要变体。
    if [[ "${NODE_HOST:-}" =~ ^[0-9.]+$ ]] && [[ "$(state_get DUAL_STACK off)" == "on" ]]; then
        local _ip6
        _ip6="$(public_ip6 || true)"
        if [[ -n "$_ip6" && "$_ip6" != "$NODE_HOST" ]]; then
            uri6="$(link_uri "$envf" "$_ip6" || true)"
        fi
    fi
    printf '\n'
    printf '  节点     : %s_%s\n' "$MODE" "$PORT"
    printf '  地址     : %s\n' "${NODE_HOST:-$CF_DOMAIN}"
    printf '  端口     : %s\n' "$PORT"
    printf '  UUID     : %s\n' "$UUID"
    [[ -n "${NODE_PATH:-}" ]] && printf '  路径     : %s\n' "$NODE_PATH"
    [[ -n "${SNI:-}" ]]       && printf '  SNI      : %s\n' "$SNI"
    [[ -n "${TARGET:-}" ]]    && printf '  Target   : %s\n' "$TARGET"
    [[ -n "${PUBLIC_KEY:-}" ]] && printf '  公钥 pbk : %s\n' "$PUBLIC_KEY"
    [[ -n "${SHORT_ID:-}" ]]  && printf '  shortId  : %s\n' "$SHORT_ID"
    if [[ "$MODE" == "hy2" ]]; then
        printf '  传输     : UDP / QUIC (Hysteria2, Xray 内置入站)\n'
        printf '  伪装站   : %s\n' "$MASQ_URL"
        printf '  证书     : %s\n' "$CERT_FILE"
        printf '  指纹 SHA256: %s\n' "$PIN_HEX"
        printf '  简易链接（跳过证书校验，不推荐）: hysteria2://%s@%s:%s?insecure=1&sni=%s#xray-hy-hy2-%s\n' \
            "$AUTH" "$(_link_host "$NODE_HOST")" "$PORT" "$SNI" "$PORT"
    fi
    printf '\n  %s\n\n' "$uri"
    [[ -n "$uri6" ]] && printf '  IPv6 变体: %s\n\n' "$uri6"
    printf '  %s\n' "注意：完整链接等同于访问凭证，请勿公开分享。"
}

link_all() {
    local f n=0
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        link_from_env "$f"
    done
    (( n > 0 )) || warn "暂无节点，先用 xhy add 添加一个。"
}

link_qr() {
    local envf="$1" uri
    ensure_optional qrencode
    have_cmd qrencode || die "未安装 qrencode，无法生成二维码。"
    uri="$(link_uri "$envf")"
    qrencode -t ANSIUTF8 "$uri"
}

# ===================== lib/export.sh =====================
# xray-hy / client config export: mihomo (Clash.Meta) proxies and sing-box
# outbounds, generated from the node registry. Read-only over /etc/xray-hy.

_export_name() { printf 'xray-hy-%s-%s' "$MODE" "$PORT"; }

# ---- mihomo / Clash.Meta --------------------------------------------------
# 每个节点一段 YAML（列表项）。返回 1 表示该协议 mihomo 不支持（xHTTP）。
_clash_node() {
    local envf="$1"
    node_load "$envf"
    case "$MODE" in
        reality)
            printf -- '- name: "%s"\n' "$(_export_name)"
            printf '  type: vless\n  server: "%s"\n  port: %s\n  uuid: "%s"\n' "$NODE_HOST" "$PORT" "$UUID"
            printf '  network: tcp\n  udp: true\n  tls: true\n  flow: xtls-rprx-vision\n'
            printf '  client-fingerprint: chrome\n  servername: "%s"\n' "$SNI"
            printf '  reality-opts:\n    public-key: "%s"\n    short-id: "%s"\n' "$PUBLIC_KEY" "$SHORT_ID"
            ;;
        hy2)
            printf -- '- name: "%s"\n  type: hysteria2\n  server: "%s"\n  port: %s\n' "$(_export_name)" "$NODE_HOST" "$PORT"
            printf '  password: "%s"\n  sni: "%s"\n' "$AUTH" "$SNI"
            # 自签证书：mihomo 不支持 pinSHA256，只能 skip-cert-verify。
            printf '  skip-cert-verify: true\n'
            if [[ -n "${BRUTAL_UP:-}" ]]; then
                printf '  up: "%s"\n  down: "%s"\n' "$BRUTAL_UP" "$BRUTAL_DOWN"
            fi
            ;;
        direct)
            printf -- '- name: "%s"\n  type: vless\n  server: "%s"\n  port: %s\n  uuid: "%s"\n' "$(_export_name)" "$NODE_HOST" "$PORT" "$UUID"
            printf '  network: ws\n  udp: true\n  tls: false\n'
            printf '  ws-opts:\n    path: "%s"\n    headers:\n      Host: "%s"\n' "$NODE_PATH" "$NODE_HOST"
            ;;
        tunnel)
            printf -- '- name: "%s"\n  type: vless\n  server: "%s"\n  port: 443\n  uuid: "%s"\n' "$(_export_name)" "$CF_DOMAIN" "$UUID"
            printf '  network: ws\n  udp: true\n  tls: true\n  servername: "%s"\n  client-fingerprint: chrome\n' "$CF_DOMAIN"
            printf '  ws-opts:\n    path: "%s"\n    headers:\n      Host: "%s"\n' "$NODE_PATH" "$CF_DOMAIN"
            ;;
        xhttp)
            # mihomo 目前没有 xHTTP 传输：跳过并在汇总里说明。
            return 1
            ;;
        *) return 1 ;;
    esac
}

# ---- sing-box -------------------------------------------------------------
# 每个节点一个 JSON 对象。xHTTP / sing-box 无对应传输的同样返回 1。
_singbox_node() {
    local envf="$1"
    node_load "$envf"
    case "$MODE" in
        reality)
            printf '{\n'
            printf '  "type": "vless",\n  "tag": "%s",\n' "$(json_escape "$(_export_name)")"
            printf '  "server": "%s",\n  "server_port": %s,\n  "uuid": "%s",\n' \
                "$(json_escape "$NODE_HOST")" "$PORT" "$(json_escape "$UUID")"
            printf '  "flow": "xtls-rprx-vision",\n'
            printf '  "tls": {\n    "enabled": true,\n    "server_name": "%s",\n' "$(json_escape "$SNI")"
            printf '    "utls": { "enabled": true, "fingerprint": "chrome" },\n'
            printf '    "reality": { "enabled": true, "public_key": "%s", "short_id": "%s" }\n  }\n' \
                "$(json_escape "$PUBLIC_KEY")" "$(json_escape "$SHORT_ID")"
            printf '}'
            ;;
        hy2)
            printf '{\n'
            printf '  "type": "hysteria2",\n  "tag": "%s",\n' "$(json_escape "$(_export_name)")"
            printf '  "server": "%s",\n  "server_port": %s,\n  "password": "%s",\n' \
                "$(json_escape "$NODE_HOST")" "$PORT" "$(json_escape "$AUTH")"
            if [[ -n "${BRUTAL_UP:-}" ]]; then
                # "100mbps" -> 100：纯 bash 提取数字，不依赖外部解释器。
                local upn="${BRUTAL_UP//[!0-9]/}" downn="${BRUTAL_DOWN//[!0-9]/}"
                printf '  "up_mbps": %s,\n  "down_mbps": %s,\n' "${upn:-0}" "${downn:-0}"
            fi
            printf '  "tls": { "enabled": true, "server_name": "%s", "insecure": true }\n' "$(json_escape "$SNI")"
            printf '}'
            ;;
        direct)
            printf '{\n'
            printf '  "type": "vless",\n  "tag": "%s",\n' "$(json_escape "$(_export_name)")"
            printf '  "server": "%s",\n  "server_port": %s,\n  "uuid": "%s",\n' \
                "$(json_escape "$NODE_HOST")" "$PORT" "$(json_escape "$UUID")"
            printf '  "tls": { "enabled": false },\n'
            printf '  "transport": { "type": "ws", "path": "%s", "headers": { "Host": "%s" } }\n' \
                "$(json_escape "$NODE_PATH")" "$(json_escape "$NODE_HOST")"
            printf '}'
            ;;
        tunnel)
            printf '{\n'
            printf '  "type": "vless",\n  "tag": "%s",\n' "$(json_escape "$(_export_name)")"
            printf '  "server": "%s",\n  "server_port": 443,\n  "uuid": "%s",\n' \
                "$(json_escape "$CF_DOMAIN")" "$(json_escape "$UUID")"
            printf '  "tls": { "enabled": true, "server_name": "%s", "utls": { "enabled": true, "fingerprint": "chrome" } },\n' "$(json_escape "$CF_DOMAIN")"
            printf '  "transport": { "type": "ws", "path": "%s", "headers": { "Host": "%s" } }\n' \
                "$(json_escape "$NODE_PATH")" "$(json_escape "$CF_DOMAIN")"
            printf '}'
            ;;
        *) return 1 ;;
    esac
}

# 汇总导出。$1=clash|singbox，--out FILE 写文件（0600），否则打 stdout。
cmd_export() {
    local fmt="${1:-}" out=""
    shift || true
    while (($#)); do
        case "$1" in
            --out) out="${2:?需要文件路径}"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    [[ "$fmt" == "clash" || "$fmt" == "singbox" ]] || die "用法: xhy export clash|singbox [--out FILE]"
    local skipped=0 n=0 f item
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/xhy-export.XXXXXX")"
    if [[ "$fmt" == "clash" ]]; then
        printf '# generated by xray-hy %s (build %s) at %s\n' "$XHY_VERSION" "$XHY_BUILD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp"
        printf '# 节点数据来自 /etc/xray-hy，含凭证，请勿公开此文件\n' >>"$tmp"
        printf 'proxies:\n' >>"$tmp"
    else
        printf '[\n' >>"$tmp"
    fi
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        if [[ "$fmt" == "clash" ]]; then
            if item="$(_clash_node "$f")"; then
                printf '%s\n' "$item" >>"$tmp"
                n=$((n + 1))
            else
                skipped=$((skipped + 1))
            fi
        else
            if item="$(_singbox_node "$f")"; then
                (( n > 0 )) && printf ',\n' >>"$tmp"
                printf '%s\n' "$item" >>"$tmp"
                n=$((n + 1))
            else
                skipped=$((skipped + 1))
            fi
        fi
    done
    if [[ "$fmt" == "singbox" ]]; then
        printf '\n]\n' >>"$tmp"
    fi
    if (( n == 0 )); then
        rm -f "$tmp"
        die "没有可导出的节点（共 $(node_count) 个，跳过 $skipped 个）"
    fi
    # sing-box 输出必须是合法 JSON；机器上有没有 python 都校验一下。
    if [[ "$fmt" == "singbox" ]] && [[ -n "${PY:-}" ]] && command -v "$PY" >/dev/null 2>&1; then
        "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" \
            || { rm -f "$tmp"; die "生成的 sing-box JSON 校验失败（内部错误，请报告）"; }
    fi
    if [[ -n "$out" ]]; then
        install -m 0600 "$tmp" "$out"
        rm -f "$tmp"
        ok "已导出 $n 个节点到 $out（含凭证，注意保管）"
        (( skipped > 0 )) && warn "跳过 $skipped 个节点：$fmt 暂不支持 xHTTP"
    else
        cat "$tmp"
        rm -f "$tmp"
        (( skipped > 0 )) && warn "（已跳过 $skipped 个节点：$fmt 暂不支持 xHTTP）" >&2
    fi
    return 0
}

# ===================== lib/backup.sh =====================
# xray-hy / backup & restore of script-managed state, with a per-file SHA256
# manifest. 借鉴 idleleo 的「备份带完整性清单、恢复先校验、失败可回滚」。
#
# 备份范围：/etc/xray-hy 下的运行数据 —— config.json、confs/*.json、
# nodes/*.env、certs/、state.env、target 自定义等；**排除** snapshots/ 与
# backups/（历史与备份自身，避免递归与体积膨胀）。Xray 二进制与 geodata
# 不入包：可按版本通道重新下载，备份里只记录版本号便于核对。
#
# 归档结构：
#   payload/          /etc/xray-hy 的内容快照
#   manifest.tsv      meta 行 + 每文件 "sha256<TAB>size<TAB>相对路径"

_backup_meta() {
    printf 'meta\tscript-version\t%s\n' "$XHY_VERSION"
    printf 'meta\tscript-build\t%s\n' "$XHY_BUILD"
    printf 'meta\tcreated\t%s\n' "$1"
    printf 'meta\txray\t%s\n' "$(xray_installed_version 2>/dev/null || true)"
}

backup_create() {
    local out=""
    while (($#)); do
        case "$1" in
            --out) out="${2:?--out 需要路径}"; shift 2 ;;
            *) die "backup 的参数只有 --out，收到: $1" ;;
        esac
    done
    need_root
    init_dirs
    local ts stage f cnt=0
    ts="$(date +%Y%m%d-%H%M%S)"
    [[ -n "$out" ]] || out="$XHY_BACKUP/xhy-backup-$ts.tar.gz"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-bak.XXXXXX")"
    mkdir -p "$stage/payload"
    if [[ -d "$XHY_ETC" ]]; then
        cp -a "$XHY_ETC/." "$stage/payload/"
    else
        die "$XHY_ETC 不存在：还没有可备份的数据（先 install）"
    fi
    rm -rf "$stage/payload/snapshots" "$stage/payload/backups"
    {
        printf '# xray-hy backup manifest v1\n'
        _backup_meta "$ts"
        # busybox find 没有 -printf，用相对路径逐行处理
        ( cd "$stage/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) \
            | while IFS= read -r f; do
                printf '%s\t%s\t%s\n' \
                    "$(sha256sum "$stage/payload/$f" | awk '{print $1}')" \
                    "$(wc -c <"$stage/payload/$f")" \
                    "$f"
            done
    } >"$stage/manifest.tsv"
    cnt="$(grep -c $'^[0-9a-f]\{64\}\t' "$stage/manifest.tsv" || true)"
    if ! tar -C "$stage" -czf "$out" payload manifest.tsv; then
        rm -rf "$stage"
        die "打包失败: $out"
    fi
    rm -rf "$stage"
    chmod 0600 "$out"
    ok "备份完成: $out"
    printf '  文件数: %s   大小: %s 字节\n' "$cnt" "$(wc -c <"$out")"
    printf '  %s\n' "提示：备份含全部节点凭证与证书私钥，请按敏感文件保管。"
}

backup_restore() {
    local arc="${1:-}"
    [[ -n "$arc" ]] || die "用法: xhy restore <备份文件.tar.gz>"
    [[ -f "$arc" ]] || die "备份文件不存在: $arc"
    need_root
    init_dirs
    local stage bad=0 total=0 sum size f
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-rst.XXXXXX")"
    if ! tar -xzf "$arc" -C "$stage"; then
        rm -rf "$stage"
        die "解包失败：文件损坏或不是 tar.gz"
    fi
    [[ -d "$stage/payload" && -f "$stage/manifest.tsv" ]] \
        || { rm -rf "$stage"; die "不是 xray-hy 备份（缺 payload/manifest.tsv）"; }

    # 1) 完整性校验 —— 任何一项不过就整体放弃，绝不部分还原。
    while IFS=$'\t' read -r sum size f; do
        [[ "$sum" == "meta" || "$f" == "relative-path" ]] && continue
        case "$sum" in '#'*) continue ;; esac
        total=$((total + 1))
        if [[ ! -f "$stage/payload/$f" ]] \
           || [[ "$(sha256sum "$stage/payload/$f" 2>/dev/null | awk '{print $1}')" != "$sum" ]]; then
            warn "校验失败: $f"
            bad=1
        fi
    done <"$stage/manifest.tsv"
    if (( bad )); then
        rm -rf "$stage"
        die "备份完整性校验未通过（$total 项中存在损坏），已放弃还原，目标机未做任何改动"
    fi
    ok "清单校验通过: $total 个文件"
    grep '^meta' "$stage/manifest.tsv" | sed 's/^meta\t/  /'

    # 2) 确认 + 现状留底
    local pre="$XHY_BACKUP/pre-restore-$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$XHY_ETC" ]] && [[ -n "$(ls -A "$XHY_ETC" 2>/dev/null || true)" ]]; then
        mkdir -p "$pre"
        cp -a "$XHY_ETC/." "$pre/"
        info "还原前现状已留底: $pre"
    fi
    if ! confirm "用这份备份覆盖 $XHY_ETC？（备份里没有的 nodes/confs 条目会被删除，保持与备份一致）" "n"; then
        rm -rf "$stage"
        info "已取消"
        return 0
    fi

    # 3) 清掉会与备份产生歧义的内容，再整体拷入。
    rm -rf "$XHY_ETC/confs" "$XHY_ETC/nodes" "$XHY_ETC/certs"
    rm -f "$XHY_ETC/state.env" "$XHY_ETC/config.json"
    cp -a "$stage/payload/." "$XHY_ETC/"
    rm -rf "$stage"                                         # 配置一律从 nodes 重建：
    rm -rf "$XHY_ETC/confs" "$XHY_ETC/config.json"          # confs/ 与 config.json 不沿用备份
    chmod 0700 "$XHY_ETC/nodes" "$XHY_ETC/certs" 2>/dev/null || true
    chmod 0600 "$XHY_ETC/state.env" 2>/dev/null || true

    # 4) 新机器没有 Xray：数据已还原，指引装核心后再起服务。
    if [[ ! -x "$XRAY_BIN" ]]; then
        warn "本机还没有 Xray。数据已还原，接下来: xhy core update 安装核心，再 xhy service start"
        return 0
    fi

    # 5) 从 nodes 重建配置并验证；失败整体回滚到留底。
    local frag
    if ! ( for frag in "$XHY_NODES"/*.env; do
              [[ -f "$frag" ]] || continue
              write_fragment "$frag" || exit 1
          done && rebuild_config && xray_config_test ); then
        err "还原后的配置重建/校验失败，回滚到还原前状态"
        rm -rf "$XHY_ETC/confs" "$XHY_ETC/nodes" "$XHY_ETC/certs"
        rm -f "$XHY_ETC/state.env" "$XHY_ETC/config.json"
        cp -a "$pre/." "$XHY_ETC/"
        die "已回滚。备份清单是完整的，问题多半在目标机环境（版本/端口冲突），看上面的报错"
    fi
    config_reload || warn "配置已写入，但服务重启失败（尚未 install？可 xhy service start 手动起）"
    ok "还原完成（配置已按 nodes 重建并通过 xray -test）"
}

# ===================== lib/update.sh =====================
# xray-hy / script, core, geodata and configuration updates.

# 单文件发布后，更新脚本 = 下载新的 install.sh -> 语法检查 -> 原子替换自己。
# 不依赖 git，也不会把下载到的内容直接喂给 shell：先落到临时文件、跑
# `bash -n`、比对构建号，确认后整文件替换。配置与节点数据完全不动。
#
# 非交互门控（借鉴 idleleo 的发布序列策略）：
#   --yes          自动确认；仅限同一主版本序列内（v1.x -> v1.y）
#   --allow-major  跨主版本（v1 -> v2）时解除 --yes 的限制，需与 --yes 同用
update_script() {
    local autoyes=0 allowmajor=0 a
    for a in "$@"; do
        case "$a" in
            --yes) autoyes=1 ;;
            --allow-major) allowmajor=1 ;;
            *) die "update script 的选项只有 --yes 和 --allow-major，收到: $a" ;;
        esac
    done
    need_root
    info "当前版本: $XHY_VERSION (build $XHY_BUILD)"
    info "检查更新: $XHY_INSTALL_URL"
    local tmp newbuild newver
    tmp="$(mktemp "${TMPDIR:-/tmp}/xhy-update.XXXXXX")" || die "无法创建临时文件"
    if ! fetch "$XHY_INSTALL_URL" "$tmp"; then
        rm -f "$tmp"
        warn "拉取失败，保持当前版本 $XHY_VERSION"
        return 1
    fi
    if ! bash -n "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "下载的脚本未通过 bash -n 语法检查，已放弃（本地脚本未改动）"
    fi
    newbuild="$(sed -n 's/^XHY_BUILD="\(.*\)"$/\1/p' "$tmp" | head -1)"
    if [[ -z "$newbuild" ]]; then
        rm -f "$tmp"
        die "下载的脚本里找不到构建号，可能不是本项目的 install.sh，已放弃"
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]]; then
        rm -f "$tmp"
        ok "脚本已是最新 ($XHY_VERSION build $newbuild)"
        return 0
    fi
    newver="$(sed -n 's/^XHY_VERSION="\(.*\)"$/\1/p' "$tmp" | head -1 || true)"
    [[ -n "$newver" ]] || newver="未知"
    info "发现新版本: $newver (build $newbuild，当前 $XHY_VERSION build $XHY_BUILD)"
    if have_cmd diff; then
        diff -u "$XHY_SELF" "$tmp" | head -40 || true
    fi
    if [[ "${newver%%.*}" != "${XHY_VERSION%%.*}" ]]; then
        warn "这是跨主版本更新 ($XHY_VERSION -> $newver)，可能包含不兼容变更，建议先看 release notes。"
        if (( autoyes && ! allowmajor )); then
            rm -f "$tmp"
            die "非交互模式拒绝跨主版本更新；确认后请加 --allow-major 重试"
        fi
    fi
    if (( autoyes )); then
        info "--yes: 自动确认替换"
    elif ! confirm "替换 $XHY_SELF 为这个构建？配置与节点数据不受影响。" "y"; then
        rm -f "$tmp"
        info "已取消"
        return 0
    fi
    backup_file "$XHY_SELF"
    if ! install -m 0755 "$tmp" "$XHY_SELF.new" || ! mv -f "$XHY_SELF.new" "$XHY_SELF"; then
        rm -f "$tmp" "$XHY_SELF.new"
        die "替换失败，旧版本仍在 $XHY_SELF"
    fi
    rm -f "$tmp"
    ok "已更新到 build $newbuild；当前进程仍是旧版，下次执行 xhy 生效"
}

update_core() {
    need_root
    init_dirs
    local ver rollback=""
    ver="$(xray_resolve_version)"
    info "版本通道 $(xray_channel) -> 目标 $ver"
    # Keep the working binary so an incompatible new core can be rolled back
    # automatically (idea borrowed from easyxray's version switch).
    if [[ -x "$XRAY_BIN" ]]; then
        rollback="$(mktemp "$XHY_BACKUP/xray-rollback.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$rollback" ]] && cp -a "$XRAY_BIN" "$rollback"; then :; else rollback=""; fi
    fi
    xray_install "$ver"
    if [[ -s "$XHY_ETC/config.json" ]] && ! xray_config_test >/dev/null 2>&1; then
        if [[ -n "$rollback" ]]; then
            cp -a "$rollback" "$XRAY_BIN"
            err "新版本 $ver 无法加载现有配置，已自动回滚到原二进制。"
        fi
        die "请检查 $XHY_ETC/config.json，或改用兼容版本"
    fi
    if [[ -s "$XHY_ETC/config.json" ]]; then config_reload; fi
    [[ -n "$rollback" ]] && rm -f "$rollback"
    ok "Xray 更新完成: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

update_geodata() {
    need_root
    local f
    install -d -m 0755 "$XRAY_ASSET"
    for f in geoip.dat geosite.dat; do
        info "更新 $f"
        if fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" "$XRAY_ASSET/$f.new"; then
            local sz
            sz="$(stat -c%s "$XRAY_ASSET/$f.new" 2>/dev/null || echo 0)"
            if (( sz < 102400 )); then
                warn "$f 下载内容异常 (${sz} bytes)，保留旧文件"
                rm -f "$XRAY_ASSET/$f.new"
                continue
            fi
            backup_file "$XRAY_ASSET/$f"
            mv "$XRAY_ASSET/$f.new" "$XRAY_ASSET/$f"
            chmod 0644 "$XRAY_ASSET/$f"
        else
            rm -f "$XRAY_ASSET/$f.new"
            warn "$f 更新失败，保留旧文件"
        fi
    done
    ok "Geodata 更新完成"
}

update_config() {
    need_root
    node_rebuild_all
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "配置已按当前设置重建"
}

update_all() {
    update_script || true
    update_core
    update_geodata
    update_config
    self_check
}

self_check() {
    printf '\n========== xray-hy 环境检查 ==========\n'
    platform_summary
    printf '脚本版本 : %s (build %s)\n' "$XHY_VERSION" "$XHY_BUILD"
    printf '脚本路径 : %s\n' "$XHY_SELF"
    printf '配置目录 : %s\n' "$XHY_ETC"
    printf '出口 IPv4: %s\n' "$(public_ip || true)"
    local _ip6; _ip6="$(public_ip6 || true)"
    if [[ -n "$_ip6" ]]; then
        printf '出口 IPv6: %s（REALITY/hy2 客户端可直接用它做双栈连接）\n' "$_ip6"
    else
        printf '出口 IPv6: 无\n'
    fi
    printf '%s\n' "--------------------------------------"
    core_status
    local inst mptcp v6rules
    inst="$(xray_installed_version)"
    if [[ "$inst" == [0-9]* ]]; then
        if version_lt "v$inst" "$XHY_MPTCP_FIXED_VERSION"; then
            printf 'MPTCP 修复: 未包含 (v%s < %s)，依赖内核缓解\n' "$inst" "$XHY_MPTCP_FIXED_VERSION"
        else
            printf 'MPTCP 修复: 已包含\n'
        fi
        if ! version_lt "v$inst" "$XHY_PQ_BREAK_VERSION"; then
            warn "当前 v$inst >= $XHY_PQ_BREAK_VERSION：sing-box / mihomo 客户端可能无法连接 REALITY (#4520)"
        else
            printf '客户端兼容: OK (v%s < %s)\n' "$inst" "$XHY_PQ_BREAK_VERSION"
        fi
    fi
    mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf '内核 MPTCP: %s (应为 0)\n' "$mptcp"
    [[ "$mptcp" == "1" ]] && warn "MPTCP 已启用，请执行 xhy bbr on 关闭它（钉死旧版时的关键缓解）"
    printf '%s\n' "--------------------------------------"
    bbr_status
    printf '%s\n' "--------------------------------------"
    firewall_status | head -4
    if have_cmd ip6tables; then
        v6rules="$(ip6tables -S 2>/dev/null | grep -c "$FW_CHAIN" || true)"
        printf 'IPv6 链规则: %s 条\n' "${v6rules:-0}"
        [[ "${v6rules:-0}" == "0" ]] && warn "IPv6 未受保护，SSH 可能绕过防爆破"
    else
        warn "未安装 ip6tables，IPv6 未受保护"
    fi
    printf '%s\n' "--------------------------------------"
    target_show
    printf '节点数量 : %s\n' "$(node_count)"
    printf '配置快照 : %s 份 (xhy snapshots / xhy rollback)\n' \
        "$(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s\n' "--------------------------------------"
    if [[ -s "$XHY_ETC/config.json" ]] && [[ -x "$XRAY_BIN" ]]; then
        if xray_config_test >/dev/null 2>&1; then ok "配置语法: 通过"; else err "配置语法: 失败"; fi
    else
        warn "尚未安装或未生成配置"
    fi
    if svc_active "$SVC_XRAY" 2>/dev/null; then ok "Xray 服务: 运行中"; else warn "Xray 服务: 未运行"; fi
    if [[ -x "$CF_BIN" ]] && svc_active "$SVC_CF" 2>/dev/null; then ok "CF Tunnel: 运行中"; fi
    printf '======================================\n\n'
}

# Pre-install checklist, modelled on the environment gates used by ArgoX /
# xray-agent. Read-only; safe to run on a live server.
preflight_check() {
    printf '\n========== xray-hy 安装前预检（只读） ==========\n'
    local kver major minor patch min_patch="" mem_kb disk_kb m r c p
    if (( $(id -u) == 0 )); then printf '  [正常] root 权限\n'; else printf '  [问题] 需要 root 权限\n'; fi
    printf '  [信息] 发行版 %s %s / init %s / 架构 %s\n' \
        "$XHY_DISTRO" "$XHY_DISTRO_VER" "$XHY_INIT" "$XHY_ARCH"

    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    disk_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)"
    if (( mem_kb < 131072 )); then
        printf '  [注意] 内存 %s MB 偏小，安装时会设置 GOMEMLIMIT\n' "$((mem_kb / 1024))"
    else
        printf '  [正常] 内存 %s MB\n' "$((mem_kb / 1024))"
    fi
    if (( ${disk_kb:-0} < 307200 )); then
        printf '  [问题] 可用磁盘不足 300 MB\n'
    else
        printf '  [正常] 可用磁盘 %s MB\n' "$((disk_kb / 1024))"
    fi

    kver="$(uname -r)"; kver="${kver%%-*}"
    IFS=. read -r major minor patch <<<"$kver"
    patch="${patch%%[^0-9]*}"
    case "${major}.${minor}" in
        5.10) min_patch=272 ;; 5.15) min_patch=223 ;; 6.1)  min_patch=190 ;;
        6.6)  min_patch=159 ;; 6.12) min_patch=113 ;; 6.18) min_patch=56 ;;
        7.2)  min_patch=10  ;;
    esac
    if [[ -n "$min_patch" ]]; then
        if (( ${patch:-0} >= min_patch )); then
            printf '  [正常] 内核 %s 已包含 CVE-2026-98432 修复 (>= %s.%s.%s)\n' \
                "$kver" "$major" "$minor" "$min_patch"
        else
            printf '  [问题] 内核 %s 低于修复线 %s.%s.%s，请更新内核并重启\n' \
                "$kver" "$major" "$minor" "$min_patch"
        fi
    else
        printf '  [注意] 内核 %s 不在已知分支映射内，请自行核对 CVE-2026-98432\n' "$kver"
    fi
    m="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo NA)"
    r="$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo NA)"
    if [[ "$m" == "0" && "$r" == "0" ]]; then
        printf '  [正常] MPTCP / tcp_migrate_req 均已关闭\n'
    else
        printf '  [注意] MPTCP=%s migrate_req=%s，建议执行 xhy bbr on\n' "$m" "$r"
    fi

    for c in bash curl openssl iptables unzip; do
        if have_cmd "$c"; then printf '  [正常] 依赖 %s\n' "$c"; else printf '  [注意] 缺少 %s（install 会尝试安装）\n' "$c"; fi
    done
    if curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null; then
        printf '  [正常] GitHub 可达\n'
    else
        printf '  [问题] GitHub 不可达，Xray / cloudflared 下载会失败\n'
    fi
    for p in 443 8443 8080 10086; do
        if port_busy "$p"; then printf '  [注意] 端口 %s 已被占用\n' "$p"; fi
    done
    if [[ -r /proc/net/if_inet6 ]]; then
        printf '  [信息] IPv6 协议栈可用（可选 DUAL_STACK=on）\n'
    else
        printf '  [信息] IPv6 未启用，DUAL_STACK 请保持 off\n'
    fi
    if [[ -x "$XRAY_BIN" ]]; then
        printf '  [信息] 已装 Xray %s\n' "$(xray_installed_version)"
    else
        printf '  [信息] Xray 未安装，install 将下载 %s\n' "$(xray_resolve_version)"
    fi
    printf '==============================================\n\n'
}

# ============ 内嵌数据：conf/targets.tsv ============
targets_tsv() {
    cat <<'XHY_TARGETS_TSV'
# xray-hy REALITY target candidates
# Format: region|country-code|label|target|SNI
# These are starting points, NOT guarantees. Sites change, move behind CDNs or
# drop TLS 1.3. Always run `xhy target check` from the VPS before deploying.
# Rule of thumb: a target must answer TLS 1.3 + HTTP/2, must not redirect, and
# must NOT sit behind a CDN (otherwise your server becomes an open forwarder).
# Add your own lines freely; the first line matching a region is preferred.
auto|XX|amazon|www.amazon.com:443|www.amazon.com
us|US|t-mobile|www.t-mobile.com:443|business.t-mobile.com
us|US|cloudflare-free-alt|www.microsoft.com:443|www.microsoft.com
uk|GB|arm|www.arm.com:443|learn.arm.com
uk|GB|bbc|www.bbc.co.uk:443|www.bbc.co.uk
jp|JP|tsukuba|www.tsukuba.ac.jp:443|www.tsukuba.ac.jp
jp|JP|rakuten|www.rakuten.co.jp:443|www.rakuten.co.jp
hk|HK|disneyland|www.hongkongdisneyland.com:443|entitlement.hongkongdisneyland.com
hk|HK|hku|www.hku.hk:443|www.hku.hk
tw|TW|china-airlines|www.china-airlines.com:443|book.china-airlines.com
tw|TW|ntu|www.ntu.edu.tw:443|www.ntu.edu.tw
sg|SG|sigtel|sigtelinc.com:443|www.sigtelinc.com
sg|SG|nus|www.nus.edu.sg:443|www.nus.edu.sg
fr|FR|bouygues|www.bouyguestelecom.fr:443|www.bouygtel.fr
fr|FR|orange|www.orange.fr:443|www.orange.fr
de|DE|mercedes|www.mercedes-benz.de:443|pro.mercedes-benz.com
de|DE|siemens|www.siemens.com:443|www.siemens.com
in|IN|incredibleindia|www.incredibleindia.gov.in:443|www.incredibleindia.org
in|IN|iitb|www.iitb.ac.in:443|www.iitb.ac.in
ca|CA|shopify|www.shopify.ca:443|www.shopify.ca
au|AU|abc|www.abc.net.au:443|www.abc.net.au
nl|NL|tudelft|www.tudelft.nl:443|www.tudelft.nl
other|XX|amazon-corp|www.amazon.com:443|corporate.amazon.com
other|XX|microsoft|www.microsoft.com:443|www.microsoft.com
XHY_TARGETS_TSV
}

# ===================== entry/main.sh =====================
# 把「正在运行的这个文件」装到 $XHY_APP_DIR/xhy，供 /usr/local/bin/xhy 软链。
#   本地文件运行（sh install.sh / ./xhy）：直接复制
#   bash <(curl ...)：BASH_SOURCE 是管道，读不回来，按 XHY_INSTALL_URL 取一份
# 已经在目标位置运行时（开发目录）什么都不做。
install_self() {
    need_root
    install -d -m 0755 "$XHY_APP_DIR" || die "无法创建 $XHY_APP_DIR"
    local src="${XHY_RUNNING:-}" tmp
    if [[ -n "$src" ]] && [[ "$(readlink -f "$src" 2>/dev/null || echo "$src")" == "$(readlink -f "$XHY_SELF" 2>/dev/null || echo "$XHY_SELF")" ]]; then
        chmod 0755 "$XHY_SELF" 2>/dev/null || true
        return 0
    fi
    tmp="$XHY_SELF.new.$$"
    if [[ -n "$src" && -f "$src" ]]; then
        install -m 0755 "$src" "$tmp" || die "复制脚本到 $tmp 失败"
    else
        info "当前是从管道运行的，重新下载一份脚本到 $XHY_SELF ..."
        fetch "$XHY_INSTALL_URL" "$tmp" || die "下载脚本本体失败（见上面的 curl 错误码）"
        # 拿到的必须是本项目（有构建号）。构建号不同只说明 release 已更新，
        # 装「最新这份」正是期望行为；真正的风险（下到非本项目内容）由下面的
        # 构建号存在性检查兜底。
        if ! grep -q '^XHY_BUILD="[0-9a-f]\{12\}"$' "$tmp"; then
            rm -f "$tmp"
            die "下载到的脚本缺少构建号，可能不是本项目的 install.sh，已放弃"
        fi
        if ! grep -q "^XHY_BUILD=\"$XHY_BUILD\"$" "$tmp"; then
            warn "下载到的构建 $(sed -n 's/^XHY_BUILD=\"\(.*\)\"$/\1/p' "$tmp" | head -1) 与当前运行的不同（release 已更新），将安装最新这份"
        fi
        chmod 0755 "$tmp"
    fi
    mv -f "$tmp" "$XHY_SELF" || { rm -f "$tmp"; die "无法写入 $XHY_SELF"; }
    ok "脚本已安装到 $XHY_SELF"
}

create_symlink() {
    install -d -m 0755 /usr/local/bin
    chmod 0755 "$XHY_SELF"
    ln -sf "$XHY_SELF" /usr/local/bin/xhy
    ok "命令入口: /usr/local/bin/xhy -> $XHY_SELF"
}

usage() {
    cat <<EOF
xray-hy $XHY_VERSION - 模块化 Xray 部署管理 (Debian/Ubuntu, Alpine, RHEL 系)

用法: xhy <命令> [选项]

  安装与检查
    install                     完整初始化（脚本本体、依赖、Xray、服务、BBR、防火墙）
    preflight                   安装前预检（端口/磁盘/内核/网络/依赖）
    check                       环境自检报告
    version                     显示脚本版本

  节点管理
    add <mode> [--port N] [选项] 添加节点
    list                        列出所有节点
    link [--all|--uri|--qr]     导出 vless:// 链接
    del <mode> <port>           删除节点
    menu                        交互式菜单

    mode: direct | tunnel | reality | xhttp | hy2
    add 选项: --host --path --uuid --sni --target --domain --token --reality
              --masq --up --down   (hy2 专用)
    默认端口: direct 8080 / tunnel 10086 / reality 443 / xhttp 8081 / hy2 8443(UDP)
    hy2 用 Xray 内置 Hysteria2 入站(v26.3.27+)，自签证书 + pinSHA256 链接

  配置
    config                      路由/DNS/日志开关菜单（也可直接 set）
    config set KEY VALUE        直接改设置，见下方 KEY
    snapshots                   列出最近 5 份整套状态快照
    rollback [快照路径]         回滚整套状态（config + 节点 + 分片 + state）
    target                      伪装站选择 / 校验菜单
    firewall [apply|strict|off|status]   双栈 IPv4 + IPv6
    bbr [on|status]             含 MPTCP 关闭 (CVE-2026-98432)

  版本与更新
    core [status|channel pinned|channel latest|channel vX.Y.Z|update]
    update [script|core|geodata|config|all]
    update script --yes [--allow-major]   非交互更新（跨主版本需 --allow-major）

  备份与导出
    backup [--out FILE]              备份 /etc/xray-hy（内含逐文件 SHA256 清单）
    restore <备份文件>               校验清单后还原（先备份现状，失败自动回滚）
    export clash|singbox [--out F]   导出 mihomo/Clash 或 sing-box 节点配置

  服务与卸载
    service [start|stop|restart|status]
    uninstall                   卸载（可选保留配置）

config 的 KEY: BLOCK_BT BLOCK_PRIVATE BLOCK_CN BLOCK_ADS
               DNS_PROVIDER(cloudflare|quad9|dns-sb|system)
               LOG_LEVEL(warning|info|none) SSH_GUARD TARGET_REGION
               DUAL_STACK(on=新节点监听 :: 双栈，off=0.0.0.0)
EOF
}

default_port() {
    case "$1" in
        direct) echo 8080 ;; tunnel) echo 10086 ;; reality) echo 443 ;; xhttp) echo 8081 ;; hy2) echo 8443 ;;
        *) echo 0 ;;
    esac
}

cmd_install() {
    need_root
    detect_platform
    printf '\n'
    platform_summary
    printf '\n'
    stage 1 7 "依赖检查与安装（这一步最慢；卡住多半是软件源，见文末提示）"
    ensure_deps
    stage 2 7 "安装脚本本体与命令入口"
    install_self
    create_symlink
    stage 3 7 "创建数据目录"
    init_dirs
    if [[ -z "$(state_get DUAL_STACK '')" && -n "$(public_ip6 || true)" ]]; then
        state_set DUAL_STACK on
        ok "检测到 IPv6 出口，新节点默认双栈监听 (::)（xhy config set DUAL_STACK off 可改回）"
    fi
    local ver
    stage 4 7 "下载并校验 Xray"
    # 版本二选一：最新版功能全，但 >=26.9.8 的 REALITY 要求 MLKEM ClientHello，
    # sing-box / mihomo 客户端连不上（SagerNet/sing-box#4520）；钉死版没这问题。
    if confirm "安装最新版 Xray？(回车/n = 钉死 ${XHY_PINNED_VERSION}，sing-box/mihomo 客户端兼容性最好)" "n"; then
        xray_set_channel latest
    else
        xray_set_channel pinned
    fi
    ver="$(xray_resolve_version)"
    xray_install "$ver"
    stage 5 7 "安装服务与开机自启"
    install_xray_service

    stage 6 7 "内核网络优化与防火墙"
    if confirm "启用 BBR 与内核网络优化？" "y"; then
        tune_bbr || warn "BBR 未启用，可执行 xhy check 复查。"
    fi
    if confirm "配置防火墙（safe 模式：SSH 防爆破 + 放行节点端口，不改动现有规则）？" "y"; then
        state_set FIREWALL_MODE safe
        state_set SSH_GUARD on
        firewall_apply safe
    fi

    stage 7 7 "渲染配置并启动服务"
    rebuild_config
    xray_config_test || die "初始配置校验失败"
    svc_start "$SVC_XRAY" || die "Xray 启动失败，查看 $XHY_LOGDIR/xray.err"
    state_set INSTALLED "$(date -Is)"
    ok "安装完成。现在用 xhy add reality 添加第一个节点，或输入 xhy 打开菜单。"
}

cmd_add_interactive() {
    local mode port host path sni target domain token
    local -a extra=()
    cat <<'EOF'
  节点类型：
    1) direct   VLESS + WS 直连（明文，建议套 CDN / 反代）
    2) tunnel   VLESS + WS + Cloudflare Tunnel（不需要公网入站端口）
    3) reality  VLESS + REALITY + XTLS Vision
    4) xhttp    VLESS + XHTTP（可选叠加 REALITY）
    5) hy2      Hysteria2（UDP/QUIC，Xray 内置入站 + 自签证书）
EOF
    case "$(ask '选择类型' '3')" in
        1) mode=direct ;; 2) mode=tunnel ;; 3) mode=reality ;; 4) mode=xhttp ;; 5) mode=hy2 ;; *) return 0 ;;
    esac
    port="$(ask '监听端口' "$(default_port "$mode")")"
    valid_port "$port" || { err "端口不合法"; return 1; }
    local ip4 ip6
    ip4="$(public_ip || true)"
    ip6="$(public_ip6 || true)"
    host="$(ask '客户端连接地址(域名或 IP)' "${ip4:-$ip6}")"
    if [[ -n "$ip6" && -n "$ip4" ]]; then
        info "检测到双栈出口 (v6: $ip6)。想让客户端也能走 v6：xhy config set DUAL_STACK on，链接会自动附 IPv6 变体。"
    elif [[ -z "$ip4" && -n "$ip6" ]]; then
        info "仅检测到 IPv6 出口 ($ip6)，已用它作为默认连接地址。"
    fi
    path="$(ask '路径 (回车随机生成)' '')"

    local -a opts=(--host "$host")
    [[ -n "$path" ]] && opts+=(--path "$path")
    case "$mode" in
        reality)
            if confirm "手动指定 REALITY target / SNI？" "n"; then
                # 一条输入：host[:port][,sni=xxx]；不写 sni= 时 SNI 与 target 同名，
                # 绝大多数情况两者就是同一个域，没必要问两遍。
                local t_in ts
                t_in="$(ask 'target (域名[:443]，SNI 不同才加 ,sni=其他域名)')"
                [[ -n "$t_in" ]] || return 0
                ts="${t_in#*,sni=}"; [[ "$ts" == "$t_in" ]] && ts=""
                t_in="${t_in%%,*}"
                [[ "$t_in" == *:* ]] || t_in="${t_in}:443"
                opts+=(--target "$t_in" --sni "${ts:-${t_in%%:*}}")
            else
                info "按地区自动选择伪装站并做 TLS 1.3 / H2 校验..."
            fi ;;
        xhttp)
            if confirm "叠加 REALITY（无需证书）？" "n"; then extra+=(--reality); fi ;;
        tunnel)
            domain="$(ask 'Cloudflare 公开主机名' '')"
            token="$(ask 'Tunnel Token (回车复用已保存的)' '')"
            opts+=(--domain "$domain")
            [[ -n "$token" ]] && opts+=(--token "$token") ;;
        hy2)
            opts+=(--sni "$(ask 'SNI / 证书 CN' 'www.bing.com')")
            if confirm "自定义伪装站 URL？" "n"; then
                opts+=(--masq "$(ask '伪装站 URL' 'https://www.bing.com/')")
            fi
            if confirm "设置 Brutal 带宽上限？" "n"; then
                opts+=(--up "$(ask '上行 (如 100mbps)' '100mbps')" --down "$(ask '下行' '300mbps')")
            fi ;;
    esac
    node_add "$mode" "$port" "${opts[@]}" "${extra[@]}"
}

cmd_add() {
    if (( $# == 0 )); then cmd_add_interactive; return; fi
    local mode="$1" port="" opts=()
    shift
    port="$(default_port "$mode")"
    while (( $# > 0 )); do
        case "$1" in
            --port)   port="$2"; shift 2 ;;
            --host|--path|--uuid|--sni|--target|--domain|--token|--masq|--up|--down) opts+=("$1" "$2"); shift 2 ;;
            --reality) opts+=("$1"); shift ;;
            *) die "未知参数: $1（见 xhy --help）" ;;
        esac
    done
    valid_port "$port" || die "端口不合法: $port"
    node_add "$mode" "$port" "${opts[@]}"
}

cmd_config_set() {
    local key="$1" val="$2"
    case "$key" in
        BLOCK_BT|BLOCK_PRIVATE|BLOCK_CN|BLOCK_ADS|SSH_GUARD|DUAL_STACK)
            [[ "$val" == "on" || "$val" == "off" ]] || die "$key 只能是 on/off" ;;
        DNS_PROVIDER)
            [[ "$val" =~ ^(cloudflare|quad9|dns-sb|system)$ ]] || die "DNS_PROVIDER 值不合法" ;;
        LOG_LEVEL)
            [[ "$val" =~ ^(warning|info|debug|none)$ ]] || die "LOG_LEVEL 值不合法" ;;
        TARGET_REGION) ;;
        *) die "未知设置项: $key" ;;
    esac
    # Snapshot before the setting changes: a snapshot should always represent
    # the state you had *before* this command, otherwise it cannot undo it.
    snapshot_state
    state_set "$key" "$val"
    ok "$key=$val"
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all
    [[ "$key" == "SSH_GUARD" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)"
}

cmd_config_menu() {
    while true; do
        printf '\n当前配置（改动会立即重建并校验配置）：\n'
        printf '  1) BT 阻断          %s\n' "$(state_get BLOCK_BT on)"
        printf '  2) 私网地址阻断     %s\n' "$(state_get BLOCK_PRIVATE on)"
        printf '  3) 回国 IP 阻断     %s\n' "$(state_get BLOCK_CN off)"
        printf '  4) 广告域名阻断     %s\n' "$(state_get BLOCK_ADS off)"
        printf '  5) SSH 防爆破       %s\n' "$(state_get SSH_GUARD on)"
        printf '  6) DoH              %s\n' "$(state_get DNS_PROVIDER cloudflare)"
        printf '  7) 日志级别         %s\n' "$(state_get LOG_LEVEL warning)"
        printf '  8) 伪装站地区       %s\n' "$(target_region)"
        printf '  9) 双栈监听         %s\n' "$(state_get DUAL_STACK off)"
        printf '  0) 返回\n'
        case "$(ask '选择' '0')" in
            1) cmd_config_set BLOCK_BT "$([[ "$(state_get BLOCK_BT on)" == on ]] && echo off || echo on)" ;;
            2) cmd_config_set BLOCK_PRIVATE "$([[ "$(state_get BLOCK_PRIVATE on)" == on ]] && echo off || echo on)" ;;
            3) cmd_config_set BLOCK_CN "$([[ "$(state_get BLOCK_CN off)" == on ]] && echo off || echo on)" ;;
            4) cmd_config_set BLOCK_ADS "$([[ "$(state_get BLOCK_ADS off)" == on ]] && echo off || echo on)" ;;
            5) cmd_config_set SSH_GUARD "$([[ "$(state_get SSH_GUARD on)" == on ]] && echo off || echo on)" ;;
            6) cmd_config_set DNS_PROVIDER "$(ask 'cloudflare/quad9/dns-sb/system' 'cloudflare')" ;;
            7) cmd_config_set LOG_LEVEL "$(ask 'warning/info/debug/none' 'warning')" ;;
            8) target_menu ;;
            9) cmd_config_set DUAL_STACK "$([[ "$(state_get DUAL_STACK off)" == on ]] && echo off || echo on)" ;;
            0) return 0 ;;
        esac
    done
}

cmd_link() {
    local what="${1:---all}" f
    case "$what" in
        --uri)
            for f in "$XHY_NODES"/*.env; do
                [[ -f "$f" ]] || continue
                link_uri "$f"
            done
            return 0 ;;
        --all|"") link_all; return ;;
        --qr)
            local n=0; for f in "$XHY_NODES"/*.env; do [[ -f "$f" ]] || continue; link_qr "$f"; n=1; done
            (( n == 1 )) || warn "暂无节点"; return ;;
    esac
    # link <mode> <port>
    f="$(node_file "$what" "${2:-}")"
    [[ -f "$f" ]] || die "节点不存在: ${what}_${2:-}"
    link_from_env "$f"
}

cmd_uninstall() {
    need_root
    warn "这将停止 Xray / cloudflared 服务并移除 xray-hy 的开机项与防火墙链。"
    confirm "确定卸载？" "n" || { info "已取消"; return 0; }
    svc_stop "$SVC_CF"; svc_stop "$SVC_XRAY"
    svc_disable "$SVC_CF"; svc_disable "$SVC_XRAY"
    remove_cf_service 2>/dev/null || true
    firewall_off
    rm -f /etc/systemd/system/xray-hy.service /etc/systemd/system/xray-hy-firewall.service \
          /etc/init.d/xray-hy /etc/init.d/xray-hy-firewall \
          /usr/local/lib/xray-hy/tunnel-run /usr/local/bin/xhy \
          "$XHY_SELF" /etc/sysctl.d/90-xray-hy.conf /etc/modules-load.d/xray-hy.conf
    # 仓库内运行时 XHY_APP_DIR 就是工作树：只删入口，不碰 conf/ 和目录本身。
    if [[ "${XHY_DEV:-0}" != "1" ]]; then
        rm -rf "$XHY_APP_DIR/conf"
        rmdir "$XHY_APP_DIR" 2>/dev/null || true
    fi
    [[ "$XHY_INIT" == "systemd" ]] && systemctl daemon-reload
    if confirm "同时删除 Xray 二进制与所有节点配置/凭证？" "n"; then
        rm -f "$XRAY_BIN" "$CF_BIN"
        rm -rf "$XRAY_ASSET" "$XHY_ETC"
        ok "配置与凭证已删除"
    else
        ok "已保留 $XHY_ETC（内含节点凭证，权限 0600/0700）"
    fi
    ok "卸载完成"
}

cmd_menu() {
    while true; do
        printf '\n============ xray-hy %s ============\n' "$XHY_VERSION"
        printf '  %s / %s / Xray %s / 节点 %s 个\n' "$XHY_DISTRO" "$XHY_INIT" "$(xray_installed_version)" "$(node_count)"
        cat <<'EOF'
  ---- 节点 ----
   1) 添加节点               2) 节点列表
   3) 导出分享链接           4) 删除节点
  ---- 系统 ----
   5) 完整安装 / 重装        6) 环境自检
   7) 配置（路由/DNS/日志）  8) 伪装站
   9) 防火墙                10) BBR / 内核
  ---- 维护 ----
  11) 服务管理              12) Xray 版本通道
  13) 更新                  14) 卸载
   0) 退出
EOF
        case "$(ask '选择' '0')" in
            1) cmd_add_interactive ;;
            2) node_list; ask '按回车继续' '' ;;
            3) link_all; ask '按回车继续' '' ;;
            4) local m p
               m="$(ask '模式' 'reality')"; p="$(ask '端口' '443')"
               [[ -f "$(node_file "$m" "$p")" ]] && node_del "$m" "$p" || warn "节点不存在" ;;
            5) cmd_install ;;
            6) self_check ;;
            7) cmd_config_menu ;;
            8) target_menu ;;
            9) local fa
               fa="$(ask 'apply / strict / off / status' 'status')"
               case "$fa" in
                   apply)  firewall_apply safe ;;
                   strict) warn "strict 会丢弃除 SSH 与节点端口外的所有入站连接。"
                           if confirm "确认？" "n"; then firewall_apply strict; fi ;;
                   off)    firewall_off ;;
                   *)      firewall_status ;;
               esac ;;
           10) [[ "$(ask 'on / status' 'status')" == "on" ]] && tune_bbr || bbr_status ;;
           11) local sa
               sa="$(ask 'start / stop / restart / status' 'status')"
               case "$sa" in
                   start|stop|restart) "svc_$sa" "$SVC_XRAY" ;;
                   *) svc_status "$SVC_XRAY" ;;
               esac ;;
           12) core_status
               local ch; ch="$(ask 'pinned / latest / vX.Y.Z（回车不改）' '')"
               [[ -n "$ch" ]] && { xray_set_channel "$ch"; core_status; } ;;
           13) local ua; ua="$(ask 'all / script / core / geodata / config' 'all')"
               case "$ua" in
                   all) update_all ;; script) update_script ;; core) update_core ;;
                   geodata) update_geodata ;; config) update_config ;;
               esac ;;
           14) cmd_uninstall; return 0 ;;
            0) return 0 ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        --help|-h|help) usage; return 0 ;;
        --version|version) printf 'xray-hy %s\n' "$XHY_VERSION"; return 0 ;;
    esac

    need_root
    detect_platform
    acquire_lock
    trap release_lock EXIT

    case "$cmd" in
        install)    cmd_install ;;
        preflight)  preflight_check ;;
        check)      self_check ;;
        menu)       cmd_menu ;;
        add)        cmd_add "$@" ;;
        list)       node_list ;;
        link)       cmd_link "$@" ;;
        export)     cmd_export "$@" ;;
        backup)     backup_create "$@" ;;
        restore)    backup_restore "${1:?用法: xhy restore <备份文件>}" ;;
        del)        node_del "${1:?需要模式}" "${2:?需要端口}" ;;
        config)     if [[ "${1:-}" == "set" ]]; then cmd_config_set "${2:?需要 KEY}" "${3:?需要 VALUE}";
                    else cmd_config_menu; fi ;;
        snapshots)  list_snapshots ;;
        rollback)   rollback_config "${1:-}" ;;
        target)     target_menu ;;
        firewall)   case "${1:-status}" in
                        # --quiet is passed by the boot unit; forward it so boot
                        # logs stay clean.
                        apply)  firewall_apply safe "${2:-}" ;;
                        strict) firewall_apply strict ;;
                        off)    firewall_off ;;
                        *)      firewall_status ;;
                    esac ;;
        bbr)        case "${1:-status}" in on) tune_bbr ;; *) bbr_status ;; esac ;;
        core)       case "${1:-status}" in
                        status)  core_status ;;
                        channel) xray_set_channel "${2:?需要 pinned/latest/vX.Y.Z}"; core_status ;;
                        update)  update_core ;;
                        *) die "用法: xhy core [status|channel <值>|update]" ;;
                    esac ;;
        update)     case "${1:-all}" in
                        all) update_all ;;
                        script) shift; update_script "$@" ;;
                        core) update_core ;;
                        geodata) update_geodata ;; config) update_config ;;
                        *) die "用法: xhy update [all|script [--yes] [--allow-major]|core|geodata|config]" ;;
                    esac ;;
        service)    case "${1:-status}" in
                        start|stop|restart) "svc_$1" "$SVC_XRAY" ;;
                        status) svc_status "$SVC_XRAY" ;;
                        *) die "用法: xhy service [start|stop|restart|status]" ;;
                    esac ;;
        uninstall)  cmd_uninstall ;;
        *)          err "未知命令: $cmd"; usage; return 1 ;;
    esac
}

main "$@"
