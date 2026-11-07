#!/usr/bin/env bash
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
    "扫描范围默认是本机公网 IP 所在 /24；无合格站点、或强制 TFO 时没找到支持 TFO 的站，会自动扩到 /21 再扫一次" "当前网段内没有支持被动 TFO 的候选（每个站点后已标注 TFO 结果）；将自动扩大到 /21 再扫一次" "安装完成。现在可用 xhy add reality 添加第一个节点，或直接输入 xhy 打开菜单。"
    "  xhy lang en    强制英文（纯 ASCII；云 VNC 控制台中文是小方块时用）" "  单次强制：XHY_LANG=en xhy  或  XHY_ASCII=1 xhy" "现在用 xhy add reality 添加第一个节点，或输入 xhy 打开菜单"
    "缓存里没有支持被动 TFO 的站点；自动扩大网段再扫一次（不重复扫同一 /24）" "  xhy lang auto  按终端 / locale 自动判定（默认）" "1) 自动扫描本机机房网段，选最优站点（推荐；有缓存直接复用，不重复扫）"
    "（safe 模式：SSH 防爆破 + 放行节点端口，不改动现有规则）" "TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连）" "是否只选支持 TFO 的伪装站？(y/N，回车=不强制): "
    "；scanner_pick 会自动扩大到 /21 再扫一次。" "非交互环境：安装完成，下次直接运行 xhy 即可打开菜单。" "候选伪装站（按质量排序；TFO=目标是否支持被动 TFO）"
    "选哪个 \[1-%d\]（回车=1，0=自动取最高分）: " "尚未安装 Xray，请先运行: xhy install" "（未强制 TFO；列表里也可能含支持 TFO 的站点）"
    "每个候选后面都标注「TFO 支持 / 不支持」" "（这一步最慢；卡住多半是软件源，见文末提示）" "（下次运行生效；本次可用 XHY_LANG="
    "2) 内置地区库（按 VPS 出口国家匹配）" "去掉 --require-tfo 按质量选" "伪装站（target / dest）来源："
    "  xhy lang zh    强制中文" "里没有支持被动 TFO 的站点，自动扩大到" "伪装站（target / dest）来源"
    "3) 手动指定 target / SNI" "内置地区库（按 VPS 出口国家匹配）" "自动扫描本机机房网段，选最优站点"
    "脚本本体已就位（本次启动已落地）" "（已按「必须支持 TFO」过滤）" "客户端连接地址(域名或 IP)"
    "（回车=1，0=自动取最高分）" "前 个候选都不支持被动 TFO" "或换 --cidr 网段再试"
    "可改用 xhy target" "最优伪装站: target=" "配置（路由/DNS/日志）"
    "建议套 CDN / 反代" "---- 节点 ----" "---- 系统 ----"
    "---- 维护 ----" "上面每个站点后已标注结果" "选择类型 \[3\]: "
    "扫描范围默认是本机公网" "扫描完成但没有可用站点" "非 CDN（源站直连）"
    "安装脚本本体与命令入口" "路径 (回车随机生成)" "缓存里的候选都已失效"
    "内核网络优化与防火墙" "选择 \[0\]: " "选择 \[1\]: "
    "不需要公网入站端口" "完整安装 / 重装" "Xray 版本通道"
    "尚未安装 Xray" "安装服务与开机自启" "渲染配置并启动服务"
    "每个候选后面都标注" "BBR / 内核" "支持被动 TFO"
    "无结果会自动扩到" "备份 / 恢复" "客户端连接地址"
    "依赖检查与安装" "当前语言 : " "TFO 不支持"
    "结果已缓存: " "个可用候选（共" "导出分享链接"
    "内核网络优化" "自动扫描失败" "创建数据目录"
    "已设置语言为" "TFO 支持" "使用扫描缓存"
    "扫描伪装站" "结果已缓存" "最优伪装站"
    "直接建节点" "候选伪装站" "按质量排序"
    "个去重候选" "下载并校验" "安装最新版"
    "配置防火墙" "不写入缓存" "不参与打分"
    "节点类型：" "立即切换）" "验证完成："
    "服务管理" "添加节点" "节点列表"
    "删除节点" "环境自检" "版本通道"
    "重新扫描" "完整安装" "手动指定"
    "自动扫描" "随机生成" "监听端口"
    "节点类型" "选择类型" "必须支持"
    "现场探测" "再扫一次" "本网段前"
    "防火墙" "伪装站" "不支持"
    "已清除" "已过期" "已失效"
    "已跳过" "未启用" "未安装"
    "已安装" "签发者" "小时前"
    "个候选" "不合法" "未强制"
    "列表里" "个站点" "硬过滤"
    "同机房" "小方块" "控制台"
    "选择 " "选哪个" "支持"
    "握手" "分数" "缓存"
    "候选" "扫描" "校验"
    "复核" "查看" "清除"
    "列出" "刷新" "扩容"
    "扩大" "节点" "端口"
    "地址" "域名" "证书"
    "流量" "探测" "最优"
    "质量" "结果" "来源"
    "添加" "删除" "导出"
    "列表" "配置" "路由"
    "日志" "系统" "维护"
    "更新" "卸载" "备份"
    "恢复" "重装" "自检"
    "服务" "管理" "环境"
    "内核" "权限" "脚本"
    "入口" "启用" "开启"
    "关闭" "使用" "当前"
    "选择" "返回" "继续"
    "确认" "确定" "取消"
    "输入" "示例" "格式"
    "说明" "提示" "警告"
    "错误" "失败" "成功"
    "完成" "安装" "下载"
    "检查" "启动" "停止"
    "重启" "状态" "默认"
    "有效" "保留" "剔除"
    "需要" "运行" "命令"
    "参数" "文件" "目录"
    "版本" "缺少" "无法"
    "必须" "可选" "回车"
    "路径" "退出" "只选"
    "中文" "英文" "终端"
)

