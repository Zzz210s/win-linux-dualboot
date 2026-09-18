#Requires -Version 5.1
<#
.SYNOPSIS
  L4:设置"下次启动进 Ubuntu"的**一次性**固件启动条目(BootNext 语义),并断言 BootOrder 未被改动。
.DESCRIPTION
  机制:`bcdedit /set {fwbootmgr} bootsequence {GUID}` 把某固件条目排到**下一次启动**,
  用过即自动消失,不改动 BootOrder —— 这正是设计文档不变量 I2 要求的"一次性启动"。
  纪律(设计文档第 2 节):
    I2:本脚本**绝不**执行 `bcdedit /set {fwbootmgr} displayorder ...` 之类的改序操作;
    I1:执行后必须重新枚举固件条目,断言 BootOrder 首位仍是 Windows Boot Manager,否则报错退出。
  本文件必须保存为 UTF-8 with BOM(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码,中文会解析失败)。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1 -WhatIf   # 只看计划,不改系统
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1            # 真正设置
  参数 -Match 是匹配 Ubuntu 条目的描述正则(默认 'ubuntu|grub');描述行在中文系统上可能是中文标签,故解析做了双语匹配。
  若匹配到**多条**(重装或换 ESP 后残留旧 ubuntu 条目的常见情形),脚本打印 GUID + description 清单并以非零退出;
  核对出当前有效的那条后用 -Guid <{GUID}> 显式指定重跑(绝不能随便取第一条:失效 GUID 会直接把重启落到 grub rescue>)。
  退出码:0 = 计划打印完成(-WhatIf 下"未找到目标条目"也只打印计划并返回 0),或设置成功且 I1 断言通过;1 = 失败(含条目歧义、非 -WhatIf 下未找到目标条目、-Guid 指向容器伪条目与 I1 断言失败)。
#>
[CmdletBinding()]
param(
  [switch]$WhatIf,
  [string]$Match = 'ubuntu|grub',
  [string]$Guid = ''
)

$ErrorActionPreference = 'Stop'
$WBM = 'Windows Boot Manager|Windows 启动管理器'
$FWBM = '{fwbootmgr}'

function Get-FirmwareText {
  # 只读枚举:失败(非管理员 / 非 UEFI / 无 bcdedit)一律返回 $null,由调用方给中文提示
  $out = $null
  try { $out = (& bcdedit /enum firmware 2>&1 | Out-String) } catch { return $null }
  if ($LASTEXITCODE -ne 0) { return $null }
  if (-not $out -or $out.Trim().Length -eq 0) { return $null }
  if ($out -match '拒绝访问|Access is denied') { return $null }
  return $out
}

function Get-FirmwareEntries {
  # 按 `identifier {GUID}` 切块,块内取 description;字段名做双语匹配
  param([string]$Text)
  $entries = @(); $cur = $null
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') {
      if ($cur) { $entries += $cur }
      $cur = [pscustomobject]@{ Guid = $Matches[2]; Desc = ''; Path = '' }
      continue
    }
    if ($null -eq $cur) { continue }
    if ($line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { if (-not $cur.Desc) { $cur.Desc = $Matches[2] } continue }
    if ($line -match '^\s*(path|路径)\s+(\S.*?)\s*$') { if (-not $cur.Path) { $cur.Path = $Matches[2] } }
  }
  if ($cur) { $entries += $cur }
  return $entries
}

function Get-BootOrderGuids {
  # displayorder 的值可能跨行;取第一行与后续"只含 GUID"的续行,遇到非 GUID 行即结束
  param([string]$Text)
  $guids = @(); $inOrder = $false
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*(displayorder|显示顺序|启动顺序)\s*(.*)$') {
      $inOrder = $true
      foreach ($g in [regex]::Matches($Matches[2], '\{[^}]+\}')) { $guids += $g.Value }
      continue
    }
    if ($inOrder) {
      if ($line.Trim().Length -eq 0) { $inOrder = $false; continue }
      $gs = @([regex]::Matches($line, '\{[^}]+\}'))
      if ($gs.Count -eq 0) { $inOrder = $false; continue }
      foreach ($g in $gs) { $guids += $g.Value }
    }
  }
  return $guids
}

