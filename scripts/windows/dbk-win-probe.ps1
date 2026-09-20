# 库文件:非步骤脚本
# 用途:轨道 W 的 Windows 侧只读探测公共实现:分区布局读数、templates/partitions.txt 目标值解析、连续未分配间隙、
#   系统版本/内部版本读数。被 scripts/windows/verify-windows-baseline.ps1 与 scripts/windows/collect-l1.ps1 dot-source。
# 契约:调用方必须先 dot-source dbk-cli.ps1(本库用 Write-DbkNote 与 $script:DBK_USAGE 报用法错误),并保持 $ErrorActionPreference='Stop'。
# 只读:本文件只定义函数,不主动执行动作、不写任何系统状态与文件。
# 夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT=<JSON>(形状见 check-partition-layout.ps1 的文件头);
#   DBK_WIN_VERSION=<文件,每行 key=value:caption/productname/displayversion/currentbuild/ubr>;
#   DBK_WIN_PROBE_FAIL=<原因文本> 让 Get-DbkPartsLayout 直接返回读不到(仅离线夹具,用来验证调用方的失败路径)。
# 已知限制:磁盘无分区表(partitionStyle=RAW)或读不到时返回 Ok=$false,由调用方判失败,本库不猜结论。
# 本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。

# Get-DbkPartsLayout [-Disk <编号>]:返回 @{ Ok; Rows(按偏移排序,含 Number/OffsetMB/SizeMB/Kind/Label); DiskMB; Reason }。
# Kind 取 efi|msr|basic|recovery|linux|unknown。
function Get-DbkPartsLayout {
  param([int]$Disk = 0)
  $rows = @(); $mb = 0
  if ($env:DBK_WIN_PROBE_FAIL) {
    return @{ Ok = $false; Rows = @(); DiskMB = 0; Reason = ('夹具强制失败:' + $env:DBK_WIN_PROBE_FAIL) }
  }
  if ($env:DBK_PART_LAYOUT) {
    if (-not (Test-Path -LiteralPath $env:DBK_PART_LAYOUT)) {
      Write-DbkNote ('用法错误: DBK_PART_LAYOUT 指向的文件不存在: ' + $env:DBK_PART_LAYOUT); exit $script:DBK_USAGE
    }
    try { $o = (Get-Content -LiteralPath $env:DBK_PART_LAYOUT -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-DbkNote ('用法错误: DBK_PART_LAYOUT 不是合法 JSON: ' + $_.Exception.Message); exit $script:DBK_USAGE }
    if ($o.disk) { $mb = [double]$o.disk.sizeMB }
    foreach ($q in @($o.partitions)) {
      if ($q) { $rows += @{ Number = [int]$q.number; OffsetMB = [double]$q.offsetMB; SizeMB = [double]$q.sizeMB; Kind = ([string]$q.kind).ToLower(); Label = [string]$q.name } }
    }
    return @{ Ok = $true; Rows = @($rows | Sort-Object { $_.OffsetMB }); DiskMB = $mb; Reason = '' }
  }
  if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
    return @{ Ok = $false; Rows = @(); DiskMB = 0; Reason = '本会话没有 Get-Partition(不是 Windows 存储环境)' }
  }
  $kinds = @{ 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' = 'efi'; 'e3c9e316-0b5c-4db8-817d-f92df00215ae' = 'msr'
              'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' = 'basic'; 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' = 'recovery'
              '0fc63daf-8483-4772-8e79-3d69d8477de4' = 'linux' }
  try {
    $mb = [double]((Get-Disk -Number $Disk -ErrorAction Stop).Size / 1MB)
    foreach ($p in @(Get-Partition -DiskNumber $Disk -ErrorAction Stop)) {
      $g = ([string]$p.GptType).Trim().ToLower(); $kind = 'unknown'
      if ($kinds.ContainsKey($g)) { $kind = $kinds[$g] }
      $label = ''
      try { $label = [string](Get-Volume -Partition $p -ErrorAction Stop).FileSystemLabel } catch { $label = '' }
      $rows += @{ Number = [int]$p.PartitionNumber; OffsetMB = [double]($p.Offset / 1MB); SizeMB = [double]($p.Size / 1MB); Kind = $kind; Label = $label }
    }
  } catch { return @{ Ok = $false; Rows = @(); DiskMB = $mb; Reason = ('分区表读不到:' + $_.Exception.Message + '(需要管理员权限)') } }
  return @{ Ok = $true; Rows = @($rows | Sort-Object { $_.OffsetMB }); DiskMB = $mb; Reason = '' }
}

# Get-DbkTargetLayout -Template <路径>:按模板里的 create partition 行取目标值(efi / msr / primary 顺序),返回 @{ Kind; SizeMB } 数组。
function Get-DbkTargetLayout {
  param([string]$Template = '')
  $rows = @()
  if (-not $Template -or -not (Test-Path -LiteralPath $Template)) { return $rows }
  foreach ($line in [System.IO.File]::ReadAllLines($Template, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*create partition\s+(efi|msr|primary)\s+size=([0-9]+)') {
      $k = $Matches[1].ToLower(); $kind = 'basic'
      if ($k -eq 'efi') { $kind = 'efi' } elseif ($k -eq 'msr') { $kind = 'msr' }
      $rows += @{ Kind = $kind; SizeMB = [double]$Matches[2] }
    }
  }
  return $rows
}

# Get-DbkMaxGapMB -Rows <布局行> -SizeMB <磁盘容量>:最大连续未分配间隙(MB)。WinRE 占盘尾,故不能拿"盘尾空隙"当判据。
function Get-DbkMaxGapMB {
  param($Rows, [double]$SizeMB)
  $gaps = @(); $prev = [double]0
  foreach ($p in @($Rows)) { if (($p.OffsetMB - $prev) -gt 1) { $gaps += ($p.OffsetMB - $prev) }; $prev = $p.OffsetMB + $p.SizeMB }
  if (($SizeMB - $prev) -gt 1) { $gaps += ($SizeMB - $prev) }
  if ($gaps.Count -eq 0) { return [double]0 }
  return [double](($gaps | Measure-Object -Maximum).Maximum)
}

# Get-DbkWinVersion:返回 @{ Caption; ProductName; DisplayVersion; CurrentBuild; UBR };夹具钩子优先,否则读 CIM 与注册表。
function Get-DbkWinVersion {
  $o = @{ Caption = ''; ProductName = ''; DisplayVersion = ''; CurrentBuild = ''; UBR = '' }
  if ($env:DBK_WIN_VERSION) {
    if (-not (Test-Path -LiteralPath $env:DBK_WIN_VERSION)) {
      Write-DbkNote ('用法错误: DBK_WIN_VERSION 指向的文件不存在: ' + $env:DBK_WIN_VERSION); exit $script:DBK_USAGE
    }
    foreach ($line in [System.IO.File]::ReadAllLines($env:DBK_WIN_VERSION, [System.Text.Encoding]::UTF8)) {
      if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') { $o[$Matches[1]] = $Matches[2].Trim() }
    }
    return $o
  }
  try { $o.Caption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $o.Caption = '' }
  $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  foreach ($n in @('ProductName', 'DisplayVersion', 'CurrentBuild', 'UBR')) {
    try { $o[$n] = [string]((Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n) } catch { $o[$n] = '' }
  }
  return $o
}
