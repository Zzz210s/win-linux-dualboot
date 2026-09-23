#Requires -Version 5.1
# 验收总控(Windows 侧;执行器:不进卡映射表、不登记 steps.tsv)。按 docs/08-verification.md 的 A-F 六组逐项判定:
#   能自动的复用 scripts\windows\verify-baseline.ps1 的逐项结论、bcdedit 固件表与 baseline 产物核对;不能自动的
#   记「需人工」并给手动核对步骤。**绝不执行任何 -Apply**:本脚本自己的 -Apply 只表示"把汇总落盘",子脚本一律只被
#   以只读方式调用(夹具断言从不传 -Apply)。汇总只在 -Apply 时落盘 <BaselineDir>\08-verification.md(每台设备副本,
#   含「已知例外」表与结论行);-Check 零写。同一台设备两侧都跑时用 -BaselineDir 分指两个目录,再人工合并为填写版。
#   退出码:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项(加 -ConfirmManual 表示人工项已逐条核对,
#   不再计入退出码)/ 64 用法错误。用法(仓库根、管理员会话):
#     powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-all.ps1 -Check
#   -BaselineDir(缺省 baseline)/-OutDir(缺省与 -BaselineDir 同;汇总写在它下面)/-BaselineScript/-FirmwareText/-GitRoot
#   为夹具注入点。本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。
#   -Step 语义(执行器专用,真源 docs/design/03 第 5 节):取**验收条目关联的卡号**(NN-K),不是第 2 节的
#   「脚本头卡号集合成员判断」——本执行器不绑卡,没有「# 对应卡:」头。合法值 = 本脚本条目表里出现过的卡号
#   (非法时打印可用集合并非零退出 64);`08-A-F` = 六组全判(缺省)。给了 -Step 时**只判定关联到该卡号的条目**,
#   其余条目记「跳过」、不计入退出码(退出码语义不变:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项)。
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes, [switch]$ConfirmManual,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @(),
  [string]$BaselineDir = 'baseline', [string]$BaselineScript = '', [string]$FirmwareText = '', [string]$GitRoot = '', [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $sourceDir '..\..'))
. (Join-Path $sourceDir 'dbk-cli.ps1')
. (Join-Path $sourceDir 'dbk-win-probe.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
# -Step:缺省 '08-A-F' = 六组全判;其它值在条目表建好后按「关联卡号」过滤(非法值 -> 64,见下面的过滤段)。
if (-not $script:DbkStep) { $script:DbkStep = '08-A-F' }
$script:StepSel = ''; if ($script:DbkStep -ne '08-A-F') { $script:StepSel = $script:DbkStep }
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'verify-all' }
if (-not $BaselineScript) { $BaselineScript = Join-Path $repoRoot 'scripts\windows\verify-baseline.ps1' }
if (-not $GitRoot) { $GitRoot = $repoRoot }
$base = [System.IO.Path]::GetFullPath($BaselineDir)
if (-not $OutDir) { $OutDir = $base }
$summary = Join-Path ([System.IO.Path]::GetFullPath($OutDir)) '08-verification.md'
$script:Items = New-Object System.Collections.ArrayList
$script:nPass = 0; $script:nFail = 0; $script:nManual = 0; $script:nSkip = 0
function Get-DbkTag { param([string]$State); switch ($State) {
    'pass' { return 'PASS' } 'fail' { return 'FAIL' } 'skip' { return '跳过' }
    default { if ($ConfirmManual) { return '需人工(已确认)' } return '需人工' } } }
function Add-VerifyItem {
  # 只登记;打印与计数在「-Step 过滤与计数」段(否则 -Step 过滤后的结论会与已打印的行不一致)。
  param([string]$Id, [string]$Group, [string]$State, [string]$Reason, [string]$Card)
  [void]$script:Items.Add([pscustomobject]@{ Id = $Id; Group = $Group; State = $State; Reason = $Reason; Card = $Card })
}
function Add-Manual { param([string]$Id, [string]$Group, [string]$Reason, [string]$Card) Add-VerifyItem $Id $Group 'manual' $Reason $Card }
function Get-VerifyState { param([string]$Id) foreach ($i in $script:Items) { if ($i.Id -eq $Id) { return $i.State } } return '' }

