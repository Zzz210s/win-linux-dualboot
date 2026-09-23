#Requires -Version 5.1
# 对应卡:04-1
# 破坏性:1
<#
.SYNOPSIS
  设置"下次启动进 Kubuntu / 进安装 U 盘"的**一次性**固件启动条目(BootNext 语义),并断言 BootOrder 未被改动。
.DESCRIPTION
  机制:`bcdedit /set {fwbootmgr} bootsequence {GUID}` 把某固件条目排到**下一次启动**,用过即自动消失,不改动 BootOrder(I2)。
  纪律:绝不执行 `bcdedit /set {fwbootmgr} displayorder ...` 之类的改序操作(I2),也绝不改 `{bootmgr}` 的 `path`(I3);
  执行后必须重新枚举固件条目,断言 BootOrder **逐字未变**且首位仍是 Windows Boot Manager(I1)。
  CLI 契约(设计 03 第 2 节):-Check 是**缺省**且只读;-Apply 才执行。本脚本改的是固件启动项,脚本头声明了「# 破坏性:1」,
  所以 -Apply 必须同时给 -Yes,缺 -Yes 由库层直接退 64 且**零写**。`-WhatIf` 保留(手册与 FAQ 里的既有写法),
  语义 = -Check(只打印将执行的命令,零写);-WhatIf 与 -Apply 同时给视为用法错误 64。
  目标选择:默认按 -Match 正则匹配固件条目的 description/描述(默认 'ubuntu|kubuntu|grub');-Guid <{GUID}> 显式指定;
  -Device USB 改按可移动介质特征匹配(描述含 USB/UEFI:/Removable,或 loader 路径为 \EFI\BOOT\)。
  匹配到多条时打印清单并非零退出(绝不能随便取第一条:失效 GUID 会把重启落到 grub rescue>)。
  -Check 判定:目标条目存在且可设 -> 0;找不到目标 / 固件不支持(枚举不出固件条目)-> 1;
  读不到(非管理员会话,需人工重开管理员会话)-> 2;参数非法 -> 64(-Device 非 USB、-Guid 是容器伪条目、
  -Check 与 -Apply 互斥、-WhatIf 与 -Apply 互斥、-Apply 缺 -Yes、-Step 不在卡号集合)。
  夹具钩子(仅离线验证,真机留空):DBK_FW_TEXT / DBK_FW_TEXT_AFTER(替代 bcdedit /enum firmware 的前/后文本)、
  DBK_BM_TEXT / DBK_BM_TEXT_AFTER(替代 /enum {bootmgr} 的前/后文本)、DBK_BCEDIT_EXE(假 bcdedit,记录 /set 调用)、
  DBK_IS_ADMIN=1/0(强制管理员判定)、DBK_CALLS(假 exe 记录调用行的文件)。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:bcdedit /set {fwbootmgr} bootsequence <GUID>。
  本文件必须保存为 UTF-8 with BOM(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码,中文会解析失败)。
  固件枚举/解析与后置断言在库 scripts/windows/dbk-win-probe.ps1 里(本脚本只做目标选择与写动作)。
  用法(仓库根目录、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1                  # -Check(缺省):只看计划
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1 -Apply -Yes      # 真正设置(一次性进 Kubuntu)
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1 -Device USB -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1 -Device USB -Apply -Yes   # 卡 04-1:一次性从安装 U 盘启动
  退出码:0 通过 / 1 失败(找不到目标、条目歧义、-Guid 不存在、bcdedit /set 失败、后置复读不符)/ 2 需人工(非管理员)
    / 9 跳过(非 Windows) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes, [switch]$WhatIf,
  [string]$Match = 'ubuntu|kubuntu|grub', [string]$Guid = '', [string]$Device = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
$srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $srcDir 'dbk-cli.ps1')
# 固件/BCD 枚举与断言的共享实现(库文件;本脚本只做目标选择与写动作)。
. (Join-Path $srcDir 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($WhatIf -and $script:DbkMode -eq 'apply') {
  Show-DbkUsage
  Write-DbkNote '用法错误: -WhatIf(等价 -Check,只打印计划)与 -Apply 互斥,只能给一个'
  exit $script:DBK_USAGE
}
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\set-bootnext.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'set-bootnext' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
$FWBM = '{fwbootmgr}'
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;固件枚举与 bootsequence 都要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:bcdedit 读固件条目与 bootsequence 都要求管理员,本步既无法判定也无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
# 参数校验:-Device 只认 USB(其余按用法错误 64,不静默忽略)
$pathMatch = ''
if ($Device) {
  if ($Device -ne 'USB') {
    Show-DbkUsage
    Write-DbkNote ('用法错误: -Device 只认 USB(实为 ''' + $Device + ''');一次性进 Kubuntu 用默认的 -Match/-Guid,不要用 -Device。本次未执行任何命令。')
    exit $script:DBK_USAGE
  }
  if (-not $PSBoundParameters.ContainsKey('Match')) { $Match = 'USB|UEFI:|Removable' }
  $pathMatch = '\\EFI\\BOOT\\'
}
if ($Device -eq 'USB') { Write-DbkNote 'set-bootnext:设置一次性固件启动条目从**安装 U 盘**启动(BootNext 语义;本脚本不改动 BootOrder)' }
else { Write-DbkNote 'set-bootnext:设置一次性固件启动条目进 Kubuntu(BootNext 语义;本脚本不改动 BootOrder)' }
if ($script:DbkMode -eq 'apply') { Write-DbkNote '运行模式:-Apply(会调用 bcdedit /set {fwbootmgr} bootsequence)' }
elseif ($WhatIf) { Write-DbkNote '运行模式:-WhatIf(等价 -Check:只打印计划,零写)' }
else { Write-DbkNote '运行模式:-Check(缺省:只读判定,零写)' }
Write-DbkNote ('目标匹配正则:-Match ''' + $Match + '''(匹配固件条目的 description/描述)')
if ($Device -eq 'USB') { Write-DbkNote ('附加匹配:loader 路径 /' + $pathMatch + '/(可移动介质)') }
$fw0 = Get-DbkFwEnum -What firmware -Exe $script:DbkBcd
if (-not $fw0) {
  Write-DbkExit -Status FAIL -Message '读不到固件启动条目(bcdedit /enum firmware 失败):固件不支持 UEFI 固件条目枚举,或系统以 Legacy/BIOS 方式启动;兜底路径:开机按厂商启动菜单键(BOOT_MENU_KEY)一次性选目标条目;本次零写'
}
$fi0 = Get-DbkFwInfo -Text $fw0
$order0 = @($fi0.Order)
$ent = @(Get-DbkFwEntries -Text $fw0)
if ($order0.Count -gt 0) {
  $d0 = ''; if ($fi0.Desc.ContainsKey($order0[0])) { $d0 = [string]$fi0.Desc[$order0[0]] }
  Write-DbkNote ('当前 BootOrder 首位:' + $order0[0] + '(' + $d0 + ')')
}
# 先收集**全部**匹配:多条时绝不能静默取第一条(残留旧条目的 GUID 可能已失效)
$hits = @($ent | Where-Object {
  if ($_.Guid -eq $FWBM -or $_.Guid -eq '{bootmgr}') { return $false }
  $okDesc = ($_.Desc -and ($_.Desc -match $Match))
  $okPath = ($pathMatch -and $_.Path -and ($_.Path -match $pathMatch))
  return [bool]($okDesc -or $okPath)
})
$target = $null
if ($Guid) {
  # 显式拒绝容器伪条目:{fwbootmgr}/{bootmgr} 不是可引导的固件条目,落到 bootsequence 会绕过下面的"排除 Windows 自身"保护
  if ($Guid -eq $FWBM -or $Guid -eq '{bootmgr}') {
    Show-DbkUsage
    Write-DbkNote ('用法错误: -Guid ' + $Guid + ' 是容器伪条目({fwbootmgr} = 固件启动管理器,{bootmgr} = Windows 启动管理器),不是可引导的固件条目,拒绝使用。')
    Write-DbkNote '要重建 Windows 引导条目请走 docs/07-rescue.md 的 bcdboot 路径;本脚本只负责一次性切换。本次未执行任何命令。'
    exit $script:DBK_USAGE
  }
  $target = @($ent | Where-Object { $_.Guid -eq $Guid }) | Select-Object -First 1
  if (-not $target) {
    Write-DbkNote ('找不到目标:-Guid 指定的条目 ' + $Guid + ' 在固件条目里不存在。现有条目:')
    foreach ($e in $ent) { Write-DbkNote ('  ' + $e.Guid + '  ' + $e.Desc) }
    Write-DbkExit -Status FAIL -Message ('-Guid ' + $Guid + ' 在固件条目里不存在(共枚举到 ' + $ent.Count + ' 条);核对 GUID,或去掉 -Guid 让脚本按 -Match 自动匹配;本次零写')
  }
} elseif ($hits.Count -gt 1) {
  Write-DbkNote ('找不到唯一目标:description 匹配 /' + $Match + '/ 的固件条目有 ' + $hits.Count + ' 条,无法自动确定。')
  Write-DbkNote '匹配到的条目(重装/换 ESP 后常会留下失效的旧条目,选错会把下次启动落到 grub rescue>):'
  foreach ($e in $hits) { Write-DbkNote ('  ' + $e.Guid + '  ' + $e.Desc + '  路径:' + $e.Path) }
  Write-DbkExit -Status FAIL -Message ('匹配到 ' + $hits.Count + ' 条候选,无法自动确定目标:核对哪一条是当前有效的目标条目(对照 BootOrder 里的 GUID 与路径),用 -Guid <{GUID}> 显式指定后重跑;本次零写')
} elseif ($hits.Count -eq 1) { $target = $hits[0] }
if (-not $target) {
  Write-DbkNote ('找不到目标:没有 description 匹配 /' + $Match + '/ 的固件条目。现有条目:')
  foreach ($e in $ent) { Write-DbkNote ('  ' + $e.Guid + '  ' + $e.Desc) }
  if ($Device -eq 'USB') { Write-DbkNote '兜底路径:开机按厂商启动菜单键(BOOT_MENU_KEY)一次性选带 UEFI: 前缀的 U 盘条目;仍看不到就回 docs/01-firmware.md 核对介质与固件设置。' }
  else { Write-DbkNote '兜底路径:开机按厂商启动菜单键(BOOT_MENU_KEY)一次性选 ubuntu;若条目确实缺失,按 docs/04-kubuntu.md 出错时一节重建条目。' }
  Write-DbkExit -Status FAIL -Message ('固件条目里没有匹配 /' + $Match + '/ 的目标(共枚举到 ' + $ent.Count + ' 条);本脚本未执行任何命令(零写)')
}
$cmd = ('bcdedit /set {fwbootmgr} bootsequence ' + $target.Guid)
Write-DbkNote ('目标条目:' + $target.Desc + '  ' + $target.Guid + '  路径:' + $target.Path)
Write-DbkNote ('将执行(待核实(以官方文档为准)):' + $cmd)
Write-DbkNote '说明:bootsequence 只在下次启动生效、用后自动消失,不构成对 BootOrder 的改动(I2)。'
Write-DbkNote '本脚本绝不执行 bcdedit /set {fwbootmgr} displayorder ... 或任何改序操作(I2),也绝不改 {bootmgr} 的 path(I3)。'
Add-DbkCheck ('目标固件条目:' + $target.Guid + '(' + $target.Desc + ')')
Add-DbkAction $cmd
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:未执行任何命令;确认后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('目标条目存在且可设:' + $target.Guid + '(' + $target.Desc + ');-Check 零写,将执行 ' + $cmd)
}
$bm0 = (Get-DbkFwInfo -Text (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd)).Path
if (-not $bm0) { Write-DbkNote '提示:读不到 {bootmgr} 的 path,后置断言只能核对 BootOrder(仍会核对逐字未变与首位仍是 Windows Boot Manager)。' }
$r = Invoke-DbkProbeExe -Exe $script:DbkBcd -CmdArgs @('/set', '{fwbootmgr}', 'bootsequence', $target.Guid)
Write-DbkNote ('bcdedit /set 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
Write-DbkLog ('bcdedit /set {fwbootmgr} bootsequence ' + $target.Guid + ' 退出码 ' + $r.Code)
if ($r.Code -ne 0) {
  Add-DbkCheck ('失败项:bcdedit /set {fwbootmgr} bootsequence 失败(退出码 ' + $r.Code + '):' + $r.Out)
  Write-DbkExit -Status FAIL -Message ('设置一次性启动条目失败(退出码 ' + $r.Code + '):' + $r.Out + ';BootOrder 未被本脚本改动,可在管理员会话重试')
}
Set-DbkChanged
Write-DbkNote '已设置一次性启动条目;下面重新枚举固件条目并断言 I1/I2/I3。'
$bad = @(Assert-DbkFwPost -BmPath $bm0 -Order $order0 -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if ($bad.Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('已设置一次性 bootsequence(' + $target.Guid + '),但后置复读不符(' + $bad.Count + ' 项,见 checks 与上面的复读值);处置:只在固件设置界面把 Windows Boot Manager 改回首位,并把偏差写进 L4 记录;不得用 bcdedit displayorder 或 efibootmgr -o 改序(I2)')
}
Write-DbkExit -Status PASS -Message ('已设置一次性 bootsequence(' + $target.Guid + ' ' + $target.Desc + '):下次启动从该条目走;BootOrder 逐字未变、首位仍是 Windows Boot Manager(I1)、{bootmgr} path 未变(I3);一次性条目用后自动消失')
