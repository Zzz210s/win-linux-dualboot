#Requires -Version 5.1
# 对应卡:07-12
# 破坏性:1
<#
.SYNOPSIS
  L5 退役(07-12):把删除 Fedora 分区后腾出的未分配空间扩展给 **D:(不是 C:)**,执行后复读断言。
.DESCRIPTION
  前置断言(任一不满足 -> 64 且零写):-BaselineDir(缺省 baseline)下 02-partitions.txt 与 02-firmware-entries.txt 都在;
  BootOrder 首位是 Windows Boot Manager;待扩分区(D:)紧邻一段连续未分配空间(用分区表 offset/size 计算)。
  不紧邻时不硬扩:-Drive C 或"最大未分配段与 C: 相邻而不与 D: 相邻"-> 64 并给出"C: 与未分配空间不相邻、不可扩 /
  本卡只扩 D:"的结论;不紧邻的其它情况 -> 64,并提示在"磁盘管理"里人工扩展。
  -Check(缺省,零写)只做前置断言与计划打印;-Apply -Yes 生成 diskpart 脚本(select partition D -> extend)-> 执行
  -> 复读断言:D: 新末端 ≈ 该连续未分配段末端、D: 确实变大、起点未变、其它分区 offset/size 逐项未变、C: 未被扩,
  且 BootOrder 首位仍是 Windows Boot Manager、{bootmgr} path 未变;任一不符 -> FAIL(1)并打印复读结果。
  非管理员会话 -> 2(需人工);非 Windows -> 9(跳过)。
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT / DBK_PART_LAYOUT_AFTER(前/后分区表 JSON,结构同
  check-partition-layout.ps1)、DBK_DATA_NUMBER(D: 分区号)、DBK_C_NUMBER(C: 分区号)、DBK_DISKPART_EXE(假 diskpart)、
  DBK_DISKPART_SCRIPT(diskpart 脚本落盘路径)、DBK_FW_TEXT[_AFTER] / DBK_BM_TEXT[_AFTER] / DBK_BCEDIT_EXE /
  DBK_IS_ADMIN=1、DBK_CALLS。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:diskpart 的 select partition <N> 与 extend(无参数,扩到紧邻连续空间末端)。
  本文件 UTF-8 with BOM;夹具级验证,真机未跑。固件解析与断言在库 scripts/windows/dbk-win-probe.ps1 里。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\extend-data-partition.ps1 -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\extend-data-partition.ps1 -Apply -Yes
  退出码:0 通过 / 1 失败(后置复读不符) / 2 需人工(非管理员或分区表读不到) / 9 跳过(非 Windows) / 64 前置断言或用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [int]$Disk = 0, [string]$Drive = 'D', [string]$BaselineDir = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
