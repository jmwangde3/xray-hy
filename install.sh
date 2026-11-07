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
#     XHY_LANG          en / zh / auto；云 VNC 控制台中文会显示成小方块，用 en
#     XHY_ASCII         1 = 等同 XHY_LANG=en
# ===========================================================================

XHY_APP_DIR="${XHY_APP_DIR:-/usr/local/lib/xray-hy}"
XHY_INSTALL_URL="${XHY_INSTALL_URL:-https://github.com/jmwangde3/xray-hy/releases/latest/download/install.sh}"
export XHY_APP_DIR XHY_INSTALL_URL

_xhy_say() { printf '%s\n' "$*"; }
_xhy_err() { printf '%s\n' "$*" >&2; }
_xhy_die() { _xhy_err "[x] $*"; exit 1; }

# ---- 输出语言：云厂商网页 VNC 只有 ASCII 字体，中文全是小方块 ----
# 这一段只管 POSIX sh 自己的几条底层提示；bash 段由 lib/i18n.sh 完整判定。
_XHY_POSIX_LANG=zh
case "${XHY_LANG:-}" in
    en|EN|ascii|ASCII|english) _XHY_POSIX_LANG=en ;;
    zh|ZH|cn|CN|chinese)       _XHY_POSIX_LANG=zh ;;
    *)
        _xhy_lc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
        case "$_xhy_lc" in
            zh*|ZH*) ;;
            C|POSIX|c|posix|"") _XHY_POSIX_LANG=en ;;
            *) case "${TERM:-}" in linux|vt100|vt102|ansi|cons25|sun) _XHY_POSIX_LANG=en ;; esac ;;
        esac
        _cm="$(locale charmap 2>/dev/null || true)"
        case "$_cm" in
            ""|*UTF-8*|*utf8*|*utf-8*|*UTF8*) ;;
            *) _XHY_POSIX_LANG=en ;;
        esac
        ;;
esac
_xhy_say2() { if [ "$_XHY_POSIX_LANG" = en ]; then _xhy_say "$2"; else _xhy_say "$1"; fi; }
_xhy_err2()  { if [ "$_XHY_POSIX_LANG" = en ]; then _xhy_err "$2"; else _xhy_err "$1"; fi; }
_xhy_die2()  { if [ "$_XHY_POSIX_LANG" = en ]; then _xhy_die "$2"; else _xhy_die "$1"; fi; }
# 不在这里打通用 banner：xhy version / --help / 脚本化调用也会经过这一段，
# 多一行输出会污染机器可读结果。ASCII 提示由 bash 段的 xhy_lang_banner()
# 在菜单与安装流程里打印（VNC 用户真正会看的地方）。

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
        _xhy_say2 "[*] 未检测到 bash，先安装（最多等 180 秒）..." "[*] bash not found, installing (up to 180s)..."
        if command -v apk >/dev/null 2>&1; then
            _xhy_run_lim 180 apk add --no-cache bash || {
                _xhy_err2 "[x] apk add bash 失败或超时。按顺序排查：" "[x] apk add bash failed or timed out. Check in order:"
                _xhy_err2 "    1) 软件源/DNS 不通：apk update; cat /etc/resolv.conf" "    1) mirror/DNS unreachable: apk update; cat /etc/resolv.conf"
                _xhy_err2 "    2) 另一个 apk 进程占锁（云厂商初始化脚本常见）：ps w | grep apk" "    2) another apk holds the lock (common with cloud-init): ps w | grep apk"
                _xhy_err2 "    3) 换源：sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories" "    3) switch mirror: sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories"
                _xhy_err2 "    4) 手动装齐依赖后重跑：apk add bash curl ca-certificates openssl coreutils" "    4) install deps manually then retry: apk add bash curl ca-certificates openssl coreutils"
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
        _xhy_err2 "[x] xray-hy 需要 bash，但系统没有包管理器或安装失败。" "[x] xray-hy needs bash; no package manager found or install failed."
        _xhy_err  "    Alpine: apk add bash    Debian/Ubuntu: apt-get install -y bash"
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
    _xhy_say2 "[*] stdin 被管道占用，重新取一份脚本到 $_xhy_tmp ..." "[*] stdin is a pipe, fetching a copy to $_xhy_tmp ..."
    _xhy_dl "$XHY_INSTALL_URL" "$_xhy_tmp" \
        || _xhy_die2 "下载失败：$XHY_INSTALL_URL
    先装 curl（apk add curl / apt-get install -y curl），
    或本地下载后执行 sh install.sh" "Download failed: $XHY_INSTALL_URL
    Install curl first (apk add curl / apt-get install -y curl),
    or download locally and run: sh install.sh"
    [ -s "$_xhy_tmp" ] || _xhy_die2 "下载到的文件是空的：$XHY_INSTALL_URL" "Downloaded file is empty: $XHY_INSTALL_URL"

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

XHY_VERSION="1.9.3"
XHY_BUILD="fbc5fec19a4f"

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

XHY_VERSION="${XHY_VERSION:-1.9.3}"
# 单文件发布时由 build.sh 写入真实构建号；仓库内运行就是 dev。
XHY_BUILD="${XHY_BUILD:-dev}"

# 单文件发布后，"脚本目录"只有两种含义：
#   已安装 -> 单文件本体直装到 /usr/local/bin/xhy（不再嵌套 /usr/local/lib/xray-hy + 软链）
#   仓库内 -> 仓库根（xhy 是开发入口，直接 source lib/）
# 数据目录（内嵌 conf/targets.tsv 落盘、tunnel-run 辅助脚本）仍在 /usr/local/lib/xray-hy，
# 与脚本本体解耦：用户敲的命令路径变浅，但数据落盘位置不变。
# 测试会显式给出 XHY_SCRIPT_DIR，因此这里全部用「已存在就不覆盖」的写法。
XHY_SCRIPT_DIR="${XHY_SCRIPT_DIR:-${XHY_APP_DIR:-/usr/local/lib/xray-hy}}"
XHY_APP_DIR="${XHY_APP_DIR:-$XHY_SCRIPT_DIR}"
XHY_SELF="${XHY_SELF:-/usr/local/bin/xhy}"
XHY_HOME="${XHY_HOME:-$XHY_APP_DIR}"
# 单文件发布物地址。prelude（单文件本体内）会给出同名变量；库层也留默认值，
# 这样 test/ 与仓库入口直接 source lib/ 时不会在 set -u 下炸掉。
XHY_INSTALL_URL="${XHY_INSTALL_URL:-https://github.com/jmwangde3/xray-hy/releases/latest/download/install.sh}"

# 命令入口自愈：旧版本把 /usr/local/bin/xhy 留成软链（指向已失效的本体或旧仓库）。
# 直装成文件前必须先摘掉软链，否则 install -m / mv 会顺着软链写进旧本体。
reconcile_bin() {
    local bindir="${XHY_BINDIR:-/usr/local/bin}"
    local target="$bindir/xhy"
    if [[ -L "$target" ]]; then
        local cur; cur="$(readlink "$target" 2>/dev/null || true)"
        info "命令入口是旧软链（$target -> $cur），改为直接安装单文件"
        rm -f "$target" || true
    fi
}

# 迁移清理：单文件改用 /usr/local/bin/xhy 后，旧位置 /usr/local/lib/xray-hy/xhy
# 成为孤儿。只删这份遗留脚本本体（数据目录里的 conf/、tunnel-run 不动）。
_cleanup_legacy_self() {
    local legacy="${XHY_LEGACY_SELF:-/usr/local/lib/xray-hy/xhy}"
    local self; self="$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")"
    [[ "$legacy" == "$self" ]] && return 0
    [[ -e "$legacy" ]] || return 0
    [[ "$(head -c 256 "$legacy" 2>/dev/null || true)" == *"xray-hy"* ]] || return 0
    rm -f "$legacy" || true
}
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
# read -p 的提示不走 printf 过滤器，必须在这里显式过一遍 xhy_t，否则英文模式下
# 所有交互提问依旧是中文方块。返回值用 builtin printf 输出，避免被过滤器碰。
ask() {
    local prompt="$1" default="${2:-}" reply="" p
    if [[ -n "$default" ]]; then
        p="$prompt [$default]: "
    else
        p="$prompt: "
    fi
    if declare -F xhy_t >/dev/null 2>&1; then p="$(xhy_t "$p")"; fi
    read -r -t 60 -p "$p" reply || reply=""
    builtin printf '%s' "${reply:-$default}"
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

# 根分区剩余 MB。df -Pm 是 POSIX 格式，BusyBox 也支持；-m 直接给 MB，
# 免得自己拿 1K 块换算。取不到时返回 0（调用方按"没空间"处理更安全）。
# 11-07 事故当晚手工装的清理钩子。路径做成变量，测试才能指到临时目录。
legacy_prune_hook() {
    printf '%s/xhy-backup-prune' "${XHY_PERIODIC_DIR:-/etc/periodic/daily}"
}

disk_free_mb() {
    local p="${1:-$XHY_ETC}" v
    v="$(df -Pm "$p" 2>/dev/null | awk 'NR==2 {print $4; exit}')"
    # 路径不存在 / df 不支持 -m 时都会得到空串；调用方按 0 处理更安全。
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

# 单个文件/目录占用的 KB（du -k 是 POSIX，BusyBox 支持）。取不到给 0。
# 为什么不拿 `df` 前后相减算释放量：df 的粒度是 1 MB，删一堆零字节残留文件
# 会显示「释放 0 MB」，看起来像没删掉 —— 这正是 v1.6.2 要修掉的误导。
file_kb() {
    local k
    k="$(du -k "$1" 2>/dev/null | awk 'NR==1 {print $1+0; exit}')"
    [[ "$k" =~ ^[0-9]+$ ]] || k=0
    printf '%s' "$k"
}

# KB → 人读字符串（小于 1024 给 KB，否则 MB 带一位小数）。纯 shell，不依赖 bc。
human_kb() {
    local k="${1:-0}"
    [[ "$k" =~ ^[0-9]+$ ]] || k=0
    if (( k >= 1024 )); then
        printf '%d.%d MB' $(( k / 1024 )) $(( (k % 1024) * 10 / 1024 ))
    else
        printf '%d KB' "$k"
    fi
}

# 写盘前的空间闸门。need_mb = 这次操作还要占多少，不是「剩多少才好」。
# 与 v1.6.1 的 `if free < 120 then 跳过备份 else 备份` 是完全不同的语义：
# 那种写法在余量为 0 时是「跳过保险，继续写」—— 47.88.102.45 上就是这么把
# /usr/local/bin/xray 写成 11 MB 半截文件的。这里不足就直接返回非零。
disk_need() {
    local need="${1:-0}" what="${2:-当前操作}" have
    have="$(disk_free_mb "$XHY_ETC")"
    (( have >= need )) && return 0
    err "根分区余量 ${have} MB，${what} 至少需要 ${need} MB"
    err "先清理：xhy clean all     然后 df -h / 确认余量"
    return 1
}

# 可重新下载 / 可再生的文件不进备份目录：xray 36 MB + geoip 19 MB + geosite 10 MB
# ≈ 65 MB，在 427 MB 根分区上备份几次就是灾难，而它们一条命令就能重新拉回来。
backup_is_redownloadable() {
    case "$(basename "$1")" in
        xray|xray.new|geoip.dat|geosite.dat|geoip.dat.new|geosite.dat.new) return 0 ;;
        *) return 1 ;;
    esac
}

# 只备份配置类文件。可重下的大件直接跳过并说明省了多少 —— 备份目录的职责是
# 「丢了要重新想一遍」的东西（config.json / nodes / certs / state.env），不是镜像站。
backup_file() {
    local f="$1" base keep="${XHY_BACKUP_KEEP:-2}" n=0
    [[ -f "$f" ]] || return 0
    if backup_is_redownloadable "$f"; then
        info "不备份 $(basename "$f")（可重新下载，省 $(human_kb "$(file_kb "$f")")）"
        return 0
    fi
    mkdir -p "$XHY_BACKUP"
    base="$(basename "$f")"
    cp -a "$f" "$XHY_BACKUP/$base.$(date +%Y%m%d%H%M%S).bak"
    # 写完就裁：同名只留最新 N 份。备份该在写入时收敛，而不是等 xhy clean 收拾。
    while IFS= read -r old; do
        n=$(( n + 1 ))
        (( n > keep )) && rm -f "$old"
    done < <(ls -1t "$XHY_BACKUP/$base."*.bak 2>/dev/null || true)
    return 0
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

# ===================== lib/i18n.sh =====================
# xray-hy / 输出语言层。
#
# 为什么需要它：阿里云 / 腾讯云的网页 VNC 控制台只有一套 ASCII 字体，UTF-8
# 中文能正确解码但没有字形，全部显示成「小方块」。脚本本身改不了终端字体，
# 只能保证在这种环境下输出的每一个字节都是可打印 ASCII。
#
#   XHY_LANG=en / XHY_ASCII=1   强制英文（纯 ASCII，VNC 可用）
#   XHY_LANG=zh                 强制中文
#   xhy lang en|zh|auto         写进 state.env，之后每次运行沿用
#   auto（默认）                按 LANG/TERM/charmap 判定：控制台终端、C locale、
#                              非 UTF-8 一律切英文；普通 UTF-8 SSH 终端保持中文
#
# 实现方式：默认（中文）模式下 xhy_t 是恒等变换，离线测试与原有输出逐字节一致；
# 只有英文模式才启用 printf 过滤器。这样不用改散落在十几个 lib 里的几百条
# 中文文案，也不会把配置 / JSON / 分享链接这类纯 ASCII 数据碰坏。

# 中文 -> 英文短语表。必须按「长词在前」排，否则「不支持」会被「支持」先拆开。
# 不带 declare：本文件是在 load_libs() 函数内被 source 的，显式 declare 会创建
# 局部变量，函数返回后数组就丢了（同一个坑 scanner.sh 的 XHY_TFO_CACHE 踩过）。
XHY_T_ZH=(
    "菜单 1 / 2 的地域名单也可选择「只要 TFO」：逐站实测，不支持的不兜底；"
    "该选择会保存，之后新建节点继续沿用。大网站不等于支持 TFO，以实测为准。"
    "地域名单里没有通过校验且支持被动 TFO 的站点。"
    "TFO 筛选 : 仅支持被动 TFO"
    "TFO 筛选 : 不强制（按质量选）"
    "TFO 不支持（跳过）"
    "本机不具备被动 TFO 探测能力："
    "此时 --require-tfo 的结果必然是空，不代表网段里没有支持 TFO 的站点。"
    "改为按质量选站（不强制 TFO）？"
    "已按你的要求中止。修好上面那条再跑，或去掉 --require-tfo。"
    "TFO 探测  : 可用（curl --tcp-fastopen + nstat + 客户端位已开）"
    "TFO 探测  : 不可用（%s）—— --require-tfo 会恒为空"
    "nstat 缺失且 /proc/net/netstat 不可读（apk add iproute2）"
    "net.ipv4.tcp_fastopen=%s，客户端位没开（需 1 或 3）"
    "curl 缺失"
    "扫描范围默认是本机公网 IP 所在 /24；无合格站点、或强制 TFO 时没找到支持 TFO 的站，会自动扩到 /21 再扫一次" "根分区余量不足 200 MB：盘满会让 sshd 写不了会话文件、SSH 直接连不上。先跑 xhy clean" "当前网段内没有支持被动 TFO 的候选（每个站点后已标注 TFO 结果）；将自动扩大到 /21 再扫一次"
    "安装完成。现在可用 xhy add reality 添加第一个节点，或直接输入 xhy 打开菜单。" "  xhy lang en    强制英文（纯 ASCII；云 VNC 控制台中文是小方块时用）" "已按新的端口 / SNI 重签 Hysteria2 证书，客户端的 pinSHA256 需要更新"
    "节点参数已写入但未生效，可用 xhy snapshots + xhy rollback 回退" "TFO 只省首连 1 个 RTT，伪装站又不承载正常代理流量，不值得为它牺牲站点质量。" "  单次强制：XHY_LANG=en xhy  或  XHY_ASCII=1 xhy"
    "当前没有 REALITY 节点，新伪装站已记为默认 target，下次新建节点会用" "现在用 xhy add reality 添加第一个节点，或输入 xhy 打开菜单" "缓存里没有支持被动 TFO 的站点；自动扩大网段再扫一次（不重复扫同一 /24）"
    "  xhy lang auto  按终端 / locale 自动判定（默认）" "TFO auto/on/off（auto = 按新 target 重新探测）" "  10) 防火墙                11) BBR / 内核"
    "  12) 服务管理              13) Xray 版本通道" "1) 自动扫描本机机房网段，选最优站点（推荐；有缓存直接复用，不重复扫）" "磁盘余量不足 120 MB，跳过自动回滚副本（换版失败需手动重装旧版本）"
    "backup / restore / clean（清理旧备份释放磁盘）" "（safe 模式：SSH 防爆破 + 放行节点端口，不改动现有规则）" "   3) 节点列表               4) 导出分享链接"
    "本机网段（/24 与同机房 /21）都没有支持被动 TFO 的站点。" "自动扫描没有找到可用站点，可改用 1) 按地区，或 3) 手动指定" "TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连）"
    "   1) 添加节点               2) 编辑节点" "  14) 更新                  15) 卸载" "  7) 扫描本机机房网段挑站（可强制 TFO，可替换已有节点）"
    "是否只选支持 TFO 的伪装站？(y/N，回车=不强制): " "；scanner_pick 会自动扩大到 /21 再扫一次。" "   6) 完整安装 / 重装        7) 环境自检"
    "非交互环境：安装完成，下次直接运行 xhy 即可打开菜单。" "候选伪装站（按质量排序；TFO=目标是否支持被动 TFO）" "选哪个 \[1-%d\]（回车=1，0=自动取最高分）: "
    "只支持 backup / restore / clean" "尚未安装 Xray，请先运行: xhy install" "（未强制 TFO；列表里也可能含支持 TFO 的站点）"
    "   8) 配置（路由/DNS/日志）  9) 伪装站" "shortId（输入 new 重新生成，客户端需同步）" "编辑已有节点；省略参数时列出编号选择（回车=不改）"
    "伪装站 target（IP:端口 或 域名:端口）" "清理旧的核心二进制备份 / 旧快照（小硬盘必用）" "根分区满时 sshd 会连不上、而代理仍在工作；"
    "每个候选后面都标注「TFO 支持 / 不支持」" "选择地区编号（也可直接输入地区代码，回车取消）" "替换哪些（all / 1,3 / 回车=不换）"
    "磁盘余量不足 120 MB，跳过旧二进制备份（" "（这一步最慢；卡住多半是软件源，见文末提示）" "（下次运行生效；本次可用 XHY_LANG="
    "2) 内置地区库（按 VPS 出口国家匹配）" "SNI（target 是 IP 时必填域名）" "去掉 --require-tfo 按质量选"
    "伪装站（target / dest）来源：" "  xhy lang zh    强制中文" "里没有支持被动 TFO 的站点，自动扩大到"
    "  2) 指定地区（列出现有地区与候选数）" "Brutal 上行 Mbps（空=不启用）" "Brutal 下行 Mbps（空=不启用）"
    "只有 REALITY 节点有伪装站（当前 " "伪装站（target / dest）来源" "3) 手动指定 target / SNI"
    "xhy check 里有「磁盘余量」一行" "内置地区库（按 VPS 出口国家匹配）" "  已存在的 REALITY 节点："
    "UUID（输入 new 重新生成）" "伪装模式 string/proxy" "自动扫描本机机房网段，选最优站点"
    "脚本本体已就位（本次启动已落地）" "（已按「必须支持 TFO」过滤）" "改为不强制 TFO、按质量重选？"
    "已完成 %s 个节点的伪装站替换" "客户端连接地址(域名或 IP)" "（回车=1，0=自动取最高分）"
    "前 个候选都不支持被动 TFO" "SNI（改这个会重签自签证书）" "或换 --cidr 网段再试"
    "可改用 xhy target" "最优伪装站: target=" "固定下来（新建节点直接用）？"
    "没有匹配的编号，未做任何替换" "配置（路由/DNS/日志）" "  16) 备份 / 恢复"
    "保持原 target 不变" "建议套 CDN / 反代" "---- 节点 ----"
    "---- 系统 ----" "---- 维护 ----" "上面每个站点后已标注结果"
    "选择类型 \[3\]: " "直接回车 = 保持原值。" "连接地址（域名或 IP）"
    "扫描范围默认是本机公网" "扫描完成但没有可用站点" "非 CDN（源站直连）"
    "安装脚本本体与命令入口" "路径 (回车随机生成)" "缓存里的候选都已失效"
    "内核网络优化与防火墙" "选择 \[0\]: " "选择 \[1\]: "
    "   5) 删除节点" "当前 target:" "没有新的伪装站可应用"
    "不需要公网入站端口" "完整安装 / 重装" "Xray 版本通道"
    "尚未安装 Xray" "安装服务与开机自启" "渲染配置并启动服务"
    "每个候选后面都标注" "清理前：根分区剩余" "清理后：根分区剩余"
    "BBR / 内核" "支持被动 TFO" "无结果会自动扩到"
    "   0) 退出" "指纹 / TFO" "删除旧二进制备份"
    "删除旧 .bak" "备份 / 恢复" "客户端连接地址"
    "依赖检查与安装" "当前语言 : " "TFO 不支持"
    "结果已缓存: " "个可用候选（共" "磁盘余量 : "
    "（根分区剩余）" "删除旧状态快照" "导出分享链接"
    "内核网络优化" "自动扫描失败" "创建数据目录"
    "已设置语言为" "TFO 支持" "使用扫描缓存"
    "扫描伪装站" "结果已缓存" "最优伪装站"
    "直接建节点" "候选伪装站" "按质量排序"
    "个去重候选" "下载并校验" "安装最新版"
    "配置防火墙" "不写入缓存" "不参与打分"
    "节点类型：" "立即切换）" "验证完成："
    "地区已设为" "将要修改：" "确认应用？"
    "服务管理" "添加节点" "节点列表"
    "删除节点" "环境自检" "版本通道"
    "重新扫描" "完整安装" "手动指定"
    "自动扫描" "随机生成" "监听端口"
    "节点类型" "选择类型" "必须支持"
    "现场探测" "再扫一次" "本网段前"
    "没有改动" "防火墙" "伪装站"
    "不支持" "已清除" "已过期"
    "已失效" "已跳过" "未启用"
    "未安装" "已安装" "签发者"
    "小时前" "个候选" "不合法"
    "未强制" "列表里" "个站点"
    "硬过滤" "同机房" "小方块"
    "控制台" "选择 " "选哪个"
    "支持" "握手" "分数"
    "缓存" "候选" "扫描"
    "校验" "复核" "查看"
    "清除" "列出" "刷新"
    "扩容" "扩大" "节点"
    "端口" "地址" "域名"
    "证书" "流量" "探测"
    "最优" "质量" "结果"
    "来源" "添加" "删除"
    "导出" "列表" "配置"
    "路由" "日志" "系统"
    "维护" "更新" "卸载"
    "备份" "恢复" "重装"
    "自检" "服务" "管理"
    "环境" "内核" "权限"
    "脚本" "入口" "启用"
    "开启" "关闭" "使用"
    "当前" "选择" "返回"
    "继续" "确认" "确定"
    "取消" "输入" "示例"
    "格式" "说明" "提示"
    "警告" "错误" "失败"
    "成功" "完成" "安装"
    "下载" "检查" "启动"
    "停止" "重启" "状态"
    "默认" "有效" "保留"
    "剔除" "需要" "运行"
    "命令" "参数" "文件"
    "目录" "版本" "缺少"
    "无法" "必须" "可选"
    "回车" "路径" "退出"
    "只选" "中文" "英文"
    "终端"
)

XHY_T_EN=(
    "Region menus 1 / 2 can also require TFO: probe each site and never fall back to one without it;"
    "The choice is saved for future nodes. Big-name sites do not necessarily support TFO; live probing decides."
    "No candidate in the region list both passed validation and supports passive TFO."
    "TFO filter : passive TFO required"
    "TFO filter : not required (pick by quality)"
    "TFO: no (skipped)"
    "Local TFO probing unavailable: "
    "so --require-tfo would always come back empty; that does NOT mean this subnet has no TFO-capable site."
    "Pick by quality instead (do not require TFO)?"
    "Aborted as requested. Fix the line above, or drop --require-tfo."
    "TFO probe : ready (curl --tcp-fastopen + nstat + client bit on)"
    "TFO probe : NOT ready (%s) -- --require-tfo would always be empty"
    "nstat missing and /proc/net/netstat unreadable (apk add iproute2)"
    "net.ipv4.tcp_fastopen=%s has the client bit off (needs 1 or 3)"
    "curl missing"
    "Default scan range is this host's /24; with no usable site (or no TFO-capable site when required) it auto-widens to /21 and rescans" "Root filesystem has <200 MB free. A full disk makes sshd unable to write session files, so SSH stops responding while the proxy keeps running. Run xhy clean first" "No TFO-capable candidate in this subnet (each site above is labelled); auto-widening to /21 and rescanning"
    "Install complete. Run xhy add reality to add the first node, or just xhy for the menu." "  xhy lang en    force English (pure ASCII; use when a cloud VNC shows boxes)" "Hysteria2 cert re-issued for the new port/SNI; update pinSHA256 on clients"
    "Node updated but not active; use xhy snapshots + xhy rollback to revert" "TFO only saves 1 RTT on the first connect and the target carries no proxy traffic; not worth trading site quality for." "  one-shot: XHY_LANG=en xhy   or  XHY_ASCII=1 xhy"
    "No REALITY node yet; the new site is saved as the default target for the next node" "Now run xhy add reality to add the first node, or just xhy for the menu" "No TFO-capable site in cache; auto-widening the subnet to rescan (not the same /24)"
    "  xhy lang auto  detect from terminal / locale (default)" "TFO auto/on/off (auto = re-probe the new target)" "  10) Firewall              11) BBR / kernel"
    "  12) Service               13) Xray channel" "1) Auto-scan this datacenter subnet and pick the best site (recommended; cache reused, no rescan)" "Disk free <120 MB, skipping the rollback copy (a failed switch needs a manual reinstall)"
    "backup / restore / clean (free disk space)" " (safe mode: SSH brute-force guard + allow node ports, no changes to existing rules)" "   3) List nodes             4) Export links"
    "No passive-TFO site in this subnet (/24) or the same rack (/21)." "Scan found no usable site; use 1) by region or 3) specify manually" "TLS 1.3 / H2 / no redirect / not CDN (origin direct)"
    "   1) Add node               2) Edit node" "  14) Update                15) Uninstall" "  7) Scan this rack's subnet (optional TFO, optional node retarget)"
    "Only TFO-capable sites? (y/N, Enter = no): " "; scanner_pick auto-widens to /21 and rescans." "   6) Full install           7) Self check"
    "Non-interactive shell: install complete, run xhy later to open the menu." "Candidate sites (by quality; TFO = target supports passive TFO)" "Pick [1-%d] (Enter=1, 0=best score): "
    "Only backup / restore / clean" "Xray is not installed, run: xhy install" " (TFO not required; the list may still contain TFO sites)"
    "   8) Config (routing/DNS)   9) Camouflage site" "shortId (type new to regenerate; clients must update)" "Edit a node; no args = pick by number (Enter = keep)"
    "Target site (IP:port or domain:port)" "Drop old core backups / snapshots (needed on small disks)" "A full root fs makes sshd unreachable while the proxy keeps working; "
    "each candidate is labelled TFO: yes / no" "Region number (or code, Enter = cancel)" "Replace which (all / 1,3 / Enter = none)"
    "Disk free <120 MB, skipping the core backup (" " (this is the slowest step; stalls are usually the package mirror)" " (effective next run; use XHY_LANG="
    "2) Built-in region library (match VPS egress country)" "SNI (required when target is an IP)" "drop --require-tfo to pick by quality"
    "Camouflage site (target / dest) source:" "  xhy lang zh    force Chinese" " has no TFO-capable site, auto-widening to "
    "  2) Pick a region (shows regions and candidate counts)" "Brutal up Mbps (empty = off)" "Brutal down Mbps (empty = off)"
    "Only REALITY nodes have a target site (current " "Camouflage site (target / dest) source" "3) Specify target / SNI manually"
    "xhy check shows the free-space line" "Built-in region library (match VPS egress country)" "  Existing REALITY nodes:"
    "UUID (type new to regenerate)" "Masquerade mode string/proxy" "Auto-scan this datacenter subnet and pick the best site"
    "Script and command entry already installed (this run)" " (filtered: TFO required)" "Retry without requiring TFO (pick by quality)? "
    "%s node(s) retargeted" "Client address (domain or IP)" "(Enter=1, 0=best score)"
    "no TFO-capable candidates" "SNI (changing it re-issues the self-signed cert)" "or try another --cidr subnet"
    "fall back to xhy target" "Best camouflage site: target=" "Pin it (new nodes use it)? "
    "No matching number; nothing replaced" "Config (routing/DNS/log)" "  16) Backup / restore"
    "Keeping the current target" "put it behind a CDN / reverse proxy" "---- Nodes ----"
    "---- System ----" "---- Maintenance ----" "each site above is labelled"
    "Select type [3]: " "Press Enter to keep the current value." "Client address (domain or IP)"
    "Default scan range is the public" "Scan finished but no usable site" "not CDN (origin direct)"
    "Install script and command entry" "Path (Enter = random)" "all cached candidates are stale"
    "Kernel network tuning and firewall" "Select [0]: " "Select [1]: "
    "   5) Delete node" "Current target: " "No new camouflage site to apply"
    "no public inbound port needed" "Full install / reinstall" "Xray version channel"
    "Xray is not installed" "Install service and enable at boot" "Render config and start service"
    "each candidate is labelled with" "Before: root filesystem free" "After: root filesystem free"
    "BBR / kernel" "supports passive TFO" "auto-widens to"
    "   0) Exit" "Fingerprint / TFO" "Removed old core backups: "
    "Removed old .bak files: " "Backup / restore" "Client address"
    "Dependency check and install" "Language : " "TFO: no"
    "Results cached: " " usable candidates (of " "Disk free : "
    " (root filesystem)" "Removed old snapshots: " "Export share links"
    "kernel network tuning" "Auto-scan failed" "Create data directories"
    "Language set to" "TFO: yes" "Using scan cache"
    "Scan camouflage sites" "Results cached" "Best camouflage site"
    "Create a node now" "Candidate sites" "sorted by quality"
    "unique candidates" "Download and verify" "Install latest"
    "Configure firewall" "not written to cache" "not part of the score"
    "Node type:" " for this run)" "Verified: "
    "Region set to" "Changes to apply:" "Apply these changes? "
    "Service control" "Add node" "List nodes"
    "Delete node" "Environment check" "version channel"
    "Rescanning" "full install" "specify manually"
    "auto scan" "random" "Listen port"
    "Node type" "Select type" "must support"
    "live probe" " and rescanning" "Among the first "
    "No changes" "Firewall" "camouflage site"
    "does not support" "cleared" "expired"
    "stale" "skipped" "not enabled"
    "not installed" "installed" "Issuer"
    "hours ago" "candidates" "invalid"
    "not required" "the list" "sites"
    "hard filter" "same rack" "boxes"
    "console" "Select " "Pick"
    "supports" "Handshake" "Score"
    "cache" "candidate" "scan"
    "validate" "reverify" "show"
    "clear" "list" "refresh"
    "widen" "widen" "node"
    "port" "address" "domain"
    "certificate" "traffic" "probe"
    "best" "quality" "result"
    "source" "add" "delete"
    "export" "list" "config"
    "routing" "log" "system"
    "maintenance" "update" "uninstall"
    "backup" "restore" "reinstall"
    "check" "service" "manage"
    "environment" "kernel" "privileges"
    "script" "entry" "enable"
    "on" "off" "use"
    "current" "select" "back"
    "continue" "confirm" "confirm"
    "cancel" "input" "example"
    "format" "notes" "hint"
    "warning" "error" "failed"
    "success" "done" "install"
    "download" "check" "start"
    "stop" "restart" "status"
    "default" "valid" "keep"
    "drop" "needs" "run"
    "command" "option" "file"
    "directory" "version" "missing"
    "unable" "must" "optional"
    "Enter" "Path" "Exit"
    "only" "Chinese" "English"
    "terminal"
)


# 纯 ASCII 快速路径：配置 / JSON / 分享链接 / 表头里的英文都不会被翻译或改写。
# 在 C locale 下 ${#s} 按字节计数，逐字节看有没有 >0x7f 的，比正则可靠。
xhy_is_ascii() {
    local LC_ALL=C s="$1" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if [[ "$c" > $'\x7f' ]]; then return 1; fi
    done
    return 0
}

# 一行的翻译：先按短语表替换，再把残留的非 ASCII 字节换成空格。
# 最后这一步是硬保证：即便将来新增了没进词表的中文，VNC 上也只会看到 ASCII。
# 用 tr -c（替换成空格）而不是 tr -cd（直接删除）：中文是多字节，直接删会让
# 前后两个英文词粘成一个（"scan完成support" -> "scandonesupport"），换空格
# 后至少还能读。保留 tab/LF/CR/ESC（ANSI 颜色）与 0x20-0x7e 可打印字符。
xhy_t_line() {
    local s="$1" i
    for (( i = 0; i < ${#XHY_T_ZH[@]}; i++ )); do
        s="${s//${XHY_T_ZH[$i]}/${XHY_T_EN[$i]}}"
    done
    builtin printf '%s' "$(builtin printf '%s' "$s" | LC_ALL=C tr -c '\11\12\15\33\40-\176' ' ')"
}

# xhy_t <字符串>  或  xhy_t <<'EOF' ... EOF（整段展示文本）
# 中文模式恒等；英文模式只处理含中文的那部分输出。stdin 模式逐行处理，
# 保留 heredoc 的行结构与末尾不换行的内容。
xhy_t() {
    local s line
    if (( $# > 0 )); then
        s="$1"
        if [[ "${XHY_LANG_EFFECTIVE:-zh}" != "en" ]] || xhy_is_ascii "$s"; then
            builtin printf '%s' "$s"
        else
            xhy_t_line "$s"
        fi
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "${XHY_LANG_EFFECTIVE:-zh}" != "en" ]] || xhy_is_ascii "$line"; then
            builtin printf '%s\n' "$line"
        else
            xhy_t_line "$line"; builtin printf '\n'
        fi
    done
    return 0
}

# 英文模式下的 printf 过滤器：不改任何调用点，把所有 printf 出来的用户可见
# 文本统一过一遍 xhy_t。printf -v 与纯 ASCII 数据原样透传。
# 注意：这里必须用 builtin printf，否则会递归回自己。
xhy_install_output_filters() {
    [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]] || return 0
    printf() {
        if (( $# == 0 )); then return 0; fi
        if [[ "${1:-}" == "-v" ]]; then builtin printf "$@"; return $?; fi
        local -a a=()
        local x
        for x in "$@"; do a+=("$(xhy_t "$x")"); done
        builtin printf "${a[@]}"
    }
    return 0
}

# 判定语言。优先级：XHY_ASCII=1 / XHY_LANG 环境变量 > state.env > 环境探测。
xhy_lang_init() {
    local want="${XHY_LANG:-}" st="" cm="" lang_all="" is_zh=0 no_utf8=0 console=0
    [[ "${XHY_ASCII:-0}" == "1" ]] && want="en"
    if [[ -z "$want" || "${want,,}" == "auto" ]]; then
        st="$(state_get XHY_LANG '' 2>/dev/null || true)"
        if [[ -n "$st" && "${st,,}" != "auto" ]]; then want="$st"; fi
    fi
    case "${want,,}" in
        en|english|ascii) XHY_LANG_EFFECTIVE="en" ;;
        zh|cn|chinese|zh_cn|zh_tw) XHY_LANG_EFFECTIVE="zh" ;;
        *)
            # 空 locale ≠ 非 UTF-8。Alpine / 精简容器默认根本没有 LANG，终端照样
            # 是 UTF-8、中文照样能显示；早期把空值当 no_utf8，导致普通 ssh 会话
            # 一律被判成英文。只有「明确设了、且不是 UTF-8」才算。
            lang_all="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
            case "${lang_all,,}" in zh*|*zh_cn*|*zh_tw*) is_zh=1 ;; esac
            if [[ -n "$lang_all" || -n "${LC_ALL:-}" || -n "${LC_CTYPE:-}" ]]; then
                case "$lang_all" in C|POSIX|c|posix) no_utf8=1 ;; esac
                case "${lang_all,,}" in *utf-8*|*utf8*) ;; *) no_utf8=1 ;; esac
                cm="$(locale charmap 2>/dev/null || true)"
                if [[ -n "$cm" ]]; then
                    case "${cm,,}" in *utf-8*|*utf8*) ;; *) no_utf8=1 ;; esac
                fi
            fi
            # 云 VNC / 串口控制台的 TERM：没有中文字形。
            # 不含 dumb：非交互 ssh / CI / agent 管道常见 TERM=dumb，那不是
            # 控制台，输出中文给日志和管道读完全没问题，不该切成英文。
            # 中文 locale 明确出现时尊重用户（他自己配了字形）。
            case "${TERM:-}" in linux|vt100|vt102|ansi|cons25|sun) console=1 ;; esac
            if (( no_utf8 == 1 )); then
                # 脚本输出是 UTF-8、终端却不是：中文只会更乱，直接英文。
                XHY_LANG_EFFECTIVE="en"
            elif (( is_zh == 1 )); then
                # 管理员显式配了中文 locale，尊重他（他自己装了字形）。
                XHY_LANG_EFFECTIVE="zh"
            elif (( console == 1 )); then
                XHY_LANG_EFFECTIVE="en"
            else
                XHY_LANG_EFFECTIVE="zh"
            fi
            ;;
    esac
    export XHY_LANG_EFFECTIVE
    # 颜色转义里的 ESC 会被兜底 tr 保留，但控制台上没必要冒这个险，直接关掉。
    if [[ "$XHY_LANG_EFFECTIVE" == "en" ]]; then
        C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
    fi
    return 0
}

