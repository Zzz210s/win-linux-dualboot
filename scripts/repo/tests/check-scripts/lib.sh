#!/usr/bin/env bash
# check-scripts 夹具公共库:建临时镜像仓、跑门禁、断言输出标记。
# 用法:各 case-*.sh `source` 本文件,末尾调 summary。
# 设计:门禁 ROOT 由脚本自身位置推出,故镜像仓只放 scripts/repo/check-scripts.sh 即自洽;
#   本目录被 check-scripts.sh 的 find 以 `-not -path '*/tests/*'` 排除,不会自检(见其文件头注释)。
set -uo pipefail
CS_FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_ROOT="$(cd "$CS_FIX/../../../.." && pwd)"
# CS_SRC_OVERRIDE 供变异验证用:指向被故意改坏的副本,证明用例真会变红(不影响正常路径)。
CS_SRC="${CS_SRC_OVERRIDE:-$CS_ROOT/scripts/repo/check-scripts.sh}"
# 镜像仓放系统临时目录:放进本目录(路径含 /tests/)会被 check-scripts 自身的 `-not -path '*/tests/*'` 排除掉。
CS_TMP="$(mktemp -d)"; trap 'rm -rf "$CS_TMP"' EXIT
pass=0; bad=0
LAST_OUT=""

# 建镜像仓:<名字> -> 打印路径。调用方随后往仓里放夹具文件。
mk_repo() {
  local d="$CS_TMP/$1"
  rm -rf "$d"; mkdir -p "$d/scripts/repo"
  cp "$CS_SRC" "$d/scripts/repo/check-scripts.sh"
  printf '%s' "$d"
}
mk_git_repo() { local d; d="$(mk_repo "$1")"; git -C "$d" init -q; printf '%s' "$d"; }

# 跑门禁并留存输出/退出码
run_gate() {
  local d="$1"
  LAST_OUT="$(cd "$d" && bash scripts/repo/check-scripts.sh 2>&1)"
}

ok() { printf -- '--- [PASS] %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf -- '--- [FAIL] %s\n%s\n' "$1" "$(printf '%s\n' "$2" | sed 's/^/    /')"; bad=$((bad + 1)); }
skip() { printf -- '--- [SKIP] %s\n' "$1"; }
# 断言输出含 / 不含固定标记
want() { if printf '%s' "$LAST_OUT" | grep -qF -- "$2"; then ok "$1"; else ng "$1(缺标记: $2)" "$LAST_OUT"; fi; }
dont() { if printf '%s' "$LAST_OUT" | grep -qF -- "$2"; then ng "$1(不应出现: $2)" "$LAST_OUT"; else ok "$1"; fi; }
# 正则版断言(绝对路径里带临时目录前缀,用正则锁定文件名)
want_re() { if printf '%s' "$LAST_OUT" | grep -qE -- "$2"; then ok "$1"; else ng "$1(缺正则: $2)" "$LAST_OUT"; fi; }
dont_re() { if printf '%s' "$LAST_OUT" | grep -qE -- "$2"; then ng "$1(不应匹配正则: $2)" "$LAST_OUT"; else ok "$1"; fi; }
# 标记出现次数断言
cnt_is() { local c; c="$(printf '%s\n' "$LAST_OUT" | grep -cF -- "$2" || true)"; if [ "$c" -eq "$1" ]; then ok "$3"; else ng "$3(期望 $1 次,实为 $c 次)" "$LAST_OUT"; fi; }
summary() { printf '\nPASS=%s FAIL=%s\n' "$pass" "$bad"; [ "$bad" -eq 0 ] || exit 1; }
