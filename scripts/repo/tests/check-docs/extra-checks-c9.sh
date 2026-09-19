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

# ==== F9:仓库级扫描目录含 scripts/repo =======================================
D="$W/repo-f9"; mkdir -p "$D/docs" "$D/scripts/repo"
cp "$ROOT"/scripts/repo/check-docs.sh "$ROOT"/scripts/repo/check-docs-lib.sh "$ROOT"/scripts/repo/check-docs-repo.sh "$D/scripts/repo/"
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
WLLIB="$(ROOT="$ROOT" bash -c '. "$1"; printf "%s\n" $WL' _ "$ROOT/scripts/repo/check-docs-lib.sh" | grep -v '^$' | sort)"
DOCWL="$(sed -n '/^| C9d /p' "$ROOT/docs/design/03-step-automation-design.md" | grep -oE '`scripts/[^`]+\.(sh|ps1)`' | tr -d '`' | sort)"
d="$(diff <(printf '%s\n' "$WLLIB") <(printf '%s\n' "$DOCWL") 2>&1)"
verdict "$([ -z "$d" ] && echo 0 || echo 1)" "F7 白名单与设计文档 C9d 名单逐行一致" "$d"
if printf '%s' "$(bash "$SCRIPT" 2>&1)" | grep -q 'dbk-apt'; then
  verdict 1 "F7 dbk-apt.sh 已在白名单(不再报 C9b/C9c)" "$(bash "$SCRIPT" 2>&1 | grep 'dbk-apt')"
else verdict 0 "F7 dbk-apt.sh 已在白名单(不再报 C9b/C9c)"; fi

# ==== F12:--repo 在单文件模式下追加仓库级 C9b/C9c/C9d ========================
out="$(bash "$SCRIPT" "$ROOT/docs/00-overview.md" 2>&1)"; rc=$?
judge "F12 不带 --repo:单文件模式无仓库级规则" OK 0 "$out" "$rc"
out="$(bash "$SCRIPT" --repo "$ROOT/docs/00-overview.md" 2>&1)"; rc=$?
n_b="$(printf '%s\n' "$out" | grep -c ' C9b ' || true)"; n_c="$(printf '%s\n' "$out" | grep -c ' C9c ' || true)"
n_d="$(printf '%s\n' "$out" | grep -c ' C9d ' || true)"
if [ "$rc" -eq 1 ] && [ "$n_b" -ge 1 ] && [ "$n_c" -ge 1 ] && [ "$n_d" -ge 1 ]; then verdict 0 "F12 --repo 追加 C9b/C9c/C9d 且退出码 1"
else verdict 1 "F12 --repo 追加 C9b/C9c/C9d 且退出码 1(rc=$rc C9b=$n_b C9c=$n_c C9d=$n_d)" "$out"; fi

# ==== 真实仓库样本(原补充 7/8/9) =============================================
for f in docs/00-overview.md README.md README.zh-CN.md checklists/deploy.md checklists/rollback.md \
         baseline/README.md docs/design/00-design.md docs/design/02-fedora-variant-design.md \
         docs/design/03-step-automation-design.md; do
  runcheck "真实样本 $f(应过)" OK 0 "$ROOT/$f"
done
runcheck "设计文档 01(既有中间态:5 条 C5)" C5 5 "$ROOT/docs/design/01-playbook-reshape-design.md"

printf '\nPASS=%s FAIL=%s\n' "$pass" "$bad"
[ "$bad" -eq 0 ] || exit 1
