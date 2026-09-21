#Requires -Version 5.1
# 对应卡:03-2
# 破坏性:1
<#
.SYNOPSIS
  轨道 W:关闭 Fast Startup(快速启动)与休眠。缺省 -Check 只读判定;-Apply(需 -Yes)执行 powercfg /h off 并把 HiberbootEnabled 显式置 0。
.DESCRIPTION
  判据(依据见 03-windows.md 的 03-2 与 design 5.3 前置条件第 1 条):
    1) 注册表 HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power 的 HiberbootEnabled = 0;
    2) hiberfil.sys 不存在(休眠已关)。
    两项都要成立:只删休眠文件而注册表值不为 0 时,快速启动仍可能在下次大版本更新后被打开。
  只读边界:-Check 零写(不落盘、不改注册表、不执行 powercfg);-Apply 才改系统,且动作前先过 -Yes 门槛。
  幂等:已是目标状态时 -Apply 不再改动任何东西(changed=false)。
  退出码:0 通过 / 1 失败(任一项未达标) / 64 用法错误(-Apply 缺 -Yes、-Check 与 -Apply 互斥等)。
  夹具钩子(仅离线验证,真机留空):
    DBK_FF_DUMP=<文件,每行 key=value:hibernateEnabled=0|1、hiberfilExists=0|1> 覆盖本机读数;
    DBK_FF_CMDS=<文件> 存在时,-Apply 不真执行 powercfg / reg,改为把将执行的命令逐行写进该文件(离线夹具)。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法:
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\disable-faststartup.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\disable-faststartup.ps1 -Apply -Yes
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'disable-faststartup' }

