# 总控入口(Windows 侧,非步骤脚本):读步骤索引 scripts/windows/steps.tsv,以**子进程**方式运行步骤脚本并汇总。
# 契约真源:docs/design/03-step-automation-design.md 第 5 节(总控入口)与第 2 节(CLI/退出码/2.1 可观测性)。
# 只做分发与汇总,不含业务逻辑:校验步骤号与索引脚本存在 → 透传 -Check/-Apply/-Yes/-Json/-Log → 汇总退出码。
# 破坏性步骤(索引第 3 列 = 1)在 -Apply 且未给 -Yes 时**不调用子脚本**,按用法错误退 64;汇总规则:
#   任一子步骤 1 → 1;无 1 但有 2 → 2;其余(0/9)→ 0;未知步骤或索引脚本缺失 → 64。
# PowerShell 侧兜底:每个步骤脚本都以**子进程**方式运行,并给子进程设 $ErrorActionPreference='Stop'。PS 没有
#   ERR trap,步骤脚本内部的异常可能不留痕迹,所以子进程退出码非 0、或要求 -Json 时 stdout 不是恰好一行可解析
#   JSON,都由本脚步**合成一条失败记录**(含步骤号、子进程退出码、捕获到的 stderr 原文与原因),不静默通过。
# 汇总 JSON:{"steps":[{"step":…,"status":pass|fail|manual|skip,"rc":N,"message":…}],"summary":{pass,fail,manual,skip}}
# 本文件是 C9d 白名单里的库/总控脚本(不写「# 对应卡:」,不登记进 steps.tsv)。测试钩子:$env:DBK_INDEX 覆盖索引。
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Step = @(),
  [switch]$Check, [switch]$Apply, [switch]$Yes, [switch]$Json,
  [string]$Log = ''
)
$ErrorActionPreference = 'Stop'
$script:MasterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoRoot = (Resolve-Path (Join-Path $script:MasterDir '..\..')).Path
. (Join-Path $script:MasterDir 'dbk-cli.ps1')
$script:MasterMode = 'check'; if ($Apply) { $script:MasterMode = 'apply' }
$script:MasterJson = [bool]$Json
$script:MasterYes = [bool]$Yes
$script:MasterUserLog = ''; if ($Log) { $script:MasterUserLog = $Log }
$script:Index = Join-Path $script:MasterDir 'steps.tsv'
if ($env:DBK_INDEX) { $script:Index = $env:DBK_INDEX }
$script:DbkPsExe = 'powershell.exe'
if (-not (Get-Command $script:DbkPsExe -ErrorAction SilentlyContinue)) { $script:DbkPsExe = 'pwsh' }
$script:IndexRows = New-Object System.Collections.ArrayList
$script:Results = New-Object System.Collections.ArrayList

# 读索引:列 = 步骤号 / 脚本路径 / 破坏性(0|1) / 说明;非步骤号开头(表头、注释、空行)一律跳过。
function Get-DbkIndexRows {
  $rows = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $script:Index)) { return $rows }
  foreach ($line in [System.IO.File]::ReadAllLines($script:Index, [System.Text.Encoding]::UTF8)) {
    if (-not $line) { continue }
    $f = $line -split "`t"
    if ($f.Count -lt 3 -or $f[0] -notmatch '^\d{2}-\d+$') { continue }
    [void]$rows.Add([pscustomobject]@{ Step = $f[0]; Path = $f[1]; Destructive = ($f[2] -eq '1') })
  }
  return $rows
}
function Show-DbkMasterUsage {
  $ids = (($script:IndexRows | ForEach-Object { $_.Step }) -join ' ')
  Write-DbkNote @'
用法: scripts/windows/dbk.ps1 <步骤号> [<步骤号>…] [-Check] [-Apply] [-Yes] [-Json] [-Log <路径>]
  读步骤索引分发到对应步骤脚本,汇总每个子步骤的退出码与结论(总控不含业务逻辑)。
  -Check 缺省(只读);-Apply 执行(破坏性步骤必须同时给 -Yes);-Json 输出单行汇总 JSON。
退出码: 0 全部通过 / 1 有失败 / 2 有需人工 / 64 用法错误(未知步骤、索引脚本缺失、破坏性步骤缺 -Yes)
'@
  Write-DbkNote ("索引: " + $script:Index + " ;可用步骤号: " + $ids)
}
function Resolve-DbkStepPath {
  param([string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $script:RepoRoot $Path)
}
function Select-DbkIndexRow {
  param([string]$Id)
  foreach ($r in $script:IndexRows) { if ($r.Step -eq $Id) { return $r } }
  return $null
}
# 子进程运行步骤脚本:走 -Command 包装以显式设子进程的 $ErrorActionPreference='Stop';stdout/stderr 落临时文件
# (字节保真,避免 PS 流重编码),再用 UTF-8 读回。开关必须渲染成裸 token(-Check);带引号的 '-Check'
# 会被参数绑定当成位置参数串,而不是开关。启动失败也返回一条记录,不把总控自己炸掉。
function Invoke-DbkChildStep {
  param([string]$Path, [string]$ArgStr)
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  $cmd = "& { `$ErrorActionPreference = 'Stop'; & '" + ($Path -replace "'", "''") + "'" + $ArgStr + '; exit $LASTEXITCODE }'
  try {
    $p = Start-Process -FilePath $script:DbkPsExe -NoNewWindow -Wait -PassThru `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $cmd + '"')) `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    return [pscustomobject]@{ Rc = $p.ExitCode; Out = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8); Err = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) }
  } catch {
    return [pscustomobject]@{ Rc = -1; Out = ''; Err = ('子进程启动失败: ' + $_.Exception.Message) }
  } finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}
