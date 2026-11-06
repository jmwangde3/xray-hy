#!/usr/bin/env bash
# Shared bootstrap for the offline test suite.
#
# Everything here runs without a real Xray binary, without root and without
# network access: module code is exercised against a stub `xray` and stubbed
# service helpers, so the tests are safe to run on any machine (including the
# developer's laptop and CI).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prefer $PY, then python3, then python -- some Git-for-Windows setups only
# expose one of them, and a missing interpreter silently skipped the JSON
# assertions in earlier rounds.
if [[ -z "${PY:-}" ]]; then
    for _c in python3 python; do
        if command -v "$_c" >/dev/null 2>&1; then PY="$_c"; break; fi
    done
fi
[[ -n "${PY:-}" ]] || { echo "ERROR: no python interpreter found (set PY=...)" >&2; exit 1; }

# A ":" in a temp path makes GNU tar treat the archive name as host:file. Never
# happens on Linux; keeps the suite runnable under Git Bash too.
export TMPDIR="${TMPDIR_OVERRIDE:-/tmp}"
TEST_TMP="$(mktemp -d "${TMPDIR}/xhy-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

export XHY_SCRIPT_DIR="$REPO" XHY_HOME="$REPO"
export XHY_ETC="$TEST_TMP/etc" XHY_LOGDIR="$TEST_TMP/log"
export XRAY_BIN="$TEST_TMP/bin/xray" XRAY_ASSET="$TEST_TMP/asset"
export CF_BIN="$TEST_TMP/bin/cloudflared"

# openssl -subj "/CN=..." is rewritten into a drive path by MSYS on Windows.
export MSYS2_ARG_CONV_EXCL='/CN;DNS'

load_libs() {
    local l
    for l in common sockopt platform core service hardening target scanner nodes links export backup update; do
        # shellcheck disable=SC1090
        source "$REPO/lib/$l.sh"
    done
}

# Replace everything that would touch the real system.
stub_system() {
    need_root() { :; }
    svc_start() { :; }; svc_restart() { :; }; svc_stop() { :; }
    svc_enable() { :; }; svc_disable() { :; }; svc_active() { return 1; }
    config_reload() { return 0; }
    xray_config_test() { return 0; }
    firewall_apply() { :; }
    install_cf_service() { :; }
    target_validate() { return 0; }
    # 内核调优必须离线：bbr_ensure / tune_bbr 会写 /etc/sysctl.d 并 modprobe。
    # bbr-test.sh 不调 stub_system，自己注入 sysctl 来测决策逻辑。
    bbr_ensure() { return 0; }
    tune_bbr() { return 0; }
    # TFO 探测会真的打外网；离线默认「目标不支持」，auto 因此判定为关。
    # tfo-test.sh 自己注入 curl/nstat 来测决策逻辑。
    target_tfo_detect() { return 1; }
}

# Minimal stand-in for the real binary: only the subcommands the script calls.
make_stub_xray() {
    mkdir -p "$(dirname "$XRAY_BIN")" "$XRAY_ASSET"
    cat >"$XRAY_BIN" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  version) echo "Xray 26.3.27 (stub) 0000000 (go1.24 linux/amd64)" ;;
  uuid)    cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "b831381d-6324-4d53-ad4f-8cda48b30811" ;;
  x25519)  echo "PrivateKey: PRIV$(date +%s%N | cut -c1-24)"
           echo "Password (PublicKey): PUB$(date +%s%N | cut -c1-24)" ;;
  run)     echo "Configuration OK." ;;
  tls)     echo "TLS 1.3 handshake succeeded" ;;
  *)       exit 0 ;;
esac
STUB
    chmod 0755 "$XRAY_BIN"
}

PASS=0
FAIL=0
chk() { # chk <label> <shell-test>
    if eval "$2" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1))
    fi
}

summary() {
    printf '\n%s\nPASS=%d FAIL=%d\n' "---------------------------------------" "$PASS" "$FAIL"
    [[ "$FAIL" -eq 0 ]]
}
