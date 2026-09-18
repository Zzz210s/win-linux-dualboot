# L0:装机前固件设定与安装介质

本文件是 L0 阶段的手册。目标状态、参数名与四条不变量在[入口文档](00-overview.md)中定义;动机与依据在[设计文档](design/00-design.md) 4.1 节与 11.1 节。

## 目标

把固件与安装介质调到"L1 能一次装成"的状态,并把全部取值落盘为 L0 产物 `baseline/00-firmware.md`。

本阶段要达成的目标状态:

| 项目 | 目标值 | 对应参数 |
|---|---|---|
| 存储控制器模式 | AHCI / NVMe,且 VMD(Intel RST / RAID On)关闭 | `FIRMWARE_MODE` |
| Secure Boot | 保持开启,不关闭、不换密钥 | `SECURE_BOOT` |
| Fast Boot | 关闭(指固件里的 Fast Boot,不是 Windows 的"快速启动") | 无(固件项,不单列参数) |
| CSM / Legacy 引导 | 关闭(仅 UEFI) | 无 |
| 启动顺序 | 本阶段不改动。判据(**可自证**):`BootOrder` 首位与步骤 1 记录的原值一致(即本阶段未改动过 `BootOrder`),且本阶段未执行过 `efibootmgr -o`。首位是谁不参与判断:已有 Windows 时原值通常就是 `Windows Boot Manager`;**设备此前部署过、刚做过整盘重装时,固件 NVRAM 里可能仍留有排在首位的旧 `ubuntu` 条目——照原样保留即可,该残留条目不属 L0 处理范围**(处置指引见 `docs/07-rescue.md` 与 L2 基线) | 不变量 I1、I2 |
| 目标磁盘 | 型号与容量与参数表一致 | `DISK_MODEL`、`DISK_SIZE` |
| 安装介质 | 官方镜像;Ubuntu 侧已核对官方 SHA256,Windows 侧来自微软官方下载域(官方未发布镜像哈希,不做 SHA256 比对) | 无 |

完成判据:固件设定值与介质校验值记录齐全(`baseline/00-firmware.md` 字段无空缺),且在 Ubuntu live 环境中通过"验证"一节的全部检查点。

两条不变量的落地位置:

- **I2**:进 Linux 只用一次性启动菜单(本阶段记录 `BOOT_MENU_KEY`)或 `BootNext`;**本阶段绝不执行 `efibootmgr -o`**。
- **I4**:首次装机时,分区表在 L1 一次定稿、基线在 L2 生成,所以本阶段改固件设置前没有基线是允许的;**若该设备此前已部署过**(`baseline/` 下已有该设备的产物),改任何固件设置之前必须先确认基线备份可用,并在改后据实更新。

## 前置条件

- 机器能进固件设置界面(BIOS / UEFI Setup)。
- 一块 ≥8GiB 的 U 盘(两个系统建议各用一块,或用 Ventoy 一盘多 ISO);U 盘会被清空,先备份其中数据。
- 官方 Windows 11 ISO 与 Ubuntu 26.04 LTS ISO 的下载途径,以及一台可用于下载与写盘的联网电脑。
- 先核对"不适用"情形,命中就停下:存储控制器模式被 OEM 锁定且不可改,或设备无法整盘格式化(见[入口文档](00-overview.md)偏离表)。
- 设备上已有的 Windows 是在 RAID On / VMD 模式下装好的,**且需要保留该系统(不走 L1 整盘重装)时**:不要直接改模式,先读本文件末尾的"附录分支:已按 RAID On / VMD 装好系统时"。**若走 L1 整盘重装**(本方案主路径),旧系统不需要保持可用,直接在步骤 2 把模式改成 AHCI / NVMe(关闭 VMD / RAID On)后进 live 环境即可,不需要驱动预置与安全模式切换。

## 步骤

### 1. 记录当前固件状态(改之前先抄下原值)

做什么:进入固件设置(开机时反复按厂商的 Setup 键,常见 `F2` / `Del`,见"厂商差异表"),把现状逐项记录下来。回滚依赖这里的原值。

需要记录的项:

