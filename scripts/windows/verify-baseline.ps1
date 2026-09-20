#Requires -Version 5.1
<#
.SYNOPSIS
  L4 周期性巡检(只读):核对 L2 基线是否被改动,输出"巡检通过 / 需人工介入"。
.DESCRIPTION
  依据设计文档 7.1 与不变量 I1/I3,核对四项:① BootOrder 首位是否仍是 Windows Boot Manager(比对 02-firmware-entries.txt);
  ② 挂载 ESP 后对 \EFI\Microsoft\ 逐文件比对 02-esp-backup\manifest.sha256(清单格式见 backup-esp.ps1);
  ③ {bootmgr} 的 path 是否与基线一致;④ BitLocker 状态是否与 02-preflight-report.md 的记录一致(变化即提示人工介入)。
  **只读**:不修改任何内容(挂载 ESP 只为读取,收尾必然卸载);唯一输出是控制台文本。
  本文件必须保存为 UTF-8 with BOM(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码,中文会解析失败)。
  用法(仓库根目录、以管理员身份运行 Windows PowerShell;多设备时 -BaselineDir 指到 baseline\<设备别名>):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
  退出码:0 = 四项全部通过;1 = 需人工介入(含读不到基线或读不到现场状态)。
#>
[CmdletBinding()]
param(
  [string]$BaselineDir = 'baseline',
  [string]$EspLetter = ''
)

$ErrorActionPreference = 'Stop'
$WBM = 'Windows Boot Manager|Windows 启动管理器'
$results = @()

function Add-Result {
  param([string]$Item, [bool]$Ok, [string]$Detail)
  $d = ((([string]$Detail) -replace "`r?`n", ' ') -replace '\s+', ' ').Trim()
  if ($d.Length -gt 400) { $d = $d.Substring(0, 400) + ' ...' }
  $script:results += [pscustomobject]@{ Item = $Item; Ok = $Ok; Detail = $d }
}

function Get-FirmwareText {
  # 只读枚举:失败(非管理员 / 非 UEFI / 无 bcdedit)返回 $null,由调用方给中文提示
  $out = $null
  try { $out = (& bcdedit /enum firmware 2>&1 | Out-String) } catch { return $null }
  if ($LASTEXITCODE -ne 0 -or -not $out -or $out.Trim().Length -eq 0) { return $null }
  if ($out -match '拒绝访问|Access is denied') { return $null }
  return $out
}

function Get-BootOrderGuids {
  # displayorder 的值可能跨行:取第一行与后续"只含 GUID"的续行,遇到不含 GUID 的行即结束
  param([string]$Text)
  $guids = @(); $inOrder = $false
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*(displayorder|显示顺序|启动顺序)\s*(.*)$') {
      $inOrder = $true
      foreach ($g in [regex]::Matches($Matches[2], '\{[^}]+\}')) { $guids += $g.Value }
      continue
    }
    if (-not $inOrder) { continue }
    $gs = @([regex]::Matches($line, '\{[^}]+\}'))
    if ($gs.Count -eq 0) { $inOrder = $false; continue }
    foreach ($g in $gs) { $guids += $g.Value }
  }
  return $guids
}

function Get-PathLine {
  param([string]$Text)
  foreach ($l in ($Text -split "`r?`n")) { if ($l -match '^\s*(path|路径)\s+(\S.*?)\s*$') { return $Matches[2] } }
  return ''
}

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false }

# 基线产物:固件启动项快照(①③)、ESP 清单(②)、L2 预检报告(④)
$baseFwPath = Join-Path $BaselineDir '02-firmware-entries.txt'
$baseFw = ''
if (Test-Path -LiteralPath $baseFwPath) { $baseFw = Get-Content -LiteralPath $baseFwPath -Raw -Encoding UTF8 }
$baseOrder = @(Get-BootOrderGuids $baseFw)
$baseFirst = ''
if ($baseOrder.Count -gt 0) { $baseFirst = $baseOrder[0] }
$fw = Get-FirmwareText
$order = @()
if ($fw) { $order = @(Get-BootOrderGuids $fw) }

