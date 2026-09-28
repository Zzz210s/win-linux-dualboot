#Requires -Version 5.1
# 对应卡:03-8,07-10
# 破坏性:1
<#
.SYNOPSIS
  L2 基线备份:导出 ESP 全量文件树 + 文件级清单 + 固件启动项/分区快照;-Check(缺省)只校验已有备份,不重做也不写盘。

.DESCRIPTION
  产物(全部落在 -OutDir 下,I4 基线):
    02-esp-backup/                  ESP 全量文件树(含 EFI\ 子树;重复运行时与源严格同步,源上已删除的陈旧文件会被清掉)
    02-esp-backup/manifest.sha256   文件级 SHA256 清单(相对路径 + 哈希)
    02-firmware-entries.txt         bcdedit /enum firmware 与 /enum {bootmgr} 快照
    02-partitions.txt               diskpart 与 Get-Disk/Get-Partition 快照
  注意:不要改动控制台输出编码(否则 cp936 控制台下会误解码 bcdedit/diskpart 输出,快照失真);
  本文件与 preflight.ps1 一样必须保存为 UTF-8 with BOM。
  边界:本脚本只写 -OutDir,**绝不修改 ESP 的任何内容**;ESP 只在备份期间临时挂一个盘符,收尾必然卸载。
  CLI 契约(设计 03 第 2 节):-Check 是**缺省**且只读 —— 已有备份时逐文件重算 SHA256 比对(一致 -> 0,
    有差异/清单缺失 -> 1;差异逐条列出,不自动重做);还没有备份时只打印 -Apply 会做什么并退 1(零写)。
  -Apply 才写盘;脚本头声明「# 破坏性:1」,故 -Apply 必须同时给 -Yes,缺 -Yes 由库层直接退 64 且零写。
  夹具钩子(仅离线验证,真机留空):DBK_IS_ADMIN=1/0(强制管理员判定)、DBK_MOUNTVOL_EXE(假 mountvol,
    自己把调用写进 $env:DBK_CALLS);robocopy / bcdedit / diskpart 也走 Invoke-DbkExe 取退出码。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir baseline -Check
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir baseline -Apply -Yes
  多设备时 -OutDir 指到 baseline\<设备别名>\ 下;退出码:0 通过 / 1 失败 / 2 需人工(非管理员、卸载失败)
    / 9 跳过(非 Windows)/ 64 用法错误。
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$OutDir = 'baseline', [string]$EspLetter = '',
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\backup-esp.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'backup-esp' }
if ($env:OS -ne 'Windows_NT') { Write-DbkNote '跳过:非 Windows 会话($env:OS 不是 Windows_NT)'; exit $script:DBK_SKIP }

function Write-TextFile {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$outFull = [System.IO.Path]::GetFullPath($OutDir)
$espDir = Join-Path $outFull '02-esp-backup'
$manC = Join-Path $espDir 'manifest.sha256'
$fwTxt = Join-Path $outFull '02-firmware-entries.txt'
$partTxt = Join-Path $outFull '02-partitions.txt'

# ==== -Check(缺省)零写:已有备份就逐文件校验;还没有备份只打印 -Apply 会做什么,不落任何文件 ====
if ($script:DbkMode -eq 'check') {
  if (-not (Test-Path -LiteralPath $manC)) {
    Write-DbkNote ('尚未生成 I4 基线:找不到备份清单 ' + $manC + ';本次 -Check 零写(未挂载、未建目录、未写文件)。')
    Write-DbkNote '-Apply -Yes 将做:① 临时挂载 ESP 到空闲盘符(或 -EspLetter 指定):mountvol <盘符> /s'
    Write-DbkNote ('② robocopy /E /COPY:DAT /PURGE 把 ESP 全量文件树导出到 ' + $espDir)
    Write-DbkNote ('③ 逐文件算 SHA256 写 manifest.sha256;④ 写 ' + $fwTxt + '(bcdedit 固件启动项快照)与 ' + $partTxt + '(diskpart + Get-Disk/Get-Partition 快照);⑤ 收尾 mountvol /d 卸载。')
    Write-DbkNote '本脚本只写 -OutDir,绝不改动 ESP 内容。'
    Add-DbkCheck ('失败项:找不到备份清单 ' + $manC + '(I4 基线尚未生成)')
    Write-DbkExit -Status FAIL -Message ('I4 基线尚未生成:找不到 ' + $manC + ';本次 -Check 零写,确认后加 -Apply -Yes 生成,或把 -OutDir 指到真正的基线目录')
  }
  $manLines = @([System.IO.File]::ReadAllLines($manC, [System.Text.Encoding]::UTF8) | Where-Object { $_ -and $_.Trim() })
  if ($manLines.Count -eq 0) {
    Add-DbkCheck ('失败项:备份清单是空文件 ' + $manC)
    Write-DbkExit -Status FAIL -Message ('备份清单是空文件:' + $manC + ';重做一次备份(-Apply -Yes);本次 -Check 零写')
  }
  $badList = @(); $listed = @{}; $checked = 0
  foreach ($ln in $manLines) {
    $m = [regex]::Match($ln, '^(?<h>[0-9a-fA-F]{64})[ ]{2}(?<p>.+)$')
    if (-not $m.Success) { $badList += ('清单行格式不合法:' + $ln); continue }
    $rel = $m.Groups['p'].Value.Trim()
    $listed[$rel.ToLower()] = $true
    $abs = Join-Path $espDir ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs)) { $badList += ('清单里的文件不存在:' + $rel); continue }
    $h = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash.ToLower()
    $checked++
    if ($h -ne $m.Groups['h'].Value.ToLower()) { $badList += ('哈希不一致:' + $rel + '(清单 ' + $m.Groups['h'].Value.ToLower() + ',实测 ' + $h + ')') }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $espDir -Recurse -File -Force | Where-Object { $_.Name -ne 'manifest.sha256' })) {
    $rel = $f.FullName.Substring($espDir.Length + 1).Replace('\', '/')
    if (-not $listed.ContainsKey($rel.ToLower())) { $badList += ('清单未收录的备份文件:' + $rel) }
  }
  if ($badList.Count -gt 0) {
    foreach ($b in @($badList | Select-Object -First 20)) { Add-DbkCheck ('失败项:' + $b) }
    Write-DbkExit -Status FAIL -Message ('备份校验不通过:' + $badList.Count + ' 项(已比对 ' + $checked + ' 个文件);不重做备份:按上面的差异清单人工判断,要重做就加 -Apply -Yes 重跑')
  }
  Write-DbkNote ('备份树:' + $espDir + '(本次未改动任何文件,ESP 未被挂载)')
  Write-DbkExit -Status PASS -Message ('备份校验通过:清单 ' + $manLines.Count + ' 行,已比对 ' + $checked + ' 个文件,逐文件哈希一致、无清单外文件;-Check 零写')
}

