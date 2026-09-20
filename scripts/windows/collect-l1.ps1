#Requires -Version 5.1
# 对应卡:03-5
<#
.SYNOPSIS
  轨道 W:落 L1 产物。缺省 -Check 只打印将写入的内容(零写);-Apply 才写 baseline\01-partitions.txt 与 baseline\01-activation.md。
.DESCRIPTION
  01-partitions.txt = 分区表定稿值 vs 实测 + WinRE 落点与未分配空间偏差 + diskpart 原始输出 + 卷标 + 注记段(重定向核对 / C: 内容核对,
  人工补记、重跑沿用);01-activation.md = slmgr /dlv + 执行日期 + 上游项目版本号。字段真源:design 4.2 与 baseline/README.md。
  -Apply 幂等(注记段与上游版本号沿用人工填写内容);激活动作人工(03-4),本脚本不含也不分发激活脚本本体。
  退出码:0 通过 / 1 失败(分区表读不到) / 2 需人工(注记段未补记、激活未成功) / 64 用法错误。
  夹具钩子(仅离线验证,真机留空):DBK_PART_LAYOUT=<JSON>(形状见 dbk-win-probe.ps1 文件头);DBK_L1_PART_RAW=<文件> diskpart 输出;
    DBK_L1_LABELS=<文件> 卷标行;DBK_L1_NOTE=<文件> 注记段行;DBK_L1_ACT_RAW=<文件> slmgr 输出;DBK_L1_UPSTREAM=<文本> 上游版本号。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法(仓库根、管理员会话):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\collect-l1.ps1 [-Apply]
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes, [switch]$WithXpr,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$OutDir = 'baseline', [string]$Template = '', [int]$Disk = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'collect-l1' }
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
if (-not $Template) { $Template = Join-Path $repoRoot 'templates\partitions.txt' }
$outFull = [System.IO.Path]::GetFullPath($OutDir)
$partFile = Join-Path $outFull '01-partitions.txt'
$actFile = Join-Path $outFull '01-activation.md'
$NOTE_HEAD = '## 4. 注记(人工补记:已知文件夹重定向核对 / C: 内容核对)'

function Read-FixtureLines {
  param([string]$Path)
  if (-not $Path) { return @() }
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-DbkNote ('用法错误: 夹具钩子指向的文件不存在: ' + $Path); exit $script:DBK_USAGE
  }
  return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}

$L = Get-DbkPartsLayout -Disk $Disk
$targets = @(Get-DbkTargetLayout -Template $Template)
$gapMB = Get-DbkMaxGapMB -Rows $L.Rows -SizeMB $L.DiskMB
$rec = @($L.Rows | Where-Object { $_.Kind -eq 'recovery' })
$cmp = @($L.Rows | Where-Object { $_.Kind -ne 'recovery' -and $_.Kind -ne 'unknown' })
$dpRaw = '(未采集:' + $L.Reason + ')'
if ($env:DBK_L1_PART_RAW) { $dpRaw = (Read-FixtureLines -Path $env:DBK_L1_PART_RAW) -join "`r`n" }
elseif ($L.Ok) {
  $dpIn = "select disk 0`r`nlist disk`r`nlist partition`r`nlist volume`r`ndetail disk`r`nexit`r`n"
  try { $dpRaw = ($dpIn | & diskpart 2>&1 | Out-String).Trim() } catch { $dpRaw = ('diskpart 失败:' + $_.Exception.Message) }
}
$labelLines = @()
if ($env:DBK_L1_LABELS) { $labelLines = @(Read-FixtureLines -Path $env:DBK_L1_LABELS) }
else { foreach ($r in @($L.Rows)) { $labelLines += ('分区 ' + $r.Number + '(' + $r.Kind + '):' + $(if ($r.Label) { $r.Label } else { '(无卷标)' })) } }

