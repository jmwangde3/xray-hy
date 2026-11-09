#!/usr/bin/env bash
# Regression tests for failures at config, backup and update boundaries.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source test/_lib.sh
# This file asserts real rollback, so keep the full transaction snapshot even
# on MSYS where the rest of the suite skips it for speed.
export XHY_TX_SKIP_SNAPSHOT=0
load_libs
stub_system
make_stub_xray
source <(sed '/^main "\$@"$/d' entry/main.sh)
init_dirs
export XHY_RELAY_NO_TCP=1
public_ip() { printf '192.0.2.1'; }
relay_fw_chain() { printf XHY-IN; }
relay_fw_add() { return 0; }
relay_fw_del() { return 0; }
confirm() { return 0; }
disk_need() { return 0; }

node_save "$XHY_NODES/direct_8080.env" MODE=direct PORT=8080 UUID=fake NODE_PATH=/test PUBLIC=1
write_fragment "$XHY_NODES/direct_8080.env" || exit 1
relay_land --allow 192.0.2.2 --port 14430 --uuid fake --ip 192.0.2.1 >/dev/null || exit 1
backup_create --out "$TEST_TMP/valid.tgz" >/dev/null || exit 1
printf '{"tag":"obsolete"}\n' >"$XHY_CONFDIR/relay_in_14430.json"
chk 'reapply updates an existing landing fragment' 'relay_reapply && grep -q "in-relay-14430" "$XHY_CONFDIR/relay_in_14430.json"'
rm -f "$XHY_NODES/direct_8080.env"
chk 'restore round trip with relay' 'backup_restore "$TEST_TMP/valid.tgz" && [[ $(node_count) == 1 ]] && grep -q "in-relay-14430" "$XHY_ETC/config.json"'
cp "$XHY_ETC/config.json" "$TEST_TMP/good.json"
cp "$XHY_STATE" "$TEST_TMP/good-state"
mkdir -p "$TEST_TMP/tampered"
tar -xzf "$TEST_TMP/valid.tgz" -C "$TEST_TMP/tampered" || exit 1
printf 'extra=1\n' >"$TEST_TMP/tampered/payload/nodes/extra.env"
tar -czf "$TEST_TMP/tampered.tgz" -C "$TEST_TMP/tampered" payload manifest.tsv || exit 1
chk 'unlisted archive members are rejected' '! backup_restore "$TEST_TMP/tampered.tgz" && cmp -s "$TEST_TMP/good.json" "$XHY_ETC/config.json"'
xray_config_test() { return 1; }
chk 'failed validation preserves the active config' '! relay_reapply && cmp -s "$TEST_TMP/good.json" "$XHY_ETC/config.json"'
chk 'failed setting restores the registry' '! cmd_config_set ACCESS_LOG on && cmp -s "$TEST_TMP/good-state" "$XHY_STATE"'
chk 'failed restore preserves both config and registry' '! backup_restore "$TEST_TMP/valid.tgz" && cmp -s "$TEST_TMP/good.json" "$XHY_ETC/config.json" && [[ $(node_count) == 1 ]]'
xray_config_test() { return 0; }
source <(sed -n '/^config_reload()/,/^}/p' lib/service.sh)
svc_restart() {
    if [[ -e "$TEST_TMP/restart-attempt" ]]; then
        printf recovered >"$TEST_TMP/restart-attempt"
        return 0
    fi
    printf failed >"$TEST_TMP/restart-attempt"
    return 1
}
chk 'restart failure restores and restarts the previous config' \
    '! cmd_config_set ACCESS_LOG on && cmp -s "$TEST_TMP/good.json" "$XHY_ETC/config.json" && cmp -s "$TEST_TMP/good-state" "$XHY_STATE" && [[ "$(cat "$TEST_TMP/restart-attempt")" == recovered ]]'
config_reload() { return 0; }
chk 'setting returns zero and applies ACCESS_LOG' 'cmd_config_set ACCESS_LOG on && [[ "$(state_get ACCESS_LOG off)" == on ]] && grep -q xray-access.log "$XHY_ETC/config.json"'
chk 'ordinary setting succeeds with firewall off' 'cmd_config_set BLOCK_BT off && [[ "$(state_get BLOCK_BT)" == off ]]'

pattern='regexp:^(.+\.)?example\.com$'
chk 'regex survives entry setup and reload' 'relay_entry --to 192.0.2.2:14430 --uuid fake --domains "$pattern" && relay_env_load && [[ "$RELAY_DOMAINS" == "$pattern" ]]'
printf 'RELAY_DOMAINS=regexp:$(touch${IFS}%s)\n' "$TEST_TMP/unexpected" >>"$XHY_NODES/relay.env"
chk 'relay state is treated as data' 'relay_env_load && [[ "$RELAY_DOMAINS" == *"\$(touch"* && ! -e "$TEST_TMP/unexpected" ]]'

