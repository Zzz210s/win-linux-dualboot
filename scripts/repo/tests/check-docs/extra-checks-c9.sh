#!/usr/bin/env bash
# 附加回归 2:C7 锚点(F2)、C9a 反斜杠(F1)、仓库级 C9b/C9c 目录(F9)、
# 白名单与设计文档一致性(F7)、--repo 开关(F12)与真实仓库样本。
# 用法:bash scripts/repo/tests/check-docs/extra-checks-c9.sh —— 末行 `PASS=n FAIL=m`,FAIL 非零时退出码 1。
set -uo pipefail
FIX="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$FIX/../../../.." && pwd)"
SCRIPT="$ROOT/scripts/repo/check-docs.sh"
W="$FIX/.tmp/extra2"; rm -rf "$W"; mkdir -p "$W"
pass=0; bad=0; LAST_OUT=""

verdict() { # 判定(0=通过) / 名称 / 输出
  if [ "$1" -eq 0 ]; then printf -- '--- [PASS] %s\n' "$2"; pass=$((pass + 1))
  else printf -- '--- [FAIL] %s\n%s\n' "$2" "$(printf '%s\n' "$3" | sed 's/^/    /')"; bad=$((bad + 1)); fi
}
judge() { # 名称 / 期望规则(OK=零问题)/ 条数 / 输出 / 退出码
  local name="$1" rule="$2" want="$3" out="$4" rc="$5" errs cnt v=1
  LAST_OUT="$out"
  errs="$(printf '%s\n' "$out" | grep -c '^ERROR ' || true)"
  if [ "$rule" = OK ]; then
    { [ "$errs" -eq 0 ] && [ "$rc" -eq 0 ]; } && v=0
  else
    cnt="$(printf '%s\n' "$out" | grep -c "^ERROR .* $rule " || true)"
    { [ "$cnt" -eq "$want" ] && [ "$cnt" -eq "$errs" ] && [ "$rc" -eq 1 ]; } && v=0
  fi
  verdict "$v" "$name(期望 $rule x$want)" "$out"
}
runcheck() { # 名称 / 规则 / 条数 / 文件路径
  local out rc; out="$(bash "$SCRIPT" "$4" 2>&1)"; rc=$?; judge "$1" "$2" "$3" "$out" "$rc"
}
t() { # 名称 / 规则 / 条数 / 相对路径 —— 文件内容由 stdin 提供
  local rel="$4"; mkdir -p "$W/$(dirname "$rel")"; cat > "$W/$rel"
  runcheck "$1" "$2" "$3" "$W/$rel"
}
has() { # 名称 / 期望出现在上一条用例输出中的原文
  if printf '%s' "$LAST_OUT" | grep -qF -- "$2"; then verdict 0 "$1"; else verdict 1 "$1" "$LAST_OUT"; fi
}

# ==== F2:C7 同文件锚点(连字符/下划线/重复标题,以及空锚点) ==================
runcheck "F2b C7 连字符/下划线/重复标题锚点正例(应过)" OK 0 "$FIX/c7-self-ok/notes.md"
runcheck "F2b C7 同文件锚点负例" C7 1 "$FIX/c7-self-bad/notes.md"
has "F2b 报错打印原始锚点原文(不是归一化结果)" "#小节-a-b-c"
t "F2a C7 空锚点 ](#) 不再误报(应过)" OK 0 docs/notes.md <<'EOF'
# 夹具:C7 空锚点

## 小节

