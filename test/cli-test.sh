#!/usr/bin/env bash
# CLI dispatch regression: `xhy update` without a subcommand must reach
# update_all instead of dying on an unconditional `shift` under errexit.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source test/_lib.sh
load_libs
stub_system
make_stub_xray
source <(sed '/^main "\$@"$/d' entry/main.sh)
init_dirs

# main() does platform detection, locking and self-bootstrap before it
# dispatches. Replace only those entry-point side effects; the dispatch table
# itself stays real. bootstrap_self MUST be stubbed: it would otherwise
# install the dev script over /usr/local/bin/xhy.
xhy_lang_init() { :; }
xhy_install_output_filters() { :; }
detect_platform() { :; }
acquire_lock() { :; }
release_lock() { :; }
bootstrap_self() { :; }

update_all()      { printf 'update_all|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }
update_continue() { printf 'update_continue|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }
update_script()   { printf 'update_script|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }
update_core()     { printf 'update_core|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }
update_geodata()  { printf 'update_geodata|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }
update_config()   { printf 'update_config|%s\n' "$*" >>"$TEST_TMP/calls"; return 0; }

# Production runs under `set -Eeuo pipefail`. An unconditional `shift` on an
# empty argument list returns 1 and there kills the whole script; reproduce
# exactly those settings in a subshell so the test cannot kill itself.
run_main() ( set -Eeuo pipefail; main "$@" )
last_call() { tail -1 "$TEST_TMP/calls" 2>/dev/null || true; }

: >"$TEST_TMP/calls"
run_main update >/dev/null 2>&1
rc=$?
chk 'xhy update (no subcommand) exits 0' '[[ "$rc" == 0 ]]'
chk 'xhy update dispatches update_all' '[[ "$(last_call)" == "update_all|" ]]'

: >"$TEST_TMP/calls"
run_main update all >/dev/null 2>&1
rc=$?
chk 'xhy update all exits 0' '[[ "$rc" == 0 ]]'
chk 'xhy update all dispatches update_all' '[[ "$(last_call)" == "update_all|" ]]'

: >"$TEST_TMP/calls"
run_main update all --yes >/dev/null 2>&1
rc=$?
chk 'xhy update all --yes forwards --yes' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_all|--yes" ]]'

: >"$TEST_TMP/calls"
run_main update script >/dev/null 2>&1
rc=$?
chk 'xhy update script exits 0' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_script|" ]]'

: >"$TEST_TMP/calls"
run_main update script --yes >/dev/null 2>&1
rc=$?
chk 'xhy update script --yes forwards --yes' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_script|--yes" ]]'

: >"$TEST_TMP/calls"
run_main update core >/dev/null 2>&1
rc=$?
chk 'xhy update core exits 0' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_core|" ]]'

: >"$TEST_TMP/calls"
run_main update geodata --force >/dev/null 2>&1
rc=$?
chk 'xhy update geodata --force forwards --force' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_geodata|--force" ]]'

: >"$TEST_TMP/calls"
run_main update config >/dev/null 2>&1
rc=$?
chk 'xhy update config exits 0' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_config|" ]]'

: >"$TEST_TMP/calls"
run_main update _continue 1 >/dev/null 2>&1
rc=$?
chk 'xhy update _continue 1 forwards chain id' \
    '[[ "$rc" == 0 && "$(last_call)" == "update_continue|1" ]]'

run_main update bogus >/dev/null 2>&1
rc=$?
chk 'unknown update subcommand is rejected' '[[ "$rc" != 0 ]]'

chk 'xhy --version prints version' \
    '[[ "$(run_main --version 2>/dev/null)" == xray-hy\ * ]]'
run_main --help >/dev/null 2>&1
rc=$?
chk 'xhy --help exits 0' '[[ "$rc" == 0 ]]'

chk 'update all guard is conditional (no bare shift)' \
    'grep -q "all) if (( \$# )); then shift; fi; update_all" entry/main.sh'

summary
