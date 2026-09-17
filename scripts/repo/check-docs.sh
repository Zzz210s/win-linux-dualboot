#!/usr/bin/env bash
# 校验文档:六段式章节、占位符、emoji、相对链接。用法:check-docs.sh [file...]
# 缺省集合 = docs/*.md(手册清单 + 实际存在者) + 仓库根两份 README。
# 注意:docs/design/ 属设计文档,不在缺省集合内,仅在显式传参时检查。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
REQ=("## 目标" "## 前置条件" "## 步骤" "## 验证" "## 失败处理" "## 回滚")
PH='TBD|TODO|待补|FIXME|占位符'
# 手册应有清单:文档尚未写出时如实报 MISSING,而不是静默跳过
EXPECTED=(00-overview.md 01-firmware.md 02-windows.md 03-preflight.md 04-ubuntu.md
  05-first-boot.md 06-decommission.md 07-rescue.md 08-verification.md 09-risks.md 10-faq.md)

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  mapfile -t files < <(
    {
      for n in "${EXPECTED[@]}"; do printf '%s\n' "$ROOT/docs/$n"; done
      find "$ROOT/docs" -maxdepth 1 -name '*.md' | sort
      printf '%s\n' "$ROOT/README.md" "$ROOT/README.zh-CN.md"
    } | awk '!seen[$0]++'
  )
fi

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then echo "MISSING $f"; fail=1; continue; fi
  base="$(basename "$f")"
  if [ "$base" != "00-overview.md" ] && [ "$base" != "10-faq.md" ] && [ "$base" != "README.md" ] && [ "$base" != "README.zh-CN.md" ]; then
    for h in "${REQ[@]}"; do
      grep -qF "$h" "$f" || { echo "MISSING_SECTION $f :: $h"; fail=1; }
    done
  fi
  if grep -nE "$PH" "$f" >/dev/null; then
    echo "PLACEHOLDER $f"; grep -nE "$PH" "$f" | head -3; fail=1
  fi
  if grep -qP '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]' "$f" 2>/dev/null; then
    echo "EMOJI $f"; fail=1
  fi
  while IFS= read -r link; do
    case "$link" in http*|"") continue ;; esac
    d="$(dirname "$f")"
    [ -e "$d/$link" ] || { echo "BROKEN_LINK $f -> $link"; fail=1; }
  done < <(grep -oE '\]\([^)#][^)]*\)' "$f" | sed -E 's/^\]\(//; s/\)$//' | grep -E '\.md$|\.sh$|\.ps1$|\.txt$|\.snippet$|\.conf$')
done

if [ "$fail" -eq 0 ]; then echo "check-docs: OK"; else echo "check-docs: FAIL"; fi
exit "$fail"
