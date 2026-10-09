# 库文件:非步骤脚本
# 职责:验收条目表的唯一读取层 —— 读 scripts/verification-items.tsv、按 -Step 选择符过滤、给用法错误的可用集合。
#   表是验收条目的唯一真源(与 docs/08-verification.md 同步);本库不做任何判定,也不内置任何条目副本。
# 契约(调用方 = scripts/windows/verify-all.ps1 验收总控):
#   1) Read-DbkVerificationItems -Path <tsv> -> @{ Ok; Error; Items }
#        Items[] = 保持表内顺序的数组,每项 [pscustomobject]@{ Id; Group; Card; Side; Script; Args; Label }。
#        制表符分隔、LF(CRLF 亦可)、# 与空行跳过。表不存在/读不出/某行不足 7 列/侧不是 L|W|B/编号为空/零条目
#        -> Ok=$false 且 Error 非空;调用方据此退 64 且零写(禁止回退到硬编码条目,否则真源分裂)。
#   2) Get-DbkStepSelection -Items <Items> -Step <值> -> @{ Mode; Group; Card; Error; Known; Groups }
#        Mode = all(缺省、08-A-G 或 08-A-H)/group(08-A…08-H,过滤「组」列)/card(NN-K,过滤「卡」列)/invalid(Error 非空)。
#        Known/Groups = 空格分隔的可用卡号/组集合(供用法错误信息打印,与 Linux 侧 verify-all.sh 同口径)。
#   3) Test-DbkItemSelected -Item <项> -Selection <上者> -> $true/$false(是否命中当前 -Step 选择符)。
#   4) Get-DbkSkipPrefix -Step <值> -Selection <上者> -> 未选中条目的原因前缀(「未选中(-Step X 只判组/卡 Y):」)。
# 本文件必须保存为 UTF-8 with BOM。夹具级验证,真机未跑。

# TSV 一行 -> 条目对象;字段不足或侧非法时返回 @{ Ok=$false; Error=… }。
function ConvertFrom-DbkItemLine {
  param([string]$Line = '', [int]$LineNo = 0)
  $f = @($Line -split "`t")
  if ($f.Count -lt 7) { return @{ Ok = $false; Error = ('条目表第 ' + $LineNo + ' 行不足 7 列(制表符分隔):' + $Line); Item = $null } }
  $id = $f[0].Trim(); $side = $f[3].Trim().ToUpper()
  if (-not $id) { return @{ Ok = $false; Error = ('条目表第 ' + $LineNo + ' 行编号为空'); Item = $null } }
  if (@('L', 'W', 'B') -notcontains $side) { return @{ Ok = $false; Error = ('条目表第 ' + $LineNo + ' 行侧必须是 L|W|B,实际:' + $side); Item = $null } }
  $label = $f[6]; if ($f.Count -gt 7) { $label = ($f[6..($f.Count - 1)] -join "`t") }
  $item = [pscustomobject]@{ Id = $id; Group = $f[1].Trim(); Card = $f[2].Trim(); Side = $side; Script = $f[4].Trim(); Args = $f[5].Trim(); Label = $label.Trim() }
  return @{ Ok = $true; Error = ''; Item = $item }
}

# 读条目表;返回 @{ Ok; Error; Items }(见文件头契约 1)。
function Read-DbkVerificationItems {
  param([string]$Path = '')
  $res = @{ Ok = $false; Error = ''; Items = @() }
  if (-not $Path) { $res.Error = '没有给条目表路径'; return $res }
  if (-not (Test-Path -LiteralPath $Path)) { $res.Error = ('条目表不存在:' + $Path); return $res }
  try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { $res.Error = ('读不到条目表(' + $Path + '):' + $_.Exception.Message); return $res }
  $items = New-Object System.Collections.ArrayList
  $n = 0
  foreach ($ln in @($lines)) {
    $n++
    if (-not $ln.Trim()) { continue }
    if ($ln.TrimStart().StartsWith('#')) { continue }
    $one = ConvertFrom-DbkItemLine -Line $ln -LineNo $n
    if (-not $one.Ok) { $res.Error = $one.Error; return $res }
    [void]$items.Add($one.Item)
  }
  if ($items.Count -eq 0) { $res.Error = ('条目表里没有条目行:' + $Path); return $res }
  $res.Ok = $true; $res.Items = @($items.ToArray()); return $res
}

# 解析 -Step 选择符(见文件头契约 2);Known/Groups 始终填好,便于非法值时打印可用集合。
function Get-DbkStepSelection {
  param($Items = @(), [string]$Step = '')
  $sel = @{ Mode = 'all'; Group = ''; Card = ''; Error = ''; Known = ''; Groups = '' }
  $cards = @(); $groups = @()
  foreach ($i in @($Items)) { $cards += [string]$i.Card; $groups += [string]$i.Group }
  $cards = @($cards | Sort-Object -Unique); $groups = @($groups | Sort-Object -Unique)
  $sel.Known = ($cards -join ' '); $sel.Groups = ($groups -join ' ')
  if (-not $Step -or $Step -eq '08-A-G' -or $Step -eq '08-A-H') { return $sel }
  if ($Step -match '^08-([A-H])$') {
    if ($groups -notcontains $Matches[1]) { $sel.Mode = 'invalid'; $sel.Error = ('组 ' + $Matches[1] + ' 不在条目表里'); return $sel }
    $sel.Mode = 'group'; $sel.Group = $Matches[1]; return $sel
  }
  if ($cards -notcontains $Step) { $sel.Mode = 'invalid'; $sel.Error = ('卡号 ' + $Step + ' 不在条目表里'); return $sel }
  $sel.Mode = 'card'; $sel.Card = $Step; return $sel
}

# 当前选择符是否命中该条目(见文件头契约 3)。
function Test-DbkItemSelected {
  param($Item, $Selection)
  if ($Selection.Mode -eq 'group') { return ([string]$Item.Group -eq [string]$Selection.Group) }
  if ($Selection.Mode -eq 'card') { return ([string]$Item.Card -eq [string]$Selection.Card) }
  return $true
}

# 未选中条目的原因前缀(见文件头契约 4;all 模式返回空串)。
function Get-DbkSkipPrefix {
  param([string]$Step = '', $Selection)
  if ($Selection.Mode -eq 'group') { return ('未选中(-Step ' + $Step + ' 只判组 ' + $Selection.Group + '):') }
  if ($Selection.Mode -eq 'card') { return ('未选中(-Step ' + $Step + ' 只判卡 ' + $Selection.Card + '):') }
  return ''
}
