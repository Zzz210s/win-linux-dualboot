#Requires -Version 5.1
# 对应卡:03-1,07-4
<#
.SYNOPSIS
  轨道 W:Windows 安装基线核对(安装本身为人工)。缺省 -Check 只读比对版本/内部版本与分区布局;templates/partitions.txt 是目标值真源。
.DESCRIPTION
  三条判据(依据 03-windows.md 的 03-1 与 design 5.1):
    1) 版本:Caption/ProductName 是 Windows 11 专业版且 CurrentBuild >= 22000(DisplayVersion 与 UBR 一并记录)。
    2) 分区:按模板 create partition 行取目标值,与实测按偏移顺序逐项比对(容差 ±2MB)。-Track W 只比前 3 行(ESP/MSR/C:),
       -Track D 比 4 行(含 D: 650240MB)。
    3) WinRE 偏差(只记录、不修布局):恢复分区可能在盘尾另建或吃掉预留段;**ESP 尺寸未被削减**且**最大连续未分配 >= 115GiB**
       (117760MB)即接受(仅 -Track D 要求这段预留);偏差由 03-5 的产物记录。
  只读:不写任何系统状态;唯一写动作是 -Apply 时的日志(本卡无自动改系统的动作,-Apply 与 -Check 等价)。
  退出码:0 通过 / 1 失败(版本或分区不符、ESP 被削减、预留不足、读不到) / 9 跳过(非 Windows 存储环境) / 64 用法错误。
  夹具钩子(仅离线验证,真机留空):DBK_WIN_VERSION=<文件,key=value>、DBK_PART_LAYOUT=<JSON>(形状见 dbk-win-probe.ps1 文件头)。
  参数:-Template <模板路径> 缺省 templates/partitions.txt;-Disk <编号> 缺省 0。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法:
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-windows-baseline.ps1 -Check -Track D
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$Track = 'D', [int]$Disk = 0, [string]$Template = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'verify-windows-baseline' }

$Track = ([string]$Track).ToUpper()
if (@('W', 'D') -notcontains $Track) {
  Write-DbkNote ('用法错误: -Track 只认 W(只 Windows)与 D(双系统),实得 ' + $Track); exit $script:DBK_USAGE
}
if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
  Write-DbkNote '跳过:本会话没有 Get-Disk(不是 Windows 存储环境)'; exit $script:DBK_SKIP
}
$TOL = 2
$ReserveMB = 117760
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
if (-not $Template) { $Template = Join-Path $repoRoot 'templates\partitions.txt' }
$wantN = 3
if ($Track -eq 'D') { $wantN = 4 }
$failN = 0; $failItems = @()

# --- 1. 版本与内部版本 ---
$v = Get-DbkWinVersion
$verText = [string]$v.Caption
if (-not $verText) { $verText = [string]$v.ProductName }
$buildN = 0
if ([string]$v.CurrentBuild -match '^[0-9]+') { $buildN = [int]$Matches[0] }
$verLine = $verText + ' / DisplayVersion ' + [string]$v.DisplayVersion + ' / Build ' + [string]$v.CurrentBuild + '.' + [string]$v.UBR
if ($buildN -lt 22000) { $failN++; $failItems += '系统版本'; Add-DbkCheck ('失败项:不是 Windows 11(内部版本需 >= 22000),实测 ' + $verLine) }
elseif ($verText -notmatch '专业版|Pro') { $failN++; $failItems += '系统版本'; Add-DbkCheck ('失败项:不是 Windows 专业版,实测 ' + $verLine) }
else { Add-DbkCheck ('系统版本:' + $verLine) }

# --- 2. 目标值(模板)与实测布局 ---
$exp = @(Get-DbkTargetLayout -Template $Template)
if ($exp.Count -lt $wantN) {
  Write-DbkExit -Status FAIL -Message ('目标值读不到:' + $Template + ' 里少于 ' + $wantN + ' 条 create partition 行(实得 ' + $exp.Count + ');模板被改过或路径不对,用 -Template 指定正确模板')
}
Add-DbkAction ('目标值来源:' + $Template + '(取前 ' + $wantN + ' 条 create partition 行)')
Add-DbkCheck ('目标布局:' + ((@($exp | Select-Object -First $wantN) | ForEach-Object { $_.Kind + ' ' + $_.SizeMB + 'MB' }) -join ' -> ') + '(' + $Track + ' 轨道)')

