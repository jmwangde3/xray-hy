#!/usr/bin/env bash
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
