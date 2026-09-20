#Requires -Version 5.1
# 对应卡:01-1
<#
.SYNOPSIS
  L0:核对固件设置(只读)。操作系统内能读到的项自动判定;固件界面里的开关读不到,一律列进"人工核对清单"。
.DESCRIPTION
  判定与依据(设计 4.1):
    ① Secure Boot:Confirm-SecureBootUEFI 为真 = 通过;为假 = 失败("Secure Boot 保持开启");
    ② 存储控制器:SCSIAdapter / Win32_PnPEntity 名字里出现 VMD / RST / RAID = 失败(装 Windows 之前必须关闭 VMD / RAID On,见设计 4.1 关键点);
    ③ 读不到的项(Fast Boot、CSM、启动模式、固件里的控制器项名与取值)无法自动判定 → 列为人工核对清单;其中任一项**读取失败**时结论为"需人工"(退出码 2),不当作通过。
  本卡没有自动写动作:BIOS 内的开关只能人在固件界面里改,-Apply 不改变系统任何状态(只再打印一遍人工清单)。
  注意:非管理员会话下 Confirm-SecureBootUEFI 会因“访问被拒”而读不到(实测 Windows PowerShell 5.1),此时本脚本判“需人工”而不判通过;正式核对请用管理员会话。
  (与 preflight.ps1 的差异:那份用注册表 UEFISecureBootEnabled,非管理员也能读;两处口径不同属有意为之——本卡按设计指定用 Confirm-SecureBootUEFI。)
  夹具钩子(仅离线验证用,真机留空):DBK_FW_SB=1|0|unknown 覆盖 Secure Boot 读取;DBK_FW_PNP="名字;名字" 覆盖控制器名列表。
  本文件必须保存为 UTF-8 with BOM(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码,中文会解析失败)。
  夹具级验证,真机未跑。
  用法(在仓库根目录、以管理员身份运行 Windows PowerShell):
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\check-firmware.ps1          # 只读判定(缺省)
    powershell.exe -ExecutionPolicy Bypass -File scripts\windows\check-firmware.ps1 -Json     # 机器可读(单行 JSON)
  退出码:0 通过 / 1 失败(Secure Boot 未开或控制器仍在 VMD / RAID) / 2 需人工(有读不到的项) / 9 跳过 / 64 用法错误
#>
[CmdletBinding()]
param(
  [switch]$Check, [switch]$Apply, [switch]$Json, [switch]$Yes,
  [string]$Step = '', [string]$Log = '', [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dbk-cli.ps1')
Parse-DbkArgs -Check:$Check -Apply:$Apply -Json:$Json -Yes:$Yes -Step $Step -Log $Log -Extra $Extra
Assert-DbkStep
# -Check 零写:不设缺省日志(失败信息仍走 stderr 与 -Json);只有 -Apply 才落 %LOCALAPPDATA%\dbk\logs\check-firmware.log。
if ($script:DbkMode -eq 'apply') { Set-DbkLogDefault -Name 'check-firmware' }

function Get-SecureBootState {
  # on / off / unknown(unknown = 读不到:非 UEFI 固件,或平台不支持 Confirm-SecureBootUEFI)
  if ($env:DBK_FW_SB) {
    if ($env:DBK_FW_SB -eq '1') { return 'on' }
    if ($env:DBK_FW_SB -eq '0') { return 'off' }
    return 'unknown'
  }
  try { if (Confirm-SecureBootUEFI) { return 'on' } else { return 'off' } } catch { return 'unknown' }
}

function Get-ControllerProbe {
  # 控制器推断(与 preflight.ps1 同一口径):类名取自 SCSIAdapter,辅以 Win32_PnPEntity 里含 VMD / RST / RAID 的设备名
  if ($env:DBK_FW_PNP) { return @{ Class = @($env:DBK_FW_PNP -split ';' | Where-Object { $_ }); Pnp = @() } }
  $cls = @(); $pnp = @()
  try { $cls = @(Get-PnpDevice -Class SCSIAdapter -ErrorAction Stop | ForEach-Object { $_.FriendlyName }) } catch { }
  try { $pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Name -match 'VMD|RST|RAID' } | ForEach-Object { $_.Name }) } catch { }
  return @{ Class = @($cls | Where-Object { $_ } | Sort-Object -Unique); Pnp = @($pnp | Where-Object { $_ } | Sort-Object -Unique) }
}