# 复用 07-7 的只读巡检:以子进程方式跑,只传 -BaselineDir(绝不传 -Apply),逐行取 ①/②/③ 的结论。
function Invoke-BaselineCheck {
  $script:BaseOut = ''; $script:BaseRc = 127
  if (-not (Test-Path -LiteralPath $BaselineScript)) { return }
  $exe = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $exe) { return }
  # 不合并 stderr:子脚本按 O2 把失败写 stderr,而 `2>&1` 会把原生 stderr 变成 NativeCommandError,在 Stop 下终止执行器(①/②/③ 行在 stdout,不合并也能解析)
  $script:BaseOut = (& $exe.Source '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $BaselineScript '-BaselineDir' $BaselineDir | Out-String)
  $script:BaseRc = $LASTEXITCODE
}
function Get-BaselineVerdict {
  param([string]$Mark)
  foreach ($l in ($script:BaseOut -split "`r?`n")) {
    if ($l -match ([regex]::Escape($Mark) + '\s*->\s*(通过|需人工介入)')) { return $Matches[1] }
  }
  return ''
}
function Add-BaselineItem {
  param([string]$Id, [string]$Card, [string]$Lab, [string]$Mark)
  $hint = ';手动核对:在 Windows 侧跑 verify-baseline.ps1 -BaselineDir ' + $BaselineDir
  if (-not (Test-Path -LiteralPath $BaselineScript)) { Add-Manual $Id 'A' ($Lab + ':找不到 ' + $BaselineScript + $hint) $Card; return }
  $v = Get-BaselineVerdict $Mark
  if (-not $v) { Add-Manual $Id 'A' ($Lab + ':基线巡检输出里取不到该行(需管理员会话?)' + $hint) $Card }
  elseif ($v -eq '通过') { Add-VerifyItem $Id 'A' 'pass' ($Lab + ':基线巡检判为通过') $Card }
  else { Add-VerifyItem $Id 'A' 'fail' ($Lab + ':基线巡检判为需人工介入,与 L2 基线不一致;处置见 07-6') $Card }
}
# 固件枚举文本 → @{Order;Desc;Path}(BootOrder 的 GUID 序列含跨行续行);解析实现见 dbk-win-probe.ps1。
function Get-FwOrder {
  $t = ''
  if ($FirmwareText) { if (Test-Path -LiteralPath $FirmwareText) { $t = [System.IO.File]::ReadAllText($FirmwareText) } }
  else { try { $t = (& bcdedit /enum firmware 2>&1 | Out-String) } catch { $t = '' } }
  return (Get-DbkFwInfo -Text $t)
}

