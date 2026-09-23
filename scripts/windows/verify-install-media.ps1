#Requires -Version 5.1
# 对应卡:01-2
<#
.SYNOPSIS
  L0:校验两个安装介质(只读):ISO 是否存在、Kubuntu ISO 的 SHA256 是否等于官方校验值、列出可移动盘。
.DESCRIPTION
  校验值来源(设计 4.1 与 5.3):
    ① Kubuntu 26.04 LTS ISO:官方发布页(https://releases.ubuntu.com/)的 `SHA256SUMS` 文件里的
       `<64 位十六进制> *<文件名>` 行(该文件放在与 ISO 同一目录,缺省名 <ISO 文件名>.CHECKSUM,可用 -IsoChecksum 指定),
       本脚本逐字符比对;该文件另有官方 GPG 签名(`SHA256SUMS.gpg`),签名核验由人工 gpg --verify 完成。
       兼容旧原子版的 `SHA256 (<文件名>) = <哈希>` 行格式,两种写法都认。
    ② Windows 11 ISO:微软官方**不发布**该镜像的 SHA256(设计 5.3),因此本脚本不做哈希比对;要求它来自微软官方下载域
       (https://www.microsoft.com/software-download/windows11),由人工确认后用 -WindowsOfficial 声明,脚本只记录实测 SHA256 留档。
  国内镜像站(repo.huaweicloud.com 等)只作下载加速、不作信任源:本脚本只认官方发布页的值。
  写入 U 盘仍为人工(分盘写用 Rufus:GPT + UEFI;一盘多 ISO 用 Ventoy,Secure Boot 下 Ventoy 必须先完成 MOK 注册):
  -Apply 不写任何系统状态,只把写盘与来源确认清单再打印一遍。
  夹具钩子(仅离线验证用,真机留空):DBK_MEDIA_DRIVES="型号|容量|总线;型号|容量|总线" 覆盖可移动盘列表。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。
  用法(在仓库根目录运行;ISO 与官方 CHECKSUM 放同一目录):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-install-media.ps1 -IsoDir D:\iso
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-install-media.ps1 -IsoDir D:\iso -WindowsOfficial
  退出码:0 通过 / 1 失败(ISO 缺失或 Kubuntu ISO 哈希与官方值不一致) / 2 需人工(缺校验值文件、未声明 -WindowsOfficial) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$IsoDir = '.', [string]$LinuxIso = '', [string]$WindowsIso = '',
  [string]$IsoChecksum = '', [switch]$WindowsOfficial,
  # 已废弃别名(原原子版遗留,保留以免破坏既有调用):-FedoraChecksum -> -IsoChecksum
  [string]$FedoraChecksum = ''   # 已废弃别名
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($PSBoundParameters.ContainsKey('FedoraChecksum')) {   # 已废弃别名命中
  Write-Host '提示:-FedoraChecksum 是已废弃别名(原原子版遗留),请改用 -IsoChecksum。'
  if (-not $IsoChecksum) { $IsoChecksum = $FedoraChecksum }   # 已废弃别名
}
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\verify-install-media.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'verify-install-media' }

function Find-Iso {
  # 用 -XxxIso 指定优先;否则在 -IsoDir 里按文件名特征找第一个
  param([string]$Given, [string]$Pattern)
  if ($Given) { return $Given }
  $d = [System.IO.Path]::GetFullPath($IsoDir)
  if (-not (Test-Path -LiteralPath $d)) { return '' }
  $hit = @(Get-ChildItem -LiteralPath $d -Filter '*.iso' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $Pattern } | Sort-Object Name | Select-Object -First 1)
  if ($hit.Count -eq 0) { return '' }
  return $hit[0].FullName
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-ExpectedSha256 {
  # 读官方 CHECKSUM 文件里该 ISO 文件名对应的 SHA256 值;找不到(缺文件 / 无该文件名行)返回空串
  param([string]$Iso, [string]$ChecksumFile)
  $ck = $ChecksumFile
  if (-not $ck) { $ck = $Iso + '.CHECKSUM' }
  if (-not (Test-Path -LiteralPath $ck)) { return '' }
  $leaf = Split-Path -Leaf $Iso
  foreach ($line in [System.IO.File]::ReadAllLines($ck, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*SHA256\s*\((.+?)\)\s*=\s*([0-9a-fA-F]{64})\s*$') {
      if ($Matches[1].Trim() -eq $leaf) { return $Matches[2].ToLower() }
    }
    # Ubuntu 官方 SHA256SUMS 格式:`<64 位十六进制> *<文件名>`(兼容不带 * 的写法)
    if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
      if ($Matches[2].Trim() -eq $leaf) { return $Matches[1].ToLower() }
    }
  }
  return ''
}

