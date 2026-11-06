#!/usr/bin/env bash
# 版本号唯一入口 —— 不要手改 entry/prelude.sh 或 lib/common.sh 里的版本号。
#
#   tools/bump-version.sh <major|minor|patch|X.Y.Z> [--note "改动摘要"] [--no-test]
#
# 版本号规则（也写在 README「版本号与发布」里）：
#   major  X.0.0  不兼容变更：配置格式 / 目录结构 / CLI 语义变了，旧节点需要重建
#   minor  x.Y.0  新增功能、新命令、新交互，向后兼容
#   patch  x.y.Z  修 bug、改文案、小重构，不改变既有行为
#
# 它做的事：
#   1. 同时更新 entry/prelude.sh 与 lib/common.sh（build.sh 会校验两者一致）
#   2. 在 CHANGELOG.md 顶部插入一节（--note 可重复，每次一行）
#   3. 重新生成 install.sh
#   4. 跑 test/run-all.sh（--no-test 可跳过，不推荐）
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRELUDE="$ROOT/entry/prelude.sh"
COMMON="$ROOT/lib/common.sh"
CHANGELOG="$ROOT/CHANGELOG.md"

bump=""
notes=()
run_test=1
while (( $# > 0 )); do
    case "$1" in
        --note)    notes+=("$2"); shift 2 ;;
        --no-test) run_test=0; shift ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "未知参数: $1" >&2; exit 2 ;;
        *)         bump="$1"; shift ;;
    esac
done
[[ -n "$bump" ]] || { echo "用法: tools/bump-version.sh <major|minor|patch|X.Y.Z>" >&2; exit 2; }

cur="$(sed -n 's/^XHY_VERSION="\(.*\)"$/\1/p' "$PRELUDE" | head -1)"
[[ -n "$cur" ]] || { echo "读不到 XHY_VERSION（$PRELUDE）" >&2; exit 1; }
IFS=. read -r major minor patch <<<"$cur"

case "$bump" in
    major) new="$(( major + 1 )).0.0" ;;
    minor) new="$major.$(( minor + 1 )).0" ;;
    patch) new="$major.$minor.$(( patch + 1 ))" ;;
    [0-9]*.[0-9]*.[0-9]*) new="$bump" ;;
    *) echo "不认识的版本参数: $bump（major / minor / patch / X.Y.Z）" >&2; exit 2 ;;
esac

if [[ "$new" == "$cur" ]]; then
    echo "版本号没变（$cur），无需操作" >&2
    exit 1
fi

echo "[*] $cur -> $new"

sed -i "s|^XHY_VERSION=\"${cur}\"$|XHY_VERSION=\"${new}\"|" "$PRELUDE"
sed -i "s|^XHY_VERSION=\"\${XHY_VERSION:-${cur}}\"$|XHY_VERSION=\"\${XHY_VERSION:-${new}}\"|" "$COMMON"

got_prelude="$(sed -n 's/^XHY_VERSION="\(.*\)"$/\1/p' "$PRELUDE" | head -1)"
got_common="$(sed -n 's/^XHY_VERSION="\${XHY_VERSION:-\(.*\)}"$/\1/p' "$COMMON" | head -1)"
if [[ "$got_prelude" != "$new" || "$got_common" != "$new" ]]; then
    echo "[x] 版本号替换失败：prelude=$got_prelude common=$got_common（期望 $new）" >&2
    exit 1
fi
echo "[ok] prelude / common 均已更新为 $new"

# ---- CHANGELOG ----
today="$(date +%Y-%m-%d)"
section="## v${new} — ${today}"
if (( ${#notes[@]} == 0 )); then
    notes=("（待补：这次改了什么）")
fi
if [[ ! -f "$CHANGELOG" ]]; then
    {
        printf '# 变更记录\n\n'
        printf '版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。\n\n'
    } >"$CHANGELOG"
fi

tmp="$(mktemp "${CHANGELOG}.XXXXXX")"
{
    printf '%s\n\n' "$section"
    for n in "${notes[@]}"; do printf -- '- %s\n' "$n"; done
    printf '\n'
} >"$tmp.body"
awk -v body="$tmp.body" '
    BEGIN { done = 0 }
    {
        if (!done && $0 ~ /^## v/) {
            while ((getline line < body) > 0) print line
            close(body)
            done = 1
        }
        print
    }
    END {
        if (!done) {
            while ((getline line < body) > 0) print line
            close(body)
        }
    }' "$CHANGELOG" >"$tmp"
mv -f "$tmp" "$CHANGELOG"
rm -f "$tmp.body"
echo "[ok] CHANGELOG 已插入 $section"

# ---- 重建 + 测试 ----
"$ROOT/build.sh"
if (( run_test == 1 )); then
    ( cd "$ROOT" && bash test/run-all.sh )
fi

echo
echo "版本 $new 已就绪。下一步："
echo "  git add -A && git commit -m \"chore(release): v$new\" && git push"
echo "  （方式 A 安装的机器要等 release 发布；方式 B 直接 git pull）"
