#Requires -Version 5.1
# 对应卡:01-3,03-7
<#
.SYNOPSIS
  L2 只读预检:体检本机状态并生成闸门报告(默认 baseline\02-preflight-report.md)。判定:红 = 禁止进入 L3;黄 = 记录后继续;绿 = 通过。
.DESCRIPTION
  只读:不修改系统任何设置,唯一写动作是生成报告文件;带 -Only <段名> 或 -Json 时只做查询输出,连报告也不写。
  -Only <段名> 只输出指定段(段名见 $SEC,至少支持 target-disk = 磁盘段,01-3 用;结论只由选中段得出);-Json 输出单行机器可读 JSON(script/only/rows[]/red/yellow/verdict)。
  本文件必须保存为 UTF-8 with BOM,否则 Windows PowerShell 5.1 会按 ANSI 解码中文而解析失败。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell;多设备时把 -OutFile 与 -BaselineDir 都指到 baseline\<设备别名>\ 下):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\preflight.ps1 -OutFile baseline\02-preflight-report.md
#>
[CmdletBinding()]
param(
  [string]$OutFile = 'baseline\02-preflight-report.md',
  [string]$BaselineDir = 'baseline',
  [string]$Only = '',
  [switch]$Json
)

$GREEN = '绿'; $YELLOW = '黄'; $RED = '红'
$rows = @(); $notes = @()

# -Only 段名 → 检查行名正则;段名写错按用法错误退 64(不静默返回空结果)
$SEC = @{ admin = '管理员权限'; storage = '存储控制器'; 'secure-boot' = 'Secure Boot'; bitlocker = 'BitLocker'; power = 'Fast Startup|休眠文件'
  'target-disk' = '磁盘 0|ESP 大小'; l0 = '^L0 基准'; l1 = '^L1 '; baseline = '^I4 基线'; system = '系统版本' }
$onlyRe = ''
if ($Only) {
  if (-not $SEC.ContainsKey($Only)) { Write-Host ('用法错误:-Only 不认识的段 ' + $Only + ';可用段:' + (($SEC.Keys | Sort-Object) -join '、')); exit 64 }
  $onlyRe = $SEC[$Only]
}

function Add-Row {
  param([string]$Item, [string]$Value, [string]$Verdict)
  $v = ((([string]$Value) -replace '\r?\n', ' ') -replace '\|', '/').Trim(); if ($v.Length -gt 240) { $v = $v.Substring(0, 240) + ' ...' }
  $script:rows += [pscustomobject]@{ Item = $Item; Value = $v; Verdict = $Verdict }
}
function Read-RegValue { param([string]$Path, [string]$Name) try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null } }
function EscJ { param([string]$Text) return ([string]$Text -replace '\\', '\\' -replace '"', '\"' -replace '\r?\n', ' ') }

# 1. 管理员权限
$isAdmin = $false; try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isAdmin = $false }
if ($isAdmin) { Add-Row '管理员权限' '是(当前进程为管理员,本报告结论有效)' $GREEN } else { Add-Row '管理员权限' '否:管理员权限不足,报告不可用(存储控制器/BitLocker/固件启动项/分区表都读不到),一律按禁止进入 L3 处理' $RED }

