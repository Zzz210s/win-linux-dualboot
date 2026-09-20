#Requires -Version 5.1
# 对应卡:03-9
<#
.SYNOPSIS
  轨道 W:落 L2 产物——核对 L2 四件产物齐全且可读(产物由 03-6 的 preflight.ps1 与 03-8 的 backup-esp.ps1 生成)。
.DESCRIPTION
  四件产物(design 4.3 与 baseline/README.md 的 L2 各行;缺任一即 I4 不满足、禁止进入 L3):
    02-preflight-report.md   闸门报告:必须在位且含结论行(结论: 允许进入 L3 / 禁止进入 L3);
    02-esp-backup/           ESP 全量文件树:必须在位且含 EFI/ 子树与 manifest.sha256(清单逐行可解析);
    02-firmware-entries.txt  固件启动项快照:BootOrder 与 {bootmgr} 的对比基准;
    02-partitions.txt        分区快照:核验 L1 定稿的分区表未被改动。
  另附核对 L1 两件(01-partitions.txt / 01-activation.md):它们是报告"I4 基线产物齐备"一行的输入。
  本卡无自动写动作:-Apply 与 -Check 等价(只做核对与打印);产物的生成分别属于 03-6 与 03-8。
  退出码:0 四件齐备且结论为允许进入 L3 / 1 缺件、不可读或结论为禁止 / 64 用法错误。
  参数:-BaselineDir <基线目录> 缺省 baseline(多设备时指到 baseline\\<设备别名>)。
  本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。用法(仓库根):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\collect-l2.ps1 -Check
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$BaselineDir = 'baseline'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'collect-l2' }

$base = [System.IO.Path]::GetFullPath($BaselineDir)
Add-DbkCheck ('基线目录:' + $base)
$missing = @(); $bad = @()

# 1. 闸门报告:在位 + 含结论行
$rep = Join-Path $base '02-preflight-report.md'
if (-not (Test-Path -LiteralPath $rep)) { $missing += '02-preflight-report.md'; Add-DbkCheck '失败项:02-preflight-report.md 缺失(由 03-6 的 preflight.ps1 生成)' }
else {
  $text = [System.IO.File]::ReadAllText($rep, [System.Text.Encoding]::UTF8)
  $verdict = ''
  foreach ($l in ($text -split "`r?`n")) { if ($l -match '^结论:\s*(允许|禁止)进入 L3') { $verdict = $Matches[1] } }
  if (-not $verdict) { $bad += '02-preflight-report.md'; Add-DbkCheck '失败项:02-preflight-report.md 没有结论行("结论: 允许进入 L3"或"禁止进入 L3");报告不完整,重跑 03-6' }
  elseif ($verdict -eq '禁止') { $bad += '闸门结论'; Add-DbkCheck '失败项:报告结论为"禁止进入 L3"(红项未清);按 03-7 的出错时:处置,不得进入 L3' }
  else { Add-DbkCheck ('02-preflight-report.md 在位,' + $text.Length + ' 字符,结论"允许进入 L3"') }
}

