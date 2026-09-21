# 库文件:非步骤脚本
# 用途:轨道 W 与 L5 退役卡共用的 Windows 侧只读探测公共实现:分区布局读数、templates/partitions.txt 目标值解析、
#   连续未分配间隙、系统版本/内部版本读数,以及固件/BCD 枚举文本的读取与解析(Get-DbkFwEnum / Get-DbkFwInfo /
#   Get-DbkFwEntries)与两条断言(Assert-DbkFwPre / Assert-DbkFwPost:基线产物齐全 + BootOrder 首位 =
#   Windows Boot Manager + {bootmgr} path 未变)。被 scripts/windows/verify-windows-baseline.ps1、collect-l1.ps1
#   与 07-9…07-13 五张退役卡(restore-boot-order / delete-linux-partition / cleanup-nvram / extend-data-partition /
#   disable-linux-entry)dot-source;断言函数失败时按契约退 64(零写),写动作只在调用方的 -Apply 路径里。
# 契约:调用方必须先 dot-source dbk-cli.ps1(本库用 Write-DbkNote 与 $script:DBK_USAGE 报用法错误),并保持 $ErrorActionPreference='Stop'。
# 只读:本文件只定义函数,不主动执行动作、不写任何系统状态与文件。
# 夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT=<JSON>(形状见 check-partition-layout.ps1 的文件头);
#   DBK_WIN_VERSION=<文件,每行 key=value:caption/productname/displayversion/currentbuild/ubr>;
#   DBK_WIN_PROBE_FAIL=<原因文本> 让 Get-DbkPartsLayout 直接返回读不到(仅离线夹具,用来验证调用方的失败路径);
#   DBK_FW_TEXT / DBK_FW_TEXT_AFTER=<文件> 替代 bcdedit /enum firmware 的执行前/后文本;
#   DBK_BM_TEXT / DBK_BM_TEXT_AFTER=<文件> 替代 bcdedit /enum {bootmgr} 的执行前/后文本(以上四个只被固件函数使用)。
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