$L = Get-DbkPartsLayout -Disk $Disk
if (-not $L.Ok) { Write-DbkExit -Status FAIL -Message ($L.Reason + ';本卡不猜结论,请在管理员会话里重跑(设计 5.1)') }
$got = @($L.Rows | Where-Object { $_.Kind -eq 'efi' -or $_.Kind -eq 'msr' -or $_.Kind -eq 'basic' } | Sort-Object { $_.OffsetMB })
Add-DbkCheck ('实测布局:' + ((@($got) | ForEach-Object { $_.Kind + ' ' + [math]::Round($_.SizeMB, 0) + 'MB@' + [math]::Round($_.OffsetMB, 0) + 'MB' }) -join ' -> '))
if ($got.Count -lt $wantN) {
  $failN++; $failItems += '分区数量'
  Add-DbkCheck ('失败项:实测只有 ' + $got.Count + ' 块 Windows 侧分区,期望 ' + $wantN + ' 块;多余或缺失都按整盘重排处理(02-4)')
} else {
  for ($i = 0; $i -lt $wantN; $i++) {
    $w = $exp[$i]; $g = $got[$i]
    if ($g.Kind -ne $w.Kind) { $failN++; $failItems += ('分区 ' + ($i + 1)); Add-DbkCheck ('失败项:第 ' + ($i + 1) + ' 块类型期望 ' + $w.Kind + ',实测 ' + $g.Kind) }
    elseif ([math]::Abs($g.SizeMB - $w.SizeMB) -gt $TOL) {
      $failN++; $failItems += ('分区 ' + ($i + 1))
      $why = '尺寸不符'
      if ($i -eq 0 -and $g.SizeMB -lt $w.SizeMB) { $why = 'ESP 被削减(安装器默认 100MB 级)' }
      Add-DbkCheck ('失败项:第 ' + ($i + 1) + ' 块(' + $g.Kind + ')' + $why + ',期望 ' + $w.SizeMB + 'MB,实测 ' + [math]::Round($g.SizeMB, 0) + 'MB')
    } else { Add-DbkCheck ('分区 ' + $g.Number + '(' + $g.Kind + ')= ' + [math]::Round($g.SizeMB, 0) + 'MB(期望 ' + $w.SizeMB + 'MB)') }
  }
}

# --- 3. WinRE 偏差与留给 Linux 的未分配空间 ---
$maxGapMB = Get-DbkMaxGapMB -Rows $L.Rows -SizeMB $L.DiskMB
$rec = @($L.Rows | Where-Object { $_.Kind -eq 'recovery' } | Sort-Object { $_.OffsetMB })
if ($rec.Count -gt 0) {
  Add-DbkCheck ('WinRE 落点:分区 ' + $rec[0].Number + ',' + [math]::Round($rec[0].SizeMB, 0) + 'MB@' + [math]::Round($rec[0].OffsetMB, 0) + 'MB(偏差已接受:ESP 未削减且预留 >= 115GiB 即通过)')
  Add-DbkAction '把 WinRE 落点与未分配空间实测值记进 L1 产物(03-5);偏差不改布局'
} else { Add-DbkCheck 'WinRE:尚未看到恢复分区(装完 Windows 才由安装程序建;此处只作提示)' }
if ($Track -eq 'D') {
  if ($maxGapMB -lt ($ReserveMB - $TOL)) {
    $failN++; $failItems += '预留空间'
    Add-DbkCheck ('失败项:留给 Linux 的最大连续未分配只有 ' + [math]::Round(($maxGapMB / 1024), 1) + ' GiB,期望 >= 115GiB;不得削减 ESP 或事后缩容,整盘重排(02-4)')
  } else { Add-DbkCheck ('留给 Linux 的未分配空间:最大连续 ' + [math]::Round(($maxGapMB / 1024), 1) + ' GiB(期望 >= 115GiB;盘尾空隙可比它小,WinRE 占盘尾)') }
} else { Add-DbkCheck ('未分配空间:最大连续 ' + [math]::Round(($maxGapMB / 1024), 1) + ' GiB(轨道 W 不预留 Linux 空间,只作提示)') }

if ($failN -gt 0) {
  Write-DbkExit -Status FAIL -Message ('Windows 基线核对失败 ' + $failN + ' 项:' + ($failItems -join '、') + ';版本或分区不符时不要就地微调,按 02-4 整盘重排后重装')
}
Write-DbkExit -Status PASS -Message ('Windows 11 专业版基线通过:' + $verLine + ';Windows 侧 ' + $got.Count + ' 块分区与模板一致(允许的 WinRE 偏差已记录)')
