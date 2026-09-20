#Requires -Version 5.1
# 对应卡:01-4
<#
.SYNOPSIS
  L0:落 L0 产物。缺省 -Check 只打印将写入的内容(零写);-Apply 才写 baseline\00-firmware.md。
.DESCRIPTION
  产物字段(设计 4.1 与 docs/01-firmware.md 的 01-4 字段清单):设备型号、固件厂商与版本、启动模式、存储控制器模式(原值 → 目标值)、
  Secure Boot 状态、Fast Boot 状态、**启动顺序(`BootOrder` 首位)原值**、启动菜单键、CPU / GPU / 网卡型号、目标磁盘型号与容量、安装介质校验值。
  机器能读的项由本脚本直接填;读不到的项(固件界面里的原值、Fast Boot、启动菜单键、介质校验值)写成占位值由人补齐;
  -Apply **幂等**:重跑时沿用已有产物里的人工填写值(不覆盖人手填的内容),机器可读的项则每次重新采集。
  -Check 零写:内容打印到 stderr(stdout 留给 -Json 的一行 JSON),不建目录、不落盘。
  **启动顺序行必须逐字写成 `| 启动顺序(`BootOrder` 首位)原值 | <实测值> |`**:L2 预检(preflight.ps1)按这一行的字段名提取比对基准;
  读不到时写 `-`(预检按"基准缺失"判黄,不会把缺值当成假值)。
  夹具钩子(仅离线验证用,真机留空):DBK_L0_DUMP=<文本文件,每行 key=value> 覆盖本机读取;
  键:model / bios / fwmode / bootorder / cpu / gpu / nic / disk / secureboot / controller / fastboot / bootkey / media。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell;多设备时 -OutFile 指到 baseline\<设备别名>\00-firmware.md):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\collect-l0.ps1            # 只打印,不落盘
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\collect-l0.ps1 -Apply     # 写产物
  退出码:0 通过 / 1 失败(关键字段读不到;产物仍写下,缺值记 `-`) / 2 需人工(有必须人工补的字段) / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$OutFile = 'baseline\00-firmware.md', [string]$IsoDir = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志;只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\collect-l0.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'collect-l0' }