# 2. 存储控制器模式(Linux 侧看不到磁盘的最大原因)
$ctrlNames = @(); try { $ctrlNames = @(Get-PnpDevice -Class SCSIAdapter -ErrorAction Stop | ForEach-Object { $_.FriendlyName }) } catch { $ctrlNames = @() }
if ($ctrlNames.Count -eq 0) { try { $ctrlNames = @(Get-CimInstance -ClassName Win32_SCSIController -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { $ctrlNames = @() } }
if (@($ctrlNames | Where-Object { $_ -match 'VMD|RAID' }).Count -gt 0) { Add-Row '存储控制器模式' (@($ctrlNames | Where-Object { $_ -match 'VMD|RAID' }) -join '; ') $RED }
elseif ($ctrlNames.Count -eq 0) { Add-Row '存储控制器模式' '读不到(PnP 与 CIM 均无结果)' $YELLOW } else { Add-Row '存储控制器模式' ($ctrlNames -join '; ') $GREEN }

# 3. Secure Boot
$sb = Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
if ($null -eq $sb) { Add-Row 'Secure Boot' '读取不到(注册表键缺失或非 UEFI 启动)' $YELLOW } elseif ([int]$sb -eq 1) { Add-Row 'Secure Boot' 'UEFISecureBootEnabled = 1(已开启)' $GREEN } else { Add-Row 'Secure Boot' ('UEFISecureBootEnabled = ' + $sb + '(未开启)') $YELLOW }

# 4. BitLocker 保护状态
$blProt = ''; $blVol = ''; $blDetail = ''
try {
  $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
  $blProt = [string]$blv.ProtectionStatus; $blVol = [string]$blv.VolumeStatus; $blDetail = 'ProtectionStatus=' + $blProt + '; VolumeStatus=' + $blVol
} catch {
  $raw = ''; try { $raw = (& manage-bde -status $env:SystemDrive 2>&1 | Out-String) } catch { $raw = '' }
  $pl = ($raw -split "`r?`n" | Where-Object { $_ -match '保护状态|Protection Status' } | Select-Object -First 1)
  $vl = ($raw -split "`r?`n" | Where-Object { $_ -match '转换状态|Conversion Status' } | Select-Object -First 1)
  $blDetail = (@($pl, $vl) | Where-Object { $_ }) -join '; '
  if ($pl -match '打开|开启|启用|Protection On') { $blProt = 'On' } elseif ($pl -match '关闭|禁用|Protection Off') { $blProt = 'Off' }
  if ($vl -match '完全加密|Fully Encrypted') { $blVol = 'FullyEncrypted' } elseif ($vl -match '完全解密|未加密|Fully Decrypted') { $blVol = 'FullyDecrypted' }
}
$blSuffix = ''; if ($blDetail) { $blSuffix = ';' + $blDetail }
if ($blProt -eq 'On') { Add-Row 'BitLocker 保护状态' ($env:SystemDrive + ' 保护已开启' + $blSuffix) $RED }
elseif ($blProt -eq 'Off' -and $blVol -match 'FullyEncrypted') { Add-Row 'BitLocker 保护状态' ($env:SystemDrive + ' 卷已加密、保护已关闭(挂起或暂停),属允许进入 L3 的状态' + $blSuffix) $GREEN }
elseif ($blProt -eq 'Off') { Add-Row 'BitLocker 保护状态' ($env:SystemDrive + ' 未加密' + $blSuffix) $GREEN }
else { Add-Row 'BitLocker 保护状态' ('读不到(需管理员权限)' + $blSuffix) $YELLOW }

# 5. Fast Startup(NTFS 双写风险)与 6. 休眠文件
$hb = Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
if ($null -eq $hb) { Add-Row 'Fast Startup(HiberbootEnabled)' '读取不到' $YELLOW } elseif ([int]$hb -eq 1) { Add-Row 'Fast Startup(HiberbootEnabled)' 'HiberbootEnabled = 1(快速启动已开启)' $RED } else { Add-Row 'Fast Startup(HiberbootEnabled)' ('HiberbootEnabled = ' + $hb + '(已关闭)') $GREEN }
$hib = Join-Path ($env:SystemDrive + '\') 'hiberfil.sys'; if (Test-Path -LiteralPath $hib) { Add-Row '休眠文件 hiberfil.sys' '存在(休眠未关闭,共享盘挂载前必须处理)' $YELLOW } else { Add-Row '休眠文件 hiberfil.sys' '不存在' $GREEN }

# 7-8. 磁盘 0 的未分配空间(判据 = 最大连续间隙:WinRE 在盘尾,盘尾空隙接近 0,不能拿它当判据)与 ESP
$disk = $null; $parts = @()
try { $disk = Get-Disk -Number 0 -ErrorAction Stop; $parts = @(Get-Partition -DiskNumber 0 -ErrorAction Stop) } catch { $disk = $null; $parts = @() }
if ($disk -and $parts.Count -gt 0) {
  $gaps = @(); $prev = [int64]0
  foreach ($p in @($parts | Sort-Object Offset)) { if (([int64]$p.Offset - $prev) -gt 0) { $gaps += ([int64]$p.Offset - $prev) }; $prev = [int64]$p.Offset + [int64]$p.Size }
  if (([int64]$disk.Size - $prev) -gt 0) { $gaps += ([int64]$disk.Size - $prev) }
  $maxGapGiB = [math]::Round(((($gaps | Measure-Object -Maximum).Maximum / 1GB)), 1); $tailGapGiB = [math]::Round((([int64]$disk.Size - $prev) / 1GB), 1)
  $gapVal = '最大连续未分配 ' + $maxGapGiB + ' GiB;盘尾未分配 ' + $tailGapGiB + ' GiB'
  if ($maxGapGiB -lt 115) { Add-Row '磁盘 0 未分配空间' ($gapVal + '(Linux 侧需 115GiB 连续 = root 100 + 快照 15;盘尾归 WinRE)') $RED }
  else { Add-Row '磁盘 0 未分配空间' $gapVal $GREEN }
} else { Add-Row '磁盘 0 未分配空间' '读不到(Get-Disk/Get-Partition 失败或需管理员权限)' $YELLOW }
$esp = @($parts | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }); if ($esp.Count -eq 0) { $esp = @($parts | Where-Object { $_.Type -eq 'System' }) }
if ($esp.Count -ge 1) {
  $espGiB = [math]::Round(([int64]$esp[0].Size / 1GB), 2); $vol = $null
  try { $vol = Get-Volume -Partition $esp[0] -ErrorAction Stop } catch { $vol = $null }
  $espVal = '分区 ' + $esp[0].PartitionNumber + ' = ' + $espGiB.ToString() + ' GiB'
  if ($vol -and $null -ne $vol.SizeRemaining) { $espVal += ';文件系统剩余 ' + [math]::Round(([int64]$vol.SizeRemaining / 1MB), 1).ToString() + ' MiB' } else { $espVal += ';剩余空间读不到(ESP 不挂载,只用 Get-Partition/Get-Volume 读,避免改动系统)' }
  if ($espGiB -lt 1) { Add-Row 'ESP 大小与剩余' $espVal $YELLOW } else { Add-Row 'ESP 大小与剩余' $espVal $GREEN }
} else { Add-Row 'ESP 大小与剩余' '找不到 ESP 分区(GptType/Type 均未命中)' $YELLOW }

# 9. 固件启动项
$fwText = ''; $fwOk = $false
try { $fwText = (& bcdedit /enum firmware 2>&1 | Out-String); $fwOk = ($LASTEXITCODE -eq 0 -and $fwText.Trim().Length -gt 0 -and $fwText -notmatch '拒绝访问|Access is denied') } catch { $fwOk = $false }
if ($fwOk) { Add-Row '固件启动项(bcdedit /enum firmware)' ('已读取;含 { } 标识符的行数 = ' + @(($fwText -split "`r?`n") | Where-Object { $_ -match '\{' }).Count) $GREEN } else { Add-Row '固件启动项(bcdedit /enum firmware)' '读不到(需管理员权限或非 UEFI 启动)' $YELLOW }
$orderLine = ($fwText -split "`r?`n" | Where-Object { $_ -match 'displayorder|显示顺序|启动顺序|bootsequence|启动序列' } | Select-Object -First 1)
if ($orderLine) { $notes += ('固件启动项中的顺序行(原样记录):' + $orderLine.Trim()) }

# 10. L0 比对基准:启动顺序(BootOrder 首位)原值
$l0 = Join-Path $BaselineDir '00-firmware.md'; $l0Val = ''
if (Test-Path -LiteralPath $l0) {
  # 只认字段名逐字为"启动顺序(`BootOrder` 首位)原值"的产物行:允许 2-4 列、取最后一个单元格;模板样板值按字段缺失处理。行内空白用 [ \t](不用 \s:后者能吃掉 \r\n 而跨行合并相邻两行);行尾用 \r?$ 兼容 CRLF
  $m = [regex]::Matches((Get-Content -LiteralPath $l0 -Raw -Encoding UTF8), '(?m)^[ \t]*\|[^|\r\n]*启动顺序[ \t]*\([ \t]*`?BootOrder`?[ \t]*首位[ \t]*\)[ \t]*原值[^|\r\n]*\|(?:[ \t]*[^|\r\n]*\|)*[ \t]*([^|\r\n]*?)[ \t]*\|[ \t]*\r?$')
  $vals = @($m | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ -and $_ -notmatch '照实记录|后续阶段比对基准|判据|不变量|步骤' -and $_ -notin @('-', '无', '未记录') })
  if ($vals.Count -gt 0) { $l0Val = $vals[$vals.Count - 1] }
}
if ($l0Val -and $l0Val -notin @('-', '无', '未记录')) { Add-Row 'L0 基准:启动顺序原值' ('已记录:' + $l0Val) $GREEN }
else { Add-Row 'L0 基准:启动顺序原值' 'L0 产物字段缺失,无法比对启动顺序(baseline/00-firmware.md 缺失或缺少"启动顺序(BootOrder 首位)原值"一行)' $YELLOW }

# 11-12. L1 产物复核与 L1 隔离结论转记(只核验,不重做 L1)
$p01 = Join-Path $BaselineDir '01-partitions.txt'; $a01 = Join-Path $BaselineDir '01-activation.md'
$missingL1 = @(); if (-not (Test-Path -LiteralPath $p01)) { $missingL1 += '01-partitions.txt' }; if (-not (Test-Path -LiteralPath $a01)) { $missingL1 += '01-activation.md' }
$actText = ''; if (Test-Path -LiteralPath $a01) { $actText = Get-Content -LiteralPath $a01 -Raw -Encoding UTF8 }
if ($missingL1.Count -gt 0) { Add-Row 'L1 产物复核' ('缺失:' + ($missingL1 -join '、')) $YELLOW }
elseif ($actText -match '失败|未激活|错误|not activated|fail') { Add-Row 'L1 产物复核' '分区表与激活记录在位;激活记录含失败字样,按黄项登记(不阻塞,后续单独处理)' $YELLOW }
else { Add-Row 'L1 产物复核' '01-partitions.txt 与 01-activation.md 在位' $GREEN }
$isoLines = @()
if (Test-Path -LiteralPath $p01) { $isoLines = @((Get-Content -LiteralPath $p01 -Encoding UTF8) | Where-Object { $_ -match '重定向|User Shell Folders|Personal|D:\\|C: 内容|C:\\Users' }) }
if (-not (Test-Path -LiteralPath $p01)) { Add-Row 'L1 隔离核对结论' '01-partitions.txt 不存在,无法转记' $YELLOW } elseif ($isoLines.Count -eq 0) { Add-Row 'L1 隔离核对结论' 'L1 注记段缺少已知文件夹重定向与 C: 内容核对结论' $YELLOW } else { Add-Row 'L1 隔离核对结论' ('已从 01-partitions.txt 转记 ' + $isoLines.Count + ' 行到本报告') $GREEN }

# 13. I4 基线产物齐备(缺任一即禁止进入 L3)
$needPaths = @{ 'ESP 文件树备份' = (Join-Path $BaselineDir '02-esp-backup\manifest.sha256'); '固件启动项快照' = (Join-Path $BaselineDir '02-firmware-entries.txt'); 'L2 分区快照' = (Join-Path $BaselineDir '02-partitions.txt'); 'L1 分区表定稿' = $p01 }
$miss = @($needPaths.Keys | Where-Object { -not (Test-Path -LiteralPath $needPaths[$_]) })
if ($miss.Count -gt 0) { Add-Row 'I4 基线产物齐备' ('缺失:' + ($miss -join '、') + ';先跑 backup-esp.ps1 再重跑本脚本') $RED } else { Add-Row 'I4 基线产物齐备' 'ESP 备份清单、固件启动项快照、L2 分区快照、L1 分区表均在位' $GREEN }

# 14. 系统版本(记录即可;Win11 的注册表 ProductName 仍写 "Windows 10 Pro",故优先用 CIM Caption)
$cap = ''; try { $cap = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $cap = '' }
$cvPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$ver = @('ProductName', 'DisplayVersion', 'CurrentBuild', 'UBR') | ForEach-Object { Read-RegValue $cvPath $_ }
if (-not $cap) { $cap = $ver[0] }
Add-Row '系统版本' (@($cap, $ver[1], ('Build ' + $ver[2] + '.' + $ver[3])) -join ' / ') $GREEN

# 汇总与报告正文(-Only 只保留选中段的行;结论也只由选中段得出)
if ($onlyRe) { $rows = @($rows | Where-Object { $_.Item -match $onlyRe }); $notes = @() }
$reds = @($rows | Where-Object { $_.Verdict -eq $RED }); $yellows = @($rows | Where-Object { $_.Verdict -eq $YELLOW })
$redList = '无'; if ($reds.Count -gt 0) { $redList = ($reds | ForEach-Object { $_.Item }) -join '、' }
$yellowList = '无'; if ($yellows.Count -gt 0) { $yellowList = ($yellows | ForEach-Object { $_.Item }) -join '、' }
$verdictLine = '结论: 允许进入 L3'; if ($reds.Count -gt 0) { $verdictLine = '结论: 禁止进入 L3' }

# 查询模式:-Json 只输出一行 JSON、-Only 只打印选中段的表行;两者都不写报告文件(退出码按选中段的红项)
$arr = @($rows | ForEach-Object { '{"item":"' + (EscJ $_.Item) + '","value":"' + (EscJ $_.Value) + '","verdict":"' + $_.Verdict + '"}' })
$rc = 0; if ($reds.Count -gt 0) { $rc = 1 }
if ($Json) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); Write-Output ('{"script":"preflight","only":"' + (EscJ $Only) + '","rows":[' + ($arr -join ',') + '],"red":' + $reds.Count + ',"yellow":' + $yellows.Count + ',"verdict":"' + $verdictLine + '"}'); exit $rc }
if ($onlyRe) { foreach ($r in $rows) { Write-Output ('| ' + $r.Item + ' | ' + $r.Value + ' | ' + $r.Verdict + ' |') }; Write-Output ('段:' + $Only + ';行数 ' + $rows.Count + ';红 ' + $reds.Count + ';黄 ' + $yellows.Count); exit $rc }