Invoke-BaselineCheck
$fw = Get-FwOrder
$fo = @($fw.Order)
# ===== A 引导安全组 =====
Add-BaselineItem A1 '07-7' '① BootOrder 首位仍是 Windows Boot Manager' '① BootOrder 首位'
Add-Manual A2 A '连续重启 3 次(不按键、不选菜单),每次都自动进 Windows' '03-8'
Add-BaselineItem A3 '07-7' '② \EFI\Microsoft\ 与 L2 基线逐文件一致' '② ESP\EFI\Microsoft\ 比对'
Add-BaselineItem A4 '07-7' '③ {bootmgr} 的 path 与基线一致' '③ {bootmgr} 的 path'
if ($fo.Count -eq 0) { Add-Manual A5 A '读不到 bcdedit /enum firmware(非管理员或非 UEFI);手动核对:BootOrder 末位是否为 ubuntu' '04-3' }
elseif ([string]$fw.Desc[$fo[$fo.Count - 1]] -match 'ubuntu') { Add-VerifyItem A5 A 'pass' ('BootOrder 末位是 Ubuntu 条目(' + [string]$fw.Desc[$fo[$fo.Count - 1]] + ')') '04-3' }
else { Add-VerifyItem A5 A 'fail' ('BootOrder 末位不是 Ubuntu 条目(实际:' + [string]$fw.Desc[$fo[$fo.Count - 1]] + ');处置见 04-3') '04-3' }
Add-Manual A6 A '复核全部执行记录:没有任何一次 bcdedit /set {fwbootmgr} displayorder 或 efibootmgr -o 调整永久顺序' '07-7'
if ((Get-VerifyState 'A1') -eq 'pass' -and (Get-VerifyState 'A3') -eq 'pass') { Add-VerifyItem A7 A 'pass' '两个 ESP 互不干扰:Windows ESP 逐文件与基线一致且 BootOrder 首位仍是 Windows' '07-7' }
elseif ((Get-VerifyState 'A1') -eq 'fail' -or (Get-VerifyState 'A3') -eq 'fail') { Add-VerifyItem A7 A 'fail' '两个 ESP 不再互不干扰:Windows ESP 或 BootOrder 首位已被改动;处置见 07-6' '07-6' }
else { Add-Manual A7 A '无法从 Windows 侧自动判定;手动核对:两块 ESP 分别可挂载且内容完整、BootOrder 首位仍是 Windows' '07-7' }
Add-Manual A8 A '可撤除性演练:另存 \EFI\ubuntu\ 后删除该子树,连续重启 3 次应自动进 Windows,再还原复测' '07-8'
# ===== B 系统功能组(Kubuntu 侧判定;此处只记需人工) =====
Add-Manual B1 B '在 Kubuntu 侧看 echo $XDG_SESSION_TYPE 应为 wayland,且登录界面无 X11 会话选项' '05-12'
Add-Manual B2 B '在 Kubuntu 侧跑 check-signature.sh --check:nvidia 模块已签名且签名者非空(或 nouveau 兜底)' '05-3'
Add-Manual B3 B '在 Kubuntu 侧 mokutil --sb-state 应为 SecureBoot enabled,且未做过自签密钥导入' '07-7'
Add-Manual B4 B '在 Kubuntu 侧 findmnt /mnt/shared:ntfs3 + rw + nofail;写测试后无残留' '05-1'
Add-Manual B5 B '在 Kubuntu 侧 ubuntu-drivers devices 的推荐驱动与实装一致,apt policy nvidia-driver-* 候选来自 Ubuntu 归档' '05-3'
Add-Manual B6 B '在 Kubuntu 侧 snap 零残留:snap list 空、dpkg -l snapd 无输出、apt-cache policy snapd 无候选或被 pin 到 -1' '05-14'
Add-Manual B7 B '跨系统双向可见性:Windows 写 D:\Shared\dbk-verify-win.txt -> Kubuntu 读到;反向再测一次' '05-1'
Add-Manual B8 B '在 Kubuntu 侧六项 XDG 目录都指向 /mnt/shared 下(桌面/文档/下载/图片/视频/音乐)' '05-2'
Add-Manual B9 B '在 Kubuntu 侧 timedatectl 的 RTC in local TZ 应为 no;切到 Windows 复核时间一致' '05-4'
Add-Manual B10 B '切换系统后蓝牙无需重新配对(三趟往返都能直连)' '05-5'
Add-Manual B11 B '在 Kubuntu 侧 fwupdmgr get-devices 应至少列出一项设备(UEFI 固件/NVMe)' '05-12'