# Download or install failures must preserve the exact pair and marker.
for f in geoip.dat geosite.dat; do printf 'existing-%s' "$f" >"$XRAY_ASSET/$f"; done
printf 'loyalsoldier\n' >"$XRAY_ASSET/.geodata-source"
fetch() {
    case "$1" in
        */geoip.dat) head -c 102400 /dev/zero >"$2" ;;
        */geoip.dat.sha256sum) sha256sum "${2%.sum}" >"$2" ;;
        *) return 1 ;;
    esac
}
chk 'second geodata download failure preserves first file and marker' \
    '! update_geodata --force && [[ "$(cat "$XRAY_ASSET/geoip.dat")" == existing-geoip.dat && "$(cat "$XRAY_ASSET/geosite.dat")" == existing-geosite.dat && "$(cat "$XRAY_ASSET/.geodata-source")" == loyalsoldier ]]'
mkdir -p "$TEST_TMP/release"
cp "$XRAY_BIN" "$TEST_TMP/release/xray"
verify_release_digest() { return 0; }
disk_free_mb() { printf 1000; }
export XHY_ARCH=64
fetch() { case "$1" in *Loyalsoldier*) return 1;; *) printf bundle >"$2";; esac; }
unzip() {
    local dest
    while (($#)); do
        if [[ "$1" == -d ]]; then dest="$2"; shift; fi
        shift
    done
    cp "$TEST_TMP/release/xray" "$dest/xray"
    printf official >"$dest/geoip.dat"
    printf official >"$dest/geosite.dat"
}
chk 'core update with failed Loyalsoldier download retains existing data' \
    'xray_install v26.3.27 && [[ "$(cat "$XRAY_ASSET/geosite.dat")" == existing-geosite.dat && "$(cat "$XRAY_ASSET/.geodata-source")" == loyalsoldier ]]'

# Validate the install-to-new-process handoff with actual script replacement.
export XHY_BINDIR="$TEST_TMP/updater" XHY_SCRIPT_DIR="$TEST_TMP/not-repo" XHY_LEGACY_SELF="$TEST_TMP/no-legacy"
mkdir -p "$XHY_BINDIR"
XHY_SELF="$XHY_BINDIR/xhy" XHY_BUILD=111111111111 XHY_VERSION=1.14.5
printf '#!/usr/bin/env bash\nXHY_VERSION="1.14.5"\nXHY_BUILD="111111111111"\nXHY_RELAY_SCHEMA="4"\n' >"$XHY_SELF"
cat >"$TEST_TMP/candidate.sh" <<'NEW'
#!/usr/bin/env bash
XHY_VERSION="1.14.6"
XHY_BUILD="222222222222"
XHY_RELAY_SCHEMA="5"
XHY_UPDATE_CHAIN="1"
[[ ! -d "$XHY_ETC/.lock.d" && ! -e /dev/fd/9 ]] || exit 98
printf '%s\n' "$*" >"$XHY_ETC/new-process"
NEW
fetch() { cp "$TEST_TMP/candidate.sh" "$2"; }
update_core() { printf old >"$XHY_ETC/old-process"; }
(
    XHY_LOCK_MODE=dir
    mkdir "$XHY_ETC/.lock.d"
    exec 9>"$TEST_TMP/fake-lock-fd"
    update_all --yes
) >"$TEST_TMP/upgrade.log" 2>&1
rc=$?
chk 'full upgrade delegates only to the new process with lock FD closed' \
    '[[ "$rc" == 0 && "$(cat "$XHY_ETC/new-process")" == "update _continue 1" && ! -e "$XHY_ETC/old-process" ]]'

# v1.14.5 and earlier packed `cp -a "$XHY_ETC/."`, so archives also carry
# internal-state entries (.lock / .lock.d/ / snapshots/). The v1.14.6
# whitelist must still accept and ignore them instead of refusing the restore.
mkdir -p "$TEST_TMP/legacy"
tar -xzf "$TEST_TMP/valid.tgz" -C "$TEST_TMP/legacy" || exit 1
mkdir -p "$TEST_TMP/legacy/payload/.lock.d" "$TEST_TMP/legacy/payload/snapshots"
printf 'stale\n' >"$TEST_TMP/legacy/payload/.lock"
printf 'old\n' >"$TEST_TMP/legacy/payload/snapshots/old.json"
{
    printf '# xray-hy backup manifest v1\n'
    ( cd "$TEST_TMP/legacy/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) |
        while IFS= read -r f; do
            printf '%s\t%s\t%s\n' \
                "$(sha256sum "$TEST_TMP/legacy/payload/$f" | awk '{print $1}')" \
                "$(wc -c <"$TEST_TMP/legacy/payload/$f" | tr -d '[:space:]')" "$f"
        done
} >"$TEST_TMP/legacy/manifest.tsv"
tar -czf "$TEST_TMP/legacy.tgz" -C "$TEST_TMP/legacy" payload manifest.tsv || exit 1
chk 'legacy backup with internal-state entries is accepted' \
    'backup_restore "$TEST_TMP/legacy.tgz" && [[ $(node_count) == 1 ]]'
chk 'legacy internal-state entries are not restored into etc' \
    '[[ ! -e "$XHY_ETC/.lock" && ! -e "$XHY_SNAPSHOTS/old.json" ]]'
summary
