#!/usr/bin/env bash
# xray-hy / common helpers. Sourced by the entrypoint, never executed directly.

XHY_VERSION="${XHY_VERSION:-1.4.1}"
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
