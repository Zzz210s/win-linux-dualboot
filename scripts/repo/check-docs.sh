#!/usr/bin/env bash
# 校验文档:操作卡体系自检 C1–C9a。用法:check-docs.sh [--repo] [file...]
# 规则真源:docs/design/01-playbook-reshape-design.md 第 6/7 节、docs/design/03-step-automation-design.md 第 4 节。
# 缺省集合 = docs/*.md(仅深度 1)+ checklists/*.md + 仓库根 README.md / README.zh-CN.md;显式传文件时只查这些文件;
# 加 --repo 时即使只传单个文件,也追加仓库级 C9b/C9c/C9d(实现在同目录 check-docs-repo.sh,库在 check-docs-lib.sh)。
# 计数口径两处不同:C1 的「## 开始前 3-5 行」不计空行与 --- 分隔线;C4 的「卡体 ≤25 行」计全部物理行。
# C5 解析:优先引用方自身(文件名形如 NN-*.md),否则按编号到 docs/NN-*.md 里找承载该卡的手册。
# 适用范围:01-07 查 C1-C5/C7/C8/C9a;08 查 C6/C9a;09/10 查 C6(速查卡只要求卡标题);
# 00-overview、README、checklists 只查 C5/C7/C8;docs/design/* 与 baseline/README.md 只查 C5/C7/C8。
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$SELF/check-docs-lib.sh"
issues=0; OUT=()
emit() { OUT+=("$(rel "$1"):$2 $3 $4"); issues=$((issues+1)); }

# ==== 参数:缺省全仓(含仓库级 C9b/c/d);显式文件 = 定点检查 ==================
args=(); opt_repo=0
for a in "$@"; do case "$a" in --repo) opt_repo=1;; *) args+=("$a");; esac; done
if [ "${#args[@]}" -gt 0 ]; then files=("${args[@]}"); repo_scan="$opt_repo"
else mapfile -t files < <(default_docs); repo_scan=1
fi

