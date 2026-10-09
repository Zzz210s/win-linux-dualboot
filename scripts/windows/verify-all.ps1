#Requires -Version 5.1
# 验收总控(Windows 侧;执行器:不进卡映射表、不登记 steps.tsv)。条目表真源 = scripts\verification-items.tsv(A-H 八组 51 条):
#   本脚本只读它,按「侧」与「编号」分派判定 —— 侧 = L(在 Fedora 侧判)的条目在本侧记「需人工」并注明在 Fedora 侧跑;
#   判定脚本 = - 的条目按标签记「需人工」(标签即人工核对步骤);其余走本侧内置探测(按编号分派:复用
#   scripts\windows\verify-baseline.ps1 的 ①/②/③ 结论、bcdedit 固件表、baseline 产物与 git 核对)。增删条目只改那张表。
#   **绝不执行任何 -Apply**:本脚本自己的 -Apply 只表示"把汇总落盘",子脚本一律只被以只读方式调用(夹具断言从不传 -Apply)。
#   汇总只在 -Apply 时落盘 <OutDir>\08-verification.md(每台设备副本,含「已知例外」表与结论行);-Check 零写。
#   退出码:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项(加 -ConfirmManual 表示人工项已逐条核对,
#   不再计入退出码)/ 64 用法错误。用法(仓库根、管理员会话):
#     powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-all.ps1 -Check
#   注入点:-BaselineDir(缺省 baseline)/-OutDir(缺省 <BaselineDir>\auto;缺省落点避开手填的 <BaselineDir>\08-verification.md);
#   -ItemsTsv 或环境变量 DBK_ITEMS_TSV(换一张条目表,夹具用)。本文件必须保存为 UTF-8 with BOM。
#   -Step 语义(执行器专用,真源 docs/design/03 第 5 节,与 Linux 侧 verify-all.sh 同口径):`08-A-G`/`08-A-H` = 八组全判(缺省);
#   `08-A`…`08-H` = 只判该组(过滤条目表的**组**列);其它值 = 验收条目关联的卡号(NN-K,过滤**卡**列)。非法时打印可用集合
#   并非零退出 64;给了 -Step 时未命中的条目记「跳过」、不计入退出码(退出码语义不变:0/1/2/64)。夹具级验证,真机未跑。
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes, [switch]$ConfirmManual,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$BaselineDir = 'baseline', [string]$BaselineScript = '', [string]$FirmwareText = '', [string]$GitRoot = '', [string]$OutDir = '',
  [string]$ItemsTsv = ''
)
$ErrorActionPreference = 'Stop'
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $sourceDir '..\..'))
. (Join-Path $sourceDir 'dbk-cli.ps1')
. (Join-Path $sourceDir 'dbk-win-probe.ps1')
. (Join-Path $sourceDir 'dbk-items.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
if (-not $script:DbkStep) { $script:DbkStep = '08-A-G' }
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'verify-all' }
if (-not $BaselineScript) { $BaselineScript = Join-Path $repoRoot 'scripts\windows\verify-baseline.ps1' }
if (-not $GitRoot) { $GitRoot = $repoRoot }
$base = [System.IO.Path]::GetFullPath($BaselineDir)
if (-not $OutDir) { $OutDir = Join-Path $base 'auto' }
$summary = Join-Path ([System.IO.Path]::GetFullPath($OutDir)) '08-verification.md'
# 条目表(唯一真源):参数 > 环境变量 > 仓库相对路径;读不到就 64 零写,绝不回退到硬编码条目。
$itemsPath = $ItemsTsv
if (-not $itemsPath) { $itemsPath = [string]$env:DBK_ITEMS_TSV }
if (-not $itemsPath) { $itemsPath = Join-Path $repoRoot 'scripts\verification-items.tsv' }
$table = Read-DbkVerificationItems -Path $itemsPath
if (-not $table.Ok) { Show-DbkUsage; Write-DbkNote ('用法错误: ' + $table.Error + '(条目表随仓库分发,不要手工生成)'); exit $script:DBK_USAGE }
$sel = Get-DbkStepSelection -Items $table.Items -Step $script:DbkStep
if ($sel.Mode -eq 'invalid') {
  Show-DbkUsage
  Write-DbkNote ('用法错误: -Step ' + $script:DbkStep + ' 不在本执行器(验收总控)的验收条目集合里;可用值:' + $sel.Known + ';可用组:08-' + (($sel.Groups -split ' ') -join ' 08-') + ';08-A-G/08-A-H = 八组全判(缺省)')
  exit $script:DBK_USAGE
}
$script:Items = New-Object System.Collections.ArrayList
$script:nPass = 0; $script:nFail = 0; $script:nManual = 0; $script:nSkip = 0
function Get-DbkTag { param([string]$State); switch ($State) {
    'pass' { return 'PASS' } 'fail' { return 'FAIL' } 'skip' { return '跳过' }
    default { if ($ConfirmManual) { return '需人工(已确认)' } return '需人工' } } }