# ===== C 双系统切换组 / D 可撤除性组(必须实机切换或真做) =====
Add-Manual C1 C '从 Windows 用 set-bootnext.ps1 或固件菜单键一次性进 Linux' '05-11'
Add-Manual C2 C '一次性入口用掉后再重启应自动回 Windows,且 BootOrder 与基线逐字一致' '05-11'
Add-Manual C3 C '切换 3 轮后 A1/A3/A4(必要时 A5)复检仍成立' '07-7'
Add-Manual D1 D '按 L5 五步顺序完整推演(参考设备真做一次);参考设备不做即该设备 D 组不成立' '07-9'
Add-Manual D2 D '结束后固件条目与实际状态一致、BootOrder 首位仍是 Windows Boot Manager' '07-12'
Add-Manual D3 D '逐项核对:六个已知文件夹与游戏库都在 D:,C: 不含用户数据(重定向动作见 03-3)' '03-3'
Add-Manual D4 D '原地重装两法各推演一次(参考设备至少真做一法:只格 C:,或只格 root)' '07-4'
Add-Manual D5 D '重装后 A 组四条不变量复检通过(A3 按预期差异口径判读)' '07-4'
Add-Manual D6 D '非重装逃生路径:从 02-esp-backup 还原 \EFI\Microsoft\ 并 bcdboot 重建后可正常启动' '07-6'
$missing = @()   # ===== E 记录组(产物齐备与未入库) =====
foreach ($f in @('00-firmware.md', '01-partitions.txt', '01-activation.md', '02-preflight-report.md', '02-firmware-entries.txt', '02-partitions.txt', '02-esp-backup\manifest.sha256', '03-efi-layout.txt', '04-first-boot.md', '04-robustness.md', '08-verification.md')) {
  if (-not (Test-Path -LiteralPath (Join-Path $base $f))) { $missing += $f }
}
if ($missing.Count -gt 0) { Add-VerifyItem E1 E 'fail' ('baseline 产物缺失:' + ($missing -join ' ') + '(见 baseline/README.md 命名规范)') '03-9' }
else { Add-VerifyItem E1 E 'pass' ('baseline 十一件产物齐全(' + $base + ')') '03-9' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Add-Manual E2 E '未找到 git;手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md' '03-9' }
else {
  # 同理不合并 git 的 stderr(它把 CRLF 等警告写 stderr,合并后同样终止执行器,还可能把警告文字误当 baseline/ 命中)
  $gs = (& git -C $GitRoot status --porcelain | Out-String); $grc1 = $LASTEXITCODE
  $tracked = @(& git -C $GitRoot ls-files baseline/ | Where-Object { $_ -and $_.Trim() -ne 'baseline/README.md' }); $grc2 = $LASTEXITCODE
  if ($grc1 -ne 0 -or $grc2 -ne 0) { Add-Manual E2 E ('git 读不到工作区(' + $GitRoot + ');手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md') '03-9' }
  elseif ($gs -match 'baseline/') { Add-VerifyItem E2 E 'fail' ('baseline/ 内容混进了工作区:' + (($gs -split "`r?`n" | Where-Object { $_ -match 'baseline/' }) -join ' ')) '03-9' }
  elseif ($tracked.Count -gt 0) { Add-VerifyItem E2 E 'fail' 'baseline/ 已被 git 追踪(只允许 baseline/README.md)' '03-9' }
  else { Add-VerifyItem E2 E 'pass' 'baseline/ 未入库(仅 README.md 被追踪)' '03-9' }
}
Add-Manual E3 E '本次与设备参数表的偏差已回写 baseline/ 或 00-overview.md 的偏离项处置表' '07-7'
Add-Manual E4 E '所有未勾选项都整理成已知例外(条目/原因/影响面/是否阻塞/后续动作)' '08'
Add-Manual E5 E '至少一台设备 A-F 全绿(或例外都不阻塞),方可称参考实现' '08'