# 夹具注入:把 key=value 覆盖值读进内存(真机不设 DBK_L0_DUMP)。
$script:Dump = @{}
if ($env:DBK_L0_DUMP) {
  if (-not (Test-Path -LiteralPath $env:DBK_L0_DUMP)) {
    Write-DbkNote ('用法错误: DBK_L0_DUMP 指向的文件不存在: ' + $env:DBK_L0_DUMP)
    exit $script:DBK_USAGE
  }
  foreach ($line in [System.IO.File]::ReadAllLines($env:DBK_L0_DUMP, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') { $script:Dump[$Matches[1].ToLower()] = $Matches[2].Trim() }
  }
}

function Get-Raw {
  # 有夹具覆盖值就用覆盖值;否则跑真实读取,读不到一律返回空串(由调用方决定是失败还是需人工)
  param([string]$Key, [scriptblock]$Real)
  if ($script:Dump.ContainsKey($Key)) { return [string]$script:Dump[$Key] }
  try { return [string](& $Real) } catch { return '' }
}

function Get-BootOrderFirst {
  # 只读:bcdedit /enum firmware 的 displayorder / 显示顺序 第一项 → 尽力换成它的 description
  $txt = ''
  try { $txt = (& bcdedit /enum firmware 2>&1 | Out-String) } catch { return '' }
  if ($LASTEXITCODE -ne 0 -or -not $txt -or $txt -match '拒绝访问|Access is denied') { return '' }
  $guids = @(); $inOrder = $false
  foreach ($line in ($txt -split "`r?`n")) {
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
  if ($guids.Count -eq 0) { return '' }
  $cur = ''; $desc = ''
  foreach ($line in ($txt -split "`r?`n")) {
    if ($line -match '^\s*(identifier|标识符)\s+(\{[^}]+\})') { $cur = $Matches[2]; continue }
    if (-not $desc -and $cur -eq $guids[0] -and $line -match '^\s*(description|描述)\s+(\S.*?)\s*$') { $desc = $Matches[2] }
  }
  if ($desc) { return $desc }
  return $guids[0]
}

$outFull = [System.IO.Path]::GetFullPath($OutFile)
# -Apply 幂等:沿用已有产物里的人工填写值(占位值一律不沿用)
$prev = @{}
if (Test-Path -LiteralPath $outFull) {
  foreach ($line in [System.IO.File]::ReadAllLines($outFull, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*$') {
      $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
      if ($k -and $k -ne '字段' -and $v -and $v -ne '-' -and $v -notmatch '^需人工填') { $prev[$k] = $v }
    }
  }
}
function Use-Prev { param([string]$Key, [string]$Value) if (-not $Value -and $script:prev.ContainsKey($Key)) { return $script:prev[$Key] } return $Value }

$HUMAN = '需人工填(见 docs/01-firmware.md 的 01-4 字段清单)'
$model = Get-Raw 'model' { (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model }
$bios = Get-Raw 'bios' { $b = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop; ($b.Manufacturer + ' ' + $b.SMBIOSBIOSVersion).Trim() }
$fwmode = Get-Raw 'fwmode' { if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI(按 SecureBoot\State 键存在推断)' } else { '' } }
$order = Get-Raw 'bootorder' { Get-BootOrderFirst }
$cpu = Get-Raw 'cpu' { (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | ForEach-Object { $_.Name }) -join '; ') }
$gpu = Get-Raw 'gpu' { (@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { $_.Name }) -join '; ') }
$nic = Get-Raw 'nic' { (@(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop | Where-Object { $_.PhysicalAdapter } | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '; ') }
$disk = Get-Raw 'disk' { $d = Get-Disk -Number 0 -ErrorAction Stop; ($d.FriendlyName + ' / ' + [math]::Round($d.Size / 1GB, 1) + ' GiB') }
$sb = Get-Raw 'secureboot' { if (Confirm-SecureBootUEFI) { '已开启' } else { '未开启' } }
$ctrl = Get-Raw 'controller' { (@(Get-PnpDevice -Class SCSIAdapter -ErrorAction Stop | ForEach-Object { $_.FriendlyName }) -join '; ') }
$media = Get-Raw 'media' { '' }
if (-not $media -and $IsoDir -and (Test-Path -LiteralPath $IsoDir)) {
  $lines = @()
  foreach ($iso in @(Get-ChildItem -LiteralPath $IsoDir -Filter '*.iso' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $lines += ($iso.Name + ': SHA256 ' + (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash.ToLower())
  }
  if ($lines.Count -gt 0) { $media = ($lines -join ' / ') }
}
$controller = $ctrl
if ($controller) { $controller = $controller + ';原值需人工按 01-1 的抄录补' }

$rows = [ordered]@{}
$rows['设备型号'] = $model
$rows['固件厂商与版本'] = $bios
$rows['启动模式'] = $fwmode
$rows['存储控制器模式(原值 → 目标值)'] = Use-Prev '存储控制器模式(原值 → 目标值)' $controller
$rows['Secure Boot 状态'] = $sb
$rows['Fast Boot 状态'] = Use-Prev 'Fast Boot 状态' (Get-Raw 'fastboot' { '' })
$rows['启动顺序(`BootOrder` 首位)原值'] = $order
$rows['启动菜单键'] = Use-Prev '启动菜单键' (Get-Raw 'bootkey' { '' })
$rows['CPU'] = $cpu
$rows['GPU'] = $gpu
$rows['网卡'] = $nic
$rows['目标磁盘型号与容量'] = $disk
$rows['安装介质校验值'] = Use-Prev '安装介质校验值' $media

$missing = @()
foreach ($k in @('设备型号', '固件厂商与版本', '启动模式', '启动顺序(`BootOrder` 首位)原值')) { if (-not $rows[$k]) { $missing += $k } }
foreach ($k in @($rows.Keys)) { if (-not $rows[$k]) { if ($missing -contains $k) { $rows[$k] = '-' } else { $rows[$k] = $HUMAN } } }

function Format-Cell { param([string]$Value) $s = (([string]$Value) -replace "`r?`n", ' ').Trim(); $s = $s -replace '\|', '/'; if (-not $s) { return '-' } return $s }
$md = @('# L0 固件与介质记录', '')
$md += ('- 生成时间:' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
$md += '- 生成方式:scripts/windows/collect-l0.ps1 -Apply(设计 4.1 的 L0 产物)'
$md += '- 说明:baseline/ 下除 README.md 外一律不入库;多设备时本文件放 baseline/<设备别名>/ 下;占位值由人按 01-1 / 01-2 的记录补齐后重跑本脚本(幂等,人工值会被沿用)'
$md += ''
$md += '| 字段 | 实测值 |'
$md += '|---|---|'
foreach ($k in @($rows.Keys)) { $md += ('| ' + $k + ' | ' + (Format-Cell $rows[$k]) + ' |') }
$md += ''
$text = (($md -join "`r`n") + "`r`n")

Add-DbkAction ('产物路径:' + $outFull)
$humanN = @($rows.Keys | Where-Object { $rows[$_] -eq $HUMAN }).Count
if ($missing.Count -eq 0) { Add-DbkCheck ('关键字段已采齐(启动顺序行:' + (Format-Cell $rows['启动顺序(`BootOrder` 首位)原值']) + ')') }
foreach ($m in $missing) { Add-DbkCheck ('失败项:关键字段读不到:' + $m) }
if ($humanN -gt 0 -and $missing.Count -eq 0) { Add-DbkCheck ('需人工:' + $humanN + ' 个字段要人补(占位值写的「需人工填」)') }

if ($script:DbkMode -eq 'apply') {
  $dirOut = Split-Path -Parent $outFull
  if ($dirOut -and -not (Test-Path -LiteralPath $dirOut)) { New-Item -ItemType Directory -Path $dirOut -Force | Out-Null }
  [System.IO.File]::WriteAllText($outFull, $text, (New-Object System.Text.UTF8Encoding($false)))
  Add-DbkAction '已写入产物(重复执行结果一致:人工填写值沿用,机器可读项重新采集)'
  Set-DbkChanged
} else {
  Write-DbkNote ('--- -Check 未落盘,以下是将写入 ' + $outFull + ' 的内容 ---')
  foreach ($l in $md) { Write-DbkNote $l }
  Write-DbkNote '--- 内容结束(-Check 不建目录、不落盘,重复执行不改动任何文件) ---'
}

if ($missing.Count -gt 0) {
  Write-DbkExit -Status FAIL -Message ('关键字段读不到:' + ($missing -join '、') + ';产物已按缺值(-)写入,请修好读取条件(管理员会话 / UEFI 启动)后重跑')
}
if ($humanN -gt 0) {
  Write-DbkExit -Status 需人工 -Message ('有 ' + $humanN + ' 个字段必须人工补齐(占位值写的「需人工填」);补齐后重跑本脚本,人工值会被沿用')
}
Write-DbkExit -Status PASS -Message '字段采齐,启动顺序(BootOrder 首位)原值已落盘'
