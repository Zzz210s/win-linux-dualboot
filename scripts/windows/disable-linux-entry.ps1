#Requires -Version 5.1
# 对应卡:07-13
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-13):**只停用** Fedora 启动条目(不删条目、不删分区),并断言分区数量与基线一致。
.DESCRIPTION
  **与 07-12(cleanup-nvram.ps1)的区别**:07-12 把 fedora 的 NVRAM 条目**删掉**;07-13 连条目都不删——
  它只用一次性 bootsequence 回落 {bootmgr}(让下次启动落在 Windows),再提示人工在固件设置界面把 fedora 条目
  移到最后或删除。分区表与 NVRAM 条目都原样保留,所以本卡可逆,适合"暂时不想删"的场景。
  本脚本绝不执行 bcdedit /set {fwbootmgr} displayorder(属于改序,I2)或任何删除动作。
  前置断言(任一不满足 -> 64 且零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  BootOrder 首位是 Windows Boot Manager;**当前分区数量与 baseline\02-partitions.txt 记录的一致**(证明没动分区)。
  找不到 fedora 条目 -> 2(需人工:可能已无此条目,无需停用)。
  -Check(缺省,零写)只断言并打印计划;-Apply -Yes 设一次性 bootsequence 后复读断言:固件条目数与 GUID 集合未变
  (证明不删条目)、分区数量未变(证明不删分区)、BootOrder 逐字未变且首位仍是 Windows Boot Manager、
  {bootmgr} path 未变;任一不符 -> FAIL(1)并打印复读结果。非管理员 -> 2;非 Windows -> 9。
  夹具钩子(仅离线验证,真机留空):DBK_FW_TEXT / DBK_FW_TEXT_AFTER(替代 bcdedit /enum firmware 的前/后文本)、
  DBK_BM_TEXT / DBK_BM_TEXT_AFTER(替代 /enum {bootmgr})、DBK_BCEDIT_EXE(假 bcdedit,记录 /set 调用)、
  DBK_PART_LAYOUT(当前分区表 JSON,结构同 check-partition-layout.ps1)、DBK_IS_ADMIN=1、DBK_CALLS。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:bcdedit /set {fwbootmgr} bootsequence {bootmgr}。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。固件解析与断言在库 scripts/windows/dbk-win-probe.ps1 里。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\disable-linux-entry.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\disable-linux-entry.ps1 -Apply -Yes
  退出码:0 通过 / 1 失败(后置复读不符) / 2 需人工(非管理员、分区表读不到或找不到 fedora 条目) / 9 跳过(非 Windows) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [int]$Disk = 0, [string]$Match = 'fedora|silverblue', [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
# 库文件:固件/BCD 枚举与断言 + 分区表只读读数(本脚本只数分区数,证明"没动分区")。
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\disable-linux-entry.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'disable-linux-entry' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
# 数 baseline\02-partitions.txt 里 diskpart list partition 段的分区行(.NET 的 \s 在 (?m) 下含换行,故只用 [ \t])。
function Get-DbkBasePartCount {
  param([string]$File)
  if (-not (Test-Path -LiteralPath $File)) { return -1 }
  $t = Get-Content -LiteralPath $File -Raw -Encoding UTF8
  $i = $t.IndexOf('==== Get-Disk'); if ($i -gt 0) { $t = $t.Substring(0, $i) }
  return @([regex]::Matches($t, '(?m)^[ \t]*(?:Partition|分区)[ \t]+[0-9]+[ \t]')).Count
}
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;bcdedit 读写固件条目都要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:bcdedit 读固件条目与 bootsequence 都要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
$base = 'baseline'; if ($BaselineDir) { $base = $BaselineDir }
$fw0 = Get-DbkFwEnum -What firmware -Exe $script:DbkBcd
$bm0 = Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd
$pre = Assert-DbkFwPre -Base $base -FwText $fw0 -BmText $bm0
$order0 = @((Get-DbkFwInfo -Text $fw0).Order)
$ent = @(Get-DbkFwEntries -Text $fw0)
$tg = @($ent | Where-Object { $_.Guid -ne '{fwbootmgr}' -and $_.Guid -ne '{bootmgr}' -and (($_.Desc -and $_.Desc -match $Match) -or ($_.Path -and $_.Path -match '\\EFI\\fedora\\')) })
if ($tg.Count -eq 0) {
  Add-DbkCheck ('需人工:固件条目里没有匹配 /' + $Match + '/ 或 \\EFI\\fedora\\ 的 fedora 条目(共枚举到 ' + $ent.Count + ' 条)')
  Write-DbkExit -Status 需人工 -Message ('没找到 fedora 启动条目:可能已经不存在(无需"只停用"),也可能条目名变了;请人工核对固件设置界面。本卡不删条目、不删分区,已零写')
}
# 分区数量必须与基线一致(证明本卡没动分区)
$lay = Get-DbkPartsLayout -Disk $Disk
if (-not $lay.Ok) { Add-DbkCheck ('失败项:分区表读不到:' + $lay.Reason); Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $lay.Reason + ';无法证明分区数量与基线一致,已零写') }
$baseCnt = Get-DbkBasePartCount -File (Join-Path $base '02-partitions.txt')
$cnt = @($lay.Rows).Count
if ($baseCnt -lt 0 -or $baseCnt -ne $cnt) {
  Add-DbkCheck ('失败项:当前分区数量 ' + $cnt + ' 与 ' + (Join-Path $base '02-partitions.txt') + ' 记录的不一致(基线数 ' + $baseCnt + ')')
  Write-DbkNote '本卡(07-13)只停用启动条目、绝不改分区;分区数量对不上说明分区表已被改动过,先人工核对(必要时重做基线)再重跑。已零写。'
  exit $script:DBK_USAGE
}
Add-DbkCheck ('分区数量与基线一致(' + $cnt + ' 个;基线 ' + (Join-Path $base '02-partitions.txt') + ');本卡不动分区')
Add-DbkCheck ('待停用的 fedora 条目 ' + $tg.Count + ' 条:' + (($tg | ForEach-Object { $_.Guid + '(' + $_.Desc + ')' }) -join ';'))
Write-DbkNote '手段:设一次性 bootsequence 回落 {bootmgr}(下次启动落在 Windows);永久处置(在固件设置界面把 fedora 条目移到后面或删除)属人工动作,本脚本不代做。'
Write-DbkNote '与 07-12(cleanup-nvram.ps1)的区别:07-12 删 NVRAM 条目;本卡不删条目、不删分区,只让 Linux 不再被默认选中。'
Write-DbkNote '将执行(待核实(以官方文档为准)):bcdedit /set {fwbootmgr} bootsequence {bootmgr}'
Add-DbkAction 'bcdedit /set {fwbootmgr} bootsequence {bootmgr}'
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:未执行任何命令;确认后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('前置断言全绿:分区数量与基线一致(' + $cnt + ')、BootOrder 首位是 Windows Boot Manager、fedora 条目 ' + $tg.Count + ' 条;-Check 零写,将设一次性 bootsequence 回落 {bootmgr}')
}
$r = Invoke-DbkProbeExe -Exe $script:DbkBcd -CmdArgs @('/set', '{fwbootmgr}', 'bootsequence', '{bootmgr}')
Write-DbkNote ('bcdedit /set 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
Write-DbkLog ('bcdedit /set {fwbootmgr} bootsequence {bootmgr} 退出码 ' + $r.Code)
if ($r.Code -ne 0) {
  Add-DbkCheck ('失败项:bcdedit /set {fwbootmgr} bootsequence 失败(退出码 ' + $r.Code + '):' + $r.Out)
  Write-DbkExit -Status FAIL -Message ('设置一次性启动条目失败(退出码 ' + $r.Code + '):' + $r.Out + ';未删条目、未动分区,可在管理员会话重试')
}
Set-DbkChanged
$bad = @()
$aent = @(Get-DbkFwEntries -Text (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After))
foreach ($e0 in $ent) { if (@($aent | Where-Object { $_.Guid -eq $e0.Guid }).Count -eq 0) { $bad += ('复读:固件条目 ' + $e0.Guid + ' 消失了(本卡不删条目)') } }
if ($aent.Count -ne $ent.Count) { $bad += ('复读:固件条目数变了(执行前 ' + $ent.Count + ',执行后 ' + $aent.Count + ';本卡不删条目)') }
$lay2 = Get-DbkPartsLayout -Disk $Disk
if (-not $lay2.Ok) { $bad += ('复读:' + $lay2.Reason) }
elseif (@($lay2.Rows).Count -ne $cnt) { $bad += ('复读:分区数量变了(执行前 ' + $cnt + ',执行后 ' + @($lay2.Rows).Count + ';本卡不动分区)') }
else { Add-DbkCheck ('复读通过:固件条目仍 ' + $ent.Count + ' 条、分区仍 ' + $cnt + ' 个(未删条目、未删分区)') }
$bad += @(Assert-DbkFwPost -BmPath $pre.BmPath -Order $order0 -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if (@($bad).Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('已设置一次性 bootsequence,但后置复读不符(' + @($bad).Count + ' 项,见 checks 与上面的复读值);先人工核对 bcdedit /enum firmware 与分区表,必要时在固件设置界面把 Windows Boot Manager 改回首位(I2)')
}
Write-DbkExit -Status PASS -Message ('已设一次性 bootsequence 回落 {bootmgr}(下次启动落在 Windows);固件条目 ' + $ent.Count + ' 条、分区 ' + $cnt + ' 个均未变(未删条目、未删分区);BootOrder 逐字未变、首位仍是 Windows Boot Manager、{bootmgr} path 未变;永久停用需人工在固件设置界面把 fedora 条目移后或删除')
