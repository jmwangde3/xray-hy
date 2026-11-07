#!/usr/bin/env bash
# 输出语言层回归：中文模式逐字节不变；英文模式保证 100% 可打印 ASCII，
# 且纯 ASCII 的配置 / JSON / 分享链接不被改写。全程离线。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system

echo "=== xhy_is_ascii ==="
chk "纯 ASCII 判定为真"  'xhy_is_ascii "abc 123 /tmp/{}%s"'
chk "中文判定为假"       '! xhy_is_ascii "节点"'
chk "中文+ASCII 判定为假" '! xhy_is_ascii "node 节点"'

echo "=== xhy_t 中文模式恒等 ==="
out="$(XHY_LANG_EFFECTIVE=zh xhy_t '---- 节点 ----')"
chk "中文模式原样返回" '[[ "$out" == "---- 节点 ----" ]]'
out="$(XHY_LANG_EFFECTIVE=zh xhy_t '[ok] www.easeus.com / TFO 不支持')"
chk "中文模式含中文原样" '[[ "$out" == *"不支持"* ]]'

echo "=== xhy_t 英文模式 ==="
en="$(XHY_LANG_EFFECTIVE=en xhy_t '---- 节点 ----')"
chk "菜单标题译成英文"   '[[ "$en" == *Nodes* ]]'
chk "菜单标题纯 ASCII"   '! printf "%s" "$en" | LC_ALL=C grep -q "[^ -~]"'
en="$(XHY_LANG_EFFECTIVE=en xhy_t '   1) 添加节点               2) 编辑节点')"
chk "菜单项译成英文"     '[[ "$en" == *"Add node"* && "$en" == *"Edit node"* ]]'
en="$(XHY_LANG_EFFECTIVE=en xhy_t '[ok]   www.easeus.com @ 47.88.102.65 : TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连） / TFO 不支持')"
chk "校验行译成英文"     '[[ "$en" == *"no redirect"* && "$en" == *"TFO: no"* ]]'
chk "校验行纯 ASCII"     '! printf "%s" "$en" | LC_ALL=C grep -q "[^ -~]"'
en="$(XHY_LANG_EFFECTIVE=en xhy_t '这个新词没进词表也不会变成小方块')"
chk "未登录词条仍纯 ASCII" '! printf "%s" "$en" | LC_ALL=C grep -q "[^ -~]"'
en="$(XHY_LANG_EFFECTIVE=en xhy_t 'scan完成support')"
chk "未登录中文换成空格不粘连" '[[ "$en" == *scan* && "$en" == *support* && "$en" != *scansupport* ]]'

echo "=== 纯 ASCII 数据不被改写 ==="
json='{"sockopt":{"tcpFastOpen":false},"remark":"hello"}'
en="$(XHY_LANG_EFFECTIVE=en xhy_t "$json")"
chk "JSON 逐字节不变" '[[ "$en" == "$json" ]]'
tsv='95	1.1.1.1	www.a.com	1.1.1.1:443'
en="$(XHY_LANG_EFFECTIVE=en xhy_t "$tsv")"
chk "TSV 逐字节不变" '[[ "$en" == "$tsv" ]]'
uri='vless://uuid@host:443?encryption=none&security=reality'
en="$(XHY_LANG_EFFECTIVE=en xhy_t "$uri")"
chk "分享链接逐字节不变" '[[ "$en" == "$uri" ]]'

echo "=== stdin / heredoc 模式 ==="
en="$(XHY_LANG_EFFECTIVE=en xhy_t <<'EOF'
---- 节点 ----
1) 添加节点
EOF
)"
chk "heredoc 纯 ASCII" '! printf "%s" "$en" | LC_ALL=C grep -q "[^ -~]"'
chk "heredoc 保留两行"  '[[ $(printf "%s\n" "$en" | wc -l | tr -d " ") -eq 2 ]]'
chk "heredoc 译出英文"  '[[ "$en" == *Nodes* ]]'

echo "=== printf 过滤器 ==="
t_filters() (
    XHY_LANG_EFFECTIVE=en
    xhy_install_output_filters
    local out v j
    out="$(printf '%s\n' '---- 节点 ----')"
    printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]' && return 1
    [[ "$out" == *Nodes* ]] || return 1
    printf -v v '%02X' 255
    [[ "$v" == FF ]] || return 1
    j='{"a":1}'
    [[ "$(printf '%s' "$j")" == "$j" ]] || return 1
    return 0
)
chk "printf 过滤 / -v 透传 / 数据不变" 't_filters'
chk "中文模式不重定义 printf" '( XHY_LANG_EFFECTIVE=zh xhy_install_output_filters; ! declare -F printf >/dev/null )'

