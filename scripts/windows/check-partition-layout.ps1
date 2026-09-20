#Requires -Version 5.1
# 对应卡:02-1,02-2,02-3
<#
.SYNOPSIS
  分盘前置章节的只读核对:当前磁盘布局 vs 定稿目标布局(设计 5.1)。缺省 -Track D。
.DESCRIPTION
  判据(数值即定稿值,一字不改):
    W 只 Windows:ESP-Windows 2048MB(EFI System)、MSR 16MB、C: 204800MB、WinRE;不要求预留 Linux 空间。
    L 只 Silverblue:ESP-Fedora 1024MB(EFI System)、/boot 1024MB(Linux filesystem)、root >= 115712MB(约 113GiB)。
    D 双系统:ESP-Windows 2048MB + MSR 16MB + C: 204800MB + D: 650240MB + D: 之后连续未分配 >= 117760MB(115GiB)+ WinRE
      (WinRE 未建时只提示:它由 Windows 安装程序在 03-1 阶段建,不作为失败项)。
  口径:尺寸按 MB 比对(容差 +-2MB);角色按 GPT 类型识别;/boot 的 ext4 与 root 的 btrfs 在 Windows 侧读不到,
    须进 live 后按 04-2 复核(本脚本在 actions 里提示)。
  退出码:0 通过 / 1 失败(打印期望与实际) / 2 需人工(类型未识别等无法判定) / 9 跳过(非 Windows 存储环境) / 64 用法错误。
  只读:不写任何系统状态与文件;-Check 缺省,-Apply 也只重复打印一遍(本卡无自动写动作)。
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT=<JSON 文件> 覆盖 Get-Disk/Get-Partition 读数;
    {"disk":{"sizeMB":953869,"partitionStyle":"GPT"},"partitions":[{"number":1,"offsetMB":1,"sizeMB":2048,"kind":"efi","name":""}]};
    kind 取 efi|msr|basic|recovery|linux|unknown;partitionStyle 用 RAW 表示尚无分区表。
  UTF-8 with BOM + CRLF;夹具级验证,真机未跑。用法:
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\check-partition-layout.ps1 -Track D [-Json]
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Track = 'D', [int]$Disk = 0,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\check-partition-layout.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'check-partition-layout' }

$Track = ([string]$Track).ToUpper()
if (@('W', 'L', 'D') -notcontains $Track) {
  Write-DbkNote ('用法错误: -Track 只认 W / L / D,实得 ' + $Track); exit $script:DBK_USAGE
}
if (-not $env:DBK_PART_LAYOUT -and -not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
  Write-DbkNote '跳过:本会话没有 Get-Disk(不是 Windows 存储环境)'; exit $script:DBK_SKIP
}

# 定稿布局(设计 5.1):数值与 docs/02-partitioning.md 的 02-1 值表逐字一致,改这里必须同改该表。
$TR = @{ WinEspMB = 2048; MsrMB = 16; WinMB = 204800; DataMB = 650240; WinReMB = 1024
         FedEspMB = 1024; BootMB = 1024; RootMinMB = 115712; ReserveMB = 117760 }
$TOL = 2

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
    return @{ Exists = $true; SizeMB = [double]$o.disk.sizeMB; Style = ([string]$o.disk.partitionStyle).ToUpper(); Parts = $list; Error = '' }
  }
  $d = $null; try { $d = Get-Disk -Number $DiskNumber -ErrorAction Stop } catch { }
  if (-not $d) { return @{ Exists = $false; Error = ('读不到磁盘 ' + $DiskNumber + '(不存在,或会话没有管理员权限)'); Parts = @(); SizeMB = 0; Style = '' } }
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
  return @{ Exists = $true; SizeMB = [double]($d.Size / 1MB); Style = ([string]$d.PartitionStyle).ToUpper(); Parts = $list; Error = $err }
}

function ConvertTo-GiB { param([double]$MB) return [string]([math]::Round(($MB / 1024), 1)) + ' GiB' }
function Test-MB { param([double]$Actual, [double]$Expected) return ([math]::Abs($Actual - $Expected) -le $TOL) }
function Format-Part { param($P) return ('分区 ' + $P.Number + ' ' + $P.Kind + ' ' + [math]::Round($P.SizeMB, 0) + 'MB@' + [math]::Round($P.OffsetMB, 0) + 'MB') }
function Show-Parts { param($Parts) if (@($Parts).Count -eq 0) { return '无' } return ((@($Parts) | ForEach-Object { Format-Part $_ }) -join ';') }
function Select-Kind { param($Parts, [string]$Kind) return @($Parts | Where-Object { $_.Kind -eq $Kind }) }
function Select-KindMB { param($Parts, [string]$Kind, [double]$MB) return @($Parts | Where-Object { $_.Kind -eq $Kind -and (Test-MB $_.SizeMB $MB) }) }
function Get-Gaps { param($L)
  $gaps = @(); $prev = [double]0
  foreach ($p in @($L.Parts | Sort-Object { $_.OffsetMB })) {
    if (($p.OffsetMB - $prev) -gt 1) { $gaps += @{ StartMB = $prev; SizeMB = ($p.OffsetMB - $prev) } }
    $prev = $p.OffsetMB + $p.SizeMB
  }
  if (($L.SizeMB - $prev) -gt 1) { $gaps += @{ StartMB = $prev; SizeMB = ($L.SizeMB - $prev) } }
  return $gaps
}
function Get-MaxGapMB { param($Gaps) $a = @($Gaps | ForEach-Object { [double]$_.SizeMB }); if ($a.Count -eq 0) { return [double]0 } return [double](($a | Measure-Object -Maximum).Maximum) }