function Get-EntryDesc {
  param([string]$Guid, $Entries)
  foreach ($e in $Entries) { if ($e.Guid -eq $Guid) { return $e.Desc } }
  return ''
}

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false }

Write-Host 'set-bootnext:设置一次性固件启动条目进 Ubuntu(BootNext 语义;本脚本不改动 BootOrder)'
if ($WhatIf) { Write-Host '运行模式:空跑(-WhatIf),只打印计划,不执行任何命令' } else { Write-Host '运行模式:执行(会调用 bcdedit /set {fwbootmgr} bootsequence)' }
if ($isAdmin) { Write-Host '管理员权限:是' } else { Write-Host '管理员权限:否(读不到固件条目;真正设置必须用管理员会话)' }
Write-Host ('目标匹配正则:-Match ''' + $Match + '''(匹配固件条目的 description/描述)')

$fw = Get-FirmwareText
$entries = @(); $order = @()
if ($fw) {
  $entries = @(Get-FirmwareEntries $fw)
  $order = @(Get-BootOrderGuids $fw)
  if ($order.Count -gt 0) { Write-Host ('当前 BootOrder 首位:' + $order[0] + '(' + (Get-EntryDesc $order[0] $entries) + ')') }
}
$target = $null
# 先收集**全部**匹配:多条时绝不能静默取第一条(残留旧 ubuntu 条目的 GUID 可能已失效)
$hits = @($entries | Where-Object { $_.Guid -ne $FWBM -and $_.Desc -and $_.Desc -match $Match })
if ($Guid) {
  # 显式拒绝容器伪条目:{fwbootmgr}/{bootmgr} 不是可引导的固件条目,落到 bootsequence 会绕过下面的"排除 Windows 自身"保护
  if ($Guid -eq $FWBM -or $Guid -eq '{bootmgr}') {
    Write-Host ('错误:-Guid ' + $Guid + ' 是容器伪条目({fwbootmgr} = 固件启动管理器,{bootmgr} = Windows 启动管理器),不是可引导的固件条目,拒绝使用。')
    Write-Host '要重建 Windows 引导条目请走 docs/07-rescue.md 的 bcdboot 路径;本脚本只负责一次性进 Ubuntu。本次未执行任何命令。'
    exit 1
  }
  $target = @($hits | Where-Object { $_.Guid -eq $Guid }) | Select-Object -First 1
  if (-not $target) { $target = @($entries | Where-Object { $_.Guid -eq $Guid }) | Select-Object -First 1 }
  if (-not $target) {
    Write-Host ('错误:-Guid 指定的条目 ' + $Guid + ' 在固件条目里不存在。现有条目:')
    foreach ($e in $entries) { Write-Host ('  ' + $e.Guid + '  ' + $e.Desc) }
    Write-Host '本次未执行任何命令;请核对 GUID,或去掉 -Guid 让脚本按 -Match 自动匹配。'
    exit 1
  }
} elseif ($hits.Count -gt 1) {
  Write-Host ('错误:description 匹配 /' + $Match + '/ 的固件条目有 ' + $hits.Count + ' 条,无法自动确定目标。')
  Write-Host '匹配到的条目(重装/换 ESP 后常会留下失效的旧 ubuntu 条目,选错会把下次启动落到 grub rescue>):'
  foreach ($e in $hits) { Write-Host ('  ' + $e.Guid + '  ' + $e.Desc + '  路径:' + $e.Path) }
  Write-Host '处置:核对哪一条是当前有效的 Ubuntu 条目(可对照上面 BootOrder 里的 GUID 与路径),用 -Guid <{GUID}> 显式指定后重跑;本次未执行任何命令。'
  exit 1
} elseif ($hits.Count -eq 1) { $target = $hits[0] }

$cmd = 'bcdedit /set {fwbootmgr} bootsequence <目标条目 GUID>'
if ($target) { $cmd = ('bcdedit /set {fwbootmgr} bootsequence ' + $target.Guid) }

if (-not $target) {
  if (-not $fw) {
    Write-Host '提示:读不到固件启动条目(bcdedit /enum firmware 失败)。常见原因:当前不是管理员会话,或系统以 Legacy/BIOS 方式启动(非 UEFI)。'
  } else {
    Write-Host ('未找到 description 匹配 /' + $Match + '/ 的固件条目。现有条目:')
    foreach ($e in $entries) { Write-Host ('  ' + $e.Guid + '  ' + $e.Desc) }
    Write-Host '兜底路径:开机按厂商启动菜单键(BOOT_MENU_KEY)一次性选 ubuntu;若 ubuntu 条目确实缺失,按 docs/04-ubuntu.md 失败处理一节重建条目。'
  }
  Write-Host ('计划(条目未解析成功,命令里的 GUID 需替换后再手工执行):' + $cmd)
  Write-Host '本脚本绝不改动 BootOrder(I2):不执行 displayorder 之类的改序操作。'
  if ($WhatIf) { Write-Host '(-WhatIf:只打印计划,未执行任何命令;退出码 0)'; exit 0 }
  Write-Host '错误:无法确定目标固件条目,未执行任何命令。'
  exit 1
}

Write-Host ('目标条目:' + $target.Desc + '  ' + $target.Guid + '  路径:' + $target.Path)
Write-Host ('将执行:' + $cmd)
Write-Host '说明:bootsequence 只在下次启动生效、用后自动消失,不构成对 BootOrder 的改动(I2)。'
Write-Host '本脚本绝不执行 bcdedit /set {fwbootmgr} displayorder ... 或任何改序操作(I2)。'
if ($WhatIf) { Write-Host '(-WhatIf:只打印计划,未执行任何命令;退出码 0)'; exit 0 }

$out = ''
$rc = 1
try { $out = (& bcdedit /set '{fwbootmgr}' bootsequence $target.Guid 2>&1 | Out-String); $rc = $LASTEXITCODE } catch { $out = $_.Exception.Message; $rc = 1 }
if ($rc -ne 0) { Write-Host ('错误:设置一次性启动条目失败:' + ($out -replace "`r?`n", ' ').Trim()); exit 1 }
Write-Host '已设置一次性启动条目;下面重新枚举固件条目并断言 I1。'

$fw2 = Get-FirmwareText
if (-not $fw2) {
  Write-Host '错误:设置后无法重新枚举固件条目,I1 断言无法完成;请手工执行 bcdedit /enum firmware 核对 BootOrder 首位仍是 Windows Boot Manager。'
  exit 1
}
$entries2 = @(Get-FirmwareEntries $fw2)
$order2 = @(Get-BootOrderGuids $fw2)
if ($order2.Count -eq 0) { Write-Host '错误:重新枚举后解析不到 displayorder,无法完成 I1 断言。'; exit 1 }

$first = $order2[0]
$firstDesc = Get-EntryDesc $first $entries2
if ($first -eq '{bootmgr}' -or $firstDesc -match $WBM) {
  Write-Host ('I1 断言通过:BootOrder 首位仍是 Windows Boot Manager(' + $first + ' ' + $firstDesc + ')')
  if ($order.Count -gt 0 -and $order[0] -ne $first) { Write-Host ('提示:BootOrder 首位 GUID 与执行前不同(执行前 ' + $order[0] + ');条目可能被重建,请把该偏差写进 L4 记录。') }
  Write-Host '下一步:重启即进入 Ubuntu。一次性条目用后自动消失,重启后 BootOrder 仍以 Windows Boot Manager 为首位(I1)。'
  exit 0
}
Write-Host ('错误:I1 断言失败——BootOrder 首位变成了 ' + $first + ' ' + $firstDesc + '。')
Write-Host '处置(见 docs/04-ubuntu.md 失败处理):只在固件设置界面把 Windows Boot Manager 改回首位,并把偏差写进 L4 记录;不得用 bcdedit displayorder 或 efibootmgr -o 改序(I2)。'
exit 1
