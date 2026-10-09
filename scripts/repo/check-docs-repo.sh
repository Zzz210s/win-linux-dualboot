#!/usr/bin/env bash
# 仓库级自检 C9b/C9c/C9d/C9e(卡 ↔ 脚本双向绑定 + 条目表与勾选卡一致):每个步骤脚本必须有 `# 对应卡:NN-K` 头、
# 必须被某张卡引用、必须登记进 scripts/<侧>/steps.tsv;验收条目表与 08 勾选卡的编号集合必须一致。
# 由 check-docs.sh 在仓库模式(缺省或 --repo)下调用;也可单独运行定位。
# 用法:check-docs-repo.sh  —— 每行一条 `<文件>:<行号> <规则> <说明>`,无问题则无输出(退出码恒 0)。
# 性能(2026-10-09):旧实现对每个脚本/每条引用都 fork 一次 grep/sed;现在改为**一次 awk 扫完全部脚本**取卡头,
#   卡号存在性/引用命中/索引命中全部改成 bash 关联数组查表,条目表比对改用 comm,不再有 O(n²) 子进程。
#   判定语义与输出格式必须与旧实现逐字一致(见 .superpowers/docs-golden.sh 黄金样本 fast 模式)。
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$SELF/check-docs-lib.sh"
PARSER="$SELF/check-docs-parse.awk"
[ -f "$PARSER" ] || { echo "check-docs-repo: 缺少解析器 $PARSER" >&2; exit 2; }

declare -A CARDSET=() HEADMAP=() REFSET=() IDXSET=()
while IFS= read -r id; do [ -n "$id" ] && CARDSET["$id"]=1; done < <(
  LC_ALL=C awk 'substr($0,1,4)=="### " { id=substr($0,5)
      if (id ~ /^[0-9][0-9]-[0-9]+([ \t]|$)/) { sub(/[ \t].*$/,"",id); print id } }' \
    "$ROOT"/docs/[0-9][0-9]-*.md 2>/dev/null)

