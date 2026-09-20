# 库文件:非步骤脚本
# 用途:步骤脚本的统一 CLI 契约(Windows 侧):参数解析、卡号断言、破坏性门槛、退出码常量。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(CLI、退出码、可观测性)与第 7 节(夹具要求)。
# 用法(dot-source 后依次调用):Parse-DbkArgs(开关与取值)→ Assert-DbkStep(与脚本头卡号集合比对,不一致 64)
#   → Add-DbkCheck / Assert-DbkYes / Add-DbkAction / Set-DbkChanged → Write-DbkExit -Status … -Message …。
# 脚本头声明:「# 对应卡:NN-K[,NN-K…]」(一脚本服务多张卡用逗号列表);破坏性脚本另写「# 破坏性:1」——
#   声明后 -Apply 缺 -Yes 由库层直接拒(64),不靠作者记得调 Assert-DbkYes。.ps1 必须是 UTF-8 with BOM:
#   BOM 不算「#」行,所以「# 对应卡:」要写在 `#Requires` 之类的文件头指令之后(指令必须是第一条非注释语句)。
#   声明破坏性但动作是条件性的时候(声明不适用),仍在动作前调 Assert-DbkYes。
# 输出与 JSON 由 dbk-obs.ps1 提供(本文件 dot-source 它);-Json 时 stdout 只有 Write-DbkExit/Write-DbkErrTrap 的一行 JSON。
# 只读保证:本文件只定义函数与常量;参数错误一律打印用法到 stderr 并 exit 64,不落盘。
#   只有显式 -Log(或调过 Set-DbkLogDefault)才记路径,且只在失败路径追加日志(Write-DbkObs)。
# 已知差异(与 bash 侧 dbk-cli.sh 的读法不同;由 Task 2 总控在调用前自行校验,不靠本库兜):
#   1) -Log / -Step 缺值会被 PowerShell 参数绑定先拦下,实测 rc=1(不是 bash 侧的用法错误 64);
#   2) -Log '' / -Step '' 被本库归一成"未给"并静默接受,不报 64。
# 夹具级验证,真机未跑。

$script:DBK_PASS = 0
$script:DBK_FAIL = 1
$script:DBK_MANUAL = 2
$script:DBK_SKIP = 9
$script:DBK_USAGE = 64

# 解析结果与状态在这里预置默认值,避免调用方漏调 Parse-DbkArgs 时读到未定义变量。
$script:DbkMode = 'check'
$script:DbkJson = $false
$script:DbkYes = $false
$script:DbkLog = ''
$script:DbkStep = ''
$script:DbkLastStatus = ''
$script:DbkChanged = $false
$script:DbkChecks = New-Object System.Collections.ArrayList
$script:DbkChecksRaw = New-Object System.Collections.ArrayList
$script:DbkActions = New-Object System.Collections.ArrayList
$script:DbkErrTrap = $false

# 输出与 JSON 汇总在可观测性库里(与本文件同目录)。
$dbkObs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-obs.ps1'
. $dbkObs

function Show-DbkUsage {
  $text = @'
用法: <脚本> [-Check] [-Apply] [-Json] [-Log <路径>] [-Yes] [-Step <NN-K>]
  -Check 只读判定(缺省,不写系统状态);-Apply 执行本步(幂等);-Json 机器可读输出(含 message/checks[]/changed)
  -Log <路径> 日志路径;不给就不落盘(步骤脚本可用 Set-DbkLogDefault 设缺省路径)
  -Yes 破坏性动作必需;缺省时打印动作与影响并以 64 退出(声明了「# 破坏性:1」的脚本照样 64)
  -Step <NN-K> 显式声明卡号;必须是脚本头卡号集合的成员,否则 → 64
退出码: 0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误
'@
  [Console]::Error.WriteLine($text)
}

# Get-DbkHeaderField -File <脚本> -Field <字段名> -ValueRe <值正则>:读脚本头「# 字段:值」的第一个匹配(取不到返回空)。
# 卡号头与破坏性声明共用这一个实现;行首允许 UTF-8 BOM(.ps1 必须带)。
# 字段名与值都大小写敏感(-CaseSensitive),与仓库自检 C9b 的 CARDRE 对齐(否则会接受 `# card: 05-1`)。
function Get-DbkHeaderField {
  param([string]$File = '', [string]$Field = '', [string]$ValueRe = '')
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return '' }
  $pattern = '^(?:' + [char]0xFEFF + ')?#\s*(?:' + $Field + '):\s*(' + $ValueRe + ')'
  $hit = Select-String -LiteralPath $File -Pattern $pattern -List -CaseSensitive
  if ($hit) { return $hit.Matches[0].Groups[1].Value.Trim() }
  return ''
}

