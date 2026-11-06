#!/usr/bin/env bash
# 把 entry/ + lib/ + conf/ 拼成单文件 install.sh。
#
#   ./build.sh                 生成 ./install.sh
#   ./build.sh --check         只判断 install.sh 是否与源码一致（不写文件）
#   ./build.sh --stdout        打到标准输出（调试用）
#
# 构建号 = <git 短 hash>-<源码内容前 8 位>，只由源码决定，因此可以重复构建、
# 可以做 --check。install.sh 自身不参与计算，避免自我递归。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/install.sh"
LIBS=(common platform core service hardening target nodes links update)
PRELUDE="$ROOT/entry/prelude.sh"
MAIN="$ROOT/entry/main.sh"
TARGETS="$ROOT/conf/targets.tsv"

MODE="build"
case "${1:-}" in
    --check)  MODE="check" ;;
    --stdout) MODE="stdout" ;;
    "")       ;;
    *)        printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
esac

for f in "$PRELUDE" "$MAIN" "$TARGETS"; do
    [[ -f "$f" ]] || { printf '[x] 缺少 %s\n' "$f" >&2; exit 1; }
done
for l in "${LIBS[@]}"; do
    [[ -f "$ROOT/lib/$l.sh" ]] || { printf '[x] 缺少 lib/%s.sh\n' "$l" >&2; exit 1; }
done

# ---- 构建号 ----
# sha256sum 与 openssl 的输出格式不同（后者是 "SHA2-256(stdin)= <hex>"），
# 统一用正则把 64 位十六进制抓出来，避免取到文件名字段。
inputs_hash() {
    { cat "$PRELUDE" "$MAIN" "$TARGETS"
      for l in "${LIBS[@]}"; do cat "$ROOT/lib/$l.sh"; done
    } | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else openssl dgst -sha256; fi; } \
      | grep -oE '[0-9a-f]{64}' | head -1 | cut -c1-8
}
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUILD="${commit}-$(inputs_hash)"

# 去掉各 lib 的 shebang：拼进单文件后它是中间行，只是噪音。
strip_shebang() { sed '1{/^#!/d;}' "$1"; }

emit() {
    sed "s|__XHY_BUILD__|${BUILD}|" "$PRELUDE"
    for l in "${LIBS[@]}"; do
        printf '\n# ===================== lib/%s.sh =====================\n' "$l"
        strip_shebang "$ROOT/lib/$l.sh"
    done
    printf '\n# ============ 内嵌数据：conf/targets.tsv ============\n'
    printf 'targets_tsv() {\n'
    printf "    cat <<'XHY_TARGETS_TSV'\n"
    cat "$TARGETS"
    printf 'XHY_TARGETS_TSV\n'
    printf '}\n'
    printf '\n# ===================== entry/main.sh =====================\n'
    cat "$MAIN"
}

tmp="$(mktemp "${TMPDIR:-/tmp}/xhy-build.XXXXXX")"
# 某些受限环境会拦截 rm 并返回非零，不能让它污染退出码；留着临时文件无害。
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
emit >"$tmp"
chmod 0755 "$tmp"

# 拼出来的东西必须还能被 bash 解析：单文件最容易在这里出问题（漏了分隔、
# 只拼了一半的函数），所以在写盘之前就拦住。
if ! bash -n "$tmp" >/dev/null 2>&1; then
    printf '[x] 生成的 install.sh 未通过 bash -n：\n' >&2
    bash -n "$tmp" || true
    exit 1
fi

case "$MODE" in
    stdout) cat "$tmp" ;;
    check)
        if [[ ! -f "$OUT" ]]; then
            printf '[x] install.sh 不存在，先跑 ./build.sh\n' >&2
            exit 1
        fi
        if cmp -s "$tmp" "$OUT"; then
            printf '[ok] install.sh 与源码一致 (build %s)\n' "$BUILD"
        else
            printf '[x] install.sh 与源码不一致，重新跑 ./build.sh\n' >&2
            diff -u "$OUT" "$tmp" | head -40 >&2 || true
            exit 1
        fi
        ;;
    build)
        mv -f "$tmp" "$OUT"
        trap - EXIT
        printf '[ok] %s\n     build %s, %s 字节\n' "$OUT" "$BUILD" "$(wc -c <"$OUT" | tr -d ' ')"
        ;;
esac