# 一行永远可读的 ASCII 提示：不管判定成哪种语言，VNC 用户都能看到怎么切英文。
xhy_lang_banner() {
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        builtin printf '[*] xray-hy %s | English (ASCII) output. Switch back: xhy lang zh\n' "$XHY_VERSION"
    else
        builtin printf '[*] xray-hy %s | Chinese UI | boxes on VNC? re-run with XHY_LANG=en or: xhy lang en\n' "$XHY_VERSION"
    fi
    return 0
}

# ===================== lib/sockopt.sh =====================
# xray-hy / per-inbound sockopt + TFO 决策。
#
# ============================================================================
# 口径：**字段被接受 ≠ 运行时生效**（2026-11-07 定）
# ============================================================================
#
# Xray 26.3.27（XHY_PINNED_VERSION）与 26.10.31 都接受七字段完整写法
# （tcpFastOpen / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout /
#  tcpcongestion / tcpMptcp / tcpFastOpenQueueLength），`xray run -test`
# 输出 Configuration OK、EXIT=0、无 unknown field。任何「Xray 不支持某字段」
# 的说法都不成立。要判断的是运行时：setsockopt 失败时 Xray 静默忽略。
#
# ---- 一、TFO：默认跟随伪装站，用户可显式覆盖（v1.4.3 起）----
#
# 先纠正早期误判：**Xray 的 tcpFastOpen 是生效的**。2026-11-07 在
# 47.88.102.45 / 26.10.31 / 内核 tcp_fastopen=3 上实测：
#
#   入站 true + 客户端带有效 cookie 的 SYN（1542 B early data）
#     → SYN-ACK 的 ack 跳过 1542 字节、TcpExtTCPFastOpenPassive 每次 +1、
#       curl http=200（REALITY 转发正常，early data 没破坏功能）
#   入站 true + 首次 cookiereq（换新目标 IP 绕开内核 cookie 缓存）
#     → SYN-ACK 回 `tfo cookie 88c5d6bf…`（option 34）、CookieReqd +1
#   入站 false
#     → Passive 不变、SYN-ACK 的 ack 只 +1（early data 被丢）
#   tcpFastOpenQueueLength 写不写都不影响上述结果
#
# 早期判「不生效」用的是「客户端只发 cookiereq 时 SYN-ACK 无 option 34」——
# 那条路径下服务端本来就不该回 34，判据不成立。要看 ack 是否跳过 early data、
# Passive / CookieReqd 计数、以及 cookiereq 路径回不回 cookie。
#
# 既然它真的生效，就不能一刀切关掉或无条件打开，而要**跟伪装站保持一致**：
#
#   真实伪装站支持被动 TFO  → 我们开，探测者看到的 SYN-ACK 一致，且白拿 1 RTT
#   真实伪装站不支持         → 我们关，否则同样是探测者一个 SYN 就能区分开
#
# 现网 www.easeus.com 源站 47.88.102.65:443 不支持（带 cookiereq 的 SYN 打过去，
# SYN-ACK 只有 mss/sackOK/TS/nop/wscale，无 option 34），所以 auto 判定为关，
# 现网行为与 v1.4.2 一致。客户端默认配合：我们开它开、我们关它关。
#
# 探测方法：`curl --tcp-fastopen` 连打 3 次，看内核
# `TcpExtTCPFastOpenActive` 是否增长（远端回 cookie 后本机才能成功用 TFO）。
# 实测：不支持的 easeus delta=0，启用 TFO 的 Xray delta=3。
# **不需要 tcpdump** —— v1.3.0 那个探测之所以恒 false，是因为用普通 connect
# 发 SYN（不带 option 34），任何服务端都不会回 34；这一版判据是成立的。
#
# --tfo auto|on|off：auto 跟随伪装站（默认），on/off 由用户强制覆盖。
# 判定结果写进节点 env 的 TFO 字段并随节点持久保存，重建配置不会重复探测。
#
# ⚠️ **扫描不把 TFO 纳入打分或筛选**（见 lib/scanner.sh 的 scanner_score 注释）：
# 伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽/延迟
# 不影响代理上网速度；为凑 TFO 去缩小候选池，反而会削弱抗探测可信度，
# 换来的只是首连省 1 RTT。先按质量选最优站，再读它的 TFO 能力决定我们开不开。
#
# ---- 二、tcpcongestion 按内核能力决定写不写（v1.4.2 起）----
#
# setsockopt(TCP_CONGESTION) 在内核没编译 bbr 时返回 EINVAL 被静默忽略。
#  47.88.102.45  available = reno cubic bbr  → 写 bbr 真生效
#  AX3600 路由器  available = reno cubic      → 写 bbr 是装饰
# 判定用 tcp_available_congestion_control（算法是否可用），不用 current
# （当前默认算法）：per-socket 只要算法可用就生效，也与 `xhy bbr on` 的
# 判定依据一致。不可用时省略整个字段（继承内核默认，不写死 cubic）。
#
# ---- 三、其余四字段无条件写 ----
#
# tcpNoDelay / tcpKeepAliveIdle=45 / tcpUserTimeout=10000 / tcpMptcp=false
# 与 TFO、拥塞控制都无关，任何内核上都成立，砍 sockopt 时不得连带删掉。
# tcpMptcp 显式写 false：GODEBUG 已在进程级关掉 MPTCP，写出来让读代码的人
# 一眼看到结论（字段存在性已在 26.3.27 + 26.10.31 上实测通过）。
# tcpFastOpenQueueLength 不写：Xray 用默认队列长度即可，实测不影响启用。

# 内核是否编译了 bbr（决定 tcpcongestion 写不写）。
# 缓存一次，避免每个 inbound 都 fork 一个 sysctl。
# 测试用 XHY_SOCKOPT_AVAIL_CC 注入，unset 时读真实 sysctl。
XHY_SOCKOPT_CC=""
sockopt_cc_available() {
    if [ -z "${XHY_SOCKOPT_CC-}" ]; then
        local avail=""
        if [ -n "${XHY_SOCKOPT_AVAIL_CC+x}" ]; then
            avail="$XHY_SOCKOPT_AVAIL_CC"
        else
            avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
        fi
        case " $avail " in
            *" bbr "*) XHY_SOCKOPT_CC="bbr" ;;
            *)         XHY_SOCKOPT_CC="none" ;;
        esac
    fi
    if [ "${XHY_SOCKOPT_CC-}" = "bbr" ]; then
        return 0
    fi
    return 1
}

# 判定伪装站 target 是否启用被动 TFO。
# 返回 0 = 支持（应开 TFO）；1 = 不支持或判不了（应关，失败时保守关闭）。
# 判据：curl --tcp-fastopen 连打 3 次，TcpExtTCPFastOpenActive 是否增长。
# 本机到底能不能探测「别人的」被动 TFO —— 三个前提缺一不可：
#   ① curl 支持 --tcp-fastopen
#   ② 读 MIB 的通道可用（nstat 或 /proc/net/netstat 任一可读；精简系统常无 nstat，
#      但 /proc/net/netstat 里 TCPFastOpenActive 字段在，必须回退，否则明明能探却
#      被判「不可用」——8.222.223.248 即此情形：tcp_fastopen=3、无 nstat、但
#      /proc 可读，实测 curl --tcp-fastopen 后 TCPFastOpenActive 照常 +6）
#   ③ net.ipv4.tcp_fastopen 的**客户端位**（bit 0）为 1；为 0 时内核根本不会
#      带数据发 SYN，任何服务端都测成「不支持」——这是最典型的静默假阴性。
# 三者任一不满足，--require-tfo 的结果必然是「一个都没有」，所以要先判再扫。

# 读内核 TcpExtTCPFastOpenActive 计数。优先 nstat；精简系统（BusyBox / 未装
# iproute2）常无 nstat，但 /proc/net/netstat 里字段在，必须回退，否则探测链路
# 明明能探却被判成「不可用」。XHY_NETSTAT_PROC 可重定向，便于测试。
tfo_active_read() {
    local v="" proc="${XHY_NETSTAT_PROC:-/proc/net/netstat}"
    if have_cmd nstat; then
        v="$(nstat -az 2>/dev/null | awk '$1=="TcpExtTCPFastOpenActive"{print $2}')"
    fi
    if [[ ! "$v" =~ ^[0-9]+$ ]] && [[ -r "$proc" ]]; then
        v="$(awk '/^TcpExt:/{ if(h==0){for(i=1;i<=NF;i++) if($i=="TCPFastOpenActive") c=i; h=1; next} else {print $c; exit} }' "$proc" 2>/dev/null)"
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

tfo_probe_ready() {
    local v
    have_cmd curl || return 1
    # ② 通道：nstat 或 /proc/net/netstat 任一可读即可。
    if ! have_cmd nstat && [[ ! -r "${XHY_NETSTAT_PROC:-/proc/net/netstat}" ]]; then
        return 1
    fi
    v="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    (( v & 1 )) || return 1
    return 0
}

# 说明「为什么不能探」，给用户一句能行动的话。
tfo_probe_blocker() {
    local v
    have_cmd curl || { printf 'curl 缺失'; return 0; }
    if ! have_cmd nstat && [[ ! -r "${XHY_NETSTAT_PROC:-/proc/net/netstat}" ]]; then
        printf 'nstat 缺失且 /proc/net/netstat 不可读（apk add iproute2 / apt install iproute2）'
        return 0
    fi
    v="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    if (( !(v & 1) )); then
        printf 'net.ipv4.tcp_fastopen=%s，客户端位没开（需 1 或 3）' "$v"
        return 0
    fi
    printf ''
}

# 把一个域名钉到单个 IPv4。TFO cookie 按目的 IP 缓存，多 A 记录的站在
# 三次 curl 之间可能落到不同 IP 上，于是「支持 TFO 的站」也会测出 0 —— 假阴性。
# 扫描器本身以 IP 为候选（dest 是 IP，走 --resolve 已天然钉死），这里补的是
# 「用户直接给域名」那条路。
resolve_v4_one() {
    local h="$1" ip=""
    if have_cmd getent; then
        ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && have_cmd nslookup; then
        ip="$(nslookup -type=A "$h" 2>/dev/null | awk '/^Name:/{f=1;next} f && /^Address: /{print $2; exit}')"
    fi
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$ip"
}

target_tfo_detect() {
    local dest="$1" port="${2:-443}" sni="${3:-}" b a i resolve=()
    have_cmd curl || return 1
    [[ -n "$sni" ]] || sni="$dest"
    if is_ip_literal "$dest"; then
        resolve=(--resolve "${sni}:${port}:${dest}")
    else
        # 多 A 记录的站：钉死一个 IP，否则三次试探可能各连一台，cookie 永远攒不齐。
        local _ip
        _ip="$(resolve_v4_one "$dest")"
        [[ -n "$_ip" ]] && resolve=(--resolve "${sni}:${port}:${_ip}")
    fi
    b="$(tfo_active_read)"
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    i=0
    while (( i < 3 )); do
        curl -sk -m 4 --tcp-fastopen "${resolve[@]}" \
            "https://${sni}:${port}/" -o /dev/null 2>/dev/null || true
        i=$((i + 1))
    done
    a="$(tfo_active_read)"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    if (( a > b )); then
        return 0
    fi
    return 1
}

# tfo_decide <auto|on|off> <dest> <port> <sni> -> 打印 1（开）或 0（关）
tfo_decide() {
    local mode="${1:-auto}" dest="${2:-}" port="${3:-443}" sni="${4:-}"
    case "$mode" in
        on)  printf '1'; return 0 ;;
        off) printf '0'; return 0 ;;
        auto)
            if [[ -z "$dest" ]]; then printf '0'; return 0; fi
            if target_tfo_detect "$dest" "$port" "$sni"; then
                printf '1'
            else
                printf '0'
            fi
            return 0 ;;
        *)   printf '0'; return 0 ;;
    esac
}

