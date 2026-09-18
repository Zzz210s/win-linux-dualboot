#!/usr/bin/env bash
# 校验文档:六段式章节、占位符、emoji、相对链接。用法:check-docs.sh [file...]
# 缺省集合 = docs/*.md(手册清单 + 实际存在者) + checklists/*.md + 仓库根两份 README。
# 注意:docs/design/ 属设计文档,不在缺省集合内,仅在显式传参时检查。
# 注意:checklists/*.md 是勾选清单(非六段式手册),只受占位符/emoji/链接检查。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
REQ=("## 目标" "## 前置条件" "## 步骤" "## 验证" "## 失败处理" "## 回滚")
PH='TBD|TODO|待补|FIXME|占位符'
# emoji 字节模式(F0 9F = U+1F000 及以上;E2 98/99/9A/9B = U+2600~U+26FF 符号区;E2 9C/9D/9E = U+2700~U+27BF dingbats 区(U+2705 / U+2728 / U+274C / U+27A1 之类);EF B8 8F = 变体选择符)。
# 本机 grep -P 不支持多字节码点范围(恒 exit 2,且 LC_ALL=C.UTF-8 会把 ASCII 判成 emoji),故用 LC_ALL=C 下的字节级 -E 匹配。
EMOJI="$(printf '\xf0\x9f|\xe2\x98|\xe2\x99|\xe2\x9a|\xe2\x9b|\xe2\x9c|\xe2\x9d|\xe2\x9e|\xef\xb8\x8f')"
# 手册应有清单:文档尚未写出时如实报 MISSING,而不是静默跳过
EXPECTED=(00-overview.md 01-firmware.md 02-windows.md 03-preflight.md 04-ubuntu.md
  05-first-boot.md 06-decommission.md 07-rescue.md 08-verification.md 09-risks.md 10-faq.md)

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  mapfile -t files < <(
    {
      for n in "${EXPECTED[@]}"; do printf '%s\n' "$ROOT/docs/$n"; done
      find "$ROOT/docs" -maxdepth 1 -name '*.md' | sort
      find "$ROOT/checklists" -maxdepth 1 -name '*.md' 2>/dev/null | sort
      printf '%s\n' "$ROOT/README.md" "$ROOT/README.zh-CN.md"
    } | awk '!seen[$0]++'
  )
fi

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then echo "MISSING $f"; fail=1; continue; fi
  base="$(basename "$f")"
  case "$f" in
    checklists/*|*/checklists/*) : ;;  # 勾选清单不是六段式手册,只做占位符/emoji/链接检查
    *)
      if [ "$base" != "00-overview.md" ] && [ "$base" != "10-faq.md" ] && [ "$base" != "README.md" ] && [ "$base" != "README.zh-CN.md" ]; then
        for h in "${REQ[@]}"; do
          grep -qF "$h" "$f" || { echo "MISSING_SECTION $f :: $h"; fail=1; }
        done
      fi ;;
  esac
  if grep -nE "$PH" "$f" >/dev/null; then
    echo "PLACEHOLDER $f"; grep -nE "$PH" "$f" | head -3; fail=1
  fi
  if LC_ALL=C grep -qE "$EMOJI" "$f"; then
    echo "EMOJI $f"; fail=1
  fi
  while IFS= read -r link; do
    case "$link" in http*|"") continue ;; esac
    d="$(dirname "$f")"
    [ -e "$d/$link" ] || { echo "BROKEN_LINK $f -> $link"; fail=1; }
    # 先剥离锚点(#...),再做扩展名过滤;否则 "x.md#锚点" 会被整条丢弃而漏检
  done < <(grep -oE '\]\([^)#][^)]*\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/#.*$//' | grep -E '\.md$|\.sh$|\.ps1$|\.txt$|\.snippet$|\.conf$')
done

if [ "$fail" -eq 0 ]; then echo "check-docs: OK"; else echo "check-docs: FAIL"; fi
exit "$fail"