XHY_T_EN=(
    "Default scan range is this host's /24; with no usable site (or no TFO-capable site when required) it auto-widens to /21 and rescans" "No TFO-capable candidate in this subnet (each site above is labelled); auto-widening to /21 and rescanning" "Install complete. Run xhy add reality to add the first node, or just xhy for the menu."
    "  xhy lang en    force English (pure ASCII; use when a cloud VNC shows boxes)" "  one-shot: XHY_LANG=en xhy   or  XHY_ASCII=1 xhy" "Now run xhy add reality to add the first node, or just xhy for the menu"
    "No TFO-capable site in cache; auto-widening the subnet to rescan (not the same /24)" "  xhy lang auto  detect from terminal / locale (default)" "1) Auto-scan this datacenter subnet and pick the best site (recommended; cache reused, no rescan)"
    " (safe mode: SSH brute-force guard + allow node ports, no changes to existing rules)" "TLS 1.3 / H2 / no redirect / not CDN (origin direct)" "Only TFO-capable sites? (y/N, Enter = no): "
    "; scanner_pick auto-widens to /21 and rescans." "Non-interactive shell: install complete, run xhy later to open the menu." "Candidate sites (by quality; TFO = target supports passive TFO)"
    "Pick [1-%d] (Enter=1, 0=best score): " "Xray is not installed, run: xhy install" " (TFO not required; the list may still contain TFO sites)"
    "each candidate is labelled TFO: yes / no" " (this is the slowest step; stalls are usually the package mirror)" " (effective next run; use XHY_LANG="
    "2) Built-in region library (match VPS egress country)" "drop --require-tfo to pick by quality" "Camouflage site (target / dest) source:"
    "  xhy lang zh    force Chinese" " has no TFO-capable site, auto-widening to " "Camouflage site (target / dest) source"
    "3) Specify target / SNI manually" "Built-in region library (match VPS egress country)" "Auto-scan this datacenter subnet and pick the best site"
    "Script and command entry already installed (this run)" " (filtered: TFO required)" "Client address (domain or IP)"
    "(Enter=1, 0=best score)" "no TFO-capable candidates" "or try another --cidr subnet"
    "fall back to xhy target" "Best camouflage site: target=" "Config (routing/DNS/log)"
    "put it behind a CDN / reverse proxy" "---- Nodes ----" "---- System ----"
    "---- Maintenance ----" "each site above is labelled" "Select type [3]: "
    "Default scan range is the public" "Scan finished but no usable site" "not CDN (origin direct)"
    "Install script and command entry" "Path (Enter = random)" "all cached candidates are stale"
    "Kernel network tuning and firewall" "Select [0]: " "Select [1]: "
    "no public inbound port needed" "Full install / reinstall" "Xray version channel"
    "Xray is not installed" "Install service and enable at boot" "Render config and start service"
    "each candidate is labelled with" "BBR / kernel" "supports passive TFO"
    "auto-widens to" "Backup / restore" "Client address"
    "Dependency check and install" "Language : " "TFO: no"
    "Results cached: " " usable candidates (of " "Export share links"
    "kernel network tuning" "Auto-scan failed" "Create data directories"
    "Language set to" "TFO: yes" "Using scan cache"
    "Scan camouflage sites" "Results cached" "Best camouflage site"
    "Create a node now" "Candidate sites" "sorted by quality"
    "unique candidates" "Download and verify" "Install latest"
    "Configure firewall" "not written to cache" "not part of the score"
    "Node type:" " for this run)" "Verified: "
    "Service control" "Add node" "List nodes"
    "Delete node" "Environment check" "version channel"
    "Rescanning" "full install" "specify manually"
    "auto scan" "random" "Listen port"
    "Node type" "Select type" "must support"
    "live probe" " and rescanning" "Among the first "
    "Firewall" "camouflage site" "does not support"
    "cleared" "expired" "stale"
    "skipped" "not enabled" "not installed"
    "installed" "Issuer" "hours ago"
    "candidates" "invalid" "not required"
    "the list" "sites" "hard filter"
    "same rack" "boxes" "console"
    "Select " "Pick" "supports"
    "Handshake" "Score" "cache"
    "candidate" "scan" "validate"
    "reverify" "show" "clear"
    "list" "refresh" "widen"
    "widen" "node" "port"
    "address" "domain" "certificate"
    "traffic" "probe" "best"
    "quality" "result" "source"
    "add" "delete" "export"
    "list" "config" "routing"
    "log" "system" "maintenance"
    "update" "uninstall" "backup"
    "restore" "reinstall" "check"
    "service" "manage" "environment"
    "kernel" "privileges" "script"
    "entry" "enable" "on"
    "off" "use" "current"
    "select" "back" "continue"
    "confirm" "confirm" "cancel"
    "input" "example" "format"
    "notes" "hint" "warning"
    "error" "failed" "success"
    "done" "install" "download"
    "check" "start" "stop"
    "restart" "status" "default"
    "valid" "keep" "drop"
    "needs" "run" "command"
    "option" "file" "directory"
    "version" "missing" "unable"
    "must" "optional" "Enter"
    "Path" "Exit" "only"
    "Chinese" "English" "terminal"
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
            lang_all="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
            case "${lang_all,,}" in zh*|*zh_cn*|*zh_tw*) is_zh=1 ;; esac
            case "$lang_all" in ""|C|POSIX|c|posix) no_utf8=1 ;; esac
            cm="$(locale charmap 2>/dev/null || true)"
            if [[ -n "$cm" ]]; then
                case "${cm,,}" in *utf-8*|*utf8*) ;; *) no_utf8=1 ;; esac
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
