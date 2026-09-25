#!/usr/bin/env bash
# 校验脚本:行数上限 200、bash 语法、shellcheck(若有)、PowerShell 语法解析
# 覆盖范围:仅 scripts/ 下的 *.sh 与 *.ps1;templates/ 下的文件(.snippet/.conf/partitions.txt 等)不在自动检查范围内,靠人工复核(扩展名/格式各不相同,无通用解析器)。
# 豁免:路径中含 /tests/ 的文件是测试夹具数据(如 scripts/repo/tests/check-docs/ 下的样例与运行时副本),
#   不参与本脚本扫描——夹具是靠 run-fixtures.sh 实际执行验证的,且夹具里允许故意不合法的对照样本。
# S-1(脚本层:发行版薄接口)扫 scripts/linux/*.sh 与 scripts/windows/*.ps1,豁免四个发行版薄接口 + 四个 Windows 契约库;
# S-2(仓库卫生)只查仓库根的追踪文件名,不查子目录布局与内容。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
PS="$(command -v pwsh || command -v powershell.exe || true)"
SC="$(command -v shellcheck || true)"
# S-1 模式:按字面量匹配,含 snapd/rpm-ostreed/snapper/snap_begin 等词内形态(不再依赖尾部 \b)。
#   只给 apt 分支加词首守卫,否则英文单词里的 apt(SCSIAdapter / NetworkAdapter / Caption)会永久误报,
#   使 Task 10 的“S-1 清零”不可达(WMI 类名与 PS 属性名不能改名)。
S1_PAT='(^|[^A-Za-z0-9_])apt(-get)?|aptitude|dpkg|dnf|snap(d)?|rpm-ostreed?'

# 环境缺失的检查项必须显式披露为 SKIP;SKIP 不影响退出码(退出码只由 fail 决定)。
# templates/ 与 /tests/ 不在检查范围内(见文件头注释):这里显式声明,避免把"未报错"误读成"通过"。
echo "NOTE 覆盖范围:仅 scripts/**.sh|ps1(豁免 /tests/);templates/ 需人工复核"
[ -n "$SC" ] || echo "SKIP shellcheck (not installed)"
[ -n "$PS" ] || echo "SKIP powershell syntax (no pwsh)"

# S-2:仓库卫生 —— 根目录的追踪文件只允许这份白名单;任何追踪文件名不得含空格。
#   背景:2026-09-25 有子代理把夹具残留文件写到仓库根并误提交、误推(已 force-with-lease 清除)。
#   非 git 工作树(如夹具里的临时副本)下静默跳过;不可达即不报错。
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  allowed_root="README.md README.zh-CN.md LICENSE .gitignore .gitattributes"
  while IFS= read -r f; do
    case "$f" in */*) continue ;; esac                 # 只看根目录文件
    ok=0; for a in $allowed_root; do [ "$f" = "$a" ] && ok=1; done
    if [ "$ok" -eq 0 ]; then echo "S2_STRAY_ROOT $f"; fail=1; fi
  done < <(git -C "$ROOT" ls-files)
  if git -C "$ROOT" ls-files | LC_ALL=C grep -q ' '; then
    echo "S2_SPACE_NAME $(git -C "$ROOT" ls-files | LC_ALL=C grep ' ' | head -n 3 | tr '\n' ' ')"; fail=1
  fi
fi

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
  # S-1:除豁免文件外,步骤脚本不得直呼包管理器(发行版差异必须收敛在接口层)。
  #   范围:scripts/linux/*.sh 与 scripts/windows/*.ps1(两侧对称);scripts/repo/** 的仓库自检不在扫描范围内(只做模式匹配,不装包)。
  #   豁免两组:四个发行版薄接口(Linux 侧收敛点)+ 四个 Windows 契约库(Windows 侧对应物)。
  case "$f" in
    "$ROOT"/scripts/linux/dbk-pkg.sh|"$ROOT"/scripts/linux/dbk-update.sh|"$ROOT"/scripts/linux/dbk-rollback.sh|"$ROOT"/scripts/linux/dbk-driver.sh) ;;
    "$ROOT"/scripts/windows/dbk.ps1|"$ROOT"/scripts/windows/dbk-cli.ps1|"$ROOT"/scripts/windows/dbk-obs.ps1|"$ROOT"/scripts/windows/dbk-win-probe.ps1) ;;
    "$ROOT"/scripts/linux/*.sh|"$ROOT"/scripts/windows/*.ps1)
      if hits="$(grep -nE "$S1_PAT" "$f" 2>/dev/null)"; then
        rel="${f#"$ROOT"/}"
        printf '%s\n' "$hits" | sed 's/^/  /'; echo "S1_PKG_LEAK $rel"; fail=1
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
