#!/usr/bin/env bash
# Real Xray parser/key/certificate coverage, no services or iptables touched.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source test/_lib.sh
load_libs
need_root() { :; }
svc_restart() { :; }
target_validate() { :; }
target_tfo_detect() { return 1; }
bbr_ensure() { :; }
port_busy() { return 1; }
public_ip() { printf '192.0.2.1'; }
relay_fw_chain() { printf XHY-IN; }
relay_fw_add() { :; }
relay_fw_del() { :; }
confirm() { return 0; }
export XHY_RELAY_NO_TCP=1 XHY_SOCKOPT_AVAIL_CC=cubic
init_dirs
if [[ -n "${XRAY_TEST_BIN:-}" && -n "${XRAY_TEST_ASSET:-}" ]]; then
    XRAY_BIN="$XRAY_TEST_BIN"
    XRAY_ASSET="$XRAY_TEST_ASSET"
else
    export XHY_ARCH=64
    xray_install "${XHY_TEST_CORE_VERSION:-$XHY_PINNED_VERSION}"
fi
smoke() {
    if ! "$@" >"$TEST_TMP/core-case.log" 2>&1; then
        printf 'Real Xray case failed: %s\n' "$1" >&2
        cat "$TEST_TMP/core-case.log" >&2
        return 1
    fi
}
"$XRAY_BIN" version
smoke node_add direct 18080 --host 192.0.2.1
smoke node_add reality 18443 --host 192.0.2.1 --target www.microsoft.com:443 --sni www.microsoft.com
smoke node_add hy2 18444 --host 192.0.2.1
smoke relay_entry --to 10.0.0.2:14430 --categories openai --domains 'regexp:^(.+\.)?example\.com$'
xray_config_test
# A newer core rejects plaintext VLESS to a public IP. Verify that rejection
# rolls back the route and never substitutes the default outbound.
if [[ "${XHY_TEST_CORE_VERSION:-}" == v26.10.31 ]]; then
    cp "$XHY_ETC/config.json" "$TEST_TMP/valid-config.json"
    cp "$XHY_NODES/relay.env" "$TEST_TMP/valid-relay.env"
    if relay_entry --to 192.0.2.2:14430 --categories openai >"$TEST_TMP/rejected.log" 2>&1; then
        printf 'Unexpected acceptance of public plaintext relay\n' >&2
        exit 1
    fi
    grep -Fq 'vless without TLS or other encryption is prohibited' "$TEST_TMP/rejected.log"
    cmp "$TEST_TMP/valid-config.json" "$XHY_ETC/config.json"
    cmp "$TEST_TMP/valid-relay.env" "$XHY_NODES/relay.env"
fi

smoke relay_land --allow 192.0.2.2 --port 14430 --ip 192.0.2.1
smoke backup_create --out "$TEST_TMP/smoke.tgz"
smoke backup_restore "$TEST_TMP/smoke.tgz"
[[ "$(node_count)" == 3 ]]
[[ "$(stat -c %a "$XHY_CONFDIR")" == 700 ]]
[[ "$(stat -c %a "$XHY_CONFDIR/reality_18443.json")" == 600 ]]
[[ "$(stat -c %a "$XHY_CONFDIR/relay_in_14430.json")" == 600 ]]
grep -q 'in-relay-14430' "$XHY_ETC/config.json"
xray_config_test
printf 'Real Xray validation passed\n'