# ==== C9b:步骤脚本必须声明对应卡,且该卡真实存在 ==============================
# 扫描目录含 scripts/repo(仓库自检脚本之外的新脚本同样受检),白名单跳过;递归扫描 scripts/{repo,linux,windows}。
# 豁免:路径含 /tests/ 的文件是测试夹具(夹具里的假 *.sh/*.ps1 不要求卡头);用**仓库相对路径**判断。
# 卡头允许列表写法(「# 对应卡:03-9,07-10」):列表里至少一个卡号真实存在即可。
steps=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  p="$(rel "$f")"; is_wl "$p" && continue
  case "$p" in */tests/*) continue;; esac
  steps="$steps $p"
done < <(find "$ROOT/scripts/repo" "$ROOT/scripts/linux" "$ROOT/scripts/windows" -type f \( -name '*.sh' -o -name '*.ps1' \) 2>/dev/null | sort)

# 一次 awk 取全部脚本的卡头行号与卡号列表(输出:相对路径 <TAB> 行号 <TAB> 卡号空格列表;无卡头时行号为 -)
while IFS=$'\t' read -r p hl cards; do
  if [ "$hl" = "-" ]; then printf '%s:1 C9b 缺少脚本头「# 对应卡:NN-K」\n' "$p"; continue; fi
  HEADMAP["$p"]="$cards"
  found=0
  for r in $cards; do [ -n "${CARDSET[$r]:-}" ] && found=1 && break; done
  [ "$found" -eq 1 ] || printf '%s:%s C9b 脚本头声明的卡都不存在: %s\n' "$p" "$hl" "$cards"
done < <(cd "$ROOT" && LC_ALL=C awk -v cardre="$CARDRE" '
  FNR == 1 { if (NR > 1) print path "\t" (hl ? hl : "-") "\t" (hl ? cards : ""); path = FILENAME; hl = 0; cards = "" }
  { if (!hl && $0 ~ cardre) { hl = FNR; line = $0
      n = split(line, a, /[0-9][0-9]-[0-9]+/)
      rest = line; cards = ""
      while (match(rest, /[0-9][0-9]-[0-9]+/)) { cards = cards substr(rest, RSTART, RLENGTH) " "; rest = substr(rest, RSTART + RLENGTH) }
      sub(/ $/, "", cards) } }
  END { if (NR > 0) print path "\t" (hl ? hl : "-") "\t" (hl ? cards : "") }' $steps)

# ==== C9c 反向覆盖:步骤脚本必须被至少一张卡引用 ==============================
# 引用来源固定为缺省文档集合的卡体(与传入 check-docs.sh 的文件无关,保证 `--repo` 单文件模式下结论一致)。
# 卡体定义与 check-docs.sh 共用同一个解析器(check-docs-parse.awk 的 A 记录)。
refs="$(default_docs | while IFS= read -r d; do
    case "$(scope_of "$d")" in FLOW|DOC08|SPEED) ;; *) continue;; esac
    LC_ALL=C awk -v scope="$(scope_of "$d")" -v nn="" -v no_ph=1 -v emoji="$EMOJI" \
      -f "$PARSER" "$d" | awk -F'\t' '$1 == "A" { print $3 }'
  done | sort -u)"
while IFS= read -r p; do [ -n "$p" ] && REFSET["$p"]=1; done <<<"$refs"
for p in $steps; do
  [ -n "${REFSET[$p]:-}" ] || printf '%s:1 C9c 步骤脚本未被任何卡引用\n' "$p"
done

# ==== C9d:步骤索引 steps.tsv 与步骤脚本一一对应 ==============================
# 逐行四验:脚本存在且属本侧、破坏性列 ∈ {0,1}、步骤号与脚本头卡号集合一致(支持列表头)、
#   (步骤号, 脚本路径) 对不重复。一张卡可以对应多个脚本,故同一步骤号允许多行;只有同一(步骤号,脚本)才报重复。
for d in linux windows; do
  idx="scripts/$d/steps.tsv"; dir_steps=""; IDXSET=()
  for p in $steps; do case "$p" in scripts/"$d"/*) dir_steps="$dir_steps $p";; esac; done
  if [ ! -f "$ROOT/$idx" ]; then
    [ -n "$dir_steps" ] && printf '%s:1 C9d 缺少步骤索引(%s 侧存在步骤脚本)\n' "$idx" "$d"
    continue
  fi
  while IFS=$'\t' read -r ln s x dst; do
    [ -n "$x" ] || continue
    x="$(norm_path <<<"$x")"
    IDXSET["$x"]=1
    case "$dst" in 0|1) ;; *) printf '%s:%s C9d 破坏性列必须是 0 或 1: %s\n' "$idx" "$ln" "${dst:-空}";; esac
    [ -e "$ROOT/$x" ] || printf '%s:%s C9d 索引中的脚本不存在: %s\n' "$idx" "$ln" "$x"
    case " $dir_steps " in *" $x "*) ;; *) printf '%s:%s C9d 索引条目不是本侧步骤脚本: %s\n' "$idx" "$ln" "$x";; esac
    hc="${HEADMAP[$x]:-}"
    if [ -e "$ROOT/$x" ] && [ -n "$hc" ]; then
      case " $hc " in *" $s "*) ;; *) printf '%s:%s C9d 索引步骤号 %s 与脚本头卡号集合(%s)不一致: %s\n' "$idx" "$ln" "$s" "$hc" "$x";; esac
    fi
  done < <(awk -F'\t' '/^[0-9][0-9]-[0-9]+/ { print FNR "\t" $1 "\t" $2 "\t" $3 }' "$ROOT/$idx")
  dup_idx="$ROOT/$idx"
  awk -F'\t' '/^[0-9][0-9]-[0-9]+/ { p=$2; gsub(/\\/,"/",p); n[$1 "\t" p]++ }
    END { for (k in n) if (n[k] > 1) print k }' "$dup_idx" | while IFS=$'\t' read -r s x; do
    awk -F'\t' -v s="$s" -v x="$x" -v f="$idx" '/^[0-9][0-9]-[0-9]+/ {
      p=$2; gsub(/\\/,"/",p)
      if ($1 == s && p == x) printf "%s:%d C9d 索引 (步骤号, 脚本) 对重复: %s -> %s\n", f, FNR, s, x
    }' "$dup_idx"
  done
  for p in $dir_steps; do
    [ -n "${IDXSET[$p]:-}" ] || printf '%s:1 C9d 步骤脚本未登记进索引: %s\n' "$idx" "$p"
  done
done

# ==== C9e:验收条目表与勾选卡的编号集合必须一致 ==============================
# 条目唯一真源是 scripts/verification-items.tsv(两侧总控都读它),docs/08-verification.md 是人读视图。
# 只比**编号集合**(不是行序):少一条、多一条、改名都算不一致。
ITEMS="$ROOT/scripts/verification-items.tsv"
CARD08="$ROOT/docs/08-verification.md"
if [ -f "$ITEMS" ]; then
  tsv_ids="$(awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { print $1 }' "$ITEMS" | sort -u)"
  card_ids="$(grep -oE '^- \[ \] [A-H][0-9]+ ' "$CARD08" 2>/dev/null | awk '{ print $4 }' | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$tsv_ids" | grep -v '^$') <(printf '%s\n' "$card_ids") | tr '\n' ' ')"
  extra="$(comm -13 <(printf '%s\n' "$tsv_ids" | grep -v '^$') <(printf '%s\n' "$card_ids") | tr '\n' ' ')"
  [ -n "${missing% }" ] && printf 'scripts/verification-items.tsv:1 C9e 条目表有、勾选卡里没有: %s\n' "${missing% }"
  [ -n "${extra% }" ] && printf 'docs/08-verification.md:1 C9e 勾选卡有、条目表里没有: %s\n' "${extra% }"
fi
exit 0   # 本脚本只输出问题行,退出码恒 0(调用方按输出计数)
