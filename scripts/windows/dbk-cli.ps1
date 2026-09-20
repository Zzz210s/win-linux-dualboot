# 库文件:非步骤脚本
# 用途:步骤脚本的统一 CLI 契约(Windows 侧):参数解析、退出码常量、报告与 JSON 汇总。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(CLI 与退出码)、第 7 节(夹具要求)。
# 用法(步骤脚本 dot-source 本文件后依次调用):Parse-DbkArgs(开关与取值)→ Assert-DbkStep(与脚本头
#   「# 对应卡:NN-K」比对,不一致 64)→ Add-DbkCheck / Assert-DbkYes / Add-DbkAction / Set-DbkChanged
#   → Write-DbkExit -Status PASS|FAIL|需人工|跳过 -Message <说明>。
# 输出:文本模式行首 `[PASS]`/`[FAIL]`/`[需人工]`/`[跳过]`;-Json 时只有 Write-DbkExit 写 stdout(单行 JSON),
#   其余人读信息一律走 Write-DbkNote(写 stderr)。Assert-DbkYes 只在 -Apply 分支调用。
# 只读保证:本文件只定义函数与常量,不写任何路径(只有显式 -Log 才把路径记进 $script:DbkLog)。
# 夹具级验证,真机未跑。

$script:DBK_PASS = 0
$script:DBK_FAIL = 1
$script:DBK_MANUAL = 2
$script:DBK_SKIP = 9
$script:DBK_USAGE = 64

# 解析结果在这里预置默认值,避免调用方漏调 Parse-DbkArgs 时读到未定义变量。
$script:DbkMode = 'check'
$script:DbkJson = $false
$script:DbkYes = $false
$script:DbkLog = ''
$script:DbkStep = ''
$script:DbkLastStatus = ''
$script:DbkChanged = $false
$script:DbkChecks = New-Object System.Collections.ArrayList
$script:DbkActions = New-Object System.Collections.ArrayList

# 人读信息一律走 stderr(保证 -Json 模式下 stdout 只有 Write-DbkExit 的单行 JSON)。
function Write-DbkNote { param([string]$Message = '') [Console]::Error.WriteLine($Message) }

function Show-DbkUsage {
  $text = @'
用法: <脚本> [-Check] [-Apply] [-Json] [-Log <路径>] [-Yes] [-Step <NN-K>]
  -Check 只读判定(缺省,不写系统状态);-Apply 执行本步(幂等);-Json 机器可读输出
  -Log <路径> 日志路径(缺省不落盘);-Yes 破坏性动作必需;缺省时打印将执行的命令与影响并以 64 退出
  -Step <NN-K> 显式声明卡号;与脚本头「# 对应卡:」不一致 → 64
退出码: 0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误
'@
  [Console]::Error.WriteLine($text)
}

function Parse-DbkArgs {
  param(
    [switch]$Check,
    [switch]$Apply,
    [switch]$Json,
    [switch]$Yes,
    [string]$Step = '',
    [string]$Log = '',
    [string[]]$Extra = @()
  )
  $script:DbkChecks = New-Object System.Collections.ArrayList
  $script:DbkActions = New-Object System.Collections.ArrayList
  $script:DbkChanged = $false
  if ($Check -and $Apply) {
    Show-DbkUsage
    Write-DbkNote '用法错误: -Check 与 -Apply 互斥,只能给一个'
    exit $script:DBK_USAGE
  }
  if ($Extra -and $Extra.Count -gt 0) {
    Show-DbkUsage
    Write-DbkNote ("用法错误: 未知参数 " + ($Extra -join ' '))
    exit $script:DBK_USAGE
  }
  # -Step/-Log 传空串等同未给:步骤脚本会把自己的默认值原样转发,无法区分"显式给空"。
  if ([string]::IsNullOrWhiteSpace($Step)) { $Step = '' }
  if ([string]::IsNullOrWhiteSpace($Log)) { $Log = '' }
  if ($Apply) { $script:DbkMode = 'apply' } else { $script:DbkMode = 'check' }
  $script:DbkJson = [bool]$Json
  $script:DbkYes = [bool]$Yes
  $script:DbkStep = $Step
  if ($Log) { $script:DbkLog = $Log }
}

# Assert-DbkStep [-Declared <卡号>]:不给 -Declared 时从调用脚本的文件头读「# 对应卡:NN-K」;
#   -Step 给过且与声明不一致 → 64;两处都取不到卡号 → 64(步骤脚本必须有卡头)。
function Assert-DbkStep {
  param([string]$Declared = '')
  if (-not $Declared) {
    $caller = $MyInvocation.ScriptName
    if (-not $caller) { $caller = $PSCommandPath }
    if ($caller -and (Test-Path -LiteralPath $caller)) {
      $hit = Select-String -LiteralPath $caller -Pattern '^#\s*(对应卡|Card):\s*([0-9]{2}-[0-9]+)' -List
      if ($hit) { $Declared = $hit.Matches[0].Groups[2].Value }
    }
  }
  if (-not $Declared) {
    Write-DbkNote '用法错误: 取不到「# 对应卡:NN-K」,无法确认本脚本服务的卡'
    exit $script:DBK_USAGE
  }
  if ($script:DbkStep -and $script:DbkStep -ne $Declared) {
    Write-DbkNote "用法错误: -Step $script:DbkStep 与脚本头声明的卡号 $Declared 不一致"
    exit $script:DBK_USAGE
  }
  $script:DbkStep = $Declared
}

