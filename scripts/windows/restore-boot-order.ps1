#Requires -Version 5.1
# 对应卡:07-9
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-9):把 Windows Boot Manager 归位为 BootOrder 首位(只用一次性 bootsequence,不改 BootOrder)。
.DESCRIPTION
  纪律(I2):永久启动顺序**只能在固件设置界面改**;本脚本绝不执行 bcdedit /set {fwbootmgr} displayorder 或 efibootmgr -o
  之类改序操作,也绝不改 {bootmgr} 的 path(I3)。允许的手段只有 bcdedit /set {fwbootmgr} bootsequence {bootmgr}
  (一次性语义:下次启动落在 Windows,用过即消失,不构成对 BootOrder 的改动)。
  -Check(缺省,零写):BootOrder 首位已是 Windows Boot Manager -> PASS(0)并说明无需动作;不是 -> FAIL(1)并给人工步骤
  "进固件设置界面把 Windows Boot Manager 移到第一位"(顺序本身是判据,所以 -Check 退 1 而不是 64)。
  -Apply -Yes:先存执行前 BootOrder 与 {bootmgr} path,设一次性 bootsequence,再复读并断言 ① BootOrder 逐字未变(元素级)
  ② 首位仍是 Windows Boot Manager ③ {bootmgr} 的 path 未变;任一不符 -> FAIL(1)并打印复读结果与处置。
  前置断言(任一不满足 -> 64 且零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  -Apply 还要求 BootOrder 首位已是 Windows Boot Manager(顺序本来就错时先人工改固件,一次性 bootsequence 救不了)。
  非管理员会话 -> 2(需人工);非 Windows -> 9(跳过)。
  夹具钩子(仅离线验证,真机留空):DBK_FW_TEXT / DBK_FW_TEXT_AFTER(替代 bcdedit /enum firmware 的前/后文本)、
  DBK_BM_TEXT / DBK_BM_TEXT_AFTER(替代 /enum {bootmgr})、DBK_BCEDIT_EXE(假 bcdedit,记录 -set 调用)、
  DBK_IS_ADMIN=1(强制管理员)、DBK_CALLS(假 exe 记录调用行的文件)。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:bcdedit /set {fwbootmgr} bootsequence {bootmgr}。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。固件解析与断言在库 scripts/windows/dbk-win-probe.ps1 里。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\restore-boot-order.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\restore-boot-order.ps1 -Apply -Yes
  退出码:0 通过 / 1 失败(首位不是 WBM 或后置断言不符) / 2 需人工(非管理员) / 9 跳过(非 Windows) / 64 前置断言或用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$BaselineDir = '', [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
# 固件/BCD 枚举与断言的共享实现(库文件;本脚本只做本地决策与写动作)。
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\restore-boot-order.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'restore-boot-order' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
$WBM = 'Windows Boot Manager|Windows 启动管理器'
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;firmware 枚举与 bootsequence 都要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:bcdedit /enum firmware 与 bootsequence 都要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
$base = 'baseline'; if ($BaselineDir) { $base = $BaselineDir }
$fw0 = Get-DbkFwEnum -What firmware -Exe $script:DbkBcd
$bm0 = Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd
$pre = Assert-DbkFwPre -Base $base -SkipOrderCheck:($script:DbkMode -eq 'check') -FwText $fw0 -BmText $bm0
$fi0 = Get-DbkFwInfo -Text $fw0
$order0 = @($fi0.Order)
$first0 = ''; if ($order0.Count -gt 0) { $first0 = $order0[0] }
$desc0 = ''; if ($first0 -and $fi0.Desc.ContainsKey($first0)) { $desc0 = [string]$fi0.Desc[$first0] }
Add-DbkCheck ('BootOrder 首位:' + $first0 + ' ' + $desc0 + ';判据:必须是 Windows Boot Manager(I1)')
Write-DbkNote '纪律:永久启动顺序只能在固件设置界面改(I2);本脚本只用一次性 bootsequence(bootsequence 不构成对 BootOrder 的改动)。'
if (-not ($first0 -eq '{bootmgr}' -or $desc0 -match $WBM)) {
  Write-DbkNote '人工步骤:重启进固件设置界面(UEFI/BIOS),把 "Windows Boot Manager" 移到启动顺序第一位并保存;'
  Write-DbkNote '         顺序正确后本卡即达成(-Check 应转 PASS);若固件没有顺序选项,按 docs\07-rescue.md 的"启动顺序偏差复原"一节处理。'
  if ($script:DbkMode -eq 'apply') {
    Write-DbkNote '-Apply 不写:顺序本来就错时,一次性 bootsequence 只能让下次启动落在 Windows,不能永久归位(先人工改固件)。'
    exit $script:DBK_USAGE
  }
  Write-DbkExit -Status FAIL -Message ('BootOrder 首位是 ' + $first0 + ' ' + $desc0 + ',不是 Windows Boot Manager;永久归位必须人工进固件设置界面把 Windows Boot Manager 移到第一位(本脚本不改 BootOrder,I2);已零写')
}
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:BootOrder 首位已是 Windows Boot Manager,本卡无需动作。'
  Write-DbkExit -Status PASS -Message ('BootOrder 首位已是 Windows Boot Manager(' + $first0 + ');无需动作(永久顺序仍由固件设置界面维护,I2);-Check 零写')
}
# -Apply:设一次性 bootsequence(目标 = Windows Boot Manager 固件条目 {bootmgr};一次性语义)
$target = '{bootmgr}'
Write-DbkNote ('将执行(待核实(以官方文档为准)):bcdedit /set {fwbootmgr} bootsequence ' + $target)
Add-DbkAction ('bcdedit /set {fwbootmgr} bootsequence ' + $target)
$r = Invoke-DbkProbeExe -Exe $script:DbkBcd -CmdArgs @('/set', '{fwbootmgr}', 'bootsequence', $target)
Write-DbkNote ('bcdedit /set 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
Write-DbkLog ('bcdedit /set {fwbootmgr} bootsequence ' + $target + ' 退出码 ' + $r.Code)
if ($r.Code -ne 0) {
  Add-DbkCheck ('失败项:bcdedit /set {fwbootmgr} bootsequence 失败(退出码 ' + $r.Code + '):' + $r.Out)
  Write-DbkExit -Status FAIL -Message ('设置一次性启动条目失败(退出码 ' + $r.Code + '):' + $r.Out + ';BootOrder 未被本脚本改动,可在管理员会话重试')
}
Set-DbkChanged
$bad = @(Assert-DbkFwPost -BmPath $pre.BmPath -Order $order0 -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if ($bad.Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('已设置一次性 bootsequence,但后置复读不符(' + $bad.Count + ' 项,见 checks 与上面的复读值);处置:先人工核对 bcdedit /enum firmware,必要时在固件设置界面把 Windows Boot Manager 改回首位(不得用 displayorder/efibootmgr -o)')
}
Write-DbkExit -Status PASS -Message ('已设置一次性 bootsequence(' + $target + '):下次启动落在 Windows;BootOrder 逐字未变、首位仍是 Windows Boot Manager、{bootmgr} path 未变。永久归位需人工在固件设置界面完成,本脚本只用一次性 bootsequence')
