#!/usr/bin/env bash
# 附加回归 1:C1-C8 边界 + F2/F3/F4/F5/F6 修复点。
# 用例把内容写进夹具目录下的临时子目录 .tmp/extra1/(不入库),再以仓库内相对路径跑 check-docs.sh。
# 用法:bash scripts/repo/tests/check-docs/extra-checks.sh —— 末行 `PASS=n FAIL=m`,FAIL 非零时退出码 1。
set -uo pipefail
FIX="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$FIX/../../../.." && pwd)"
SCRIPT="$ROOT/scripts/repo/check-docs.sh"
W="$FIX/.tmp/extra1"; rm -rf "$W"; mkdir -p "$W"
pass=0; bad=0; LAST_OUT=""; NOTRAIL=0

verdict() { # 判定(0=通过) / 名称 / 输出
  if [ "$1" -eq 0 ]; then printf -- '--- [PASS] %s\n' "$2"; pass=$((pass + 1))
  else printf -- '--- [FAIL] %s\n%s\n' "$2" "$(printf '%s\n' "$3" | sed 's/^/    /')"; bad=$((bad + 1)); fi
}
# 生成 01-firmware.md:$1 = ## 开始前 的内容行数,$2 = 卡标题行,$3 起 = 卡体内插行
mk01() {
  local n="$1" head="$2"; shift 2
  printf '# L0:夹具样例\n\n## 开始前\n'
  local i; for ((i = 1; i <= n; i++)); do printf -- '- 内容行 %s\n' "$i"; done
  printf '\n%s\n\n做:甲。\n\n' "$head"
  [ "$#" -gt 0 ] && printf '%s\n' "$@"
  printf '  1. 做甲\n     看到:甲完成\n坑:某个坑(设计 I3)。\n出错时:去向 -> 01-1。\n脚本:无(人工)\n'
  return 0
}
runcheck() { # 名称 / 期望规则(OK=零问题)/ 期望条数 / 文件路径
  local name="$1" rule="$2" want="$3" path="$4" out errs cnt rc v=1
  out="$(bash "$SCRIPT" "$path" 2>&1)"; rc=$?; LAST_OUT="$out"
  errs="$(printf '%s\n' "$out" | grep -c '^ERROR ' || true)"
  if [ "$rule" = OK ]; then
    { [ "$errs" -eq 0 ] && [ "$rc" -eq 0 ]; } && v=0
  else
    cnt="$(printf '%s\n' "$out" | grep -c "^ERROR .* $rule " || true)"
    { [ "$cnt" -eq "$want" ] && [ "$cnt" -eq "$errs" ] && [ "$rc" -eq 1 ]; } && v=0
  fi
  verdict "$v" "$name(期望 $rule x$want)" "$out"
}
t() { # 名称 / 规则 / 条数 / 相对路径 —— 文件内容由 stdin 提供,随后调 runcheck
  local name="$1" rule="$2" want="$3" rel="$4"
  mkdir -p "$W/$(dirname "$rel")"; cat > "$W/$rel"
  [ "$NOTRAIL" -eq 1 ] && { printf '%s' "$(cat "$W/$rel")" > "$W/$rel.n"; mv "$W/$rel.n" "$W/$rel"; }
  NOTRAIL=0; runcheck "$name" "$rule" "$want" "$W/$rel"
}
has() { # 名称 / 期望出现在上一条用例输出中的原文
  if printf '%s' "$LAST_OUT" | grep -qF -- "$2"; then verdict 0 "$1"; else verdict 1 "$1" "$LAST_OUT"; fi
}

t "C1 该节 2 行" C1 1 docs/01-firmware.md < <(mk01 2 '### 01-1 甲')
has "F3/C1 报错信息含实测行数" "实为 2 行"
t "C1 该节 6 行" C1 1 docs/01-firmware.md < <(mk01 6 '### 01-1 甲')
t "C1 该节 3 行(应过)" OK 0 docs/01-firmware.md < <(mk01 3 '### 01-1 甲')
t "F3 两个 ## 开始前 均合规(应过)" OK 0 docs/01-firmware.md <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
- 丙

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
脚本:无(人工)
EOF
t "F3 第二个 ## 开始前 也受检(只查第一个会漏)" C1 1 docs/01-firmware.md <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
- 丙

## 开始前
- 甲
- 乙

### 01-1 甲

做:甲。

  1. 做甲
     看到:完成
坑:坑。
出错时:去向 -> 01-1。
脚本:无(人工)
EOF
t "F4a --- 分隔线不计入 C1 行数" C1 1 docs/01-firmware.md <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
---

### 01-1 甲

做:甲。

  1. 做甲
     看到:完成
坑:坑。
出错时:去向 -> 01-1。
脚本:无(人工)
EOF
NOTRAIL=1 t "F4b 无尾换行时 C4 不少计 1 行" C4 1 docs/01-firmware.md < <(
  mk01 3 '### 01-1 甲'
  printf '%s\n' '```' e1 e2 e3 e4 e5 e6 e7 e8 e9 e10 e11 e12 e13 e14 e15 '```'
)
has "F4b 卡体行数为 26(旧实现报 25 而漏报)" "卡体 26 行"
t "F6 裸卡标题缺动作名" C2 1 docs/01-firmware.md < <(mk01 3 '### 01-1')
has "F6 报错信息点明缺动作名" "卡标题缺动作名"
t "C2 卡号前缀与文件名不一致" C2 1 docs/01-firmware.md <<'EOF'
# L0:夹具样例

## 开始前
- 甲
- 乙
- 丙

### 05-1 甲

做:甲。

  1. 做甲
     看到:完成
坑:坑。
出错时:见手册。
脚本:无(人工)
EOF
has "C2 前缀错报错信息点明应为 01" "卡编号前缀应为 01"
t "C2 两位卡号不与 01-1 混淆" C2 1 docs/01-firmware.md <<'EOF'
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
脚本:无(人工)

### 01-10 癸

做:癸。

  1. 做癸
     看到:完成
坑:坑。
出错时:去向 -> 01-1。
脚本:无(人工)
EOF
has "C2 卡号跳号报错信息" "卡号应为 01-2"
t "C5 反引号写法同样受检" C5 1 docs/01-firmware.md < <(mk01 3 '### 01-1 甲' '见 `01-9`。')
t "C8 emoji 与坏链接各一条" C8 2 docs/notes.md < <(printf '# 夹具:C8\n\n这行有 %b 与坏链接 [坏](nope.md)。\n' '\xf0\x9f\x98\x80')
printf '
PASS=%s FAIL=%s
' "$pass" "$bad"
[ "$bad" -eq 0 ] || exit 1
