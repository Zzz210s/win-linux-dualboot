#!/usr/bin/env bash
# 校验文档:操作卡体系自检 C1–C9a。用法:check-docs.sh [--repo] [file...]
# 规则真源:docs/design/01-playbook-reshape-design.md 第 6/7 节、docs/design/03-step-automation-design.md 第 4 节。
# 缺省集合 = docs/**/*.md(排除 docs/superpowers/)+ checklists/*.md + 仓库根 README.md / README.zh-CN.md;
# 显式传文件时只查这些文件;加 --repo 时即使只传单个文件,也追加仓库级 C9b/C9c/C9d/C9e(见 check-docs-repo.sh)。
# 计数口径两处不同:C1 的「## 开始前 3-5 行」不计空行与 --- 分隔线;C4 的「卡体 ≤25 行」计全部物理行。
# C5 解析:优先引用方自身(文件名形如 NN-*.md),否则按编号到 docs/NN-*.md 里找承载该卡的手册。
# C5 历史豁免(窄口径):只跳过「## 变更历史」段内的行,以及「| YYYY-MM-DD |」变更历史表格行 —— 账本里的旧卡号不参与 C5;
#   其余任何行(包括措辞里出现“历史/已废弃”等词的活引用行)一律照常检查,不做关键词整行豁免。
# 适用范围:01-07 查 C1-C5/C7/C8/C9a;08 查 C6/C9a(并照常查 C5/C7/C8);09/10 查 C6(速查卡只要求卡标题,并照常查 C5/C7/C8);
# 00-overview、README、checklists 只查 C5/C7/C8;docs/design/* 与 baseline/README.md 只查 C5/C7/C8(C8 占位符豁免)。
# 性能(2026-10-09):逐文件只跑**一次 awk**,把该文件要用的事实(标题/卡体长度/缺键/引用/链接/锚点/emoji/脚本路径/
#   08 条目)打成 TSV,再由 bash 判定并 emit —— 旧实现每个提示都要 fork 若干个 grep/sed,Windows 上单次全仓扫描 >4 分钟。
#   判定语义与输出格式必须与旧实现逐字一致:由文档校验器夹具(scripts/repo/tests/check-docs/run-fixtures.sh,89 条断言)
#   与本机黄金样本 harness(.superpowers/docs-golden.sh,不入库)共同钉住。
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$SELF/check-docs-lib.sh"
# 解析器(scripts/repo/check-docs-parse.awk)缺失时必须**响亮失败**:样例仓库若只复制了 check-docs*.sh,
#   静默跳过会让「一个提示都不报」被误当成通过(文档校验器夹具就踩过这个坑)。
PARSER="$SELF/check-docs-parse.awk"
[ -f "$PARSER" ] || { echo "check-docs: 缺少解析器 $PARSER(复制脚本时需一并带上 check-docs*.awk)" >&2; exit 2; }
issues=0; OUT=()
emit() { OUT+=("$(rel "$1"):$2 $3 $4"); issues=$((issues+1)); }

# ==== 参数:缺省全仓(含仓库级 C9b/c/d/e);显式文件 = 定点检查 ==================
args=(); opt_repo=0
for a in "$@"; do case "$a" in --repo) opt_repo=1;; *) args+=("$a");; esac; done
if [ "${#args[@]}" -gt 0 ]; then files=("${args[@]}"); repo_scan="$opt_repo"
else mapfile -t files < <(default_docs); repo_scan=1
fi

# ==== C5 查表:docs/NN-*.md 里真实存在的卡号集合(替代 per-ref 的 grep)==========
declare -A DOCS_CARDS=() FILE_CARDS=() ANCH=()
while IFS= read -r id; do [ -n "$id" ] && DOCS_CARDS["$id"]=1; done < <(
  LC_ALL=C awk 'substr($0,1,4)=="### " { id=substr($0,5)
      if (id ~ /^[0-9][0-9]-[0-9]+([ \t]|$)/) { sub(/[ \t].*$/,"",id); print id } }' \
    "$ROOT"/docs/[0-9][0-9]-*.md 2>/dev/null)
card_exists() {   # <ref> <引用方文件>:仓库文档里存在,或引用方自身(夹具)里存在
  local ref="$1" f="$2" nn="${1%%-*}"
  [ -n "${DOCS_CARDS[$ref]:-}" ] && return 0
  case "$(basename "$f")" in "$nn"-*.md) [ -n "${FILE_CARDS[$ref]:-}" ] && return 0;; esac
  return 1
}

# ==== 单次解析:把该文件要用的事实打成 TSV(KIND<TAB>行号<TAB>载荷)==============
# P 占位符 / E emoji / L 相对链接 / X 跨文件锚点 / S 同文件锚点 / R 卡引用(逐行去重)/ H ### 标题
# T 卡体长度 / M 缺失的键 / K 卡标题行(供 C5 自表)/ A 卡内脚本路径 / I 08 清单条目
# 关键:与旧实现一致 —— T/M 只对「前缀与卡号都合法」的卡标题产出(旧实现遇格式错会 continue,不再查 C4/C3)。
parse_file() {   # <文件> <体裁> <NN 前缀> <是否豁免占位符:0|1>
  LC_ALL=C awk -v scope="$2" -v nn="$3" -v no_ph="$4" -v emoji="$EMOJI" \
    -f "$PARSER" "$1"
}

