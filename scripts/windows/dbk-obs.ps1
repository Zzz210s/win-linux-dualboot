# 库文件:非步骤脚本
# 用途:步骤脚本契约的可观测性层(Windows 侧):人读/机器读输出、JSON 汇总、-Log 落盘、UTF-8 输出编码。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(可观测性)与第 7 节(夹具要求)。
# 装配方式:dbk-cli.ps1 定义常量与状态变量后 dot-source 本文件;本文件只定义函数,不主动执行动作。
# 可观测性三条(与 scripts/linux/dbk-obs.sh 同构):
#   1) 失败不得只给退出码:FAIL/需人工 必须给原因文本,库把说明同时写进 message 与 checks[](判据为空时补一条);
#   2) 三处可见:失败要能在 stderr、-Log 日志、-Json 的 checks[] 里同时看到;
#   3) 不吞错误:日志写不进去时把失败打到 stderr,不许 -ErrorAction SilentlyContinue 蒙掉。
# 输出编码:PS 5.1 用当前代码页(中文 Windows 是 CP936)编码 stdout,走管道会变乱码;库加载时(此时还没有任何
#   输出、Console.Out 尚未定型)统一设成 UTF-8 无 BOM,保证 -Json 被总控与验收汇总正确消费。
# 失败可见的 Windows 侧做法:PS 没有 bash 的 ERR trap,库不装 trap(免得改变"失败不中断"脚本的默认语义);
#   由使用 try/catch 的步骤脚本在 catch 里调 Enable-DbkErrTrap(opt-in)与 Write-DbkErrTrap。
# 夹具级验证,真机未跑。

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# 人读信息一律走 stderr(保证 -Json 模式下 stdout 只有一行 JSON)。只写 stderr,不落盘。
function Write-DbkNote { param([string]$Message = '') [Console]::Error.WriteLine($Message) }

# Write-DbkLog <文本>:追加到 $script:DbkLog 指定的日志文件(未给 -Log 时直接返回,库层不落盘)。
# 写文件用 .NET + UTF8 无 BOM:PS 5.1 的 Add-Content 默认按 ANSI 代码页写,中文会变乱码。
function Write-DbkLog {
  param([string]$Text = '')
  if (-not $script:DbkLog) { return }
  $dir = Split-Path -Parent $script:DbkLog
  try {
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:sszzz')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($script:DbkLog, ($stamp + ' ' + $Text + [Environment]::NewLine), $utf8)
  } catch {
    [Console]::Error.WriteLine("dbk: 日志写入失败($($script:DbkLog)):$($_.Exception.Message)")
  }
}

# Write-DbkObs <文本>:失败信息的统一出口——stderr +(给了 -Log 时的)日志文件。
function Write-DbkObs {
  param([string]$Text = '')
  [Console]::Error.WriteLine($Text)
  Write-DbkLog $Text
}

# Set-DbkLogDefault -Name <脚本名>:步骤脚本显式调用,把缺省日志路径写进日志变量。
# 库自身不调它(保证"不给 -Log 就不落盘");调用后失败路径(Write-DbkObs)才会写这个文件。
function Set-DbkLogDefault {
  param([string]$Name = 'dbk')
  if ($script:DbkLog) { return }
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = $env:TEMP }
  $script:DbkLog = Join-Path (Join-Path $base 'dbk\logs') ("$Name.log")
}

# 判据/动作登记:普通判据是字符串;库层失败项(如 errtrap)用原始 JSON 对象登记,与字符串项一起进 checks[]。
function Add-DbkCheck { param([string]$Text = '') [void]$script:DbkChecks.Add($Text) }
function Add-DbkAction { param([string]$Text = '') [void]$script:DbkActions.Add($Text) }
function Add-DbkCheckRaw { param([string]$Json = '') [void]$script:DbkChecksRaw.Add($Json) }
function Set-DbkChanged { $script:DbkChanged = $true }

# ConvertTo-DbkJson <文本>:转义成可安全放进 JSON 双引号字符串的形式(反斜杠/双引号/短转义/其余控制字符)。
function ConvertTo-DbkJson {
  param([string]$Text = '')
  if ($null -eq $Text) { return '' }
  $s = $Text -replace '\\', '\\'
  $s = $s -replace '"', '\"'
  $s = $s -replace "`r", '\r'
  $s = $s -replace "`n", '\n'
  $s = $s -replace "`t", '\t'
  return [regex]::Replace($s, '[\u0000-\u001F]', { param($m) '\u00' + ('{0:X2}' -f [int][char]$m.Value) })
}

