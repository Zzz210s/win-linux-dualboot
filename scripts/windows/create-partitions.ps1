#Requires -Version 5.1
# 对应卡:02-4
# 破坏性:1
<#
.SYNOPSIS
  轨道 D 首次装机:用 diskpart 预建整盘分区表(ESP-Windows 2048MB + MSR 16MB + C: 204800MB + D: 650240MB),
  余下约 115GiB 保持未分配,留给 L3 的 Ubuntu 三块分区。**破坏性,只在首次装机用**。
.DESCRIPTION
  前置断言(任一不满足 -> 64 且零写):-Disk 指定的盘存在;该盘当前无有效分区表(0 个分区);-Apply 必须显式 -Yes。
  -Check(缺省)只打印将执行的 diskpart 脚本与断言结果,不执行、不落盘(零写)。
  -Apply -Yes 才写:生成 diskpart 脚本(缺省 %TEMP%\dbk\create-partitions.diskpart)-> diskpart /s 执行
  -> 复读分区表并打印(后置断言:4 个分区尺寸 + D: 之后连续未分配 >= 117760MB(115GiB))。
  **绝不**创建或改动 ESP-Fedora 与 /boot,也不动 \EFI\Microsoft\ 与 {bootmgr}:那三块 Fedora 分区由 L3 在
  未分配段里建(04-2);执行完立刻复读,不符时只能整盘 clean 重来(不做事后缩容,设计 3.5)。
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT=<JSON 文件> 覆盖分区表读数(结构见 check-partition-layout.ps1;
    "disk" 可带 "model");DBK_DISKPART_EXE=<可执行文件> 替代 diskpart(夹具传假盘,记录收到的脚本内容)。
  只读模式(-Check)不建目录、不落盘;-Apply 才写 diskpart 脚本与日志。UTF-8 with BOM + CRLF;夹具级验证,真机未跑。
  用法:在 Windows 安装界面 Shift+F10 的命令行里(或首次装机前的管理员会话):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\create-partitions.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\create-partitions.ps1 -Apply -Yes
  退出码:0 通过 / 1 失败(diskpart 失败或复读不符) / 2 需人工(分区表读不到) / 9 跳过(非 Windows 存储环境) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [int]$Disk = 0, [string]$PlanFile = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\create-partitions.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'create-partitions' }
if (-not $env:DBK_PART_LAYOUT -and -not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
  Write-DbkNote '跳过:本会话没有 Get-Disk(不是 Windows 存储环境)'; exit $script:DBK_SKIP
}

# 定稿布局(设计 5.1):数值与 docs/02-partitioning.md 的 02-1 值表逐字一致,改这里必须同改该表。
$TR = @{ WinEspMB = 2048; MsrMB = 16; WinMB = 204800; DataMB = 650240; ReserveMB = 117760 }
$TOL = 2
$plan = @(
  ('select disk ' + $Disk)
  'clean'
  'convert gpt'
  ('create partition efi size=' + $TR.WinEspMB)
  'format quick fs=fat32 label="System"'
  ('create partition msr size=' + $TR.MsrMB)
  ('create partition primary size=' + $TR.WinMB)
  'format quick fs=ntfs label="Windows"'
  ('create partition primary size=' + $TR.DataMB)
  'format quick fs=ntfs label="Data"'
  'list partition'
  'list disk'
)