sockopt_json() {
    local tfo="false" cc=""
    if [[ "${TFO:-0}" == "1" ]]; then
        tfo="true"
    fi
    if sockopt_cc_available; then
        cc=',"tcpcongestion":"bbr"'
    fi
    printf '"sockopt":{"tcpFastOpen":%s,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false%s}' "$tfo" "$cc"
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
#
# 三段式，顺序不能动：
#   ① 写前空间闸门 —— 不够就中止，目标二进制一个字节都不碰
#   ② 在临时目录里先验证新二进制能不能跑
#   ③ 同盘 rename 原子替换（跨盘时 .new + mv）
# 反过来做（先 install 再 version）就是 47.88.102.45 那次事故：0 MB 余量下
# install 先把目标 truncate 掉再写到一半，留下 11 MB 的半截文件，而 version
# 失败被误报成「架构或依赖不匹配」。
xray_install() {
    local ver="$1" asset tmp unpack f oldver got
    # 旧二进制不再归档：36 MB 一份，切几次 channel 就是几百 MB，而它能按版本号
    # 重新下载。要留一份保险就显式 XHY_BACKUP_CORE=1（只留最新 1 份）。
    if [[ -x "$XRAY_BIN" && "${XHY_BACKUP_CORE:-0}" == "1" ]]; then
        oldver="$(xray_installed_version)"
        install -d -m 0700 "$XHY_BACKUP"
        cp -a "$XRAY_BIN" "$XHY_BACKUP/xray-${oldver//[^0-9A-Za-z._-]/_}-$(date +%Y%m%d%H%M%S)" 2>/dev/null \
            || warn "旧二进制备份失败（磁盘？），继续安装"
        ls -1t "$XHY_BACKUP"/xray-[0-9]* 2>/dev/null | tail -n +2 | while IFS= read -r f; do rm -f "$f"; done
    fi

    asset="Xray-linux-${XHY_ARCH}.zip"
    tmp="$(mktemp -d)" || die "无法创建临时目录"
    unpack="$tmp/unpack"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    # ① 写前闸门：36 MB 二进制 + geo 数据 + 余量。不足就中止，原文件未动。
    disk_need 90 "安装 Xray $ver" || die "已中止安装：原二进制未改动"
    install -d -m 0700 "$XHY_BACKUP"

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
    chmod 0755 "$unpack/xray"

    # ② 先在临时目录验证，通过后才碰目标文件
    got="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$unpack/xray" version 2>/dev/null \
           | head -1 | awk '{print $2}' | tr -d '\r' || true)"
    if [[ -z "$got" ]]; then
        err "下载的二进制无法执行（下载损坏 / 架构 $XHY_ARCH 不符）"
        err "原二进制未改动，当前版本: $(xray_installed_version)"
        die "安装失败"
    fi

    # ③ 原子替换：同一文件系统用 rename（零拷贝、瞬间），跨盘才退化成 .new + mv
    install -d -m 0755 "$(dirname "$XRAY_BIN")" "$XRAY_ASSET"
    if [[ "$(df -P "$unpack" 2>/dev/null | awk 'NR==2 {print $1}')" \
        == "$(df -P "$(dirname "$XRAY_BIN")" 2>/dev/null | awk 'NR==2 {print $1}')" ]]; then
        mv -f "$unpack/xray" "$XRAY_BIN" || die "替换 $XRAY_BIN 失败（磁盘满？）；原文件未动"
    else
        install -m 0755 "$unpack/xray" "$XRAY_BIN.new" 2>/dev/null \
            || { rm -f "$XRAY_BIN.new"
                 err "写入 $XRAY_BIN.new 失败，余量 $(disk_free_mb /) MB —— 多半是根分区满"
                 die "原二进制未改动"; }
        mv -f "$XRAY_BIN.new" "$XRAY_BIN" || die "替换 $XRAY_BIN 失败；原文件未动"
    fi
    sync
    for f in geoip.dat geosite.dat; do
        [[ -s "$unpack/$f" ]] || continue
        install -m 0644 "$unpack/$f" "$XRAY_ASSET/$f.new" 2>/dev/null \
            || { rm -f "$XRAY_ASSET/$f.new"; warn "$f 写入失败（磁盘满？），保留旧文件"; continue; }
        mv -f "$XRAY_ASSET/$f.new" "$XRAY_ASSET/$f"
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
    if [[ -x "$CF_BIN" ]]; then
        printf 'cloudflared: %s\n' "$("$CF_BIN" --version 2>&1 | head -1)"
    fi
    # 显式 return 0：最后一条若是 `[[ ... ]] && printf`，条件为假时函数返回 1，
    # 在 `set -e` 下调用方（xhy check）会直接中断，自检报告只印一半。
    return 0
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
    local memlimit sup_note="" bg="true" restart_desc
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
# ProtectSystem=strict 会把整个文件系统挂成只读，ReadWritePaths 必须同时上：
# 没有它 append 日志写不进去，服务会直接起不来。
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${XHY_LOGDIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
# 万一 Go runtime 用到集合外的调用，返回 EPERM 而不是 SIGSYS 直接杀进程。
SystemCallErrorNumber=EPERM
StandardOutput=append:${XHY_LOGDIR}/xray.log
StandardError=append:${XHY_LOGDIR}/xray.err

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        # command_background=true 只是把进程丢到后台，挂了不会拉起。OpenRC 上
        # 真正的重启策略要靠 supervise-daemon；老版本没有它时退回后台模式，
        # 但要明确告知"崩溃不自动拉起"，否则 README 里写的自动重启是空的。
        if have_cmd supervise-daemon; then
            bg="false"
        else
            sup_note="本机无 supervise-daemon，Xray 崩溃后不会自动拉起"
        fi
        {
            cat <<'EOF'
#!/sbin/openrc-run
name="xray-hy"
description="xray-hy Xray multi-node service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray-hy/config.json"
EOF
            if [[ "$bg" == "false" ]]; then
                cat <<'EOF'
command_background=false
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 5 --respawn-delay 3 --respawn-period 60"
EOF
            else
                printf 'command_background=true\n'
            fi
            cat <<'EOF'
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
        } >/etc/init.d/xray-hy
        chmod 0755 /etc/init.d/xray-hy
        # 只能替换带引号的值：裸 "s|MEMLIMIT|$memlimit|" 会把 GOMEMLIMIT 里的
        # 子串一起改掉，产出 GO108MiB="108MiB" —— 变量名坏了，Go 根本读不到，
        # 内存上限从未生效过（小内存机器会 OOM）。
        sed -i "s|GOMEMLIMIT=\"MEMLIMIT\"|GOMEMLIMIT=\"${memlimit}\"|" /etc/init.d/xray-hy
        if [[ -n "$sup_note" ]]; then warn "$sup_note"; fi
    fi
    if [[ "$XHY_INIT" == "systemd" ]]; then
        restart_desc="systemd Restart=on-failure"
    elif have_cmd supervise-daemon; then
        restart_desc="supervise-daemon (5 次/60s)"
    else
        restart_desc="无（后台模式，崩溃不拉起）"
    fi
    svc_enable "$SVC_XRAY"
    install_logrotate
    ok "Xray 服务已安装并设为开机自启 ($XHY_INIT, GOMEMLIMIT=${memlimit}, 重启策略=${restart_desc})"
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
XHY_SYSCTL_FILE="/etc/sysctl.d/90-xray-hy.conf"

in_container() {
    [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qE '^container=|^lxc'
}

# 只有运行中的内核真的暴露了该键才写。容器/老内核上不存在的键会让
# `sysctl -p` 整体失败，把同一个文件里本来有效的 BBR 设置一起带走。
# 调用方先设置 XHY_SYSCTL_FILE。
add_sysctl() {
    local key="$1" val="$2" path
    [[ -n "${XHY_SYSCTL_FILE:-}" ]] || return 0
    path="/proc/sys/${key//./\/}"
    [[ -e "$path" ]] || return 0
    printf '%s = %s\n' "$key" "$val" >>"$XHY_SYSCTL_FILE"
    sysctl -w "$key=$val" >/dev/null 2>&1 || true
    return 0
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
    # net.ipv4.tcp_fastopen = 3 只是内核「允许」位（bit0 client + bit1 server），
    # 不代表服务端启用被动 TFO。真正的开关是 sockopt.tcpFastOpen=false
    # （lib/sockopt.sh）：伪装站不支持 TFO，开了会被主动探测区分出来。
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
    XHY_SYSCTL_FILE="$sysctl_file"
    # PMTU 黑洞：握手成功但传不动数据，跨境链路第一号原因
    add_sysctl net.ipv4.tcp_mtu_probing 1
    # idle 后 cwnd 归 1，长连接周期性掉速
    add_sysctl net.ipv4.tcp_slow_start_after_idle 0
    # 默认 32768-60999 只有 28k 个临时端口，高并发出站会 cannot assign requested address
    add_sysctl "net.ipv4.ip_local_port_range" "10240 65000"
    add_sysctl net.core.netdev_max_backlog 16384
    # listen_addr() 用 "::" 监听依赖 bindv6only=0，被别的工具改过就会 v4 全挂
    add_sysctl net.ipv6.bindv6only 0
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
    if ! sysctl -p "$sysctl_file" >/dev/null 2>&1 && ! sysctl --system >/dev/null 2>&1; then
        warn "内核参数写入成功但即时应用失败，重启后通常会生效。请执行 xhy check 复查。"
        state_set BBR_STATUS "pending-reboot"
        return 1
    fi
    # 「选了开就要真开好」：sysctl -p 返回 0 不代表值真的变了 —— 容器、
    # 只读 /proc、被别的工具覆盖都会造成假成功。这里按实测值判定。
    local applied_cc applied_qd
    applied_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    applied_qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$applied_cc" != "bbr" || "$applied_qd" != "fq" ]]; then
        warn "sysctl 已下发但实测未生效 (congestion=${applied_cc:-?} qdisc=${applied_qd:-?})；常见于容器 / 只读 /proc / 被覆盖。开机自启已写好，重启后跑 xhy check 复查。"
        state_set BBR_STATUS "apply-failed"
        return 1
    fi
    state_set BBR_STATUS "on"
    ok "BBR 已启用并验证 (congestion=bbr qdisc=fq)"
    return 0
}

# 幂等兜底：服务端本来就该开 BBR，发现没生效就重新下发。
# BBR_ENABLED=off 是用户在安装时显式选的「不开」，此时完全不干预；
# 未设置（老部署 / 默认）视为 on。只在实测未生效时才调 tune_bbr，
# 避免每次 update config 都重写 sysctl 文件、堆备份。
bbr_ensure() {
    local cur qd
    if [[ "$(state_get BBR_ENABLED on)" == "off" ]]; then
        return 0
    fi
    cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$cur" == "bbr" && "$qd" == "fq" ]]; then
        state_set BBR_STATUS "on"
        return 0
    fi
    info "BBR 未生效 (congestion=${cur:-?} qdisc=${qd:-?})，正在启用…"
    if tune_bbr; then
        return 0
    fi
    return 1
}

bbr_status() {
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    printf '拥塞控制 : %s\n' "${cc:-?}"
    printf 'qdisc    : %s\n' "${qd:-?}"
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]]; then
        printf '实际生效 : yes (congestion=bbr + qdisc=fq)\n'
    else
        printf '实际生效 : NO (congestion=%s qdisc=%s) → 执行 xhy bbr on\n' "${cc:-?}" "${qd:-?}"
    fi
    printf '可用算法 : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
    printf 'MPTCP    : %s (应为 0)\n' "$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf 'migrate_req: %s (应为 0)\n' "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo '内核未暴露')"
    printf '端口范围 : %s\n' "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
    printf 'MTU 探测 : %s (应为 1)\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
    printf 'access日志: %s\n' "$(state_get ACCESS_LOG 'off (默认关闭)')"
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

# 存一份防火墙规则快照；空表不存，同类只留最新 3 份。
_fw_snapshot() {
    local tool="$1" tmp cnt f n=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/fw.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 0
    if ! "${tool}-save" >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    cnt="$(grep -c '^-A' "$tmp" 2>/dev/null || true)"
    if (( ${cnt:-0} == 0 )); then
        rm -f "$tmp"
        info "${tool} 当前没有规则（空表），跳过快照"
        return 0
    fi
    mv -f "$tmp" "$XHY_BACKUP/${tool}.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || { rm -f "$tmp"; return 0; }
    while IFS= read -r f; do
        n=$(( n + 1 ))
        (( n > 3 )) && rm -f "$f"
    done < <(ls -1t "$XHY_BACKUP/${tool}."*.rules 2>/dev/null || true)
    return 0
}

firewall_apply() {
    local mode="${1:-$(state_get FIREWALL_MODE safe)}" quiet="${2:-}" guard
    have_cmd iptables || { warn "未安装 iptables，跳过防火墙配置"; return 1; }
    guard="$(state_get SSH_GUARD on)"
    install -d -m 0700 "$XHY_BACKUP"
    # 空规则不值一份快照：`iptables -F` 之后存下来的是两百多字节的空表，还会按
    # 「最新一份」把有价值的历史顶掉（47.88.102.45 上真实发生过）。
    _fw_snapshot iptables
    if have_cmd ip6tables; then _fw_snapshot ip6tables; fi

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

# firewall_status [--brief]
# --brief 只打前四行摘要：调用方用 `firewall_status | head -4` 时，head 提前
# 关掉管道会让 printf 收到 SIGPIPE，在 pipefail 下把整个 `xhy check` 变成 141。
firewall_status() {
    local brief=""
    if [[ "${1:-}" == "--brief" ]]; then brief="1"; fi
    printf '工作模式 : %s\n' "$(state_get FIREWALL_MODE safe)"
    printf 'SSH 防爆破: %s (端口 %s，60s/5 次 + 1h/8 次 双窗口)\n' "$(state_get SSH_GUARD_STATUS '?')" "$XHY_SSH_PORT"
    printf '节点端口(TCP): %s\n' "$(firewall_node_ports | tr '\n' ' ')"
    printf '节点端口(UDP): %s\n' "$(firewall_udp_ports | tr '\n' ' ')"
    if [[ -n "$brief" ]]; then return 0; fi
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

# 是不是 IPv4 字面量。用于区分「dest 写源站 IP」和「dest 写域名」。
# 只认 v4：v6 目标在 REALITY 里罕见，且 "2001:db8::1:443" 的端口切分会误判，
# 与其悄悄给出错误结果，不如明确不支持。
is_ip_literal() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# 概念说明：target/dest、SNI、serverNames 三个词最容易被混用。
target_help() {
    xhy_t <<'EOF'
  ---- REALITY 名词（这几个词经常被混着说）----
  target / dest  服务端主动去连的「目的地址」，形如 IP:端口 或 域名:端口。
                 REALITY 把未通过认证的探测流量原样转发过去，所以它必须是一个
                 真实存在、长期稳定的 HTTPS 站点 —— 这就是「伪装站」。
  SNI            客户端 TLS 握手时明文声明的域名（ClientHello.server_name）。
                 服务端按 SNI 选证书；REALITY 也拿它判断「像不像正常访问」。
  serverNames    Xray 配置字段，= 允许的 SNI 白名单，一般写一个域名。
                 它必须被 target 的证书覆盖，否则回落握手证书对不上，一眼假。

  ---- 为什么有时要「IP 和域名分开填」----
  站点挂 CDN 时，域名解析到的是 CDN 边缘 IP。此时 dest 若也写域名，REALITY
  就是在替 CDN 做转发，特征不像源站。正确做法：dest 写源站 IP、SNI 仍写域名，
  握手特征与真实站点一致。例：
      target=47.88.102.65:443   SNI=www.easeus.com
  校验会带 --resolve 打这个 IP，验证证书确实覆盖该域名、且没有 CDN 头。

  ---- TFO 与伪装站 ----
  TFO（TCP Fast Open）是 TCP 层的 0-RTT 特性。Xray 的 tcpFastOpen 实测确实
  生效，但我们只在伪装站也支持时才开（xhy add reality 默认 --tfo auto）：
  目标不支持却开，探测者发一个带 cookiereq 的 SYN 就会看到我们回了
  tfo cookie、真实站点没回，一眼可区分。--tfo on / off 可强制覆盖。
  伪装站不承载正常代理流量，它的带宽和延迟不影响代理上网速度，所以 scan
  不把 TFO 纳入打分 —— 先按质量选最优站，再读它的能力。
  scan 的每个候选后面都会标注「TFO 支持 / 不支持」；--require-tfo 只留支持的，
  探测不了或明确不支持都按「不支持」显示（决策上一律关，不做模糊态）。
  --require-tfo 在 /24（或缓存）里没找到时，会自动扩到同机房 /21 再扫一次；
  扩的是不同网段，不会把同一个 /24 白扫两遍。
  菜单 1 / 2 的地域名单也可选择「只要 TFO」：逐站实测，不支持的不兜底；
  该选择会保存，之后新建节点继续沿用。大网站不等于支持 TFO，以实测为准。
EOF
}

# Verify a candidate really speaks TLS 1.3 + HTTP/2, does not redirect and is
# not sitting behind a CDN. Xray itself warns that a CDN-fronted target turns
# the node into an open port forwarder.
#
# $1 = target（IP 或域名，可带 :port），$2 = SNI（可省，省则等于 target 的域名部分）。
# target 是 IP 时必须给 SNI：校验会用 --resolve 把 SNI 域名钉到该 IP 上，
# 测的就是「真实回落到这台源站」的效果，而不是公共 DNS 解析出的 CDN 边缘。
# $3 = 可选的 TFO 标记（如「支持」/「不支持」），由扫描模块现场探测后传入，
#      追加在 [ok] 校验行末尾，让每个候选后面都能看到它是否支持被动 TFO。
#      其它调用方（xhy target 手动校验 / pick_target）不传，输出保持原样。
target_validate() {
    local host="$1" sni="${2:-}" tfo_tag="${3:-}" tls_out="" hdr="" rc=0 probe="" use_openssl=0
    [[ -n "$host" ]] || return 1
    host="${host%%:*}"

    if is_ip_literal "$host"; then
        if [[ -z "$sni" ]]; then
            warn "  $host : target 是 IP，必须同时指定 SNI 域名（否则回落到该 IP 时证书对不上）"
            return 1
        fi
        probe="$sni"; use_openssl=1
    else
        probe="${sni:-$host}"
        if [[ "$probe" != "$host" ]]; then use_openssl=1; fi
    fi

    if [[ -x "$XRAY_BIN" ]] && (( use_openssl == 0 )); then
        if XRAY_LOCATION_ASSET="$XRAY_ASSET" \
                "$XRAY_BIN" tls ping "${host}:443" >/tmp/xhy-tlsping.$$ 2>&1; then
            tls_out="$(cat /tmp/xhy-tlsping.$$)"
        fi
    else
        tls_out="$(printf 'Q' | openssl s_client -connect "${host}:443" \
            -servername "$probe" -tls1_3 2>/dev/null \
            | grep -iE 'Protocol|Cipher' | head -5 || true)"
    fi
    rm -f "/tmp/xhy-tlsping.$$"

    if [[ -n "$tls_out" ]] && ! grep -qiE 'TLS ?v?1\.3|TLS_AES|TLS_CHACHA' <<<"$tls_out"; then
        warn "  $probe : 未确认 TLS 1.3"; rc=1
    fi

    if (( use_openssl == 1 )) && is_ip_literal "$host"; then
        hdr="$(curl -sS -I --http2 -m 12 --resolve "${probe}:443:${host}" \
            "https://${probe}/" 2>/dev/null | tr -d '\r' || true)"
    else
        hdr="$(curl -sS -I --http2 -m 12 "https://${probe}/" 2>/dev/null | tr -d '\r' || true)"
    fi
    if [[ -z "$hdr" ]]; then
        if is_ip_literal "$host"; then
            warn "  ${probe} @ ${host} : 无法建立 HTTPS 连接（该 IP 的证书不覆盖此 SNI，或源站不服务该域名）"
        else
            warn "  ${probe} : 无法建立 HTTPS 连接"
        fi
        return 1
    fi
    grep -qiE '^HTTP/2( |$)' <<<"$hdr" || { warn "  ${probe} : 不支持 HTTP/2"; rc=1; }
    if grep -qiE '^location:' <<<"$hdr"; then
        warn "  ${probe} : 会重定向，不适合作为 target"; rc=1
    fi
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' <<<"$hdr"; then
        warn "  ${probe} : 位于 CDN 之后，不推荐作为 REALITY target"; rc=1
    fi
    if (( rc == 0 )); then
        local suffix=""
        if [[ -n "$tfo_tag" ]]; then suffix=" / TFO ${tfo_tag}"; fi
        if is_ip_literal "$host"; then
            ok "  ${probe} @ ${host} : TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连）${suffix}"
        else
            ok "  ${probe} : TLS 1.3 / H2 / 无跳转 / 非 CDN${suffix}"
        fi
    fi
    return "$rc"
}

target_region() { state_get TARGET_REGION "auto"; }

# Echo "<target> <sni> <label>". Resolution order:
#   1) explicit custom target from state
#   2) best entry of a still-valid scan cache (same datacenter, already verified)
#   3) region chosen by the admin
#   4) auto: match the VPS egress country code
pick_target() {
    local region candidate="" cc="" line r c label tgt sni
    local custom_t custom_s sbest dest port
    local require="${1:-$(state_get TARGET_REQUIRE_TFO 0)}"
    [[ "$require" == "1" ]] || require=0
    custom_t="$(state_get TARGET_CUSTOM '')"
    custom_s="$(state_get TARGET_SNI '')"
    if [[ -n "$custom_t" ]]; then
        printf '%s %s %s\n' "$custom_t" "${custom_s:-${custom_t%%:*}}" "custom"
        return 0
    fi

    # 扫描缓存优先：同机房的真实源站比全球静态表更贴合，而且已经验过一次。
    # XHY_SKIP_SCAN_CACHE=1 可绕过（排查问题时用）。
    # 强制 TFO 的地域选站必须真的读地域名单并逐站探测；扫描缓存的「最优站」
    # 不带这个过滤语义，不能抢在前面直接返回。
    if (( require == 0 )) && [[ "${XHY_SKIP_SCAN_CACHE:-0}" != "1" ]] && declare -F scanner_cache_valid >/dev/null; then
        if scanner_cache_valid; then
            if sbest="$(scanner_cache_pick_valid)"; then
                printf '%s\n' "$sbest"
                return 0
            fi
            warn "扫描缓存中的候选当前都不可用，回退到内置地区库" >&2
        fi
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

    if (( require == 1 )) && ! tfo_probe_ready; then
        warn "本机不具备被动 TFO 探测能力：$(tfo_probe_blocker)" >&2
        return 1
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
            if target_validate "$tgt" "${sni:-${tgt%%:*}}" >&2; then
                if (( require == 1 )); then
                    dest="${tgt%%:*}"; port="${tgt##*:}"
                    [[ "$tgt" == *:* ]] || port=443
                    if target_tfo_detect "$dest" "$port" "${sni:-${tgt%%:*}}"; then
                        ok "  ${sni:-${tgt%%:*}} : TFO 支持" >&2
                    else
                        info "  ${sni:-${tgt%%:*}} : TFO 不支持（跳过）" >&2
                        continue
                    fi
                fi
                found="$tgt|${sni:-${tgt%%:*}}|$label"
                break
            fi
            # 强制 TFO 时绝不把「校验失败或 TFO 不支持」的站当兜底返回。
            (( require == 0 )) && [[ -z "$candidate" ]] && candidate="$tgt|${sni:-${tgt%%:*}}|$label"
        done < <(target_rows)
        [[ -n "$found" ]] && break
    done

    if [[ -n "$found" ]]; then
        printf '%s\n' "${found//|/ }"
        return 0
    fi
    if (( require == 1 )); then
        warn "地域名单里没有通过校验且支持被动 TFO 的站点。" >&2
        return 1
    fi
    if [[ -n "$candidate" ]]; then
        warn "该地区候选均未通过完整校验，回退使用第一个（请自行确认可用性）" >&2
        printf '%s\n' "${candidate//|/ }"
        return 0
    fi
    die "没有可用的伪装站候选，请用 xhy target custom <域名> 手动指定。"
}

# 菜单 1 / 2 共用的地域选站流程。TFO 选择随结果保存，之后新建节点仍沿用，
# 避免菜单里选中了 TFO 站，真正建节点时却又按质量选到别的站。
target_region_pick_flow() {
    local require=0 picked=""
    if confirm "是否只选支持 TFO 的伪装站？（不强制则按质量选）" "n"; then
        require=1
    fi
    if picked="$(pick_target "$require")"; then
        state_set TARGET_REQUIRE_TFO "$require"
        printf '%s\n' "$picked"
        return 0
    fi
    if (( require == 1 )) && confirm "改为不强制 TFO、按质量重选？" "y"; then
        if picked="$(pick_target 0)"; then
            state_set TARGET_REQUIRE_TFO 0
            printf '%s\n' "$picked"
            return 0
        fi
    fi
    return 1
}

target_show() {
    local t s cache
    t="$(state_get TARGET_CUSTOM '')"
    s="$(state_get TARGET_SNI '')"
    printf '地区     : %s (可选: %s)\n' "$(target_region)" "$(target_list_regions)"
    if [[ -n "$t" ]]; then
        printf '自定义   : %s  SNI=%s\n' "$t" "${s:-${t%%:*}}"
    else
        printf '自定义   : 未设置（使用地区自动匹配）\n'
        if [[ "$(state_get TARGET_REQUIRE_TFO 0)" == "1" ]]; then
            printf 'TFO 筛选 : 仅支持被动 TFO\n'
        else
            printf 'TFO 筛选 : 不强制（按质量选）\n'
        fi
    fi
    if declare -F scanner_cache_count >/dev/null && [[ -s "$SCANNER_CACHE" ]]; then
        cache="$(scanner_cache_count) 个候选 / $(scanner_cache_age_h) 小时前"
        if scanner_cache_valid; then
            printf '扫描缓存 : %s（有效，建节点时优先采用）\n' "$cache"
        else
            printf '扫描缓存 : %s（已过期，选项 8 可查看/清除）\n' "$cache"
        fi
    else
        printf '扫描缓存 : 无（选项 7 自动扫描本机机房网段）\n'
    fi
}

# 「指定地区」不该让人背地区代码：列出序号 / 地区 / 国家 / 候选数 / 首个候选。
target_region_table() {
    target_rows | awk -F'|' '
        NF >= 4 && $1 != "" {
            n[$1]++
            if (!($1 in first)) { first[$1] = $4; cc[$1] = $2 }
        }
        END { for (r in n) printf "%s|%s|%d|%s\n", r, cc[r], n[r], first[r] }
    ' | sort
}

# 扫描 → 选出候选 → 可选固定为默认 target → 可选套用到已有 REALITY 节点。
# require_tfo=1 时，若 /24 与同机房 /21 都没有支持被动 TFO 的站点，问一次
# 是否改成不强制重选：支持被动 TFO 的站本来就少，把「扫不到」变成一次选择，
# 而不是让用户回到菜单再猜该去掉哪个开关。
target_scan_flow() {
    local require="${1:-0}" refresh="${2:-0}"
    local -a args=() plain=()
    local sp st ss a
    (( refresh == 1 )) && args+=(--refresh)
    (( require == 1 )) && args+=(--require-tfo)

    if sp="$(scanner_pick ${args[@]+"${args[@]}"})"; then
        read -r st ss _ <<<"$sp"
        ok "最优站点: target=$st SNI=$ss"
        if confirm "固定为当前 target（新建节点直接使用）？" "y"; then
            state_set TARGET_CUSTOM "$st"; state_set TARGET_SNI "$ss"; state_set TARGET_REQUIRE_TFO 0
            ok "已固定 target=$st SNI=$ss"
        fi
        node_retarget_menu "$st" "$ss"
        return 0
    fi

    if (( require == 1 )); then
        warn "本机网段（/24 与同机房 /21）都没有支持被动 TFO 的站点。"
        info "TFO 只省首连 1 个 RTT，伪装站又不承载正常代理流量，不值得为它牺牲站点质量。"
        if confirm "改为不强制 TFO、按质量重选？" "y"; then
            for a in "${args[@]}"; do
                [[ "$a" == "--require-tfo" ]] || plain+=("$a")
            done
            if sp="$(scanner_pick ${plain[@]+"${plain[@]}"})"; then
                read -r st ss _ <<<"$sp"
                ok "最优站点: target=$st SNI=$ss"
                if confirm "固定为当前 target（新建节点直接使用）？" "y"; then
                    state_set TARGET_CUSTOM "$st"; state_set TARGET_SNI "$ss"; state_set TARGET_REQUIRE_TFO 0
                    ok "已固定 target=$st SNI=$ss"
                fi
                node_retarget_menu "$st" "$ss"
                return 0
            fi
        fi
    fi
    warn "自动扫描没有找到可用站点，可改用 1) 按地区，或 3) 手动指定"
    return 1
}

target_menu() {
    while true; do
        printf '\n'
        target_show
        xhy_t <<'EOF'
  1) 按地区自动匹配（按 VPS 出口国家）
  2) 指定地区（列出现有地区与候选数）
  3) 手动指定 target / SNI
  4) 清除自定义设置
  5) 校验指定域名或 IP+SNI
  6) 名词说明（target / dest / SNI / serverNames）
  7) 扫描本机机房网段挑站（可强制 TFO，可替换已有节点）
  8) 查看 / 复核 / 清除扫描缓存
  0) 返回
