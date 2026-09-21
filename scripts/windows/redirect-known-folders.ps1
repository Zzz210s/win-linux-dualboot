#Requires -Version 5.1
# 对应卡:03-3
# 破坏性:1
<#
.SYNOPSIS
  轨道 W:系统盘隔离——六个已知文件夹重定向到 D:,并建 D:\Shared\。缺省 -Check 只读比对;-Apply(需 -Yes)才写。
.DESCRIPTION
  重定向清单(值表真源 = 03-windows.md 的 03-3;Windows 侧的隐含约定,定下后不再改名,见 design 4.2):
    Desktop -> D:\Desktop;Personal(文档)-> D:\Documents;{374DE290-123F-4565-9164-39C4925E467B}(下载)-> D:\Downloads;
    My Pictures -> D:\Pictures;My Video -> D:\Videos;My Music -> D:\Music;另建办公约定目录 D:\Shared\。
  判据:六个值都等于目标路径(读 HKCU\...\Explorer\User Shell Folders),且 D:\Shared\ 目录存在。
  只写边界:只改这六个注册表值与建 D:\ 下的目标目录;**不搬整个用户配置文件**、不动 ProfileList、不动 AppData 类值。
  幂等:已是目标值时 -Apply 不写该值。不做回滚(要回退按 03-3 的出错时:去向人工改回 C:\Users\<用户名>\ 并更新 L1 产物)。
  退出码:0 通过 / 1 失败(有值不符或 D:\Shared\ 缺失) / 64 用法错误。
  夹具钩子(仅离线验证,真机留空):
    DBK_USF_STORE=<文件> 时,读写改用该文件(每行 name=value),不碰注册表;
    DBK_USF_DROOT=<目录> 覆盖 D 盘根(缺省 D:\),夹具用它把目标落在临时目录。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法:
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\redirect-known-folders.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\redirect-known-folders.ps1 -Apply -Yes
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$DRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'redirect-known-folders' }