$table = ($rows | ForEach-Object { '| ' + $_.Item + ' | ' + $_.Value + ' | ' + $_.Verdict + ' |' }) -join "`r`n"
$noteText = '- 无'; if ($notes.Count -gt 0) { $noteText = ($notes | ForEach-Object { '- ' + $_ }) -join "`r`n" }
$isoText = '- 未取到可转记的行(见"检查项与判定"中"L1 隔离核对结论"一行)'
if ($isoLines.Count -gt 0) { $isoText = (@($isoLines | Select-Object -First 30) | ForEach-Object { '- ' + $_.Trim() }) -join "`r`n" }

$md = @'
# L2 预检报告

- 生成时间:<GEN>;基线目录:<BASE>
- 运行模式:只读(本脚本不修改系统任何设置;唯一的写动作是生成本报告)
- 判定口径:红 = 禁止进入 L3;黄 = 记录后继续;绿 = 通过
- 结论有效性前提:本报告必须在**管理员会话**中生成;非管理员会话下若干项读不到,脚本一律判"禁止进入 L3"

## 检查项与判定

| 检查项 | 实测值 | 判定 |
|---|---|---|
<TABLE>

## 补充说明
<NOTES>
- 分区表是否"未被后续操作改变"由人工比对:本报告的"最大连续未分配空间"(盘尾空隙只作参考,WinRE 占盘尾)与 ESP 尺寸对照 baseline/01-partitions.txt 的定稿值,不一致时按黄项处理并在此处说明。
- ESP 目标尺寸为 2GiB;实测低于 2048MB 时本表仍可能判绿,但属偏差,须记入设备偏差并回写文档。红项修复后、基线产物补齐后,都必须重跑本脚本。

## L1 隔离核对结论(从 baseline/01-partitions.txt 转记)

<ISO>

## 结论
- 红项:<REDS>;黄项:<YELLOWS>

<VERDICT>
'@
$md = $md.Replace('<GEN>', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')).Replace('<BASE>', $BaselineDir)
$md = $md.Replace('<TABLE>', $table).Replace('<NOTES>', $noteText).Replace('<ISO>', $isoText)
$md = $md.Replace('<REDS>', $redList).Replace('<YELLOWS>', $yellowList).Replace('<VERDICT>', $verdictLine)

$outFull = [System.IO.Path]::GetFullPath($OutFile)
$outDir = Split-Path -Parent $outFull
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllText($outFull, (($md -replace "`r?`n", "`r`n").TrimEnd() + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('报告已写入:' + $outFull)
Write-Host $verdictLine
if ($reds.Count -gt 0) { exit 1 } else { exit 0 }