function Add-VerifyItem {
  # 只登记;打印与计数在下面的打印段(否则 -Step 过滤后的结论会与已打印的行不一致)。
  param([string]$Id, [string]$Group, [string]$State, [string]$Reason, [string]$Card)
  [void]$script:Items.Add([pscustomobject]@{ Id = $Id; Group = $Group; State = $State; Reason = $Reason; Card = $Card })
}
function Get-VerifyState { param([string]$Id) foreach ($i in $script:Items) { if ($i.Id -eq $Id) { return $i.State } } return '' }

# 复用 07-7 的只读巡检:以子进程方式跑,只传 -BaselineDir(绝不传 -Apply),逐行取 ①/②/③ 的结论。
$script:BaseOut = ''
function Invoke-BaselineCheck {
  if (-not (Test-Path -LiteralPath $BaselineScript)) { return }
  $exe = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $exe) { return }
  # 不合并 stderr:子脚本按 O2 把失败写 stderr,`2>&1` 会把原生 stderr 变成 NativeCommandError,在 Stop 下终止执行器。
  $script:BaseOut = (& $exe.Source '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $BaselineScript '-BaselineDir' $BaselineDir | Out-String)
}
function Get-BaselineVerdict {
  param([string]$Mark)
  foreach ($l in ($script:BaseOut -split "`r?`n")) { if ($l -match ([regex]::Escape($Mark) + '\s*->\s*(通过|不通过|需人工介入)')) { return $Matches[1] } }
  return ''
}
function Get-DbkBaselineItem {
  # 返回 @{State;Reason};A1/A3/A4 共用一次巡检结果。
  param([string]$Mark, [string]$Lab)
  $hint = ';手动核对:在 Windows 侧跑 verify-baseline.ps1 -BaselineDir ' + $BaselineDir
  if (-not (Test-Path -LiteralPath $BaselineScript)) { return @{ State = 'manual'; Reason = ($Lab + ':找不到 ' + $BaselineScript + $hint) } }
  $v = Get-BaselineVerdict $Mark
  if (-not $v) { return @{ State = 'manual'; Reason = ($Lab + ':基线巡检输出里取不到该行(需管理员会话?)' + $hint) } }
  if ($v -eq '通过') { return @{ State = 'pass'; Reason = ($Lab + ':基线巡检判为通过') } }
  if ($v -eq '需人工介入') { return @{ State = 'manual'; Reason = ($Lab + ':基线巡检判为需人工介入(读不到现场状态或基线产物缺失),需人工核对' + $hint) } }
  return @{ State = 'fail'; Reason = ($Lab + ':基线巡检判为不通过,与 L2 基线不一致;处置见 07-6') }
}
# 固件枚举文本 → @{Order;Desc;Path}(BootOrder 的 GUID 序列含跨行续行);解析实现见 dbk-win-probe.ps1。
function Get-FwOrder {
  $t = ''
  if ($FirmwareText) { if (Test-Path -LiteralPath $FirmwareText) { $t = [System.IO.File]::ReadAllText($FirmwareText) } }
  else { try { $t = (& bcdedit /enum firmware 2>&1 | Out-String) } catch { $t = '' } }
  return (Get-DbkFwInfo -Text $t)
}
function Get-DbkA5Verdict {
  $fo = @($script:Fw.Order)
  if ($fo.Count -eq 0) { return @{ State = 'manual'; Reason = '读不到 bcdedit /enum firmware(非管理员或非 UEFI);手动核对:BootOrder 末位是否为 Linux(Fedora)条目' } }
  $last = [string]$script:Fw.Desc[$fo[$fo.Count - 1]]
  if ($last -match 'ubuntu|fedora') { return @{ State = 'pass'; Reason = ('BootOrder 末位是 Linux 引导条目(' + $last + ')') } }
  return @{ State = 'fail'; Reason = ('BootOrder 末位不是 Linux 引导条目(实际:' + $last + ');处置见 04-3') }
}
function Get-DbkA7Verdict {
  $s1 = Get-VerifyState 'A1'; $s3 = Get-VerifyState 'A3'
  if ($s1 -eq 'pass' -and $s3 -eq 'pass') { return @{ State = 'pass'; Card = '07-7'; Reason = '两个 ESP 互不干扰:Windows ESP 逐文件与基线一致且 BootOrder 首位仍是 Windows' } }
  if ($s1 -eq 'fail' -or $s3 -eq 'fail') { return @{ State = 'fail'; Card = '07-6'; Reason = '两个 ESP 不再互不干扰:Windows ESP 或 BootOrder 首位已被改动;处置见 07-6' } }
  return @{ State = 'manual'; Card = '07-7'; Reason = '无法从 Windows 侧自动判定;手动核对:两块 ESP 分别可挂载且内容完整、BootOrder 首位仍是 Windows' }
}
function Get-DbkArtifactVerdict {
  $missing = @()
  foreach ($f in @('00-firmware.md', '01-partitions.txt', '01-activation.md', '02-preflight-report.md', '02-firmware-entries.txt', '02-partitions.txt', '02-esp-backup\manifest.sha256', '03-efi-layout.txt', '04-first-boot.md', '04-robustness.md', '08-verification.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $base $f))) { $missing += $f }
  }
  if ($missing.Count -gt 0) { return @{ State = 'fail'; Reason = ('baseline 产物缺失:' + ($missing -join ' ') + '(见 baseline/README.md 命名规范)') } }
  return @{ State = 'pass'; Reason = ('baseline 十一件产物齐全(' + $base + ')') }
}
function Get-DbkGitVerdict {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @{ State = 'manual'; Reason = '未找到 git;手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md' } }
  # 同理不合并 git 的 stderr(它把 CRLF 等警告写 stderr,合并后同样终止执行器,还可能把警告文字误当 baseline/ 命中)
  $gs = (& git -C $GitRoot status --porcelain | Out-String); $grc1 = $LASTEXITCODE
  $tracked = @(& git -C $GitRoot ls-files baseline/ | Where-Object { $_ -and $_.Trim() -ne 'baseline/README.md' }); $grc2 = $LASTEXITCODE
  if ($grc1 -ne 0 -or $grc2 -ne 0) { return @{ State = 'manual'; Reason = ('git 读不到工作区(' + $GitRoot + ');手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md') } }
  if ($gs -match 'baseline/') { return @{ State = 'fail'; Reason = ('baseline/ 内容混进了工作区:' + (($gs -split "`r?`n" | Where-Object { $_ -match 'baseline/' }) -join ' ')) } }
  if ($tracked.Count -gt 0) { return @{ State = 'fail'; Reason = 'baseline/ 已被 git 追踪(只允许 baseline/README.md)' } }
  return @{ State = 'pass'; Reason = 'baseline/ 未入库(仅 README.md 被追踪)' }
}
# Windows 侧判定分派(契约见文件头):侧 = L 与判定脚本 = - 一律需人工;其余按编号走内置探测。
function Get-DbkWindowsVerdict {
  param($Item)
  if ($Item.Side -eq 'L') { return @{ State = 'manual'; Reason = ('在 Fedora 侧跑:' + $Item.Label) } }
  if ($Item.Script -eq '-') { return @{ State = 'manual'; Reason = $Item.Label } }
  switch ([string]$Item.Id) {
    'A1' { return (Get-DbkBaselineItem '① BootOrder 首位' '① BootOrder 首位仍是 Windows Boot Manager') }
    'A3' { return (Get-DbkBaselineItem '② ESP\EFI\Microsoft\ 比对' '② \EFI\Microsoft\ 与 L2 基线逐文件一致') }
    'A4' { return (Get-DbkBaselineItem '③ {bootmgr} 的 path' '③ {bootmgr} 的 path 与基线一致') }
    'A5' { return (Get-DbkA5Verdict) }
    'A7' { return (Get-DbkA7Verdict) }
    'E1' { return (Get-DbkArtifactVerdict) }
    'E2' { return (Get-DbkGitVerdict) }
  }
  if ($Item.Script -match '(?i)^scripts/windows/.+\.ps1$') { return @{ State = 'manual'; Reason = ($Item.Label + '(本侧尚未接入该判定脚本的只读调用:' + $Item.Script + ';按标签人工核对)') } }
  return @{ State = 'manual'; Reason = ($Item.Label + '(判定脚本 ' + $Item.Script + ' 在 Windows 侧不可执行,需人工)') }
}
Invoke-BaselineCheck
$script:Fw = Get-FwOrder
# ===== 读条目表逐条判定(顺序即表内顺序);未命中选择符的条目记「跳过」、不判定也不计数 =====
foreach ($it in @($table.Items)) {
  if (-not (Test-DbkItemSelected -Item $it -Selection $sel)) { Add-VerifyItem $it.Id $it.Group 'skip' ((Get-DbkSkipPrefix $script:DbkStep $sel) + $it.Label) $it.Card; continue }
  $v = Get-DbkWindowsVerdict -Item $it
  $card = $it.Card; if ($v.ContainsKey('Card')) { $card = $v.Card }
  Add-VerifyItem $it.Id $it.Group $v.State $v.Reason $card
}
foreach ($i in $script:Items) {
  if ($i.State -eq 'pass') { $script:nPass++ } elseif ($i.State -eq 'fail') { $script:nFail++ } elseif ($i.State -eq 'manual') { $script:nManual++ } else { $script:nSkip++ }
  if (-not $script:DbkJson) { Write-Host ('[' + (Get-DbkTag $i.State) + '] ' + $i.Id + ' ' + $i.Reason) }
}

