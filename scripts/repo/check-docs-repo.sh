#!/usr/bin/env bash
# 仓库级自检 C9b/C9c/C9d(卡 ↔ 脚本双向绑定):每个步骤脚本必须有 `# 对应卡:NN-K` 头、必须被某张卡引用、
# 必须登记进 scripts/<侧>/steps.tsv。由 check-docs.sh 在仓库模式(缺省或 --repo)下调用;也可单独运行定位。
# 用法:check-docs-repo.sh  —— 每行一条 `<文件>:<行号> <规则> <说明>`,无问题则无输出(退出码恒 0)。
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$SELF/check-docs-lib.sh"

# ==== C9b:步骤脚本必须声明对应卡,且该卡真实存在 ==============================
# 扫描目录含 scripts/repo(仓库自检脚本之外的新脚本同样受检),白名单跳过。
# 豁免:路径含 /tests/ 的文件是测试夹具(如 scripts/repo/tests/check-docs/ 下的样例仓库),
#   夹具里的假 *.sh/*.ps1 不应被要求 `# 对应卡:`;C9c/C9d 消费同一个 $steps,故一并豁免。
# 卡头允许列表写法(多卡复用同一脚本,如「# 对应卡:02-9,07-10」):列表里至少一个卡号真实存在即可;
# 正则 $CARDRE 允许行首 BOM(.ps1 必须带 BOM,而 BOM 行不算「#」行,故 `# 对应卡:` 要写在 `#Requires` 之后)。
steps=""
for d in repo linux windows; do
  for f in "$ROOT/scripts/$d"/*.sh "$ROOT/scripts/$d"/*.ps1; do
    [ -f "$f" ] || continue
    p="$(rel "$f")"; is_wl "$p" && continue
    case "$p" in */tests/*) continue;; esac
    steps="$steps $p"
    hl="$(grep -n -m1 -E "$CARDRE" "$f" | cut -d: -f1)"
    if [ -z "$hl" ]; then printf '%s:1 C9b 缺少脚本头「# 对应卡:NN-K」\n' "$p"
    else
      refs="$(sed -n "${hl}p" "$f" | grep -oE '[0-9][0-9]-[0-9]+')"
      found=0
      for r in $refs; do card_exists "$r" "$f" && found=1 && break; done
      [ "$found" -eq 1 ] || printf '%s:%s C9b 脚本头声明的卡都不存在: %s\n' "$p" "$hl" "$(printf '%s' "$refs" | tr '\n' ' ')"
    fi
  done
done

# ==== C9c 反向覆盖:步骤脚本必须被至少一张卡引用 ==============================
# 引用来源固定为缺省文档集合的卡体(与传入 check-docs.sh 的文件无关,保证 `--repo` 单文件模式下结论一致)。
refs="$(default_docs | while IFS= read -r f; do
    case "$(scope_of "$f")" in FLOW|DOC08|SPEED) ;; *) continue;; esac
    while IFS=: read -r hln _; do
      end="$(card_end "$f" "$hln")"
      card_lines "$f" "$hln" "$end" | grep -oE "$PATHRE" | norm_path
    done < <(card_heads "$f")
  done | sort -u)"
for p in $steps; do
  printf '%s\n' "$refs" | grep -qxF "$p" || printf '%s:1 C9c 步骤脚本未被任何卡引用\n' "$p"
done

# ==== C9d:步骤索引 steps.tsv 与步骤脚本一一对应 ==============================
# 逐行四验:脚本存在且属本侧、破坏性列 ∈ {0,1}、步骤号与脚本头卡号集合一致(支持列表头)、步骤号不重复。
# 脚本还没有卡头时由 C9b 报,这里不重复报错(卡头是 Task 8/10/17 才补的既有脚本)。
for d in linux windows; do
  idx="scripts/$d/steps.tsv"; dir_steps=""
  for p in $steps; do case "$p" in scripts/"$d"/*) dir_steps="$dir_steps $p";; esac; done
  if [ ! -f "$ROOT/$idx" ]; then
    [ -n "$dir_steps" ] && printf '%s:1 C9d 缺少步骤索引(%s 侧存在步骤脚本)\n' "$idx" "$d"
    continue
  fi
  while IFS=$'\t' read -r ln s x dst; do
    [ -n "$x" ] || continue
    x="$(norm_path <<<"$x")"
    case "$dst" in 0|1) ;; *) printf '%s:%s C9d 破坏性列必须是 0 或 1: %s\n' "$idx" "$ln" "${dst:-空}";; esac
    [ -e "$ROOT/$x" ] || printf '%s:%s C9d 索引中的脚本不存在: %s\n' "$idx" "$ln" "$x"
    case " $dir_steps " in *" $x "*) ;; *) printf '%s:%s C9d 索引条目不是本侧步骤脚本: %s\n' "$idx" "$ln" "$x";; esac
    if [ -e "$ROOT/$x" ]; then
      hc="$(card_header_cards "$ROOT/$x")"
      if [ -n "$hc" ]; then
        case " $hc " in *" $s "*) ;; *) printf '%s:%s C9d 索引步骤号 %s 与脚本头卡号集合(%s)不一致: %s\n' "$idx" "$ln" "$s" "$hc" "$x";; esac
      fi
    fi
  done < <(awk -F'\t' '/^[0-9][0-9]-[0-9]+/ { print FNR "\t" $1 "\t" $2 "\t" $3 }' "$ROOT/$idx")
  for s in $(awk -F'\t' '/^[0-9][0-9]-[0-9]+/ { print $1 }' "$ROOT/$idx" | sort | uniq -d); do
    printf '%s:1 C9d 索引步骤号重复: %s\n' "$idx" "$s"
  done
  for p in $dir_steps; do
    grep -qE "^[0-9][0-9]-[0-9]+[[:space:]]+$p([[:space:]]|$)" "$ROOT/$idx" \
      || printf '%s:1 C9d 步骤脚本未登记进索引: %s\n' "$idx" "$p"
  done
done
