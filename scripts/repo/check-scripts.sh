#!/usr/bin/env bash
# 校验脚本:行数上限 200、bash 语法、shellcheck(若有)、PowerShell 语法解析
# 覆盖范围:仅 scripts/ 下的 *.sh 与 *.ps1;templates/ 下的文件(.snippet/.conf/partitions.txt 等)不在自动检查范围内,靠人工复核(扩展名/格式各不相同,无通用解析器)。
# 豁免:路径中含 /tests/ 的文件是测试夹具数据(如 scripts/repo/tests/check-docs/ 下的样例与运行时副本),
#   不参与本脚本扫描——夹具是靠 run-fixtures.sh 实际执行验证的,且夹具里允许故意不合法的对照样本。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
PS="$(command -v pwsh || command -v powershell.exe || true)"
SC="$(command -v shellcheck || true)"

# 环境缺失的检查项必须显式披露为 SKIP;SKIP 不影响退出码(退出码只由 fail 决定)。
# templates/ 与 /tests/ 不在检查范围内(见文件头注释):这里显式声明,避免把"未报错"误读成"通过"。
echo "NOTE 覆盖范围:仅 scripts/**.sh|ps1(豁免 /tests/);templates/ 需人工复核"
[ -n "$SC" ] || echo "SKIP shellcheck (not installed)"
[ -n "$PS" ] || echo "SKIP powershell syntax (no pwsh)"

while IFS= read -r f; do
  n=$(wc -l < "$f")
  if [ "$n" -gt 200 ]; then echo "TOO_LONG $f ($n 行)"; fail=1; fi
  case "$f" in
    *.sh)
      bash -n "$f" || { echo "SYNTAX $f"; fail=1; }
      # 工作树 CRLF:只影响本机 lint 与“直接把文件拷到 Linux 执行”的场景(blob 由 .gitattributes 保证 LF)。
      # 注意:shellcheck 读不进 CRLF 文件(heredoc 会被当成 EOF\r 报解析错),故先剥 \r 到临时文件再 lint。
      if ! cmp -s <(tr -d '\r' < "$f") "$f"; then
        echo "WARN CRLF $f(工作树是 CRLF;Linux 上直接执行会坏。转 LF:tr -d '\\r' < f > f.lf && mv f.lf f)"
        scf="$(mktemp)"; tr -d '\r' < "$f" > "$scf"
      else
        scf="$f"
      fi
      if [ -n "$SC" ]; then
        sc_out="$(shellcheck -S warning -f gcc "$scf" 2>&1)"; sc_rc=$?
        if [ "$sc_rc" -ne 0 ]; then printf '%s\n' "${sc_out//$scf/$f}" | sed 's/^/  /'; echo "SHELLCHECK $f"; fail=1; fi
      fi
      [ "$scf" = "$f" ] || rm -f "$scf" ;;
    *.ps1)
      if [ -n "$PS" ]; then
        # PowerShell 读不懂 MSYS 路径(/f/...),先转成 Windows 形式;无 cygpath 时原样传入
        pf="$f"
        if command -v cygpath >/dev/null; then pf="$(cygpath -w "$f")"; fi
        "$PS" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$pf',[ref]\$null,[ref]\$e); if (\$e -and \$e.Count) { \$e | ForEach-Object { Write-Output \$_.Message }; exit 1 }" \
          || { echo "PS_SYNTAX $f"; fail=1; }
      fi ;;
  esac
done < <(find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.ps1' \) -not -path '*/tests/*' | sort)

# PSScriptAnalyzer(可选,高信号规则集):只跑能指真实缺陷的规则,不跑命名/风格类。
#   环境缺失(无 pwsh / 未装模块 / 调用失败)一律显式 SKIP,不影响退出码。
PSA="$(command -v pwsh || command -v pwsh.exe || true)"
if [ -z "$PSA" ] && [ -x "$HOME/scoop/apps/pwsh/current/pwsh.exe" ]; then PSA="$HOME/scoop/apps/pwsh/current/pwsh.exe"; fi
if [ -z "$PSA" ]; then echo "SKIP PSScriptAnalyzer (no pwsh)"
else
  if ! "$PSA" -NoProfile -Command "if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
    echo "SKIP PSScriptAnalyzer (module not installed)"
  else
    wdir="$(pwd)"; command -v cygpath >/dev/null && wdir="$(cygpath -w "$(pwd)")"
    psout="$("$PSA" -NoProfile -Command "Invoke-ScriptAnalyzer -Path '${wdir}\scripts\windows' -IncludeRule @('PSAvoidUsingEmptyCatchBlock','PSAvoidAssignmentToAutomaticVariable','PSAvoidUsingInvokeExpression','PSPossibleIncorrectComparisonWithNull','PSUseCmdletCorrectly') -Severity Error,Warning | ForEach-Object { \$_.ScriptPath + ':' + \$_.Line + '  [' + \$_.RuleName + '] ' + \$_.Message }" 2>&1)"; prc=$?
    if [ "$prc" -ne 0 ]; then echo "SKIP PSScriptAnalyzer (调用失败输出: rc=$prc)"
    elif [ -n "$(printf '%s' "$psout" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$psout" | sed 's/^/  /'; echo "PS_ANALYZER(高信号规则集:见上)"; fail=1
    fi
  fi
fi

if [ "$fail" -eq 0 ]; then echo "check-scripts: OK"; else echo "check-scripts: FAIL"; fi
exit "$fail"