$L = Get-DbkLayout -DiskNumber $Disk
$failN = 0; $manualN = 0; $failItems = @()
if (-not $L.Exists) { Write-DbkExit -Status FAIL -Message ($L.Error + ';先用 02-1 的"看到:"确认 -Disk 编号(磁盘 0 通常是第一块盘),再重跑') }
Add-DbkCheck ('磁盘 ' + $Disk + ':样式 ' + $L.Style + '、容量 ' + (ConvertTo-GiB $L.SizeMB) + '、分区 ' + @($L.Parts).Count + ' 个;轨道 ' + $Track)
foreach ($p in @($L.Parts | Sort-Object { $_.OffsetMB })) { Write-DbkNote ('  ' + (Format-Part $p)) }
if ($L.Error) {
  Add-DbkCheck ('需人工:分区表读取不完整(' + $L.Error + ');布局无法判定,请在管理员会话或 live 环境复核')
  Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $L.Error + ';本脚本不猜结论,请人工核对后再判')
}
$parts = @($L.Parts)
foreach ($u in @($parts | Where-Object { $_.Kind -eq 'unknown' })) { $manualN++; Add-DbkCheck ('需人工:' + (Format-Part $u) + ' 的 GPT 类型未识别(' + $u.Name + '),无法判定它的用途') }
$gaps = @(Get-Gaps -L $L)

if ($Track -eq 'W' -or $Track -eq 'D') {
  # ESP-Windows 定稿 2048MB;安装器自动分区给的是 100MB 级 ESP,与本表不符(设计 3.4),要过本项须最小手工预建。
  $esp = @(Select-KindMB -Parts $parts -Kind 'efi' -MB $TR.WinEspMB)
  if ($esp.Count -eq 0) { $failN++; $failItems += 'ESP-Windows'; Add-DbkCheck ('失败项:ESP-Windows 期望 ' + $TR.WinEspMB + 'MB(EFI System),实际 ' + (Show-Parts (Select-Kind -Parts $parts -Kind 'efi'))) }
  else { Add-DbkCheck ('ESP-Windows:' + (Format-Part $esp[0]) + '(期望 ' + $TR.WinEspMB + 'MB)') }
  $msr = @(Select-Kind -Parts $parts -Kind 'msr')
  if ($msr.Count -eq 0) { $failN++; $failItems += 'MSR'; Add-DbkCheck ('失败项:MSR 期望 ' + $TR.MsrMB + 'MB(Microsoft Reserved),实际 无') }
  elseif (-not (Test-MB $msr[0].SizeMB $TR.MsrMB)) { $failN++; $failItems += 'MSR'; Add-DbkCheck ('失败项:MSR 期望 ' + $TR.MsrMB + 'MB,实际 ' + (Format-Part $msr[0])) }
  else { Add-DbkCheck ('MSR:' + (Format-Part $msr[0]) + '(期望 ' + $TR.MsrMB + 'MB)') }
  $win = @(Select-KindMB -Parts $parts -Kind 'basic' -MB $TR.WinMB)
  if ($win.Count -eq 0) { $failN++; $failItems += 'C:'; Add-DbkCheck ('失败项:C: 期望 ' + $TR.WinMB + 'MB(NTFS),实际 ' + (Show-Parts (Select-Kind -Parts $parts -Kind 'basic'))) }
  else { Add-DbkCheck ('C::' + (Format-Part $win[0]) + '(期望 ' + $TR.WinMB + 'MB)') }
  $re = @(Select-Kind -Parts $parts -Kind 'recovery')
  if ($Track -eq 'W' -and $re.Count -eq 0) { $failN++; $failItems += 'WinRE'; Add-DbkCheck '失败项:WinRE 期望 1GiB(Recovery,盘尾),实际 无;装完 Windows 后由 03-1 核对落点' }
  elseif ($re.Count -eq 0) { Add-DbkCheck 'WinRE:尚未创建(轨道 D 首次装机时正常;它由 Windows 安装程序在 03-1 阶段建,本项不判失败)' }
  else { Add-DbkCheck ('WinRE:' + (Format-Part $re[0]) + '(可能落在预留段内,只要预留段仍 >=115GiB 即接受)') }
  $data = @(Select-KindMB -Parts $parts -Kind 'basic' -MB $TR.DataMB)
  $dataEnd = [double]0
  if ($data.Count -gt 0) { $dataEnd = $data[0].OffsetMB + $data[0].SizeMB }
  if ($Track -eq 'D') {
    if ($data.Count -eq 0) { $failN++; $failItems += 'D:'; Add-DbkCheck ('失败项:D: 期望 ' + $TR.DataMB + 'MB(NTFS 数据盘),实际 ' + (Show-Parts (Select-Kind -Parts $parts -Kind 'basic'))) }
    else { Add-DbkCheck ('D::' + (Format-Part $data[0]) + '(期望 ' + $TR.DataMB + 'MB)') }
    $best = Get-MaxGapMB -Gaps @($gaps | Where-Object { $_.StartMB -ge ($dataEnd - $TOL) })
    if ($best -lt ($TR.ReserveMB - $TOL)) {
      $failN++; $failItems += '预留段'
      Add-DbkCheck ('失败项:D: 之后的预留段期望 >= ' + $TR.ReserveMB + 'MB(115GiB)连续未分配,实际 ' + (ConvertTo-GiB $best) + ';L3 的 ESP-Fedora 1GiB + /boot 1GiB + root 约 113GiB 都要落在这段里')
    } else { Add-DbkCheck ('D: 之后的预留段:' + (ConvertTo-GiB $best) + ' 连续未分配(期望 >= ' + (ConvertTo-GiB $TR.ReserveMB) + ')') }
  } else {
    if ($data.Count -gt 0) { Add-DbkCheck ('数据分区 D::' + (Format-Part $data[0]) + '(轨道 W 不要求,只作提示)') }
    Add-DbkCheck ('未分配空间:' + (ConvertTo-GiB (Get-MaxGapMB -Gaps $gaps)) + '(轨道 W 不要求预留 Linux 空间,只作提示)')
  }
}