EOF
        case "$(ask '选择' '0')" in
            1) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto
               info "已设为自动匹配"
               if picked="$(target_region_pick_flow)"; then
                   read -r pt ps pl <<<"$picked"
                   ok "当前 target: $pt SNI=$ps（来源 $pl）"
               fi ;;
            2) local -a regs=()
               local line idx=0 sel r c n t picked pt ps pl
               mapfile -t regs < <(target_region_table)
               if (( ${#regs[@]} == 0 )); then
                   err "伪装站数据文件里没有候选：$TARGETS_FILE"
                   continue
               fi
               printf '\n  %-3s %-8s %-6s %-6s %s\n' "#" "地区" "国家" "候选" "首个候选"
               printf '  %s\n' "----------------------------------------------------------------------"
               for line in "${regs[@]}"; do
                   idx=$((idx + 1))
                   IFS='|' read -r r c n t <<<"$line"
                   printf '  %-3s %-8s %-6s %-6s %s\n' "$idx" "$r" "${c:--}" "$n" "${t:--}"
               done
               printf '\n'
               sel="$(ask '选择地区编号（也可直接输入地区代码，回车取消）' '')"
               [[ -n "$sel" ]] || continue
               if [[ "$sel" =~ ^[0-9]+$ ]]; then
                   if (( sel < 1 || sel > ${#regs[@]} )); then
                       err "编号超出范围（1-${#regs[@]}）"; continue
                   fi
                   IFS='|' read -r r c n t <<<"${regs[$((sel - 1))]}"
               else
                   line="$(target_region_table | grep -m1 -F "${sel}|" || true)"
                   if [[ -z "$line" ]]; then
                       err "没有这个地区：$sel（可用：$(target_list_regions)）"; continue
                   fi
                   IFS='|' read -r r c n t <<<"$line"
               fi
               state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION "$r"
               ok "地区已设为 $r（国家 ${c:--}，$n 个候选）"
               if picked="$(target_region_pick_flow)"; then
                   read -r pt ps pl <<<"$picked"
                   ok "当前 target: $pt SNI=$ps（来源 $pl）"
                   if confirm "固定下来（新建节点直接用）？" "y"; then
                       state_set TARGET_CUSTOM "$pt"; state_set TARGET_SNI "$ps"
                       ok "已固定 target=$pt SNI=$ps"
                   fi
               fi ;;
            3) local h s
               xhy_t <<'EOF'
  输入格式（三种都行）：
    www.example.com                     域名，dest 与 SNI 相同
    1.2.3.4:443,sni=www.example.com     源站 IP + 域名 SNI（目标在 CDN 后时用这个）
    www.example.com:8443                非 443 端口
EOF
               h="$(ask 'target（输入 6 可看详细说明）')"
               [[ -n "$h" ]] || continue
               s="${h#*,sni=}"; [[ "$s" == "$h" ]] && s=""
               h="${h%%,*}"
               [[ "$h" == *:* ]] || h="${h}:443"
               if is_ip_literal "${h%%:*}" && [[ -z "$s" ]]; then
                   err "target 是 IP 时必须加 ,sni=域名（dest 用 IP、SNI 用域名，两者不能省）"
                   continue
               fi
               s="${s:-${h%%:*}}"
               target_validate "$h" "$s" || confirm '校验未完全通过，仍要使用？' 'n' || continue
               state_set TARGET_CUSTOM "$h"; state_set TARGET_SNI "$s"; state_set TARGET_REQUIRE_TFO 0
               ok "已固定 target=$h SNI=$s"
               node_retarget_menu "$h" "$s" ;;
            4) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_del TARGET_REQUIRE_TFO; state_set TARGET_REGION auto; ok "已清除" ;;
            5) local v vs
               xhy_t <<'EOF'
  格式同选项 3：域名 / 域名:端口 / IP:端口,sni=域名
EOF
               v="$(ask '要校验的 target')"
               [[ -n "$v" ]] || continue
               vs="${v#*,sni=}"; [[ "$vs" == "$v" ]] && vs=""
               v="${v%%,*}"
               [[ "$v" == *:* ]] || v="${v}:443"
               if is_ip_literal "${v%%:*}" && [[ -z "$vs" ]]; then
                   err "校验 IP 时必须给 ,sni=域名"; continue
               fi
               vs="${vs:-${v%%:*}}"
               target_validate "$v" "$vs" && ok "校验通过" || warn "校验未完全通过（见上面每条原因）" ;;
            6) target_help; ask '按回车继续' '' ;;
            7) local req=0 ref=0
               if [[ -s "$SCANNER_CACHE" ]] && scanner_cache_valid; then
                   if confirm "已有 $(scanner_cache_age_h) 小时前的扫描缓存，重新扫描？" "n"; then
                       ref=1
                   fi
               fi
               if confirm "是否只选支持 TFO 的伪装站？（不强制则按质量选）" "n"; then
                   req=1
               fi
               target_scan_flow "$req" "$ref" ;;
            8) local ca
               ca="$(ask 'list 查看 / verify 复核 / clear 清除' 'list')"
               case "$ca" in
                   list)   scanner_cache_show ;;
                   verify) scanner_cache_verify ;;
                   clear)  scanner_cache_clear ;;
                   *)      scanner_cache_show ;;
               esac ;;
            0) return 0 ;;
        esac
    done
}

limit_fallback_json() {
    # Mitigation for the upstream REALITY warning: unauthenticated traffic is
    # forwarded to the target. Rate-limit that fallback path.
    # 这是配置片段，不是给人看的文本：保持 cat，别走语言过滤器。
    cat <<'EOF'
        "limitFallbackUpload":   { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
        "limitFallbackDownload": { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
EOF
}

# ===================== lib/scanner.sh =====================
# xray-hy / REALITY 伪装站自动发现（XTLS/RealiTLScanner）+ 结果缓存。
#
# 为什么需要它：conf/targets.tsv 是一份全球静态候选表，而最合适的伪装站往往
# 就在 VPS 自己的机房里 —— 同一个 /24、同一家运营商、TLS 握手个位数毫秒，
# 而且机架不拆它就一直在。RealiTLScanner 能把一个网段里所有 TLS 1.3 + HTTP/2
# 的站点列出来；这个模块负责排序、用**真实 SNI** 逐个验证，并把结果缓存下来，
# 下次建 REALITY 节点不必再扫一遍。
#
# 两个容易踩的点，实现里都做了处理：
#   1. 扫描器看到的是「该 IP 在无 SNI 时给出的默认证书」，CN 可能是 *.example.com。
#      REALITY 回落时会带 serverNames[0] 去握手，所以必须换成具体域名再用
#      curl --resolve 验证证书确实覆盖它，否则回落到源站时证书对不上号。
#   2. 本机 443 上跑的就是 REALITY，扫描会看到「自己回落到 target 的那张证书」，
#      不排除就会把自己选成 target，流量自我循环。
#
# 缓存格式（TSV，前两行是元数据，其余按 score 降序）：
#   # xray-hy scan-cache 1
#   # epoch=<unix> at=<iso> cidr=<...> tool=<ver>
#   score  ip  sni  target  appconnect_ms  http_code  size  issuer  tls  at

SCANNER_REPO="XTLS/RealiTLScanner"
SCANNER_VER="${SCANNER_VER:-v0.2.3}"
XHY_TOOLS_DIR="${XHY_TOOLS_DIR:-/usr/local/lib/xray-hy-tools}"
SCANNER_BIN="${SCANNER_BIN:-$XHY_TOOLS_DIR/RealiTLScanner}"
SCANNER_CACHE="${SCANNER_CACHE:-$XHY_ETC/scan-cache.tsv}"
SCANNER_WORK="${SCANNER_WORK:-$XHY_ETC/scan}"
SCANNER_TTL="${SCANNER_TTL:-604800}"        # 缓存有效期，秒（默认 7 天）
SCANNER_MAX_VERIFY="${SCANNER_MAX_VERIFY:-48}"
SCANNER_BUDGET="${SCANNER_BUDGET:-180}"     # 验证阶段总时长上限，秒
SCANNER_THREADS="${SCANNER_THREADS:-128}"
SCANNER_TIMEOUT="${SCANNER_TIMEOUT:-4}"

# 下面这些函数的 stdout 会被 `best="$(scanner_pick)"` 捕获，只允许输出最终
# 三元组 "<target> <sni> <label>"。所有进度/诊断一律走 stderr。
sc_info() { info "$@" >&2; }
sc_ok()   { ok   "$@" >&2; }

# ---------------------------------------------------------------------------
# 二进制获取
# ---------------------------------------------------------------------------

# 官方只发 linux-amd64 / linux-arm64 两个 Linux 资产。
scanner_asset() {
    case "$XHY_ARCH" in
        64)        printf 'linux-amd64' ;;
        arm64-v8a) printf 'linux-arm64' ;;
        *)         return 1 ;;
    esac
}

# 能不能跑起来。musl 系统缺 glibc loader 时是 127/not found，不是崩溃。
scanner_smoke() {
    local out="" rc=0
    [[ -x "$SCANNER_BIN" ]] || return 1
    out="$("$SCANNER_BIN" 2>&1)" || rc=$?
    (( rc == 127 )) && return 1
    grep -q -- '-addr' <<<"$out"
}

scanner_ensure() {
    local asset tmp rc=0
    if scanner_smoke; then return 0; fi
    if ! asset="$(scanner_asset)"; then
        err "RealiTLScanner 只提供 linux-amd64 / linux-arm64，当前架构 $XHY_ARCH 用不了"
        err "改用内置地区库: xhy target → 1) 按地区自动匹配，或手动指定 target/SNI"
        return 1
    fi
    need_root
    install -d -m 0755 "$XHY_TOOLS_DIR" || return 1
    tmp="$(mktemp "$XHY_TOOLS_DIR/.rts.XXXXXX")" || return 1
    sc_info "下载 RealiTLScanner $SCANNER_VER ($asset，约 4 MB)"
    if ! fetch "https://github.com/${SCANNER_REPO}/releases/download/${SCANNER_VER}/RealiTLScanner-${asset}" "$tmp"; then
        rm -f "$tmp"
        err "RealiTLScanner 下载失败。GitHub 不通时只能用内置地区库。"
        return 1
    fi
    if [[ "$(head -c 4 "$tmp" 2>/dev/null)" != $'\x7fELF' ]]; then
        rm -f "$tmp"
        err "下载内容不是 ELF 二进制（可能被劫持/重定向），已中止"
        return 1
    fi
    chmod 0755 "$tmp"
    install -m 0755 "$tmp" "$SCANNER_BIN" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    if ! scanner_smoke; then
        # 官方二进制是 glibc 动态链接的；Alpine 是 musl，直接跑会 "not found"。
        if [[ "$XHY_DISTRO" == "alpine" ]]; then
            sc_info "RealiTLScanner 需要 glibc 兼容层（Alpine/musl），安装 libc6-compat ..."
            pkg_install libc6-compat >/dev/null 2>&1 || true
            if ! scanner_smoke; then
                pkg_install gcompat >/dev/null 2>&1 || true
            fi
        fi
        if ! scanner_smoke; then
            err "RealiTLScanner 无法运行（架构或运行库不匹配）：$SCANNER_BIN"
            err "Alpine 可手工修复: apk add libc6-compat gcompat"
            return 1
        fi
        sc_ok "glibc 兼容层已装好，扫描器可用"
    fi
    sc_ok "扫描器就绪: $SCANNER_BIN ($SCANNER_VER)"
}

# ---------------------------------------------------------------------------
# 网段推导
# ---------------------------------------------------------------------------

# cidr_truncate <ipv4> <prefix> —— 把 IP 归到指定前缀的网络地址
cidr_truncate() {
    local ip="$1" p="$2"
    is_ip_literal "$ip" || return 1
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 8 && p <= 32 )) || return 1
    awk -v ip="$ip" -v p="$p" 'BEGIN {
        n = split(ip, a, ".")
        if (n != 4) exit 1
        v = a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4]
        block = 2 ^ (32 - p)
        net = int(v / block) * block
        printf "%d.%d.%d.%d/%d", int(net / 16777216) % 256, int(net / 65536) % 256, int(net / 256) % 256, net % 256, p
    }'
}

# 默认扫本机公网 IP 所在的 /24：同机架、最低延迟、最容易长期存在。
scanner_default_cidr() {
    local ip
    ip="$(public_ip || true)"
    is_ip_literal "$ip" || return 1
    cidr_truncate "$ip" 24
}

# ---------------------------------------------------------------------------
# 候选过滤与打分（纯函数，离线可测）
# ---------------------------------------------------------------------------

# CN -> 可用于 SNI 的具体域名（通配符证书给两个猜测，按顺序试）
scanner_sni_candidates() {
    local cn="${1,,}" base
    base="${cn#\*.}"
    case "$cn" in
        \*.*) printf '%s %s\n' "www.${base}" "${base}" ;;
        *)    printf '%s\n' "$base" ;;
    esac
}

# 这个 CN 适合当伪装站吗？排除的不是「证书无效」，而是「一眼就是代理/测试环境」。
scanner_domain_ok() {
    local d="${1,,}" lab
    local -a labels=()
    # 通配符证书的 "*." 是证书属性，不是域名的一部分；去掉后再按标签判断。
    d="${d#\*.}"
    [[ -n "$d" ]] || return 1
    case "$d" in
        *" "*|*/*|*:*) return 1 ;;
        *kubernetes*|*ingress*|*localhost*|*example.com|*example.net|*example.org|*invalid) return 1 ;;
        *.local|*.internal|*.lan|*.test|*.home|*.arpa|*.onion) return 1 ;;
        # 这类 CN 说明这台机器只是别人的反代/CDN 边缘，拿到的是厂商证书而不是
        # 站点自己的证书，回落时会露馅。
        *cloudflare.com|*cloudflare.net|*fastly.net|*akamaiedge.net) return 1 ;;
    esac
    [[ "$d" == *.* ]] || return 1
    IFS='.' read -r -a labels <<<"$d"
    (( ${#labels[@]} >= 2 )) || return 1
    for lab in "${labels[@]}"; do
        [[ "$lab" =~ ^[a-z0-9-]+$ ]] || return 1
        case "$lab" in
            api|vpn|proxy|proxies|sub|subs|subscribe|subscription|node|nodes|airport|\
            test|testing|dev|develop|staging|stage|demo|alpha|beta|sandbox|\
            chatgpt|openai|claude|gemini|copilot|grok|\
            ss|ssr|v2ray|xray|clash|trojan|hysteria|hy2|reality|tunnel|relay|forward)
                return 1 ;;
        esac
    done
    if [[ "${labels[0]}" =~ ^[0-9]+$ ]]; then return 1; fi
    return 0
}

# scanner_score <appconnect_ms> <http_code> <size> <wildcard 0|1> <www 0|1>
# 分数只用于排序，不做合格判定（合格与否由 scanner_probe 决定）。
#
# 不把 TFO 能力纳入打分（它是 --require-tfo 的硬过滤项，但不加权）：
#   - TFO 只是我们服务端 listen socket 的行为，跟随目标即可（见 sockopt.sh
#     的 target_tfo_detect / tfo_decide），不需要目标「优先支持」；
#   - 支持被动 TFO 的 HTTPS 站点在公网上是少数，加权会把候选池往冷门站带，
#     削弱抗探测可信度；
#   - 伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽和
#     延迟不影响代理上网速度，凑 TFO 换来的只是首连省 1 RTT。
# 顺序：先按质量打分 → 展示短名单时现场探测 TFO → 需要则硬过滤 → 用户选。
# 是否强制由用户在 xhy scan / xhy target 里选，默认不强制。
scanner_score() {
    local ms="${1:-9999}" code="${2:-0}" size="${3:-0}" wild="${4:-0}" www="${5:-0}" s=100
    [[ "$ms" =~ ^[0-9]+$ ]] || ms=9999
    (( ms <= 0 )) && ms=9999
    # 同机房通常 <10ms。每 10ms 扣 3 分，最低 70：延迟差一点不该盖过站点质量。
    s=$(( s - (ms / 10) * 3 ))
    (( s < 70 )) && s=70
    case "$code" in
        200)      s=$(( s + 15 )) ;;
        204|206)  s=$(( s + 8 )) ;;
        401|403)  s=$(( s - 15 )) ;;
        404|410)  s=$(( s - 20 )) ;;
        5??)      s=$(( s - 30 )) ;;
    esac
    (( size > 2000 )) && s=$(( s + 6 ))
    (( wild == 1 )) && s=$(( s - 4 ))
    # www. 是最常见的访问形态，回落时看起来最像普通用户访问。
    (( www == 1 )) && s=$(( s + 2 ))
    printf '%d' "$s"
}

# CSV -> 候选 TSV（ip \t cn \t issuer \t tls \t alpn）
# RealiTLScanner 只写「TLS 1.3 + h2 + 有 CN + 有 issuer」的行，这里再做一次
# 防御性过滤，并按列尾定位（issuer 里可能带逗号，不能简单按第 9/10 列取）。
scanner_candidates() {
    local csv="$1" tab=$'\t'
    [[ -s "$csv" ]] || return 1
    awk -F',' -v OFS="$tab" '
        NR > 1 && NF >= 11 {
            ip = $1; tls = $(NF - 8); alpn = $(NF - 7); cn = $(NF - 2); iss = $(NF - 1)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", cn)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", iss)
            if (tls !~ /1\.3/ || alpn !~ /h2/ || cn == "") next
            print ip, cn, iss, tls, alpn
        }' "$csv" | sort -u
}

# 用真实 SNI 打这台 IP。成功时输出：
#   <http_version>|<appconnect_ms>|<http_code>|<size>|<redirect 0/1>|<cdn 0/1>
# 故意不带 -k：证书必须真的覆盖这个域名，否则 RELITY 回落时看到的就是错证书。
scanner_probe() {
    local ip="$1" sni="$2" d rc=0 met hv ac code size ms redir=0 cdn=0
    d="$(mktemp -d "${TMPDIR:-/tmp}/xhy-probe.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$d'" RETURN
    curl -sS --tlsv1.3 --http2 --max-time 8 \
        --resolve "${sni}:443:${ip}" \
        -D "$d/h" -o /dev/null \
        -w '%{http_version}|%{time_appconnect}|%{http_code}|%{size_download}' \
        "https://${sni}/" >"$d/m" 2>/dev/null || rc=$?
    (( rc == 0 )) || return 1
    [[ -s "$d/m" ]] || return 1
    met="$(cat "$d/m")"
    IFS='|' read -r hv ac code size <<<"$met"
    [[ "$hv" == "2" ]] || return 1
    [[ -n "$code" && "$code" != "000" ]] || return 1
    ms="$(awk -v v="${ac:-0}" 'BEGIN { printf "%d", v * 1000 }')"
    if grep -qiE '^location:' "$d/h"; then redir=1; fi
    case "$code" in 30[12378]) redir=1 ;; esac
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' "$d/h"; then
        cdn=1
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$hv" "$ms" "$code" "$size" "$redir" "$cdn"
}

# CSV -> 已排序的合格候选 TSV（就是缓存的数据行格式）
scanner_rank() {
    local csv="$1" out="$2" tab=$'\t'
    local ip cn iss tls alpn sni res hv ms code size redir cdn sc
    local self4 self6 total=0 keep=0 t0 now
    : >"$out"
    self4="$(public_ip || true)"
    self6="$(public_ip6 || true)"
    total="$(scanner_candidates "$csv" | wc -l | tr -d ' ')"
    t0="$(date +%s)"
    while IFS="$tab" read -r ip cn iss tls alpn; do
        [[ -n "$ip" ]] || continue
        # 本机 443 就是 REALITY：不排掉会把自己选成 target。
        if [[ -n "$self4" && "$ip" == "$self4" ]]; then continue; fi
        if [[ -n "$self6" && "$ip" == "$self6" ]]; then continue; fi
        scanner_domain_ok "$cn" || continue
        if (( keep >= SCANNER_MAX_VERIFY )); then break; fi
        now="$(date +%s)"
        if (( now - t0 > SCANNER_BUDGET )); then
            warn "验证阶段超过 ${SCANNER_BUDGET}s，用已完成的 $keep 个候选继续"
            break
        fi
        for sni in $(scanner_sni_candidates "$cn"); do
            if ! res="$(scanner_probe "$ip" "$sni")"; then continue; fi
            IFS='|' read -r hv ms code size redir cdn <<<"$res"
            if (( redir == 1 || cdn == 1 )); then continue; fi
            local ww=0 wc=0
            if [[ "$cn" == \*.* ]]; then ww=1; fi
            if [[ "${sni#www.}" != "$sni" ]]; then wc=1; fi
            sc="$(scanner_score "$ms" "$code" "$size" "$ww" "$wc")" 
            printf '%s\t%s\t%s\t%s:443\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$sc" "$ip" "$sni" "$ip" "$ms" "$code" "$size" "$iss" "$tls" "$(date -Is)" >>"$out"
            keep=$(( keep + 1 ))
            sc_info "  + ${sni} @ ${ip}  ${ms}ms  HTTP ${code}  ${size}B  score ${sc}"
            break
        done
    done < <(scanner_candidates "$csv")
    (( keep > 0 )) || return 1
    # 分数相同的按握手延迟升序，再按行内容定序（避免每次扫描结果漂移）。
    sort -t "$tab" -k1,1nr -k5,5n "$out" >"$out.sorted" && mv -f "$out.sorted" "$out"
    sc_ok "验证完成：$keep 个可用候选（共 $total 个去重候选）"
}

# ---------------------------------------------------------------------------
# 缓存
# ---------------------------------------------------------------------------

scanner_cache_epoch() {
    sed -n 's/^# epoch=\([0-9][0-9]*\).*/\1/p' "$SCANNER_CACHE" 2>/dev/null | head -1
}

scanner_cache_age_h() {
    local epoch now
    epoch="$(scanner_cache_epoch)"
    if [[ -z "$epoch" ]]; then printf '?'; return 0; fi
    now="$(date +%s)"
    printf '%s' "$(( (now - epoch) / 3600 ))"
}

scanner_cache_valid() {
    local epoch now
    [[ -s "$SCANNER_CACHE" ]] || return 1
    epoch="$(scanner_cache_epoch)"
    [[ -n "$epoch" ]] || return 1
    now="$(date +%s)"
    (( now - epoch <= SCANNER_TTL ))
}

scanner_cache_count() {
    local n="0"
    [[ -s "$SCANNER_CACHE" ]] || { printf '0'; return 0; }
    n="$(grep -vc '^#' "$SCANNER_CACHE" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

scanner_cache_best() {
    local tab=$'\t'
    [[ -s "$SCANNER_CACHE" ]] || return 1
    { grep -v '^#' "$SCANNER_CACHE" 2>/dev/null || true; } | sort -t "$tab" -k1,1nr -k5,5n
}

# 同 ip|sni 只留分数最高的那条。
scanner_cache_merge() {
    local old="$1" new="$2" tab=$'\t'
    { grep -v '^#' "$old" 2>/dev/null || true; cat "$new"; } \
        | awk -F"$tab" '
            {
                k = $2 "|" $3
                s = $1 + 0
                if (!(k in score) || s > score[k]) { score[k] = s; line[k] = $0 }
            }
            END { for (k in line) print line[k] }' \
        | sort -t "$tab" -k1,1nr -k5,5n
}

# scanner_cache_save <cidr> <ranked.tsv> [replace 0|1]
scanner_cache_save() {
    local cidr="$1" rows="$2" replace="${3:-0}" tmp tab=$'\t'
    [[ -s "$rows" ]] || return 1
    # 不用 `install -d -m`：目录已存在时它会去 chmod，MSYS / 只读挂载上会返回
    # 非零，缓存就写不进去了。权限失败不影响功能，忽略即可（与 init_dirs 一致）。
    mkdir -p "$(dirname "$SCANNER_CACHE")" || return 1
    chmod 0700 "$(dirname "$SCANNER_CACHE")" 2>/dev/null || true
    tmp="$(mktemp "${SCANNER_CACHE}.XXXXXX")" || return 1
    {
        printf '# xray-hy scan-cache 1\n'
        printf '# epoch=%s at=%s cidr=%s tool=%s\n' \
            "$(date +%s)" "$(date -Is)" "$cidr" "$SCANNER_VER"
        if [[ "$replace" == "0" ]] && scanner_cache_valid; then
            scanner_cache_merge "$SCANNER_CACHE" "$rows"
        else
            sort -t "$tab" -k1,1nr -k5,5n "$rows"
        fi
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    install -m 0600 "$tmp" "$SCANNER_CACHE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp" || true
}

scanner_cache_clear() {
    rm -f "$SCANNER_CACHE" && sc_ok "已清除扫描缓存"
}

scanner_cache_show() {
    local sc ip sni tgt ms code size iss tls at epoch at_iso tfo
    if [[ ! -s "$SCANNER_CACHE" ]]; then
        warn "暂无扫描缓存（xhy scan 扫一次就会存下来）"
        return 0
    fi
    epoch="$(scanner_cache_epoch)"
    at_iso="$(sed -n 's/^# .*at=\([^ ]*\).*/\1/p' "$SCANNER_CACHE" 2>/dev/null | head -1 || true)"
    printf '缓存文件 : %s\n' "$SCANNER_CACHE"
    printf '扫描时间 : %s（%s 小时前，有效期 %s 小时）\n' \
        "${at_iso:-?}" "$(scanner_cache_age_h)" "$(( SCANNER_TTL / 3600 ))"
    if scanner_cache_valid; then printf '状态     : 有效（建节点时会被直接采用）\n'
    else printf '状态     : 已过期（下次自动扫描会重扫）\n'; fi
    printf '\n  %-4s %-16s %-34s %7s %5s %9s  %-6s %s\n' "分数" "IP" "SNI" "握手" "HTTP" "大小" "TFO" "签发者"
    printf '  %s\n' "--------------------------------------------------------------------------------------------------"
    printf '  TFO 列为现场探测结果（不写入缓存；探测不了按不支持处理）\n'
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$ip" ]] || continue
        tfo="$(scanner_tfo_tag "$(scanner_tfo_of "$ip" "$sni")")"
        printf '  %-4s %-16s %-34s %5sms %5s %8sB  %-6s %s\n' \
            "$sc" "$ip" "$sni" "$ms" "$code" "$size" "$tfo" "$iss"
    done < <(scanner_cache_best)
    printf '\n'
}

scanner_cache_verify() {
    local sc ip sni tgt ms code size iss tls at tmp keep=0 drop=0 hdr tfo
    [[ -s "$SCANNER_CACHE" ]] || { warn "暂无扫描缓存"; return 1; }
    tmp="$(mktemp "${SCANNER_CACHE}.XXXXXX")" || return 1
    hdr="$(head -2 "$SCANNER_CACHE" | grep '^#' || true)"
    {
        printf '%s\n' "$hdr"
        while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
            [[ -n "$ip" ]] || continue
            tfo="$(scanner_tfo_tag "$(scanner_tfo_of "$ip" "$sni")")"
            if target_validate "$tgt" "$sni" "$tfo" >&2; then
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$sc" "$ip" "$sni" "$tgt" "$ms" "$code" "$size" "$iss" "$tls" "$at"
                keep=$(( keep + 1 ))
            else
                drop=$(( drop + 1 ))
            fi
        done < <(scanner_cache_best)
    } >"$tmp"
    install -m 0600 "$tmp" "$SCANNER_CACHE"
    rm -f "$tmp" || true
    if (( keep == 0 )); then
        rm -f "$SCANNER_CACHE"
        warn "所有缓存候选都已失效，缓存已清空（下次会重新扫描）"
        return 1
    fi
    sc_ok "复核完成：保留 $keep 个，剔除 $drop 个"
}

# 逐个拿缓存候选做 REALITY 级校验，返回第一个可用的 "<target> <sni> scan"。
# target_validate 的 stdout 必须转到 stderr，否则会污染调用方捕获的三元组。
scanner_cache_pick_valid() {
    local sc ip sni tgt ms code size iss tls at
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$tgt" ]] || continue
        if target_validate "$tgt" "$sni" >&2; then
            printf '%s %s scan\n' "$tgt" "$sni"
            return 0
        fi
    done < <(scanner_cache_best)
    return 1
}

# ---------------------------------------------------------------------------
# 候选短名单与 TFO 选项
# ---------------------------------------------------------------------------
#
# TFO 能力不写进缓存：它是站点当前配置，7 天 TTL 的缓存反而可能过期。
# 展示短名单时现场探测（同机房约 0.1s），并用关联数组在同一次调用内去重。
# 打分不因 TFO 加权（scanner_score 注释），但 --require-tfo 会做硬过滤。

SCANNER_SHORTLIST="${SCANNER_SHORTLIST:-5}"   # 最终展示给用户挑的候选数
SCANNER_TFO_POOL="${SCANNER_TFO_POOL:-12}"    # require-tfo 时最多探多少个
# 扩到 /21 后候选会多得多，别让排在前面的 /24 老候选把新站挤出探测池。
SCANNER_TFO_POOL_WIDE="${SCANNER_TFO_POOL_WIDE:-32}"
# 不能用 declare -A：本文件是被 load_libs() 在函数内 source 的，declare
# 会创建局部变量，函数返回后它退化成普通索引数组、字符串下标触发算术错误。
# 用空格分隔的 "ip|sni=0/1" 字符串做去重，无作用域问题。
XHY_TFO_CACHE=""

# scanner_tfo_of <ip> <sni> -> 1（支持）/ 0（不支持或判不了）
scanner_tfo_of() {
    local k="${1}|${2}" r
    case " $XHY_TFO_CACHE " in
        *" $k=1 "*) printf '1'; return 0 ;;
        *" $k=0 "*) printf '0'; return 0 ;;
    esac
    if target_tfo_detect "$1" 443 "$2"; then r=1; else r=0; fi
    XHY_TFO_CACHE="$XHY_TFO_CACHE $k=$r"
    printf '%s' "$r"
}