$USF_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
if (-not $DRoot) {
  if ($env:DBK_USF_DROOT) { $DRoot = $env:DBK_USF_DROOT } else { $DRoot = 'D:\' }
}
if (-not ($DRoot -match '\\$')) { $DRoot = $DRoot + '\' }
$StorePath = $env:DBK_USF_STORE

# 清单(顺序 = 值表顺序):注册表值名 -> D: 下的目录名
$MAP = [ordered]@{
  'Desktop'                                  = 'Desktop'
  'Personal'                                 = 'Documents'
  '{374DE290-123F-4565-9164-39C4925E467B}'   = 'Downloads'
  'My Pictures'                              = 'Pictures'
  'My Video'                                 = 'Videos'
  'My Music'                                 = 'Music'
}
$SHARED = 'Shared'

function Read-Store {
  $o = @{}
  if (-not $StorePath) { return $o }
  if (-not (Test-Path -LiteralPath $StorePath)) { return $o }
  foreach ($line in [System.IO.File]::ReadAllLines($StorePath, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*(.+?)\s*=\s*(.*)$') { $o[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  return $o
}
function Get-UsfValue {
  param([string]$Name, $Store)
  if ($StorePath) { if ($Store.ContainsKey($Name)) { return [string]$Store[$Name] } return '' }
  try { return [string]((Get-ItemProperty -Path $USF_KEY -Name $Name -ErrorAction Stop).$Name) } catch { return '' }
}
function Set-UsfValue {
  param([string]$Name, [string]$Value)
  if ($StorePath) {
    $usf = Read-Store
    $usf[$Name] = $Value
    $lines = @()
    foreach ($k in @($usf.Keys)) { $lines += ($k + '=' + $usf[$k]) }
    [System.IO.File]::WriteAllText($StorePath, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return
  }
  if (-not (Test-Path -LiteralPath $USF_KEY)) { New-Item -Path $USF_KEY -Force | Out-Null }
  Set-ItemProperty -Path $USF_KEY -Name $Name -Value $Value -Type ExpandString -Force
}

$usf = Read-Store
$bad = @()
Add-DbkCheck ('读取来源:' + $(if ($StorePath) { '夹具存储 ' + $StorePath } else { '注册表 ' + $USF_KEY }))
foreach ($name in @($MAP.Keys)) {
  $target = $DRoot + $MAP[$name]
  $cur = Get-UsfValue -Name $name -Store $usf
  $ok = ($cur.TrimEnd('\') -ieq $target.TrimEnd('\'))
  if ($ok) { Add-DbkCheck ($name + ' = ' + $cur + '(目标 ' + $target + ')') }
  else { $bad += $name; Add-DbkCheck ('失败项:' + $name + ' 实测 ' + $(if ($cur) { $cur } else { '(空)' }) + ',目标 ' + $target) }
}
$sharedPath = $DRoot + $SHARED
$sharedOk = Test-Path -LiteralPath $sharedPath
if ($sharedOk) { Add-DbkCheck ('办公约定目录已存在:' + $sharedPath) }
else { $bad += $SHARED; Add-DbkCheck ('失败项:办公约定目录不存在:' + $sharedPath) }

if ($script:DbkMode -eq 'check') {
  if ($bad.Count -eq 0) {
    Write-DbkExit -Status PASS -Message '六个已知文件夹均已重定向到 D:,且 D:\Shared\ 已建'
  }
  Write-DbkExit -Status FAIL -Message ('有 ' + $bad.Count + ' 项未达标(' + ($bad -join '、') + ');加 -Apply -Yes 由本脚本重定向,或按 03-3 的做:用资源管理器逐项移动')
}

# -Apply:先过 -Yes(会改注册表与建目录)
$CMDS = @()
foreach ($name in @($MAP.Keys)) { $CMDS += ('reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "' + $name + '" /t REG_EXPAND_SZ /d "' + ($DRoot + $MAP[$name]) + '" /f') }
$CMDS += ('mkdir "' + $sharedPath + '"')
Assert-DbkYes -Description ('重定向六个已知文件夹到 ' + $DRoot + ' 并建 ' + $sharedPath + '(只改这六项注册表值与目标目录,不搬用户配置文件)') -Commands $CMDS

$changed = 0
foreach ($name in @($MAP.Keys)) {
  $target = $DRoot + $MAP[$name]
  $cur = Get-UsfValue -Name $name -Store $usf
  $dir = $target
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Add-DbkAction ('已建目录:' + $dir)
  }
  if ($cur.TrimEnd('\') -ieq $target.TrimEnd('\')) { Add-DbkAction ($name + ' 已是目标值,跳过(幂等)'); continue }
  Set-UsfValue -Name $name -Value $target
  $script:DbkChanged = $true; $changed++
  Add-DbkAction ('已写入:' + $name + ' = ' + $target)
}
if (-not $sharedOk) {
  New-Item -ItemType Directory -Path $sharedPath -Force | Out-Null
  $script:DbkChanged = $true
  Add-DbkAction ('已建目录:' + $sharedPath)
}
if ($StorePath) {
  Add-DbkCheck '夹具模式(DBK_USF_STORE):读写落在该文件,未碰注册表'
  Write-DbkExit -Status PASS -Message ('夹具模式:已写 ' + $changed + ' 项到 ' + $StorePath)
}
$usf2 = Read-Store
$bad2 = @()
foreach ($name in @($MAP.Keys)) {
  $target = $DRoot + $MAP[$name]
  if ((Get-UsfValue -Name $name -Store $usf2).TrimEnd('\') -ine $target.TrimEnd('\')) { $bad2 += $name }
}
if (-not (Test-Path -LiteralPath $sharedPath)) { $bad2 += $SHARED }
if ($bad2.Count -eq 0) {
  Add-DbkAction '重启资源管理器(或注销重登)后新值才在所有程序里生效'
  Write-DbkExit -Status PASS -Message ('六个已知文件夹已重定向到 ' + $DRoot + '(本次写入 ' + $changed + ' 项),' + $sharedPath + ' 已建')
}
Write-DbkExit -Status FAIL -Message ('写入后仍有 ' + $bad2.Count + ' 项未达标(' + ($bad2 -join '、') + ');核对是否有组策略/漫游配置文件把它们改回')