# Assert-DbkYes -Description <动作> [-Commands <命令>]:未给 -Yes → 打印动作、将执行的命令与影响并退出 64
#   (调用点之前不做任何改动 → 零写)。
function Assert-DbkYes {
  param([string]$Description = '', [string[]]$Commands = @())
  if ($script:DbkYes) { return }
  Write-DbkNote "破坏性动作:$Description"
  if ($Commands -and $Commands.Count -gt 0) {
    Write-DbkNote '将执行的命令:'
    foreach ($c in $Commands) { Write-DbkNote "  $c" }
  }
  Write-DbkNote '影响:该动作会改动系统状态;确认无误后加 -Yes 重跑(缺 -Yes 时脚本不做任何改动)。'
  exit $script:DBK_USAGE
}

function Add-DbkCheck { param([string]$Text = '') [void]$script:DbkChecks.Add($Text) }
function Add-DbkAction { param([string]$Text = '') [void]$script:DbkActions.Add($Text) }
function Set-DbkChanged { $script:DbkChanged = $true }

# ConvertTo-DbkJson <文本>:转义成可安全放进 JSON 双引号字符串的形式(反斜杠/双引号/制表符/回车/换行)。
function ConvertTo-DbkJson {
  param([string]$Text = '')
  if ($null -eq $Text) { return '' }
  $s = $Text -replace '\\', '\\'
  $s = $s -replace '"', '\"'
  $s = $s -replace "`r", '\r'
  $s = $s -replace "`n", '\n'
  $s = $s -replace "`t", '\t'
  return $s
}

# 状态归一表(PowerShell 哈希表键不分大小写,故 PASS/pass 只需一条):
$script:DbkStatusMap = @{
  'pass' = 'pass'; '通过' = 'pass'
  'fail' = 'fail'; '不通过' = 'fail'
  'manual' = 'manual'; '人工' = 'manual'; '需人工' = 'manual'
  'skip' = 'skip'; '跳过' = 'skip'
}
function Get-DbkStatusKey {
  param([string]$Status = '')
  if ($script:DbkStatusMap.ContainsKey($Status)) { return $script:DbkStatusMap[$Status] }
  return ''
}

function Get-DbkStatusCode {
  param([string]$Key = '')
  switch ($Key) {
    'pass' { $script:DBK_PASS }
    'fail' { $script:DBK_FAIL }
    'manual' { $script:DBK_MANUAL }
    'skip' { $script:DBK_SKIP }
    default { $script:DBK_USAGE }
  }
}

function Get-DbkJsonArray {
  param([object[]]$Items = @())
  $parts = @()
  foreach ($i in $Items) { $parts += ('"' + (ConvertTo-DbkJson ([string]$i)) + '"') }
  return ($parts -join ',')
}

# JSON 汇总(单行):{"step":…,"status":…,"checks":[…],"actions":[…],"changed":true|false}
function Get-DbkJsonReport {
  param([string]$Step = '', [string]$Key = 'pass')
  $changed = 'false'
  if ($script:DbkChanged) { $changed = 'true' }
  return '{"step":"' + (ConvertTo-DbkJson $Step) + '","status":"' + $Key + '","checks":[' +
    (Get-DbkJsonArray ($script:DbkChecks.ToArray())) + '],"actions":[' +
    (Get-DbkJsonArray ($script:DbkActions.ToArray())) + '],"changed":' + $changed + '}'
}

# Write-DbkReport -Status <PASS|FAIL|需人工|跳过> -Message <说明>:文本模式打印 [-Json 模式打印单行 JSON]。
function Write-DbkReport {
  param([string]$Status = '', [string]$Message = '')
  $key = Get-DbkStatusKey $Status
  if (-not $key) {
    Write-DbkNote "用法错误: 未知状态 '$Status'(只认 PASS/FAIL/需人工/跳过 或 pass/fail/manual/skip)"
    exit $script:DBK_USAGE
  }
  $script:DbkLastStatus = $key
  if ($script:DbkJson) {
    Write-Output (Get-DbkJsonReport -Step $script:DbkStep -Key $key)
    return
  }
  $tag = switch ($key) { 'pass' { 'PASS' } 'fail' { 'FAIL' } 'manual' { '需人工' } 'skip' { '跳过' } }
  Write-Output ("[{0}] {1}" -f $tag, $Message)
  foreach ($c in $script:DbkChecks) { Write-Output ("  - {0}" -f $c) }
  foreach ($a in $script:DbkActions) { Write-Output ("  > {0}" -f $a) }
}

# Write-DbkExit -Status <状态> -Message <说明>:报告后以对应退出码结束(0/1/2/9)。
function Write-DbkExit {
  param([string]$Status = '', [string]$Message = '')
  Write-DbkReport -Status $Status -Message $Message
  exit (Get-DbkStatusCode $script:DbkLastStatus)
}
