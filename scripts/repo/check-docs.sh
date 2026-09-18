#!/usr/bin/env bash
# 校验文档:操作卡体系自检 C1–C9。用法:check-docs.sh [file...]
# 规则真源:docs/design/01-playbook-reshape-design.md 第 6/7 节、docs/design/03-step-automation-design.md 第 4 节。
# 缺省集合 = docs/*.md(仅深度 1)+ checklists/*.md + 仓库根 README.md / README.zh-CN.md;
# 显式传文件时只查该文件,并跳过仓库级 C9b/C9c/C9d(单任务定点验证用)。
# 适用范围:01-07 查 C1-C5/C7/C8/C9a;08 查 C6/C9a;09/10 查 C6(速查卡只要求卡标题);
# 00-overview、README、checklists 只查 C5/C7/C8;docs/design/* 与 baseline/README.md 只查 C5/C7/C8。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
issues=0; repo_scan=1; OUT=()
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}";; *) printf '%s' "$1";; esac; }
emit() { OUT+=("$(rel "$1"):$2 $3 $4"); issues=$((issues+1)); }
# emoji 字节模式:F0 9F = U+1F000 及以上;E2 98/99/9A/9B = U+2600~U+26FF;E2 9C/9D/9E = U+2700~U+27BF;EF B8 8F = 变体选择符。
# 本机 grep -P 不支持多字节码点范围,故用 LC_ALL=C 下的字节级匹配。
EMOJI="$(printf '\xf0\x9f|\xe2\x98|\xe2\x99|\xe2\x9a|\xe2\x9b|\xe2\x9c|\xe2\x9d|\xe2\x9e|\xef\xb8\x8f')"
# C9 白名单:库文件与仓库自检脚本(名单与 03 设计第 4 节 C9d 及任务 1 裁定一致)
WL=" scripts/linux/dbk-log.sh scripts/linux/dbk-cli.sh scripts/linux/dbk-pkg.sh scripts/linux/dbk.sh scripts/repo/check-docs.sh scripts/repo/check-scripts.sh scripts/windows/dbk-cli.ps1 scripts/windows/dbk.ps1 "
is_wl() { case "$WL" in *" $1 "*) return 0;; *) return 1;; esac; }

