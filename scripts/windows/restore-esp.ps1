#Requires -Version 5.1
# 对应卡:07-6
# 破坏性:1
<#
.SYNOPSIS
  轨道 D 救援(07-6):从 L2 基线 baseline\02-esp-backup 复原 Windows ESP 上的 \EFI\Microsoft\(逐文件比对 manifest.sha256)。
.DESCRIPTION
  用途(设计 4.8 第三选择的一半):ESP 被格式化/污染后,用 L2 基线里的 ESP 备份把 Windows 引导文件放回去。
  前置断言(任一不满足 -> 64 且零写):-BaselineDir(缺省 baseline)下 02-esp-backup\manifest.sha256 存在且非空;清单里有
  EFI/Microsoft/ 条目;**备份树自身**先校验(逐条 Get-FileHash 与清单比对 + 检查清单外文件);ESP 盘符可用(-EspLetter
  指定或自动挑 S/T/U/V/W 中空闲的)。备份源不一致时**不覆盖** ESP(设计 4.8 第三选择),差异逐条打印后以 64 退出
  (用 64 同时满足「不一致 -> FAIL 且不覆盖」)。非管理员会话 -> 2(需人工):mountvol /s 要求管理员。
  判据:只复制清单里 EFI/Microsoft/ 的文件;复制后复读 ESP 上 \EFI\Microsoft\ 与清单一致(允许比清单多出 BCD.LOG/
  BCD.LOG1/BCD.LOG2 这类事务日志,单列「预期新增」);\EFI\fedora\ 执行前后文件清单必须完全一致(L2 基线不含它,
  本脚本绝不创建/还原;本来不存在则写「不存在,未创建」)。不一致 -> FAIL(1)并打印复读结果。
  纪律:不改 {bootmgr} 的 path、不用 displayorder/efibootmgr -o、不碰 \EFI\fedora\;ESP 只临时挂载,finally 卸载。
  夹具钩子(仅离线验证,真机留空):DBK_MOUNTVOL_EXE(假 exe)、DBK_ESP_LETTER(替代 -EspLetter)、DBK_IS_ADMIN
  (1=强制管理员,0=强制非管理员)、DBK_ESP_ROOT(把 ESP 当作普通目录,替代 mountvol;此时不调 mountvol)。
  未在真机验证(夹具级验证,真机未跑);本文件 UTF-8 with BOM;清单格式与 backup-esp.ps1 一致(`<SHA256>  <相对路径>`)。
  未在真机验证的命令标「# 待核实(以官方文档为准)」:mountvol <ESP>: /s 与 mountvol <ESP>: /d。
  用法(仓库根、管理员 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\restore-esp.ps1 -Check -BaselineDir baseline
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\restore-esp.ps1 -Apply -Yes -BaselineDir baseline
  退出码:0 通过 / 1 失败(复制后复读不一致) / 2 需人工(非管理员会话) / 9 跳过(非 Windows) / 64 前置断言失败或用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$BaselineDir = '', [string]$EspLetter = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\restore-esp.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'restore-esp' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }
# 外部命令统一走这个包装:合并 stdout/stderr 后由调用方打印(不吞 stderr),并带回退出码。
function Invoke-DbkExe {
  param([string]$Exe, [string[]]$CmdArgs = @())
  $o = ''; $c = 1
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = [string](& $Exe @CmdArgs 2>&1 | Out-String); $c = [int]$LASTEXITCODE }
  catch { $o = [string]$_.Exception.Message; $c = 1 }
  $ErrorActionPreference = $prev
  return @{ Out = $o.Trim(); Code = $c }
}
# 目录下(相对 Root 的 Rel 子目录)全部文件,返回排序后的「/ 分隔相对路径」清单;目录不存在返回空数组。
function Get-DbkTreeList {
  param([string]$Root, [string]$Rel)
  $p = Join-Path $Root ($Rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  $pref = $p.Length + 1
  return @(Get-ChildItem -LiteralPath $p -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($pref).Replace('\', '/') } | Sort-Object)
}
# 前置断言 1:管理员会话(夹具用 DBK_IS_ADMIN=1/0 强制)
$isAdmin = $null
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true } elseif ($env:DBK_IS_ADMIN -eq '0') { $isAdmin = $false }
else { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '当前不是管理员会话:mountvol /s 需要管理员,本步无法执行;请以管理员身份重开 Windows PowerShell 后重跑(本次零写)' }
# 前置断言 2/3:备份清单可读、备份树自身与清单一致(有任一不符就不作为还原来源)
$base = $BaselineDir
if (-not $base) { $base = 'baseline' }
$bak = Join-Path ([System.IO.Path]::GetFullPath($base)) '02-esp-backup'
$manPath = Join-Path $bak 'manifest.sha256'
$diffs = @(); $entries = @(); $listed = @{}
if (-not (Test-Path -LiteralPath $manPath)) { $diffs += ('找不到备份清单:' + $manPath) }
elseif ((Get-Item -LiteralPath $manPath).Length -eq 0) { $diffs += ('备份清单是空文件:' + $manPath) }
if (@($diffs).Count -eq 0) {
  $lines = @([System.IO.File]::ReadAllLines($manPath, [System.Text.Encoding]::UTF8) | Where-Object { $_ -and $_.Trim() })
  if ($lines.Count -eq 0) { $diffs += ('备份清单没有有效行:' + $manPath) }
  foreach ($ln in $lines) {
    $m = [regex]::Match($ln, '^(?<h>[0-9a-fA-F]{64})[ ]{2,}(?<p>\S.*?)\s*$')
    if (-not $m.Success) { $diffs += ('清单行格式不合法:' + $ln); continue }
    $rel = $m.Groups['p'].Value.Trim().Replace('\', '/')
    $entries += @{ Rel = $rel; Hash = $m.Groups['h'].Value.ToLower() }
    $listed[$rel.ToLower()] = $true
  }
  if (@($entries | Where-Object { $_.Rel -like 'EFI/Microsoft/*' }).Count -eq 0) { $diffs += '清单里没有 EFI/Microsoft/ 条目,不能作为还原来源' }
}
if (@($diffs).Count -eq 0) {
  foreach ($e in $entries) {
    $abs = Join-Path $bak ($e.Rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs)) { $diffs += ('备份里缺文件:' + $e.Rel); continue }
    if ((Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash.ToLower() -ne $e.Hash) { $diffs += ('备份文件哈希与清单不一致:' + $e.Rel) }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $bak -Recurse -File -Force | Where-Object { $_.Name -ne 'manifest.sha256' })) {
    $rel = $f.FullName.Substring($bak.Length + 1).Replace('\', '/')
    if (-not $listed.ContainsKey($rel.ToLower())) { $diffs += ('备份里有清单未收录的文件:' + $rel) }
  }
}
$want = @($entries | Where-Object { $_.Rel -like 'EFI/Microsoft/*' })
# 前置断言 4:ESP 可用(夹具用 DBK_ESP_ROOT 指定一个普通目录替代挂载)
$mountvol = 'mountvol'; if ($env:DBK_MOUNTVOL_EXE) { $mountvol = $env:DBK_MOUNTVOL_EXE }
$espHook = [string]$env:DBK_ESP_ROOT
$mp = ''; $espRoot = ''; $to = ''
if ($espHook) {
  $espRoot = $espHook.TrimEnd('\') + '\'
  $to = 'DBK_ESP_ROOT 指定的普通目录 ' + $espRoot + '(夹具模式,不调用 mountvol)'
} else {
  $letter = $EspLetter; if ($env:DBK_ESP_LETTER) { $letter = $env:DBK_ESP_LETTER }
  if ($letter) {
    $letter = $letter.TrimEnd(':')
    if (Test-Path -LiteralPath ($letter + ':\')) { $diffs += ('ESP 盘符 ' + $letter + ': 已被占用,请换 -EspLetter') }
  } else { foreach ($c in @('S', 'T', 'U', 'V', 'W')) { if (-not (Test-Path -LiteralPath ($c + ':\'))) { $letter = $c; break } } }
  if (-not $letter) { $diffs += 'S/T/U/V/W 都被占用,找不到空闲盘符,请用 -EspLetter 指定' }
  $mp = $letter + ':'; $to = 'ESP 盘符 ' + $mp
}
if (@($diffs).Count -gt 0) {
  Write-DbkNote ('前置断言不满足 ' + @($diffs).Count + ' 项(零写:未挂载、未复制、未改动 ESP):')
  foreach ($d in $diffs) { Write-DbkNote ('  - ' + $d); Add-DbkCheck ('失败项:' + $d) }
  Write-DbkNote '本脚本只从校验通过的基线复原,源不一致时不覆盖 ESP(设计 4.8 第三选择);请修复或重做 L2 基线后重跑。'
  exit $script:DBK_USAGE
}
Add-DbkCheck '管理员权限: 是'
Add-DbkCheck ('备份树校验通过:清单 ' + $entries.Count + ' 行(其中 EFI/Microsoft/ ' + $want.Count + ' 个文件),逐条哈希与清单一致、无清单外文件')
Add-DbkCheck ('还原来源:' + $bak + ';目标:' + $to)
Add-DbkCheck ('将逐个复制 ' + $want.Count + ' 个文件;不触碰 \EFI\fedora\(L2 基线不含它,绝不还原)')
if ($espHook) { Add-DbkAction ('夹具模式:ESP 当作普通目录 ' + $espRoot + ',不调用 mountvol') }
else { Add-DbkAction ('mountvol ' + $mp + ' /s -> 复制 -> 复读比对 -> mountvol ' + $mp + ' /d') }
foreach ($e in $want) { Add-DbkAction ('复制 ' + $e.Rel) }
if ($script:DbkMode -eq 'check') {
  Write-DbkNote '-Check 只做校验与清单打印,未挂载、未写盘(零写);确认无误后加 -Apply -Yes 重跑。'
  Write-DbkExit -Status PASS -Message ('备份树校验通过(清单 ' + $entries.Count + ' 行,EFI/Microsoft/ ' + $want.Count + ' 个文件);-Check 零写,将把这 ' + $want.Count + ' 个文件复制到 ' + $to + ',不改 {bootmgr} 的 path、不碰 \EFI\fedora\')
}
$bad = @(); $mounted = $false; $boom = $false
try {
  if (-not $espHook) {
    $r1 = Invoke-DbkExe $mountvol @($mp, '/s')
    Write-DbkNote ('mountvol ' + $mp + ' /s 退出码 ' + $r1.Code + ';输出:' + ($r1.Out -replace "`r?`n", ' | '))
    Write-DbkLog ('mountvol ' + $mp + ' /s 退出码 ' + $r1.Code)
    if ($r1.Code -ne 0) { throw ('mountvol ' + $mp + ' /s 失败(退出码 ' + $r1.Code + '):' + $r1.Out) }
    $mounted = $true
    if (-not (Test-Path -LiteralPath ($mp + '\EFI'))) { throw ('挂载 ' + $mp + ' 后看不到 \EFI,可能不是 ESP;已中止,未复制任何文件') }
    $espRoot = $mp + '\'
  }
  $fedBefore = @(Get-DbkTreeList $espRoot 'EFI\fedora')
  foreach ($e in $want) {
    $src = Join-Path $bak ($e.Rel -replace '/', '\')
    $dst = Join-Path $espRoot ($e.Rel -replace '/', '\')
    $dir = Split-Path -Parent $dst
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $hSrc = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $hDst = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
    if ($hSrc -ne $e.Hash -or $hDst -ne $e.Hash) { $bad += ('复制后哈希不一致:' + $e.Rel + '(清单 ' + $e.Hash + ';源 ' + $hSrc + ';目标 ' + $hDst + ')') }
    else { Add-DbkAction ('复制 ' + $e.Rel + '(复制前后哈希一致)') }
  }
  $msRoot = Join-Path $espRoot 'EFI\Microsoft'
  if (-not (Test-Path -LiteralPath $msRoot)) { $bad += '复读:ESP 上 \EFI\Microsoft\ 不存在' }
  else {
    $seen = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $msRoot -Recurse -File -Force)) {
      $rel = 'EFI/Microsoft/' + $f.FullName.Substring($msRoot.Length + 1).Replace('\', '/')
      $seen[$rel.ToLower()] = @{ H = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(); Rel = $rel }
    }
    foreach ($e in $want) {
      $k = $e.Rel.ToLower()
      if (-not $seen.ContainsKey($k)) { $bad += ('复读:ESP 上缺 ' + $e.Rel) }
      elseif ($seen[$k].H -ne $e.Hash) { $bad += ('复读:ESP 上 ' + $e.Rel + ' 的哈希与清单不一致') }
      else { $seen.Remove($k) }
    }
    foreach ($k in @($seen.Keys | Sort-Object)) {
      $x = $seen[$k].Rel
      if ($x -match '(?i)/BCD\.LOG[0-9]?$') { Add-DbkCheck ('预期新增(BCD 事务日志,允许):' + $x) } else { $bad += ('复读:ESP 上出现清单外文件 ' + $x) }
    }
    if (@($bad).Count -eq 0) { Add-DbkCheck ('复读通过:ESP 上 \EFI\Microsoft\ 的 ' + $want.Count + ' 个文件与清单逐文件一致') }
  }
  $fedAfter = @(Get-DbkTreeList $espRoot 'EFI\fedora')
  if ($fedBefore.Count -eq 0) {
    if ($fedAfter.Count -gt 0) { $bad += ('复读:\EFI\fedora\ 原本不存在,执行后却有 ' + $fedAfter.Count + ' 个文件(本脚本绝不还原它)') }
    else { Add-DbkAction '\EFI\fedora\ 不存在,未创建' }
  } elseif (($fedBefore -join '|') -ne ($fedAfter -join '|')) {
    $bad += ('复读:\EFI\fedora\ 文件清单被改动(执行前 ' + $fedBefore.Count + ' 个,执行后 ' + $fedAfter.Count + ' 个;本脚本不碰它)')
  } else { Add-DbkAction ('\EFI\fedora\ 未触碰(' + $fedBefore.Count + ' 个文件,执行前后清单一致)') }
} catch {
  Enable-DbkErrTrap
  Write-DbkErrTrap -Reason ('restore-esp 执行中断:' + $_.Exception.Message)
  $boom = $true
} finally {
  if ($mounted) {
    $rd = Invoke-DbkExe $mountvol @($mp, '/d')
    Write-DbkNote ('mountvol ' + $mp + ' /d 退出码 ' + $rd.Code + ';输出:' + ($rd.Out -replace "`r?`n", ' | '))
    Write-DbkLog ('mountvol ' + $mp + ' /d 退出码 ' + $rd.Code)
  }
}
if ($boom) { exit $script:DBK_FAIL }
if (@($bad).Count -gt 0) {
  foreach ($b in @($bad)) { Add-DbkCheck ('失败项:' + $b) }
  Write-DbkExit -Status FAIL -Message ('复制后复读与基线不一致(' + @($bad).Count + ' 项,见 checks);ESP 上 \EFI\Microsoft\ 可能只还原了一部分,先按上面的差异人工核对(本脚本不改 {bootmgr} 的 path、不碰 \EFI\fedora\),必要时用同一基线重跑。ESP 已卸载')
}
Set-DbkChanged
$fedMsg = '\EFI\fedora\ 原本不存在,未创建'
if ($fedBefore.Count -gt 0) { $fedMsg = ('\EFI\fedora\ 未触碰(' + $fedBefore.Count + ' 个文件)') }
Write-DbkExit -Status PASS -Message ('已从 ' + $bak + ' 还原 \EFI\Microsoft\(' + $want.Count + ' 个文件,与清单逐文件一致);' + $fedMsg + ';ESP 已卸载')
