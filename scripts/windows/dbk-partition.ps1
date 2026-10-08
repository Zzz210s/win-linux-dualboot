# 库文件:非步骤脚本
# 职责:07-11 退役删分区所需的分区表读取与保护判定(只出函数:不写盘、不执行外部命令、不做 diskpart 动作)。
# 契约(调用方 = scripts/windows/delete-linux-partition.ps1):
#   1) Get-DbkPartitionTable -Disk <int> [-After] -> @{ Ok; DiskMB; Rows; Error }
#        Rows[] = @{ Number; OffsetMB; SizeMB; Kind; Label; Guid }(按 OffsetMB 升序,Kind 小写,Guid 大写去花括号)。
#        夹具钩子 DBK_PART_LAYOUT / DBK_PART_LAYOUT_AFTER(JSON,结构同 check-partition-layout.ps1);JSON 非法或
#        文件不存在 -> 用法错误退 64(与拆分前一致);真机走 Get-Disk/Get-Partition,读不到 -> Ok=$false(调用方记需人工)。
#   2) Get-DbkMaxGap -Rows <Rows> -DiskMB <double> -> 最大连续未分配间隙 MB(间隔 <=2MB 不算)。
#   3) Get-DbkEspVerdict -N <int> -WinEspNumber <int> -> @{ V = 'win'|'other'|'unknown'; Why = '…' }
#        夹具 DBK_ESP_ROOT_<N>(探 <root>\EFI\Microsoft\)优先;其次人工声明的 -WinEspNumber / DBK_WIN_ESP_NUMBER;
#        都没有 -> 'unknown'(调用方据此拒删,绝不放行)。
#   4) Get-DbkVerdict -N <int> -Rows <Rows> -Protect <int[]> -> '' 可删 / 'EXIST:…' 不存在 / 'PROTECT:…' 禁删
#        (去掉前缀即原因文本)。MSR/恢复分区、保护名单(C:/D: 或 DBK_PROTECT_NUMBERS)、Windows ESP 一律拒删;
#        EFI 分区探测不到归属也拒删(无法证明"它不是 Windows ESP"就不删)。
#   5) Get-DbkProtectList -Rows <Rows> -> @{ Ok; Numbers; Error }
#        DBK_PROTECT_NUMBERS 直接给出就用它(不再并 MSR/恢复分区,与拆分前一致);否则解析 C:/D: 分区号再并入
#        MSR/恢复分区。DBK_NO_GETPARTITION=1 或 C:/D: 解析不出 -> Ok=$false(调用方记需人工,不按不完整名单判定)。
#   6) Format-DbkRow -Row <Row> -> 分区行文本「#<号> <类型> <大小>MB@<偏移>MB <标签>」(diff 前/后两行共用)。
# 本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。

# 分区表读数(只读;夹具走 DBK_PART_LAYOUT[_AFTER],真机走 Get-Disk/Get-Partition)。
function Get-DbkPartitionTable {
  param([int]$Disk = 0, [switch]$After)
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

# Windows ESP 判定(目标含 efi 分区时必需;无法证明"它不是 Windows ESP"一律拒删)。
function Get-DbkEspVerdict {
  param([int]$N, [int]$WinEspNumber = 0)
  $r = [string](Get-Item -Path ('Env:DBK_ESP_ROOT_' + $N) -ErrorAction SilentlyContinue).Value
  if ($r) { if (Test-Path -LiteralPath (Join-Path $r 'EFI\Microsoft')) { return @{ V = 'win'; Why = ($r + ' 下存在 \EFI\Microsoft\') } }; return @{ V = 'other'; Why = ($r + ' 下无 \EFI\Microsoft\') } }
  $w = $WinEspNumber; if ($w -le 0 -and $env:DBK_WIN_ESP_NUMBER) { $w = [int]$env:DBK_WIN_ESP_NUMBER }
  if ($w -gt 0) { if ($N -eq $w) { return @{ V = 'win'; Why = ('人工声明的 Windows ESP 分区号 ' + $w) } }; return @{ V = 'other'; Why = ('人工声明的 Windows ESP 分区号 ' + $w + '(该分区不是)') } }
  return @{ V = 'unknown'; Why = '无法把当前挂载的 ESP 映射到分区号;真机请先确认 Windows ESP 分区号并用 -WinEspNumber 指定' }
}

# 目标分区能不能删:空串 = 可删;'EXIST:…' = 不存在(-> 1 零写);'PROTECT:…' = 禁删(-> 64 零写)。
function Get-DbkVerdict {
  param([int]$N, $Rows, $Protect, [int]$WinEspNumber = 0)
  $hit = @($Rows | Where-Object { [int]$_.Number -eq $N })
  if ($hit.Count -eq 0) { return ('EXIST:分区 ' + $N + ' 不在当前分区表里(可能已删过或写错号)') }
  $r = $hit[0]
  if ($r.Kind -eq 'msr' -or $r.Kind -eq 'recovery') { return ('PROTECT:分区 ' + $N + ' 是系统保留/恢复分区(' + $r.Kind + '),绝不允许删除') }
  if ($Protect -contains $N) { return ('PROTECT:分区 ' + $N + ' 是 Windows 系统/数据盘(C:/D: 或 DBK_PROTECT_NUMBERS 判定),绝不允许删除') }
  if ($r.Kind -ne 'efi') { return '' }
  $v = Get-DbkEspVerdict -N $N -WinEspNumber $WinEspNumber
  if ($v.V -eq 'win') { return ('PROTECT:分区 ' + $N + ' 是 Windows ESP(' + $v.Why + '),绝不允许删除') }
  if ($v.V -eq 'unknown') { return ('PROTECT:分区 ' + $N + ' 是 EFI 分区,但' + $v.Why + ';拒绝删除') }
  return ''
}

# 保护名单:DBK_PROTECT_NUMBERS 优先;否则 C:/D: 分区号 + MSR/恢复分区;解析不全 -> Ok=$false。
function Get-DbkProtectList {
  param($Rows)
  $protect = @()
  $raw = [string]$env:DBK_PROTECT_NUMBERS
  if ($raw) { foreach ($n in @($raw -split '[,\s]+' | Where-Object { $_ })) { $protect += [int]$n }; return @{ Ok = $true; Numbers = @($protect); Error = '' } }
  $protectErr = @()
  foreach ($c in @('C', 'D')) {
    try {
      if ($env:DBK_NO_GETPARTITION) { throw '夹具钩子 DBK_NO_GETPARTITION 强制不可解析' }
      $protect += [int](Get-Partition -DriveLetter $c -ErrorAction Stop).PartitionNumber
    } catch { $protectErr += ($c + ': ' + $_.Exception.Message) }
  }
  if ($protectErr.Count -gt 0) { return @{ Ok = $false; Numbers = @(); Error = ($protectErr -join '; ') } }
  foreach ($r in @($Rows)) { if ($r.Kind -eq 'msr' -or $r.Kind -eq 'recovery') { $protect += [int]$r.Number } }
  return @{ Ok = $true; Numbers = @($protect); Error = '' }
}

# 分区行显示(大小/偏移四舍五入到 MB)。
function Format-DbkRow { param($Row) return ('#' + $Row.Number + ' ' + $Row.Kind + ' ' + [math]::Round($Row.SizeMB, 0) + 'MB@' + [math]::Round($Row.OffsetMB, 0) + 'MB ' + $Row.Label) }