# 子进程输出 → 记录:<步骤号> <状态键> <退出码> <原因>;任一不可判定的情形都合成失败记录并带上 stderr 原文。
function New-DbkStepResult {
  param([string]$Id, [object]$Res)
  $lines = @(); if ($Res.Out) { $lines = @($Res.Out.Trim() -split "`r?`n" | Where-Object { $_ -ne '' }) }
  $errText = ''; if ($Res.Err) { $errText = ($Res.Err.Trim() -replace "`r?`n", ' | ') }
  $key = switch ($Res.Rc) { 0 { 'pass' } 1 { 'fail' } 2 { 'manual' } 9 { 'skip' } default { 'fail' } }
  $parsed = $null; $jsonOk = $false
  if ($script:MasterJson -and $lines.Count -eq 1) {
    try { $parsed = $lines[0] | ConvertFrom-Json; $jsonOk = $true } catch { $jsonOk = $false }
  }
  $msg = ''
  if ($script:MasterJson) { if ($jsonOk) { $msg = [string]$parsed.message } }
  elseif ($lines.Count -gt 0) { $msg = $lines[$lines.Count - 1] -replace '^\[[^\]]*\]\s*', '' }
  $synth = New-Object System.Collections.ArrayList
  if ($script:MasterJson -and -not $jsonOk) { [void]$synth.Add("输出不是恰好一行可解析 JSON(实际 " + $lines.Count + " 行)") }
  if (@(0, 1, 2, 9) -notcontains [int]$Res.Rc) { [void]$synth.Add("子进程退出码 " + $Res.Rc + " 不在 0/1/2/9 契约内") }
  if (($key -eq 'fail' -or $key -eq 'manual') -and -not $msg) { [void]$synth.Add('子进程未给出原因文本') }
  if ($synth.Count -gt 0) {
    $key = 'fail'
    $parts = @("子进程退出码 " + $Res.Rc) + $synth.ToArray()
    if ($errText) { $parts += ('stderr 原文: ' + $errText) }
    $msg = ($parts -join ';')
  }
  return [pscustomobject]@{ Step = $Id; Key = $key; Rc = $Res.Rc; Msg = $msg }
}
function Get-DbkResultLine {
  param([object]$Result)
  $tag = Get-DbkStatusTag $Result.Key
  if ($Result.Msg) { return ("[{0}] {1} rc={2} {3}" -f $tag, $Result.Step, $Result.Rc, $Result.Msg) }
  return ("[{0}] {1} rc={2}" -f $tag, $Result.Step, $Result.Rc)
}
function Get-DbkResultCount {
  param([string]$Key)
  return @($script:Results | Where-Object { $_.Key -eq $Key }).Count
}