# ==== 固件/BCD 枚举共享实现(07-9…07-13 五张退役卡用;全部只读)=================================================
# Invoke-DbkProbeExe -Exe <可执行文件> -CmdArgs <参数数组>:合并 stdout/stderr(不吞 stderr)并返回 @{ Out; Code }。
function Invoke-DbkProbeExe {
  param([string]$Exe, [string[]]$CmdArgs = @())
  $o = ''; $c = 1
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = [string](& $Exe @CmdArgs 2>&1 | Out-String); $c = [int]$LASTEXITCODE } catch { $o = [string]$_.Exception.Message; $c = 1 }
  $ErrorActionPreference = $prev
  return @{ Out = $o.Trim(); Code = $c }
}
# Get-DbkFwEnum -What firmware|bootmgr -Exe <bcdedit 或假 exe> [-After]:夹具注入文件优先(DBK_FW_TEXT[_AFTER] /
#   DBK_BM_TEXT[_AFTER]),否则调 -Exe /enum <What> 并把退出码写日志;读不到返回空串(由调用方判失败退出码)。
function Get-DbkFwEnum {
  param([string]$What = 'firmware', [string]$Exe = 'bcdedit', [switch]$After)
  $f = ''
  if ($What -eq 'firmware') { if ($After) { $f = [string]$env:DBK_FW_TEXT_AFTER } else { $f = [string]$env:DBK_FW_TEXT } }
  else { if ($After) { $f = [string]$env:DBK_BM_TEXT_AFTER } else { $f = [string]$env:DBK_BM_TEXT } }
  if ($f) {
    if (-not (Test-Path -LiteralPath $f)) { Write-DbkNote ('用法错误: 注入文件不存在: ' + $f); exit $script:DBK_USAGE }
    return (Get-Content -LiteralPath $f -Raw -Encoding UTF8)
  }
  $r = Invoke-DbkProbeExe -Exe $Exe -CmdArgs @('/enum', $What)
  Write-DbkLog ('bcdedit /enum ' + $What + ' 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "\r?\n", ' | '))
  if ($r.Code -ne 0) { return '' }
  return $r.Out
}
# Get-DbkFwInfo -Text <枚举文本>:displayorder/显示顺序 -> Order;identifier/标识符 起块;description/描述 -> Desc;path/路径 取首条。
function Get-DbkFwInfo {
  param([string]$Text = '')
  $order = @(); $desc = @{}; $path = ''; $inOrder = $false; $cur = ''
  foreach ($line in ($Text -split "\r?\n")) {
    if ($line -match '^\s*(displayorder|显示顺序|启动顺序)\s*(.*)$') { $inOrder = $true; foreach ($g in [regex]::Matches($Matches[2], '\{[^}]+\}')) { $order += $g.Value }; continue }
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') { $cur = $Matches[2]; $inOrder = $false; continue }
    if ($line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { if ($cur -and -not $desc.ContainsKey($cur)) { $desc[$cur] = $Matches[2] }; continue }
    if ($line -match '^\s*(path|路径)\s+(\S.*?)\s*$') { if (-not $path) { $path = $Matches[2] }; continue }
    if ($inOrder) { if ($line -match '^\s+(\{[^}]+\}\s*)+$') { foreach ($g in [regex]::Matches($line, '\{[^}]+\}')) { $order += $g.Value } } else { $inOrder = $false } }
  }
  return @{ Order = @($order); Desc = $desc; Path = $path }
}
# Get-DbkFwEntries -Text <枚举文本>:逐条 identifier/标识符 起块 -> @{ Guid; Desc; Path }(每条各取首个字段)。
function Get-DbkFwEntries {
  param([string]$Text = '')
  $e = @(); $cur = $null
  foreach ($line in ($Text -split "\r?\n")) {
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') { if ($cur) { $e += $cur }; $cur = @{ Guid = $Matches[2]; Desc = ''; Path = '' }; continue }
    if (-not $cur) { continue }
    if ($line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { if (-not $cur.Desc) { $cur.Desc = $Matches[2] }; continue }
    if ($line -match '^\s*(path|路径)\s+(\S.*?)\s*$') { if (-not $cur.Path) { $cur.Path = $Matches[2] } }
  }
  if ($cur) { $e += $cur }
  return @($e)
}
$script:DbkProbeWbm = 'Windows Boot Manager|Windows 启动管理器'
# Assert-DbkFwPre -Base <基线目录> [-SkipOrderCheck] -FwText -BmText:前置断言(-BaselineDir 缺省 baseline 下
#   02-partitions.txt 与 02-firmware-entries.txt 都在、BootOrder 首位是 Windows Boot Manager、{bootmgr} path 可读);
#   任一不满足 -> 逐个登记失败项并退 64(零写)。-SkipOrderCheck 供"顺序本身就是本卡判据"的脚本(它要报 1)。
#   返回 @{ First; BmPath }(调用方拿去给 Assert-DbkFwPost 比对)。
function Assert-DbkFwPre {
  param([string]$Base = 'baseline', [switch]$SkipOrderCheck, [string]$FwText = '', [string]$BmText = '')
  $bad = @()
  foreach ($n in @('02-partitions.txt', '02-firmware-entries.txt')) { if (-not (Test-Path -LiteralPath (Join-Path $Base $n))) { $bad += ('基线产物缺失:' + (Join-Path $Base $n)) } }
  $fi = Get-DbkFwInfo -Text $FwText
  $first = ''; if (@($fi.Order).Count -gt 0) { $first = $fi.Order[0] }
  if (-not $first) { $bad += '读不到 BootOrder(固件枚举失败:需管理员会话或不是 UEFI 启动)' }
  elseif (-not $SkipOrderCheck) {
    $fd = ''; if ($fi.Desc.ContainsKey($first)) { $fd = [string]$fi.Desc[$first] }
    if (-not ($first -eq '{bootmgr}' -or $fd -match $script:DbkProbeWbm)) { $bad += ('BootOrder 首位不是 Windows Boot Manager(实际 ' + $first + ' ' + $fd + ');I1 要求首位永远是 Windows Boot Manager') }
  }
  $bm = (Get-DbkFwInfo -Text $BmText).Path
  if (-not $bm) { $bad += '读不到 {bootmgr} 的 path' }
  if (@($bad).Count -gt 0) {
    Write-DbkNote ('前置断言不满足 ' + @($bad).Count + ' 项(零写:未做任何改动):')
    foreach ($b in @($bad)) { Write-DbkNote ('  - ' + $b); Add-DbkCheck ('失败项:' + $b) }
    Write-DbkNote '先补齐基线(baseline/README.md)或回固件设置界面处理顺序,再重跑本脚本。'
    exit $script:DBK_USAGE
  }
  Add-DbkCheck ('前置断言:基线产物齐全(' + $Base + ');BootOrder 首位 ' + $first + ';{bootmgr} path ' + $bm)
  return @{ First = $first; BmPath = $bm }
}
# Assert-DbkFwPost -BmPath <执行前 path> -Order <执行前 BootOrder> -FwText -BmText:后置复读断言 ① BootOrder 逐字未变
#   (给了 -Order 时)② 首位仍是 Windows Boot Manager ③ {bootmgr} path 未变。返回失败项数组(并打印复读值);
#   失败项由调用方登记进 checks[](库不替调用方写 checks,否则同一失败会被登记两次)。
function Assert-DbkFwPost {
  param([string]$BmPath = '', [string[]]$Order = @(), [string]$FwText = '', [string]$BmText = '')
  $bad = @(); $fi = Get-DbkFwInfo -Text $FwText; $o2 = @($fi.Order); $p2 = (Get-DbkFwInfo -Text $BmText).Path
  Write-DbkNote ('复读 BootOrder:' + ($o2 -join ' ') + ';{bootmgr} path:' + $p2)
  if ($o2.Count -eq 0) { $bad += '复读:解析不到 BootOrder' }
  elseif (@($Order).Count -gt 0 -and ($o2 -join ' ') -ne (@($Order) -join ' ')) { $bad += ('复读:BootOrder 被执行改动(执行前 ' + (@($Order) -join ' ') + ';执行后 ' + ($o2 -join ' ') + ')') }
  $f2 = ''; if ($o2.Count -gt 0) { $f2 = $o2[0] }
  $d2 = ''; if ($f2 -and $fi.Desc.ContainsKey($f2)) { $d2 = [string]$fi.Desc[$f2] }
  if (-not ($f2 -eq '{bootmgr}' -or $d2 -match $script:DbkProbeWbm)) { $bad += ('复读:BootOrder 首位不是 Windows Boot Manager(实际 ' + $f2 + ' ' + $d2 + ')') }
  if ($p2 -ne $BmPath) { $bad += ('复读:{bootmgr} 的 path 变了(执行前 ' + $BmPath + ';执行后 ' + $p2 + ');I3 绝不允许') }
  return @($bad)
}
