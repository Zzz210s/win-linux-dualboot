#!/usr/bin/env bash
# 用例⑤⑥:.ps1 必须 UTF-8 with BOM;PowerShell 语法解析优先 5.1。
#   BOM 检查与所在目录无关(只认扩展名),故夹具放 scripts/misc/(避开 PSScriptAnalyzer 对 scripts/windows 的全量扫描,让用例快)。
#   三元 `? :` 只在 5.1 下是语法错,pwsh 7 会放行 —— 同一用例同时证明门禁真的在用 5.1。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

d="$(mk_repo ps)"
mkdir -p "$d/scripts/misc"
BOM="$(printf '\xef\xbb\xbf')"
printf '%s\n'   'Write-Output "hi"'            > "$d/scripts/misc/nobom.ps1"    # 无 BOM -> PS_NO_BOM
printf '%s%s\n' "$BOM" 'Write-Output "hi"'     > "$d/scripts/misc/withbom.ps1"  # 有 BOM -> 不报
printf '%s%s\n' "$BOM" '$x = $true ? 1 : 2'    > "$d/scripts/misc/ternary.ps1"  # 5.1 语法错 -> PS_SYNTAX
printf '%s%s\n' "$BOM" 'if ($true) { 1 } else { 2 }' > "$d/scripts/misc/ifelse.ps1"  # 合法 -> 不报

run_gate "$d"
want_re "无 BOM 的 .ps1 报 PS_NO_BOM"   "PS_NO_BOM .*nobom\\.ps1"
dont_re "带 BOM 的 .ps1 不报 PS_NO_BOM" "PS_NO_BOM .*withbom\\.ps1"
if command -v powershell.exe >/dev/null; then
  want "优先选 PowerShell 5.1(引擎自述)" "powershell.exe (5.1)"
  want_re "5.1 下三元 ? : 报 PS_SYNTAX"  "PS_SYNTAX .*ternary\\.ps1"
  dont_re "5.1 下 if/else 不报 PS_SYNTAX" "PS_SYNTAX .*ifelse\\.ps1"
  cnt_is 1 "PS_SYNTAX" "PS_SYNTAX 只报一次(三元那个)"
else
  skip "本机无 powershell.exe,跳过 5.1 三元用例"
fi
summary
