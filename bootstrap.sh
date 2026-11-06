#!/bin/sh
# xray-hy / bootstrap.sh
#
# 给一台「全新、没有 bash、没有 git」的机器做准备，然后把控制权交给 ./xhy。
# 只用 POSIX sh 和 busybox：它必须在 bash 装好之前就能跑。
#
# 用法：
#   sh bootstrap.sh --check           只体检，不装任何东西（排查"没反应"用）
#   sh bootstrap.sh                   装依赖，然后对当前目录的 xhy 跑 preflight
#   sh bootstrap.sh /tmp/xray-hy.tar.gz   装依赖 + 解包到 /opt/xray-hy + preflight
#
# 环境变量：
#   XHY_APP_DIR       安装目录，默认 /opt/xray-hy
#   XHY_PKG_TIMEOUT   单次包操作上限秒数，默认 180
#   XHY_APK_MIRROR    换成指定 Alpine 镜像（如 mirrors.aliyun.com）
set -u

APP_DIR="${XHY_APP_DIR:-/opt/xray-hy}"
PKG_TIMEOUT="${XHY_PKG_TIMEOUT:-180}"
MODE="${1:-}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> [%s/%s] %s\n' "$1" "$2" "$3"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

run_lim() { _t="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$_t" "$@"; else "$@"; fi; }

detect_pkg() {
    if command -v apk >/dev/null 2>&1; then echo apk
    elif command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    else echo none
    fi
}

PKG="$(detect_pkg)"

pkg_install_all() {
    case "$PKG" in
        apk) run_lim "$PKG_TIMEOUT" apk add --no-cache "$@" ;;
        apt) DEBIAN_FRONTEND=noninteractive run_lim "$PKG_TIMEOUT" apt-get install -y -qq --no-install-recommends "$@" ;;
        dnf) run_lim "$PKG_TIMEOUT" dnf install -y -q "$@" ;;
        yum) run_lim "$PKG_TIMEOUT" yum install -y -q "$@" ;;
        *)   die "没有可用的包管理器（apk/apt/dnf/yum 都没有）" ;;
    esac
}

dep_list() {
    case "$PKG" in
        apk) echo "bash curl ca-certificates openssl coreutils unzip iptables ip6tables" ;;
        apt) echo "bash curl ca-certificates openssl coreutils unzip iptables" ;;
        *)   echo "bash curl ca-certificates openssl coreutils unzip iptables" ;;
    esac
}

pkg_hint() {
    printf '[!] 包操作失败或超时（上限 %ss）。按顺序排查：\n' "$PKG_TIMEOUT" >&2
    case "$PKG" in
        apk) printf '    1) 软件源/DNS：apk update ; cat /etc/resolv.conf\n' >&2
             printf '    2) 换源：sed -i "s#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g" /etc/apk/repositories\n' >&2
             printf '    3) 锁：ps w | grep apk（云厂商 cloud-init 会用锁）\n' >&2 ;;
        apt) printf '    1) 软件源/DNS：apt-get update ; cat /etc/resolv.conf\n' >&2
             printf '    2) 锁：ps aux | grep -E "apt|dpkg"\n' >&2 ;;
        *)   printf '    检查网络、DNS 与软件源\n' >&2 ;;
    esac
}

net_check() {
    say "  --- 网络体检 ---"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup github.com >/dev/null 2>&1; then say "  DNS        ok   github.com 可解析"
        else say "  DNS        失败 github.com 解析不了（先修 /etc/resolv.conf）"; fi
    else
        say "  DNS        跳过（没有 nslookup）"
    fi
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' https://api.github.com 2>/dev/null || echo 000)"
        say "  HTTPS      api.github.com -> HTTP $code"
        code2="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' https://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null || echo 000)"
        say "  软件源     dl-cdn.alpinelinux.org -> HTTP $code2"
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -T 10 -O /dev/null https://api.github.com 2>/dev/null; then say "  HTTPS      api.github.com ok"
        else say "  HTTPS      api.github.com 失败"; fi
    else
        say "  HTTPS      跳过（没有 curl/wget）"
    fi
}

