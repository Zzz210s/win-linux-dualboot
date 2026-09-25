#Requires -Version 5.1
# 对应卡:07-11
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-11):按分区号或 GPT GUID 精确删除 Ubuntu 分区(两块 Ubuntu 分区可一并删)。
.DESCRIPTION
  只认显式目标:-Partition <int[]> 与/或 -PartitionGuid <string[]>(GUID 先在当前分区表里解析成分区号;都没给 -> 64 零写)。
  绝不做"删除所有 Linux 分区"这类模糊操作,也绝不用 diskpart clean / delete volume。**Windows ESP / C: / D: / MSR /
  WinRE 永远不是目标**:逐个校验(MSR/WinRE 按分区类型,C:/D: 按盘符,Windows ESP 用挂载探测 \EFI\Microsoft\ ——
  ESP-Fedora 与 Windows ESP 同为 EFI System 类型,必须靠显式分区号/GUID + 探测才能分开;无法映射时先用 -WinEspNumber 声明。目标非法 -> 64 零写;目标不存在 -> 1 零写。
  -Check(缺省)只打印分区表 diff(执行前 / 计划执行后);-Apply -Yes:生成 diskpart 脚本(select partition <N> +
  delete partition override)-> 执行 -> 复读断言:目标分区消失、其它分区 offset/size 逐项未变、最大连续未分配空间新增,
  且 BootOrder 首位仍是 Windows Boot Manager、{bootmgr} path 未变;任一不符 -> FAIL(1)并打印复读结果。
  前置断言(任一不满足 -> 64 零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  BootOrder 首位是 Windows Boot Manager;显式目标已确认。非管理员 -> 2(需人工);非 Windows -> 9(跳过)。
  用法示例(仓库根、管理员 Windows PowerShell;分区号按 baseline\02-partitions.txt 实测;5 = ESP-Fedora,6 = /boot,7 = Ubuntu root):
    ... -Check -Partition 5,6
    ... -Apply -Yes -Partition 5,6 -WinEspNumber 1    # 或 -PartitionGuid <GPT 分区 GUID>
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT / DBK_PART_LAYOUT_AFTER(前/后分区表 JSON,结构同
  check-partition-layout.ps1,可带 guid 字段)、DBK_PROTECT_NUMBERS(注入 Windows 分区号,逗号分隔)、DBK_ESP_ROOT_<N>
  (分区 N 的 ESP 内容根)与 DBK_WIN_ESP_NUMBER(声明哪个分区号是 Windows ESP)、DBK_DISKPART_EXE(假 diskpart)、
  DBK_DISKPART_SCRIPT(diskpart 脚本落盘路径)、DBK_FW_TEXT[_AFTER] / DBK_BM_TEXT[_AFTER] / DBK_BCEDIT_EXE / DBK_IS_ADMIN=1、DBK_CALLS。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:diskpart 的 select partition <N> 与 delete partition override。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。固件解析与断言在库 scripts/windows/dbk-win-probe.ps1 里。
  退出码:0 通过 / 1 失败(目标不存在或后置复读不符) / 2 需人工(非管理员或分区表读不到) / 9 跳过(非 Windows) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [int]$Disk = 0, [int[]]$Partition = @(), [string[]]$PartitionGuid = @(),
  [int]$WinEspNumber = 0, [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
# 库文件:固件/BCD 枚举与断言(本脚本只做分区计算与 diskpart 写动作)。
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\delete-linux-partition.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'delete-linux-partition' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
# 分区表读数(只读):夹具用 DBK_PART_LAYOUT[_AFTER];真机用 Get-Disk/Get-Partition。行:Number/OffsetMB/SizeMB/Kind/Label/Guid。
function Get-DbkTable {
  param([switch]$After)
  $f = [string]$env:DBK_PART_LAYOUT
  if ($After -and $env:DBK_PART_LAYOUT_AFTER) { $f = $env:DBK_PART_LAYOUT_AFTER }
  if ($f) {
    if (-not (Test-Path -LiteralPath $f)) { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 指向的文件不存在: ' + $f); exit $script:DBK_USAGE }
    try { $o = (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 不是合法 JSON: ' + $_.Exception.Message); exit $script:DBK_USAGE }
    $rows = @()
    foreach ($q in @($o.partitions)) { if ($q) { $rows += @{ Number = [int]$q.number; OffsetMB = [double]$q.offsetMB; SizeMB = [double]$q.sizeMB; Kind = ([string]$q.kind).ToLower(); Label = [string]$q.name; Guid = ([string]$q.guid).Trim().Trim('{', '}').ToUpper() } } }
    $mb = 0; if ($o.disk) { $mb = [double]$o.disk.sizeMB }
    return @{ Ok = $true; DiskMB = $mb; Rows = @($rows | Sort-Object { $_.OffsetMB }); Error = '' }
  }
  if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) { return @{ Ok = $false; DiskMB = 0; Rows = @(); Error = '本会话没有 Get-Partition(不是 Windows 存储环境)' } }
  $kinds = @{ 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' = 'efi'; 'e3c9e316-0b5c-4db8-817d-f92df00215ae' = 'msr'; 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' = 'basic'; 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' = 'recovery'; '0fc63daf-8483-4772-8e79-3d69d8477de4' = 'linux' }
  $mb = 0; $rows = @()
  try {
    $mb = [double]((Get-Disk -Number $Disk -ErrorAction Stop).Size / 1MB)
    foreach ($p in @(Get-Partition -DiskNumber $Disk -ErrorAction Stop)) {
      $g = ([string]$p.GptType).Trim().ToLower(); $k = 'unknown'; if ($kinds.ContainsKey($g)) { $k = $kinds[$g] }
      $rows += @{ Number = [int]$p.PartitionNumber; OffsetMB = [double]($p.Offset / 1MB); SizeMB = [double]($p.Size / 1MB); Kind = $k; Label = ''; Guid = ([string]$p.Guid).Trim('{', '}').ToUpper() }
    }
    return @{ Ok = $true; DiskMB = $mb; Rows = @($rows | Sort-Object { $_.OffsetMB }); Error = '' }
  } catch { return @{ Ok = $false; DiskMB = $mb; Rows = @(); Error = ('分区表读不到:' + $_.Exception.Message + '(需要管理员会话)') } }
}
# 最大连续未分配间隙(MB):删除前后比较"连续未分配空间新增"。
function Get-DbkMaxGap {
  param($Rows, [double]$DiskMB)
  $g = @(); $prev = [double]0
  foreach ($p in @($Rows | Sort-Object { $_.OffsetMB })) { if (($p.OffsetMB - $prev) -gt 2) { $g += ($p.OffsetMB - $prev) }; $prev = $p.OffsetMB + $p.SizeMB }
  if (($DiskMB - $prev) -gt 2) { $g += ($DiskMB - $prev) }
  if ($g.Count -eq 0) { return [double]0 }
  return [double](($g | Measure-Object -Maximum).Maximum)
}
# Windows ESP 判定(目标含 efi 分区时必需;无法证明"它不是 Windows ESP"一律拒删):夹具 DBK_ESP_ROOT_<N> = 分区 N
#   的 ESP 内容根(探 <root>\EFI\Microsoft);真机用 -WinEspNumber <N>/DBK_WIN_ESP_NUMBER 由人工声明;都没有 -> unknown。
function Get-DbkEspVerdict {
  param([int]$N)
  $r = [string](Get-Item -Path ('Env:DBK_ESP_ROOT_' + $N) -ErrorAction SilentlyContinue).Value
  if ($r) { if (Test-Path -LiteralPath (Join-Path $r 'EFI\Microsoft')) { return @{ V = 'win'; Why = ($r + ' 下存在 \EFI\Microsoft\') } }; return @{ V = 'other'; Why = ($r + ' 下无 \EFI\Microsoft\') } }
  $w = $WinEspNumber; if ($w -le 0 -and $env:DBK_WIN_ESP_NUMBER) { $w = [int]$env:DBK_WIN_ESP_NUMBER }
  if ($w -gt 0) { if ($N -eq $w) { return @{ V = 'win'; Why = ('人工声明的 Windows ESP 分区号 ' + $w) } }; return @{ V = 'other'; Why = ('人工声明的 Windows ESP 分区号 ' + $w + '(该分区不是)') } }
  return @{ V = 'unknown'; Why = '无法把当前挂载的 ESP 映射到分区号;真机请先确认 Windows ESP 分区号并用 -WinEspNumber 指定' }
}
# 目标分区能不能删:空串 = 可删;'EXIST:...' = 不存在(-> 1 零写);其它 = 禁删(-> 64 零写)。
function Get-DbkVerdict {
  param([int]$N, $Rows, $Protect)
  $hit = @($Rows | Where-Object { [int]$_.Number -eq $N })
  if ($hit.Count -eq 0) { return ('EXIST:分区 ' + $N + ' 不在当前分区表里(可能已删过或写错号)') }
  $r = $hit[0]
  if ($r.Kind -eq 'msr' -or $r.Kind -eq 'recovery') { return ('PROTECT:分区 ' + $N + ' 是系统保留/恢复分区(' + $r.Kind + '),绝不允许删除') }
  if ($Protect -contains $N) { return ('PROTECT:分区 ' + $N + ' 是 Windows 系统/数据盘(C:/D: 或 DBK_PROTECT_NUMBERS 判定),绝不允许删除') }
  if ($r.Kind -ne 'efi') { return '' }
  $v = Get-DbkEspVerdict -N $N
  if ($v.V -eq 'win') { return ('PROTECT:分区 ' + $N + ' 是 Windows ESP(' + $v.Why + '),绝不允许删除') }
  if ($v.V -eq 'unknown') { return ('PROTECT:分区 ' + $N + ' 是 EFI 分区,但' + $v.Why + ';拒绝删除') }
  return ''
}
# 分区行显示:<号> <类型> <大小>MB@<偏移>MB <标签>(diff 的"前/后"两行共用,避免重复格式串)。
function Fmt-Row { param($r) return ('#' + $r.Number + ' ' + $r.Kind + ' ' + [math]::Round($r.SizeMB, 0) + 'MB@' + [math]::Round($r.OffsetMB, 0) + 'MB ' + $r.Label) }
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;diskpart 删除分区要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false } else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:diskpart 删除分区要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
$base = 'baseline'; if ($BaselineDir) { $base = $BaselineDir }
$pre = Assert-DbkFwPre -Base $base -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd)
$order0 = @((Get-DbkFwInfo -Text (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd)).Order)
# 目标必须显式给(-Partition 与/或 -PartitionGuid);本脚本绝不做"删除所有 Linux 分区"这类模糊操作。
$targets = @(); foreach ($n in @($Partition)) { if ([int]$n -gt 0) { $targets += [int]$n } }
$guids = @($PartitionGuid | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().Trim('{', '}').ToUpper() })
if ($targets.Count -eq 0 -and $guids.Count -eq 0) {
  Add-DbkCheck '失败项:没有显式给目标(-Partition 与 -PartitionGuid 至少给一个)'
  Write-DbkNote '拒绝:没有显式给目标(-Partition 与 -PartitionGuid 至少给一个);已零写(未执行任何命令)。'
  Write-DbkNote '示例(两块 Fedora 分区一并删除;ESP-Fedora 与 Windows ESP 同为 EFI System 类型,靠挂载探测 \EFI\Microsoft\ 拒掉 Windows ESP):'
  Write-DbkNote '  -Partition 5,6              # 5 = ESP-Fedora,6 = /boot(号按 baseline\02-partitions.txt 实测)'
  Write-DbkNote '  -PartitionGuid 1a2b3c4d-...  # 或按 GPT 分区 GUID 精确指定'
  exit $script:DBK_USAGE}
$before = Get-DbkTable
if (-not $before.Ok) { Add-DbkCheck ('失败项:' + $before.Error); Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $before.Error + ';无法核对目标,已零写') }
$rows = @($before.Rows)
$protect = @(); foreach ($n in @(([string]$env:DBK_PROTECT_NUMBERS) -split '[,\s]+' | Where-Object { $_ })) { $protect += [int]$n }
if (-not $env:DBK_PART_LAYOUT) {
  # C:/D: 的分区号是保护名单的一部分;解析不出来时不再静默吞错,改在 -Apply 时升为「需人工」。
  $protectErr = @()
  foreach ($c in @('C', 'D')) { try { $protect += [int](Get-Partition -DriveLetter $c -ErrorAction Stop).PartitionNumber } catch { $protectErr += ($c + ': ' + $_.Exception.Message) } }
  if ($protectErr.Count -gt 0 -and $Apply) { Add-DbkCheck ('需人工:系统盘分区号未能解析(' + ($protectErr -join '; ') + '):C:/D: 未进自动保护名单'); Write-DbkExit -Status 需人工 -Message ('无法解析系统盘分区号(' + ($protectErr -join '; ') + ');拒绝在保护名单不完整时删除分区(--apply 零写)') }
  foreach ($r in $rows) { if ($r.Kind -eq 'msr' -or $r.Kind -eq 'recovery') { $protect += [int]$r.Number } }
}
$notFound = @(); $prot = @()
foreach ($g in $guids) {
  $h = @($rows | Where-Object { $_.Guid -eq $g })
  if ($h.Count -eq 0) { $notFound += ('GUID ' + $g + ' 不在当前分区表里(可能已删过或写错)') } else { $targets += [int]$h[0].Number }
}
$targets = @($targets | Sort-Object -Unique)
foreach ($n in @($targets)) {
  $v = Get-DbkVerdict -N $n -Rows $rows -Protect $protect
  if ($v -like 'EXIST:*') { $notFound += $v.Substring(6) } elseif ($v) { $prot += $v.Substring(8) }
}
if ($notFound.Count -gt 0) {
  foreach ($n in $notFound) { Add-DbkCheck ('失败项:' + $n) }
  Write-DbkExit -Status FAIL -Message ('分区号/GUID 不存在:' + ($notFound -join ';') + ';已零写(未执行任何命令)。请按 baseline\02-partitions.txt 核对分区号/GUID 后重跑')
}
if ($prot.Count -gt 0) {
  foreach ($p in $prot) { Add-DbkCheck ('失败项:' + $p); Write-DbkNote ('拒绝删除:' + $p) }
  Write-DbkNote 'Windows ESP / C: / D: / MSR / WinRE 永远不是本脚本的目标(I1/I3);已零写(未执行任何命令)。'
  exit $script:DBK_USAGE
}
# 分区表 diff(执行前 / 计划执行后):只算,不写。
$keep = @($rows | Where-Object { $targets -notcontains [int]$_.Number } | Sort-Object { $_.OffsetMB })
Write-DbkNote '--- 分区表 diff(执行前 / 计划执行后)---'
foreach ($r in $rows) { Write-DbkNote ('  前 ' + (Fmt-Row $r)) }
foreach ($r in $keep) { Write-DbkNote ('  后 ' + (Fmt-Row $r)) }
Add-DbkCheck ('删除目标:' + (($targets | ForEach-Object { '#' + $_ }) -join ' ') + '(共 ' + $targets.Count + ' 个;Windows ESP/C:/D:/MSR/WinRE 已逐个校验拒删)')
$lines = @('select disk ' + $Disk)
foreach ($n in $targets) { $lines += ('select partition ' + $n); $lines += 'delete partition override' }
$lines += 'list partition'
Write-DbkNote ('将执行的 diskpart 命令(待核实(以官方文档为准)):' + [Environment]::NewLine + '  ' + ($lines -join ([Environment]::NewLine + '  ')))
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:未写 diskpart 脚本、未执行删除;确认分区表 diff 与目标无误后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('目标分区 ' + (($targets | ForEach-Object { '#' + $_ }) -join ',') + ' 校验通过(非 Windows ESP/C:/D:/MSR/WinRE);-Check 零写,计划删除后保留 ' + $keep.Count + ' 个分区')
}
$exe = 'diskpart'; if ($env:DBK_DISKPART_EXE) { $exe = $env:DBK_DISKPART_EXE }
$sf = [string]$env:DBK_DISKPART_SCRIPT
if (-not $sf) { $sf = Join-Path (Join-Path $env:TEMP 'dbk') 'delete-linux-partition.diskpart' }
$dir = Split-Path -Parent $sf; if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllLines($sf, [string[]]$lines)
Add-DbkAction ('diskpart 脚本已落盘:' + $sf)
$r = Invoke-DbkProbeExe -Exe $exe -CmdArgs @('/s', $sf)
Write-DbkNote ('diskpart 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
Write-DbkLog ('diskpart /s ' + $sf + ' 退出码 ' + $r.Code)
if ($r.Code -ne 0) {
  Add-DbkCheck ('失败项:diskpart 退出码 ' + $r.Code + ',输出:' + $r.Out)
  Write-DbkExit -Status FAIL -Message ('diskpart 执行失败(退出码 ' + $r.Code + '):' + $r.Out + ';分区表可能只删了一半,先人工核对再处理')
}
Set-DbkChanged
$after = Get-DbkTable -After
$bad = @()
if (-not $after.Ok) { $bad += ('复读:' + $after.Error) } else {
  foreach ($n in $targets) { if (@($after.Rows | Where-Object { [int]$_.Number -eq $n }).Count -gt 0) { $bad += ('复读:目标分区 ' + $n + ' 仍在(未被删除)') } }
  foreach ($r0 in $rows) {
    if ($targets -contains [int]$r0.Number) { continue }
    $h = @($after.Rows | Where-Object { [int]$_.Number -eq [int]$r0.Number })
    if ($h.Count -eq 0) { $bad += ('复读:非目标分区 ' + $r0.Number + ' 消失(只应删目标分区)') }
    elseif ([math]::Abs([double]$h[0].OffsetMB - $r0.OffsetMB) -gt 2 -or [math]::Abs([double]$h[0].SizeMB - $r0.SizeMB) -gt 2) { $bad += ('复读:分区 ' + $r0.Number + ' 的 offset/size 变了(不该动它)') }
  }
  $g0 = Get-DbkMaxGap -Rows $rows -DiskMB $before.DiskMB
  $g1 = Get-DbkMaxGap -Rows $after.Rows -DiskMB $after.DiskMB
  if ($g1 -le $g0) { $bad += ('复读:连续未分配空间没有新增(执行前 ' + [math]::Round($g0, 0) + 'MB,执行后 ' + [math]::Round($g1, 0) + 'MB)') }
  else { Add-DbkCheck ('复读通过:目标分区已消失,其余分区 offset/size 未变,最大连续未分配从 ' + [math]::Round($g0, 0) + 'MB 增到 ' + [math]::Round($g1, 0) + 'MB') }
}
$bad += @(Assert-DbkFwPost -BmPath $pre.BmPath -Order $order0 -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if ($bad.Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('diskpart 已执行,但后置复读不符(' + $bad.Count + ' 项,见 checks 与上面的复读值);分区表已改动、无法自动回退:先人工核对,再按 docs\07-rescue.md 的 `07-11` 卡处置')
}
Write-DbkExit -Status PASS -Message ('已删除分区 ' + (($targets | ForEach-Object { '#' + $_ }) -join ',') + ';目标消失、其余分区 offset/size 逐项未变、连续未分配空间新增;BootOrder 首位仍是 Windows Boot Manager、{bootmgr} path 未变')
