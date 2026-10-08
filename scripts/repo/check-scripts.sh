#!/usr/bin/env bash
# 校验脚本:行数上限 200(按物理行计)、bash 语法、shellcheck(若有)、PowerShell 语法解析(优先 5.1)、
#   .ps1 BOM、S-1 发行版薄接口、S-2 仓库卫生、步骤脚本夹具语法自检。
# 覆盖范围:仅 scripts/ 下的 *.sh 与 *.ps1;templates/ 下的文件(.snippet/.conf/partitions.txt 等)不在自动检查范围内,靠人工复核(扩展名/格式各不相同,无通用解析器)。
# 豁免:路径中含 /tests/ 的文件是测试夹具数据(scripts/repo/tests/check-docs/ 的样例与样例仓库、
#   scripts/repo/tests/check-scripts/ 的用例仓库),不参与本脚本扫描——夹具是靠各自的 run-fixtures.sh 实际执行
#   验证的,且夹具里允许故意不合法的对照样本(超 200 行、缺 BOM、包管理器字面量等),门禁不能把它们当违规。
# S-1(脚本层:发行版薄接口)扫 scripts/linux/*.sh 与 scripts/windows/*.ps1,豁免四个发行版薄接口 + 四个 Windows 契约库;
# S-2(仓库卫生)查仓库根的追踪文件与未跟踪且未被忽略的文件(git status 会看到的散落物),不查子目录布局与内容。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
# PowerShell 语法引擎:优先 PowerShell 5.1(powershell.exe)——文档与真机口径是 5.1,pwsh 7 支持 5.1 没有的
#   三元 `? :`,只用 7 会把 5.1 上的语法错判成 PASS。5.1 不可用时才退回 pwsh,并在输出里标明引擎。
PS="$(command -v powershell.exe || true)"
PS_KIND="powershell.exe (5.1)"
if [ -z "$PS" ]; then PS="$(command -v pwsh || command -v pwsh.exe || true)"; PS_KIND="pwsh (7; 5.1 不可用)"; fi
SC="$(command -v shellcheck || true)"
# S-1 模式:按字面量匹配。snap 分支两侧加词边界——命中 snap/snapd/snapd.socket,但不再误伤注释里的
#   snapshot/snapper;补 yum/zypper/pacman/apk(RHEL/openSUSE/Arch/Alpine 的包管理器,原模式漏网);
#   flatpak 只在命令形态报(“GUI 应用优先 flatpak”这类指引文字不该拦)。
#   只给 apt 分支加词首守卫,否则英文单词里的 apt(SCSIAdapter / adaptation)会永久误报,
#   使 Task 10 的“S-1 清零”不可达(WMI 类名与 PS 属性名不能改名)。
S1_PAT='(^|[^A-Za-z0-9_])apt(-get)?|aptitude|dpkg|dnf|\byum\b|\bzypper\b|\bpacman\b|\bapk\b|\bsnapd?\b|rpm-ostreed?|flatpak[[:space:]]+(install|uninstall|update|remote-add|remote-delete)|brew[[:space:]]+(install|upgrade|uninstall|bundle)'

# 环境缺失的检查项必须显式披露为 SKIP;SKIP 不影响退出码(退出码只由 fail 决定)。
# templates/ 与 /tests/ 不在检查范围内(见文件头注释):这里显式声明,避免把"未报错"误读成"通过"。
echo "NOTE 覆盖范围:仅 scripts/**.sh|ps1(豁免 /tests/);templates/ 需人工复核"
if [ -n "$PS" ]; then echo "NOTE PowerShell 语法引擎:$PS_KIND"; else echo "SKIP powershell syntax (无 powershell.exe 也无 pwsh)"; fi
[ -n "$SC" ] || echo "SKIP shellcheck (not installed)"

# S-2:仓库卫生 —— 根目录的文件只允许这份白名单;任何散落文件名不得含空格。
#   背景:2026-09-25 有子代理把夹具残留文件写到仓库根并误提交、误推(已 force-with-lease 清除)。
#   同时看追踪与未跟踪且未被忽略的文件(git ls-files --others --exclude-standard):未跟踪散落物(含带空格名)
#   过去完全逃过门禁;而 gitignore 的(.superpowers/**、.tmp/ 等)不算违规。
#   非 git 工作树(如夹具里的临时副本)下静默跳过;不可达即不报错。
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  allowed_root="README.md README.zh-CN.md LICENSE .gitignore .gitattributes"
  s2_files="$({ git -C "$ROOT" ls-files; git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */*) continue ;; esac                 # 只看根目录文件
    ok=0; for a in $allowed_root; do [ "$f" = "$a" ] && ok=1; done
    if [ "$ok" -eq 0 ]; then echo "S2_STRAY_ROOT $f"; fail=1; fi
  done <<< "$s2_files"
  if printf '%s\n' "$s2_files" | LC_ALL=C grep -q ' '; then
    echo "S2_SPACE_NAME $(printf '%s\n' "$s2_files" | LC_ALL=C grep ' ' | head -n 3 | tr '\n' ' ')"; fail=1
  fi
fi

