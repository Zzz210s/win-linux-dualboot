#!/usr/bin/env bash
# check-scripts 夹具运行器:逐个跑 case-*.sh,汇总 PASS/FAIL。
# 用法:bash scripts/repo/tests/check-scripts/run-fixtures.sh(可从仓库任意工作目录运行)
# 目录约定:用例把临时镜像仓建在系统临时目录(mktemp -d,退出自动删除)。放本目录不行——镜像仓路径会含 /tests/,
#   被 check-scripts 自身的 `-not -path '*/tests/*'` 排除掉。镜像仓只放当前 scripts/repo/check-scripts.sh 的副本
#   + 故意造违规的夹具文件,门禁按脚本自身位置推 ROOT,故自洽。
# 自带自检:运行器与全部用例先 `bash -n`,坏夹具不得污染结论。
set -uo pipefail
FIX="$(cd "$(dirname "$0")" && pwd)"
pass=0; bad=0

for s in "$FIX/run-fixtures.sh" "$FIX"/lib.sh "$FIX"/case-*.sh; do
  bash -n "$s" || { echo "--- [FAIL] 夹具脚本语法错误:$s" >&2; exit 1; }
done

for c in "$FIX"/case-*.sh; do
  echo
  echo "==== ${c##*/} ===="
  out="$(bash "$c" 2>&1)"; printf '%s\n' "$out"
  p="$(printf '%s' "$out" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2)"
  b="$(printf '%s' "$out" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)"
  pass=$((pass + ${p:-0})); bad=$((bad + ${b:-0}))
done

printf '\n夹具结果:PASS=%s FAIL=%s\n' "$pass" "$bad"
[ "$bad" -eq 0 ] || exit 1