- 设备型号、固件厂商与版本(常见位置:`Main` / `System Information` / `BIOS Version`);
- 启动模式:UEFI 还是 Legacy / CSM(`Boot Mode` / `Boot List Option`);
- 存储控制器模式**原值**(`SATA Operation` / `SATA Mode` / `Storage Configuration`,取值可能是 `AHCI`、`RAID On`、`Intel RST`、`VMD`);
- `Secure Boot` 状态与 `Fast Boot` 状态;
- `Boot Order` / `Boot Sequence` 第一位是谁(**照实记录**):若第一位是前次部署残留的旧 `ubuntu` 条目,也原样记下,不要先"清理"再记录——这一格是步骤 6 与验证第 6 行"启动顺序"判据的比对基准。

辅助手段:设备已有 Windows 时可用 `Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion` 与 `msinfo32` 核对;已有 Linux 时可用 `sudo dmidecode -t bios` 与 `[ -d /sys/firmware/efi ]`。无系统也能完成本步——以上取值在固件界面里都直接可见。

验证:记录里同时有"存储控制器模式原值"、"启动模式"与"`Boot Order` 第一位"三项。缺任何一项则回滚无依据、启动顺序判据也无基准,不得进入下一步。

### 2. 存储控制器设为 AHCI / NVMe(关闭 VMD / RAID On)

做什么:把控制器模式改为 **AHCI**(SATA 设备)或 **NVMe**(NVMe 设备),并关闭 VMD / RAID On / Intel RST。

为什么必须在安装 Windows **之前**完成:VMD / RAID On 模式下 Linux 安装器看不到 NVMe 磁盘;而"先按 RAID On 装好 Windows、事后再改 AHCI"会让已装好的 Windows 直接蓝屏 `INACCESSIBLE_BOOT_DEVICE`。本方案的适用设备前提是整盘重装(Windows 与 Linux 都是全新安装),这条红利只在本步兑现一次。

操作要点:

- 选项名因厂商而异(`SATA Operation` / `SATA Mode` / `Storage Configuration` / `VMD setup menu`),**具体项名以实际固件为准**;Intel 平台还要确认 `VMD` / `Intel RST` 相关开关处于关闭状态。
- 改完**保存并退出**(常见 `F10` / `Save and Exit`),重新进固件界面复查取值是否已生效。
- 若固件里根本没有 AHCI / NVMe 选项(被 OEM 锁定):该设备不适用本方案,按[入口文档](00-overview.md)偏离表处置,不要继续。
- 若该设备已按 RAID On / VMD 装好 Windows 且必须保留系统:走文末"附录分支"。

验证:固件界面复查结果为 `AHCI`(或 NVMe 模式且 VMD 关闭)。本步不验证 Linux 能否看到磁盘,统一在"验证"一节用 live 环境的 `lsblk` 复核。

### 3. Secure Boot 保持开启;Fast Boot 关闭;仅 UEFI(CSM 关闭)

做什么:

- `Secure Boot`:**保持 `Enabled`**。不改密钥、不切 `Setup Mode`、不做自签——L3 装 Ubuntu 走官方 shim + 签名 GRUB,L4 的 NVIDIA 驱动走仓库预签名包,前提都是 Secure Boot 全程开着。
- `Fast Boot`(固件项):设为 `Disabled`。它会在开机时跳过 USB 枚举,导致启动菜单里看不到安装 U 盘。
- `CSM` / `Legacy Boot` / `Legacy Option ROMs`:设为 `Disabled`,只保留 UEFI。CSM 开着时同一块 U 盘会出现 legacy 条目,选错就装成了 MBR 引导。

验证:三项取值分别为 `Enabled` / `Disabled` / `Disabled(CSM)`;若 `Secure Boot Mode` 显示 `Custom`,改回 `Standard` 后再确认。

注意:若本阶段之后还要更新固件(厂商 Windows 工具或 Linux 侧 `fwupd`),更新后必须重新复查本步骤三项取值与步骤 2 的控制器模式——固件更新可能把设置重置回默认值(RAID On / CSM 开启),那会让 L1 装完的系统起不来。

### 4. 制作安装介质(国内可用镜像站加速,校验不可省)

做什么:分别制作 Windows 11 与 Ubuntu 26.04 LTS 安装 U 盘,写盘模式为 GPT + UEFI。

下载来源:

| 介质 | 官方来源 | 国内加速(仅加速) |
|---|---|---|
| Windows 11 ISO | 微软官方下载页 https://www.microsoft.com/software-download/windows11 | 无,不走第三方 |
| Ubuntu 26.04 LTS ISO | 官方发布页 https://releases.ubuntu.com/ | 华为云镜像 https://repo.huaweicloud.com/ubuntu-releases/ |

**信任模型固定为一条**:镜像站只当下载加速器,不当信任源。**Ubuntu ISO** 的 SHA256 必须与**官方发布值**逐字符一致;唯一判据是官方发布页的 `SHA256SUMS`(路径形如 `https://releases.ubuntu.com/<版本号>/SHA256SUMS`)及其签名 `SHA256SUMS.gpg`。

**Windows ISO 官方校验值的获取途径**:微软官方下载页(https://www.microsoft.com/software-download/windows11)不发布 Windows 11 ISO 的 SHA256 值,也没有 `SHA256SUMS` 一类的官方摘要页,所以 **Windows ISO 不做 SHA256 比对(理由:官方未发布该镜像哈希)**,改用两项替代约束保证来源可信:(1) ISO 必须从微软官方下载域(`microsoft.com` / `download.microsoft.com`)直接取得,不经任何第三方盘中转;(2) 以官方安装器自身的完整性校验为准——写入 U 盘后能正常引导进入安装界面即为可用(安装能否完成在 L1 自证,不属于本阶段闸门)。若不满足 (1),或引导阶段报介质损坏,一律从官方域重新下载。日后若微软发布该镜像的官方哈希,以官方发布值为准并补做比对。

校验命令(Linux 侧):

```bash
# 从官方发布页取得 SHA256SUMS,只校验已下载的那个文件(文件名以官方发布页为准)
grep ' ubuntu-26.04-desktop-amd64.iso' SHA256SUMS | sha256sum -c -
# 期望输出:ubuntu-26.04-desktop-amd64.iso: OK
```

校验命令(Windows 侧,校验上面那个 Ubuntu ISO):

```powershell
Get-FileHash -Algorithm SHA256 .\ubuntu-26.04-desktop-amd64.iso   # 或 certutil -hashfile <iso> SHA256
```

期望输出:哈希值与官方发布值逐字符一致。不一致时**重新下载**或换一个镜像站重下,不要"先用用看"。

写盘:

- 分盘写:Windows 用 Rufus(https://rufus.ie/,分区类型选 GPT、目标系统选 UEFI);Ubuntu 也可用 Rufus 或 `dd if=<iso> of=/dev/sdX bs=4M status=progress oflag=sync`。
- 一盘多 ISO:Ventoy(https://www.ventoy.net/)。Ventoy 安装包自身的 SHA256 同样要核对,官方下载页提供校验值。
- **Ventoy + Secure Boot 注意**:Secure Boot 全程开启(步骤 3)时,Ventoy 首次引导会进入 MOK 界面,需按提示完成密钥注册(选 `Enroll key` / `Enroll MOK`,设一次密码,重启后在 MOK 界面再确认一次),否则引导被拒并报 `Verification failed: (0x1A) Security Violation`。不接受该流程,就改用 Rufus / 官方工具写入(见上一行)。
- 无论哪种方式,启动菜单里都应出现带 `UEFI:` 前缀的 U 盘条目。

验证:Ubuntu ISO 的 SHA256 与官方发布值逐字符一致;Windows ISO 满足替代约束(来自微软官方下载域、官方安装器能正常引导进入安装界面;能否装完在 L1 自证);U 盘在启动菜单里显示为 UEFI 条目(与步骤 6 一起做)。

### 5. 安装前核对目标磁盘(防选错盘)

做什么:把所有磁盘的型号与容量列出来,与参数表的 `DISK_MODEL` / `DISK_SIZE` 逐字比对,确认"将被整盘格式化的那块盘"是哪一块。

- Windows 安装界面:`Shift + F10` 调出命令行 → `diskpart` → `list disk`,再 `select disk N` / `detail disk` 看型号与容量;
- Ubuntu live 环境:`lsblk -d -o NAME,MODEL,SIZE`;
- 多盘设备:把接线 / 插槽位置也记下来(哪一块是第一块盘),避免后续选错。

期望输出:目标盘型号字符串与参数表一致,容量显示为约 `953G`(标称 1TB 级,L1 的整盘分区按约 953GiB 规划)。

判据:型号与容量两者都确认,才允许在 L1 执行整盘分区。任何一项对不上就停下核对,不要按"看起来差不多"推进——评论区多起事故正是出在"选错安装目标盘导致重装"([设计文档](design/00-design.md) 11.1 第 9 条)。

### 6. 记录厂商启动菜单键

做什么:开机自检阶段按厂商键进入**一次性启动菜单**,确认它既能列出安装 U 盘,也能列出设备上已有的可引导条目(已有 Windows 时应列出 `Windows Boot Manager`;磁盘为空或尚未安装 Windows 时列不出该条目属正常)。这个键就是参数表的 `BOOT_MENU_KEY`,也是不变量 I2 的落地手段(用它替代改 `BootOrder`)。

按键取值见下方"厂商差异表";有的机型需要先在固件里启用启动菜单(如 Acer 的 `F12 Boot Menu`,默认可能关闭)。

验证:能在菜单里选中 U 盘并成功引导一次;按键值写入参数表。本步**不改启动顺序**(I1):判据是 `BootOrder` 首位与步骤 1 记录的原值一致(即本阶段未改动过 `BootOrder`,也未执行过 `efibootmgr -o`),首位是谁不参与判断;首位是前次部署残留的旧 `ubuntu` 条目时同样满足判据,该残留条目不属 L0 处理范围(见验证第 6 行)。

### 7. 生成 L0 产物 `baseline/00-firmware.md`

做什么:按下表字段填写,路径为 `baseline/00-firmware.md`;多设备时按 [baseline/README.md](../baseline/README.md) 的布局放到 `baseline/<设备别名>/00-firmware.md`。设备别名不得含机器名、序列号、用户名。

字段清单(缺一项即视为 L0 未完成):

| 字段 | 取值来源 | 说明 |
|---|---|---|
| 设备型号 | 步骤 1 | 只写型号,不写序列号 |
| 固件厂商与版本 | 步骤 1 | 固件厂商即参数表 `VENDOR` |
| 启动模式 | 步骤 1、3 | UEFI(CSM 关闭) |
| 存储控制器模式(原值 → 目标值) | 步骤 1、2 | 原值供回滚;目标值为 AHCI / NVMe 且 VMD 关闭 |
| Secure Boot 状态 | 步骤 3 | 开启 |
| Fast Boot 状态 | 步骤 3 | 关闭 |
| 启动顺序(`BootOrder` 首位)原值 | 步骤 1 | 照实记录首位条目(如 `Windows Boot Manager`,或前次部署残留的 `ubuntu`);后续阶段比对基准 |
| 启动菜单键 | 步骤 6 | 即参数表 `BOOT_MENU_KEY` |
| CPU / GPU / 网卡型号 | 固件界面或系统信息 | 与 [baseline/README.md](../baseline/README.md) 列出的 L0 内容一致 |
| 目标磁盘型号与容量 | 步骤 5 | 即参数表 `DISK_MODEL` / `DISK_SIZE` |
| 安装介质校验值 | 步骤 4 | 每个 ISO 一行:文件名 + 校验方式 + 校验值来源。Ubuntu ISO 填 SHA256 值与官方发布值来源;Windows ISO 填"来自微软官方下载域 + 官方安装器校验(官方未发布该镜像哈希)" |

验证:`baseline/00-firmware.md` 存在且上表字段无空缺(其中"启动顺序(`BootOrder` 首位)原值"一行必须在产物里落盘——缺这行则 L2 的启动顺序比对没有基准,会被 L2 预检判为黄项);`baseline/` 下除 `README.md` 外的产物一律不入库。

### 厂商差异表(步骤 2 与步骤 6 使用)

**表内只写业界通用项名,不写具体机型的菜单路径**;标注"以实际固件为准"的单元格,以及"能否从第二块盘引导"列,都必须在该设备上实测确认后才写入参数表。

| 厂商 | 启动菜单键 | 存储模式项名 | Secure Boot 项名 | 能否从第二块盘引导 | 备注 |
|---|---|---|---|---|---|
| Dell | `F12`(一次性启动菜单 One-Time Boot Menu);固件设置 `F2` | `SATA Operation`(取值 `AHCI` / `RAID On`);NVMe 机型在 `Storage` 下 | `Secure Boot`(位于 `Security` 或 `Boot` 菜单) | 以实际固件为准(多数机型启动菜单会枚举两块盘) | 键位与项名以实际固件为准。来源:Dell 官方 KB |
| HP | `Esc`(Startup Menu)→ `F9`(`Boot Device Options`);固件设置 `F10` | `SATA Emulation` / `Storage` 下的 SATA 模式项;Intel 平台另有 `VMD` 开关 | `Secure Boot`(位于 `Security` / `Boot Options`) | **否(据用户报告:惠普官方口径不支持从第二块盘启动;未获厂商一手文档确认,按最坏情况处理)** → 双盘分支下 ESP 必须留在第一块盘 | 硬约束,直接决定分区落盘位置,见[入口文档](00-overview.md)偏离表与[设计文档](design/00-design.md) 11.1 第 8 条(该条在设计文档 3.20 标注为社区报告,无厂商一手文档支撑)。因此本行按最坏情况处理:上台实测确认前,不得按"能用第二块盘引导"规划。来源:HP 官方支持文档,仅支撑 `Esc` / `F9` / `F10` 键位,不支撑本列结论 |
| Lenovo | `F12`(部分机型 `Fn + F12`);部分消费机型用 Novo 键;固件设置 `F2` | `Storage` 下的 `SATA Controller Mode` / `Controller Mode`(取值含 `AHCI` / `Intel RST` / `RAID`) | `Secure Boot`(位于 `Security` / `Boot`) | 以实际固件为准(须在启动菜单里实测) | Novo 键机型从关机状态按 Novo 键,再选 `BIOS Setup` / `Boot Menu`。来源:Lenovo 官方支持文章 |
| ASUS | `Esc`(部分机型 `F8`);固件设置 `F2` / `Del` | `SATA Configuration` / `SATA Mode Selection`;Intel 机型另有 `VMD setup menu`(`Intel VMD Controller`) | `Secure Boot`(位于 `Boot` / `Security`,项名可能是 `Secure Boot Control`) | 以实际固件为准 | 来源:ASUS 官方 FAQ |
| Acer | `F12`(需先在固件里启用 `F12 Boot Menu`,默认可为关闭);固件设置 `F2` | `SATA Mode`(取值含 `AHCI` / `Intel RST with Optane` / `RAID`) | `Secure Boot`(位于 `Boot` / `Security`) | 以实际固件为准 | 若 `F12` 无反应,先回固件打开 `F12 Boot Menu`。来源:Acer 官方社区知识库 |
| MSI | `F11`(启动菜单);固件设置 `Del` | `SATA Mode` / `Storage` 下的模式项;Intel 平台另有 `Intel RST` / `VMD` 相关项 | `Secure Boot`(位于 `Security`) | 以实际固件为准 | 来源:MSI 官方 FAQ |
| 通用 | `Esc` 或 `F12`(部分机型 `F8` / `F10` / `F11`);固件设置 `Del` 或 `F2` | 常见项名:`SATA Mode` / `SATA Operation` / `Storage Configuration`;VMD / RST 开关通常在 `Advanced` 或 `Storage` 下 | `Secure Boot`,通常在 `Security` 或 `Boot` 菜单,取值 `Standard` / `Custom` | 以实际固件为准 | 判定方法:进一次性启动菜单,看它是否分别列出两块盘的 `Windows Boot Manager` / ESP 条目;不列出即按"只能从第一块盘引导"处理(ESP 放第一块盘) |

上述厂商键位的官方来源(均为厂商官方站点,未逐机型展开):

- Dell:https://www.dell.com/support/kbdoc/en-us/000128928/flashing-the-bios-from-the-f12-one-time-boot-menu
- HP:https://support.hp.com/in-en/document/ish_6930187-6931079-16(Startup Menu → `F9` Boot Device Options)
- Lenovo:https://support.lenovo.com/us/en/solutions/ht500207(F12 启动菜单)、https://support.lenovo.com/us/en/solutions/ht062552-introduction-to-novo-button-ideapad(Novo 键)
- ASUS:https://www.asus.com/us/support/faq/1013017/(`Esc` 进启动菜单)
- Acer:https://community.acer.com/en/kb/articles/563-why-cant-i-get-the-f12-boot-menu-to-work-on-my-notebook-or-netbook
- MSI:https://www.msi.com/faq/nb-901(`F11` 进启动菜单)

数据用途:本表用于填写[入口文档](00-overview.md)参数表的 `VENDOR` 与 `BOOT_MENU_KEY` 两格;项名只用于在固件界面里定位,机型专属路径不写进仓库。

### 附录分支:已按 RAID On / VMD 装好系统时(驱动预置 + 安全模式切换)

适用:设备上已有的 Windows 是在 `RAID On` / `Intel RST` / `VMD` 模式下装好的,且不能整盘重装。这是附录分支,不属于本方案主路径。

简版流程(细节在 `02-windows.md` 与 `07-rescue.md` 中补齐):

1. **先预置驱动,再改模式**:在 Windows 中把对应控制器的驱动装入系统(厂商驱动包 / `pnputil /add-driver <inf> /install`),使系统具备在 AHCI 下启动的能力;顺带备份 BitLocker 恢复密钥(若已启用)。
2. **改固件模式**:回到步骤 2,把 `RAID On` / `VMD` 改为 `AHCI`,保存退出。
3. **让系统完成切换**:若首次启动失败(常见为 `INACCESSIBLE_BOOT_DEVICE` 或自动进入恢复环境),**不要反复长按电源强断**([设计文档](design/00-design.md)第 9 节:反复强断会造成文件系统损坏);用恢复环境 / 安全模式完成一次启动,让 AHCI 驱动被加载。
4. 切换完成后回到步骤 5 继续。

分支判据:完成本分支后,Ubuntu live 环境能看到 `nvme0n1`,即视为控制器模式达标。

## 验证

在**步骤 4 做好的 Ubuntu 安装 U 盘**引导出的 live 环境里执行(开机时用一次性启动菜单选带 `UEFI:` 前缀的条目):

| # | 命令 | 期望输出 / 判据 |
|---|---|---|
| 1 | `[ -d /sys/firmware/efi ] && echo UEFI \|\| echo LEGACY` | 输出 `UEFI`:说明固件处于 UEFI 模式(CSM 关闭),介质也以 UEFI 模式写入 |
| 2 | `mokutil --sb-state` | `SecureBoot enabled`(live 环境通常自带 `mokutil`) |
| 3 | `lsblk -d -o NAME,MODEL,SIZE` | 出现 `nvme0n1`,型号与参数表 `DISK_MODEL` 一致、容量约 `953G` |
| 4 | `sudo dmesg \| grep -i -E 'nvme\|ahci' \| head` | NVMe 控制器已被枚举、AHCI 驱动已绑定;**看不到任何磁盘**即控制器不是 AHCI / NVMe → 回步骤 2 |
| 5 | `grep ' ubuntu-26.04-desktop-amd64.iso' SHA256SUMS \| sha256sum -c -` | 输出 `OK`(`SHA256SUMS` 取自官方发布页);Windows ISO 官方未发布镜像哈希,不做 SHA256 比对,只复核其来自微软官方下载域(见步骤 4) |
| 6 | `sudo efibootmgr` | 判据(**可自证**):`BootOrder` 首位与步骤 1 记录的原值一致(即本阶段未改动过 `BootOrder`),且本阶段**未**执行过 `efibootmgr -o`(I1、I2)。首位是谁不参与判断——已有 Windows 时原值通常是 `Windows Boot Manager`;而 `efibootmgr` 里没有 Windows 条目(裸机 / 已抹盘 / 待装),或首位是前次部署残留的旧 `ubuntu` 条目(刚整盘重装:磁盘虽空,固件 NVRAM 里旧条目仍在),同样算通过;**残留条目保留原样,不属 L0 处理范围**,处置指引见 `docs/07-rescue.md` 与 L2 基线(固件启动项快照 `baseline/02-firmware-entries.txt`) |
| 7 | 人工复核 `baseline/00-firmware.md` | 步骤 7 的字段清单全部有值,无空缺 |

7 项全部通过 = L0 完成,可进入 L1(`02-windows.md`);第 6 行按上述判据计"通过",设备上不存在 Windows 条目、或首位是残留的旧 `ubuntu` 条目,本身都不算失败。任一项不通过则按"失败处理"解决后再进 L1。

## 失败处理

| 现象 | 处置 |
|---|---|
| live 环境 `lsblk` 看不到任何磁盘(或只看到 U 盘) | 控制器不是 AHCI / NVMe。回步骤 2 确认 `VMD` / `RAID On` / `Intel RST` 已关闭且已保存退出;固件里没有该选项则按偏离表判"不适用" |
| Secure Boot 开着时 U 盘无法启动,或启动菜单里没有 UEFI 条目 | 先排除 Secure Boot 拒绝(见下一行,尤其 Ventoy 的 MOK 注册),再查介质写入模式:重新以 GPT + UEFI 方式写入(步骤 4);同时确认固件里 `Fast Boot` 为 `Disabled`、`CSM` 为 `Disabled` |
| 启动菜单里能选到 U 盘,但被 Secure Boot 拒绝(报 `Verification failed` / `Security Violation`) | 先查该 U 盘是不是 Ventoy:Ventoy 在 Secure Boot 下必须先完成 MOK 密钥注册(步骤 4);不是 Ventoy、或不愿走 MOK 流程,就改用 Rufus / 官方工具重新写入。**不要为绕过它关闭 Secure Boot**(步骤 3、回滚第 3 条) |
| 启动菜单里同一 U 盘出现两个条目 | 一个是 legacy、一个是 `UEFI:`;只选带 `UEFI:` 前缀的那个,选错会装成 MBR 引导,与 L1 的 GPT 分区表冲突 |
| `sudo efibootmgr` 里看不到 `Windows Boot Manager` 条目,或首位是前次部署残留的旧 `ubuntu` 条目 | 两种都属正常情形:L0 早于 L1(Windows 全新安装),设备可能尚未安装 Windows(裸机 / 已抹盘 / 待装);也可能磁盘虽已抹,固件 NVRAM 里的旧 `ubuntu` 条目仍在。按验证第 6 行的判据,`BootOrder` 首位与步骤 1 记录的原值一致即通过;**不得为"凑判据"去改动 `BootOrder`、也不得顺手删除旧条目**(I1、I2)——本阶段绝不执行 `efibootmgr -o`。残留条目本身不属 L0 处理范围,处置指引见 `docs/07-rescue.md` 与 L2 基线(固件启动项快照 `baseline/02-firmware-entries.txt`) |
| Ubuntu ISO 的 SHA256 与官方发布值不一致 | 不要使用该 ISO:重新下载或换镜像站重下;仍不一致时检查下载链路(代理、断点续传工具) |
| 改完控制器模式后原系统蓝屏 `INACCESSIBLE_BOOT_DEVICE` | 属于"已按 RAID On 装好系统"的情形:走"附录分支",先恢复原模式再预置驱动;不要反复强断电源 |
| 固件里的存储模式项被锁定 / 置灰 | 先尝试清除固件管理员密码或更新固件(注意步骤 3 的复查要求);仍不可改则该设备不适用本方案,按[入口文档](00-overview.md)偏离表处置 |
| `mokutil` 报 `SecureBoot disabled` | 回步骤 3 打开 `Secure Boot`,并把 `Secure Boot Mode` 从 `Custom` 改回 `Standard`;L3 的 shim 与 L4 的 NVIDIA 预签名包都以 Secure Boot 开启为前提 |
| 安装界面里选错了目标盘 | 立刻取消安装(不要点"下一步"/"确定"),回到步骤 5 逐盘核对型号与容量 |

## 回滚

1. **把存储控制器模式改回步骤 1 记录的原值**(如 `RAID On` / `VMD` 重新开启),`Fast Boot` / `CSM` 同样改回原值。原值是回滚的唯一依据,所以步骤 1 的记录不能省。
2. **对"已完成安装的系统"把模式改回原值会导致系统无法启动**——此时必须配套驱动预置(见"附录分支"),不能只改固件项。L1 装完 Windows 之后本项尤其如此:它已经不再是"随便改回去"的设置。
3. **`Secure Boot` 不作为可回滚项**:本方案从 L0 到 L5 全程保持开启(关闭它会破坏 L3 / L4 的签名链前提)。
4. 安装介质(U 盘)可整盘清空,无副作用;Ubuntu 安装 U 盘按健壮性设计 R4 保留为常备救援介质,装机结束后不回收。
5. **I4 复核**:若该设备此前已有 `baseline/` 产物,回滚固件设置后固件启动项与分区表状态可能发生变化,需重新核对并更新基线(固件启动项快照归 L2 生成,见 `03-preflight.md`),之后再做任何分区或固件变更。