function Get-DbkLayout {
  # 夹具钩子优先;否则读真实 Get-Disk / Get-Partition(只读,不改任何状态)。
  param([int]$DiskNumber)
  if ($env:DBK_PART_LAYOUT) {
    if (-not (Test-Path -LiteralPath $env:DBK_PART_LAYOUT)) {
      Write-DbkNote ('用法错误: DBK_PART_LAYOUT 指向的文件不存在: ' + $env:DBK_PART_LAYOUT); exit $script:DBK_USAGE
    }
    try { $o = (Get-Content -LiteralPath $env:DBK_PART_LAYOUT -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 不是合法 JSON: ' + $_.Exception.Message); exit $script:DBK_USAGE }
    if (-not $o.disk) { Write-DbkNote '用法错误: DBK_PART_LAYOUT 缺少 disk 对象'; exit $script:DBK_USAGE }
    $list = @()
    foreach ($q in @($o.partitions)) {
      if ($q) { $list += @{ Number = [int]$q.number; OffsetMB = [double]$q.offsetMB; SizeMB = [double]$q.sizeMB; Kind = ([string]$q.kind).ToLower(); Name = [string]$q.name } }
    }
    return @{ Exists = $true; SizeMB = [double]$o.disk.sizeMB; Style = ([string]$o.disk.partitionStyle).ToUpper(); Model = [string]$o.disk.model; Parts = $list; Error = '' }
  }
  $d = $null; $dErr = ''; try { $d = Get-Disk -Number $DiskNumber -ErrorAction Stop } catch { $dErr = $_.Exception.Message }
  if (-not $d) { return @{ Exists = $false; Error = ('读不到磁盘 ' + $DiskNumber + '(不存在,或会话没有管理员权限)' + $(if ($dErr) { ';底层错误:' + $dErr } else { '' })); Parts = @(); SizeMB = 0; Style = ''; Model = '' } }
  $parts = @(); $err = ''
  try { $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop) } catch { $err = $_.Exception.Message }
  $map = @{ 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' = 'efi'; 'e3c9e316-0b5c-4db8-817d-f92df00215ae' = 'msr'
            'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' = 'basic'; 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' = 'recovery'
            '0fc63daf-8483-4772-8e79-3d69d8477de4' = 'linux' }
  $list = @()
  foreach ($p in $parts) {
    $g = ([string]$p.GptType).Trim().ToLower(); $kind = 'unknown'
    if ($map.ContainsKey($g)) { $kind = $map[$g] }
    $list += @{ Number = [int]$p.PartitionNumber; OffsetMB = [double]($p.Offset / 1MB); SizeMB = [double]($p.Size / 1MB); Kind = $kind; Name = ([string]$p.GptType).Trim() }
  }
  return @{ Exists = $true; SizeMB = [double]($d.Size / 1MB); Style = ([string]$d.PartitionStyle).ToUpper(); Model = ([string]$d.FriendlyName); Parts = $list; Error = $err }
}

function ConvertTo-GiB { param([double]$MB) return [string]([math]::Round(($MB / 1024), 1)) + ' GiB' }
function Format-Part { param($P) return ('分区 ' + $P.Number + ' ' + $P.Kind + ' ' + [math]::Round($P.SizeMB, 0) + 'MB@' + [math]::Round($P.OffsetMB, 0) + 'MB') }
function Show-Parts { param($Parts) if (@($Parts).Count -eq 0) { return '无' } return ((@($Parts) | ForEach-Object { Format-Part $_ }) -join ';') }
function Get-MaxGapMB { param($Gaps) $a = @($Gaps | ForEach-Object { [double]$_.SizeMB }); if ($a.Count -eq 0) { return [double]0 } return [double](($a | Measure-Object -Maximum).Maximum) }
function Get-GapsAfter { param($L, [double]$FromMB)
  $gaps = @(); $prev = [double]0
  foreach ($p in @($L.Parts | Sort-Object { $_.OffsetMB })) {
    if (($p.OffsetMB - $prev) -gt 1 -and $prev -ge ($FromMB - $TOL)) { $gaps += @{ SizeMB = ($p.OffsetMB - $prev) } }
    $prev = $p.OffsetMB + $p.SizeMB
  }
  if (($L.SizeMB - $prev) -gt 1 -and $prev -ge ($FromMB - $TOL)) { $gaps += @{ SizeMB = ($L.SizeMB - $prev) } }
  return @($gaps)
}

$L = Get-DbkLayout -DiskNumber $Disk
if (-not $L.Exists) {
  Write-DbkNote ('前置断言不满足: ' + $L.Error)
  Write-DbkNote '本脚本只用于"目标盘当前无有效分区表"的首次装机;已零写(未执行任何命令)。'
  exit $script:DBK_USAGE
}
Add-DbkCheck ('目标盘 磁盘 ' + $Disk + ':型号 ' + $L.Model + '、样式 ' + $L.Style + '、容量 ' + (ConvertTo-GiB $L.SizeMB))
if ($L.Error) {
  Add-DbkCheck ('需人工:分区表读取不完整(' + $L.Error + ');空白判定不可信,本脚本拒绝执行(零写)')
  Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $L.Error + ';不能确认目标盘是空白盘,故不执行任何命令')
}
$cur = @($L.Parts)
foreach ($p in @($cur | Sort-Object { $_.OffsetMB })) { Write-DbkNote ('  现: ' + (Format-Part $p)) }
if ($cur.Count -gt 0) {
  Write-DbkNote ('前置断言不满足: 磁盘 ' + $Disk + ' 上已有分区表(' + $cur.Count + ' 个分区):' + (Show-Parts $cur))
  Write-DbkNote '本脚本只用于首次装机;要整盘重排,先人工确认目标盘无误并 clean,再重跑(已零写)。'
  exit $script:DBK_USAGE
}
Add-DbkCheck '前置断言:目标盘存在,且当前无有效分区表(0 个分区)'
Write-DbkNote ('--- 将执行的分区命令(diskpart /s;磁盘 ' + $Disk + ')---')
foreach ($c in $plan) { Write-DbkNote ('  ' + $c) }
Add-DbkCheck ('将执行 ' + $plan.Count + ' 条 diskpart 命令(ESP ' + $TR.WinEspMB + 'MB / MSR ' + $TR.MsrMB + 'MB / C: ' + $TR.WinMB + 'MB / D: ' + $TR.DataMB + 'MB;余下约 115GiB 不分配)')
Add-DbkAction '不建 ESP-Fedora 与 /boot(那是 L3 在未分配段里建的,见 02-3 与 04-2)'