function Get-RemovableDiskList {
  if ($env:DBK_MEDIA_DRIVES) { return @($env:DBK_MEDIA_DRIVES -split ';' | Where-Object { $_ }) }
  $out = @()
  try { $out += @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'USB' } |
    ForEach-Object { $_.FriendlyName + '|' + [math]::Round($_.Size / 1GB, 1) + 'GiB|BusType=USB' }) } catch { }
  if ($out.Count -eq 0) {
    try { $out += @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
      Where-Object { $_.InterfaceType -eq 'USB' -or $_.MediaType -match 'Removable' } |
      ForEach-Object { $_.Model + '|' + [math]::Round([int64]$_.Size / 1GB, 1) + 'GiB|InterfaceType=' + $_.InterfaceType }) } catch { }
  }
  return @($out | Where-Object { $_ })
}

$failN = 0; $manualN = 0; $failItems = @()
$fIso = Find-Iso -Given $LinuxIso -Pattern 'Kubuntu'
$wIso = Find-Iso -Given $WindowsIso -Pattern 'Win11|win11|Windows|windows'

# ① Kubuntu ISO:存在 + 与官方校验值逐字符比对
if (-not $fIso -or -not (Test-Path -LiteralPath $fIso)) {
  $failN++; $failItems += 'Kubuntu ISO 缺失'
  Add-DbkCheck ('失败项:未找到 Kubuntu ISO(在 ' + ([System.IO.Path]::GetFullPath($IsoDir)) + ' 下按文件名含 Kubuntu 查找);用 -LinuxIso <路径> 指定')
} else {
  $fHash = Get-Sha256 -Path $fIso
  Add-DbkCheck ('Kubuntu ISO 实测 SHA256:' + $fHash + '(' + (Split-Path -Leaf $fIso) + ')')
  $exp = Get-ExpectedSha256 -Iso $fIso -ChecksumFile $IsoChecksum
  if (-not $exp) {
    $manualN++
    Add-DbkCheck ('需人工:找不到可用的官方校验值(缺 ' + $fIso + '.CHECKSUM 或里面没有该文件名的 SHA256 行);从官方发布页下载 SHA256SUMS 后重跑')
  } elseif ($exp -eq $fHash) {
    Add-DbkCheck ('Kubuntu ISO 哈希与官方校验值一致(官方值:' + $exp + ')')
  } else {
    $failN++; $failItems += ('Kubuntu ISO 哈希不一致(期望 ' + $exp + ' 实际 ' + $fHash + ')')
    Add-DbkCheck ('失败项:Kubuntu ISO 哈希与官方值不一致;期望(官方 SHA256SUMS)' + $exp + ';实际' + $fHash + ';不要使用该 ISO,重新下载或换镜像站重下')
  }
  Add-DbkAction '人工:用 gpg --verify 核对 SHA256SUMS 的官方签名(签名文件与 SHA256SUMS 同目录,官方发布页给出)'
}

# ② Windows 11 ISO:存在 + 官方来源由人工声明(官方未发布镜像哈希)
if (-not $wIso -or -not (Test-Path -LiteralPath $wIso)) {
  $failN++; $failItems += 'Windows 11 ISO 缺失'
  Add-DbkCheck '失败项:未找到 Windows 11 ISO(在 -IsoDir 下按文件名含 Win11 / Windows 查找);用 -WindowsIso <路径> 指定'
} else {
  Add-DbkCheck ('Windows 11 ISO 实测 SHA256(留档;官方未发布该镜像哈希):' + (Get-Sha256 -Path $wIso) + '(' + (Split-Path -Leaf $wIso) + ')')
  if ($WindowsOfficial) { Add-DbkCheck 'Windows 11 ISO 来源:已人工确认为微软官方下载域(设计 5.3:不做 SHA256 比对)' }
  else {
    $manualN++
    Add-DbkCheck '需人工:确认 Windows 11 ISO 来自微软官方下载域(https://www.microsoft.com/software-download/windows11),确认后加 -WindowsOfficial 重跑'
  }
}

# ③ 可移动盘与写盘清单(写盘本身人工)
$drives = @(Get-RemovableDiskList)
if ($drives.Count -gt 0) { Add-DbkCheck ('可移动盘:' + ($drives -join '; ')) }
else {
  $manualN++
  Add-DbkCheck '需人工:没看到可移动盘(插上 U 盘后重跑;或本机 USB 总线读不到)'
}
Add-DbkAction '人工写盘:Windows 用 Rufus(分区类型 GPT、目标系统 UEFI);一盘多 ISO 用 Ventoy(Secure Boot 下先在 MOK 界面完成密钥注册)'
Add-DbkAction '人工:写好后在一次性启动菜单里确认出现带 UEFI: 前缀的 U 盘条目(固件的 Fast Boot 必须为 Disabled)'

if ($failN -gt 0) { Write-DbkExit -Status FAIL -Message ("介质校验失败 " + $failN + " 项:" + ($failItems -join ';') + ";逐项判据见 checks") }
if ($manualN -gt 0) { Write-DbkExit -Status 需人工 -Message ("有 " + $manualN + " 项必须人工确认(官方 CHECKSUM 文件 / Windows ISO 来源 / 可移动盘);见 checks") }
Write-DbkExit -Status PASS -Message '两个 ISO 都在位,Kubuntu ISO 哈希与官方校验值一致,Windows ISO 来源已人工声明,可移动盘已列出'