# scanner_tfo_tag <1|0> -> 「支持」/「不支持」。
# 探测失败（工具缺失、远端无响应）与明确不支持一并显示「不支持」：
# 决策上两者都按关闭处理，不给用户一个看起来「可能能用」的模糊态。
scanner_tfo_tag() {
    if [[ "${1:-0}" == "1" ]]; then printf '支持'; else printf '不支持'; fi
}

# 从缓存挑 3–5 个候选展示给用户选。
# stdout 只输出最终 "<target> <sni> scan"；列表与提示一律走 stderr，
# 因为调用方是 `best="$(scanner_pick)"`。
# 非交互（读不到 /dev/tty）时自动取第 1 个，脚本化调用不会被卡住。
scanner_shortlist() {
    local require="${1:-0}" want="${2:-$SCANNER_SHORTLIST}" pool_override="${3:-}" pool
    local -a tgts=() snis=() scs=() mss=() codes=() tfos=()
    local sc ip sni tgt ms code size iss tls at tfo n=0 ans="" pick=0 i
    if (( require == 1 )); then
        pool="${pool_override:-$SCANNER_TFO_POOL}"
    else
        pool=$(( want * 3 ))
    fi
    XHY_TFO_CACHE=""
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$tgt" ]] || continue
        (( n >= pool )) && break
        n=$(( n + 1 ))
        # 先现场探测 TFO，把标记随 target_validate 一起打印：即使该候选被
        # --require-tfo 过滤掉，用户也能看到「这个站到底支不支持」，而不是
        # 只看到最后一句「没有支持 TFO 的站点」。探测结果在同次调用内缓存。
        tfo="$(scanner_tfo_of "$ip" "$sni")"
        target_validate "$tgt" "$sni" "$(scanner_tfo_tag "$tfo")" >&2 || continue
        if (( require == 1 )) && [[ "$tfo" != "1" ]]; then continue; fi
        tgts+=("$tgt"); snis+=("$sni"); scs+=("$sc")
        mss+=("$ms"); codes+=("$code"); tfos+=("$tfo")
        (( ${#tgts[@]} >= want )) && break
    done < <(scanner_cache_best)

    if (( ${#tgts[@]} == 0 )); then
        if (( require == 1 )); then
            warn "当前网段内没有支持被动 TFO 的候选（每个站点后已标注 TFO 结果）；将自动扩大到 /21 再扫一次"
        else
            warn "缓存里没有通过校验的候选，请 xhy scan --refresh 重扫。"
        fi
        return 1
    fi

    {
        printf '\n  候选伪装站（按质量排序；TFO=目标是否支持被动 TFO）\n'
        printf '  %-3s %-5s %-16s %-34s %8s %6s  %s\n' "#" "分数" "IP" "SNI" "握手" "HTTP" "TFO"
        printf '  %s\n' "--------------------------------------------------------------------------------------------"
        for (( i=0; i<${#tgts[@]}; i++ )); do
            if [[ "${tfos[$i]}" == "1" ]]; then tfo="支持"; else tfo="—"; fi
            printf '  %-3s %-5s %-16s %-34s %6sms %6s  %s\n' \
                "$(( i + 1 ))" "${scs[$i]}" "${tgts[$i]%%:*}" "${snis[$i]}" \
                "${mss[$i]}" "${codes[$i]}" "$tfo"
        done
        if (( require == 1 )); then
            printf '  （已按「必须支持 TFO」过滤）\n'
        else
            printf '  （未强制 TFO；列表里也可能含支持 TFO 的站点）\n'
        fi
        printf '\n'
    } >&2

    printf '  选哪个 [1-%d]（回车=1，0=自动取最高分）: ' "${#tgts[@]}" >&2
    # 复合命令的 stderr 重定向才能吞掉「< /dev/tty 打不开」的 shell 报错：
    # `read ... 2>/dev/null` 只重定向 read 自己的 stderr，重定向失败发生在
    # 那之前，仍会打印 "No such device or address"（ssh 无 tty / CI 场景）。
    if { read -r ans < /dev/tty; } 2>/dev/null; then :; else ans=""; fi
    printf '\n' >&2
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tgts[@]} )); then
        pick=$(( ans - 1 ))
    fi
    printf '%s %s scan\n' "${tgts[$pick]}" "${snis[$pick]}"
    sc_ok "已选: target=${tgts[$pick]} SNI=${snis[$pick]}（TFO=${tfos[$pick]}）"
    return 0
}

# ---------------------------------------------------------------------------
# 扫描与选择
# ---------------------------------------------------------------------------

# scanner_scan <cidr> [cache_replace 0|1]
# cache_replace=1：扩到 /21 后不再和旧 /24 缓存合并，直接写本次结果，
# 避免旧候选把新扫到的站点挤出 --require-tfo 的探测池（/21 覆盖 /24，
# 同网段站点会被重新发现，不会真的丢）。
scanner_scan() {
    local cidr="$1" cache_replace="${2:-0}" ts csv log ranked n uniq
    scanner_ensure || return 1
    install -d -m 0700 "$SCANNER_WORK" || return 1
    ts="$(date +%s)"
    csv="$SCANNER_WORK/scan-${ts}.csv"
    log="$csv.log"
    sc_info "扫描 $cidr（端口 443，thread ${SCANNER_THREADS}，超时 ${SCANNER_TIMEOUT}s/主机）..."
    if ! "$SCANNER_BIN" -addr "$cidr" -port 443 -thread "$SCANNER_THREADS" \
            -timeout "$SCANNER_TIMEOUT" -out "$csv" >"$log" 2>&1; then
        err "扫描失败，日志: $log" >&2
        return 1
    fi
    n=$(( $(wc -l <"$csv" | tr -d ' ') - 1 ))
    uniq="$(scanner_candidates "$csv" | wc -l | tr -d ' ')"
    if (( n <= 0 )); then
        warn "$cidr 内没有 TLS 1.3 + HTTP/2 站点（日志: $log）"
        return 1
    fi
    sc_info "命中 ${uniq:-0} 个 TLS 1.3 + h2 站点（$n 条记录，按域名去重），逐个用真实 SNI 验证（最多 ${SCANNER_MAX_VERIFY} 个）..."
    ranked="$SCANNER_WORK/ranked-${ts}.tsv"
    if ! scanner_rank "$csv" "$ranked"; then
        warn "没有既非 CDN、又不跳转、证书可校验的站点（日志: $log）"
        return 1
    fi
    scanner_cache_save "$cidr" "$ranked" "$cache_replace" || return 1
    scanner_prune_work
    sc_ok "结果已缓存: $SCANNER_CACHE"
}

# 只保留最近 5 次扫描产物，别把 /etc 撑大（每次 CSV 只有几十 KB，但会累积）。
scanner_prune_work() {
    local f n=0
    [[ -d "$SCANNER_WORK" ]] || return 0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        n=$(( n + 1 ))
        if (( n > 10 )); then rm -f "$f"; fi
    done < <(ls -1t "$SCANNER_WORK"/scan-*.csv "$SCANNER_WORK"/ranked-*.tsv 2>/dev/null || true)
    return 0
}

# 输出 "<target> <sni> <label>"：优先用有效缓存，否则扫本机 /24（不够再扩 /21）。
#   scanner_pick [--refresh] [--cidr 1.2.3.0/24] [--require-tfo]
# --require-tfo：只展示支持被动 TFO 的候选；默认不强制（按质量选，可能含 TFO 站）。
#   /24（或缓存）里没有支持 TFO 的站点时，自动扩到同机房 /21 再扫一次。
#   扩的是**不同网段**，不是把同一 /24 白扫两遍 —— 早期版本那个误导已修掉。
scanner_pick() {
    local refresh=0 cidr="" best wide="" require_tfo=0
    local save_mode=0 tried_wide=0 cache_ok=0 pool_arg=""
    while (( $# > 0 )); do
        case "$1" in
            --refresh) refresh=1; shift ;;
            --cidr)    cidr="${2:?--cidr 需要网段}"; shift 2 ;;
            --require-tfo) require_tfo=1; shift ;;
            -*)        die "未知参数: $1（可用 --refresh / --cidr / --require-tfo）" ;;
            *)         cidr="$1"; shift ;;
        esac
    done

    # 「本机根本探不出 TFO」必须在开扫之前说清楚：否则用户看到的是
    # 「扫了 /24 又扫 /21，一个都没有」，会误判成"全网没人开 TFO"。
    if (( require_tfo == 1 )) && ! tfo_probe_ready; then
        warn "本机不具备被动 TFO 探测能力：$(tfo_probe_blocker)"
        warn "此时 --require-tfo 的结果必然是空，不代表网段里没有支持 TFO 的站点。"
        if confirm "改为按质量选站（不强制 TFO）？" "y"; then
            require_tfo=0
        else
            err "已按你的要求中止。修好上面那条再跑，或去掉 --require-tfo。" >&2
            return 1
        fi
    fi

    if (( refresh == 0 )) && scanner_cache_valid; then
        cache_ok=1
        sc_info "使用扫描缓存（$(scanner_cache_age_h) 小时前，$(scanner_cache_count) 个候选；--refresh 可强制重扫）"
        if best="$(scanner_shortlist "$require_tfo")"; then
            printf '%s\n' "$best"
            return 0
        fi
        if (( require_tfo == 0 )); then
            warn "缓存里的候选都已失效，重新扫描"
        else
            # 过滤为空 ≠ 缓存失效，但用户要求「必须 TFO 时第一次没扫到就
            # 自动扩大范围再扫」：直接跳到 /21，不重复扫同一个 /24。
            sc_info "缓存里没有支持被动 TFO 的站点；自动扩大网段再扫一次（不重复扫同一 /24）"
        fi
    fi

    if [[ -z "$cidr" ]]; then
        if ! cidr="$(scanner_default_cidr)"; then
            err "无法确定本机公网网段，请显式指定: xhy scan 1.2.3.0/24" >&2
            return 1
        fi
    fi

    # 缓存有效但 require-tfo 过滤为空：直接以 /21 起步，别把同一 /24 重扫一遍。
    if (( cache_ok == 1 && require_tfo == 1 )); then
        wide="$(cidr_truncate "${cidr%%/*}" 21)" || wide=""
        if [[ -n "$wide" && "$wide" != "$cidr" ]]; then
            cidr="$wide"; tried_wide=1; save_mode=1
        fi
    fi

    while :; do
        if ! scanner_scan "$cidr" "$save_mode"; then
            # 扫描本身没有合格站点：/24 时也扩到 /21 再试一次。
            if [[ "$cidr" == */24 ]] && (( tried_wide == 0 )); then
                wide="$(cidr_truncate "${cidr%%/*}" 21)" || wide=""
                if [[ -n "$wide" && "$wide" != "$cidr" ]]; then
                    warn "$cidr 无合格候选，扩大到同机房 $wide 再试一次"
                    cidr="$wide"; tried_wide=1; save_mode=1
                    continue
                fi
            fi
            return 1
        fi

        # 扩到 /21 后候选变多，放宽 require-tfo 的探测池上限。
        if (( tried_wide == 1 )); then pool_arg="$SCANNER_TFO_POOL_WIDE"; fi
        if best="$(scanner_shortlist "$require_tfo" "$SCANNER_SHORTLIST" "$pool_arg")"; then
            printf '%s\n' "$best"
            return 0
        fi

        # require-tfo 过滤为空且 /21 还没试过：自动扩网段再扫。
        if (( require_tfo == 1 )) && [[ "$cidr" == */24 ]] && (( tried_wide == 0 )); then
            wide="$(cidr_truncate "${cidr%%/*}" 21)" || wide=""
            if [[ -n "$wide" && "$wide" != "$cidr" ]]; then
                warn "$cidr 里没有支持被动 TFO 的站点，自动扩大到 $wide 再扫一次"
                cidr="$wide"; tried_wide=1; save_mode=1; pool_arg="$SCANNER_TFO_POOL_WIDE"
                continue
            fi
        fi
        break
    done

    if (( require_tfo == 1 )); then
        err "扫描完成，但所扫网段里没有支持被动 TFO 的候选（xhy scan --list 可看每个站点的 TFO 标记）" >&2
        err "已自动试过 /24 与 /21；可去掉 --require-tfo 按质量选，或 xhy scan --cidr <其它网段> --require-tfo" >&2
    else
        err "扫描完成但没有可用站点（xhy scan --list 查看候选与失败原因）" >&2
    fi
    return 1
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
    TFO=""; MASQ_MODE=""
    while IFS= read -r line; do
        # Keys may contain digits (PIN_B64, BRUTAL_UP); [A-Z_]+ would silently
        # skip them and produce an empty pinSHA256 in the share link.
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            MODE|PORT|PUBLIC|UUID|NODE_PATH|NODE_HOST|SNI|TARGET|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|FP|CF_DOMAIN|CF_TOKEN_SET|SECURITY|CREATED|PROTO|AUTH|CERT_FILE|KEY_FILE|PIN_B64|PIN_HEX|MASQ_URL|BRUTAL_UP|BRUTAL_DOWN|TFO|MASQ_MODE)
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
    [[ "$lvl" == "none" ]] && { printf '{"loglevel":"none"}'; return 0; }
    dir="$(json_escape "$XHY_LOGDIR")"
    # access log 记录每条连接的源 IP + 时间 + 目标，纯转发服务器不需要，
    # 且是磁盘 IO 与隐私的双重负担。排障时 `xhy config set ACCESS_LOG on`。
    if [[ "$(state_get ACCESS_LOG off)" == "on" ]]; then
        printf '{"loglevel":"%s","access":"%s/xray-access.log","error":"%s/xray-error.log"}' \
            "$lvl" "$dir" "$dir"
    else
        printf '{"loglevel":"%s","access":"none","error":"%s/xray-error.log"}' \
            "$lvl" "$dir"
    fi
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

policy_json() {
    # bufferSize 单位 KB，是每连接单向缓冲。默认 512；跨境高 BDP 链路可调到
    # 1024，但 1G 内存机器上 1024 × 2 方向 × 200 并发就是 400MB，别盲目加。
    # stats* 全关：REALITY / hy2 都是单用户或小规模，流量统计只会白烧内存。
    printf '{"levels":{"0":{"handshake":4,"connIdle":300,"uplinkOnly":2,"downlinkOnly":5,"bufferSize":%s}},"system":{"statsInboundUplink":false,"statsInboundDownlink":false,"statsOutboundUplink":false,"statsOutboundDownlink":false}}' \
        "$(state_get BUFFER_SIZE 512)"
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
        printf '  "outbounds": %s,\n' "$(outbounds_json)"
        printf '  "policy": %s\n}\n' "$(policy_json)"
    } | atomic_write "$XHY_ETC/config.json" 0600
    ok "配置已重建: $XHY_ETC/config.json ($(node_count) 个节点)"
}

sniffing_json() {
    local override='["tls"]'
    case "${MODE:-}" in
        # 明文 WS：只有 http 头可嗅探
        direct|tunnel) override='["http","tls"]' ;;
        # hy2 自身就是 QUIC，再解析一次 quic 是纯开销
        hy2)           override='["tls"]' ;;
        # reality / xhttp --reality：全程 TLS 1.3
        *)             override='["tls"]' ;;
    esac
    printf '"sniffing":{"enabled":true,"destOverride":%s,"routeOnly":true}' "$override"
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
    "wsSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}" },
    $(sockopt_json)
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
    "wsSettings": { "path": "${NODE_PATH}", "host": "${CF_DOMAIN}" },
    $(sockopt_json)
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
    },
    $(sockopt_json)
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
    "xhttpSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}", "mode": "auto" },
    $(sockopt_json)
  },
  $(sniffing_json)
}
EOF
}

# Xray's native Hysteria2 inbound (v26.3.27+). Verified with `xray run -test`:
# protocol "hysteria", version 2, network "hysteria", security "tls", alpn h3.
render_hy2() {
    local qp="" masq masq_block
    [[ -n "$BRUTAL_UP" ]] && qp="\"brutalUp\": \"${BRUTAL_UP}\""
    if [[ -n "$BRUTAL_DOWN" ]]; then
        [[ -n "$qp" ]] && qp+=", "
        qp+="\"brutalDown\": \"${BRUTAL_DOWN}\""
    fi
    masq="$(json_escape "$MASQ_URL")"
    if [[ "${MASQ_MODE:-string}" == "proxy" ]]; then
        # 反代真站最像，但被扫描时未认证流量会经你机器转发 = 拿你的带宽
        masq_block="\"masquerade\": { \"type\": \"proxy\", \"url\": \"${masq}\", \"rewriteHost\": true }"
    else
        masq_block="\"masquerade\": { \"type\": \"string\", \"statusCode\": 200, \"headers\": { \"content-type\": [\"text/html\"] }, \"content\": \"<html><head><title>Welcome to nginx!</title></head><body><h1>Welcome to nginx!</h1></body></html>\" }"
    fi
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
      ${masq_block}
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
#                    [--scan] [--scan-cidr CIDR] [--scan-refresh]
#                    [--masq-proxy] [--tfo auto|on|off]
node_add() {
    local mode="$1" port="$2"; shift 2
    local host="" path="" sni="" target="" token="" domain="" uuid="" with_reality="0"
    local masq="" up="" down=""
    local use_scan="0" scan_cidr="" scan_refresh="0"
    local masq_mode="string" tfo_opt="auto" tfo_val="0"
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
            --tfo)    tfo_opt="$2"; shift 2 ;;
            --masq-proxy) masq_mode="proxy"; shift ;;
            --reality) with_reality="1"; shift ;;
            --scan)        use_scan="1"; shift ;;
            --scan-cidr)   scan_cidr="$2"; shift 2 ;;
            --scan-refresh) scan_refresh="1"; shift ;;
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

    # 自动扫描伪装站（--scan）。放在这里而不是各分支里：reality 与
    # xhttp --reality 都走同一段解析，扫出来的结果就是普通的 --target/--sni，
    # 后面的校验、渲染、回滚逻辑完全不用改。
    if [[ "$use_scan" == "1" && -z "$target" ]]; then
        if [[ "$mode" != "reality" && "$with_reality" != "1" ]]; then
            warn "--scan 只对 REALITY 类节点有意义（reality / xhttp --reality），已忽略"
        else
            local -a scargs=()
            local sp sl
            if [[ "$scan_refresh" == "1" ]]; then scargs+=(--refresh); fi
            if [[ -n "$scan_cidr" ]]; then scargs+=(--cidr "$scan_cidr"); fi
            if sp="$(scanner_pick ${scargs[@]+"${scargs[@]}"})"; then
                read -r target sni sl <<<"$sp"
                info "自动扫描选中: target=$target SNI=$sni（来源 scan${sl:+ $sl}）"
            else
                warn "自动扫描没有找到可用站点，回退到内置伪装站库"
                target=""
            fi
        fi
    fi

    local public=1 priv="" pub="" sid="" tgt="" t_sni="" label="" security="none"
    local pairs=() picked="" kp=""
    if [[ -n "$target" && "$target" != *:* ]]; then target="${target}:443"; fi

    case "$mode" in
        reality)
            if [[ -n "$target" ]]; then
                tgt="$target"; t_sni="${sni:-${target%%:*}}"
                if is_ip_literal "${tgt%%:*}" && [[ -z "$sni" ]]; then
                    die "target 是 IP 时必须同时给 --sni 域名（dest=IP、SNI=域名，例：--target 1.2.3.4:443 --sni www.example.com）"
                fi
                target_validate "$tgt" "$t_sni" || confirm "校验未通过，仍要使用？" "n" || return 1
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
            tfo_val="$(tfo_decide "$tfo_opt" "${tgt%%:*}" "${tgt##*:}" "$t_sni")"
            if [[ "$tfo_val" == "1" ]]; then
                info "伪装站支持 TFO → 本节点 tcpFastOpen=true（--tfo off 可覆盖）"
            else
                info "伪装站不支持 TFO → 本节点 tcpFastOpen=false（--tfo on 可覆盖）"
            fi
            pairs=(
                "MODE=reality" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=$t_sni" "TARGET=$tgt"
                "PRIVATE_KEY=$priv" "PUBLIC_KEY=$pub" "SHORT_ID=$sid"
                "FP=chrome" "SECURITY=reality" "TFO=$tfo_val" "CREATED=$(date -Is)"
            ) ;;
        xhttp)
            if [[ "$with_reality" == "1" || -n "$target" ]]; then
                security="reality"
                if [[ -n "$target" ]]; then
                    tgt="$target"; t_sni="${sni:-${target%%:*}}"
                    if is_ip_literal "${tgt%%:*}" && [[ -z "$sni" ]]; then
                        die "target 是 IP 时必须同时给 --sni 域名（dest=IP、SNI=域名）"
                    fi
                    target_validate "$tgt" "$t_sni" || confirm "校验未通过，仍要使用？" "n" || return 1
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
            tfo_val="$(tfo_decide "$tfo_opt" "${tgt:-}" "${tgt##*:}" "${t_sni:-$host}")"
            pairs=(
                "MODE=xhttp" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=${t_sni:-$host}" "TARGET=${tgt:-}"
                "PRIVATE_KEY=${priv:-}" "PUBLIC_KEY=${pub:-}" "SHORT_ID=${sid:-}"
                "FP=chrome" "SECURITY=$security" "TFO=$tfo_val" "CREATED=$(date -Is)"
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
            if [[ -n "$up" || -n "$down" ]]; then
                warn "Brutal 会无视丢包、按设定速率持续发包：按流量计费的实例会产生真实账单，"
                warn "共享/突发带宽实例可能被云厂商限速或判定滥用。仅在带宽独占时使用。"
            fi
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$port" "$hy2sni")"
            [[ -s "$crt" && -s "$key" ]] || die "Hysteria2 自签证书生成失败"
            pairs=(
                "MODE=hy2" "PORT=$port" "PUBLIC=1" "PROTO=udp"
                "UUID=$uuid" "AUTH=$uuid" "NODE_HOST=$host"
                "SNI=$hy2sni" "CERT_FILE=$crt" "KEY_FILE=$key"
                "PIN_B64=$pin64" "PIN_HEX=$pinhex" "MASQ_URL=$masq_url"
                "BRUTAL_UP=$up" "BRUTAL_DOWN=$down"
                "TFO=0" "MASQ_MODE=$masq_mode"
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

# ---------------------------------------------------------------------------
# node editing
# ---------------------------------------------------------------------------

# node_env_update <env-file> KEY=VALUE...
# 就地改写注册表：命中的键替换，其余行（含注释与将来新增的字段）原样保留，
# 新键追加到末尾。不要「重新拼一遍 pairs」——那样会顺手丢掉后来加的键。
node_env_update() {
    local f="$1"; shift
    local -A kv=()
    local pair k line
    local -a out=()
    for pair in "$@"; do kv["${pair%%=*}"]="${pair#*=}"; done
    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            k="${BASH_REMATCH[1]}"
            if [[ -n "${kv[$k]+x}" ]]; then
                out+=("$k=${kv[$k]}")
                unset 'kv[$k]'
                continue
            fi
        fi
        out+=("$line")
    done <"$f"
    for k in "${!kv[@]}"; do out+=("$k=${kv[$k]}"); done
    printf '%s\n' "${out[@]}" | atomic_write "$f" 0600
}

# node_edit_apply MODE PORT KEY=VALUE...
# 落盘 + 重建 + 校验 + 重启。改端口等于重命名注册表文件；hy2 改端口或 SNI
# 必须重签证书（文件名带端口、SAN 带 SNI），否则客户端的 pinSHA256 会失配。
node_edit_apply() {
    local mode="$1" port="$2"; shift 2
    local old_envf new_envf new_mode="$mode" new_port="$port"
    local o_sni="" o_cert="" o_key="" pair clash=""
    need_root
    init_dirs
    old_envf="$(node_file "$mode" "$port")"
    [[ -f "$old_envf" ]] || die "节点不存在: ${mode}_${port}"
    node_load "$old_envf"
    o_sni="$SNI"; o_cert="$CERT_FILE"; o_key="$KEY_FILE"

    for pair in "$@"; do
        case "${pair%%=*}" in
            PORT) new_port="${pair#*=}" ;;
            MODE) new_mode="${pair#*=}" ;;
        esac
    done
    valid_port "$new_port" || die "端口不合法: $new_port"
    if [[ "$new_port" != "$port" ]]; then
        clash="$(port_used_by_node "$new_port")" || true
        if [[ -n "$clash" && "$clash" != "${mode}_${port}" ]]; then
            die "端口 $new_port 已被节点 $clash 占用（不同模式也不能共用端口）"
        fi
        if port_busy "$new_port"; then
            warn "端口 $new_port 已被其它进程占用（可能是旧进程尚未退出）"
            confirm "仍要继续？" "n" || return 1
        fi
    fi

    backup_file "$old_envf"
    snapshot_state
    node_env_update "$old_envf" "$@"

    if [[ "$new_port" != "$port" ]]; then
        new_envf="$(node_file "$new_mode" "$new_port")"
        mv -f "$old_envf" "$new_envf"
        rm -f "$(node_frag "$mode" "$port")"
    else
        new_envf="$old_envf"
    fi

    node_load "$new_envf"
    if [[ "$MODE" == "hy2" ]]; then
        if [[ "$PORT" != "$port" ]] || [[ "$SNI" != "$o_sni" ]]; then
            local crt key pin64 pinhex
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$PORT" "$SNI")" || return 1
            node_env_update "$new_envf" "CERT_FILE=$crt" "KEY_FILE=$key" \
                "PIN_B64=$pin64" "PIN_HEX=$pinhex"
            if [[ -n "$o_cert" && "$o_cert" != "$crt" && -f "$o_cert" ]]; then
                rm -f "$o_cert" "$o_key"
            fi
            info "已按新的端口 / SNI 重签 Hysteria2 证书，客户端的 pinSHA256 需要更新"
        fi
    fi

    if ! write_fragment "$new_envf"; then
        err "inbound 配置生成失败；节点参数已写入，可用 xhy snapshots + xhy rollback 回退"
        return 1
    fi
    if ! XHY_SKIP_SNAPSHOT=1 rebuild_config || ! xray_config_test; then
        err "配置校验失败；节点参数已写入但未生效，可用 xhy snapshots + xhy rollback 回退"
        return 1
    fi
    config_reload || warn "配置已写入，但服务重启失败（可 xhy service restart 重试）"
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    fi
    ok "节点 ${new_mode}_${new_port} 已更新"
    link_from_env "$new_envf" 2>/dev/null || true
    return 0
}

# node_edit [MODE PORT]
# 交互式编辑：先列出全部当前值，逐项回车即保持。只对相关模式询问相关字段。
node_edit() {
    local mode="${1:-}" port="${2:-}"
    need_root
    init_dirs
    if [[ -z "$mode" || -z "$port" ]]; then
        node_pick || return 1
        mode="$MODE"; port="$PORT"
    fi
    local envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    node_load "$envf"

    local o_port="$PORT" o_uuid="$UUID" o_path="$NODE_PATH" o_host="$NODE_HOST"
    local o_sni="$SNI" o_tgt="$TARGET" o_fp="$FP" o_sec="$SECURITY" o_sid="$SHORT_ID"
    local o_masq="$MASQ_URL" o_masqmode="$MASQ_MODE" o_up="$BRUTAL_UP" o_down="$BRUTAL_DOWN"
    local -a changes=()
    local v cur_tfo tfo_choice="" new_tgt new_sni pair

    cur_tfo="false"; [[ "$TFO" == "1" ]] && cur_tfo="true"
    printf '\n'
    printf '节点 %s_%s（%s）\n' "$mode" "$port" "${o_sec:-none}"
    printf '  %-14s %s\n' '连接地址' "${o_host:-?}"
    printf '  %-14s %s\n' 'UUID' "${o_uuid:-?}"
    printf '  %-14s %s\n' '路径' "${o_path:-?}"
    if [[ "$o_sec" == "reality" ]]; then
        printf '  %-14s %s\n' 'target' "${o_tgt:-?}"
        printf '  %-14s %s\n' 'SNI' "${o_sni:-?}"
        printf '  %-14s %s\n' 'shortId' "${o_sid:-?}"
        printf '  %-14s %s（当前 tcpFastOpen=%s）\n' '指纹 / TFO' "${o_fp:-chrome}" "$cur_tfo"
    elif [[ "$o_sec" == "tls" ]]; then
        printf '  %-14s %s\n' 'SNI' "${o_sni:-?}"
        printf '  %-14s %s（%s）\n' '伪装' "${o_masq:-?}" "${o_masqmode:-string}"
        printf '  %-14s up=%s down=%s\n' 'Brutal' "${o_up:-off}" "${o_down:-off}"
    fi
    printf '\n直接回车 = 保持原值。\n'

    v="$(ask '端口' "$o_port")"
    [[ "$v" != "$o_port" ]] && changes+=("PORT=$v")
    v="$(ask '连接地址（域名或 IP）' "$o_host")"
    [[ "$v" != "$o_host" ]] && changes+=("NODE_HOST=$v")
    v="$(ask 'UUID（输入 new 重新生成）' "$o_uuid")"
    if [[ "$v" == "new" ]]; then changes+=("UUID=$(uuid_gen)")
    elif [[ "$v" != "$o_uuid" ]]; then changes+=("UUID=$v"); fi
    v="$(ask '路径' "$o_path")"
    if [[ -n "$v" && "$v" != "$o_path" ]]; then
        [[ "$v" == /* ]] || v="/$v"
        changes+=("NODE_PATH=$v")
    fi

    case "$o_sec" in
        reality)
            v="$(ask '伪装站 target（IP:端口 或 域名:端口）' "$o_tgt")"
            [[ "$v" != "$o_tgt" ]] && changes+=("TARGET=$v")
            v="$(ask 'SNI（target 是 IP 时必填域名）' "$o_sni")"
            [[ "$v" != "$o_sni" ]] && changes+=("SNI=$v")
            v="$(ask 'shortId（输入 new 重新生成，客户端需同步）' "$o_sid")"
            if [[ "$v" == "new" ]]; then changes+=("SHORT_ID=$(rand_hex 8)")
            elif [[ "$v" != "$o_sid" ]]; then changes+=("SHORT_ID=$v"); fi
            v="$(ask '指纹 fp' "$o_fp")"
            [[ "$v" != "$o_fp" ]] && changes+=("FP=$v")
            tfo_choice="$(ask 'TFO auto/on/off（auto = 按新 target 重新探测）' 'auto')" ;;
        tls)
            v="$(ask 'SNI（改这个会重签自签证书）' "$o_sni")"
            [[ "$v" != "$o_sni" ]] && changes+=("SNI=$v")
            v="$(ask '伪装 URL' "$o_masq")"
            [[ "$v" != "$o_masq" ]] && changes+=("MASQ_URL=$v")
            v="$(ask '伪装模式 string/proxy' "$o_masqmode")"
            [[ "$v" != "$o_masqmode" ]] && changes+=("MASQ_MODE=$v")
            v="$(ask 'Brutal 上行 Mbps（空=不启用）' "$o_up")"
            [[ "$v" != "$o_up" ]] && changes+=("BRUTAL_UP=$v")
            v="$(ask 'Brutal 下行 Mbps（空=不启用）' "$o_down")"
            [[ "$v" != "$o_down" ]] && changes+=("BRUTAL_DOWN=$v") ;;
    esac

    if (( ${#changes[@]} == 0 )); then
        info "没有改动"
        return 0
    fi

    # TFO 必须在 TARGET/SNI 定稿之后再算：auto 要探测的是新目标，不是旧的。
    if [[ "$o_sec" == "reality" ]]; then
        new_tgt="$o_tgt"; new_sni="$o_sni"
        for pair in "${changes[@]}"; do
            case "${pair%%=*}" in
                TARGET) new_tgt="${pair#*=}" ;;
                SNI)    new_sni="${pair#*=}" ;;
            esac
        done
        case "$tfo_choice" in
            on)   changes+=("TFO=1") ;;
            off)  changes+=("TFO=0") ;;
            auto) changes+=("TFO=$(tfo_decide auto "${new_tgt%%:*}" "${new_tgt##*:}" "$new_sni")") ;;
        esac
    fi

    printf '\n将要修改：\n'
    for pair in "${changes[@]}"; do printf '  %s\n' "$pair"; done
    confirm "确认应用？" "y" || return 1
    node_edit_apply "$mode" "$port" "${changes[@]}"
}

# node_retarget MODE PORT TARGET SNI [auto|on|off]
# 换伪装站：REALITY 私钥与 shortId 不受影响，只换 TARGET/SNI 并重判 TFO。
node_retarget() {
    local mode="$1" port="$2" tgt="$3" sni="$4" tfo_opt="${5:-auto}"
    local envf tfo_val
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || { err "节点不存在: ${mode}_${port}"; return 1; }
    node_load "$envf"
    [[ "$SECURITY" == "reality" ]] || { err "只有 REALITY 节点有伪装站（当前 $SECURITY）"; return 1; }
    [[ -n "$tgt" ]] || { err "target 为空"; return 1; }
    [[ "$tgt" == *:* ]] || tgt="${tgt}:443"
    sni="${sni:-${tgt%%:*}}"
    tfo_val="$(tfo_decide "$tfo_opt" "${tgt%%:*}" "${tgt##*:}" "$sni")"
    info "${mode}_${port}: target=${tgt} SNI=${sni} TFO=${tfo_val}"
    node_edit_apply "$mode" "$port" "TARGET=$tgt" "SNI=$sni" "TFO=$tfo_val"
}

# node_retarget_menu TARGET SNI
# 扫描出更好的伪装站之后，问要不要套用到已有的 REALITY 节点上。
# 支持 all / 逗号分隔的多选 / 单个编号；回车 = 一个都不换。
node_retarget_menu() {
    local tgt="$1" sni="$2"
    local -a modes=() ports=() tgts=() snis=()
    local f i=0 pick item
    local -a sel=()
    if [[ -z "$tgt" ]]; then
        info "没有新的伪装站可应用"
        return 0
    fi
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        node_load "$f"
        [[ "$SECURITY" == "reality" ]] || continue
        modes+=("$MODE"); ports+=("$PORT"); tgts+=("$TARGET"); snis+=("$SNI")
    done
    if (( ${#ports[@]} == 0 )); then
        info "当前没有 REALITY 节点，新伪装站已记为默认 target，下次新建节点会用"
        return 0
    fi

    printf '\n  新伪装站: target=%s SNI=%s\n' "$tgt" "$sni"
    printf '  已存在的 REALITY 节点：\n'
    printf '  %-3s %-16s %-34s %s\n' "#" "节点" "当前 target" "当前 SNI"
    printf '  %s\n' "--------------------------------------------------------------------------"
    for (( i = 0; i < ${#ports[@]}; i++ )); do
        printf '  %-3s %-16s %-34s %s\n' "$((i + 1))" "${modes[$i]}_${ports[$i]}" \
            "${tgts[$i]:-?}" "${snis[$i]:-?}"
    done
    pick="$(ask '替换哪些（all / 1,3 / 回车=不换）' '')"
    [[ -n "$pick" ]] || { info "保持原 target 不变"; return 0; }

    if [[ "$pick" == "all" ]]; then
        for (( i = 0; i < ${#ports[@]}; i++ )); do sel+=("$i"); done
    else
        local IFS_BAK="$IFS"
        IFS=','
        for item in $pick; do
            item="${item// /}"
            if [[ "$item" =~ ^[0-9]+$ ]] && (( item >= 1 && item <= ${#ports[@]} )); then
                sel+=("$((item - 1))")
            fi
        done
        IFS="$IFS_BAK"
    fi
    if (( ${#sel[@]} == 0 )); then
        warn "没有匹配的编号，未做任何替换"
        return 0
    fi

    local rc=0
    for i in "${sel[@]}"; do
        printf '\n'
        info "替换 ${modes[$i]}_${ports[$i]} 的伪装站…"
        node_retarget "${modes[$i]}" "${ports[$i]}" "$tgt" "$sni" auto || {
            warn "${modes[$i]}_${ports[$i]} 替换失败，已跳过"
            rc=1
        }
    done
    if (( rc == 0 )); then
        ok "已完成 ${#sel[@]} 个节点的伪装站替换"
    fi
    return "$rc"
}

# 交互式选择节点：列出编号 → 选中后把该节点的字段载入全局 MODE/PORT 等。
# 供菜单「编辑 / 删除节点」与不带参数的 `xhy del` 使用；取消返回 1。
node_pick() {
    local -a files=()
    local f i=0 pick
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        files+=("$f")
    done
    if (( ${#files[@]} == 0 )); then
        warn "暂无节点"
        return 1
    fi
    printf '  %-3s %-8s %-6s %-30s %s\n' "#" "模式" "端口" "连接地址 / SNI" "创建时间"
    printf '  %s\n' "-------------------------------------------------------------------------"
    for f in "${files[@]}"; do
        node_load "$f"
        i=$((i + 1))
        printf '  %-3s %-8s %-6s %-30s %s\n' "$i" "$MODE" "$PORT" \
            "${SNI:-${NODE_HOST:-?}}" "${CREATED:-?}"
    done
    pick="$(ask '选择节点编号（回车取消）' '')"
    [[ -n "$pick" ]] || return 1
    if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
        err "请输入数字编号"
        return 1
    fi
    if (( pick < 1 || pick > ${#files[@]} )); then
        err "编号超出范围（1-${#files[@]}）"
        return 1
    fi
    node_load "${files[$((pick - 1))]}"
    ok "已选择节点 ${MODE}_${PORT}"
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
    # 备份只打包配置（config.json / nodes / confs / certs / state.env），
    # 二进制与 geoip/geosite 不入档 —— 它们能重新下载，且 65 MB 在小盘上是灾难。
    disk_need 15 "打包配置备份" || die "已中止：先腾出空间再备份"
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

# ---------------------------------------------------------------------------
# xhy clean — 小盘 VPS 的救命命令
# ---------------------------------------------------------------------------
# 根分区 400-500 MB 的机型（阿里云/腾讯云的入门配置很常见）最容易被这里塞满：
# 切一次 `xhy core channel` 就多一个 ~30 MB 的旧二进制副本，再叠加手工备份，
# 盘一满 sshd 就写不了会话文件 —— 症状是「SSH 突然连不上、但代理还能用」。
# 只保留最近若干份，其余删除。

# 删除一组文件，逐个报体积，并把「删了几个 / 释放多少」累加到 _CLEAN_N / _CLEAN_KB。
# 为什么不拿 df 前后相减：df 粒度 1 MB，删掉零星零字节残留会显示「释放 0 MB」，
# 看上去像什么都没删（v1.6.1 在 47.88.102.45 上就报过这个数）。
# 一组文件合计多少 KB（不删除，只统计）。
_clean_sum() {
    local f total=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        total=$(( total + $(file_kb "$f") ))
    done
    printf '%s' "$total"
}

_clean_drop() {
    local label="$1"; shift
    local f kb total=0 cnt=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        kb="$(file_kb "$f")"
        if rm -rf "$f" 2>/dev/null; then
            total=$(( total + kb )); cnt=$(( cnt + 1 ))
            printf '  - %-40s %s\n' "$(basename "$f")" "$(human_kb "$kb")"
        else
            warn "删除失败（仍在占用？）：$f"
        fi
    done
    _CLEAN_N=$(( _CLEAN_N + cnt ))
    _CLEAN_KB=$(( _CLEAN_KB + total ))
    (( cnt > 0 )) && ok "删除${label} $cnt 个，释放 $(human_kb "$total")"
    return 0
}

# 11-07 事故当晚手工装的 /etc/periodic/daily/xhy-backup-prune 已被 xhy clean 取代。
# 它的保留策略是「二进制留 1 份」，与新策略（默认 0 份）直接冲突 —— 留着会让
# 35 MB 的旧二进制永远爬回来。移进 /root 而不是删除，留一条回头路。
_clean_legacy_hook() {
    local h dst
    h="$(legacy_prune_hook)"
    [[ -f "$h" ]] || return 0
    # 就放在原地改名：run-parts 会跳过含 '.' 的条目，它从此不会再被执行，
    # 想回滚只需 mv 回去（放到 /root 反而要跨目录搬 2 KB）。
    dst="$(dirname "$h")/xhy-backup-prune.retired-$(date +%Y%m%d%H%M%S)"
    if mv "$h" "$dst" 2>/dev/null; then
        ok "摘掉事故期遗留的定时任务 /etc/periodic/daily/xhy-backup-prune（已由 xhy clean 取代）"
        info "如需回滚：mv $dst /etc/periodic/daily/xhy-backup-prune"
    else
        warn "遗留定时任务仍在：$h —— 它会把旧二进制留成 35 MB 常驻，建议手工删"
    fi
    return 0
}

cmd_clean() {
    local what="${1:-all}" keep_bin="${XHY_BACKUP_CORE:-0}" keep_snap=5 keep_bak=20 keep_tar=3 keep_big=2
    local before after f i k p
    local _keep=0
    local -a bins=() rt=() snaps=() baks=() bigs=() tars=() drop=()
    local -A fbseen=()
    need_root
    init_dirs
    _CLEAN_N=0
    _CLEAN_KB=0

    case "$what" in
        all|backups|snapshots|tarballs|tmp) ;;
        *) die "用法：xhy clean [all|backups|snapshots|tarballs|tmp]" ;;
    esac

    before="$(disk_free_mb /)"
    # 清 anything 之前先摘掉过时的定时钩子，免得它半夜把二进制又搬回来。
    [[ "$what" == "all" || "$what" == "backups" ]] && _clean_legacy_hook

    # 二进制备份 = xray-<版本>-<14 位时间戳>。
    # xray-rollback.* 是 update_core 的临时副本，中断时会留零字节文件；它同样匹配
    # xray-*，混在一起排序会让「最新一份」变成 0 字节残留，真正的 30 MB 备份反被删。
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
            xray-rollback.*) rt+=("$f") ;;
            *)               bins+=("$f") ;;
        esac
    done < <(ls -1t "$XHY_BACKUP"/xray-* 2>/dev/null || true)
    while IFS= read -r f; do [[ -e "$f" ]] && snaps+=("$f"); done \
        < <(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null || true)
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        # 大体积 .bak（geoip.dat / geosite.dat 这类十几 MB 的数据文件）单独算：
        # 「.bak 留 20 份」对它们等于永不清理，一次 geodata 更新就留 30 MB。
        # 而它们本来就能重新下载，留最新 2 份足够回退。
        if (( $(file_kb "$f") >= 2048 )); then
            bigs+=("$f")
        else
            baks+=("$f")
        fi
    done < <(ls -1t "$XHY_BACKUP"/*.bak 2>/dev/null || true)
    while IFS= read -r f; do [[ -e "$f" ]] && tars+=("$f"); done \
        < <(ls -1t "$XHY_BACKUP"/xhy-backup-*.tar.gz "$XHY_BACKUP"/pre-restore-* 2>/dev/null || true)

    printf '\n清理前：根分区剩余 %s MB\n' "$before"
    printf '  备份目录 %s / 快照目录 %s\n' \
        "$(human_kb "$(file_kb "$XHY_BACKUP")")" "$(human_kb "$(file_kb "$XHY_SNAPSHOTS")")"
    printf '  二进制备份 %d 个 / 临时副本 %d 个 / 状态快照 %d 个 / 打包备份 %d 个\n' \
        "${#bins[@]}" "${#rt[@]}" "${#snaps[@]}" "${#tars[@]}"
    printf '  .bak 小文件 %d 个 / 大体积 .bak %d 个（%s）\n' \
        "${#baks[@]}" "${#bigs[@]}" "$(human_kb "$(_clean_sum "${bigs[@]}")")"

    # ---- 临时副本：按定义就是可丢的，不看数量 ----
    if [[ "$what" == "tmp" || "$what" == "backups" || "$what" == "all" ]]; then
        if (( ${#rt[@]} > 0 )); then
            _clean_drop "临时副本残留" "${rt[@]}"
        else
            info "没有临时副本残留"
        fi
    fi

    # ---- 二进制备份：留最新 keep_bin 份 ----
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_bin; i < ${#bins[@]}; i++ )); do drop+=("${bins[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧二进制备份" "${drop[@]}"
        fi
        if (( ${#bins[@]} > 0 )); then
            if (( keep_bin > 0 )); then
                _keep=$(( ${#bins[@]} > keep_bin ? keep_bin : ${#bins[@]} ))
                info "保留 ${_keep} 份二进制备份：$(basename "${bins[0]}")（$(human_kb "$(file_kb "${bins[0]}")")）"
            else
                info "二进制不进备份（可重下）。需要恢复：xhy core channel <版本> && xhy core update"
                info "想留一份保险：XHY_BACKUP_CORE=1 xhy clean"
            fi
        fi
    fi

    # ---- 状态快照：留最新 keep_snap 份（xhy rollback 还要用） ----
    if [[ "$what" == "snapshots" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_snap; i < ${#snaps[@]}; i++ )); do drop+=("${snaps[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧状态快照" "${drop[@]}"
            info "保留最新 $keep_snap 份快照，xhy rollback 仍可用"
        else
            info "状态快照 ${#snaps[@]} 个，未超过保留数 $keep_snap"
        fi
    fi

    # ---- 打包备份（xhy backup / 还原前自动备份）：留最新 keep_tar 份 ----
    if [[ "$what" == "tarballs" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_tar; i < ${#tars[@]}; i++ )); do drop+=("${tars[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧打包备份" "${drop[@]}"
        fi
        if (( ${#tars[@]} > 0 )); then
            info "保留 $(( ${#tars[@]} > keep_tar ? keep_tar : ${#tars[@]} )) 份打包备份（最新一份 $(human_kb "$(file_kb "${tars[0]}")")）"
        fi
    fi

    # ---- 大体积 .bak：可重下的直接删，其余同名留最新 keep_big 份 ----
    # 47.88.102.45 上 63.8 MB 的备份目录里，29.5 MB 是 geoip.dat / geosite.dat 的旧
    # 副本；它们掉进「.bak 留 20 份」就永远清不掉。既然 v1.7 起 geodata 不再进备份，
    # 这些历史残留就是纯垃圾 —— 现用的 dat 在 /usr/local/share/xray，随时可重下。
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for f in "${bigs[@]}"; do
            k="$(basename "$f")"
            k="${k%.bak}"; k="${k%.*}"      # geoip.dat.20261107092534 -> geoip.dat
            if backup_is_redownloadable "$k"; then
                drop+=("$f")                # 可重下的历史副本：一律清掉
                continue
            fi
            fbseen[$k]=$(( ${fbseen[$k]:-0} + 1 ))
            (( ${fbseen[$k]} > keep_big )) && drop+=("$f")
        done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "大体积数据备份（可重新下载）" "${drop[@]}"
        fi
    fi

    # ---- .bak：留最新 keep_bak 份 ----
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_bak; i < ${#baks[@]}; i++ )); do drop+=("${baks[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧 .bak" "${drop[@]}"
        else
            info ".bak ${#baks[@]} 个，未超过保留数 $keep_bak"
        fi
    fi

    after="$(disk_free_mb /)"
    printf '\n清理后：根分区剩余 %s MB\n' "$after"
    if (( _CLEAN_N == 0 )); then
        printf '本次没有删除任何文件（都在保留数内）\n'
    else
        printf '本次删除 %d 个文件，合计 %s' "$_CLEAN_N" "$(human_kb "$_CLEAN_KB")"
        if (( after > before )); then
            printf '；df 增加 %d MB\n' "$(( after - before ))"
        else
            printf '；df 未变（删的多是零字节残留，或文件仍被进程占用）\n'
        fi
    fi

    if (( after < 200 )); then
        warn "余量仍不足 200 MB。备份目录里最大的几份："
        du -k "$XHY_BACKUP"/* 2>/dev/null | sort -rn | head -3 | while read -r k p; do
            printf '  %8s  %s\n' "$(human_kb "$k")" "$(basename "$p")"
        done
        warn "还可清：apk/apt 缓存、/var/log 里的旧日志、手工传上来的 tar 包（/root）"
    fi
    return 0
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

    # 单文件永远装在 /usr/local/bin/xhy。仓库模式下运行的是 $REPO/xhy（XHY_DEV=1），
    # 原地覆盖会把 42 行 dev 入口换成 4307 行 install.sh（版本回退、git 变脏）。
    # 正确做法是往规范路径装：跑一次 update script 就从「git 克隆」变成「单文件直装」，
    # 仓库目录本身不动。
    local canonical="${XHY_BINDIR:-/usr/local/bin}/xhy"
    local repo_mode=0 layout_bad=0 selfreal
    if [[ -f "$XHY_SCRIPT_DIR/build.sh" && -f "$XHY_SCRIPT_DIR/entry/main.sh" ]]; then
        repo_mode=1
        info "检测到仓库模式（$XHY_SCRIPT_DIR）：本次迁移为单文件直装 $canonical（仓库目录本身不动）"
    fi
    if [[ -L "$canonical" ]]; then
        layout_bad=1
    fi
    selfreal="$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")"
    if [[ "$selfreal" != "$(readlink -f "$canonical" 2>/dev/null || printf '%s' "$canonical")" ]]; then
        layout_bad=1
    fi
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
    # `| head -1` 会在 sed 还没写完时关管道，pipefail+errexit 下变成 141(SIGPIPE)
    # 直接把整个升级打死（实测 2026-11-07 22:5x 三台全中）。必须兜住。
    newbuild="$(sed -n 's/^XHY_BUILD="\(.*\)"$/\1/p' "$tmp" | head -1 || true)"
    if [[ -z "$newbuild" ]]; then
        rm -f "$tmp"
        die "下载的脚本里找不到构建号，可能不是本项目的 install.sh，已放弃"
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]] && (( ! layout_bad )); then
        rm -f "$tmp"
        ok "脚本已是最新 ($XHY_VERSION build $newbuild)"
        return 0
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]]; then
        info "已是最新版本，但入口布局需要纠正（旧软链或非规范路径），重装到 $canonical"
    else
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
        elif ! confirm "替换 $canonical 为这个构建？配置与节点数据不受影响。" "y"; then
            rm -f "$tmp"
            info "已取消"
            return 0
        fi
    fi
    reconcile_bin
    # 只备份真正的单文件本体；仓库模式下的 $REPO/xhy 是开发入口，不进备份目录
    if (( ! repo_mode )) && [[ -f "$XHY_SELF" && ! -L "$XHY_SELF" ]]; then
        backup_file "$XHY_SELF"
    fi
    if ! install -m 0755 "$tmp" "$canonical.new" || ! mv -f "$canonical.new" "$canonical"; then
        rm -f "$tmp" "$canonical.new"
        die "替换失败，旧版本仍在 $canonical"
    fi
    rm -f "$tmp"
    _cleanup_legacy_self
    ok "已更新到 build $newbuild（$canonical）"
    if (( layout_bad )); then
        ok "入口布局已纠正：$canonical 现在是单文件实体（非软链）"
    fi
    info "当前进程仍是旧版，下次执行 xhy 生效"
    return 0
}

update_core() {
    need_root
    init_dirs
    local ver rollback="" force="${1:-}"
    [[ "$force" == "--force" ]] || force=""
    ver="$(xray_resolve_version)"
    info "版本通道 $(xray_channel) -> 目标 $ver"

    # 回滚副本是「换核这次事务」的临时保险，不是归档备份（归档备份已取消，
    # 见 xray_install：36 MB 一份且可重下）。它只在换核期间存在，成功/失败都删。
    # 没有副本就不开工 —— 换核是唯一会原地改生产二进制的操作。
    if [[ -x "$XRAY_BIN" ]]; then
        if (( $(disk_free_mb "$XHY_BACKUP") < 100 )); then
            err "根分区余量 $(disk_free_mb "$XHY_BACKUP") MB，不足 100 MB，无法建立回滚副本"
            err "先清理：xhy clean all"
            [[ "$force" == "--force" ]] || die "拒绝在无退路的情况下换核（确要如此：xhy core update --force）"
            warn "--force：跳过回滚副本，换核失败需手动重装旧版本"
        else
            rollback="$(mktemp "$XHY_BACKUP/xray-rollback.XXXXXX" 2>/dev/null || true)"
            if [[ -n "$rollback" ]] && cp -a "$XRAY_BIN" "$rollback"; then :; else rollback=""; fi
            [[ -n "$rollback" ]] || warn "回滚副本创建失败，继续安装（失败需手动重装旧版本）"
        fi
    fi
    xray_install "$ver"
    if [[ -s "$XHY_ETC/config.json" ]] && ! xray_config_test >/dev/null 2>&1; then
        if [[ -n "$rollback" ]]; then
            cp -a "$rollback" "$XRAY_BIN"
            rm -f "$rollback"          # 回滚副本用完就删，别在小盘上留 30 MB
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
    # 两个 dat 解开后约 30 MB，还要余量给 .new。不足就别下，旧文件继续用。
    disk_need 45 "更新 geodata（约 30 MB）" || die "已中止：现有 geo 数据继续生效"
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
    # 服务端本来就该开 BBR：每次重建配置顺手兜底，实测没生效就重新下发。
    # 安装时显式选了「不开」(BBR_ENABLED=off) 的不会被强行打开。
    bbr_ensure || warn "BBR 未生效，可执行 xhy bbr on 复查。"
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
    local _canonical="${XHY_BINDIR:-/usr/local/bin}/xhy" _layout="单文件直装"
    if [[ -L "$_canonical" ]]; then
        _layout="旧软链（下次运行 xhy 会自动迁移）"
    elif [[ "$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")" != "$(readlink -f "$_canonical" 2>/dev/null || printf '%s' "$_canonical")" ]]; then
        _layout="非规范路径（跑一次 xhy update script 会迁移）"
    fi
    printf '入口布局 : %s\n' "$_layout"
    if [[ -e "${XHY_LEGACY_SELF:-/usr/local/lib/xray-hy/xhy}" ]]; then
        printf '遗留本体 : %s（下次运行 xhy 会自动清理）\n' "${XHY_LEGACY_SELF:-/usr/local/lib/xray-hy/xhy}"
    fi
    printf '配置目录 : %s\n' "$XHY_ETC"
    printf '出口 IPv4: %s\n' "$(public_ip || true)"
    local _ip6; _ip6="$(public_ip6 || true)"
    if [[ -n "$_ip6" ]]; then
        printf '出口 IPv6: %s（REALITY/hy2 客户端可直接用它做双栈连接）\n' "$_ip6"
    else
        printf '出口 IPv6: 无\n'
    fi
    local _free _total _low _bk
    _free="$(disk_free_mb /)"
    _total="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $2+0}')"
    _bk="$(human_kb "$(file_kb "$XHY_BACKUP")")"
    # 阈值按机型自适应：427 MB 的机器满载工作也到不了 200 MB，固定阈值的唯一
    # 后果是用户学会无视这行告警（狼来了）。
    if (( _total > 0 && _total < 1024 )); then _low=80; else _low=200; fi
    printf '磁盘余量 : %s MB / 总 %s MB（根分区；备份目录 %s）\n' "$_free" "$_total" "$_bk"
    if (( _free < _low )); then
        warn "根分区余量不足 ${_low} MB：盘满会让 sshd 写不了会话文件、SSH 直接连不上。先跑 xhy clean"
    fi
    # 事故期的手工定时钩子会按旧策略把 35 MB 二进制搬回来，和当前策略打架。
    if [[ -f "$(legacy_prune_hook)" ]]; then
        warn "发现遗留定时任务 $(legacy_prune_hook)（旧策略会保留 1 份二进制）"
        warn "它已被 xhy clean 取代；跑一次 xhy clean all 会自动停用它（原地改名，留一条 mv 回滚）"
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
    if [[ "$mptcp" == "1" ]]; then
        warn "MPTCP 已启用，请执行 xhy bbr on 关闭它（钉死旧版时的关键缓解）"
    fi
    printf '%s\n' "--------------------------------------"
    bbr_status
    printf '%s\n' "--------------------------------------"
    printf 'access日志: %s\n' "$(state_get ACCESS_LOG 'off')"
    printf 'bufferSize: %s KB\n' "$(state_get BUFFER_SIZE 512)"
    printf '端口范围  : %s\n' "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
    # v1.4.3 起 TFO 跟随伪装站（--tfo auto|on|off）；显示现网节点的实际判定，
    # 不再摆一个永远为 0 的「命中数」，也不再写「固定、无开关」那种过时文案。
    local _f _tfo_on=0 _tfo_off=0
    for _f in "$XHY_NODES"/*.env; do
        [[ -f "$_f" ]] || continue
        if grep -q '^TFO=1$' "$_f" 2>/dev/null; then
            _tfo_on=$(( _tfo_on + 1 ))
        else
            _tfo_off=$(( _tfo_off + 1 ))
        fi
    done
    printf 'TFO       : 跟随伪装站（开 %d / 关 %d；--tfo auto|on|off 可覆盖）\n' "$_tfo_on" "$_tfo_off"
    # 探测能力与「节点开没开」是两件事：本机客户端位没开 / 缺 nstat 时，
    # --require-tfo 会把全部候选判成「不支持」，看起来像"全网没人开 TFO"。
    if tfo_probe_ready; then
        printf 'TFO 探测  : 可用（curl --tcp-fastopen + nstat + 客户端位已开）\n'
    else
        printf 'TFO 探测  : 不可用（%s）—— --require-tfo 会恒为空\n' "$(tfo_probe_blocker)"
    fi
    # v1.4.2：tcpcongestion 按内核能力决定写不写，无 bbr 时该字段根本不出现。
    # 这里显示的是**实际渲染结果**而不是"应该是什么"，排查时少一层猜测。
    if sockopt_cc_available; then
        printf 'sockopt   : keepAliveIdle=45 uto=10000 cc=bbr（内核可用）\n'
    else
        printf 'sockopt   : keepAliveIdle=45 uto=10000 cc=继承（内核无 bbr，字段省略）\n'
    fi
    printf '%s\n' "--------------------------------------"
    firewall_status --brief
    if have_cmd ip6tables; then
        v6rules="$(ip6tables -S 2>/dev/null | grep -c "$FW_CHAIN" || true)"
        printf 'IPv6 链规则: %s 条\n' "${v6rules:-0}"
        if [[ "${v6rules:-0}" == "0" ]]; then
            warn "IPv6 未受保护，SSH 可能绕过防爆破"
        fi
    else
        warn "未安装 ip6tables，IPv6 未受保护"
    fi
    printf '%s\n' "--------------------------------------"
    if [[ -x "$SCANNER_BIN" ]]; then
        printf '扫描器   : %s\n' "$SCANNER_BIN"
    else
        printf '扫描器   : 未安装（首次 xhy scan / add --scan 自动下载）\n'
    fi
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
    local total_kb need_mb
    total_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $2}' || true)"
    # 安装本身（xray 36 MB + geodata 30 MB + 包缓存）约需 90 MB 余量。
    # 阈值不再写死 300 MB：427 MB 的机器永远到不了那个数，结果是常年「问题」，
    # 用户学会无视预检 —— 比没有预检更糟。
    if (( ${total_kb:-0} > 0 && ${total_kb:-0} < 1048576 )); then need_mb=90; else need_mb=300; fi
    if (( mem_kb < 131072 )); then
        printf '  [注意] 内存 %s MB 偏小，安装时会设置 GOMEMLIMIT\n' "$((mem_kb / 1024))"
    else
        printf '  [正常] 内存 %s MB\n' "$((mem_kb / 1024))"
    fi
    if (( ${disk_kb:-0} < need_mb * 1024 )); then
        printf '  [问题] 可用磁盘 %s MB，安装至少需要 %s MB\n' "$(( ${disk_kb:-0} / 1024 ))" "$need_mb"
    else
        printf '  [正常] 可用磁盘 %s MB（本机需 %s MB）\n' "$((disk_kb / 1024))" "$need_mb"
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

# ===================== lib/relay.sh =====================
# xray-hy / relay —— 中转（relay）子命令：把「入口机」的 AI/美区流量，经 xray
# 路由转发到「落地机」出口，绕开直连公网绕路（如硅谷 TATA 绕欧洲）。
#
# 两种角色（同一台机器只扮其一）：
#   land  : 落地/接收端（例：硅谷 sanjose）。开一个 vless/tcp 入站，仅放行入口机
#           公网 IP，出站走默认 freedom（直连落地机本地出口）。
#   entry : 入口/转发端（例：东京 tokyo）。把 geosite(ai/美区)+geoip:us 的流量，
#           经 vless 出站转发到落地机的中继端口；其余海外流量本地 freedom 直出。
#
# 配置管线说明（重要，避免与 nodes.sh 冲突）：
#   - land 仅新增一个 confs/relay_in_<port>.json 入站片段，直接复用基础
#     rebuild_config（它把 confs/*.json 拼成 inbounds），不碰 nodes.sh。
#   - entry 需要自定义 outbounds + routing 规则，而基础 rebuild_config 的
#     outbounds/routing 由函数生成、不接受片段。为避免修改 nodes.sh（与「伪装站
#     TFO」开发会话冲突），这里用 relay_rebuild 本地重新拼装：调用基础 json 函数
#     + 注入 us-relay 出站与路由规则，零依赖（不靠 jq/python）。
#   - 限制：基础 rebuild_config 不含 relay。entry 激活后，若又跑 xhy add/del/edit
#     等触发基础 rebuild 的命令，relay 出站/路由会被覆盖；改完节点后跑
#     `xhy relay reapply` 重新注入即可。
#
# 状态存 $XHY_NODES/relay.env（与节点注册同目录，纳入快照）。

# 全局状态变量（relay_env_save 前由各子命令赋值）
RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""

relay_reset_vars() {
    RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
    RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""
}

relay_env_save() {
    init_dirs
    local f="$XHY_NODES/relay.env"
    {
        [[ -n "$RELAY_ROLE" ]]       && echo "RELAY_ROLE=$RELAY_ROLE"
        [[ -n "$RELAY_PORT" ]]       && echo "RELAY_PORT=$RELAY_PORT"
        [[ -n "$RELAY_ALLOW" ]]      && echo "RELAY_ALLOW=$RELAY_ALLOW"
        [[ -n "$RELAY_UUID" ]]       && echo "RELAY_UUID=$RELAY_UUID"
        [[ -n "$RELAY_UPSTREAM" ]]   && echo "RELAY_UPSTREAM=$RELAY_UPSTREAM"
        [[ -n "$RELAY_CATEGORIES" ]] && echo "RELAY_CATEGORIES=$RELAY_CATEGORIES"
        [[ -n "$RELAY_FW_CHAIN" ]]   && echo "RELAY_FW_CHAIN=$RELAY_FW_CHAIN"
    } | atomic_write "$f" 0600
}

relay_env_load() {
    local f="$XHY_NODES/relay.env"
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
    [[ -n "$RELAY_ROLE" ]]
}

# 生成 land 入站片段（符合 confs/*.json 入站片段格式，被 rebuild_config 拼进 inbounds）
relay_fragment() {
    local port="$1" uuid="$2"
    cat <<EOF
{
  "listen": "0.0.0.0", "port": ${port}, "protocol": "vless",
  "tag": "in-relay-${port}",
  "settings": { "clients": [ { "id": "${uuid}" } ], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "none" },
  "sniffing": {"enabled":true,"destOverride":["tls"],"routeOnly":true}
}
EOF
}

# entry 出站（转发到落地机中继端口）
relay_outbounds_json() {
    local up="$RELAY_UPSTREAM" host port
    host="${up%:*}"; port="${up##*:}"
    cat <<EOF
{"protocol":"vless","tag":"us-relay","settings":{"vnext":[{"address":"$host","port":$port,"users":[{"id":"$RELAY_UUID","encryption":"none"}]}]},"streamSettings":{"network":"tcp"}}
EOF
}

# entry 路由规则（注入到 routing.rules 数组最前面）。输出为「逗号分隔的 rule 对象」，无方括号
relay_routing_rules() {
    local cats="$RELAY_CATEGORIES" domains="" sep="" c
    for c in ${cats//,/ }; do
        domains+="$sep\"geosite:$c\""; sep=","
    done
    printf '%s' "{\"type\":\"field\",\"domain\":[$domains],\"outboundTag\":\"us-relay\"},{\"type\":\"field\",\"ip\":[\"geoip:us\"],\"outboundTag\":\"us-relay\"}"
}

# entry 专用重建：调用基础 json 函数 + 注入 relay 出站/路由
relay_rebuild() {
    local joined="" sep="" f
    init_dirs
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    for f in "$XHY_CONFDIR"/*.json; do
        [[ -s "$f" ]] || continue
        joined+="$sep$(cat "$f")"
        sep=","
    done
    # outbounds: 基础 [freedom,blackhole] + relay
    local ob="$(outbounds_json)"
    local ob_inner="${ob#\[}"; ob_inner="${ob_inner%\]}"
    local outbounds="[${ob_inner},$(relay_outbounds_json)]"
    # routing: 基础规则 + 前置 relay 规则
    local rt="$(routing_json)"
    local rt_rules="${rt#*\"rules\":\[}"; rt_rules="${rt_rules%\]*}"
    local new_rules
    if [[ -z "$rt_rules" ]]; then new_rules="$(relay_routing_rules)"
    else new_rules="$(relay_routing_rules),${rt_rules}"; fi
    local routing="{\"domainStrategy\":\"IPIfNonMatch\",\"rules\":[${new_rules}]}"
    {
        printf '{\n  "log": %s,\n' "$(log_json)"
        printf '  "inbounds": [%s],\n' "$joined"
        printf '  "dns": %s,\n' "$(dns_json)"
        printf '  "routing": %s,\n' "$routing"
        printf '  "outbounds": %s,\n' "$outbounds"
        printf '  "policy": %s\n}\n' "$(policy_json)"
    } | atomic_write "$XHY_ETC/config.json" 0600
    ok "配置已重建（含 relay 出站/路由）: $XHY_ETC/config.json"
}

relay_fw_add() {
    local port="$1" allow="$2" chain t
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    if $t -w -L XHY-IN -n >/dev/null 2>&1; then chain=XHY-IN; else chain=INPUT; fi
    $t -w -C "$chain" -p tcp --dport "$port" -s "$allow" -j ACCEPT 2>/dev/null \
        || $t -w -A "$chain" -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT
    RELAY_FW_CHAIN="$chain"
}

relay_fw_del() {
    local port="$1" allow="$2" chain="${3:-XHY-IN}" t
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    $t -w -D "$chain" -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null \
        || $t -w -D INPUT -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null \
        || true
}

relay_cfg_test() {
    if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" run -test -c "$XHY_ETC/config.json" >/dev/null 2>&1; then
        ok "config.json 校验通过"
        return 0
    else
        warn "config.json 校验未通过（xray run -test 失败，检查片段 JSON）"
        return 1
    fi
}

# ---------------------------------------------------------------- 子命令

relay_land() {
    local port=14430 allow="" uuid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2"; shift 2 ;;
            --allow) allow="$2"; shift 2 ;;
            --uuid)  uuid="$2"; shift 2 ;;
            *) die "未知参数: $1（用法: xhy relay land [--port N] [--allow <入口机公网IP>] [--uuid UUID]）" ;;
        esac
    done
    relay_reset_vars
    valid_port "$port" || die "端口不合法: $port"
    port_busy "$port" && die "端口 $port 已被占用"
    [[ -z "$allow" ]] && die "缺少 --allow <入口机公网IP>：落地端只放行该 IP 到中继端口"
    [[ -z "$uuid" ]] && uuid="$(uuid_gen)"
    disk_need 1 "中继入站配置"
    relay_fragment "$port" "$uuid" | atomic_write "$XHY_CONFDIR/relay_in_${port}.json" 0644
    relay_fw_add "$port" "$allow"
    rebuild_config
    RELAY_ROLE=land
    RELAY_PORT="$port"
    RELAY_ALLOW="$allow"
    RELAY_UUID="$uuid"
    RELAY_FW_CHAIN="$RELAY_FW_CHAIN"
    relay_env_save
    relay_cfg_test
    local myip="$(public_ip)"
    ok "中继入站已就绪：${myip}:$port（仅放行 $allow）"
    info "把同一 UUID 带到入口机执行："
    printf '    xhy relay entry --to %s:%s --uuid %s\n' "$myip" "$port" "$uuid"
    printf 'vless://%s@%s:%s?encryption=none#relay-land\n' "$uuid" "$myip" "$port"
}

relay_entry() {
    local upstream="" uuid="" categories="openai,anthropic,google,tiktok,netflix"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) upstream="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --categories) categories="$2"; shift 2 ;;
            *) die "未知参数: $1（用法: xhy relay entry --to <落地IP>:<端口> [--uuid UUID] [--categories a,b,c]）" ;;
        esac
    done
    relay_reset_vars
    [[ "$upstream" == *:* ]] || die "缺少 --to <落地机公网IP>:<端口>"
    [[ -z "$uuid" ]] && uuid="$(uuid_gen)"
    local host="${upstream%:*}" p="${upstream##*:}"
    valid_port "$p" || die "端口不合法: $p"
    disk_need 1 "中继出站配置"
    RELAY_ROLE=entry
    RELAY_UPSTREAM="$upstream"
    RELAY_UUID="$uuid"
    RELAY_CATEGORIES="$categories"
    relay_env_save
    relay_rebuild
    relay_cfg_test
    ok "中继出站已就绪：美区/AI 流量 → $upstream"
    info "落地端用同一 UUID 配置：xhy relay land --allow <本机公网IP> --uuid $uuid"
}

relay_reapply() {
    relay_env_load || die "本机未配置 relay（先跑 xhy relay entry）"
    [[ "$RELAY_ROLE" == "entry" ]] || die "只有入口机需要 reapply"
    relay_rebuild
    ok "已重新注入 relay 出站/路由"
}

relay_status() {
    relay_env_load || { info "本机未配置 relay"; return 0; }
    case "$RELAY_ROLE" in
        land)
            info "角色: 落地(接收端)  端口=$RELAY_PORT  放行源=$RELAY_ALLOW  UUID=$RELAY_UUID"
            ss -H -ltn 2>/dev/null | grep -qE "[:.]${RELAY_PORT}$" && ok "端口 $RELAY_PORT 监听中" || warn "端口 $RELAY_PORT 未监听" ;;
        entry)
            info "角色: 入口(转发端)  落地=$RELAY_UPSTREAM  UUID=$RELAY_UUID  分类=$RELAY_CATEGORIES"
            relay_cfg_test >/dev/null 2>&1 && ok "config.json 含 relay 出站/路由" || warn "config.json 未含 relay（跑 xhy relay reapply）" ;;
    esac
}

relay_test() {
    relay_env_load || { info "本机未配置 relay，无法测试"; return 0; }
    relay_cfg_test || warn "配置校验失败"
    if [[ "$RELAY_ROLE" == "land" ]]; then
        local t=iptables; [[ "$RELAY_ALLOW" == *:* ]] && t=ip6tables
        $t -w -C "${RELAY_FW_CHAIN:-XHY-IN}" -p tcp --dport "$RELAY_PORT" -s "$RELAY_ALLOW" -j ACCEPT >/dev/null 2>&1 \
            && ok "防火墙已放行 $RELAY_ALLOW → :$RELAY_PORT" || warn "防火墙规则缺失"
        ss -H -ltn 2>/dev/null | grep -qE "[:.]${RELAY_PORT}$" && ok "中继端口监听中" || warn "中继端口未监听"
        info "从入口机执行 xhy relay test，并视需要 curl 经本机出口验证"
    else
        local host="${RELAY_UPSTREAM%:*}" p="${RELAY_UPSTREAM##*:}"
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host/$p" 2>/dev/null; then
            ok "入口机能 TCP 连通落地端 $RELAY_UPSTREAM"
        else
            warn "入口机无法 TCP 连通落地端 $RELAY_UPSTREAM（检查落地端防火墙/端口）"
        fi
        info "最终验证：客户端走入口机访问 ipinfo.io 应显示落地端所在地区 IP"
    fi
}

relay_del() {
    relay_env_load || { info "本机无 relay 配置"; return 0; }
    if [[ "$RELAY_ROLE" == "land" ]]; then
        rm -f "$XHY_CONFDIR/relay_in_${RELAY_PORT}.json"
        relay_fw_del "$RELAY_PORT" "$RELAY_ALLOW" "${RELAY_FW_CHAIN:-XHY-IN}"
        rebuild_config
        rm -f "$XHY_NODES/relay.env"
        ok "落地端中继已移除（片段+防火墙+重建）"
    else
        rm -f "$XHY_NODES/relay.env"
        rebuild_config
        ok "入口端 relay 已移除（恢复基础路由）"
    fi
}

cmd_relay() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        land)    relay_land "$@" ;;
        entry)   relay_entry "$@" ;;
        reapply) relay_reapply "$@" ;;
        status)  relay_status "$@" ;;
        test)    relay_test "$@" ;;
        del)     relay_del "$@" ;;
        *)       die "用法: xhy relay <land|entry|reapply|status|test|del>" ;;
    esac
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
# 把「正在运行的这个文件」直装成 /usr/local/bin/xhy（不再嵌套 /usr/local/lib/xray-hy + 软链）。
#   本地文件运行（sh install.sh / ./xhy）：直接复制
#   bash <(curl ...)：BASH_SOURCE 是管道，读不回来，按 XHY_INSTALL_URL 取一份
# 已经在目标位置运行时（开发目录）什么都不做。
install_self() {
    need_root
    local src="${XHY_RUNNING:-}" real="" tmp
    # 软链调用时 BASH_SOURCE 是链接本身。先解析出真身：reconcile_bin 会删掉
    # /usr/local/bin/xhy 这个链接，之后再复制 $src 就复制不到了。旧布局
    # /usr/local/bin/xhy -> /usr/local/lib/xray-hy/xhy 正是这种情况。
    if [[ -n "$src" ]]; then
        real="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
    fi
    reconcile_bin
    install -d -m 0755 "$XHY_APP_DIR" || die "无法创建 $XHY_APP_DIR"
    # 已是规范直装（入口是普通文件、运行的就是它本身）→ 只补权限 + 清孤儿
    if [[ -n "$real" ]] && [[ ! -L "$XHY_SELF" ]] \
       && [[ "$real" == "$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")" ]]; then
        chmod 0755 "$XHY_SELF" 2>/dev/null || true
        _cleanup_legacy_self
        return 0
    fi
    tmp="$XHY_SELF.new.$$"
    if [[ -n "$real" && -f "$real" ]]; then
        install -m 0755 "$real" "$tmp" || die "复制脚本到 $tmp 失败"
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
    _cleanup_legacy_self
}

# 命令入口目录：默认 /usr/local/bin，离线测试用 XHY_BINDIR 指到临时目录，
# 免得测试真的往系统目录里塞软链。
XHY_BINDIR="${XHY_BINDIR:-/usr/local/bin}"

create_symlink() {
    local bindir="${XHY_BINDIR:-/usr/local/bin}"
    # 单文件已直接装在 $bindir/xhy 时不再做软链（否则会变成自指向的环）。
    [[ "$XHY_SELF" == "$bindir/xhy" ]] && { chmod 0755 "$XHY_SELF" 2>/dev/null || true; return 0; }
    install -d -m 0755 "$bindir"
    chmod 0755 "$XHY_SELF"
    ln -sf "$XHY_SELF" "$bindir/xhy"
    ok "命令入口: $bindir/xhy -> $XHY_SELF"
}

# 一键脚本（bash <(curl ...)、wget|sh、sh install.sh）跑完后退出菜单，
# `xhy` 必须能用。以前只有 cmd_install 的 stage 2 会落地脚本本体，而无参数
# 运行走的是菜单，于是「装完了」其实什么都没装 —— 连 /usr/local/bin/xhy
# 都不存在。任何从非安装位置发起的运行，先在这里把本体与入口装上（幂等）。
XHY_BOOTSTRAPPED=0

# 一键脚本（bash <(curl ...)、wget|sh、sh install.sh）跑完后退出菜单，
# `xhy` 必须能用。以前只有 cmd_install 的 stage 2 会落地脚本本体，而无参数
# 运行走的是菜单，于是「装完了」其实什么都没装 —— 连 /usr/local/bin/xhy
# 都不存在。任何从非安装位置发起的运行，先在这里把本体与入口装上（幂等）。
# 统一安装路径：单文件永远直装到 /usr/local/bin/xhy（不再有 git 仓库 / 单文件
# 两套模式抢这个入口；旧软链由 reconcile_bin 在 install_self 里自动摘掉）。
bootstrap_self() {
    local src="${XHY_RUNNING:-}"
    # 已规范直装：入口就是正在运行的本体，且它不是软链 → 什么都不用做（顺手清孤儿）。
    # 注意判据是「字面同一路径」，不能只比 readlink -f：旧布局
    # /usr/local/bin/xhy -> /usr/local/lib/xray-hy/xhy 解析后同样相等，
    # 用解析值比较会永远跳过迁移，机器就永远停在旧路径上。
    if [[ -n "$src" ]] && [[ "$src" == "$XHY_SELF" ]] && [[ ! -L "$XHY_SELF" ]]; then
        _cleanup_legacy_self
        return 0
    fi
    # 仓库开发目录（XHY_DEV=1）：不往系统目录写，避免调试时被悄悄改写。
    # 仓库模式迁移到单文件由 `xhy update script` 显式完成。
    if [[ "${XHY_DEV:-0}" == "1" ]]; then
        return 0
    fi
    install_self
    create_symlink
    XHY_BOOTSTRAPPED=1
    return 0
}

# 是否已完成过完整安装。三样都在才算：Xray 二进制、INSTALLED 状态、命令入口。
# 半安装状态（比如 Xray 装了但 state 没写）会自动补一次完整安装。
xhy_is_installed() {
    [[ -x "$XRAY_BIN" ]] || return 1
    [[ -n "$(state_get INSTALLED '')" ]] || return 1
    [[ -x "${XHY_BINDIR:-/usr/local/bin}/xhy" ]] || return 1
    return 0
}

cmd_lang() {
    local v="${1:-}"
    case "${v,,}" in
        en|zh|auto|"") ;;
        *) die "用法: xhy lang [en|zh|auto]" ;;
    esac
    if [[ -z "$v" ]]; then
        # 这里要走 printf 过滤器：英文模式下这些中文提示同样不能变成方块。
        printf '当前语言 : %s（state: %s）\n' "$XHY_LANG_EFFECTIVE" "$(state_get XHY_LANG auto)"
        printf '  xhy lang en    强制英文（纯 ASCII；云 VNC 控制台中文是小方块时用）\n'
        printf '  xhy lang zh    强制中文\n'
        printf '  xhy lang auto  按终端 / locale 自动判定（默认）\n'
        printf '  单次强制：XHY_LANG=en xhy  或  XHY_ASCII=1 xhy\n'
        return 0
    fi
    state_set XHY_LANG "${v,,}"
    ok "已设置语言为 ${v,,}（下次运行生效；本次可用 XHY_LANG=${v,,} 立即切换）"
}

usage() {
    # 帮助是用户最需要读通的长文本，短语替换会把它切碎，所以单独写一份英文版。
    # 纯 ASCII，不走 xhy_t；中文版继续走原来的 xhy_t <<EOF。
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        cat <<EOF
xray-hy $XHY_VERSION - modular Xray deployment manager (Debian/Ubuntu, Alpine, RHEL)

Usage: xhy <command> [options]

  Install & check
    install                     Full init (script, deps, Xray, service, BBR, firewall)
    preflight                   Pre-install checks (ports/disk/kernel/network/deps)
    check                       Environment report
    version                     Show script version

  Node management
    add <mode> [--port N] [opts]  Add a node
    edit [mode] [port]            Edit a node; no args = pick by number
    list                          List nodes
    link [--all|--uri|--qr]       Export vless:// links
    del [mode] [port]             Delete node; no args = pick by number
    menu                          Interactive menu

    mode: direct | tunnel | reality | xhttp | hy2
    add opts: --host --path --uuid --sni --target --domain --token --reality
              --masq --masq-proxy --up --down   (hy2 only)
              --scan [--scan-cidr CIDR] [--scan-refresh]   (reality only)
              --tfo auto|on|off            (reality/xhttp; auto = follow target)
    Default ports: direct 8080 / tunnel 10086 / reality 443 / xhttp 8081 / hy2 8443(UDP)
    hy2 uses Xray's built-in Hysteria2 inbound (v26.3.27+), self-signed cert + pinSHA256
    hy2 default masquerade is a static page; --masq-proxy proxies a real site
      (looks better, but unauthenticated traffic uses this host's bandwidth)

  Camouflage site auto-scan
    scan [CIDR]                 Scan this rack's subnet, show 3-5 candidates (cached)
    scan --require-tfo          Only TFO-capable sites; otherwise asks once
    scan --list                 Show cached candidates and scores
    scan --verify               Re-verify cached candidates, drop stale ones
    scan --refresh              Ignore cache and rescan
    scan --clear                Clear cache
    How it works: RealiTLScanner enumerates TLS 1.3 + h2 sites in a /24, each is
    validated with its real SNI (cert/redirect/CDN) and scored; the top 3-5 are
    shown for you to pick (scripted calls take the best score).
    TFO is display/filter only, never part of the score: by default we pick by
    quality (TFO-capable sites may still appear); with --require-tfo only
    TFO-capable ones remain. If the /24 (or cache) has no TFO-capable site it
    auto-widens to the /21 of the same rack and rescans once.
    Every candidate is labelled "TFO: yes / no" (live probe, not cached),
    including [ok] lines, the shortlist, scan --list and scan --verify.
    Results go to /etc/xray-hy/scan-cache.tsv (7 days); later REALITY nodes
    reuse it without rescanning. amd64 / arm64 only; other arches use the
    built-in region library.

  Camouflage site / REALITY terms (xhy target -> 6)
    target(dest)   Address the server connects to (IP:port or domain:port).
                   REALITY forwards unauthenticated probes there verbatim, so it
                   must be a real, stable, long-lived HTTPS site.
    SNI            Domain in the client TLS ClientHello; serverNames is Xray's
                   SNI allowlist and must be covered by the target certificate.
    Behind a CDN?  dest = origin IP, SNI stays the domain:
        xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com
    Menu 9) -> 3) manual accepts the same form (1.2.3.4:443,sni=www.example.com);
    validation uses --resolve to hit that IP and verify the cert covers the name.
    Or just xhy scan: auto-scan this rack's subnet and pick the best site (cached).

  TFO (TCP Fast Open) - follows the target by default, can be overridden
    Xray's tcpFastOpen really works (accepts early data in SYN, answers
    cookiereq with a cookie). Whether to enable it depends on the target:
      target supports passive TFO -> auto enables it; probe sees the same
                                    SYN-ACK, and we save 1 RTT
      target does not support it  -> auto disables it; otherwise a probe sending
                                    a cookiereq SYN sees our tfo cookie while the
                                    real site sends none - trivially distinguishable
    auto probes with curl --tcp-fastopen x3 and checks TcpExtTCPFastOpenActive;
    the result is stored in the node env, so config rebuilds do not re-probe.
    --tfo on / off overrides. Clients follow the server: on->on, off->off.
    Note: the target carries no normal proxy traffic (REALITY only forwards
    unauthenticated probes), so its bandwidth/latency do not affect proxy speed;
    scanning does not shrink the candidate pool just to find TFO.

  Config
    config                      Routing / DNS / log menu (or set directly)
    config set KEY VALUE        Change a setting, see KEYs below
    snapshots                   List the 5 most recent full-state snapshots
    rollback [path]             Roll back the whole state
    target                      Camouflage site selection / validation
    firewall [apply|strict|off|status]   Dual-stack IPv4 + IPv6
    bbr [on|status]             Includes MPTCP off (CVE-2026-98432)

  Language / VNC console
    lang [en|zh|auto]           Switch to English when Chinese shows as boxes on
                                a cloud VNC console (pure ASCII output)
    XHY_LANG=en xhy <command>   Force English for one run; XHY_ASCII=1 is the same
    XHY_LANG=zh xhy <command>   Force Chinese for one run
    English mode guarantees printable ASCII; Chinese mode is byte-for-byte
    unchanged. auto checks LANG/TERM/charmap: C locale, non-UTF-8 and
    linux/vt100 style consoles switch to English; ordinary UTF-8 SSH
    terminals stay Chinese.

  Version & update
    core [status|channel pinned|channel latest|channel vX.Y.Z|update [--force]]
    update [script|core|geodata|config|all]
    update script --yes [--allow-major]   Non-interactive (major bump needs flag)

  Backup, export & disk
    backup [--out FILE]         Back up /etc/xray-hy (per-file SHA256 list)
    restore <file>              Verify then restore (auto rollback on failure)
    clean [backups|snapshots|tarballs|tmp|all]  Drop old core backups / snapshots / tarballs
                                A full root fs makes sshd unreachable while the
                                proxy keeps working; check `xhy check` disk line
                                tarballs = xhy backup output, tmp = xray-rollback.*
    export clash|singbox [--out F]  Export mihomo/Clash or sing-box configs

  Service & uninstall
    service [start|stop|restart|status]
    uninstall                   Uninstall (optionally keep config)

config KEYs: BLOCK_BT BLOCK_PRIVATE BLOCK_CN BLOCK_ADS
             DNS_PROVIDER(cloudflare|quad9|dns-sb|system)
             LOG_LEVEL(warning|info|none) SSH_GUARD TARGET_REGION
             DUAL_STACK(on = new nodes listen on ::, off = 0.0.0.0)
EOF
        return 0
    fi
    xhy_t <<EOF
xray-hy $XHY_VERSION - 模块化 Xray 部署管理 (Debian/Ubuntu, Alpine, RHEL 系)

用法: xhy <命令> [选项]

  安装与检查
    install                     完整初始化（脚本本体、依赖、Xray、服务、BBR、防火墙）
    preflight                   安装前预检（端口/磁盘/内核/网络/依赖）
    check                       环境自检报告
    version                     显示脚本版本

  节点管理
    add <mode> [--port N] [选项] 添加节点
    edit [mode] [port]          编辑已有节点；省略参数时列出编号选择（回车=不改）
    list                        列出所有节点
    link [--all|--uri|--qr]     导出 vless:// 链接
    del [mode] [port]           删除节点；省略参数时列出编号选择
    menu                        交互式菜单

    mode: direct | tunnel | reality | xhttp | hy2
    add 选项: --host --path --uuid --sni --target --domain --token --reality
              --masq --masq-proxy --up --down   (hy2 专用)
              --scan [--scan-cidr CIDR] [--scan-refresh]   (reality 专用)
              --tfo auto|on|off            (reality/xhttp；auto=跟随伪装站，默认)
    默认端口: direct 8080 / tunnel 10086 / reality 443 / xhttp 8081 / hy2 8443(UDP)
    hy2 用 Xray 内置 Hysteria2 入站(v26.3.27+)，自签证书 + pinSHA256 链接
    hy2 默认 masquerade type=string（静态页）；--masq-proxy 改为反代真站，
      伪装性更好，但未认证流量会走本机带宽

  伪装站自动扫描
    scan [网段]                 扫本机机房网段，列出 3-5 个候选让你挑（结果缓存复用）
    scan --require-tfo          只列出支持被动 TFO 的候选；不给则交互询问一次
    scan --list                 查看缓存里的候选与打分
    scan --verify               复核缓存候选，剔除已失效的
    scan --refresh              忽略缓存重新扫描
    scan --clear                清除缓存
    原理: 用 RealiTLScanner 在 /24 里枚举 TLS 1.3 + h2 站点，再逐个用真实 SNI
    做证书/跳转/CDN 校验并打分，最后列出前 3-5 个候选由你选（脚本化调用
    自动取最高分）。TFO 只是展示/过滤项，不参与打分：不强制时按质量选，
    结果里也可能带支持 TFO 的站点；强制时只留支持 TFO 的。
    --require-tfo 在 /24（或缓存）里没找到时，会自动扩到同机房 /21 再扫一次。
    每个候选后面都标注「TFO 支持 / 不支持」（现场探测，不写进缓存），
    包括 [ok] 校验行、3-5 短名单、scan --list 与 scan --verify。
    结果记在 /etc/xray-hy/scan-cache.tsv（默认 7 天），此后再建 REALITY 节点
    直接复用，不会重复扫描。仅 amd64 / arm64 支持，其它架构回退内置地区库。

  伪装站 / REALITY 名词（xhy target 里输入 6 可随时查看）
    target(dest)  服务端主动去连的目的地址（IP:端口 或 域名:端口），未认证流量
                  原样转发到这里，所以必须是真实、稳定、长期存在的 HTTPS 站点。
    SNI           客户端握手时声明的域名；serverNames 是 Xray 里的 SNI 白名单，
                  必须被 target 的证书覆盖。
    目标站挂在 CDN 后面时，dest 要写「源站 IP」、SNI 仍写域名，例如：
        xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com
    交互菜单 9) 伪装站 → 3) 手动指定 支持同一写法（1.2.3.4:443,sni=www.example.com），
    校验会用 --resolve 打该 IP，测证书是否真的覆盖这个域名。
    不想手挑就用 xhy scan：自动扫本机机房网段并选最优站点（结果缓存复用）。

  TFO（TCP Fast Open）— 默认跟随伪装站，可强制覆盖
    Xray 的 tcpFastOpen 实测确实生效（服务端能收 SYN 里的 early data、能给
    cookiereq 回 cookie）。但开不开要看伪装站：
      伪装站支持被动 TFO → auto 默认开，探测者看到的 SYN-ACK 一致，白拿 1 RTT
      伪装站不支持        → auto 默认关；否则探测者发一个带 cookiereq 的 SYN，
                            我们会回 tfo cookie、真实站点不回，一眼就能区分开
    auto 用 curl --tcp-fastopen 连打 3 次看内核 TcpExtTCPFastOpenActive 是否
    增长，判定结果写进节点配置，重建配置不会重复探测。--tfo on / off 强制覆盖。
    客户端默认跟随服务端：我们开它开、我们关它关。
    注：伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽
    和延迟不影响代理上网速度；扫描不为凑 TFO 缩小候选池，先按质量选最优站。

  配置
    config                      路由/DNS/日志开关菜单（也可直接 set）
    config set KEY VALUE        直接改设置，见下方 KEY
    snapshots                   列出最近 5 份整套状态快照
    rollback [快照路径]         回滚整套状态（config + 节点 + 分片 + state）
    target                      伪装站选择 / 校验菜单
    firewall [apply|strict|off|status]   双栈 IPv4 + IPv6
    bbr [on|status]             含 MPTCP 关闭 (CVE-2026-98432)

  语言 / VNC 控制台
    lang [en|zh|auto]           中文在云 VNC 上显示成小方块时切英文（纯 ASCII）
    XHY_LANG=en xhy <命令>      单次强制英文；XHY_ASCII=1 同义
    XHY_LANG=zh xhy <命令>      单次强制中文
    英文模式下所有输出保证是可打印 ASCII；中文模式下输出逐字节不变。
    auto 会按 LANG/TERM/charmap 判定：C locale、非 UTF-8、linux/vt100 之类
    控制台终端自动切英文，普通 UTF-8 SSH 终端保持中文。

  版本与更新
    core [status|channel pinned|channel latest|channel vX.Y.Z|update [--force]]
    update [script|core|geodata|config|all]
    update script --yes [--allow-major]   非交互更新（跨主版本需 --allow-major）

  备份、导出与磁盘
    backup [--out FILE]              备份 /etc/xray-hy（内含逐文件 SHA256 清单）
    restore <备份文件>               校验清单后还原（先备份现状，失败自动回滚）
    clean [backups|snapshots|tarballs|tmp|all]  清理旧核心二进制 / 旧快照 / 旧打包备份（小硬盘必用）
                                     根分区满时 sshd 会连不上、而代理仍在工作；
                                     xhy check 里有「磁盘余量」一行
                                     tarballs = xhy backup 产物，tmp = xray-rollback.* 残留
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
    xhy_lang_banner
    printf '\n'
    platform_summary
    printf '\n'
    stage 1 7 "依赖检查与安装（这一步最慢；卡住多半是软件源，见文末提示）"
    ensure_deps
    stage 2 7 "安装脚本本体与命令入口"
    # bootstrap_self 在 main() 里已经把本体 + /usr/local/bin/xhy 落地了，
    # 别再下载/复制一遍；显式 `xhy install` 时仍完整执行。
    if [[ "${XHY_BOOTSTRAPPED:-0}" == "1" ]]; then
        ok "脚本本体已就位（本次启动已落地）"
    else
        install_self
        create_symlink
    fi
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
        state_set BBR_ENABLED on
        bbr_ensure || warn "BBR 未启用，可执行 xhy bbr on / xhy check 复查。"
    else
        state_set BBR_ENABLED off
        warn "已跳过 BBR（要启用请执行 xhy bbr on）"
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
    ok "安装完成。现在可用 xhy add reality 添加第一个节点，或直接输入 xhy 打开菜单。"
}

cmd_add_interactive() {
    local mode port host path sni target domain token
    local -a extra=()
    xhy_t <<'EOF'
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
            xhy_t <<'EOF'
  伪装站（target / dest）来源：
    1) 自动扫描本机机房网段，选最优站点（推荐；有缓存直接复用，不重复扫）
    2) 内置地区库（按 VPS 出口国家匹配）
    3) 手动指定 target / SNI
EOF
            case "$(ask '选择' '1')" in
                1)
                    opts+=(--scan)
                    if [[ -s "$SCANNER_CACHE" ]] && scanner_cache_valid; then
                        info "已有 $(scanner_cache_age_h) 小时前的扫描缓存（$(scanner_cache_count) 个候选）"
                        if confirm "忽略缓存重新扫描？" "n"; then opts+=(--scan-refresh); fi
                    else
                        info "扫描范围默认是本机公网 IP 所在 /24；无合格站点、或强制 TFO 时没找到支持 TFO 的站，会自动扩到 /21 再扫一次"
                    fi ;;
                3)
                    # 一条输入：host[:port][,sni=xxx]；不写 sni= 时 SNI 与 target 同名。
                    # 目标站在 CDN 后面时用「源站 IP + 域名 SNI」：1.2.3.4:443,sni=www.example.com
                    local t_in ts
                    xhy_t <<'EOF'
  输入示例：
    www.example.com                    域名，dest 与 SNI 相同
    1.2.3.4:443,sni=www.example.com   源站 IP + 域名 SNI（站点在 CDN 后时用这个）
    www.example.com:8443              非 443 端口
EOF
                    t_in="$(ask 'target')"
                    [[ -n "$t_in" ]] || return 0
                    ts="${t_in#*,sni=}"; [[ "$ts" == "$t_in" ]] && ts=""
                    t_in="${t_in%%,*}"
                    [[ "$t_in" == *:* ]] || t_in="${t_in}:443"
                    if is_ip_literal "${t_in%%:*}" && [[ -z "$ts" ]]; then
                        err "target 是 IP 时必须加 ,sni=域名（dest 用 IP、SNI 用域名）"
                        return 1
                    fi
                    opts+=(--target "$t_in" --sni "${ts:-${t_in%%:*}}") ;;
                *)
                    info "使用内置地区库（conf/targets.tsv）..." ;;
            esac ;;
        xhttp)
            if confirm "叠加 REALITY（无需证书）？" "n"; then
                extra+=(--reality)
                if confirm "自动扫描本机机房网段挑伪装站？（n = 用内置地区库）" "y"; then
                    extra+=(--scan)
                fi
            fi ;;
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
            # 默认静态页：proxy 模式被扫到未认证流量时会拿本机带宽替真站转发。
            if confirm "改为反代真站（更像，但走本机带宽）？" "n"; then
                opts+=(--masq-proxy)
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
            --host|--path|--uuid|--sni|--target|--domain|--token|--masq|--up|--down|--scan-cidr|--tfo)
                opts+=("$1" "$2"); shift 2 ;;
            --reality|--scan|--scan-refresh|--masq-proxy) opts+=("$1"); shift ;;
            *) die "未知参数: $1（见 xhy --help）" ;;
        esac
    done
    valid_port "$port" || die "端口不合法: $port"
    node_add "$mode" "$port" "${opts[@]}"
}

# xhy scan [网段] [--refresh|--list|--verify|--clear]
cmd_scan() {
    local cidr="" refresh=0 mode="run" best st ss sl require=0
    while (( $# > 0 )); do
        case "$1" in
            --refresh) refresh=1; shift ;;
            --list)    mode="list"; shift ;;
            --clear)   mode="clear"; shift ;;
            --verify)  mode="verify"; shift ;;
            --require-tfo) require=1; shift ;;
            --cidr)    cidr="${2:?--cidr 需要网段}"; shift 2 ;;
            -*)        die "未知参数: $1（用法: xhy scan [网段] [--refresh|--list|--verify|--clear|--require-tfo]）" ;;
            *)         cidr="$1"; shift ;;
        esac
    done
    case "$mode" in
        list)   scanner_cache_show ;;
        clear)  scanner_cache_clear ;;
        verify) scanner_cache_verify ;;
        run)
            local -a args=()
            if (( refresh == 1 )); then args+=(--refresh); fi
            if [[ -n "$cidr" ]]; then args+=(--cidr "$cidr"); fi
            # 交互式问一次「是否必须 TFO」；显式给了 flag 或非 tty 时跳过。
            if (( require == 0 )) && [[ -t 0 ]]; then
                printf '是否只选支持 TFO 的伪装站？(y/N，回车=不强制): ' >&2
                local ans=""
                if { read -r ans < /dev/tty; } 2>/dev/null; then :; else ans=""; fi
                printf '\n' >&2
                if [[ "$ans" == "y" || "$ans" == "Y" ]]; then require=1; fi
            fi
            if (( require == 1 )); then args+=(--require-tfo); fi
            if best="$(scanner_pick ${args[@]+"${args[@]}"})"; then
                read -r st ss sl <<<"$best"
                printf '\n最优伪装站: target=%s  SNI=%s（来源 %s）\n\n' "$st" "$ss" "$sl"
                printf '  直接建节点（用缓存，不再扫描）:\n'
                printf '    xhy add reality --port 443 --target %s --sni %s\n\n' "$st" "$ss"
                printf '  或让它自己挑（缓存有效期内同样不重扫）:\n'
                printf '    xhy add reality --port 443 --scan\n'
            else
                if (( require == 1 )); then
                    err "自动扫描失败：/24 与 /21 里都没有支持被动 TFO 的候选"
                    err "可去掉 --require-tfo 按质量选，或 xhy scan --cidr <其它网段> --require-tfo"
                    err "也可改用 xhy target → 2) 指定地区，或 3) 手动指定"
                else
                    err "自动扫描失败；可改用 xhy target → 1) 内置地区库，或 3) 手动指定"
                fi
                return 1
            fi ;;
    esac
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
    # 扫描器是下载来的独立工具，不在 git 工作树里，卸载时单独清。
    rm -rf "$XHY_TOOLS_DIR"
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
    xhy_lang_banner
    while true; do
        printf '\n============ xray-hy %s ============\n' "$XHY_VERSION"
        printf '  %s / %s / Xray %s / 节点 %s 个\n' "$XHY_DISTRO" "$XHY_INIT" "$(xray_installed_version)" "$(node_count)"
        xhy_t <<'EOF'
  ---- 节点 ----
   1) 添加节点               2) 编辑节点
   3) 节点列表               4) 导出分享链接
   5) 删除节点
  ---- 系统 ----
   6) 完整安装 / 重装        7) 环境自检
   8) 配置（路由/DNS/日志）  9) 伪装站
  10) 防火墙                11) BBR / 内核
  ---- 维护 ----
  12) 服务管理              13) Xray 版本通道
  14) 更新                  15) 卸载
  16) 备份 / 恢复
   0) 退出
EOF
        case "$(ask '选择' '0')" in
            1) cmd_add_interactive ;;
            2) node_edit ;;
            3) node_list; ask '按回车继续' '' ;;
            4) link_all; ask '按回车继续' '' ;;
            5) if node_pick; then
                   if confirm "确认删除节点 ${MODE}_${PORT}？恢复需 xhy rollback" "n"; then
                       node_del "$MODE" "$PORT"
                   fi
               fi ;;
            6) cmd_install ;;
            7) self_check ;;
            8) cmd_config_menu ;;
            9) target_menu ;;
           10) local fa
               fa="$(ask 'apply / strict / off / status' 'status')"
               case "$fa" in
                   apply)  firewall_apply safe ;;
                   strict) warn "strict 会丢弃除 SSH 与节点端口外的所有入站连接。"
                           if confirm "确认？" "n"; then firewall_apply strict; fi ;;
                   off)    firewall_off ;;
                   *)      firewall_status ;;
               esac ;;
           11) if [[ "$(ask 'on / status' 'status')" == "on" ]]; then tune_bbr; else bbr_status; fi ;;
           12) local sa
               sa="$(ask 'start / stop / restart / status' 'status')"
               case "$sa" in
                   start|stop|restart) "svc_$sa" "$SVC_XRAY" ;;
                   *) svc_status "$SVC_XRAY" ;;
               esac ;;
           13) core_status
               local ch; ch="$(ask 'pinned / latest / vX.Y.Z（回车不改）' '')"
               if [[ -n "$ch" ]]; then xray_set_channel "$ch"; core_status; fi ;;
           14) local ua; ua="$(ask 'all / script / core / geodata / config' 'all')"
               case "$ua" in
                   all) update_all ;; script) update_script ;; core) update_core ;;
                   geodata) update_geodata ;; config) update_config ;;
               esac ;;
           15) cmd_uninstall; return 0 ;;
           16) local ba
               ba="$(ask 'backup / restore / clean（清理旧备份释放磁盘）' 'backup')"
               case "$ba" in
                   backup) backup_create ;;
                   restore) backup_restore "$(ask '备份文件路径' '')" ;;
                   clean)  cmd_clean all ;;
                   *) warn "只支持 backup / restore / clean" ;;
               esac ;;
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
    # 扫描器是下载来的独立工具，不在 git 工作树里，卸载时单独清。
    rm -rf "$XHY_TOOLS_DIR"
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

main() {
    # 无参数 = 一键入口：没装过就自动完整安装（含脚本本体与 xhy 命令），
    # 装过就进菜单。显式 `xhy menu` / `xhy install` 保持原语义。
    local cmd="${1:-auto}"
    [[ $# -gt 0 ]] && shift
    xhy_lang_init
    xhy_install_output_filters
    case "$cmd" in
        --help|-h|help) usage; return 0 ;;
        --version|version) printf 'xray-hy %s (build %s)\n' "$XHY_VERSION" "$XHY_BUILD"; return 0 ;;
    esac

    need_root
    detect_platform
    acquire_lock
    trap release_lock EXIT

    # 任何从非安装位置发起的运行都先把本体 + /usr/local/bin/xhy 落地。
    bootstrap_self

    case "$cmd" in
        auto)
            # 仓库开发入口永远进菜单，别让本地 ./xhy 触发完整安装。
            if [[ "${XHY_DEV:-0}" == "1" ]] || xhy_is_installed; then
                cmd_menu
            else
                cmd_install || return 1
                if [[ -t 0 ]]; then
                    cmd_menu
                else
                    info "非交互环境：安装完成，下次直接运行 xhy 即可打开菜单。"
                fi
            fi ;;
        lang)       cmd_lang "$@" ;;
        install)    cmd_install ;;
        preflight)  preflight_check ;;
        check)      self_check ;;
        menu|--menu) cmd_menu ;;
        add)        cmd_add "$@" ;;
        list)       node_list ;;
        link)       cmd_link "$@" ;;
        export)     cmd_export "$@" ;;
        backup)     backup_create "$@" ;;
        restore)    backup_restore "${1:?用法: xhy restore <备份文件>}" ;;
        del)        if [[ -z "${1:-}" ]]; then
                        # 不带参数：列出节点编号让人选，避免盲猜 mode/port
                        if node_pick; then
                            if confirm "确认删除节点 ${MODE}_${PORT}？恢复需 xhy rollback" "n"; then
                                node_del "$MODE" "$PORT"
                            fi
                        fi
                    else
                        node_del "${1:?需要模式}" "${2:?需要端口}"
                    fi ;;
        config)     if [[ "${1:-}" == "set" ]]; then cmd_config_set "${2:?需要 KEY}" "${3:?需要 VALUE}";
                    else cmd_config_menu; fi ;;
        snapshots)  list_snapshots ;;
        rollback)   rollback_config "${1:-}" ;;
        target)     target_menu ;;
        edit)       node_edit "$@" ;;
        clean)      cmd_clean "$@" ;;
        relay)      cmd_relay "$@" ;;
        scan)       cmd_scan "$@" ;;
        firewall)   case "${1:-status}" in
                        # --quiet is passed by the boot unit; forward it so boot
                        # logs stay clean.
                        apply)  firewall_apply safe "${2:-}" ;;
                        strict) firewall_apply strict ;;
                        off)    firewall_off ;;
                        *)      firewall_status ;;
                    esac ;;
        bbr)        case "${1:-status}" in
                        on) state_set BBR_ENABLED on; bbr_ensure || warn "BBR 未启用，可执行 xhy check 复查。" ;;
                        *)  bbr_status ;;
                    esac ;;
        core)       case "${1:-status}" in
                        status)  core_status ;;
                        channel) xray_set_channel "${2:?需要 pinned/latest/vX.Y.Z}"; core_status ;;
                        update)  shift; update_core "$@" ;;
                        *) die "用法: xhy core [status|channel <值>|update [--force]]" ;;
                    esac ;;
        update)     case "${1:-all}" in
                        all) update_all ;;
                        script) shift; update_script "$@" ;;
                        core) shift; update_core "$@" ;;
                        geodata) update_geodata ;; config) update_config ;;
                        *) die "用法: xhy update [all|script [--yes] [--allow-major]|core [--force]|geodata|config]" ;;
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
