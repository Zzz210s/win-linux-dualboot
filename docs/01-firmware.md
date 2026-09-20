# L0:装机前固件设定与安装介质

本文件在流程中的位置:入口(`00-overview.md`)-> **本文件(底座:L0)** -> `02-partitioning.md`(安装前的前置章节)。

目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;设计依据在[设计文档](design/00-design.md) 4.1 节与 11.1 节,本文件不复述。

## 开始前

- 前提:单块 1TB 级 NVMe 的 Windows 机器;固件为 UEFI(CSM 关闭)、`Secure Boot` 可用,且存储控制器模式可以改。
- 需要的东西:厂商 Setup 键与一次性启动菜单键(见入口页参数表 `VENDOR` / `BOOT_MENU_KEY`)、两个官方安装 ISO、一个 ≥8GB 的 U 盘(先备份其中数据)。
- 产物落点:`baseline/00-firmware.md`(字段清单与写法见 `01-4`;多设备放 `baseline/<设备别名>/`)。

### 01-1 改固件设置(先抄原值,再把三组开关改到目标状态)

做:进固件设置(厂商 Setup 键见下方厂商差异表),先记录原值,再逐项改到目标状态。

  1. 抄下五项原值:存储控制器模式、启动模式、`Secure Boot`、`Fast Boot`、`BootOrder` 首位条目(照实记录,残留的旧条目不要先清理)
     看到:五项原值已写下;`BootOrder` 首位原值是后续阶段的比对基准,由 `01-4` 落进产物
  2. 存储控制器改为 AHCI(SATA)或 NVMe,并关闭 VMD / RAID On / Intel RST
     看到:固件里该取值已是 AHCI / NVMe,且 VMD / RAID On / Intel RST 开关均为关闭
  3. `Secure Boot` 保持 Enabled;固件 `Fast Boot` 设为 Disabled;CSM / Legacy Boot 设为 Disabled(仅 UEFI)
     看到:三项取值依次为 Enabled / Disabled / Disabled(CSM);`Secure Boot Mode` 若显示 Custom 则改回 Standard

脚本:scripts/windows/check-firmware.ps1 -Check(自动判 `Secure Boot` 与存储控制器;固件界面内的开关按脚本列出的"人工核对"清单逐项看;本卡无自动写动作)
坑:VMD / RAID On 必须在装 Windows 之前关闭(设计 4.1);装好系统后再改会无法启动。不要为绕过介质报错而关闭 `Secure Boot`。
出错时:固件里没有 AHCI / NVMe 选项或该项置灰 -> 按 `00-overview.md` 的偏离项处置表处理;开机报 `INACCESSIBLE_BOOT_DEVICE` -> 走文末的 RAID On 附录分支。

### 01-2 做两个安装介质(Fedora Silverblue 安装镜像 + Windows 11 ISO)