# ==== -Apply -Yes:选盘符 -> 挂 ESP -> 导出文件树 + 清单 -> 两份快照 -> 卸载 ====
$isAdmin = $false
if ($env:DBK_IS_ADMIN -eq '1') { $isAdmin = $true }
elseif ($env:DBK_IS_ADMIN -ne '0') { try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false } }
if (-not $isAdmin) { Write-DbkExit -Status 需人工 -Message '需要管理员权限(对 ESP 执行 mountvol /s):请以管理员身份重开 Windows PowerShell 后重跑 -Apply -Yes;本次零写(未挂载、未建目录、未写文件)' }

# 1. 先选盘符(选不出就零写退出:输出目录也是写动作)
if ($EspLetter) {
  $letter = $EspLetter.TrimEnd(':')
  if (Test-Path -LiteralPath ($letter + ':\')) {
    Add-DbkCheck ('失败项:盘符 ' + $letter + ': 已被占用(-EspLetter)')
    Write-DbkExit -Status FAIL -Message ('盘符 ' + $letter + ': 已被占用,请换 -EspLetter;本次未挂载、未建目录、未写文件')
  }
} else {
  $letter = ''
  foreach ($c in @('S', 'T', 'U', 'V', 'W')) { if (-not (Test-Path -LiteralPath ($c + ':\'))) { $letter = $c; break } }
}
if (-not $letter) {
  Add-DbkCheck '失败项:S/T/U/V/W 都被占用,找不到空闲盘符'
  Write-DbkExit -Status FAIL -Message 'S/T/U/V/W 都被占用,找不到空闲盘符,请用 -EspLetter 指定;本次未挂载、未建目录、未写文件'
}

# 2. 输出目录与外部命令
New-Item -ItemType Directory -Force -Path $espDir | Out-Null
$mountvol = 'mountvol'; if ($env:DBK_MOUNTVOL_EXE) { $mountvol = $env:DBK_MOUNTVOL_EXE }
$mountPoint = $letter + ':'
$bad = @(); $mounted = $false; $unmountNote = ''; $manifestCount = 0
try {
  $r = Invoke-DbkExe $mountvol @($mountPoint, '/s')
  Write-DbkNote ('mountvol ' + $mountPoint + ' /s 退出码 ' + $r.Code + ';输出:' + ($r.Out -replace "`r?`n", ' | '))
  Write-DbkLog ('mountvol ' + $mountPoint + ' /s 退出码 ' + $r.Code)
  if ($r.Code -ne 0) { throw ('mountvol ' + $mountPoint + ' /s 失败(退出码 ' + $r.Code + '):' + $r.Out) }
  $mounted = $true
  if (-not (Test-Path -LiteralPath ($mountPoint + '\EFI'))) { throw ('挂载点 ' + $mountPoint + ' 上没有 EFI 目录,可能不是 ESP;已跳过复制') }

  # 3. 复制 ESP 全量文件树(/E 含空目录;/COPY:DAT 不含审计信息;/PURGE 清掉目标目录里源上已不存在的旧文件,
  #    否则 ESP 侧删改过的文件会永久留在备份树里,复原时又被复制回 ESP)
  $rcArgs = @(($mountPoint + '\'), $espDir, '/E', '/COPY:DAT', '/PURGE', '/R:1', '/W:1', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
  $rr = Invoke-DbkExe 'robocopy' $rcArgs
  Write-DbkLog ('robocopy 退出码 ' + $rr.Code)
  if ($rr.Code -ge 8) { throw ('robocopy 复制 ESP 失败(退出码 ' + $rr.Code + '):' + $rr.Out) }

  # 4. 文件级清单(先枚举再写清单文件;manifest.sha256 是清单自身,永远不进清单,否则会自引用并破坏 03-9 的清单可解析判据)
  $files = @(Get-ChildItem -LiteralPath $espDir -Recurse -File -Force | Where-Object { $_.Name -ne 'manifest.sha256' })
  $manifest = @()
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($espDir.Length + 1).Replace('\', '/')
    $manifest += ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash + '  ' + $rel)
  }
  $manifestCount = $manifest.Count
  Write-TextFile $manC (($manifest -join "`r`n") + "`r`n")

  # 5. 固件启动项快照(BootOrder 与 {bootmgr} 的 path 都在这两份输出里)
  $fw = (Invoke-DbkExe 'bcdedit' @('/enum', 'firmware')).Out
  $bm = (Invoke-DbkExe 'bcdedit' @('/enum', '{bootmgr}')).Out
  Write-TextFile $fwTxt ('==== bcdedit /enum firmware ====' + "`r`n" + $fw + "`r`n" + '==== bcdedit /enum {bootmgr} ====' + "`r`n" + $bm)

  # 6. 分区快照
  $dpIn = "select disk 0`r`nlist disk`r`nlist partition`r`nlist volume`r`ndetail disk`r`nexit`r`n"
  $dp = Invoke-DbkExe 'diskpart' @() -Stdin $dpIn
  if ($dp.Code -ne 0) { Write-DbkNote ('提示:diskpart 退出码 ' + $dp.Code + ',快照可能不完整:' + ($dp.Out -replace "`r?`n", ' | ')) }
  $diskInfo = ''; $partInfo = ''
  try {
    $diskInfo = (Get-Disk -Number 0 | Format-List | Out-String)
    $partInfo = @(Get-Partition -DiskNumber 0) | Format-Table -AutoSize | Out-String
  } catch { $diskInfo = ('Get-Disk/Get-Partition 失败:' + $_.Exception.Message) }
  Write-TextFile $partTxt ('==== diskpart(select disk 0 / list disk / list partition / list volume / detail disk) ====' + "`r`n" +
    $dp.Out + "`r`n" + '==== Get-Disk / Get-Partition(disk 0) ====' + "`r`n" + $diskInfo + $partInfo)
  Set-DbkChanged
} catch {
  $bad += $_.Exception.Message
} finally {
  if ($mounted) {
    $rd = Invoke-DbkExe $mountvol @($mountPoint, '/d')
    Write-DbkNote ('mountvol ' + $mountPoint + ' /d 退出码 ' + $rd.Code + ';输出:' + ($rd.Out -replace "`r?`n", ' | '))
    Write-DbkLog ('mountvol ' + $mountPoint + ' /d 退出码 ' + $rd.Code)
    if ($rd.Code -ne 0) { $unmountNote = ('mountvol ' + $mountPoint + ' /d 卸载失败(退出码 ' + $rd.Code + '):' + $rd.Out + ';盘符可能仍挂着,请手工执行 mountvol ' + $mountPoint + ' /d') }
  }
}
foreach ($b in $bad) { Add-DbkCheck ('失败项:' + $b) }
if ($unmountNote) { Add-DbkCheck ('失败项:' + $unmountNote) }
if ($bad.Count -gt 0) {
  Write-DbkExit -Status FAIL -Message ('基线备份失败:' + ($bad -join ';') + ';产物目录 ' + $outFull + ' 可能只写了一半,核对后重跑 -Apply -Yes')
}
if ($unmountNote) {
  Write-DbkExit -Status 需人工 -Message ('基线已写出(ESP 文件树 ' + $manifestCount + ' 个文件 + 两份快照),但 ESP 卸载失败:' + $unmountNote + ';清掉该盘符后即可继续(产物已在 ' + $outFull + ')')
}
Write-DbkExit -Status PASS -Message ('基线已写出:' + $espDir + '(ESP 文件树 + 清单 ' + $manifestCount + ' 个文件)、' + $fwTxt + '、' + $partTxt + ';ESP 已卸载(' + $mountPoint + '),ESP 内容全程未被修改')
