#!/usr/bin/env bash
# check-docs 夹具运行器(版本化测试套件):逐个跑 check-docs.sh 样例,断言"只报预期的那一条规则"。
# 用法:bash scripts/repo/tests/check-docs/run-fixtures.sh(可从仓库任意工作目录运行)
# 末尾串联 extra-checks.sh(C1-C8 边界回归)与 extra-checks-c9.sh(C7/C9 边界与真实仓库样本),一条命令全跑。
# 目录约定:FIX 下是常驻样例;tmp-repo/ 是样例仓库模板(不含 check-docs 自身副本),
#   运行时复制到 .tmp/run/<样例名>/ 并注入当前 scripts/repo/check-docs*.sh 后执行;.tmp/ 不入库。
set -uo pipefail
FIX="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$FIX/../../../.." && pwd)"
SCRIPT="$ROOT/scripts/repo/check-docs.sh"
pass=0; bad=0

check() { # 样例名 / 目标(样例 md 相对 FIX 的路径,或 tmp-repo/<样例仓库名>)/ 期望规则(OK=零问题)/ 期望条数
  local name="$1" tgt="$2" rule="$3" want="$4" out code errs cnt verdict cmd
  if [ -d "$FIX/tmp-repo/$tgt" ]; then
    local d="$FIX/.tmp/run/$(basename "$tgt")"
    rm -rf "$d"; mkdir -p "$d/scripts/repo"
    cp -r "$FIX/tmp-repo/$tgt/." "$d/"
    cp "$ROOT"/scripts/repo/check-docs.sh "$ROOT"/scripts/repo/check-docs-lib.sh "$ROOT"/scripts/repo/check-docs-repo.sh "$d/scripts/repo/"
    out="$(cd "$d" && bash scripts/repo/check-docs.sh 2>&1)"; code=$?
    cmd="(样例仓库 .tmp/run/$(basename "$tgt")) bash scripts/repo/check-docs.sh"
  else
    out="$(bash "$SCRIPT" "$FIX/$tgt" 2>&1)"; code=$?
    cmd="bash scripts/repo/check-docs.sh scripts/repo/tests/check-docs/$tgt"
  fi
  errs="$(printf '%s\n' "$out" | grep -c '^ERROR ' || true)"
  if [ "$rule" = OK ]; then
    { [ "$errs" -eq 0 ] && [ "$code" -eq 0 ]; } && verdict=PASS || verdict=FAIL
  else
    cnt="$(printf '%s\n' "$out" | grep -c "^ERROR .* $rule " || true)"
    if [ "$cnt" -eq "$want" ] && [ "$cnt" -eq "$errs" ] && [ "$code" -eq 1 ]; then verdict=PASS; else verdict=FAIL; fi
  fi
  printf -- '--- [%s] %s(期望 %s x%s)\n$ %s\n%s\n' "$verdict" "$name" "$rule" "$want" "$cmd" "$(printf '%s\n' "$out" | sed 's/^/    /')"
  [ "$verdict" = PASS ] && pass=$((pass + 1)) || bad=$((bad + 1))
}

check "合规样例(零输出)"            ok/01-firmware.md       OK  0
check "C1 缺 ## 开始前"             c1/01-firmware.md       C1  1
check "C2 卡标题格式 + 卡号跳号"    c2/01-firmware.md       C2  2
check "C3 卡内缺 看到:"             c3/01-firmware.md       C3  1
check "C4 卡体 26 行"               c4/01-firmware.md       C4  1
check "C4 恰 25 行(边界,应过)"     c4-ok/01-firmware.md    OK  0
check "C5 卡编号引用无法解析"       c5/01-firmware.md       C5  1
check "C6 08 条目缺 -> 看到:"       c6/08-verification.md   C6  1
check "C7 跨文件锚点链接"           c7/notes.md             C7  1
check "C7 同文件锚点正例(应过)"     c7-self-ok/notes.md     OK  0
check "C7 同文件锚点负例"           c7-self-bad/notes.md    C7  1
check "C8 占位符"                   c8/notes.md             C8  1
check "C9a 卡内脚本路径不存在"      c9a/01-firmware.md      C9a 1
check "C9b 脚本缺 对应卡 头"        c9b                     C9b 1
check "C9b 脚本头卡号不存在"        c9b-card-missing        C9b 1
check "C9b 英文 # Card: 被接受"     c9b-card-en             OK  0
check "C9b 小写 # card: 被拒绝"     c9b-card-lower          C9b 1
check "C9c 步骤脚本无人引用"        c9c                     C9c 1
check "C9d 索引与脚本不一致"        c9d                     C9d 3
check "C9d 缺步骤索引"              c9d-missing             C9d 1
check "C9b 带 BOM 的 .ps1 卡头被承认" c9b-bom                OK  0
check "C9d 多卡列表头 + 多步复用(应过)" c9d-cardlist         OK  0
check "C9d 破坏性列不是 0/1"          c9d-destructive        C9d 1
check "C9d 索引步骤号重复"            c9d-dup                C9d 1

for extra in extra-checks.sh extra-checks-c9.sh; do
  echo
  echo "==== 附加回归:${extra} ===="
  out="$(bash "$FIX/$extra" 2>&1)"; printf '%s\n' "$out"
  p="$(printf '%s' "$out" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2)"
  b="$(printf '%s' "$out" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)"
  pass=$((pass + ${p:-0})); bad=$((bad + ${b:-0}))
done

printf '\n夹具结果:PASS=%s FAIL=%s\n' "$pass" "$bad"
[ "$bad" -eq 0 ] || exit 1
