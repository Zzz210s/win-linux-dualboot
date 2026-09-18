#Requires -Version 5.1
<#
.SYNOPSIS
  L2 基线备份:导出 ESP 全量文件树 + 文件级清单 + 固件启动项/分区快照。

.DESCRIPTION
  产物(全部落在 -OutDir 下,I4 基线):
    02-esp-backup/                  ESP 全量文件树(含 EFI\ 子树;重复运行时与源严格同步,源上已删除的陈旧文件会被清掉)
    02-esp-backup/manifest.sha256   文件级 SHA256 清单(相对路径 + 哈希)
    02-firmware-entries.txt         bcdedit /enum firmware 与 /enum {bootmgr} 快照
    02-partitions.txt               diskpart 与 Get-Disk/Get-Partition 快照
  注意:不要改动控制台输出编码(否则 cp936 控制台下会误解码 bcdedit/diskpart 输出,快照失真);
  本文件与 preflight.ps1 一样必须保存为 UTF-8 with BOM。
  边界:本脚本只写 -OutDir,**绝不修改 ESP 的任何内容**;ESP 只在备份期间临时挂一个盘符,收尾必然卸载。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir baseline
  多设备时 -OutDir 指到 baseline\<设备别名>\ 下。
#>
[CmdletBinding()]
param(
  [string]$OutDir = 'baseline',
  [string]$EspLetter = ''
)

$ErrorActionPreference = 'Stop'

function Write-TextFile {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# 0. 管理员权限(mountvol /s 与读取 ESP 都要求)
$isAdmin = $false
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }
if (-not $isAdmin) {
  Write-Host '错误:需要管理员权限(对 ESP 执行 mountvol)。请以管理员身份重开 Windows PowerShell 后重跑。'
  exit 1
}

# 1. 输出目录
$outFull = [System.IO.Path]::GetFullPath($OutDir)
$espDir = Join-Path $outFull '02-esp-backup'
New-Item -ItemType Directory -Force -Path $espDir | Out-Null

# 2. 选一个空闲盘符并挂载 ESP
if ($EspLetter) {
  $letter = $EspLetter.TrimEnd(':')
  if (Test-Path -LiteralPath ($letter + ':\')) { Write-Host ('错误:盘符 ' + $letter + ' 已被占用,请换 -EspLetter。'); exit 1 }
} else {
  $letter = ''
  foreach ($c in @('S', 'T', 'U', 'V', 'W')) {
    if (-not (Test-Path -LiteralPath ($c + ':\'))) { $letter = $c; break }
  }
}
if (-not $letter) { Write-Host '错误:S/T/U/V/W 都被占用,找不到空闲盘符,请用 -EspLetter 指定。'; exit 1 }
$mountPoint = $letter + ':'
$mounted = $false
$manifestCount = 0

try {
  $mv = (& mountvol $mountPoint /s 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath ($mountPoint + '\'))) {
    throw ('mountvol ' + $mountPoint + ' /s 失败:' + $mv.Trim())
  }
  $mounted = $true
  if (-not (Test-Path -LiteralPath ($mountPoint + '\EFI'))) {
    throw ('挂载点 ' + $mountPoint + ' 上没有 EFI 目录,可能不是 ESP;已跳过复制。')
  }

  # 3. 复制 ESP 全量文件树(/E 含空目录;/COPY:DAT 不含审计信息;/PURGE 清掉目标目录里源上已不存在的旧文件,
  #    否则 ESP 侧删改过的文件会永久留在备份树里,复原时又被复制回 ESP)
  $rcArgs = @(($mountPoint + '\'), $espDir, '/E', '/COPY:DAT', '/PURGE', '/R:1', '/W:1', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
  $null = & robocopy @rcArgs
  $rc = $LASTEXITCODE
  if ($rc -ge 8) { throw ('robocopy 复制 ESP 失败(退出码 ' + $rc + ')') }

  # 4. 文件级清单(先枚举再写清单文件;manifest.sha256 是清单自身,永远不进清单,否则会自引用并破坏 docs/03-preflight.md 验证第 11 行)
  $files = @(Get-ChildItem -LiteralPath $espDir -Recurse -File -Force | Where-Object { $_.Name -ne 'manifest.sha256' })
  $manifest = @()
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($espDir.Length + 1).Replace('\', '/')
    $manifest += ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash + '  ' + $rel)
  }
  $manifestCount = $manifest.Count
  Write-TextFile (Join-Path $espDir 'manifest.sha256') (($manifest -join "`r`n") + "`r`n")

  # 5. 固件启动项快照(BootOrder 与 {bootmgr} 的 path 都在这两份输出里)
  $fw = (& bcdedit /enum firmware 2>&1 | Out-String)
  $bm = (& bcdedit /enum '{bootmgr}' 2>&1 | Out-String)
  $fwText = '==== bcdedit /enum firmware ====' + "`r`n" + $fw + "`r`n" + '==== bcdedit /enum {bootmgr} ====' + "`r`n" + $bm
  Write-TextFile (Join-Path $outFull '02-firmware-entries.txt') $fwText

  # 6. 分区快照
  $dpIn = "select disk 0`r`nlist disk`r`nlist partition`r`nlist volume`r`ndetail disk`r`nexit`r`n"
  $dp = ($dpIn | & diskpart 2>&1 | Out-String)
  $diskInfo = ''
  $partInfo = ''
  try {
    $diskInfo = (Get-Disk -Number 0 | Format-List | Out-String)
    $partInfo = @(Get-Partition -DiskNumber 0) | Format-Table -AutoSize | Out-String
  } catch { $diskInfo = ('Get-Disk/Get-Partition 失败:' + $_.Exception.Message) }
  $pText = '==== diskpart(select disk 0 / list disk / list partition / list volume / detail disk) ====' + "`r`n" +
    $dp + "`r`n" + '==== Get-Disk / Get-Partition(disk 0) ====' + "`r`n" + $diskInfo + $partInfo
  Write-TextFile (Join-Path $outFull '02-partitions.txt') $pText
} catch {
  Write-Host ('错误:' + $_.Exception.Message)
  exit 1
} finally {
  if ($mounted) { $null = (& mountvol $mountPoint /d 2>&1) }
}

Write-Host ('基线目录:' + $outFull)
Write-Host ('ESP 文件树备份:' + $espDir + '(清单 ' + $manifestCount + ' 个文件)')
Write-Host ('固件启动项快照:' + (Join-Path $outFull '02-firmware-entries.txt'))
Write-Host ('分区快照:' + (Join-Path $outFull '02-partitions.txt'))
Write-Host ('ESP 已卸载(' + $mountPoint + ');ESP 内容全程未被修改。')
Write-Host '下一步:重跑 preflight.ps1 定稿闸门报告(I4 基线产物齐备一行应转绿)。'
exit 0