if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 未执行、未落盘(零写);确认型号与容量无误后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('前置断言全部满足;将执行 ' + $plan.Count + ' 条 diskpart 命令(ESP ' + $TR.WinEspMB + ' / MSR ' + $TR.MsrMB + ' / C: ' + $TR.WinMB + ' / D: ' + $TR.DataMB + ' MB,余下约 115GiB 不分配),-Check 零写')
}

$exe = 'diskpart'
if ($env:DBK_DISKPART_EXE) { $exe = $env:DBK_DISKPART_EXE }
if (-not $PlanFile) { $PlanFile = Join-Path (Join-Path $env:TEMP 'dbk') 'create-partitions.diskpart' }
$dirP = Split-Path -Parent $PlanFile
if ($dirP -and -not (Test-Path -LiteralPath $dirP)) { New-Item -ItemType Directory -Path $dirP -Force | Out-Null }
[System.IO.File]::WriteAllLines($PlanFile, [string[]]$plan)
Add-DbkAction ('diskpart 脚本已落盘:' + $PlanFile)
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$out = ''; $code = 1
try { $out = ([string](& $exe /s $PlanFile 2>&1 | Out-String)); $code = [int]$LASTEXITCODE } catch { $out = [string]$_.Exception.Message }
$ErrorActionPreference = $prevEap
if ($out.Trim()) { Write-DbkLog ('diskpart 输出:' + ($out.Trim() -replace "`r?`n", ' | ')) }
if ($code -ne 0) {
  Add-DbkCheck ('失败项:diskpart 退出码 ' + $code + ',输出:' + ($out.Trim() -replace "`r?`n", ' | '))
  Write-DbkExit -Status FAIL -Message ('diskpart 执行失败(退出码 ' + $code + '):' + ($out.Trim() -replace "`r?`n", ' | ') + ';分区表可能只改了一半,先人工核对再决定是否整盘 clean 重来')
}
Set-DbkChanged
$R = Get-DbkLayout -DiskNumber $Disk
Write-DbkNote '--- 复读分区表(写后)---'
foreach ($p in @($R.Parts | Sort-Object { $_.OffsetMB })) { Write-DbkNote ('  ' + (Format-Part $p)) }
$f2 = 0
foreach ($spec in @('efi|2048|ESP-Windows', 'msr|16|MSR', 'basic|204800|C:', 'basic|650240|D:')) {
  $a = $spec -split '\|'
  $hit = @($R.Parts | Where-Object { $_.Kind -eq $a[0] -and ([math]::Abs($_.SizeMB - [double]$a[1]) -le $TOL) })
  if ($hit.Count -eq 0) { $f2++; Add-DbkCheck ('失败项:复读未见 ' + $a[2] + '(期望 ' + $a[1] + 'MB,' + $a[0] + '),实际 ' + (Show-Parts $R.Parts)) }
}
$data = @($R.Parts | Where-Object { $_.Kind -eq 'basic' -and ([math]::Abs($_.SizeMB - $TR.DataMB) -le $TOL) })
$dEnd = [double]0
if ($data.Count -gt 0) { $dEnd = $data[0].OffsetMB + $data[0].SizeMB }
$best = Get-MaxGapMB -Gaps (Get-GapsAfter -L $R -FromMB $dEnd)
if ($best -lt ($TR.ReserveMB - $TOL)) {
  $f2++; Add-DbkCheck ('失败项:D: 之后连续未分配期望 >= ' + $TR.ReserveMB + 'MB(115GiB),实际 ' + (ConvertTo-GiB $best))
} else { Add-DbkCheck ('复读通过:D: 之后仍有 ' + (ConvertTo-GiB $best) + ' 连续未分配(>= 115GiB,L3 的 Ubuntu 三块分区落在这里)') }
if ($f2 -gt 0) {
  Write-DbkExit -Status FAIL -Message ('diskpart 已执行,但复读分区表与目标不符(' + $f2 + ' 项,见 checks);分区表已改动、无法自动回退:确认目标盘无误后整盘 clean 重跑本脚本,不得事后缩容')
}
Write-DbkExit -Status PASS -Message ('分区表已按定稿布局建好(ESP ' + $TR.WinEspMB + ' / MSR ' + $TR.MsrMB + ' / C: ' + $TR.WinMB + ' / D: ' + $TR.DataMB + ' MB),D: 之后仍留 ' + (ConvertTo-GiB $best) + ' 未分配;接着跑 check-partition-layout.ps1 -Track D 复核')