# ① BootOrder 首位
if (-not $fw) { Add-Result '① BootOrder 首位' $false '读不到固件启动条目(bcdedit /enum firmware 失败:需管理员权限或非 UEFI 启动),无法核对' }
elseif ($order.Count -eq 0) { Add-Result '① BootOrder 首位' $false '固件条目里解析不到 displayorder 行,无法核对' }
else {
  $first = $order[0]; $fd = ''; $cur = ''
  foreach ($line in ($fw -split "`r?`n")) {
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') { $cur = $Matches[2]; $fd = ''; continue }
    if ($cur -eq $first -and $line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { $fd = $Matches[2] }
  }
  $ok = ($first -eq '{bootmgr}' -or $fd -match $WBM)
  $d = '当前首位 ' + $first + ' ' + $fd
  if (-not $baseFirst) { $d += ';基线 ' + $baseFwPath + ' 取不到首位(无法比对,按人工核对)'; $ok = $false }
  elseif ($baseFirst -eq $first) { $d += ';与基线一致' }
  else { $d += ';基线首位为 ' + $baseFirst + '(不一致)'; $ok = $false }
  Add-Result '① BootOrder 首位' $ok ($d + ';判据:首位必须是 Windows Boot Manager(I1)')
}

# ② ESP \EFI\Microsoft\ 逐文件比对
$man = Join-Path $BaselineDir '02-esp-backup\manifest.sha256'
$want = @{}; $diff = @(); $espErr = ''
if (-not (Test-Path -LiteralPath $man)) { Add-Result '② ESP\EFI\Microsoft\ 比对' $false ('缺基线清单 ' + $man + ';先跑 scripts\windows\backup-esp.ps1 生成 L2 基线') }
elseif (-not $isAdmin) { Add-Result '② ESP\EFI\Microsoft\ 比对' $false '非管理员会话,无法挂载 ESP 做逐文件比对(mountvol /s 需要管理员)' }
else {
  $mp = ''; $mounted = $false
  try {
    if ($EspLetter) { $mp = ($EspLetter.TrimEnd(':') + ':') }
    else { foreach ($c in @('S', 'T', 'U', 'V', 'W')) { if (-not (Test-Path -LiteralPath ($c + ':\'))) { $mp = ($c + ':'); break } } }
    if (-not $mp) { throw '找不到空闲盘符,请用 -EspLetter 指定' }
    if (-not (Test-Path -LiteralPath ($mp + '\'))) {
      $null = (& mountvol $mp /s 2>&1); $mounted = $true
      if (-not (Test-Path -LiteralPath ($mp + '\EFI'))) { throw ('挂载 ' + $mp + ' 后看不到 \EFI,可能不是 ESP') }
    }
    $espRoot = $mp + '\'
    foreach ($line in (Get-Content -LiteralPath $man -Encoding UTF8)) {
      if ($line -match '^([0-9A-Fa-f]{64})\s+(EFI/Microsoft/.+?)\s*$') { $want[$Matches[2]] = $Matches[1].ToUpper() }
    }
    foreach ($rel in ($want.Keys | Sort-Object)) {
      $fp = Join-Path $espRoot ($rel.Replace('/', '\'))
      if (-not (Test-Path -LiteralPath $fp)) { $diff += ('缺失 ' + $rel); continue }
      if ((Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash -ne $want[$rel]) { $diff += ('哈希不一致 ' + $rel) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $espRoot 'EFI\Microsoft') -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($espRoot.Length).Replace('\', '/')
      if (-not $want.ContainsKey($rel)) { $diff += ('新增 ' + $rel) }
    }
  } catch { $espErr = $_.Exception.Message } finally {
    if ($mounted -and $mp) { $null = (& mountvol $mp /d 2>&1) }
  }
  if ($espErr) { Add-Result '② ESP\EFI\Microsoft\ 比对' $false ('ESP 比对失败:' + $espErr) }
  elseif ($want.Count -eq 0) { Add-Result '② ESP\EFI\Microsoft\ 比对' $false ('基线清单里没有 EFI/Microsoft/ 条目,清单可能不完整:' + $man) }
  elseif ($diff.Count -eq 0) { Add-Result '② ESP\EFI\Microsoft\ 比对' $true ('\EFI\Microsoft\ 下 ' + $want.Count + ' 个文件与基线逐文件一致;ESP 上无新增文件') }
  else { Add-Result '② ESP\EFI\Microsoft\ 比对' $false ('差异 ' + $diff.Count + ' 项(共比对 ' + $want.Count + ' 项):' + (($diff | Select-Object -First 10) -join '; ')) }
}

# ③ {bootmgr} 的 path
$bmText = ''; $rc = 1
try { $bmText = (& bcdedit /enum '{bootmgr}' 2>&1 | Out-String); $rc = $LASTEXITCODE } catch { $rc = 1 }
$curPath = ''; if ($rc -eq 0) { $curPath = Get-PathLine $bmText }
$basePath = ''
if ($baseFw) { $i = $baseFw.IndexOf('==== bcdedit /enum {bootmgr} ===='); if ($i -ge 0) { $basePath = Get-PathLine $baseFw.Substring($i) } }
if (-not $curPath) { Add-Result '③ {bootmgr} 的 path' $false '读不到当前 {bootmgr} 的 path(需管理员权限或非 UEFI 启动)' }
elseif (-not $basePath) { Add-Result '③ {bootmgr} 的 path' $false ('当前 path = ' + $curPath + ';基线里取不到 path,无法比对(按人工核对)') }
elseif ($curPath.ToLower() -eq $basePath.ToLower()) { Add-Result '③ {bootmgr} 的 path' $true ('当前与基线一致:' + $curPath) }
else { Add-Result '③ {bootmgr} 的 path' $false ('与基线不一致:当前 ' + $curPath + ';基线 ' + $basePath + '(I3:绝不允许第三方改动 {bootmgr} 的 path)') }

# ④ BitLocker 状态
$baseBl = ''
$repPath = Join-Path $BaselineDir '02-preflight-report.md'
if (Test-Path -LiteralPath $repPath) {
  $m = [regex]::Match((Get-Content -LiteralPath $repPath -Raw -Encoding UTF8), '(?m)^\|\s*BitLocker 保护状态\s*\|([^|\r\n]*)\|')
  if ($m.Success) { $baseBl = $m.Groups[1].Value.Trim() }
}
$curBl = ''
try {
  $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
  $curBl = 'ProtectionStatus=' + [string]$blv.ProtectionStatus + '; VolumeStatus=' + [string]$blv.VolumeStatus
} catch {
  try { $curBl = ((& manage-bde -status $env:SystemDrive 2>&1 | Out-String) -replace "`r?`n", ' ').Trim() } catch { $curBl = '' }
}
$curState = ''; $baseState = ''
if ($curBl -match 'ProtectionStatus=On|保护已开启|保护已打开|保护: 已打开|Protection On') { $curState = 'On' } elseif ($curBl -match 'FullyEncrypted|完全加密|保护已关闭|保护已暂停|保护关闭|Protection Off') { $curState = 'Off+FullyEncrypted' } elseif ($curBl -match 'ProtectionStatus=Off|未加密|未启用|FullyDecrypted') { $curState = 'Off' }
if ($baseBl -match 'ProtectionStatus=On|保护已开启|保护已打开|保护: 已打开|Protection On') { $baseState = 'On' } elseif ($baseBl -match 'FullyEncrypted|完全加密|保护已关闭|保护已暂停|保护关闭|Protection Off') { $baseState = 'Off+FullyEncrypted' } elseif ($baseBl -match 'ProtectionStatus=Off|未加密|未启用|FullyDecrypted') { $baseState = 'Off' }
if (-not $curState) { Add-Result '④ BitLocker 状态' $false ('读不到当前 BitLocker 状态(需管理员权限):' + $curBl) }
elseif (-not $baseState) { Add-Result '④ BitLocker 状态' $false ('当前 ' + $curBl + ';基线报告里取不到 BitLocker 状态,无法比对:' + $repPath) }
elseif ($curState -eq $baseState) { Add-Result '④ BitLocker 状态' $true ('与基线一致:基线"' + $baseBl + '";当前 ' + $curBl) }
else { Add-Result '④ BitLocker 状态' $false ('发生变化(提示人工确认):基线"' + $baseBl + '"->当前 ' + $curBl + ';若确有变更,须重做 L2 基线') }

# 结论
Write-Host 'L2 基线巡检(只读;不修改系统任何设置,ESP 只在比对期间临时挂载并卸载)'
Write-Host ('基线目录:' + [System.IO.Path]::GetFullPath($BaselineDir))
foreach ($r in $results) { Write-Host ($r.Item + ' -> ' + $(if ($r.Ok) { '通过' } else { '需人工介入' }) + ':' + $r.Detail) }
$bad = @($results | Where-Object { -not $_.Ok })
if ($bad.Count -eq 0) {
  Write-Host '巡检通过:四项与 L2 基线一致(BootOrder 首位、ESP\EFI\Microsoft\ 文件哈希、{bootmgr} path、BitLocker 状态)。'
  exit 0
}
Write-Host ('需人工介入:' + $bad.Count + ' 项 —— ' + (($bad | ForEach-Object { $_.Item }) -join '、'))
Write-Host '处置:按 docs/03-windows.md 的 03-6(preflight.ps1)与 baseline/README.md 核对;确认改动属实且必要后,重做 L2 基线(backup-esp.ps1 + preflight.ps1)再继续。'
exit 1