env_summary() {
    say "系统   : $(uname -srm 2>/dev/null)"
    [ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && say "发行版 : ${PRETTY_NAME:-$ID}"
    say "包管理 : $PKG"
    say "bash   : $(command -v bash || echo 未安装)"
    say "git    : $(command -v git || echo 未安装（install 不需要，只有 xhy update script 需要）)"
    say "内存   : $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo 2>/dev/null || echo '?')"
    say "磁盘   : $(df -h / 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2}')"
}

# ---- 只体检 ----
if [ "$MODE" = "--check" ]; then
    say "== xray-hy 环境体检（不修改任何东西）=="
    env_summary
    net_check
    say ""
    say "如果 3 个工具都在、DNS 与 HTTPS 都 ok，那么「没反应」不是环境问题，"
    say "而是卡在某一步：用 XHY_TRACE=1 ./xhy install 看它停在哪一行。"
    exit 0
fi

# ---- 1. 前提 ----
step 1 5 "检查权限与包管理器"
[ "$(id -u)" -eq 0 ] || die "需要 root（用 su - 或 sudo -i）"
[ "$PKG" = "none" ] && die "没有可用的包管理器"
say "  root ok，包管理器 $PKG"

# ---- 2. 依赖 ----
step 2 5 "安装依赖（上限 ${PKG_TIMEOUT}s，输出会实时显示）"
need=""
for p in $(dep_list); do
    case "$p" in
        coreutils) command -v sha256sum >/dev/null 2>&1 || need="$need $p" ;;
        *)         command -v "$p" >/dev/null 2>&1 || need="$need $p" ;;
    esac
done
if [ -n "$need" ]; then
    say "  待安装:$need"
    pkg_install_all $need || { pkg_hint; die "依赖安装失败"; }
else
    say "  依赖齐全"
fi
command -v bash >/dev/null 2>&1 || { pkg_hint; die "bash 仍未装上"; }

# ---- 3. 代码 ----
step 3 5 "准备代码目录 $APP_DIR"

install_tree() { # install_tree <源目录>
    local src="$1"
    [ -f "$src/xhy" ] || die "$src 里没有 xhy，包结构不对"
    mkdir -p "$APP_DIR" || die "无法创建 $APP_DIR"
    if [ "$(cd "$src" && pwd)" = "$(cd "$APP_DIR" && pwd)" ]; then
        say "  已在 $APP_DIR，跳过复制"
        return 0
    fi
    # 保留 .git（若之前是 clone 的），其余清掉，避免旧文件残留
    find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2>/dev/null || true
    cp -a "$src"/. "$APP_DIR"/ || die "复制文件失败"
    say "  已复制到 $APP_DIR"
}

if [ -n "$MODE" ] && [ -d "$MODE" ]; then
    install_tree "$MODE"
elif [ -n "$MODE" ] && [ -f "$MODE" ]; then
    tar -tzf "$MODE" >/dev/null 2>&1 || die "$MODE 不是有效的 tar.gz"
    tmpd="$(mktemp -d)" || die "无法创建临时目录"
    tar -xzf "$MODE" -C "$tmpd" || die "解包失败"
    top="$(tar -tzf "$MODE" | head -1 | cut -d/ -f1)"
    if [ -d "$tmpd/$top" ]; then src="$tmpd/$top"; else src="$tmpd"; fi
    install_tree "$src"
    rm -rf "$tmpd"
elif [ -f "./xhy" ]; then
    install_tree "$(pwd)"
elif [ -f "$APP_DIR/xhy" ]; then
    say "  使用已有目录: $APP_DIR"
else
    die "没找到代码。先把 tar.gz 传上来（见 README「全新机器」），或在仓库目录里运行"
fi
[ -f "$APP_DIR/xhy" ] || die "$APP_DIR 里没有 xhy"
chmod 0755 "$APP_DIR/xhy" 2>/dev/null || true

# ---- 4. 体检 ----
step 4 5 "网络与工具体检"
net_check

# ---- 5. 交给 xhy ----
step 5 5 "运行 preflight（只读预检）"
cd "$APP_DIR" || die "无法进入 $APP_DIR"
./xhy preflight || die "preflight 未通过，按上面的提示修完再跑：cd $APP_DIR && ./xhy install"

say ""
say "准备就绪。下一步："
say "  cd $APP_DIR && ./xhy install"