$POWER_KEY = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$HIBER = Join-Path ($env:SystemDrive + '\') 'hiberfil.sys'

# Get-FFState:夹具钩子优先;否则读注册表与 hiberfil.sys(只读,不改任何状态)。
function Get-FFState {
  $o = @{ HibernateEnabled = $null; HiberfilExists = $null; Source = '本机' }
  if ($env:DBK_FF_DUMP) {
    if (-not (Test-Path -LiteralPath $env:DBK_FF_DUMP)) {
      Write-DbkNote ('用法错误: DBK_FF_DUMP 指向的文件不存在: ' + $env:DBK_FF_DUMP); exit $script:DBK_USAGE
    }
    foreach ($line in [System.IO.File]::ReadAllLines($env:DBK_FF_DUMP, [System.Text.Encoding]::UTF8)) {
      if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
        $k = $Matches[1]; $val = $Matches[2].Trim()
        if ($k -match '^(?i)hibernateEnabled$') { $o.HibernateEnabled = $(if ($val -match '^(?i)(0|false|no)$') { '0' } else { '1' }) }
        if ($k -match '^(?i)hiberfilExists$') { $o.HiberfilExists = [bool]($val -match '^(?i)(1|true|yes)$') }
      }
    }
    $o.Source = '夹具(DBK_FF_DUMP)'
    return $o
  }
  try { $o.HibernateEnabled = [string]((Get-ItemProperty -Path $POWER_KEY -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled) }
  catch { $o.HibernateEnabled = $null }
  $o.HiberfilExists = (Test-Path -LiteralPath $HIBER)
  return $o
}

function Test-FFOk {
  param($State)
  if ($null -eq $State.HibernateEnabled) { return $false }
  if ([string]$State.HibernateEnabled -ne '0') { return $false }
  return (-not [bool]$State.HiberfilExists)
}

$st = Get-FFState
Add-DbkCheck ('读数来源:' + $st.Source)
if ($null -eq $st.HibernateEnabled) { Add-DbkCheck ('失败项:读不到 HiberbootEnabled(' + $POWER_KEY + ');请在管理员会话里重跑') }
else { Add-DbkCheck ('HiberbootEnabled = ' + [string]$st.HibernateEnabled + '(期望 0)') }
Add-DbkCheck ('休眠文件 hiberfil.sys:' + $(if ([bool]$st.HiberfilExists) { '存在(期望不存在)' } else { '不存在' }))

if ($script:DbkMode -eq 'check') {
  if (Test-FFOk -State $st) {
    Write-DbkExit -Status PASS -Message 'Fast Startup 与休眠均已关闭(HiberbootEnabled = 0 且无 hiberfil.sys);无需改动'
  }
  if ($null -eq $st.HibernateEnabled) {
    Write-DbkExit -Status FAIL -Message ('读不到 HiberbootEnabled;以管理员身份重开 Windows PowerShell 后重跑(键 ' + $POWER_KEY + ')')
  }
  Write-DbkExit -Status FAIL -Message ('Fast Startup 或休眠未关闭(HiberbootEnabled = ' + [string]$st.HibernateEnabled + ';hiberfil.sys ' + $(if ([bool]$st.HiberfilExists) { '存在' } else { '不存在' }) + ');加 -Apply -Yes 由本脚本关闭')
}

# -Apply:动作前先过 -Yes(本卡会改系统状态:删除休眠文件 + 改注册表)
if ($env:DBK_FF_DUMP -and -not $env:DBK_FF_CMDS) {
  Write-DbkNote '用法错误: 给了 DBK_FF_DUMP(夹具读数)却没给 DBK_FF_CMDS;-Apply 会在真机上执行 powercfg/reg,夹具下必须用 DBK_FF_CMDS 指定命令记录文件'
  exit $script:DBK_USAGE
}
$CMDS = @(
  'powercfg /h off',
  'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f'
)
if (Test-FFOk -State $st) {
  Add-DbkCheck '已是目标状态,本次不做任何改动(幂等)'
  Write-DbkExit -Status PASS -Message 'Fast Startup 与休眠已关闭,无需改动(幂等,零改动)'
}
Assert-DbkYes -Description '关闭休眠与快速启动:powercfg /h off 会删除 C:\hiberfil.sys,并把 HiberbootEnabled 显式置 0' -Commands $CMDS

function Invoke-FFCmd {
  param([string]$Command)
  $script:DbkChanged = $true
  Add-DbkAction ('执行:' + $Command)
  if ($env:DBK_FF_CMDS) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($env:DBK_FF_CMDS, ($Command + "`r`n"), $utf8)
    return
  }
  $out = ''
  try { $out = (& cmd.exe /c $Command 2>&1 | Out-String) } catch { $out = $_.Exception.Message }
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    Add-DbkCheck ('失败项:命令失败(退出码 ' + $rc + '):' + $Command + ';输出:' + $out.Trim())
    Write-DbkExit -Status FAIL -Message ('命令失败(退出码 ' + $rc + '):' + $Command + ';输出:' + $out.Trim())
  }
  if ($out.Trim()) { Add-DbkCheck ('命令输出:' + $out.Trim()) }
}

foreach ($c in $CMDS) { Invoke-FFCmd -Command $c }

if ($env:DBK_FF_CMDS) {
  Add-DbkCheck '夹具模式(DBK_FF_CMDS):命令只记录不执行,状态按目标状态记账'
  Write-DbkExit -Status PASS -Message ('已记录 ' + $CMDS.Count + ' 条命令(夹具模式,未真执行):' + ($CMDS -join ' ; '))
}
$st2 = Get-FFState
if (Test-FFOk -State $st2) {
  Write-DbkExit -Status PASS -Message 'Fast Startup 与休眠已关闭(HiberbootEnabled = 0 且 hiberfil.sys 不存在)'
}
Write-DbkExit -Status FAIL -Message ('改动后仍未达标:HiberbootEnabled = ' + [string]$st2.HibernateEnabled + ';hiberfil.sys ' + $(if ([bool]$st2.HiberfilExists) { '存在' } else { '不存在' }) + ';检查是否在管理员会话、是否有组策略/厂商电源软件把它改回')