function Get-DbkJsonArray {
  param([object[]]$Items = @())
  $parts = @()
  foreach ($i in $Items) { $parts += ('"' + (ConvertTo-DbkJson ([string]$i)) + '"') }
  return ($parts -join ',')
}

# 拼 checks[]:先普通判据(字符串),再库层失败项(原始 JSON 对象,如 {"id":"errtrap","ok":false,"detail":"…"})。
function Get-DbkChecksJson {
  $parts = @()
  foreach ($c in $script:DbkChecks) { $parts += ('"' + (ConvertTo-DbkJson ([string]$c)) + '"') }
  foreach ($r in $script:DbkChecksRaw) { $parts += [string]$r }
  return ($parts -join ',')
}

# JSON 汇总(单行):{"step":…,"status":…,"message":…,"checks":[…],"actions":[…],"changed":true|false}
function Get-DbkJsonReport {
  param([string]$Step = '', [string]$Key = 'pass', [string]$Message = '')
  $changed = 'false'
  if ($script:DbkChanged) { $changed = 'true' }
  return '{"step":"' + (ConvertTo-DbkJson $Step) + '","status":"' + $Key + '","message":"' + (ConvertTo-DbkJson $Message) +
    '","checks":[' + (Get-DbkChecksJson) + '],"actions":[' + (Get-DbkJsonArray ($script:DbkActions.ToArray())) +
    '],"changed":' + $changed + '}'
}

# 状态显示名:文本报告与失败行用;未知键原样返回。
function Get-DbkStatusTag {
  param([string]$Key = '')
  switch ($Key) {
    'pass' { 'PASS' } 'fail' { 'FAIL' } 'manual' { '需人工' } 'skip' { '跳过' }
    default { $Key }
  }
}

# Write-DbkReport -Status <PASS|FAIL|需人工|跳过> -Message <说明>[ -Json 时只打印单行 JSON]
#   FAIL/需人工:说明不得为空(不得只给退出码);说明同时进 stderr+日志、JSON 的 message 与 checks[](判据为空时补一条)。
function Write-DbkReport {
  param([string]$Status = '', [string]$Message = '')
  $key = Get-DbkStatusKey $Status
  if (-not $key) {
    Write-DbkNote "用法错误: 未知状态 '$Status'(只认 PASS/FAIL/需人工/跳过 或 pass/fail/manual/skip)"
    exit $script:DBK_USAGE
  }
  $script:DbkLastStatus = $key
  $tag = Get-DbkStatusTag $key
  if ($key -eq 'fail' -or $key -eq 'manual') {
    if (-not $Message) {
      Write-DbkNote "用法错误: $tag 必须给出原因文本(失败不得只给退出码)"
      exit $script:DBK_USAGE
    }
    if ($script:DbkChecks.Count -eq 0 -and $script:DbkChecksRaw.Count -eq 0) { Add-DbkCheck "失败项: $Message" }
    Write-DbkObs "[$tag] $Message"
  }
  if ($script:DbkJson) {
    Write-Output (Get-DbkJsonReport -Step $script:DbkStep -Key $key -Message $Message)
    return
  }
  Write-Output ("[{0}] {1}" -f $tag, $Message)
  foreach ($c in $script:DbkChecks) { Write-Output ("  - {0}" -f $c) }
  foreach ($a in $script:DbkActions) { Write-Output ("  > {0}" -f $a) }
}

# Enable-DbkErrTrap:opt-in 开关(只给"失败必须中断"的步骤脚本在 try/catch 前调用)。
function Enable-DbkErrTrap { $script:DbkErrTrap = $true }

# Write-DbkErrTrap -Reason <文本>:catch 块里调,把失败写到三处(stderr/日志/JSON checks[])并立刻输出一行报告。
function Write-DbkErrTrap {
  param([string]$Reason = '')
  if (-not $script:DbkErrTrap) { return }
  $detail = $Reason
  Write-DbkObs "errtrap: $detail"
  Add-DbkCheckRaw ('{"id":"errtrap","ok":false,"detail":"' + (ConvertTo-DbkJson $detail) + '"}')
  $script:DbkLastStatus = 'fail'
  if ($script:DbkJson) {
    Write-Output (Get-DbkJsonReport -Step $script:DbkStep -Key 'fail' -Message ("errtrap: $detail"))
  } else {
    Write-Output ("[FAIL] errtrap: {0}" -f $detail)
  }
}