if ($Check -and $Apply) { Show-DbkMasterUsage; Write-DbkNote '用法错误: -Check 与 -Apply 互斥,只能给一个'; exit $script:DBK_USAGE }
if (-not $Step -or $Step.Count -eq 0) { Show-DbkMasterUsage; Write-DbkNote '用法错误: 未给步骤号'; exit $script:DBK_USAGE }
if (-not (Test-Path -LiteralPath $script:Index)) { Write-DbkNote ("用法错误: 步骤索引不可读: " + $script:Index); exit $script:DBK_USAGE }
$script:IndexRows = Get-DbkIndexRows
# 先把全部步骤校验完再跑,任何一条不合格 → 64 且零调用。
$plan = New-Object System.Collections.ArrayList
foreach ($id in $Step) {
  $row = Select-DbkIndexRow $id
  if (-not $row) { Show-DbkMasterUsage; Write-DbkNote ("用法错误: 未知步骤 $id(索引 " + $script:Index + " 里没有这一行)"); exit $script:DBK_USAGE }
  $path = Resolve-DbkStepPath $row.Path
  if (-not (Test-Path -LiteralPath $path)) { Write-DbkNote ("用法错误: 索引里声明的脚本不存在: " + $row.Path + "(步骤 $id,解析为 $path)"); exit $script:DBK_USAGE }
  if ($row.Destructive -and $script:MasterMode -eq 'apply' -and -not $script:MasterYes) {
    Write-DbkNote ("用法错误: 破坏性步骤 $id 的 -Apply 必须显式给 -Yes;未调用任何子脚本")
    Write-DbkNote '影响:该步骤会改动系统状态;确认无误后加 -Yes 重跑。'
    exit $script:DBK_USAGE
  }
  [void]$plan.Add([pscustomobject]@{ Step = $id; Path = $path })
}
# 缺省日志路径沿用库约定(显式给了 -Log 时不动);只有失败路径才会真的落盘。
if (-not $script:MasterUserLog) { Set-DbkLogDefault -Name 'dbk' }
foreach ($item in $plan) {
  $argStr = ''
  if ($script:MasterMode -eq 'apply') { $argStr += ' -Apply' } else { $argStr += ' -Check' }
  if ($script:MasterYes) { $argStr += ' -Yes' }
  if ($script:MasterJson) { $argStr += ' -Json' }
  if ($script:MasterUserLog) { $argStr += " -Log '" + ($script:MasterUserLog -replace "'", "''") + "'" }
  $raw = Invoke-DbkChildStep -Path $item.Path -ArgStr $argStr
  if ($raw.Err -and $raw.Err.Trim()) { Write-DbkNote $raw.Err.TrimEnd() }
  $r = New-DbkStepResult -Id $item.Step -Res $raw
  [void]$script:Results.Add($r)
  $line = Get-DbkResultLine -Result $r
  if (-not $script:MasterJson) {
    if ($raw.Out) { Write-Output $raw.Out.TrimEnd() }
    Write-Output $line
  }
  if ($r.Key -eq 'fail' -or $r.Key -eq 'manual') { Write-DbkNote $line }
}
$nPass = Get-DbkResultCount 'pass'; $nFail = Get-DbkResultCount 'fail'
$nManual = Get-DbkResultCount 'manual'; $nSkip = Get-DbkResultCount 'skip'
if ($nFail -gt 0 -or $nManual -gt 0) {
  Write-DbkLog ("汇总: pass=$nPass fail=$nFail manual=$nManual skip=$nSkip")
  foreach ($r in $script:Results) { Write-DbkLog (Get-DbkResultLine -Result $r) }
}
if ($script:MasterJson) {
  $parts = @()
  foreach ($r in $script:Results) {
    $parts += ('{"step":"' + (ConvertTo-DbkJson $r.Step) + '","status":"' + $r.Key + '","rc":' + $r.Rc + ',"message":"' + (ConvertTo-DbkJson $r.Msg) + '"}')
  }
  Write-Output ('{"steps":[' + ($parts -join ',') + '],"summary":{"pass":' + $nPass + ',"fail":' + $nFail + ',"manual":' + $nManual + ',"skip":' + $nSkip + '}}')
} elseif ($nFail -gt 0 -or $nManual -gt 0) {
  Write-Output ("[汇总] pass=$nPass fail=$nFail manual=$nManual skip=$nSkip")
}
if ($nFail -gt 0) { exit $script:DBK_FAIL }
if ($nManual -gt 0) { exit $script:DBK_MANUAL }
exit $script:DBK_PASS