while IFS= read -r f; do
  # 行数按物理行计:wc -l 只数换行符,末行无转行符时会少 1(200 行实为 201 时漏报)。
  n=$(awk 'END{print NR}' "$f")
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
      # 仓规:.ps1 必须 UTF-8 with BOM —— PowerShell 5.1 对无 BOM 的 UTF-8 按 ANSI 解读,中文直接乱码/解析错。
      if [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]; then
        echo "PS_NO_BOM $f"; fail=1
      fi
      if [ -n "$PS" ]; then
        # PowerShell 读不懂 MSYS 路径(/f/...),先转成 Windows 形式;无 cygpath 时原样传入
        pf="$f"
        if command -v cygpath >/dev/null; then pf="$(cygpath -w "$f")"; fi
        ps_err="$("$PS" -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$pf',[ref]\$null,[ref]\$e); if (\$e -and \$e.Count) { \$e | ForEach-Object { Write-Output \$_.Message }; exit 1 }" 2>&1)"; ps_rc=$?
        if [ "$ps_rc" -ne 0 ]; then printf '%s\n' "$ps_err" | sed 's/^/  /'; echo "PS_SYNTAX $f"; fail=1; fi
      fi ;;
  esac
  # S-1:除豁免文件外,步骤脚本不得直呼包管理器(发行版差异必须收敛在接口层)。
  #   范围:scripts/linux/*.sh 与 scripts/windows/*.ps1(两侧对称);scripts/repo/** 的仓库自检不在扫描范围内(只做模式匹配,不装包)。
  #   豁免:Linux 侧五个发行版包通道薄接口(dbk-pkg/dbk-update/dbk-rollback/dbk-driver/dbk-brew)+ 四个 Windows 契约库。
  case "$f" in
    "$ROOT"/scripts/linux/dbk-pkg.sh|"$ROOT"/scripts/linux/dbk-update.sh|"$ROOT"/scripts/linux/dbk-rollback.sh|"$ROOT"/scripts/linux/dbk-driver.sh|"$ROOT"/scripts/linux/dbk-brew.sh) ;;
    "$ROOT"/scripts/windows/dbk.ps1|"$ROOT"/scripts/windows/dbk-cli.ps1|"$ROOT"/scripts/windows/dbk-obs.ps1|"$ROOT"/scripts/windows/dbk-win-probe.ps1) ;;
    "$ROOT"/scripts/linux/*.sh|"$ROOT"/scripts/windows/*.ps1)
      if hits="$(grep -nE "$S1_PAT" "$f" 2>/dev/null)"; then
        rel="${f#"$ROOT"/}"
        printf '%s\n' "$hits" | sed 's/^/  /'; echo "S1_PKG_LEAK $rel"; fail=1
      fi ;;
  esac
done < <(find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.ps1' \) -not -path '*/tests/*' | sort)

# 夹具自检:.superpowers/sdd/*/fixtures/**/*.sh 是步骤脚本夹具(不入库)。夹具语法坏了会让整套夹具静默少跑用例
#   (2026-09-29 windows 夹具里一个转义引号错位让 3 条用例消失而套件仍报全绿),而夹具不在上面 scripts/ 的扫描范围内。
#   夹具不受 200 行上限与 shellcheck 风格规则约束,这里只逐个查 bash 语法。
if [ -d "$ROOT/.superpowers/sdd" ]; then
  while IFS= read -r fx; do
    bash -n "$fx" 2>/dev/null || { echo "FIXTURE_SYNTAX ${fx#"$ROOT"/}"; fail=1; }
  done < <(find "$ROOT/.superpowers/sdd" -type f -path '*/fixtures/*' -name '*.sh' | sort)
fi

# PSScriptAnalyzer(可选,高信号规则集):只跑能指真实缺陷的规则,不跑命名/风格类。
#   路径一律基于 $ROOT(用 $(pwd) 时从非仓库根调用会静默跳过 windows 目录);
#   模块缺失才可 SKIP;调用失败(rc≠0)是门禁自身的错,必须 FAIL 而不是静默放过。
PSA="$(command -v pwsh || command -v pwsh.exe || true)"
if [ -z "$PSA" ] && [ -x "$HOME/scoop/apps/pwsh/current/pwsh.exe" ]; then PSA="$HOME/scoop/apps/pwsh/current/pwsh.exe"; fi
if [ -z "$PSA" ]; then echo "SKIP PSScriptAnalyzer (no pwsh)"
elif [ ! -d "$ROOT/scripts/windows" ]; then echo "SKIP PSScriptAnalyzer (no scripts/windows)"
else
  if ! "$PSA" -NoProfile -Command "if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
    echo "SKIP PSScriptAnalyzer (module not installed)"
  else
    # 转成 PowerShell 认得的路径(Windows 上 cygpath -w),再统一成正斜杠
    wdir="$ROOT"; command -v cygpath >/dev/null && wdir="$(cygpath -w "$ROOT")"
    wdir="${wdir//\\//}"
    psout="$("$PSA" -NoProfile -Command "Invoke-ScriptAnalyzer -Path '${wdir}/scripts/windows' -IncludeRule @('PSAvoidUsingEmptyCatchBlock','PSAvoidAssignmentToAutomaticVariable','PSAvoidUsingInvokeExpression','PSPossibleIncorrectComparisonWithNull','PSUseCmdletCorrectly') -Severity Error,Warning | ForEach-Object { \$_.ScriptPath + ':' + \$_.Line + '  [' + \$_.RuleName + '] ' + \$_.Message }" 2>&1)"; prc=$?
    if [ "$prc" -ne 0 ]; then
      printf '%s\n' "$psout" | sed 's/^/  /'; echo "PS_ANALYZER_RUN_FAIL (rc=$prc;调用失败,不是模块缺失)"; fail=1
    elif [ -n "$(printf '%s' "$psout" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$psout" | sed 's/^/  /'; echo "PS_ANALYZER(高信号规则集:见上)"; fail=1
    fi
  fi
fi

if [ "$fail" -eq 0 ]; then echo "check-scripts: OK"; else echo "check-scripts: FAIL"; fi
exit "$fail"
