#Requires -Version 5.1
# 对应卡:07-11
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-11):按分区号或 GPT GUID 精确删除 Fedora 分区(两块 Fedora 分区可一并删)。
.DESCRIPTION
  只认显式目标:-Partition <int[]> 与/或 -PartitionGuid <string[]>(GUID 先在当前分区表里解析成分区号;都没给 -> 64 零写)。
  绝不做"删除所有 Linux 分区"这类模糊操作,也绝不用 diskpart clean / delete volume。**Windows ESP / C: / D: / MSR /
  WinRE 永远不是目标**:逐个校验(MSR/WinRE 按分区类型,C:/D: 按盘符,Windows ESP 用挂载探测 \EFI\Microsoft\ ——
  ESP-Fedora 与 Windows ESP 同为 EFI System 类型,必须靠显式分区号/GUID + 探测才能分开;无法映射时先用 -WinEspNumber 声明)。
  目标非法 -> 64 零写;目标不存在 -> 1 零写。分区表读取与保护判定在库 scripts\windows\dbk-partition.ps1;固件/BCD 枚举与
  断言在库 dbk-win-probe.ps1 —— 本脚本只做目标解析、diff、diskpart 写动作与后置复读。
  -Check(缺省)只打印分区表 diff(执行前 / 计划执行后);-Apply -Yes:生成 diskpart 脚本(select partition <N> +
  delete partition override)-> 执行 -> 复读断言:目标分区消失、其它分区 offset/size 逐项未变、最大连续未分配空间新增,
  且 BootOrder 首位仍是 Windows Boot Manager、{bootmgr} path 未变;任一不符 -> FAIL(1)并打印复读结果。
  前置断言(任一不满足 -> 64 零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  BootOrder 首位是 Windows Boot Manager;显式目标已确认。非管理员 -> 2(需人工);非 Windows -> 9(跳过)。
  用法示例(仓库根、管理员 Windows PowerShell;分区号按 baseline\02-partitions.txt 实测;5 = ESP-Fedora,6 = /boot,7 = Fedora root):
    ... -Check -Partition 5,6
    ... -Apply -Yes -Partition 5,6 -WinEspNumber 1    # 或 -PartitionGuid <GPT 分区 GUID>
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT / DBK_PART_LAYOUT_AFTER / DBK_PROTECT_NUMBERS / DBK_ESP_ROOT_<N> /
  DBK_WIN_ESP_NUMBER / DBK_DISKPART_EXE / DBK_DISKPART_SCRIPT / DBK_FW_TEXT[_AFTER] / DBK_BM_TEXT[_AFTER] /
  DBK_BCEDIT_EXE / DBK_IS_ADMIN=1。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:diskpart 的 select partition <N> 与 delete partition override。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。
  退出码:0 通过 / 1 失败(目标不存在或后置复读不符) / 2 需人工(非管理员或分区表读不到) / 9 跳过(非 Windows)/ 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [int]$Disk = 0, [int[]]$Partition = @(), [string[]]$PartitionGuid = @(),
  [int]$WinEspNumber = 0, [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sourceDir 'dbk-cli.ps1')
. (Join-Path $sourceDir 'dbk-win-probe.ps1')
. (Join-Path $sourceDir 'dbk-partition.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\delete-linux-partition.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'delete-linux-partition' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
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
  exit $script:DBK_USAGE
}
$before = Get-DbkPartitionTable -Disk $Disk
if (-not $before.Ok) { Add-DbkCheck ('失败项:' + $before.Error); Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $before.Error + ';无法核对目标,已零写') }
$rows = @($before.Rows)
$pl = Get-DbkProtectList -Rows $rows
# C:/D: 的分区号是保护名单的一部分;解析不出来时不再静默吞错,-Check 也升为「需人工」(读路径不给误导性 PASS)。
if (-not $pl.Ok) {
  Add-DbkCheck ('需人工:系统盘分区号未能解析(' + $pl.Error + '):C:/D: 未进自动保护名单')
  Write-DbkExit -Status 需人工 -Message ('无法解析系统盘分区号(' + $pl.Error + ');保护名单不完整(缺 C:/D:),拒绝按不完整的保护名单判定分区(本次零写)')
}
$protect = @($pl.Numbers)
$notFound = @(); $prot = @()
foreach ($g in $guids) {
  $h = @($rows | Where-Object { $_.Guid -eq $g })
  if ($h.Count -eq 0) { $notFound += ('GUID ' + $g + ' 不在当前分区表里(可能已删过或写错)') } else { $targets += [int]$h[0].Number }
}
$targets = @($targets | Sort-Object -Unique)
foreach ($n in @($targets)) {
  $v = Get-DbkVerdict -N $n -Rows $rows -Protect $protect -WinEspNumber $WinEspNumber
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
foreach ($r in $rows) { Write-DbkNote ('  前 ' + (Format-DbkRow -Row $r)) }
foreach ($r in $keep) { Write-DbkNote ('  后 ' + (Format-DbkRow -Row $r)) }
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
$after = Get-DbkPartitionTable -Disk $Disk -After
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