# Get-DbkCardTokens <文本>:把「02-9,07-10」之类抽成空格分隔的卡号列表。
function Get-DbkCardTokens {
  param([string]$Text = '')
  if (-not $Text) { return '' }
  $m = [regex]::Matches($Text, '[0-9]{2}-[0-9]+')
  return (($m | ForEach-Object { $_.Value }) -join ' ')
}

# Get-DbkHeaderCards -File <脚本>:读「# 对应卡:NN-K[,NN-K…]」,返回空格分隔的卡号列表(支持一脚本服务多张卡)。
function Get-DbkHeaderCards {
  param([string]$File = '')
  $v = Get-DbkHeaderField -File $File -Field '对应卡|Card' -ValueRe '[0-9]{2}-[0-9]+(\s*[,，]\s*[0-9]{2}-[0-9]+)*'
  return (Get-DbkCardTokens $v)
}

# Test-DbkDeclaredDestructive -File <脚本>:脚本头声明「# 破坏性:1」→ $true。
function Test-DbkDeclaredDestructive {
  param([string]$File = '')
  return ((Get-DbkHeaderField -File $File -Field '破坏性' -ValueRe '1') -eq '1')
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
  $script:DbkChecksRaw = New-Object System.Collections.ArrayList
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
  if ($script:DbkMode -eq 'apply' -and -not $script:DbkYes -and (Test-DbkDeclaredDestructive $MyInvocation.ScriptName)) {
    Show-DbkUsage
    Write-DbkNote '用法错误: 脚本头声明了「# 破坏性:1」,-Apply 必须显式给 -Yes'
    Write-DbkNote '影响:该动作会改动系统状态;缺 -Yes 时脚本不做任何改动。确认无误后加 -Yes 重跑。'
    exit $script:DBK_USAGE
  }
}

# Assert-DbkStep [-Declared <卡号或列表>]:不给 -Declared 时从调用脚本文件头读「# 对应卡:NN-K[,NN-K…]」;
#   -Step 是集合成员判断:给了 -Step 时必须落在脚本头声明的卡号集合里,否则 64;两处都取不到卡号 → 64。
function Assert-DbkStep {
  param([string]$Declared = '')
  if (-not $Declared) {
    $caller = $MyInvocation.ScriptName
    if (-not $caller) { $caller = $PSCommandPath }
    $Declared = Get-DbkHeaderCards -File $caller
  } else {
    $Declared = Get-DbkCardTokens $Declared
  }
  if (-not $Declared) {
    Write-DbkNote '用法错误: 取不到「# 对应卡:NN-K」,无法确认本脚本服务的卡'
    exit $script:DBK_USAGE
  }
  $cards = @($Declared -split '\s+' | Where-Object { $_ })
  if ($script:DbkStep) {
    if ($cards -notcontains $script:DbkStep) {
      Write-DbkNote "用法错误: -Step $($script:DbkStep) 不在脚本头声明的卡号集合($($cards -join ' '))里"
      exit $script:DBK_USAGE
    }
  } else {
    $script:DbkStep = $cards[0]
  }
}

# Assert-DbkYes -Description <动作> [-Commands <命令>]:未给 -Yes → 打印动作、将执行的命令与影响并退出 64
#   (调用点之前不做任何改动 → 零写)。声明了「# 破坏性:1」的脚本在 Parse-DbkArgs 就会先拦(64);
#   本函数用于条件性破坏动作与 -Yes 执行路径上的命令记录。
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

# Write-DbkExit -Status <状态> -Message <说明>:报告后以对应退出码结束(0/1/2/9)。
function Write-DbkExit {
  param([string]$Status = '', [string]$Message = '')
  Write-DbkReport -Status $Status -Message $Message
  exit (Get-DbkStatusCode $script:DbkLastStatus)
}