# 固件界面里的开关:操作系统内读不到,只能人工核对(永远列出来,不参与自动判定)
$manual = @(
  'Fast Boot 设为 Disabled(固件项;它跳过 USB 枚举,开着会导致启动菜单看不到安装 U 盘)'
  'Boot Mode 设为 UEFI、CSM / Legacy Boot 设为 Disabled(只保留 UEFI)'
  '存储控制器项(SATA Operation / SATA Mode / Storage Configuration)设为 AHCI / NVMe,并关闭 VMD setup menu'
  '改之前先抄下存储控制器模式原值与启动顺序第一位(照实记录;BootOrder 首位原值是 01-4 产物的必填行)'
  'Secure Boot 在固件界面里再复核一遍(本脚本的读取值只作参考)'
)
foreach ($m in $manual) { Add-DbkAction ('人工核对:' + $m) }

$failN = 0; $manualN = 0; $failItems = @()

$sb = Get-SecureBootState
if ($sb -eq 'on') { Add-DbkCheck 'Secure Boot:已开启(Confirm-SecureBootUEFI = True)' }
elseif ($sb -eq 'off') {
  $failN++; $failItems += 'Secure Boot 未开启'
  Add-DbkCheck '失败项:Secure Boot 未开启(Confirm-SecureBootUEFI = False);固件里设为 Enabled、Secure Boot Mode 设回 Standard 后重跑'
} else {
  $manualN++
  Add-DbkCheck '需人工:Secure Boot 读数取不到(非 UEFI 固件,或平台不支持 Confirm-SecureBootUEFI);请在固件界面核对'
}

$probe = Get-ControllerProbe
$badCls = @($probe.Class | Where-Object { $_ -match 'VMD|RAID' })
$badPnp = @($probe.Pnp | Where-Object { $_ -match 'VMD|RST|RAID' })
if ($badCls.Count -gt 0) {
  $failN++; $failItems += ('存储控制器仍在 VMD / RAID(' + ($badCls -join '; ') + ')')
  Add-DbkCheck ('失败项:存储控制器仍在 VMD / RAID 模式:' + ($badCls -join '; ') + ';装 Windows 之前必须改成 AHCI / NVMe(设计 4.1)')
} elseif ($probe.Class.Count -eq 0) {
  $manualN++
  Add-DbkCheck '需人工:控制器类名读不到(SCSIAdapter 无结果);请在固件界面核对控制器模式'
} elseif ($badPnp.Count -gt 0) {
  $manualN++
  Add-DbkCheck ('需人工:控制器类名里未见 VMD / RAID(' + ($probe.Class -join '; ') + '),但设备名里出现 VMD / RST(' + ($badPnp -join '; ') + ');推断不确定,请在固件界面确认 VMD 是否已关闭')
} else { Add-DbkCheck ('存储控制器:控制器类名未见 VMD / RAID(' + ($probe.Class -join '; ') + ')') }

if ($failN -gt 0) {
  Write-DbkExit -Status FAIL -Message ("固件核对失败 " + $failN + " 项:" + ($failItems -join ';') + ";在固件界面改到目标值后重跑本脚本(逐项判据见 checks)")
}
if ($manualN -gt 0) {
  Write-DbkExit -Status 需人工 -Message ("有 " + $manualN + " 项在操作系统内读不到,必须人工核对;另有 " + $manual.Count + " 项固件界面内的开关只能人看(见 actions)")
}
Write-DbkExit -Status PASS -Message ("操作系统内可读的项全部通过;下面 " + $manual.Count + " 项固件界面内的开关仍需人工核对(读不到,不参与自动判定)")