# ==== 基本解析 ================================================================
# 卡体结束:下一个一级~三级标题的行号;没有则文件末行 + 1
card_end() {
  local e; e="$(awk -v s="$2" 'NR>s && /^#[^#]/ {print NR; exit} NR>s && /^##[^#]/ {print NR; exit} NR>s && /^###[^#]/ {print NR; exit}' "$1")"
  printf '%s' "${e:-$(( $(wc -l < "$1") + 1 ))}"
}
# 卡体行(不含卡标题):sed 切片 + 本文件内相对行号
card_lines() { sed -n "$(($2 + 1)),$(($3 - 1))p" "$1"; }
# NN -> 文档路径:被检查文件自身命名匹配时用自身(夹具场景),否则取 docs/NN-*.md
doc_of() { case "$(basename "$2")" in "$1"-*.md) printf '%s' "$2";; *) ls "$ROOT/docs/$1"-*.md 2>/dev/null | head -1;; esac; }
card_exists() { local d; d="$(doc_of "${1%%-*}" "$2")"; [ -n "$d" ] && grep -qE "^### $1([[:space:]]|\$)" "$d"; }
# 标题/锚点归一:去掉标记与标点,便于同文件锚点比对
slugify() { sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//; s/[[:space:]]+/-/g' | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -d '[:punct:]' | sed -E 's/--+/-/g; s/^-+//; s/-+$//'; }
# 卡标题行:FLOW 只认 ### NN-K 形态(C2 定义的卡);08/09/10 的卡只需 ### 标题
card_heads() {
  case "$(scope_of "$1")" in FLOW) grep -nE '^### [0-9][0-9]-[0-9]+([[:space:]]|$)' "$1";; *) grep -nE '^### ' "$1";; esac
}
# 文档体裁:FLOW(01-07 卡文档)/ DOC08 / SPEED(09-10 速查卡)/ PLAIN(不写卡)
scope_of() {
  case "$(rel "$1")" in docs/design/*|checklists/*|baseline/README.md) echo PLAIN; return;; esac
  case "$(basename "$1")" in
    00-overview.md|README.md|README.zh-CN.md) echo PLAIN;;
    0[1-7]-*.md) echo FLOW;; 08-*.md) echo DOC08;; 09-*.md|10-*.md) echo SPEED;; *) echo PLAIN;;
  esac
}

# ==== 文件集合 ================================================================
if [ "$#" -gt 0 ]; then files=("$@"); repo_scan=0
else
  mapfile -t files < <({ find "$ROOT/docs" -maxdepth 1 -name '*.md'
    find "$ROOT/checklists" -maxdepth 1 -name '*.md' 2>/dev/null
    ls "$ROOT/README.md" "$ROOT/README.zh-CN.md" 2>/dev/null; } | sort)
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
  # C7 同文件锚点:允许,但目标标题必须存在
  heads="$(grep -E '^#{1,6} ' "$f" | slugify)"
  while IFS='|' read -r ln a; do
    a="$(printf '%s' "$a" | slugify)"
    [ -n "$a" ] && printf '%s\n' "$heads" | grep -qxF "$a" || emit "$f" "$ln" C7 "同文件锚点无对应标题: #$a"
  done < <(grep -noE '\]\(#[^)]*\)' "$f" | sed -E 's/^([0-9]+):\]\(#/\1|/; s/\)$//')

  # C1-C4 只适用于流程文档 01-07
  if [ "$sc" = FLOW ]; then
    nn="$(basename "$f" | cut -c1-2)"
    h="$(grep -nE '^## 开始前[[:space:]]*$' "$f" | head -1 | cut -d: -f1)"
    if [ -z "$h" ]; then emit "$f" 1 C1 "缺少 ## 开始前 节"; else
      # 该节结束于下一个二级标题或第一张卡(卡直接跟在 ## 开始前 后面时)
      e="$(awk -v s="$h" 'NR>s && (/^##[^#]/ || /^### /) {print NR; exit}' "$f")"; e="${e:-$(( $(wc -l < "$f") + 1 ))}"
      n="$(awk -v s="$h" -v e="$e" 'NR>s && NR<e {gsub(/[[:space:]]/,""); if (length($0)) c++} END {print c+0}' "$f")"
      { [ "$n" -ge 3 ] && [ "$n" -le 5 ]; } || emit "$f" "$h" C1 "## 开始前 应 3-5 行(实为 $n 行)"
    fi
    expect=1
    while IFS=: read -r hln htext; do
      case "$htext" in
        "### $nn-"*) ;;
        "### "[0-9][0-9]-*) emit "$f" "$hln" C2 "卡编号前缀应为 $nn"; continue;;
        *) emit "$f" "$hln" C2 "卡标题格式应为 ### NN-K 动作名"; continue;;
      esac
      k="$(printf '%s' "${htext#"### $nn-"}" | grep -oE '^[0-9]+')"
      [ -n "$k" ] || { emit "$f" "$hln" C2 "卡号应为数字"; continue; }
      [ "$k" = "$expect" ] || emit "$f" "$hln" C2 "卡号应为 $nn-$expect(连续不跳号不重复)"
      expect=$((k + 1))
      end="$(card_end "$f" "$hln")"
      [ "$((end - hln))" -le 25 ] || emit "$f" "$hln" C4 "卡体 $((end - hln)) 行,超过 25 行"
      for key in 看到: 坑: 出错时:; do
        card_lines "$f" "$hln" "$end" | grep -qF -- "$key" || emit "$f" "$hln" C3 "卡内缺少「$key」行"
      done
    done < <(grep -nE '^### ' "$f")
  fi

  # C6:08 分组勾选卡 / 09、10 速查卡
  if [ "$sc" = DOC08 ]; then
    first="$(grep -nE '^### ' "$f" | head -1 | cut -d: -f1)"; first="${first:-0}"
    [ "$first" -gt 0 ] || emit "$f" 1 C6 "08 未见分组卡(### 卡标题)"
    while IFS=: read -r ln t; do
      printf '%s' "$t" | grep -qF -- '-> 看到:' || emit "$f" "$ln" C6 "08 条目应写作 - [ ] ... -> 看到: ..."
      { [ "$first" -gt 0 ] && [ "$ln" -gt "$first" ]; } || emit "$f" "$ln" C6 "08 清单条目不在分组卡内"
    done < <(grep -nE '^- \[ \]' "$f")
  elif [ "$sc" = SPEED ]; then
    grep -qE '^### ' "$f" || emit "$f" 1 C6 "速查卡缺少 ### 卡标题"
  fi

  # C9a:卡内出现的 scripts/**/*.{sh,ps1} 必须存在
  case "$sc" in FLOW|DOC08|SPEED)
    while IFS=: read -r hln _; do
      end="$(card_end "$f" "$hln")"
      while IFS=: read -r rln p; do
        [ -e "$ROOT/$p" ] || emit "$f" "$((hln + rln))" C9a "卡内脚本路径不存在: $p"
      done < <(card_lines "$f" "$hln" "$end" | grep -noE 'scripts/[A-Za-z0-9_./-]+\.(sh|ps1)')
    done < <(card_heads "$f");;
  esac
