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
steps=""
for d in repo linux windows; do
  for f in "$ROOT/scripts/$d"/*.sh "$ROOT/scripts/$d"/*.ps1; do
    [ -f "$f" ] || continue
    p="$(rel "$f")"; is_wl "$p" && continue
    case "$p" in */tests/*) continue;; esac
    steps="$steps $p"
    hl="$(grep -n -m1 -E '^#[[:space:]]*(对应卡|Card):[[:space:]]*[0-9][0-9]-[0-9]+' "$f" | cut -d: -f1)"
    if [ -z "$hl" ]; then printf '%s:1 C9b 缺少脚本头「# 对应卡:NN-K」\n' "$p"
    else
      ref="$(sed -n "${hl}p" "$f" | grep -oE '[0-9][0-9]-[0-9]+' | head -1)"
      card_exists "$ref" "$f" || printf '%s:%s C9b 脚本头声明的卡不存在: %s\n' "$p" "$hl" "$ref"
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
for d in linux windows; do
  idx="scripts/$d/steps.tsv"; dir_steps=""
  for p in $steps; do case "$p" in scripts/"$d"/*) dir_steps="$dir_steps $p";; esac; done
  if [ ! -f "$ROOT/$idx" ]; then
    [ -n "$dir_steps" ] && printf '%s:1 C9d 缺少步骤索引(%s 侧存在步骤脚本)\n' "$idx" "$d"
    continue
  fi
  while IFS=: read -r ln x; do
    [ -n "$x" ] || continue
    x="$(norm_path <<<"$x")"
    [ -e "$ROOT/$x" ] || printf '%s:%s C9d 索引中的脚本不存在: %s\n' "$idx" "$ln" "$x"
    case " $dir_steps " in *" $x "*) ;; *) printf '%s:%s C9d 索引条目不是本侧步骤脚本: %s\n' "$idx" "$ln" "$x";; esac
  done < <(awk -F'\t' '/^[0-9][0-9]-[0-9]+/ {print NR ":" $2}' "$ROOT/$idx")
  for p in $dir_steps; do
    grep -qE "^[0-9][0-9]-[0-9]+[[:space:]]+$p([[:space:]]|$)" "$ROOT/$idx" \
      || printf '%s:1 C9d 步骤脚本未登记进索引: %s\n' "$idx" "$p"
  done
done