# ==== 逐文件检查 ==============================================================
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then emit "$f" 1 C8 "文件不存在"; continue; fi
  sc="$(scope_of "$f")"; r="$(rel "$f")"

  # C8 占位符(设计文档与计划文件豁免)
  case "$r" in docs/design/*|docs/superpowers/*) ;; *)
    while IFS=: read -r ln _; do emit "$f" "$ln" C8 "占位符"; done < <(grep -nE 'TBD|TODO|待补|FIXME|占位符' "$f");;
  esac
  # C8 emoji
  while IFS=: read -r ln _; do emit "$f" "$ln" C8 "emoji"; done < <(LC_ALL=C grep -nE "$EMOJI" "$f")
  # C8 相对链接存在性(先剥锚点再按扩展名过滤;http/mailto 跳过)
  while IFS='|' read -r ln link; do
    [ -n "$link" ] || continue
    [ -e "$(dirname "$f")/$link" ] || emit "$f" "$ln" C8 "相对链接目标不存在: $link"
  done < <(grep -noE '\]\([^)#][^)]*\)' "$f" | sed -E 's/^([0-9]+):\]\(/\1|/; s/\)$//; s/#.*$//' \
           | grep -vE '\|(https?|mailto)' | grep -E '\.(md|sh|ps1|txt|snippet|conf)$')
  # C5 卡编号引用:只认 -> NN-K 与反引号 `NN-K` 两种写法,目标文档必须含该卡
  while IFS=: read -r ln ref; do
    card_exists "$ref" "$f" || emit "$f" "$ln" C5 "卡编号引用无法解析: $ref"
  done < <(grep -noE '(\-> |`)[0-9][0-9]-[0-9]+' "$f" | sed -E 's/^([0-9]+):.*([0-9][0-9]-[0-9]+)$/\1:\2/' | awk -F: '!seen[$0]++')
  # C7 禁止跨文件锚点链接
  while IFS=: read -r ln _; do emit "$f" "$ln" C7 "禁止跨文件锚点链接(改为 文档名 + 卡编号 引用)"; done \
    < <(grep -noE '\]\([^)]*\.md#[^)]*\)' "$f")
  # C7 同文件锚点:允许,但目标标题必须存在(空锚点 `](#)` 指向页首,合法)
  anchors="$(file_anchors "$f")"
  while IFS='|' read -r ln a; do
    an="$(printf '%s' "$a" | slugify)"
    { [ -n "$a" ] && [ -n "$an" ]; } || continue
    printf '%s\n' "$anchors" | grep -qxF "$an" || emit "$f" "$ln" C7 "同文件锚点无对应标题: #$a"
  done < <(grep -noE '\]\(#[^)]*\)' "$f" | sed -E 's/^([0-9]+):\]\(#/\1|/; s/\)$//')

  # C1-C4 只适用于流程文档 01-07
  if [ "$sc" = FLOW ]; then
    nn="$(basename "$f" | cut -c1-2)"
    # C1:每个 ## 开始前 节都要 3-5 行(不计空行与 --- 分隔线)
    have=0
    while IFS=: read -r h _; do
      have=1
      e="$(awk -v s="$h" 'NR > s && (/^##[^#]/ || /^### /) {print NR; exit}' "$f")"; e="${e:-$(file_end "$f")}"
      n="$(awk -v s="$h" -v e="$e" 'NR > s && NR < e {gsub(/[[:space:]]/,""); if (length($0) && $0 !~ /^-{3,}$/) c++} END {print c+0}' "$f")"
      { [ "$n" -ge 3 ] && [ "$n" -le 5 ]; } || emit "$f" "$h" C1 "## 开始前 应 3-5 行(实为 $n 行)"
    done < <(grep -nE '^## 开始前[[:space:]]*$' "$f")
    [ "$have" -eq 1 ] || emit "$f" 1 C1 "缺少 ## 开始前 节"
    # C2:卡标题必须是 `### NN-K 动作名`(K 自 1 起连续、不跳号、不重复)
    expect=1
    while IFS=: read -r hln htext; do
      case "$htext" in
        "### $nn-"*) ;;
        "### "[0-9][0-9]-*) emit "$f" "$hln" C2 "卡编号前缀应为 $nn"; continue;;
        *) emit "$f" "$hln" C2 "卡标题格式应为 ### NN-K 动作名"; continue;;
      esac
      k="$(printf '%s' "${htext#"### $nn-"}" | grep -oE '^[0-9]+')"
      [ -n "$k" ] || { emit "$f" "$hln" C2 "卡号应为数字"; continue; }
      name="$(printf '%s' "${htext#"### $nn-$k"}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      [ -n "$name" ] || emit "$f" "$hln" C2 "卡标题缺动作名(应写作 ### NN-K 动作名)"
      [ "$k" = "$expect" ] || emit "$f" "$hln" C2 "卡号应为 $nn-$expect(连续不跳号不重复)"
      expect=$((k + 1))
      end="$(card_end "$f" "$hln")"
      [ "$((end - hln))" -le 25 ] || emit "$f" "$hln" C4 "卡体 $((end - hln)) 行,超过 25 行"
      for key in 看到: 坑: 出错时:; do
        card_lines "$f" "$hln" "$end" | grep -qF -- "$key" || emit "$f" "$hln" C3 "卡内缺少「$key」行"
      done
    done < <(grep -nE '^### ' "$f")
  fi

  # C6:08 分组勾选卡 / 09、10 速查卡(勾选态 - [x] 与未勾选 - [ ] 同等受检)
  if [ "$sc" = DOC08 ]; then
    first="$(grep -nE '^### ' "$f" | head -1 | cut -d: -f1)"; first="${first:-0}"
    [ "$first" -gt 0 ] || emit "$f" 1 C6 "08 未见分组卡(### 卡标题)"
    while IFS=: read -r ln t; do
      printf '%s' "$t" | grep -qF -- '-> 看到:' || emit "$f" "$ln" C6 "08 条目应写作 - [ ] ... -> 看到: ..."
      { [ "$first" -gt 0 ] && [ "$ln" -gt "$first" ]; } || emit "$f" "$ln" C6 "08 清单条目不在分组卡内"
    done < <(grep -nE '^- \[[ xX]\]' "$f")
  elif [ "$sc" = SPEED ]; then
    grep -qE '^### ' "$f" || emit "$f" 1 C6 "速查卡缺少 ### 卡标题"
  fi

  # C9a:卡内出现的 scripts/**/*.{sh,ps1} 必须存在(反斜杠路径先归一成 /)
  case "$sc" in FLOW|DOC08|SPEED)
    while IFS=: read -r hln _; do
      end="$(card_end "$f" "$hln")"
      while IFS=: read -r rln p; do
        p="$(printf '%s' "$p" | norm_path)"
        [ -e "$ROOT/$p" ] || emit "$f" "$((hln + rln))" C9a "卡内脚本路径不存在: $p"
      done < <(card_lines "$f" "$hln" "$end" | grep -noE "$PATHRE")
    done < <(card_heads "$f");;
  esac
done

# ==== 仓库级检查:C9b / C9c / C9d =============================================
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
