#Requires -Version 5.1
# 对应卡:07-12
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-12):删除 Fedora 残留的 NVRAM 固件启动条目(只删条目,不动分区、不动 BootOrder)。
.DESCRIPTION
  目标:枚举 bcdedit /enum firmware,取 path 指向 \EFI\fedora\ 或 description 含 fedora/silverblue 的条目
  (给了 -Match 时按该正则匹配 description,默认 'fedora|silverblue';给了 -Guid 时只认这些 GUID)。
  **不得用 displayorder 代删**(I2:不允许改 BootOrder);删除手段是 bcdedit /delete <GUID> /f。
  前置断言(任一不满足 -> 64 且零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  BootOrder 首位是 Windows Boot Manager;至少找到一条目标条目(-Guid 指定的某条不存在 -> 64,目标未确认)。
  找不到任何可删条目 -> 2(需人工:可能已清干净,请人工核对固件设置界面)。
  -Check(缺省,零写)只列出将要删除的条目并断言 BootOrder;-Apply -Yes 逐条删除后复读断言:目标条目已消失、非目标条目
  仍在、BootOrder 逐字未变且首位仍是 Windows Boot Manager、{bootmgr} path 未变;任一不符 -> FAIL(1)并打印复读结果。
  与 07-13(disable-linux-entry)的区别:07-13 不删条目(只设一次性 bootsequence 让 Linux 不再被默认选中)。
  非管理员会话 -> 2(需人工);非 Windows -> 9(跳过)。
  夹具钩子(仅离线验证,真机留空):DBK_FW_TEXT / DBK_FW_TEXT_AFTER(替代 bcdedit /enum firmware 的前/后文本)、
  DBK_BM_TEXT / DBK_BM_TEXT_AFTER(替代 /enum {bootmgr})、DBK_BCEDIT_EXE(假 bcdedit,记录 /delete 调用)、
  DBK_IS_ADMIN=1(强制管理员)、DBK_CALLS(假 exe 记录调用行的文件)。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:bcdedit /delete <GUID> /f。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。固件解析与断言在库 scripts/windows/dbk-win-probe.ps1 里。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\cleanup-nvram.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\cleanup-nvram.ps1 -Apply -Yes
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\cleanup-nvram.ps1 -Apply -Yes -Guid '{xxxx-...}'
  退出码:0 通过 / 1 失败(后置复读不符) / 2 需人工(非管理员或找不到可删条目) / 9 跳过(非 Windows) / 64 前置断言或用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Match = 'fedora|silverblue', [string[]]$Guid = @(), [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
# 固件/BCD 枚举与断言的共享实现(库文件;本脚本只做目标选择与写动作)。
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\cleanup-nvram.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'cleanup-nvram' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;bcdedit /enum firmware 与 /delete 都要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:bcdedit /enum firmware 与 /delete 都要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
$base = 'baseline'; if ($BaselineDir) { $base = $BaselineDir }
$fw0 = Get-DbkFwEnum -What firmware -Exe $script:DbkBcd
$bm0 = Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd
$pre = Assert-DbkFwPre -Base $base -FwText $fw0 -BmText $bm0
$ent = @(Get-DbkFwEntries -Text $fw0)
# 选目标:给了 -Guid 只认这些 GUID(任一不存在 -> 64,目标未确认);否则按 -Match / \EFI\fedora\ 匹配。
$guids = @($Guid | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().Trim('{', '}').ToUpper() })
$targets = @(); $miss = @()
if ($guids.Count -gt 0) {
  foreach ($g in $guids) {
    $h = @($ent | Where-Object { $_.Guid.Trim('{', '}').ToUpper() -eq $g })
    if ($h.Count -eq 0) { $miss += $g } else { $targets += $h[0] }
  }
  if ($miss.Count -gt 0) {
    Add-DbkCheck ('失败项:-Guid 指定的条目不存在:' + ($miss -join ' '))
    Write-DbkNote '现有固件条目:'
    foreach ($e in $ent) { Write-DbkNote ('  ' + $e.Guid + '  ' + $e.Desc + '  路径:' + $e.Path) }
    Write-DbkNote '目标未确认,已零写;请核对 GUID(或去掉 -Guid 让脚本按 -Match 自动匹配)。'
    exit $script:DBK_USAGE
  }
} else {
  $targets = @($ent | Where-Object { $_.Guid -ne '{fwbootmgr}' -and $_.Guid -ne '{bootmgr}' -and (($_.Desc -and $_.Desc -match $Match) -or ($_.Path -and $_.Path -match '\\EFI\\fedora\\')) })
  if ($targets.Count -eq 0) {
    Add-DbkCheck ('需人工:固件条目里没有匹配 /' + $Match + '/ 或 \\EFI\\fedora\\ 的条目(共枚举到 ' + $ent.Count + ' 条)')
    Write-DbkExit -Status 需人工 -Message ('没有找到可删的 fedora 条目(可能已清干净):请人工在固件设置界面核对是否还有 Fedora/其他 Linux 残留条目;本脚本只删条目、不删分区,已零写')
  }
}
$tg = @($targets | ForEach-Object { ([string]$_.Guid).Trim('{', '}').ToUpper() })
Add-DbkCheck ('删除目标 ' + $targets.Count + ' 条:' + (($targets | ForEach-Object { $_.Guid + '(' + $_.Desc + ')' }) -join ';'))
Write-DbkNote ('将执行(待核实(以官方文档为准)):bcdedit /delete <GUID> /f,共 ' + $targets.Count + ' 条')
foreach ($t in $targets) { Write-DbkNote ('  bcdedit /delete ' + $t.Guid + ' /f   # ' + $t.Desc + '  路径:' + $t.Path); Add-DbkAction ('bcdedit /delete ' + $t.Guid + ' /f') }
Write-DbkNote '纪律:本脚本绝不执行 bcdedit /set {fwbootmgr} displayorder 之类的改序操作(I2);只删条目、不删分区。'
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:未执行任何删除;确认目标无误后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('识别到 ' + $targets.Count + ' 条 fedora NVRAM 条目可删(见 actions);BootOrder 首位仍是 Windows Boot Manager;-Check 零写')
}
$bad = @()
foreach ($t in $targets) {
  $r = Invoke-DbkProbeExe -Exe $script:DbkBcd -CmdArgs @('/delete', $t.Guid, '/f')
  Write-DbkNote ('bcdedit /delete ' + $t.Guid + ' /f 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
  Write-DbkLog ('bcdedit /delete ' + $t.Guid + ' /f 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
  if ($r.Code -ne 0) { $bad += ('删除 ' + $t.Guid + ' 失败(退出码 ' + $r.Code + '):' + $r.Out) }
}
Set-DbkChanged
$aent = @(Get-DbkFwEntries -Text (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After))
foreach ($t in $tg) { if (@($aent | Where-Object { $_.Guid.Trim('{', '}').ToUpper() -eq $t }).Count -gt 0) { $bad += ('复读:条目 ' + $t + ' 仍在(未被删除)') } }
foreach ($e0 in $ent) {
  $k = ([string]$e0.Guid).Trim('{', '}').ToUpper()
  if ($tg -contains $k) { continue }
  if (@($aent | Where-Object { $_.Guid.Trim('{', '}').ToUpper() -eq $k }).Count -eq 0) { $bad += ('复读:非目标条目 ' + $e0.Guid + ' 消失(只应删目标条目)') }
}
if (@($bad).Count -eq 0) { Add-DbkCheck ('复读通过:' + $targets.Count + ' 条目标条目已消失,其余 ' + ($ent.Count - $targets.Count) + ' 条仍在') }
$bad += @(Assert-DbkFwPost -BmPath $pre.BmPath -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if (@($bad).Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('已执行删除,但后置复读不符(' + @($bad).Count + ' 项,见 checks 与上面的复读值);先人工核对 bcdedit /enum firmware,必要时在固件设置界面把 Windows Boot Manager 改回首位(I2)')
}
Write-DbkExit -Status PASS -Message ('已删除 ' + $targets.Count + ' 条 fedora NVRAM 条目;目标条目消失、非目标条目仍在;BootOrder 首位仍是 Windows Boot Manager(删条目会让它从列表里消失,但首位不变)、{bootmgr} path 未变')
