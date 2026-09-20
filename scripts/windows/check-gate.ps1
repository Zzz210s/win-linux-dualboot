#Requires -Version 5.1
# 对应卡:03-7
<#
.SYNOPSIS
  轨道 W:读 L2 闸门结论——解析闸门报告,列红项并给退出码;**只有本卡判"能否进入 L3"**(红项一条都不许带进 L3)。
.DESCRIPTION
  读入 preflight.ps1 生成的报告(缺省 baseline\02-preflight-report.md),取三样:
    1) 末段结论行:结论: 允许进入 L3 / 结论: 禁止进入 L3;
    2) 结论节的"红项:<清单>;黄项:<清单>"行(黄项只登记,不阻塞);
    3) "检查项与判定"表里判定列为 红 的行(逐条列出来)。
  判据(design 4.3 的闸门规则):结论为"允许进入 L3"且红项为空/无 → 通过(0);否则失败(1)并逐条列红项。
  不写报告、不改判定列:要改状态就改系统然后重跑 preflight.ps1(03-6),不要手工编辑报告。
  只读:不写任何系统状态与文件;唯一写动作是 -Apply 时的日志(本卡无自动改系统的动作)。-Apply 与 -Check 等价。
  退出码:0 允许进入 L3 / 1 禁止进入 L3 或报告缺失、不完整 / 64 用法错误。
  参数:-Report <报告路径> 缺省 baseline\02-preflight-report.md。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法(仓库根):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\check-gate.ps1 -Check
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$Report = 'baseline\02-preflight-report.md'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'check-gate' }

$Report = [System.IO.Path]::GetFullPath($Report)
if (-not (Test-Path -LiteralPath $Report)) {
  Write-DbkExit -Status FAIL -Message ('闸门报告不存在:' + $Report + ';先跑 03-6 的 preflight.ps1 生成报告再重跑本脚本')
}
$lines = @([System.IO.File]::ReadAllLines($Report, [System.Text.Encoding]::UTF8))
Add-DbkCheck ('报告:' + $Report + '(' + $lines.Count + ' 行)')

# 1) 结论行(取最后一次出现;报告末行固定为它)
$verdict = ''
foreach ($l in $lines) { if ($l -match '^结论:\s*(允许|禁止)进入 L3') { $verdict = $Matches[1] } }
if (-not $verdict) {
  Write-DbkExit -Status FAIL -Message ('报告里找不到结论行(应为"结论: 允许进入 L3"或"结论: 禁止进入 L3"):' + $Report + ';报告不完整,请重跑 03-6 的 preflight.ps1')
}
Add-DbkCheck ('结论: ' + $verdict + '进入 L3')

# 2) 判定表里的红项(判定列为 红;表行形如 | 检查项 | 实测值 | 红 |)
$reds = @()
foreach ($l in $lines) {
  if ($l -match '^\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*红\s*\|\s*$') {
    $item = $Matches[1].Trim()
    if ($item -and $item -ne '检查项' -and ($reds -notcontains $item)) { $reds += $item }
  }
}
# 3) 结论节的"红项:...;黄项:..."行(报告把清单也写在一行里)
$redList = @()
$yellowList = @()
foreach ($l in $lines) {
  if ($l -match '^\s*-\s*红项:\s*(.*?);\s*黄项:\s*(.*)$') {
    if ($Matches[1].Trim() -and $Matches[1].Trim() -ne '无') { $redList = @($Matches[1] -split '、' | Where-Object { $_.Trim() }) }
    if ($Matches[2].Trim() -and $Matches[2].Trim() -ne '无') { $yellowList = @($Matches[2] -split '、' | Where-Object { $_.Trim() }) }
  }
}
foreach ($r in $redList) { $r = $r.Trim(); if ($r -and ($reds -notcontains $r)) { $reds += $r } }
if ($yellowList.Count -gt 0) { Add-DbkCheck ('黄项(记录后继续,不阻塞):' + (@($yellowList | ForEach-Object { $_.Trim() }) -join '、')) }
else { Add-DbkCheck '黄项:无' }

if ($reds.Count -eq 0) { Add-DbkCheck '红项:无' }
else { foreach ($r in $reds) { Add-DbkCheck ('失败项:红项 ' + $r) } }

if ($verdict -eq '允许' -and $reds.Count -eq 0) {
  Write-DbkExit -Status PASS -Message ('闸门通过:结论"允许进入 L3"且无红项(黄项 ' + $yellowList.Count + ' 项已登记);可进入 L3')
}
if ($verdict -eq '禁止') {
  Write-DbkExit -Status FAIL -Message ('闸门未过:报告结论为"禁止进入 L3";红项 ' + $reds.Count + ' 条:' + ($reds -join '、') + ';按 03-6 的出错时:逐条修复后重跑 preflight.ps1,红项一条都不许带进 L3')
}
Write-DbkExit -Status FAIL -Message ('闸门未过:结论行与判定表不一致(结论"允许"但表里仍有红项 ' + $reds.Count + ' 条:' + ($reds -join '、') + ');报告可能被手工改过,请重跑 03-6 的 preflight.ps1 定稿')