echo "=== xhy_lang_init 判定表 ==="
chk "XHY_LANG=en -> en"        '( XHY_LANG=en xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'
chk "XHY_LANG=zh -> zh"        '( XHY_LANG=zh xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == zh ]] )'
chk "XHY_ASCII=1 -> en"        '( XHY_ASCII=1 xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'
chk "LANG=C -> en"             '( XHY_LANG=auto LANG=C LC_ALL=C TERM=xterm xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'
chk "TERM=linux 非中文 -> en"  '( XHY_LANG=auto LANG=en_US.UTF-8 TERM=linux xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'
chk "state 里 en -> en"        'state_set XHY_LANG en; ( XHY_LANG=auto xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'
chk "UTF-8 xterm 保持中文"     'state_del XHY_LANG; ( XHY_LANG=auto LANG=zh_CN.UTF-8 TERM=xterm-256color xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == zh ]] )'
chk "TERM=dumb 不是控制台，保持中文" 'state_del XHY_LANG; ( XHY_LANG=auto LANG=zh_CN.UTF-8 TERM=dumb xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == zh ]] )'
chk "空 LANG（Alpine 默认）保持中文" 'state_del XHY_LANG; ( XHY_LANG=auto LANG= LC_ALL= LC_CTYPE= TERM=xterm-256color xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == zh ]] )'
chk "空 LANG + 控制台 TERM -> en"   'state_del XHY_LANG; ( XHY_LANG=auto LANG= LC_ALL= LC_CTYPE= TERM=linux xhy_lang_init; [[ "$XHY_LANG_EFFECTIVE" == en ]] )'

echo "=== 源码接线 ==="
for spec in \
    "build.sh 把 i18n 拼进单文件|grep -q 'LIBS=(common i18n' build.sh" \
    "load_libs 加载 i18n|grep -q 'common i18n' test/_lib.sh" \
    "main 默认命令是 auto|grep -q 'local cmd=\"\${1:-auto}\"' entry/main.sh" \
    "main 调用 bootstrap_self|grep -q '^    bootstrap_self' entry/main.sh" \
    "main 调用 xhy_lang_init|grep -q '^    xhy_lang_init' entry/main.sh" \
    "main 安装输出过滤器|grep -q 'xhy_install_output_filters' entry/main.sh" \
    "菜单与安装打 ASCII banner|grep -q 'xhy_lang_banner' entry/main.sh" \
    "有 xhy lang 命令|grep -q 'lang)       cmd_lang' entry/main.sh" \
    "prelude 支持 XHY_LANG|grep -q 'XHY_LANG' entry/prelude.sh" \
    "永远可读的 ASCII 提示在 banner 里|grep -q 'boxes on VNC' lib/i18n.sh" \
    "英文帮助单独成文|grep -q 'modular Xray deployment manager' entry/main.sh" \
    "POSIX 段不污染 version 输出|! grep -q '^    _xhy_say \"\[\*\] xray-hy' entry/prelude.sh" \
    "usage 用 xhy_t heredoc|grep -q 'xhy_t <<EOF' entry/main.sh" \
    "target 展示文本用 xhy_t|grep -q \"xhy_t <<'EOF'\" lib/target.sh" \
    "配置片段仍用 cat 不走过滤器|grep -q '保持 cat，别走语言过滤器' lib/target.sh" \
    "ask 提示过 xhy_t|grep -q 'xhy_t \"\$p\"' lib/common.sh" \
    "英文模式硬保证纯 ASCII|grep -q \"LC_ALL=C tr -c '\" lib/i18n.sh" \
    "dumb 不算控制台终端|! grep -q 'linux|dumb|vt100' lib/i18n.sh" \
    "ASCII 快速路径存在|grep -q 'xhy_is_ascii' lib/i18n.sh" \
    "glob 元字符已转义|grep -qF '\\[0\\]' lib/i18n.sh"; do
    d="${spec%%|*}"; c="${spec#*|}"
    if eval "$c" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$d"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$d"; FAIL=$((FAIL + 1))
    fi
done

summary