done

# ==== 仓库级检查:C9b / C9c / C9d =============================================
if [ "$repo_scan" -eq 1 ]; then
  steps=""
  for f in "$ROOT"/scripts/linux/*.sh "$ROOT"/scripts/windows/*.ps1; do
    [ -f "$f" ] || continue
    p="$(rel "$f")"; is_wl "$p" && continue
    steps="$steps $p"
    hl="$(grep -n -m1 -E '^#[[:space:]]*(对应卡|Card):[[:space:]]*[0-9][0-9]-[0-9]+' "$f" | cut -d: -f1)"
    if [ -z "$hl" ]; then emit "$f" 1 C9b "缺少脚本头「# 对应卡:NN-K」"
    else
      ref="$(sed -n "${hl}p" "$f" | grep -oE '[0-9][0-9]-[0-9]+' | head -1)"
      card_exists "$ref" "$f" || emit "$f" "$hl" C9b "脚本头声明的卡不存在: $ref"
    fi
  done
  # C9c 反向覆盖:步骤脚本必须被至少一张卡引用
  refs="$(for f in "${files[@]}"; do
      case "$(scope_of "$f")" in FLOW|DOC08|SPEED) ;; *) continue;; esac
      while IFS=: read -r hln _; do
        end="$(card_end "$f" "$hln")"
        card_lines "$f" "$hln" "$end" | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|ps1)'
      done < <(card_heads "$f")
    done | sort -u)"
  for p in $steps; do
    printf '%s\n' "$refs" | grep -qxF "$p" || emit "$ROOT/$p" 1 C9c "步骤脚本未被任何卡引用"
  done
  # C9d 步骤索引与脚本一一对应
  for d in linux windows; do
    idx="scripts/$d/steps.tsv"; dir_steps=""
    for p in $steps; do case "$p" in scripts/"$d"/*) dir_steps="$dir_steps $p";; esac; done
    if [ ! -f "$ROOT/$idx" ]; then
      [ -n "$dir_steps" ] && emit "$ROOT/$idx" 1 C9d "缺少步骤索引($d 侧存在步骤脚本)"
      continue
    fi
    while IFS=: read -r ln x; do
      [ -n "$x" ] || continue
      [ -e "$ROOT/$x" ] || emit "$ROOT/$idx" "$ln" C9d "索引中的脚本不存在: $x"
      case " $dir_steps " in *" $x "*) ;; *) emit "$ROOT/$idx" "$ln" C9d "索引条目不是本侧步骤脚本: $x";; esac
    done < <(awk -F'\t' '/^[0-9][0-9]-[0-9]+/ {print NR ":" $2}' "$ROOT/$idx")
    for p in $dir_steps; do
      grep -qE "^[0-9][0-9]-[0-9]+[[:space:]]+$p([[:space:]]|$)" "$ROOT/$idx" \
        || emit "$ROOT/$idx" 1 C9d "步骤脚本未登记进索引: $p"
    done
  done
fi

if [ "$issues" -eq 0 ]; then echo "check-docs: OK"; exit 0; fi
# 按 文件:行号 排序输出,便于与历史存档逐行比对
printf '%s\n' "${OUT[@]}" | sort -t: -k1,1 -k2,2n | sed 's/^/ERROR /'
echo "check-docs: FAIL ($issues 个问题)"
exit 1