# 库文件:固件/BCD 枚举与断言(本脚本只做分区计算与 diskpart 写动作)。
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\extend-data-partition.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'extend-data-partition' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
$script:DbkBcd = 'bcdedit'; if ($env:DBK_BCEDIT_EXE) { $script:DbkBcd = $env:DBK_BCEDIT_EXE }
# 分区表读数(只读):夹具用 DBK_PART_LAYOUT[_AFTER];真机用 Get-Disk/Get-Partition。行:Number/OffsetMB/SizeMB/Kind。
function Get-DbkTable {
  param([switch]$After)
  $f = [string]$env:DBK_PART_LAYOUT
  if ($After -and $env:DBK_PART_LAYOUT_AFTER) { $f = $env:DBK_PART_LAYOUT_AFTER }
  if ($f) {
    if (-not (Test-Path -LiteralPath $f)) { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 指向的文件不存在: ' + $f); exit $script:DBK_USAGE }
    try { $o = (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 不是合法 JSON: ' + $_.Exception.Message); exit $script:DBK_USAGE }
    $rows = @()
    foreach ($q in @($o.partitions)) { if ($q) { $rows += @{ Number = [int]$q.number; OffsetMB = [double]$q.offsetMB; SizeMB = [double]$q.sizeMB; Kind = ([string]$q.kind).ToLower() } } }
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
      $rows += @{ Number = [int]$p.PartitionNumber; OffsetMB = [double]($p.Offset / 1MB); SizeMB = [double]($p.Size / 1MB); Kind = $k }
    }
    return @{ Ok = $true; DiskMB = $mb; Rows = @($rows | Sort-Object { $_.OffsetMB }); Error = '' }
  } catch { return @{ Ok = $false; DiskMB = $mb; Rows = @(); Error = ('分区表读不到:' + $_.Exception.Message + '(需要管理员会话)') } }
}
# 连续未分配段(StartMB/SizeMB),按位置排序。
function Get-DbkGaps {
  param($Rows, [double]$DiskMB)
  $g = @(); $prev = [double]0
  foreach ($p in @($Rows | Sort-Object { $_.OffsetMB })) { if (($p.OffsetMB - $prev) -gt 2) { $g += @{ Start = $prev; Size = ($p.OffsetMB - $prev) } }; $prev = $p.OffsetMB + $p.SizeMB }
  if (($DiskMB - $prev) -gt 2) { $g += @{ Start = $prev; Size = ($DiskMB - $prev) } }
  return @($g)
}
function R0 { param([double]$V) return [math]::Round($V, 0) }
# 前置断言:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制;diskpart extend 要求管理员)。
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:diskpart extend 要求管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
$base = 'baseline'; if ($BaselineDir) { $base = $BaselineDir }
$pre = Assert-DbkFwPre -Base $base -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd)
$order0 = @((Get-DbkFwInfo -Text (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd)).Order)
# 目标只允许 D:(设计 07-12:把腾出的空间扩给 D:,不是 C:)
$want = ([string]$Drive).Trim().TrimEnd(':').ToUpper()
$before = Get-DbkTable
if (-not $before.Ok) { Add-DbkCheck ('失败项:' + $before.Error); Write-DbkExit -Status 需人工 -Message ('分区表读不到:' + $before.Error + ';无法计算相邻未分配空间,已零写') }
$rows = @($before.Rows)
$num = 0
if ($env:DBK_PART_LAYOUT) { if ($env:DBK_DATA_NUMBER) { $num = [int]$env:DBK_DATA_NUMBER } }
else { try { $num = [int](Get-Partition -DriveLetter $want -ErrorAction Stop).PartitionNumber } catch { $num = 0 } }
$cNum = 0
if ($env:DBK_PART_LAYOUT) { if ($env:DBK_C_NUMBER) { $cNum = [int]$env:DBK_C_NUMBER } }
else { try { $cNum = [int](Get-Partition -DriveLetter 'C' -ErrorAction Stop).PartitionNumber } catch { $cNum = 0 } }
$gaps = @(Get-DbkGaps -Rows $rows -DiskMB $before.DiskMB)
$tgt = @($rows | Where-Object { [int]$_.Number -eq $num })
$cRow = @($rows | Where-Object { [int]$_.Number -eq $cNum })
$cEnd = [double]0; if ($cRow.Count -gt 0) { $cEnd = $cRow[0].OffsetMB + $cRow[0].SizeMB }
$cAdj = $false; foreach ($g in $gaps) { if ($cNum -gt 0 -and [math]::Abs($g.Start - $cEnd) -le 2) { $cAdj = $true } }
if ($want -ne 'D' -or $num -le 0 -or $tgt.Count -eq 0) {
  if ($want -eq 'C') { Add-DbkCheck '失败项:C: 与未分配空间不相邻、不可扩(本卡只扩 D:)' } else { Add-DbkCheck ('失败项:找不到 ' + $want + ': 对应的分区(需要管理员会话;夹具用 DBK_DATA_NUMBER 注入)') }
  Write-DbkNote ('前置断言不满足:本卡(07-12)只扩 D:(不是 ' + $want + '),不硬扩;已零写。')
  if ($want -eq 'C') {
    if ($cAdj) { Write-DbkNote 'C: 与未分配空间相邻,但设计明确"扩 D: 而不是 C:";确有需要请在"磁盘管理"里人工扩展 C:。' }
    else { Write-DbkNote 'C: 与未分配空间不相邻、不可扩(定稿布局里未分配空间在 D: 之后)。' }
  }
  Write-DbkNote '已零写(未执行任何命令)。'
  exit $script:DBK_USAGE
}
$t = $tgt[0]
$tEnd = $t.OffsetMB + $t.SizeMB
$seg = $null
foreach ($g in $gaps) { if ([math]::Abs($g.Start - $tEnd) -le 2) { $seg = $g } }
if (-not $seg) {
  $mg = @($gaps | Sort-Object { $_.Size } -Descending)
  Add-DbkCheck ('失败项:D:(分区 ' + $num + ',结束于 ' + (R0 $tEnd) + 'MB)与未分配空间不相邻,不可扩')
  if ($cAdj) { Add-DbkCheck '失败项:C: 与未分配空间相邻,但本卡只扩 D:(不是 C:)' }
  Write-DbkNote ('前置断言不满足:D: 与未分配空间不相邻(D: 结束于 ' + (R0 $tEnd) + 'MB,后面没有连续未分配空间' + $(if ($gaps.Count -gt 0) { ',最大未分配段起于 ' + (R0 $mg[0].Start) + 'MB、大小 ' + (R0 $mg[0].Size) + 'MB' } else { ',也没有任何未分配空间' }) + '),不可硬扩。')
  Write-DbkNote '处置:在"磁盘管理"里人工扩展 D:(先确认没有别的分区挡在 D: 与未分配空间之间);或先人工移动分区。已零写。'
  exit $script:DBK_USAGE
}
Add-DbkCheck ('前置断言:D: 是分区 ' + $num + '(结束于 ' + (R0 $tEnd) + 'MB),紧邻未分配段 [' + (R0 $seg.Start) + ',' + (R0 ($seg.Start + $seg.Size)) + ')MB,可扩 ' + (R0 $seg.Size) + 'MB')
$lines = @('select disk ' + $Disk, 'select partition ' + $num, 'extend', 'list partition')
Write-DbkNote '将执行的 diskpart 命令(待核实(以官方文档为准)):'
foreach ($c in $lines) { Write-DbkNote ('  ' + $c) }
Write-DbkNote '说明:本卡只扩 D:,不碰 C:;其它分区的 offset/size 执行后逐项复读比对。'
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 零写:未写 diskpart 脚本、未执行扩展;确认后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('D:(分区 ' + $num + ')紧邻 ' + (R0 $seg.Size) + 'MB 未分配空间,可扩到 ' + (R0 ($seg.Start + $seg.Size)) + 'MB;-Check 零写,不改动任何分区')
}
$exe = 'diskpart'; if ($env:DBK_DISKPART_EXE) { $exe = $env:DBK_DISKPART_EXE }
$sf = [string]$env:DBK_DISKPART_SCRIPT
if (-not $sf) { $sf = Join-Path (Join-Path $env:TEMP 'dbk') 'extend-data-partition.diskpart' }
$dir = Split-Path -Parent $sf; if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllLines($sf, [string[]]$lines)
Add-DbkAction ('diskpart 脚本已落盘:' + $sf)
$r = Invoke-DbkProbeExe -Exe $exe -CmdArgs @('/s', $sf)
Write-DbkNote ('diskpart 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
Write-DbkLog ('diskpart /s ' + $sf + ' 退出码 ' + $r.Code)
if ($r.Code -ne 0) {
  Add-DbkCheck ('失败项:diskpart 退出码 ' + $r.Code + ',输出:' + $r.Out)
  Write-DbkExit -Status FAIL -Message ('diskpart 执行失败(退出码 ' + $r.Code + '):' + $r.Out + ';分区表未按计划扩展,先人工核对再处理')
}
Set-DbkChanged
$after = Get-DbkTable -After
$bad = @()
if (-not $after.Ok) { $bad += ('复读:' + $after.Error) } else {
  $t2 = @($after.Rows | Where-Object { [int]$_.Number -eq $num })
  if ($t2.Count -eq 0) { $bad += ('复读:D:(分区 ' + $num + ')不见了') } else {
    $newEnd = $t2[0].OffsetMB + $t2[0].SizeMB
    Write-DbkNote ('复读:D: 新末端 ' + (R0 $newEnd) + 'MB(执行前 ' + (R0 $tEnd) + 'MB;该未分配段末端 ' + (R0 ($seg.Start + $seg.Size)) + 'MB)')
    if ([math]::Abs($newEnd - ($seg.Start + $seg.Size)) -gt 4) { $bad += ('复读:D: 新末端 ' + (R0 $newEnd) + 'MB 与该未分配段末端 ' + (R0 ($seg.Start + $seg.Size)) + 'MB 不符') }
    if ($t2[0].SizeMB -le $t.SizeMB + 1) { $bad += ('复读:D: 没有变大(执行前 ' + (R0 $t.SizeMB) + 'MB,执行后 ' + (R0 $t2[0].SizeMB) + 'MB)') }
    if ([math]::Abs($t2[0].OffsetMB - $t.OffsetMB) -gt 2) { $bad += ('复读:D: 的起点变了(执行前 ' + (R0 $t.OffsetMB) + 'MB,执行后 ' + (R0 $t2[0].OffsetMB) + 'MB)') }
    else { Add-DbkCheck ('复读通过:D: 起点未变,容量 ' + (R0 $t.SizeMB) + 'MB -> ' + (R0 $t2[0].SizeMB) + 'MB') }
  }
  foreach ($r0 in $rows) {
    if ([int]$r0.Number -eq $num) { continue }
    $h = @($after.Rows | Where-Object { [int]$_.Number -eq [int]$r0.Number })
    if ($h.Count -eq 0) { $bad += ('复读:其它分区 ' + $r0.Number + ' 消失(只应扩 D:)') }
    elseif ([math]::Abs([double]$h[0].OffsetMB - $r0.OffsetMB) -gt 2 -or [math]::Abs([double]$h[0].SizeMB - $r0.SizeMB) -gt 2) { $bad += ('复读:其它分区 ' + $r0.Number + ' 的 offset/size 变了(不该动它)') }
  }
  $c2 = @($after.Rows | Where-Object { [int]$_.Number -eq $cNum })
  if ($cNum -gt 0 -and $cRow.Count -gt 0 -and $c2.Count -gt 0 -and [math]::Abs([double]$c2[0].SizeMB - $cRow[0].SizeMB) -gt 2) { $bad += ('复读:C: 被扩了(执行前 ' + (R0 $cRow[0].SizeMB) + 'MB,执行后 ' + (R0 $c2[0].SizeMB) + 'MB);本卡只扩 D:') }
  else { Add-DbkCheck '复读通过:其它分区 offset/size 逐项未变,C: 未被扩' }
}
$bad += @(Assert-DbkFwPost -BmPath $pre.BmPath -Order $order0 -FwText (Get-DbkFwEnum -What firmware -Exe $script:DbkBcd -After) -BmText (Get-DbkFwEnum -What '{bootmgr}' -Exe $script:DbkBcd -After))
if (@($bad).Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('diskpart 已执行,但后置复读不符(' + @($bad).Count + ' 项,见 checks 与上面的复读值);先人工核对磁盘管理与 bcdedit /enum firmware,再按 docs\07-rescue.md 的 `07-12` 卡处置')
}
Write-DbkExit -Status PASS -Message ('已把紧邻 D: 的 ' + (R0 $seg.Size) + 'MB 未分配空间扩给 D:(分区 ' + $num + ');其它分区 offset/size 逐项未变、C: 未被扩;BootOrder 首位仍是 Windows Boot Manager、{bootmgr} path 未变')
