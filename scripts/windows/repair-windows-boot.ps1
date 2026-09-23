#Requires -Version 5.1
# 对应卡:07-3
# 破坏性:1
<#
.SYNOPSIS
  轨道 D 救援(07-3):Windows 系统分区完好、只是 Windows 引导坏了时,用 bcdboot 在 ESP 上重建 \EFI\Microsoft\。
.DESCRIPTION
  适用(设计 4.8「崩溃后原地重装」第三选择):C:\Windows 还在,但固件里 Windows 启动项指向的引导文件缺失/损坏。
  前置断言(任一不满足 -> 零写退出):-WindowsDir(缺省 %SystemDrive%\Windows)下 System32\winload.efi 存在、ESP 盘符可用
  (-EspLetter 指定或自动挑 S/T/U/V/W 中空闲的)、给了 -BaselineDir 时其下 02-firmware-entries.txt 存在;这些判「用法/前提
  错误」-> 64。非管理员会话 -> 2(需人工;mountvol /s 与 bcdboot 都要求管理员);读不到固件条目 -> 2。
  判据:允许 bcdboot 重写 <ESP>:\EFI\Microsoft\Boot\bootmgfw.efi 与 BCD(这正是它的职责),但**绝不允许** {bootmgr} 的
  path 与 BootOrder 首位变化:执行前后各读一次,不一致 -> FAIL(1)并打印复读结果;BootOrder 首位不是 Windows Boot Manager
  时判 FAIL(1,设计 I1)且不执行任何写动作。
  纪律:不改 {bootmgr} 的 path、不写 displayorder/efibootmgr -o、不动 \EFI\ubuntu\;ESP 只临时挂载,finally 必卸载。
  夹具钩子(仅离线验证,真机留空):DBK_MOUNTVOL_EXE / DBK_BCDBOOT_EXE / DBK_BCEDIT_EXE(假 exe)、DBK_WIN_DIR(替代
  -WindowsDir)、DBK_ESP_LETTER(替代 -EspLetter)、DBK_IS_ADMIN(1=强制管理员,0=强制非管理员)、DBK_ESP_ROOT(把 ESP 当
  普通目录,替代对 <盘符>:\ 的文件断言;仍会调用假 mountvol)。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:mountvol <ESP>: /s、bcdboot <WindowsDir> /s <ESP>: /f UEFI、mountvol <ESP>: /d。
  未在真机验证(夹具级验证,真机未跑);本文件 UTF-8 with BOM;bcdedit 输出按中英双语字段名解析。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\repair-windows-boot.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\repair-windows-boot.ps1 -Apply -Yes -EspLetter S
  退出码:0 通过 / 1 失败(bcdboot 失败、判据或后置断言不符)/ 2 需人工(非管理员会话或读不到固件条目)/ 9 跳过(非 Windows)
          / 64 前置断言失败或用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$WindowsDir = '', [string]$EspLetter = '', [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\repair-windows-boot.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'repair-windows-boot' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
# 外部命令统一走这个包装:合并 stdout/stderr 后由调用方打印(不吞 stderr),并带回退出码。
function Invoke-DbkExe {
  param([string]$Exe, [string[]]$CmdArgs = @())
  $o = ''; $c = 1
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = [string](& $Exe @CmdArgs 2>&1 | Out-String); $c = [int]$LASTEXITCODE }
  catch { $o = [string]$_.Exception.Message; $c = 1 }
  $ErrorActionPreference = $prev
  return @{ Out = $o.Trim(); Code = $c }
}
# bcdedit 输出解析(中英双语字段名):displayorder/显示顺序 -> BootOrder;identifier/标识符 起块;description/描述 是名字
function Get-DbkFwInfo {
  param([string]$Text)
  $order = @(); $desc = @{}; $path = ''; $inOrder = $false; $cur = ''
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*(displayorder|显示顺序|启动顺序)\s*(.*)$') {
      $inOrder = $true
      foreach ($g in [regex]::Matches($Matches[2], '\{[^}]+\}')) { $order += $g.Value }
      continue
    }
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') { $cur = $Matches[2]; $inOrder = $false; continue }
    if ($line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { if ($cur -and -not $desc.ContainsKey($cur)) { $desc[$cur] = $Matches[2] }; continue }
    if ($line -match '^\s*(path|路径)\s+(\S.*?)\s*$') { if (-not $path) { $path = $Matches[2] }; continue }
    if ($inOrder) { $gs = @([regex]::Matches($line, '\{[^}]+\}')); if ($gs.Count -eq 0) { $inOrder = $false } else { foreach ($g in $gs) { $order += $g.Value } } }
  }
  return @{ Order = @($order); Desc = $desc; Path = $path }
}
$WBM = 'Windows Boot Manager|Windows 启动管理器'
$bcdedit = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $bcdedit = $env:DBK_BCEDIT_EXE }
$mountvol = 'mountvol'; if ($env:DBK_MOUNTVOL_EXE) { $mountvol = $env:DBK_MOUNTVOL_EXE }
$bcdboot = 'bcdboot'; if ($env:DBK_BCDBOOT_EXE) { $bcdboot = $env:DBK_BCDBOOT_EXE }
# 前置断言 1:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制)
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:mountvol /s 与 bcdboot 都要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
# 前置断言 2:Windows 系统分区完好(System32\winload.efi 在)
$winDir = $WindowsDir
if ($env:DBK_WIN_DIR) { $winDir = $env:DBK_WIN_DIR }
if (-not $winDir) { $winDir = Join-Path $env:SystemDrive 'Windows' }
$winDir = $winDir.TrimEnd('\')
$winload = Join-Path $winDir 'System32\winload.efi'
if (-not (Test-Path -LiteralPath $winload)) {
  Add-DbkCheck ('失败项:' + $winload + ' 不存在,不像完好的 Windows 系统分区')
  Write-DbkNote ('前置断言不满足:' + $winDir + ' 下没有 System32\winload.efi;本脚本只用于"系统分区完好、引导坏"的场景(设计 4.8 第三选择),已零写。')
  exit $script:DBK_USAGE
}
# 前置断言 3:给了 -BaselineDir 时必须能读到基线固件快照
if ($BaselineDir) {
  $fwBase = Join-Path $BaselineDir '02-firmware-entries.txt'
  if (-not (Test-Path -LiteralPath $fwBase)) {
    Add-DbkCheck ('失败项:基线固件快照不存在:' + $fwBase)
    Write-DbkNote ('前置断言不满足:-BaselineDir ' + $BaselineDir + ' 下没有 02-firmware-entries.txt;已零写。')
    exit $script:DBK_USAGE
  }
}
# 前置断言 4:ESP 盘符可用(夹具可用 DBK_ESP_ROOT 指定一个普通目录替代挂载)
$espHook = [string]$env:DBK_ESP_ROOT
$espLetter = $EspLetter; if ($env:DBK_ESP_LETTER) { $espLetter = $env:DBK_ESP_LETTER }
$letter = ''
if ($espLetter) {
  $letter = $espLetter.TrimEnd(':')
  if (-not $espHook -and (Test-Path -LiteralPath ($letter + ':\'))) {
    Add-DbkCheck ('失败项:盘符 ' + $letter + ': 已被占用')
    Write-DbkNote ('前置断言不满足:盘符 ' + $letter + ': 已被占用,请换 -EspLetter 指定空闲盘符;已零写。')
    exit $script:DBK_USAGE
  }
} else { foreach ($c in @('S', 'T', 'U', 'V', 'W')) { if (-not (Test-Path -LiteralPath ($c + ':\'))) { $letter = $c; break } } }
if (-not $letter) {
  Add-DbkCheck '失败项:S/T/U/V/W 都被占用,找不到空闲盘符'
  Write-DbkNote '前置断言不满足:S/T/U/V/W 都被占用,请用 -EspLetter 指定空闲盘符;已零写。'
  exit $script:DBK_USAGE
}
$mp = $letter + ':'; $probe = $mp + '\'
if ($espHook) { $probe = $espHook.TrimEnd('\') + '\' }
# 执行前状态:{bootmgr} 的 path 与 BootOrder 首位(只读)
$rFw = Invoke-DbkExe $bcdedit @('/enum', 'firmware')
if ($rFw.Out) { Write-DbkLog ('bcdedit /enum firmware(执行前)退出码 ' + $rFw.Code + ';输出:' + ($rFw.Out -replace "`r?`n", ' | ')) }
$rBm = Invoke-DbkExe $bcdedit @('/enum', '{bootmgr}')
$bmPre = ''; if ($rBm.Code -eq 0) { $bmPre = (Get-DbkFwInfo $rBm.Out).Path }
$fwPre = $null; if ($rFw.Code -eq 0 -and $rFw.Out) { $fwPre = Get-DbkFwInfo $rFw.Out }
if (-not $fwPre -or @($fwPre.Order).Count -eq 0 -or -not $bmPre) {
  $why = @()
  if (-not $fwPre -or @($fwPre.Order).Count -eq 0) { $why += ('读不到固件启动条目(BootOrder):bcdedit /enum firmware 退出码 ' + $rFw.Code) }
  if (-not $bmPre) { $why += ('读不到 {bootmgr} 的 path:bcdedit /enum {bootmgr} 退出码 ' + $rBm.Code) }
  Add-DbkCheck ('需人工核对:' + ($why -join ';'))
  Write-DbkExit -Status 需人工 -Message (($why -join ';') + ';常见原因:非管理员会话,或系统以 Legacy/BIOS 方式启动;本步无法自动判定,本次零写')
}
$orderPre = @($fwPre.Order); $firstPre = $orderPre[0]
$descPre = ''; if ($fwPre.Desc.ContainsKey($firstPre)) { $descPre = $fwPre.Desc[$firstPre] }
$firstIsWbm = ($firstPre -eq '{bootmgr}' -or $descPre -match $WBM)
Add-DbkCheck '管理员权限: 是'
Add-DbkCheck ('Windows 系统分区完好:' + $winload + ' 存在')
if ($BaselineDir) { Add-DbkCheck ('基线固件快照存在:' + (Join-Path $BaselineDir '02-firmware-entries.txt')) }
if ($espHook) { Add-DbkCheck ('ESP(夹具模式):' + $probe + '(DBK_ESP_ROOT;仍会调用假 mountvol)') } else { Add-DbkCheck ('ESP 盘符:' + $mp + '(自动挑到的空闲盘符)') }
$canProbe = [bool]$espHook -or (Test-Path -LiteralPath ($mp + '\'))
if ($canProbe) {
  if (Test-Path -LiteralPath ($probe + 'EFI\Microsoft')) { Add-DbkCheck 'ESP 上已有 \EFI\Microsoft\(bcdboot 会按需重写其中的 bootmgfw.efi 与 BCD)' }
  else { Add-DbkCheck 'ESP 上当前没有 \EFI\Microsoft\(bcdboot 会新建)' }
} else { Add-DbkCheck ('需人工留意:' + $mp + ' 当前不可见(未挂载);-Check 不挂载,故不断言 \EFI\Microsoft\ 是否存在;-Apply 会先 mountvol ' + $mp + ' /s') }
Add-DbkCheck ('{bootmgr} 的 path 现值:' + $bmPre)
Add-DbkCheck ('BootOrder 首位现值:' + $firstPre + ' ' + $descPre)
Add-DbkAction ('mountvol ' + $mp + ' /s(挂载 Windows ESP)')
Add-DbkAction ('bcdboot ' + $winDir + ' /s ' + $mp + ' /f UEFI(重建 \EFI\Microsoft\Boot\bootmgfw.efi 与 BCD)')
Add-DbkAction 'bcdedit /enum {bootmgr} 与 /enum firmware:复读 path 与 BootOrder 首位,断言与执行前逐字一致'
Add-DbkAction ('mountvol ' + $mp + ' /d(收尾必卸载,失败也卸载)')
if (-not $firstIsWbm) {
  Add-DbkCheck ('失败项:BootOrder 首位是 ' + $firstPre + ' ' + $descPre + ',不是 Windows Boot Manager(I1)')
  Write-DbkExit -Status FAIL -Message ('引导未修好前 BootOrder 首位必须仍是 Windows Boot Manager;当前首位是 ' + $firstPre + ' ' + $descPre + '。先在固件设置界面把它改回首位(本脚本不代改 BootOrder),再重跑本步(本次零写)')
}
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 未挂载、未写盘(零写);确认 {bootmgr} 的 path 与 BootOrder 首位无误后,加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('前置断言全部满足;-Check 零写。将 mountvol ' + $mp + ' /s -> bcdboot ' + $winDir + ' /s ' + $mp + ' /f UEFI -> 复读 {bootmgr} path(现值 ' + $bmPre + ')与 BootOrder 首位(现值 ' + $firstPre + ')未变 -> mountvol ' + $mp + ' /d')
}
$bad = @(); $mounted = $false; $boom = $false
try {
  $r1 = Invoke-DbkExe $mountvol @($mp, '/s')
  Write-DbkNote ('mountvol ' + $mp + ' /s 退出码 ' + $r1.Code + ';输出:' + ($r1.Out -replace "`r?`n", ' | '))
  Write-DbkLog ('mountvol ' + $mp + ' /s 退出码 ' + $r1.Code + ';输出:' + ($r1.Out -replace "`r?`n", ' | '))
  if ($r1.Code -ne 0) { throw ('mountvol ' + $mp + ' /s 失败(退出码 ' + $r1.Code + '):' + $r1.Out) }
  $mounted = $true
  if (-not (Test-Path -LiteralPath ($probe + 'EFI'))) { throw ('挂载 ' + $mp + ' 后看不到 ' + $probe + 'EFI,可能不是 ESP;已中止,未执行 bcdboot') }
  Add-DbkAction ('ESP 已挂载:' + $mp)
  $r2 = Invoke-DbkExe $bcdboot @($winDir, '/s', $mp, '/f', 'UEFI')
  Write-DbkNote ('bcdboot 输出(退出码 ' + $r2.Code + '):' + ($r2.Out -replace "`r?`n", ' | '))
  Write-DbkLog ('bcdboot ' + $winDir + ' /s ' + $mp + ' /f UEFI 退出码 ' + $r2.Code + ';输出:' + ($r2.Out -replace "`r?`n", ' | '))
  Add-DbkAction ('bcdboot ' + $winDir + ' /s ' + $mp + ' /f UEFI(退出码 ' + $r2.Code + ')')
  if ($r2.Code -ne 0) { $bad += ('bcdboot 失败(退出码 ' + $r2.Code + '):' + $r2.Out) }
  else {
    foreach ($rel in @('EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Microsoft\Boot\BCD')) {
      if (Test-Path -LiteralPath ($probe + $rel)) { Add-DbkCheck ('复读通过:' + $probe + $rel + ' 存在') }
      else { $bad += ('复读失败:' + $probe + $rel + ' 不存在(bcdboot 没有建成预期文件)') }
    }
    $bmPost = (Get-DbkFwInfo (Invoke-DbkExe $bcdedit @('/enum', '{bootmgr}')).Out).Path
    $fwPost = Get-DbkFwInfo (Invoke-DbkExe $bcdedit @('/enum', 'firmware')).Out
    $orderPost = @($fwPost.Order); $firstPost = ''
    if ($orderPost.Count -gt 0) { $firstPost = $orderPost[0] }
    if ($bmPost -ne $bmPre) { $bad += ('复读失败:{bootmgr} 的 path 被执行前后改了(执行前 ' + $bmPre + ';执行后 ' + $bmPost + ')') }
    if ($firstPost -ne $firstPre) { $bad += ('复读失败:BootOrder 首位被执行前后改了(执行前 ' + $firstPre + ';执行后 ' + $firstPost + ')') }
    if (@($bad).Count -eq 0) { Add-DbkCheck ('复读通过:{bootmgr} 的 path(' + $bmPre + ')与 BootOrder 首位(' + $firstPre + ')均与执行前逐字一致') }
  }
} catch {
  Enable-DbkErrTrap
  Write-DbkErrTrap -Reason ('repair-windows-boot 执行中断:' + $_.Exception.Message)
  $boom = $true
} finally {
  if ($mounted) {
    $rd = Invoke-DbkExe $mountvol @($mp, '/d')
    Write-DbkNote ('mountvol ' + $mp + ' /d 退出码 ' + $rd.Code + ';输出:' + ($rd.Out -replace "`r?`n", ' | '))
    Write-DbkLog ('mountvol ' + $mp + ' /d 退出码 ' + $rd.Code)
  }
}
if ($boom) { exit $script:DBK_FAIL }
if (@($bad).Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('bcdboot 已执行但后置断言不符(' + @($bad).Count + ' 项,见 checks);{bootmgr} 的 path 与 BootOrder 首位必须与执行前逐字一致,不得由本步改动。ESP 已卸载,处置见 docs/07-rescue.md 的 07-3')
}
Set-DbkChanged
Write-DbkExit -Status PASS -Message ('\EFI\Microsoft\ 已在 ESP(' + $mp + ')上重建(bootmgfw.efi 与 BCD 都在);{bootmgr} 的 path(' + $bmPre + ')与 BootOrder 首位(' + $firstPre + ')执行前后逐字一致;ESP 已卸载')