if ($Track -eq 'L') {
  $esp = @(Select-KindMB -Parts $parts -Kind 'efi' -MB $TR.FedEspMB)
  if ($esp.Count -eq 0) { $failN++; $failItems += 'ESP-Fedora'; Add-DbkCheck ('失败项:ESP-Fedora 期望 ' + $TR.FedEspMB + 'MB(EFI System),实际 ' + (Show-Parts (Select-Kind -Parts $parts -Kind 'efi'))) }
  else { Add-DbkCheck ('ESP-Fedora:' + (Format-Part $esp[0]) + '(期望 ' + $TR.FedEspMB + 'MB)') }
  $linux = @(Select-Kind -Parts $parts -Kind 'linux')
  if ($linux.Count -gt 2) { $manualN++; Add-DbkCheck ('需人工:盘上有 ' + $linux.Count + ' 块 Linux filesystem 分区,超出目标布局(只有 /boot 与 root 两块):' + (Show-Parts $linux)) }
  $boot = @($linux | Where-Object { Test-MB $_.SizeMB $TR.BootMB })
  if ($boot.Count -eq 0) { $failN++; $failItems += '/boot'; Add-DbkCheck ('失败项:/boot 期望 ' + $TR.BootMB + 'MB(ext4,必须独立),实际 ' + (Show-Parts $linux)) }
  else { Add-DbkCheck ('/boot:' + (Format-Part $boot[0]) + '(期望 ' + $TR.BootMB + 'MB)') }
  $big = @($linux | Sort-Object { -$_.SizeMB })
  if ($big.Count -eq 0 -or $big[0].SizeMB -lt ($TR.RootMinMB - $TOL)) { $failN++; $failItems += 'root'; Add-DbkCheck ('失败项:root 期望 >= ' + $TR.RootMinMB + 'MB(约 113GiB,btrfs),实际 ' + (Show-Parts $linux)) }
  else { Add-DbkCheck ('root:' + (Format-Part $big[0]) + '(期望 >= ' + $TR.RootMinMB + 'MB,约 113GiB)') }
  Add-DbkAction '文件系统与挂载点(/boot 的 ext4 与 root 的 btrfs)在 Windows 侧读不到:进 live 后按 04-2 的手动分区核对(用 check-partition-plan.sh)'
}
if ($Track -eq 'D') { Add-DbkAction '两块 ESP 的固件可见性(固件能否枚举/从第二块盘引导)读不到,只能人工:按 00-overview.md 的偏离项处置表记录' }
if ($failN -gt 0) { Write-DbkExit -Status FAIL -Message ('轨道 ' + $Track + ' 布局核对失败 ' + $failN + ' 项:' + ($failItems -join '、') + ';期望值与实际值见 checks;尺寸与目标不符时不要事后缩容,整盘重排(02-4)后重跑') }
if ($manualN -gt 0) { Write-DbkExit -Status 需人工 -Message ('轨道 ' + $Track + ' 有 ' + $manualN + ' 项无法在 Windows 侧判定,必须人工核对(见 checks 的「需人工」行与 actions)') }
Write-DbkExit -Status PASS -Message ('轨道 ' + $Track + ' 的布局与定稿目标一致(磁盘 ' + $Disk + ',分区 ' + $parts.Count + ' 个)')