# 2. ESP 文件树备份:目录 + EFI/ 子树 + manifest.sha256 可解析
$esp = Join-Path $base '02-esp-backup'
$man = Join-Path $esp 'manifest.sha256'
$efiDir = Join-Path $esp 'EFI'
if (-not (Test-Path -LiteralPath $esp)) { $missing += '02-esp-backup/'; Add-DbkCheck '失败项:02-esp-backup/ 缺失(由 03-8 的 backup-esp.ps1 生成)' }
else {
  if (Test-Path -LiteralPath $efiDir) {
    $files = @(Get-ChildItem -LiteralPath $esp -Recurse -File -Force | Where-Object { $_.Name -ne 'manifest.sha256' })
    Add-DbkCheck ('02-esp-backup/ 在位:EFI/ 子树 ' + @(Get-ChildItem -LiteralPath $efiDir -Recurse -File -Force).Count + ' 个文件,清单外文件 ' + $files.Count + ' 个')
  } else { $missing += '02-esp-backup/EFI/'; Add-DbkCheck ('失败项:' + $efiDir + ' 不存在(备份树不完整,重跑 03-8)') }
  if (Test-Path -LiteralPath $man) {
    $rows = @([System.IO.File]::ReadAllLines($man, [System.Text.Encoding]::UTF8) | Where-Object { $_ -and $_.Trim() })
    $okRows = @($rows | Where-Object { $_ -match '^[0-9a-fA-F]{64}\s{2}\S' })
    if ($rows.Count -eq 0) { $bad += 'manifest.sha256'; Add-DbkCheck '失败项:manifest.sha256 是空文件(重跑 03-8)' }
    elseif ($okRows.Count -ne $rows.Count) { $bad += 'manifest.sha256'; Add-DbkCheck ('失败项:manifest.sha256 有 ' + ($rows.Count - $okRows.Count) + ' 行不是"<64 位十六进制>  <相对路径>"(重跑 03-8)') }
    else { Add-DbkCheck ('manifest.sha256 在位:' + $rows.Count + ' 行,逐行格式合法(可用 03-8 的 backup-esp.ps1 -Check 复验哈希)') }
  } else { $missing += '02-esp-backup/manifest.sha256'; Add-DbkCheck '失败项:manifest.sha256 缺失(重跑 03-8)' }
}

# 3-4. 固件启动项快照与分区快照:在位 + 非空 + 内容标记
$probe = @(
  @{ Name = '02-firmware-entries.txt'; Mark = 'firmware'; Who = '03-8 的 backup-esp.ps1'; What = 'bcdedit /enum firmware 与 {bootmgr} 快照' },
  @{ Name = '02-partitions.txt';       Mark = 'diskpart'; Who = '03-8 的 backup-esp.ps1'; What = '分区快照' }
)
foreach ($p in $probe) {
  $f = Join-Path $base $p.Name
  if (-not (Test-Path -LiteralPath $f)) { $missing += $p.Name; Add-DbkCheck ('失败项:' + $p.Name + ' 缺失(由 ' + $p.Who + ' 生成,' + $p.What + ')'); continue }
  $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
  if ($t.Trim().Length -eq 0) { $bad += $p.Name; Add-DbkCheck ('失败项:' + $p.Name + ' 是空文件(重跑 ' + $p.Who + ')'); continue }
  if ($t -notmatch $p.Mark) { $bad += $p.Name; Add-DbkCheck ('失败项:' + $p.Name + ' 里没有 "' + $p.Mark + '" 标记,内容不像预期快照(重跑 ' + $p.Who + ')'); continue }
  Add-DbkCheck ($p.Name + ' 在位:' + $t.Length + ' 字符,' + $p.What)
}

# 附:L1 两件(报告"I4 基线产物齐备"一行的输入)
foreach ($n in @('01-partitions.txt', '01-activation.md')) {
  $f = Join-Path $base $n
  if (Test-Path -LiteralPath $f) { Add-DbkCheck ('附:L1 产物 ' + $n + ' 在位(' + (Get-Item -LiteralPath $f).Length + ' 字节)') }
  else { $bad += $n; Add-DbkCheck ('失败项:附:L1 产物 ' + $n + ' 缺失(03-5 的 collect-l1.ps1 生成;报告会把 L1 产物复核判黄)') }
}

Add-DbkAction '四件产物的回滚用法(ESP 复原)见 07-rescue.md;本卡只核对齐备性,不改任何内容'
if ($missing.Count -gt 0) {
  Write-DbkExit -Status FAIL -Message ('L2 产物缺 ' + $missing.Count + ' 件:' + ($missing -join '、') + ';补齐后重跑本脚本(生成者见 checks 的失败项行)')
}
if ($bad.Count -gt 0) {
  Write-DbkExit -Status FAIL -Message ('L2 产物有 ' + $bad.Count + ' 项不合规:' + ($bad -join '、') + ';按 checks 的失败项行处置后重跑')
}
Write-DbkExit -Status PASS -Message ('L2 四件产物齐备且结论为"允许进入 L3":' + $base)
