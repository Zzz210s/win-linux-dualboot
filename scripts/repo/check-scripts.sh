#!/usr/bin/env bash
# 校验脚本:行数上限 200、bash 语法、shellcheck(若有)、PowerShell 语法解析
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
PS="$(command -v pwsh || command -v powershell.exe || true)"
SC="$(command -v shellcheck || true)"

# 环境缺失的检查项必须显式披露为 SKIP;SKIP 不影响退出码(退出码只由 fail 决定)。
[ -n "$SC" ] || echo "SKIP shellcheck (not installed)"
[ -n "$PS" ] || echo "SKIP powershell syntax (no pwsh)"

while IFS= read -r f; do
  n=$(wc -l < "$f")
  if [ "$n" -gt 200 ]; then echo "TOO_LONG $f ($n 行)"; fail=1; fi
  case "$f" in
    *.sh)
      bash -n "$f" || { echo "SYNTAX $f"; fail=1; }
      if [ -n "$SC" ]; then
        shellcheck -S warning "$f" || { echo "SHELLCHECK $f"; fail=1; }
      fi ;;
    *.ps1)
      if [ -n "$PS" ]; then
        # PowerShell 读不懂 MSYS 路径(/f/...),先转成 Windows 形式;无 cygpath 时原样传入
        pf="$f"
        if command -v cygpath >/dev/null; then pf="$(cygpath -w "$f")"; fi
        "$PS" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$pf',[ref]\$null,[ref]\$e); if (\$e -and \$e.Count) { \$e | ForEach-Object { Write-Output \$_.Message }; exit 1 }" \
          || { echo "PS_SYNTAX $f"; fail=1; }
      fi ;;
  esac
done < <(find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.ps1' \) | sort)

if [ "$fail" -eq 0 ]; then echo "check-scripts: OK"; else echo "check-scripts: FAIL"; fi
exit "$fail"