做:从官方渠道下载两个 ISO,校验后写入 U 盘(GPT + UEFI);国内镜像站只作下载加速,不作信任源。
  1. 从 Fedora 官方发布页的 Silverblue `iso/` 目录下载安装镜像,连同同目录的官方 `CHECKSUM` 与它的签名文件(`.asc` / `.gpg`)一起下载
     看到:`CHECKSUM` 里有 `SHA256 (Fedora-Silverblue-<版本>-<构建>-x86_64.iso) = <64 位十六进制>` 一行
  2. 从微软官方下载页 https://www.microsoft.com/software-download/windows11 取 Windows 11 ISO,记录来源与实测 SHA256 留档(微软不发布该镜像哈希,设计 5.3)
     看到:ISO 取自微软官方下载域、未经第三方盘中转;它的 SHA256 已记下
  3. 校验:ISO 与官方 `CHECKSUM` 放同一目录后跑脚本
     看到:Fedora ISO 的 SHA256 与官方值逐字符一致、`gpg --verify` 签名通过;Windows ISO 只按"官方下载域 + 官方安装器校验"两条确认
  4. 写入 U 盘:分盘写用 Rufus(https://rufus.ie/,分区类型 GPT、目标系统 UEFI);一盘多 ISO 用 Ventoy(https://www.ventoy.net/)
     看到:一次性启动菜单里出现带 `UEFI:` 前缀的 U 盘条目

脚本:scripts/windows/verify-install-media.ps1 -Check -IsoDir <ISO 目录>;确认 Windows ISO 来自官方下载域后加 -WindowsOfficial 重跑(本卡无自动写动作)
坑:`CHECKSUM` 与签名必须取自官方发布页,镜像站的文件可能滞后;Ventoy 在 `Secure Boot` 下须先完成一次 MOK 密钥注册,否则报 `Verification failed`。
出错时:哈希不一致 -> 重新下载或换镜像站重下;U 盘引导被 `Secure Boot` 拒绝 -> 先确认是不是 Ventoy,不要关闭 `Secure Boot`(见 `01-1`)。

### 01-3 核对目标磁盘(只核对型号与容量,防选错盘)

做:列出所有磁盘的型号与容量,与参数表 `DISK_MODEL` / `DISK_SIZE` 逐字比对,确认"将被整盘分区的那一块"。
  1. 在 Windows 里看磁盘型号与容量(`Get-Disk | Select-Object FriendlyName,Size`,或磁盘管理界面)
     看到:目标盘型号字符串与参数表一致,容量显示约 `953G`(标称 1TB 级)
  2. 多盘设备把接线 / 插槽位置也记下来(哪一块是第一块盘:两块 ESP 都必须留在第一块盘)
     看到:手上有"将被整盘分区的那块盘"的唯一识别依据

脚本:scripts/windows/preflight.ps1 -Only target-disk(只打印磁盘段:磁盘 0 未分配空间 + ESP 大小与剩余;不写报告文件,型号与容量按上一行手工核对)
坑:型号或容量对不上就停下核对,不要按"看起来差不多"推进(设计 11.1 第 9 条);分区布局与分盘动作不在这里,见 `02-partitioning.md`。
出错时:两项对不上 -> 先确认选的是哪一块盘,再回 `01-1` 复核控制器模式;分盘怎么做 -> 见 `02-partitioning.md`。

### 01-4 落 L0 产物 `baseline/00-firmware.md`

做:跑采集脚本写产物,再把人工项的实测值补齐。
  1. 先看将写入的内容(`-Check` 零写),确认无误后加 `-Apply` 落盘
     看到:产物里"启动顺序(`BootOrder` 首位)原值"一行是实测值(如 `Windows Boot Manager`),不是手册里的说明文字
  2. 按 `01-1` / `01-2` 的记录补齐人工项(控制器原值、`Fast Boot`、启动菜单键、介质校验值),再跑一次 `-Apply`
     看到:脚本报字段采齐且退出 0;人工填写值在重跑后仍被沿用(幂等)

脚本:scripts/windows/collect-l0.ps1 -Check(只打印将写入的内容);确认后 scripts/windows/collect-l0.ps1 -Apply
坑:产物缺"启动顺序(`BootOrder` 首位)原值"这一行时 L2 预检判黄(没有比对基准);`baseline/` 下除 README.md 外一律不入库。
出错时:脚本报关键字段读不到(退出 1)-> 换管理员会话重跑;多设备放 `baseline/<设备别名>/00-firmware.md`。

## L0 完成判据与下一步

- 四张卡全绿,且 `baseline/00-firmware.md` 字段无空缺。
- 下一步:进入分盘前置章节 `02-partitioning.md`(分区布局与分盘卡在那边;本文件不写分区表)。

## 厂商差异表

表内只写业界通用项名,机型专属路径不写进仓库;标"以实际固件为准"的单元格与"能否从第二块盘引导"一列,必须在设备上实测后再写进参数表。

| 厂商 | 启动菜单键 / 固件设置键 | 存储模式项名 | Secure Boot 项名 | 能否从第二块盘引导 |
|---|---|---|---|---|
| Dell | `F12` / `F2` | `SATA Operation`(取 `AHCI` / `RAID On`);NVMe 机型在 `Storage` 下 | `Secure Boot`(`Security` 或 `Boot`) | 以实际固件为准(多数机型会枚举两块盘) |
| HP | `Esc` -> `F9` / `F10` | `SATA Emulation` / `Storage` 下的 SATA 模式项;Intel 平台另有 VMD 开关 | `Secure Boot`(`Security` / `Boot Options`) | **否**(用户报告:官方口径不支持从第二块盘启动,未获一手文档确认,按最坏情况处理;两块 ESP 必须留在第一块盘,设计 3.20) |
| Lenovo | `F12`(部分机型 `Fn + F12`)或 Novo 键 / `F2` | `Storage` 下的 `SATA Controller Mode` / `Controller Mode` | `Secure Boot`(`Security` / `Boot`) | 以实际固件为准 |
| ASUS | `Esc`(部分机型 `F8`) / `F2` 或 `Del` | `SATA Configuration` / `SATA Mode Selection`;Intel 机型另有 `VMD setup menu` | `Secure Boot`(`Boot` / `Security`,可能是 `Secure Boot Control`) | 以实际固件为准 |
| Acer | `F12`(需先在固件里启用 `F12 Boot Menu`) / `F2` | `SATA Mode`(取 `AHCI` / `Intel RST with Optane` / `RAID`) | `Secure Boot`(`Boot` / `Security`) | 以实际固件为准 |
| MSI | `F11` / `Del` | `SATA Mode` / `Storage` 下的模式项;Intel 平台另有 `Intel RST` / VMD | `Secure Boot`(`Security`) | 以实际固件为准 |
| 通用 | `Esc` 或 `F12`(部分机型 `F8` / `F10` / `F11`) / `Del` 或 `F2` | `SATA Mode` / `SATA Operation` / `Storage Configuration` | `Secure Boot`(`Security` / `Boot`);`Secure Boot Mode` 取 `Standard` | 以实际固件为准 |

键位来源(厂商官方站点):Dell https://www.dell.com/support/kbdoc/en-us/000128928/flashing-the-bios-from-the-f12-one-time-boot-menu;HP https://support.hp.com/in-en/document/ish_6930187-6931079-16;Lenovo https://support.lenovo.com/us/en/solutions/ht500207 与 https://support.lenovo.com/us/en/solutions/ht062552-introduction-to-novo-button-ideapad;ASUS https://www.asus.com/us/support/faq/1013017/;Acer https://community.acer.com/en/kb/articles/563;MSI https://www.msi.com/faq/nb-901

## 附录分支:已按 RAID On / VMD 装好系统且必须保留时

主路径是"装 Windows 之前就把控制器改成 AHCI / NVMe";本分支只用于"系统已在 RAID On / VMD 下装好且不能整盘重装"(设计 4.1)。

1. 先在 Windows 里预置控制器驱动(厂商驱动包,或 `pnputil /add-driver <inf> /install`),并备份 BitLocker 恢复密钥;再回 `01-1` 把模式改为 AHCI。
2. 首次启动失败(常见 `INACCESSIBLE_BOOT_DEVICE`)时不要反复长按电源强断(设计第 9 节);用恢复环境或安全模式完成一次启动,让 AHCI 驱动被加载。
3. 之后回到 `01-3` 核对目标盘;细节在 `03-windows.md` 与 `07-rescue.md` 补齐。