# 幂等:注记段与上游版本号沿用上一版产物里的人工填写内容
$prevNote = @(); $prevUpstream = ''
if (Test-Path -LiteralPath $partFile) {
  $old = @([System.IO.File]::ReadAllLines($partFile, [System.Text.Encoding]::UTF8))
  $idx = [array]::IndexOf($old, $NOTE_HEAD)
  if ($idx -ge 0 -and ($idx + 1) -le ($old.Count - 1)) { $prevNote = @($old[($idx + 1)..($old.Count - 1)] | Where-Object { $_ -and $_.Trim() }) }
}
if (Test-Path -LiteralPath $actFile) {
  foreach ($line in [System.IO.File]::ReadAllLines($actFile, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^- 上游项目版本号与执行日期:\s*(.+)$' -and $Matches[1] -notmatch '人工') { $prevUpstream = $Matches[1].Trim() }
  }
}
$noteLines = @('- 已知文件夹重定向核对结论:（人工按 03-3 的看到填写后重跑本脚本,填写内容会被沿用）',
               '- C: 内容核对结论:（人工按 03-3 的看到填写后重跑本脚本,填写内容会被沿用）')
if ($env:DBK_L1_NOTE) { $noteLines = @(Read-FixtureLines -Path $env:DBK_L1_NOTE) }
elseif ($prevNote.Count -gt 0) { $noteLines = @($prevNote) }
$noteFilled = (@($noteLines | Where-Object { $_ -notmatch '人工按 03-3' }).Count -gt 0)

# --- 01-partitions.txt(模板 + 占位替换) ---
$rowText = ''
$names = @('ESP', 'MSR', 'C:(系统)', 'D:(数据)'); $roles = @('efi', 'msr', 'basic', 'basic')
for ($i = 0; $i -lt 4; $i++) {
  $t = ''; if ($i -lt $targets.Count) { $t = [string][math]::Round($targets[$i].SizeMB, 0) }
  $a = ''; $lab = ''
  if ($i -lt $cmp.Count) { $a = [string][math]::Round($cmp[$i].SizeMB, 0); $lab = $cmp[$i].Label }
  $d = '无法比对'
  if ($t -and $a) {
    if ([math]::Abs([double]$t - [double]$a) -le 2) { $d = '无(±2MB 容差内)' } else { $d = '有:' + ([double]$a - [double]$t) + 'MB' }
  }
  $rowText += ('| ' + ($i + 1) + ' | ' + $names[$i] + '(' + $roles[$i] + ') | ' + $t + ' | ' + $a + ' | ' + $d + ' | ' + $lab + " |`r`n")
}
$espNote = '未在首个分区上看到 EFI 分区,需人工复核'
if ($cmp.Count -gt 0 -and $cmp[0].Kind -eq 'efi') { $espNote = [string][math]::Round($cmp[0].SizeMB, 0) + 'MB(未被削减)' }
$recNote = '- WinRE 恢复分区:未看到(装完 Windows 才由安装程序建)'
if ($rec.Count -gt 0) {
  $recNote = '- WinRE 恢复分区:分区 ' + $rec[0].Number + ',' + [math]::Round($rec[0].SizeMB, 0) + 'MB@' + [math]::Round($rec[0].OffsetMB, 0) +
    'MB(落点偏差按"ESP 未削减 + 未分配 >= 115GiB 即接受"记录)'
}
$tpl = @'
# L1 分区表定稿与系统盘隔离记录

- 生成时间:<GEN>
- 生成方式:scripts/windows/collect-l1.ps1 -Apply(卡 03-5;design 4.2)
- 说明:baseline/ 下除 README.md 外一律不入库;多设备时放 baseline/<设备别名>/ 下;注记段的人工补记行会被沿用(幂等)

## 1. 分区表定稿值 vs 实测

| 序号 | 角色 | 目标(MB) | 实测(MB) | 偏差 | 卷标 |
|---|---|---|---|---|---|
<ROWS>
## 2. WinRE 落点与未分配空间(偏差只记录、不修布局)

- 磁盘 0 容量:<DISK> GiB;最大连续未分配 <GAP> GiB(目标 >= 115GiB;盘尾空隙只作参考,WinRE 占盘尾)
<REC>
- ESP 尺寸:<ESP>

## 3. diskpart 原始输出与卷标

```text
<DPRAW>
```
<LABELS>

<NOTEHEAD>
<NOTES>
'@
$labelsText = (@($labelLines | ForEach-Object { '- ' + $_ }) -join "`r`n")
$partText = $tpl.Replace('<GEN>', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')).Replace('<ROWS>', $rowText.TrimEnd())
$partText = $partText.Replace('<DISK>', [string][math]::Round(($L.DiskMB / 1024), 1)).Replace('<GAP>', [string][math]::Round(($gapMB / 1024), 1))
$partText = $partText.Replace('<REC>', $recNote).Replace('<ESP>', $espNote).Replace('<DPRAW>', $dpRaw)
$partText = $partText.Replace('<LABELS>', $labelsText).Replace('<NOTEHEAD>', $NOTE_HEAD).Replace('<NOTES>', (@($noteLines) -join "`r`n"))
$partText = (($partText -replace "`r?`n", "`r`n").TrimEnd() + "`r`n")

# --- 01-activation.md ---
$dlv = ''
if ($env:DBK_L1_ACT_RAW) { $dlv = (Read-FixtureLines -Path $env:DBK_L1_ACT_RAW) -join "`r`n" }
else {
  try { $dlv = ((& cmd.exe /c 'slmgr /dlv' 2>&1) | Out-String).Trim() } catch { $dlv = 'slmgr /dlv 失败:' + $_.Exception.Message }
  if (-not $dlv) { $dlv = 'slmgr /dlv 无输出(需管理员会话)' }
}
$upstream = $prevUpstream
if ($env:DBK_L1_UPSTREAM) { $upstream = $env:DBK_L1_UPSTREAM }
if (-not $upstream) { $upstream = '（人工按 03-4 的上游项目官方入口填写版本号与日期）' }
$atpl = @'
# L1 激活状态记录

- 生成时间:<GEN>
- 生成方式:scripts/windows/collect-l1.ps1 -Apply(卡 03-5)
- 说明:本方案不含也不分发激活脚本本体;激活走上游项目官方入口(见 03-4);激活失败不阻塞 L1,但必须留下失败记录与报错
- 上游项目版本号与执行日期:<UPSTREAM>

## slmgr /dlv

```text
<DLV>
```
'@
$actText = $atpl.Replace('<GEN>', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')).Replace('<UPSTREAM>', $upstream).Replace('<DLV>', $dlv)
if ($WithXpr) {
  $xpr = ''
  try { $xpr = ((& cmd.exe /c 'slmgr /xpr' 2>&1) | Out-String).Trim() } catch { $xpr = 'slmgr /xpr 失败:' + $_.Exception.Message }
  $actText += ("`r`n" + '## slmgr /xpr(辅助)' + "`r`n`r`n" + '```text' + "`r`n" + $xpr + "`r`n" + '```' + "`r`n")
}
$actText = (($actText -replace "`r?`n", "`r`n").TrimEnd() + "`r`n")

Add-DbkAction ('产物路径:' + $partFile)
Add-DbkAction ('产物路径:' + $actFile)
if (-not $L.Ok) { Add-DbkCheck ('失败项:分区表读不到(' + $L.Reason + ');产物按缺值写出,请修好读取条件后重跑') }
else { Add-DbkCheck ('分区表已采集 ' + $L.Rows.Count + ' 行;最大连续未分配 ' + [math]::Round(($gapMB / 1024), 1) + ' GiB') }
if ($noteFilled) { Add-DbkCheck '注记段:已有有效的人工补记内容' }
else { Add-DbkCheck '需人工:注记段(重定向核对 / C: 内容核对)还是默认内容,必须人工补记后重跑(幂等,补记会被沿用)' }
if ($dlv -match '未授权|错误|not activated') { Add-DbkCheck '需人工:slmgr /dlv 输出含未授权/错误字样,按 03-4 处理后重跑(不阻塞 L1)' }

if ($script:DbkMode -eq 'apply') {
  if (-not (Test-Path -LiteralPath $outFull)) { New-Item -ItemType Directory -Path $outFull -Force | Out-Null }
  [System.IO.File]::WriteAllText($partFile, $partText, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($actFile, $actText, (New-Object System.Text.UTF8Encoding($false)))
  Add-DbkAction '已写入两份 L1 产物(重复执行结果一致:注记段与上游版本号沿用人工填写内容)'
  Set-DbkChanged
} else {
  Write-DbkNote ('--- -Check 未落盘,以下是将写入 ' + $partFile + ' 的内容 ---')
  foreach ($dumpLine in ($partText -split "`r?`n")) { Write-DbkNote $dumpLine }
  Write-DbkNote ('--- 另将写入 ' + $actFile + '(' + @($actText -split "`r?`n").Count + ' 行) ---')
  Write-DbkNote '--- 内容结束(-Check 不建目录、不落盘) ---'
}

if (-not $L.Ok) { Write-DbkExit -Status FAIL -Message ('分区表读不到:' + $L.Reason + ';产物已按缺值写出,请修好读取条件(管理员会话)后重跑') }
if (-not $noteFilled) { Write-DbkExit -Status 需人工 -Message '注记段(重定向核对 / C: 内容核对)必须人工补记后重跑;补齐前 L2 会把 L1 隔离结论判黄' }
if ($dlv -match '未授权|错误|not activated') { Write-DbkExit -Status 需人工 -Message '激活未成功:已如实记录到 01-activation.md;按 03-4 处理后再重跑(不阻塞 L1,L2 会登记为黄项)' }
Write-DbkExit -Status PASS -Message ('L1 两份产物已落盘:' + $partFile + ' 与 ' + $actFile)
