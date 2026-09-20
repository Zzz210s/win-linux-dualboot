#Requires -Version 5.1
# 对应卡:03-4
<#
.SYNOPSIS
  轨道 W:KMS 激活状态**只读**核对(激活动作人工)。缺省 -Check 即本脚本的唯一行为,-Apply 与 -Check 等价。
.DESCRIPTION
  本脚本只读状态,**不含也不分发任何激活脚本本体**,不写购买路径,不引入自建 KMS;激活走上游项目的官方入口,步骤见 03-windows.md 的 03-4。
  判据(依据 design 3.10):
    1) Get-CimInstance SoftwareLicensingProduct(PartialProductKey 非空、名称含 Windows)的 LicenseStatus = 1(已授权);
    2) GracePeriodRemaining 记录本次周期剩余时间(Online KMS 为 180 天周期,续期任务由上游流程创建,本脚本只记录状态)。
  首次激活失败**不阻塞** L1(design 第 7 节 L1 行):未授权时退出码 2(需人工),把报错与失败记进 01-activation.md(03-5)即可继续。
  只读:不写任何系统状态与文件;唯一写动作是 -Apply 时的日志(本卡无自动改系统的动作)。
  退出码:0 已授权 / 1 读不到授权状态(需管理员或 WMI 不可用) / 2 未授权(激活动作人工) / 9 跳过(非 Windows) / 64 用法错误。
  夹具钩子(仅离线验证,真机留空):DBK_ACT_DUMP=<文件,每行 key=value:name/licenseStatus/gracePeriodRemaining/description>。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法:
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\check-activation.ps1 -Check
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
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'check-activation' }

# 授权状态文本(CIM 枚举值 → 中文;未知码原样保留)
function Get-LicStatusText {
  param([string]$Code)
  switch ($Code) {
    '0' { '未授权(Unlicensed)' }
    '1' { '已授权(Licensed)' }
    '2' { '初始宽限期' }
    '3' { '额外宽限期' }
    '4' { '非正版宽限期' }
    '5' { '通知模式(Notification)' }
    '6' { '扩展宽限期' }
    default { '未知状态码 ' + $Code }
  }
}

$o = @{ Name = ''; LicenseStatus = ''; GracePeriodRemaining = ''; Description = ''; Source = '本机' }
if ($env:DBK_ACT_DUMP) {
  if (-not (Test-Path -LiteralPath $env:DBK_ACT_DUMP)) {
    Write-DbkNote ('用法错误: DBK_ACT_DUMP 指向的文件不存在: ' + $env:DBK_ACT_DUMP); exit $script:DBK_USAGE
  }
  foreach ($line in [System.IO.File]::ReadAllLines($env:DBK_ACT_DUMP, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
      $k = $Matches[1]; $val = $Matches[2].Trim()
      if ($k -match '^(?i)name$') { $o.Name = $val }
      if ($k -match '^(?i)licenseStatus$') { $o.LicenseStatus = $val }
      if ($k -match '^(?i)gracePeriodRemaining$') { $o.GracePeriodRemaining = $val }
      if ($k -match '^(?i)description$') { $o.Description = $val }
    }
  }
  $o.Source = '夹具(DBK_ACT_DUMP)'
} else {
  $rec = $null
  try {
    $all = @(Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
      Where-Object { $_.PartialProductKey -and $_.Name -match 'Windows' })
    if ($all.Count -gt 0) { $rec = $all[0] }
  } catch {
    $rec = $null
    Write-DbkNote ('读授权状态失败:' + $_.Exception.Message)
  }
  if ($rec) {
    $o.Name = [string]$rec.Name
    $o.LicenseStatus = [string]$rec.LicenseStatus
    $o.GracePeriodRemaining = [string]$rec.GracePeriodRemaining
    $o.Description = [string]$rec.Description
  }
}

Add-DbkCheck ('读数来源:' + $o.Source)
if (-not $o.LicenseStatus) {
  Write-DbkExit -Status FAIL -Message '读不到授权状态(Get-CimInstance SoftwareLicensingProduct 无结果):用管理员身份重跑;WMI 服务被禁时需先恢复 Software Protection 服务'
}
$statusText = Get-LicStatusText $o.LicenseStatus
$days = ''
if ($o.GracePeriodRemaining -match '^[0-9]+$') { $days = [string][math]::Floor([double]$o.GracePeriodRemaining / 1440) }
Add-DbkCheck ('授权对象:' + $(if ($o.Name) { $o.Name } else { '(名称读不到)' }) + ';LicenseStatus = ' + $o.LicenseStatus + '(' + $statusText + ')')
if ($days) { Add-DbkCheck ('本周期剩余:' + $days + ' 天(GracePeriodRemaining = ' + $o.GracePeriodRemaining + ' 分钟;Online KMS 周期 180 天)') }
if ($o.Description) { Add-DbkCheck ('描述:' + $o.Description) }

if ($o.LicenseStatus.Trim() -eq '1') {
  Add-DbkAction '把本脚本输出(含执行日期)写进 01-activation.md(03-5);续期任务与 KMS 主机 1688 端口可达性按 03-4 人工核对'
  Write-DbkExit -Status PASS -Message ('已授权(LicenseStatus = 1' + $(if ($days) { ',本周期剩余 ' + $days + ' 天' } else { '' }) + ');激活状态已核对')
}
Add-DbkAction '激活走上游项目官方入口(见 03-windows.md 的 03-4),本脚本不含激活脚本本体;完成后再跑一次本脚本'
Write-DbkExit -Status 需人工 -Message ('未授权(LicenseStatus = ' + $o.LicenseStatus + ',' + $statusText + '):激活按 03-4 人工做;本项不阻塞 L1,把状态与报错记进 01-activation.md(03-5)后继续')