# ===== 汇总与落盘 =====
if ($script:nFail -gt 0) { $overall = 'fail'; $concl = '不通过(自动判定失败 ' + $script:nFail + ' 项;逐条见下表)' }
elseif ($script:nManual -gt 0 -and -not $ConfirmManual) { $overall = 'manual'; $concl = '待人工(无自动失败,但有 ' + $script:nManual + ' 项需人工核对;逐条见下表)' }
elseif ($script:nManual -gt 0) { $overall = 'pass'; $concl = '通过(人工项 ' + $script:nManual + ' 项已由执行人按清单逐条确认)' }
else { $overall = 'pass'; $concl = '通过(全部 ' + $script:nPass + ' 项自动判定通过)' }
foreach ($i in $script:Items) { Add-DbkCheck ($i.Id + '(' + $i.Group + ') ' + (Get-DbkTag $i.State) + ':' + $i.Reason + ' [关联卡 ' + $i.Card + ']') }
if ($script:DbkJson) { Write-DbkReport -Status $overall -Message $concl }
else {
  Write-Host ('汇总: PASS=' + $script:nPass + ' FAIL=' + $script:nFail + ' 需人工=' + $script:nManual + ' 跳过=' + $script:nSkip + ';每个条目都带编号与关联卡')
  Write-Host ('结论: ' + $concl)
}
if ($script:DbkMode -eq 'apply') {
  if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetFullPath($OutDir)))) { New-Item -ItemType Directory -Path ([System.IO.Path]::GetFullPath($OutDir)) -Force | Out-Null }
  Write-DbkAcceptSummary -Path $summary -Device $env:COMPUTERNAME -Side 'Windows(管理员会话)' `
    -Script '`scripts/windows/verify-all.ps1`(执行器,不进卡映射表)' -Basis '`docs/08-verification.md`(唯一判据)' `
    -Conclusion $concl -ManualConfirmed:$ConfirmManual -Items $script:Items
  Write-DbkNote ('汇总已写:' + $summary)
}
exit (Get-DbkStatusCode $overall)
