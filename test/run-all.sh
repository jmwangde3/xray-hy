#!/usr/bin/env bash
# Run every offline test plus the syntax gate. No root, no network, no writes
# outside a temp directory.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

echo "=== bash -n ==="
rc=0
for f in xhy install.sh build.sh entry/*.sh lib/*.sh test/*.sh; do
    [[ -f "$f" ]] || { printf '  SKIP  %s（不存在，先跑 ./build.sh）\n' "$f"; continue; }
    if bash -n "$f"; then printf '  ok    %s\n' "$f"; else printf '  FAIL  %s\n' "$f"; rc=1; fi
done
(( rc == 0 )) || { echo "syntax errors, aborting"; exit 1; }

total_fail=0

# 单文件发布是构建产物，必须与源码保持一致，否则线上跑的和仓库里的不是一版。
echo ""
echo "=== ./build.sh --check ==="
if ./build.sh --check; then :; else total_fail=$((total_fail + 1)); fi

for t in test/render-test.sh test/hy2-test.sh test/export-test.sh test/lifecycle-test.sh test/target-test.sh; do
    echo ""
    echo "########## $t ##########"
    if bash "$t"; then :; else total_fail=$((total_fail + 1)); fi
done

echo ""
if (( total_fail == 0 )); then
    echo "ALL TEST FILES PASSED"
else
    echo "$total_fail TEST FILE(S) FAILED"
    exit 1
fi