# ==== 逐文件检查 ==============================================================
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then emit "$f" 1 C8 "文件不存在"; continue; fi
  sc="$(scope_of "$f")"; r="$(rel "$f")"
  case "$r" in docs/design/*|docs/superpowers/*) noph=1;; *) noph=0;; esac
  case "$sc" in FLOW) nn="$(basename "$f" | cut -c1-2)";; *) nn="";; esac
  FILE_CARDS=(); ANCH=(); HLINE=(); ILINE=()
  while IFS= read -r a; do [ -n "$a" ] && ANCH["$a"]=1; done < <(file_anchors "$f")
  while IFS=$'\t' read -r kind ln pay; do
    case "$kind" in
      P) emit "$f" "$ln" C8 "占位符";;
      E) emit "$f" "$ln" C8 "emoji";;
      L) [ -e "$(dirname "$f")/$pay" ] || emit "$f" "$ln" C8 "相对链接目标不存在: $pay";;
      X) emit "$f" "$ln" C7 "禁止跨文件锚点链接(改为 文档名 + 卡编号 引用)";;
      R) card_exists "$pay" "$f" || emit "$f" "$ln" C5 "卡编号引用无法解析: $pay";;
      K) FILE_CARDS["$pay"]=1;;
      M) emit "$f" "$ln" C3 "卡内缺少「$pay」行";;
      T) [ "$pay" -le 25 ] || emit "$f" "$ln" C4 "卡体 $pay 行,超过 25 行";;
      A) [ -e "$ROOT/$pay" ] || emit "$f" "$ln" C9a "卡内脚本路径不存在: $pay";;
      I) ILINE+=("$ln")
         case "$pay" in *"-> 看到:"*) ;; *) emit "$f" "$ln" C6 "08 条目应写作 - [ ] ... -> 看到: ...";; esac;;
      S) an="$(printf '%s' "$pay" | slugify)"
         { [ -n "$pay" ] && [ -n "$an" ]; } || continue
         [ -n "${ANCH[$an]:-}" ] || emit "$f" "$ln" C7 "同文件锚点无对应标题: #$pay";;
      H) HLINE+=("$ln|$pay");;
    esac
  done < <(parse_file "$f" "$sc" "$nn" "$noph")

  # C1/C2:流程文档 01-07(## 开始前 3-5 行;卡标题 ### NN-K 动作名,K 自 1 连续不跳号)
  # 注:C4 卡体 ≤25 行 与 C3 卡内必备行 已在 parse_file 里判定(只对合法卡标题产出)。
  if [ "$sc" = FLOW ]; then
    have=0
    while IFS=: read -r h _; do
      have=1
      e="$(awk -v s="$h" 'NR > s && (/^##[^#]/ || /^### /) {print NR; exit}' "$f")"; e="${e:-$(file_end "$f")}"
      n="$(awk -v s="$h" -v e="$e" 'NR > s && NR < e {gsub(/[[:space:]]/,""); if (length($0) && $0 !~ /^-{3,}$/) c++} END {print c+0}' "$f")"
      { [ "$n" -ge 3 ] && [ "$n" -le 5 ]; } || emit "$f" "$h" C1 "## 开始前 应 3-5 行(实为 $n 行)"
    done < <(grep -nE '^## 开始前[[:space:]]*$' "$f")
    [ "$have" -eq 1 ] || emit "$f" 1 C1 "缺少 ## 开始前 节"
    expect=1
    for rec in ${HLINE[@]+"${HLINE[@]}"}; do
      hln="${rec%%|*}"; htext="${rec#*|}"
      case "$htext" in
        "### $nn-"*) ;;
        "### "[0-9][0-9]-*) emit "$f" "$hln" C2 "卡编号前缀应为 $nn"; continue;;
        *) emit "$f" "$hln" C2 "卡标题格式应为 ### NN-K 动作名"; continue;;
      esac
      k="${htext#"### $nn-"}"; k="${k%%[!0-9]*}"
      [ -n "$k" ] || { emit "$f" "$hln" C2 "卡号应为数字"; continue; }
      rest="${htext#"### $nn-$k"}"
      rest="${rest#"${rest%%[![:space:]]*}"}"; rest="${rest%"${rest##*[![:space:]]}"}"
      [ -n "$rest" ] || emit "$f" "$hln" C2 "卡标题缺动作名(应写作 ### NN-K 动作名)"
      [ "$k" = "$expect" ] || emit "$f" "$hln" C2 "卡号应为 $nn-$expect(连续不跳号不重复)"
      expect=$((k + 1))
    done
  fi

  # C6:08 分组勾选卡 / 09、10 速查卡(勾选态 - [x] 与未勾选 - [ ] 同等受检)
  if [ "$sc" = DOC08 ]; then
    first="${HLINE[0]:-}"; first="${first%%|*}"; first="${first:-0}"
    [ "$first" -gt 0 ] || emit "$f" 1 C6 "08 未见分组卡(### 卡标题)"
    for e_ln in ${ILINE[@]+"${ILINE[@]}"}; do
      { [ "$first" -gt 0 ] && [ "$e_ln" -gt "$first" ]; } || emit "$f" "$e_ln" C6 "08 清单条目不在分组卡内"
    done
  elif [ "$sc" = SPEED ]; then
    [ "${#HLINE[@]}" -gt 0 ] || emit "$f" 1 C6 "速查卡缺少 ### 卡标题"
  fi
done

# ==== 仓库级检查:C9b / C9c / C9d / C9e =======================================
if [ "$repo_scan" -eq 1 ]; then
  repo_out="$(bash "$SELF/check-docs-repo.sh")" || { echo "check-docs: 仓库级检查异常退出(check-docs-repo.sh)" >&2; exit 2; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue; OUT+=("$line"); issues=$((issues+1))
  done <<<"$repo_out"
fi

if [ "$issues" -eq 0 ]; then echo "check-docs: OK"; exit 0; fi
# 按 文件:行号 排序输出,便于与历史存档逐行比对
printf '%s\n' "${OUT[@]}" | sort -t: -k1,1 -k2,2n | sed 's/^/ERROR /'
echo "check-docs: FAIL ($issues 个问题)"
exit 1