见 [页首](#) 与 [小节](#小节)。
EOF
t "F2b C7 锚点漏报修复(下划线来源缺标题要报)" C7 1 docs/notes.md <<'EOF'
# 夹具:C7 下划线

## 小节a

见 [错位](#小节_a)。
EOF
t "F2b C7 ASCII 连字符漏报修复(repositorylayout)" C7 1 docs/notes.md <<'EOF'
# 夹具:C7 连字符

## Repository layout

见 [错位](#repositorylayout)。
EOF

# ==== F1:C9a 卡内反斜杠路径(F1) =============================================
t "F1 C9a 反斜杠路径受检" C9a 1 docs/01-firmware.md <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
- 丙

### 01-1 甲

做:甲。

  1. 做甲
     看到:完成
坑:坑。
出错时:去向 -> 01-1。
脚本:scripts\windows\absent-xyz.ps1 --check
EOF
has "F1 C9a 报错路径已归一成正斜杠" "scripts/windows/absent-xyz.ps1"

# ==== W5:C8 相对链接的标题段(剥掉 "标题" / '标题' / (标题) 后判存在性) ====
D8="$W/c8-title"; mkdir -p "$D8/docs"; : >"$D8/docs/target.md"
cat > "$D8/docs/notes.md" <<'EOF'
# 夹具:C8 带标题的链接

见 [目标](target.md "标题") 与 [目标2](target.md '标题') 与 [目标3](target.md (标题))。
EOF
runcheck "W5a C8 带标题(双/单引号/括号)的合法链接不误报(应过)" OK 0 "$D8/docs/notes.md"
cat > "$D8/docs/bad.md" <<'EOF'
# 夹具:C8 带标题的坏链

见 [坏](absent.md "标题")。
EOF
runcheck "W5b C8 带标题的坏链仍报目标不存在" C8 1 "$D8/docs/bad.md"
has "W5b 报错保留剥标题后的原始目标文本" "相对链接目标不存在: absent.md"

# ==== F9:仓库级扫描目录含 scripts/repo =======================================
D="$W/repo-f9"; mkdir -p "$D/docs" "$D/scripts/repo"
cp "$ROOT"/scripts/repo/check-docs*.sh "$ROOT"/scripts/repo/check-docs*.awk "$D/scripts/repo/"
cat > "$D/docs/01-firmware.md" <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
- 丙

### 01-1 甲

做:甲。

  1. 做甲
     看到:完成
坑:坑。
出错时:去向 -> 01-1。
脚本:scripts/repo/loose.sh --check
EOF
printf '#!/usr/bin/env bash\necho loose\n' > "$D/scripts/repo/loose.sh"
out="$(cd "$D" && bash scripts/repo/check-docs.sh 2>&1)"; rc=$?
judge "F9 scripts/repo 下未白名单脚本受检" C9b 1 "$out" "$rc"
has "F9 报错指向 scripts/repo/loose.sh" "scripts/repo/loose.sh:1 C9b"

# ==== F7:白名单与设计文档 §4 C9d 名单一致,且 dbk-apt.sh 不再报红 ============
# shellcheck disable=SC2097,SC2098  # 前缀赋值 ROOT= 只给被 fork 的 bash;`$ROOT/...` 参数由父 shell 展开,两者同值
WLLIB="$(ROOT="$ROOT" bash -c '. "$1"; printf "%s\n" $WL' _ "$ROOT/scripts/repo/check-docs-lib.sh" | grep -v '^$' | sort)"
DOCWL="$(sed -n '/^| C9d /p' "$ROOT/docs/design/03-step-automation-design.md" | grep -oE '`scripts/[^`]+\.(sh|ps1)`' | tr -d '`' | sort)"
d="$(diff <(printf '%s\n' "$WLLIB") <(printf '%s\n' "$DOCWL") 2>&1)"
verdict "$([ -z "$d" ] && echo 0 || echo 1)" "F7 白名单与设计文档 C9d 名单逐行一致" "$d"
# 整仓扫描输出只跑一次(F12a 也复用它做仓库级参照,避免重复跑 check-docs-repo.sh)。
full_out="$(bash "$SCRIPT" 2>&1)"
if printf '%s' "$full_out" | grep -q 'dbk-apt'; then
  verdict 1 "F7 dbk-apt.sh 已在白名单(不再报 C9b/C9c)" "$(printf '%s\n' "$full_out" | grep 'dbk-apt')"
else verdict 0 "F7 dbk-apt.sh 已在白名单(不再报 C9b/C9c)"; fi

# ==== F12:--repo 在单文件模式下追加仓库级 C9b/C9c/C9d ========================
out="$(bash "$SCRIPT" "$ROOT/docs/00-overview.md" 2>&1)"; rc=$?
judge "F12 不带 --repo:单文件模式无仓库级规则" OK 0 "$out" "$rc"
# F12a:真实仓库 --repo 追加的仓库级条数必须与整仓扫描逐类一致。
# 复用 F7 的 full_out(已含 check-docs-repo.sh 的仓库级输出),不再单独跑一遍 check-docs-repo.sh(单跑 ~100s);
# 断言而不是“非零”:C9b/C9c 会随文档任务推进而变化甚至清零,该真实仓库可能本来就无 C9b/C9c。
# 另断言 --repo 输出里除 C9b/C9c/C9d 外无其它 ERROR(被测文件 docs/00-overview.md 本身干净),
# 从而证明追加的确实是仓库级规则,而不是被测文件自己的问题。
out="$(bash "$SCRIPT" --repo "$ROOT/docs/00-overview.md" 2>&1)"; rc=$?
f12a_ok=1
for r in C9b C9c C9d; do
  a="$(printf '%s\n' "$full_out" | grep -c " $r " || true)"; b="$(printf '%s\n' "$out" | grep -c " $r " || true)"
  [ "$a" -eq "$b" ] || f12a_ok=0
done
other="$(printf '%s\n' "$out" | grep '^ERROR ' | grep -vcE ' C9[bcd] ' || true)"
[ "$other" -eq 0 ] || f12a_ok=0
if [ "$f12a_ok" -eq 1 ]; then verdict 0 "F12a 真实仓库 --repo 追加的 C9b/C9c/C9d 条数与整仓扫描一致(复用 F7 输出)"
else verdict 1 "F12a 真实仓库 --repo 追加条数与整仓扫描不一致" "$out"; fi
# F12c:临时仓库(存在未被任何卡引用的步骤脚本)→ --repo 在单文件模式下追加 C9c
D12c="$W/repo-f12c"; mkdir -p "$D12c/scripts/repo"
cp -r "$FIX/tmp-repo/c9c/." "$D12c/"
cp "$ROOT"/scripts/repo/check-docs*.sh "$ROOT"/scripts/repo/check-docs*.awk "$D12c/scripts/repo/"
out="$(cd "$D12c" && bash scripts/repo/check-docs.sh --repo docs/01-firmware.md 2>&1)"; rc=$?
n_c="$(printf '%s\n' "$out" | grep -c ' C9c ' || true)"
if [ "$rc" -eq 1 ] && [ "$n_c" -ge 1 ]; then verdict 0 "F12c --repo 在单文件模式下追加 C9c(临时仓库:步骤脚本无人引用)"
else verdict 1 "F12c --repo 未追加 C9c(rc=$rc C9c=$n_c)" "$out"; fi
# F12b:临时仓库(同一 (步骤号, 脚本) 对重复)→ --repo 必须把 C9d 一并追加进来
D12="$W/repo-f12"; mkdir -p "$D12/scripts/repo"
cp -r "$FIX/tmp-repo/c9d-dup/." "$D12/"
cp "$ROOT"/scripts/repo/check-docs*.sh "$ROOT"/scripts/repo/check-docs*.awk "$D12/scripts/repo/"
out="$(cd "$D12" && bash scripts/repo/check-docs.sh --repo docs/01-firmware.md 2>&1)"; rc=$?
n_d="$(printf '%s\n' "$out" | grep -c ' C9d ' || true)"
if [ "$rc" -eq 1 ] && [ "$n_d" -ge 1 ]; then verdict 0 "F12b --repo 也会追加 C9d(临时仓库:同一 (步骤号, 脚本) 对重复)"
else verdict 1 "F12b --repo 未追加 C9d(rc=$rc C9d=$n_d)" "$out"; fi

# ==== 真实仓库样本(原补充 7/8/9) =============================================
for f in docs/00-overview.md README.md README.zh-CN.md checklists/deploy.md checklists/rollback.md \
         baseline/README.md docs/design/00-design.md docs/design/03-step-automation-design.md \
         docs/design/02-fedora-atomic-variant-design.md; do   # 02 号(现行:本次回切后 02 升为现行真源,04 已标废止)
  runcheck "真实样本 $f(应过)" OK 0 "$ROOT/$f"
done
runcheck "设计文档 01(应过:卡编号引用按编号回退到手册解析)" OK 0 "$ROOT/docs/design/01-playbook-reshape-design.md"
runcheck "设计文档 04(应过:04-* 是设计文档序号,卡 04-2 在 docs/04-*.md 里)" OK 0 "$ROOT/docs/design/04-kubuntu-variant-design.md"

# ==== D5:夹具运行器语法自检(bash -n) ====================================
SYNOK="$W/syn-ok"; rm -rf "$SYNOK"; mkdir -p "$SYNOK"; printf '#!/usr/bin/env bash\necho ok\n' > "$SYNOK/a.sh"
out="$(bash "$FIX/run-fixtures.sh" --syntax-only "$SYNOK" 2>&1)"; rc=$?
judge "D5 夹具语法自检:干净目录退 0 且无输出" OK 0 "$out" "$rc"
SYNBD="$W/syn-bad"; rm -rf "$SYNBD"; mkdir -p "$SYNBD"; printf '#!/usr/bin/env bash\nif [ 1; then\n' > "$SYNBD/broken.sh"
out="$(bash "$FIX/run-fixtures.sh" --syntax-only "$SYNBD" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '语法错误'; then verdict 0 "D5 夹具语法自检:坏脚本退非 0 并报错"
else verdict 1 "D5 坏脚本未被拦下(rc=$rc)" "$out"; fi

# ==== C9e:验收条目表 ↔ 勾选卡编号集合一致(批 G 新增) ==========================
# C9e 由 check-docs-repo.sh 提供、只在仓库模式(--repo)下跑;这里在临时仓库里造不一致样本,
# 断言两个方向都报:① 条目表多一条 ② 勾选卡多一条。真实仓库样本由「真实样本」段间接覆盖(C9e 静默即一致)。
mk_c9e() {   # mk_c9e <目录> <tsv 额外编号行(可空)> <卡里额外的一行(可空)>
  local d="$1" tsvline="$2" extra="$3"
  rm -rf "$d"; mkdir -p "$d/scripts/repo" "$d/docs"
  cp "$ROOT"/scripts/repo/check-docs*.sh "$ROOT"/scripts/repo/check-docs*.awk "$d/scripts/repo/"
  { printf '# 条目唯一真源(夹具)\nA1\tA\t02-1\tW\t-\t\t示例\n'; [ -n "$tsvline" ] && printf '%s\n' "$tsvline"; } > "$d/scripts/verification-items.tsv"
  { printf '# 验收(夹具)\n\n- [ ] A1 示例 -> 看到:示例\n'; [ -n "$extra" ] && printf '%s\n' "$extra"; } > "$d/docs/08-verification.md"
}
D13="$W/repo-c9e-extra"; mk_c9e "$D13" "$(printf 'B2\tA\t02-3\tW\t-\t\t多出来的一条')" ""
out="$(cd "$D13" && bash scripts/repo/check-docs.sh --repo docs/08-verification.md 2>&1)"
if printf '%s\n' "$out" | grep -q 'C9e 条目表有、勾选卡里没有: B2'; then verdict 0 "C9e 条目表多一条 -> 报出来"
else verdict 1 "C9e 条目表多一条未报" "$out"; fi
D14="$W/repo-c9e-missing"; mk_c9e "$D14" "" "- [ ] C3 只在卡里有 -> 看到:示例"
out="$(cd "$D14" && bash scripts/repo/check-docs.sh --repo docs/08-verification.md 2>&1)"
if printf '%s\n' "$out" | grep -q 'C9e 勾选卡有、条目表里没有: C3'; then verdict 0 "C9e 勾选卡多一条 -> 报出来"
else verdict 1 "C9e 勾选卡多一条未报" "$out"; fi

printf '\nPASS=%s FAIL=%s\n' "$pass" "$bad"
[ "$bad" -eq 0 ] || exit 1