# ===== F 健壮性组(Kubuntu 侧判定;此处只记需人工) =====
Add-Manual F1 F '包级回退演练 + 原地重装演练(真做一次):按 05-9 降级并 apt-mark hold,重启复测后 --unhold;并按 07-4/07-5 推演原地重装,确认 D: 数据哈希不变' '05-9'
Add-Manual F2 F '在 Kubuntu 侧 rollback-pkg.sh --list <包> 能列出可用版本;--check 能读出 apt-mark hold 清单与 apt 历史' '05-9'
Add-Manual F3 F '在 Kubuntu 侧变更前备份与留档可用:baseline/ 与 /etc 关键文件有 .dbk.bak,apt pin 与 Mozilla 源在升级前留档' '05-13'
Add-Manual F4 F '在 Kubuntu 侧 /var/log/journal 存在且 journalctl --list-boots 至少两条' '05-7'
Add-Manual F5 F '在 Kubuntu 侧 set-updates.sh --check:apt 片段 Automatic-Reboot "false" 且 Allowed-Origins 只列 -security' '05-7'
Add-Manual F6 F '在 Kubuntu 侧 systemctl is-active sshd 应为 active,并从另一台机器 ssh 登录成功' '05-8'
Add-Manual F7 F '在 Kubuntu 侧 systemd-oomd 为 active 且 zramctl 有 /dev/zram0' '05-6'
Add-Manual F8 F '在 Kubuntu 侧 smartd 为 active 且 smartctl -H 报 PASSED' '05-8'
Add-Manual F9 F '在 Kubuntu 侧 fstab 非 root 条目都带 nofail,/boot/efi 不带' '05-1'

# ===== -Step 过滤与计数(执行器 -Step 语义:见脚本头与设计 03 第 5 节)=====
$known = @($script:Items | ForEach-Object { $_.Card } | Sort-Object -Unique)
if ($script:StepSel -and ($known -notcontains $script:StepSel)) {
  Show-DbkUsage
  Write-DbkNote ('用法错误: -Step ' + $script:StepSel + ' 不在本执行器(验收总控)的验收条目集合里;可用值:' + ($known -join '、') + ';08-A-F = 六组全判(缺省)')
  exit $script:DBK_USAGE
}
foreach ($i in $script:Items) {
  if ($script:StepSel -and $i.Card -ne $script:StepSel) { $i.State = 'skip'; $i.Reason = ('未选中(-Step ' + $script:StepSel + ' 只判卡 ' + $script:StepSel + '):' + $i.Reason) }
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
  $out = @(
    '# 验收汇总:A-F 六组逐项判定', '',
    ('- 设备:' + $env:COMPUTERNAME),
    '- 判定侧:Windows(管理员会话)',
    ('- 生成时间:' + (Get-Date).ToString('yyyy-MM-dd HH:mm:sszzz')),
    '- 判定脚本:`scripts/windows/verify-all.ps1`(执行器,不进卡映射表)',
    '- 依据:`docs/08-verification.md`(唯一判据)', '',
    '## 逐项结果', '', '| 项 | 组 | 结论 | 原因 | 关联卡 |', '|---|---|---|---|---|'
  )
  foreach ($i in $script:Items) { $out += ('| ' + $i.Id + ' | ' + $i.Group + ' | ' + (Get-DbkTag $i.State) + ' | ' + ($i.Reason -replace '\|', '\|') + ' | ' + $i.Card + ' |') }
  $out += @('', '## 失败项', '')
  $fails = @($script:Items | Where-Object { $_.State -eq 'fail' })
  if ($fails.Count -eq 0) { $out += '（无）' } else { foreach ($i in $fails) { $out += ('- ' + $i.Id + ' ' + $i.Reason + '(关联卡 ' + $i.Card + ')') } }
  $out += @('', '## 已知例外', '', '未通过项的唯一合法归宿;逐条填写条目/原因/影响面/是否阻塞/后续动作,无例外时保留(无)。', '',
    '| 条目 | 原因 | 影响面 | 是否阻塞 | 后续动作 |', '|---|---|---|---|---|', '| （无） |  |  |  |  |', '', '## 结论', '', ('结论: ' + $concl))
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText(($summary + '.new'), (($out -join "`r`n") + "`r`n"), $utf8)
  Move-Item -LiteralPath ($summary + '.new') -Destination $summary -Force
  Write-DbkNote ('汇总已写:' + $summary)
}
exit (Get-DbkStatusCode $overall)
