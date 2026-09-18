# 风险登记:28 条已知风险与缓解台账

本文件是这套方案的**风险登记表**,逐条落地[设计文档](design/00-design.md)第 9 节的风险表(风险 / 后果 / 缓解),并补上来源、已知事故链接、关联验收项与"风险已发生"时的现场动作。

- **条目编号 1-28 与设计文档第 9 节自上而下逐行对应**,顺序不得随意调换:新增风险追加到末尾(29 起),编号不复用。
- 术语:**I1-I4** = 四条不变量(见 [00 入口](00-overview.md));**R1-R9** = [L4 手册](05-first-boot.md)里 Ubuntu 健壮性的九项措施(设计 4.7 节);**A-F 组** = [验收清单](08-verification.md)的六组。
- **这不是"看一遍就完"的附录**:每次部署、每次动分区表或固件之前按"步骤 1"定位本阶段相关条目;每次事故按"失败处理"查表。

## 目标

- 把"这套方案会怎么坏、坏了什么后果、靠什么兜住"写在一处,避免每次都从聊天记录或记忆里重新拼;
- 让每条风险都有**可执行的缓解动作**(命令、脚本或文档步骤)与**可核对的验收项**(A-F 组编号),而不是"注意一下"这类无法验收的措辞;
- 让每次事故都能沉淀回登记表:同类事故第二次出现时,必须新增或修订条目,而不是靠人记住。

**覆盖范围**:设计第 9 节的 28 行风险全部在册,含修订五依据评论区实战证据新增的 9 条(内核/驱动自动更新、反复长按电源强断、硬件故障被误判、引导菜单阶段黑屏、安装时选错目标磁盘、双盘机型固件只认第一块盘、国内镜像未校验、为迁就驱动降级发行版、家目录重定向后的应用不兼容)。

## 前置条件

- 已读 [00 入口](00-overview.md)的四条不变量与设备参数表,以及 [设计文档](design/00-design.md)第 2、3、4、5、7、9 节;不变量是理解"为什么某条缓解是这样"的前提。
- 手上有当前设备的 `baseline/` 产物(至少 `02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt`):多条风险的缓解依赖它们可读,见 [baseline/README.md](../baseline/README.md)。
- 知道当前处在哪个阶段(L0-L5 或验收):不同阶段要盯的风险不同,见"步骤 1"的对照表。
- 救援介质(R4)在位:第 3、6、27 条的兜底路径要靠 Ubuntu 安装 U 盘或 Windows 安装 U 盘进恢复环境(第 17 条引导菜单黑屏不需要 U 盘:进系统后开 `GRUB_TERMINAL=console` + 日常改用一次性 `BootNext`/厂商菜单键即可),见 [07-rescue.md](07-rescue.md)。
- 口径:本文件只登记与分发**流程说明与外链**;第 23 条(激活合规)明确要求公开仓库不分发激活脚本本体。

## 步骤

### 1. 按当前阶段定位要盯的风险条目

开始任一阶段之前,先把该阶段对应的条目读一遍,确认缓解动作已经在流程里(而不是事后补救):

| 阶段 | 先读这些条目 | 为什么 |
|---|---|---|
| L0 装机前 | 1(Intel VMD/RAID)、18(选错目标磁盘)、19(固件只认第一块盘)、20(镜像未校验) | 这几条在 L0 是**一次性窗口**:VMD 必须在装 Windows 之前关;镜像校验必须在制盘之前 |
| L1 Windows | 2(BitLocker)、4(Fast Startup 与双写 NTFS)、5(ESP 过小)、8(WinRE 放置的版本敏感性)、28(重定向遗漏) | 分区表一次定稿 + 立即关 Fast Startup + 完成重定向,是后面所有阶段的前提 |
| L2 预检与基线 | 2、5、6(引导顺序被改)、24(快照容量)、25(`GRUB_DEFAULT=saved`) | L2 是唯一硬闸门,基线产物正是第 3、6、26、27 条的兜底 |
| L3 Ubuntu 安装 | 7(Secure Boot 下 NVIDIA 签名)、17(引导菜单阶段黑屏)、18、21(降级发行版)、22(家目录兼容性) | 安装器界面最容易出不可逆动作(格式化 ESP、选错盘) |
| L4 首启收敛 | 7、9(时间与蓝牙分裂)、11(`ntfs3` 写入损坏)、12(共享盘被加密)、13(POSIX 语义差异)、14(内核/驱动自动更新)、16(硬件被误判)、22、24、25、28 | 共享盘与显卡是本阶段两大风险源;健壮性措施 R1-R9 就是这些条目的缓解落地 |
| L5 退役与救援 | 3(Windows 更新重写 ESP)、6、26(重装误格分区)、27(重装误格 ESP) | 退役与重装是全流程最不可逆的两段 |
| 任意时刻 | 10(KMS 续期)、15(长按电源强断)、16、23(激活合规) | 与阶段无关的长期项 |

### 2. 每次变更前,先确认缓解在位

变更 = 内核/驱动更新、分区表或固件设置改动、退役、重装。动手前的确认清单:

1. **回滚点在位**:第 24 条的缓解要求"快照失败即视为不得执行本次变更";内核/驱动变更必须有快照(R1),见 [L4 手册](05-first-boot.md)与 [验收 F1](08-verification.md)。
2. **基线可读**:第 3、6、26、27 条的兜底都依赖 `baseline/02-esp-backup/` 与 `02-firmware-entries.txt`(I4);改动分区表或固件之前先按 [L2 手册](03-preflight.md)重做一次基线。
3. **退路在位**:第 27 条的兜底是救援 U 盘;第 17 条(引导菜单阶段黑屏)不需要 U 盘——靠 `GRUB_TERMINAL=console` + 日常改用一次性 `BootNext`/厂商菜单键(见"前置条件"与 [L3 手册](04-ubuntu.md))。确认 `BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) 可用,**不得**用 `efibootmgr -o`(I2)。
4. **四条不变量未被破坏**:改完立刻复跑 [验收 A 组](08-verification.md)的 A1、A3、A4。
5. **Windows 更新之后**:按 7.1 节巡检四项(第 3 条的正面对策),见 [07-rescue.md](07-rescue.md) 第 7 节。

### 3. 风险登记表(28 条)

"关联"列指向 [验收清单](08-verification.md)的条目编号或巡检动作;写成"--"的条目不属于验收范围(属治理或长期运维项),但同样要有责任人。

| # | 风险 | 后果 | 缓解 | 关联 |
|---|---|---|---|---|
| 1 | **Intel VMD / RAID On** | Linux 安装器看不到磁盘 | 在装 Windows **之前**就设为 AHCI/NVMe(全新设备的最大红利,见 [L0 手册](01-firmware.md));已装好才改则走"驱动预置 + 安全模式"的分支(附录路径,不属主路径) | L0 记录 `FIRMWARE_MODE`;L2 报告核验 |
| 2 | **BitLocker** | 改分区表或固件设置触发恢复密钥索要 | 备份 48 位恢复密钥 -> 挂起保护(`manage-bde -protectors -disable C: -rebootcount 0`)-> 操作 -> 恢复保护;见 [L2 手册](03-preflight.md) | L2 报告的保护状态行;A1/A3/A4 复检 |
| 3 | **Windows 更新重写 ESP / SBAT-DBX 事件** | Linux 引导消失,或出现签名校验失败("Something has gone seriously wrong")| ESP 镜像备份 + 常备救援 U 盘;必要时清理 SBAT 策略(`mokutil --set-sbat-policy delete`,7.1 节);事故后按 [07-rescue.md](07-rescue.md) 第 3 节基线回滚 | 周期性巡检(A3/A4);7.1 节 |
| 4 | **Fast Startup + 双写 NTFS** | 共享数据分区损坏 | L1 强制关闭 Fast Startup 与休眠;**共享盘禁止在 Windows 处于休眠/混合关机状态时被 Linux 挂载**;见 [L4 手册](05-first-boot.md)步骤 1 的三条前提 | B4、B5 |
| 5 | **ESP 过小** | 后续内核/引导文件放不下 | 整盘重装时把 ESP 定为 **2GiB**(决策 3.4);ESP 尺寸不允许被削减,安装器自行改小即视为偏差并据实调整 | L2 闸门报告;D5 |
| 6 | **引导顺序被改** | 删除 Linux 后卡 `grub rescue` | 四条不变量(I1/I2)+ L5 退役流程 + L2 基线;任何情况都用"删除条目"代替"改顺序" | A1、A5、A6、C4 |
| 7 | **Secure Boot 下 NVIDIA 模块签名** | 驱动不加载,严重时无桌面 | 只用 Ubuntu 仓库的**预签名**包,不做 DKMS、不自签密钥、不关 Secure Boot;保留 `nouveau` 兜底(决策 3.3、3.17) | B2、B3 |
| 8 | **Windows 安装程序对恢复分区放置的版本敏感性** | 预留空间被占用,分区表偏离计划 | L2 逐项核对分区表;**偏离可接受**(仅 ESP 尺寸不可削减),记录偏差并据实调整 | D5、E3;`baseline/02-partitions.txt` |
| 9 | **双系统时间 / 蓝牙状态分裂** | 时钟错乱、设备需反复重新配对 | `RTC in local TZ: no`(Linux 用 UTC);蓝牙走上游 `bt-keys-sync`,以 Windows 侧密钥为权威来源 | B7、B8 |
| 10 | **KMS 续期依赖可达的 KMS 主机** | 180 天周期内未成功续期会导致激活失效 | 保留上游的续期计划任务(每 7 天)并定期核对激活状态;失效时重新执行一次在线激活流程(决策 3.10) | --(L1 激活步骤 + 定期核对) |
| 11 | **`ntfs3` 写入导致共享盘数据损坏** | 办公文件丢失 | 关键目录保留第二份备份(云端或外置盘);避免在 Linux 侧批量重命名/移动大目录;不在共享盘上跑依赖权限位的工具链 | B4、B5;5.3 节风险段 |
| 12 | **共享盘被 BitLocker / 设备加密** | Linux 侧无法挂载,共享方案失效 | 装机时 `D:` 保持不加密;若 Windows 自动启用设备加密,**先解密再继续**;无法解密则把共享挂载降级为只读或改用独立共享分区变体 | B4 前提;L3/L4 |
| 13 | **POSIX 语义差异** | 依赖符号链接/权限位的工具在共享盘上报错 | 共享盘只放文档类数据;代码仓库、`~/.ssh`、`~/.config` 一律留在 Linux 本地 root(设计 4.5、5.3) | B4、B6 |
| 14 | **内核/驱动被自动更新** | 与显卡驱动不适配,黑屏或进不了桌面 | 决策 3.18:`linux-*`、`nvidia-*` 列入自动更新黑名单;变更前先快照、保留旧内核 | F3、F5 |
| 15 | **反复长按电源强制重启** | 文件系统损坏、满屏报错进不去 | 用 **REISUB**(SysRq)安全重启;事后跑 `fsck`;"不要反复强断"已写进排障纪律 | [07-rescue.md](07-rescue.md) 第 8 节 |
| 16 | **把硬件故障误判为双系统问题** | 浪费时间、误删系统、掩盖真实故障 | 硬件优先 triage:内存 / 磁盘 / 温度 / 电源;明确"两系统运行期互不影响,只有引导层会互相干扰" | F8;验收"失败处理"末行 |
| 17 | **引导菜单阶段黑屏** | 误以为系统损坏而重装 | 决策 3.19:`GRUB_TERMINAL=console` 条件项 + 日常切换改用一次性 `BootNext`/厂商菜单键;菜单黑屏不等于系统坏了 | B10、C1 |
| 18 | **安装时选错目标磁盘** | 误格数据盘或另一系统 | 设备参数表用 `DISK_MODEL`/`DISK_SIZE` 在安装前逐盘核对;安装器里逐分区确认路径与容量 | [L3 手册](04-ubuntu.md);D3、D4 |
| 19 | **双盘机型固件只认第一块盘** | 引导文件放错盘,装完无法启动 | 厂商差异表增加"能否从第二块盘引导"列;**ESP 必须在第一块盘**(偏离项处置) | [00 入口](00-overview.md)偏离项;L0 |
| 20 | **国内镜像站下载未校验** | 镜像损坏或被替换 | 下载后核对 SHA256 与官方发布值(**镜像站只作为下载加速,不作为信任源**);Windows 侧只做"来自微软官方下载域 + 官方安装器校验" | [L0 手册](01-firmware.md)介质校验 |
| 21 | **为迁就驱动而降级发行版** | 支持期缩短、新硬件兼容更差 | 优先换内核(HWE)或换驱动版本;不降发行版(决策 3.17 被否方案) | L3 故障矩阵;L4 显卡章节 |
| 22 | **家目录重定向后的应用不兼容** | 个别程序不认自定义 XDG 目录,或在 NTFS 上无法保存权限位 | 只重定向文档类目录;需权限语义的留在本地;出问题回退 `user-dirs.dirs`(`.dbk.bak` 备份) | B6;验收"失败处理" |
| 23 | **激活方案的平台合规风险** | 仓库或账号层面的合规问题 | 公开仓库只做外链与流程说明,**不分发任何激活脚本本体**;附风险与责任声明 | --(治理项) |
| 24 | **快照分区容量耗尽** | 变更前快照创建失败,回滚点缺失 | 限制保留份数(默认 3 份);**快照失败即视为"不得执行本次变更"** | F1、F2 |
| 25 | **`GRUB_DEFAULT=saved` 被误改** | 默认启动项漂移 | 纳入周期性巡检(F 组 + 7.1 节);`/etc/default/grub` 改动前留 `.dbk.bak` | F3 |
| 26 | **原地重装时误格分区** | 数据分区或另一边系统被清空 | 安装时逐分区核对;**明确禁止"删除所有分区"**;动手前先做 L2 基线备份与 NVRAM 另存 | D3、D4 |
| 27 | **重装 Ubuntu 时误格 ESP** | 连带破坏 Windows 引导(全流程最危险的一步) | 显式检查安装器里 ESP 的"格式化"勾选是否**未被勾上**;ESP 镜像可复原,但必须先备份 | D4、D6;A7 演练 |
| 28 | **已知文件夹重定向遗漏** | 数据落在 `C:`,重装即丢 | L1 完成后按验收 D 组逐项核对重定向;重定向清单固化为文档步骤,重装后必重做一次 | D2;B6 |

### 4. 来源与已知事故

- **2024-08 SBAT / Secure Boot DBX 事故**(第 3 条,微软已确认):Windows 月度安全更新(KB5041571 / KB5041580)把 SBAT 策略下发到了本不该受影响的双系统机器,导致部分 Linux 引导器拒绝加载、报 "Something has gone seriously wrong"。报道与微软回应:[BleepingComputer](https://www.bleepingcomputer.com/news/microsoft/microsoft-confirms-august-updates-break-linux-boot-in-dual-boot-systems/)、[Ars Technica](https://arstechnica.com/security/2024/08/a-patch-microsoft-spent-2-years-preparing-is-making-a-mess-for-some-linux-users/)、[The Verge](https://www.theverge.com/2024/8/21/24225108/microsoft-security-update-windows-linux-dual-boot-errors)、[Neowin](https://www.neowin.net/news/microsoft-shares-more-info-on-fixing-broken-dual-boot-after-august-patch-tuesday-updates/)、[heise](https://www.heise.de/en/news/Windows-update-paralyzes-Linuxes-again-9838334.html)。本方案的应对:ESP 镜像备份 + 常备救援 U 盘 + 7.1 节巡检 + 必要时清理 SBAT 策略。
- **BitLocker 在固件/非微软更新前的挂起**(第 2 条):[Suspend BitLocker protection for non-Microsoft software updates](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/suspend-bitlocker-protection-non-microsoft-updates);恢复密钥索要的已知问题清单见 [BitLocker recovery: known issues](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/bitlocker-recovery-known-issues)。
- **Intel RST / VMD 下 Linux 看不到磁盘**(第 1 条):[Intel RST during Ubuntu installation](https://ubuntu.com/desktop/docs/en/latest/reference/intel-rst-during-ubuntu-installation/)(Ubuntu 官方文档;切换 AHCI 的安全顺序以该文与厂商说明为准)。
- **上游与参考项目**(缓解动作的实现来源,均可外链、不内置代码库):[gillesduif/iGloo](https://github.com/gillesduif/iGloo)(safety-model:BootNext 一次性启动、只用原生分区缩容、ISO 校验、保留 nouveau 兜底)、[ublue-os/bazzite](https://github.com/ublue-os/bazzite)(先关 BitLocker 与 Fast Boot、双盘场景拔盘等结论)、[KeyofBlueS/bt-keys-sync](https://github.com/KeyofBlueS/bt-keys-sync)(第 9 条)、[pgaskin/bootnext](https://github.com/pgaskin/bootnext) 与 [mendhak/grub-reboot-picker](https://github.com/mendhak/grub-reboot-picker)(一次性启动机制)、[massgravel/Microsoft-Activation-Scripts](https://github.com/massgravel/Microsoft-Activation-Scripts)(第 10、23 条)、[fwupd/fwupd](https://github.com/fwupd/fwupd)、[bayasdev/envycontrol](https://github.com/bayasdev/envycontrol)、[rezzcode/grub-rescue](https://github.com/rezzcode/grub-rescue) 与 [blindma1den/windows-11-uefi-boot-repair](https://github.com/blindma1den/windows-11-uefi-boot-repair)(第 3、6、17 条的救援来源;后者的命令写法偏 legacy,以 [07-rescue.md](07-rescue.md) 的口径为准)。
- **评论区实战证据**(第 14、15、17、18、19、21 条等):B 站《Windows11 安装 Ubuntu 避坑指南》(https://www.bilibili.com/video/BV1Cc41127B9)的评论区归纳见[设计文档](design/00-design.md)11.1 节;该样本仅顶层 3 条热评及其子回复,**不是全量样本**,引用时不得当作统计结论。
- **内部依据链**:每条风险的"后果"与"缓解"取自[设计文档](design/00-design.md)第 9 节;故障处置矩阵在第 7 节;回滚三粒度在 7.2 节;验收判据在 [08-verification.md](08-verification.md)。

### 5. 登记表的维护规则

1. 每次事故处理后,回到本文件判断:是已有条目的复发(更新其"缓解"与"关联"),还是新类型(追加到 29 起)。
2. 同一条目在两台以上设备上复发,说明缓解动作在流程里没落地——去改手册或脚本,而不是在表里加一句"注意"。
3. 缓解动作被证明无效或因设计变更失效时,**修订本条目**并同步更新[设计文档](design/00-design.md)第 9 节;两处口径必须一致。
4. 条目顺序不与设计第 9 节脱钩:修改本表前先改设计文档,再回来改这里(与四条不变量的改动纪律一致)。

## 验证

- **覆盖完整**:本表编号 1-28 与设计文档第 9 节的 28 行自上而下逐条对应,无遗漏、无合并。核对方式:`grep -cE '^\| [0-9]+ \|' docs/09-risks.md` 应为 `28`(表头与说明行不计)。
- **缓解可执行**:每条的"缓解"要么是可复跑的命令/脚本(如第 2 条的 `manage-bde -protectors -disable`、第 3 条的 `mokutil --set-sbat-policy delete`),要么指向具体文档章节与产物;没有"注意/小心/尽量避免"这类无法验收的措辞。
- **缓解有验收落点**:除第 10、23 条(治理与长期运维项)外,"关联"列都指向 A-F 组的具体条目;若某条的关联项在验收中判为未通过,则该条风险视为**未缓解**,按"失败处理"处置。
- **来源可追溯**:第 4 节的每个外链都能打开,且与所注条目对应;引用评论区证据时保留"非全量样本"的限定。
- **巡检维持**:每次 Windows 大版本或累积更新之后按 7.1 节重跑四项巡检(第 3、6 条的正面对策,见 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 与 [07-rescue.md](07-rescue.md) 第 7 节)。
- **文档自检**:改动本文件后运行 `bash scripts/repo/check-docs.sh docs/09-risks.md`,期望 `check-docs: OK`。
- **与验收的关系**:本文件不产生新的勾选项;[验收清单](08-verification.md)全绿即主要缓解措施在位,"已知例外"清单(E4)是残余风险的唯一正式记录处。

## 失败处理

风险已经发生时的现场动作。原则:**先判断在哪一层(引导层 / 系统层 / 数据层 / 硬件层),再动手**;动手顺序永远优先"让 Windows 先能启动"。

| 风险条目 | 现场动作 | 兜底路径 |
|---|---|---|
| 3 Windows 更新重写 ESP | 先用一次性入口或厂商菜单键确认 Windows 仍能启动;按 [07-rescue.md](07-rescue.md) 第 3 节做基线还原 + `bcdboot` + NVRAM 清理;`bootmgfw.efi`/`BCD` 的差异按"预期差异"解释 | ESP 备份 + 救援 U 盘 |
| 6 引导顺序被改 / 卡 `grub rescue` | **不要先删分区**。按 [07-rescue.md](07-rescue.md) 第 1 节两条路处置(修 GRUB 或直接链回 Windows);进系统后按第 6 节把 `BootOrder` 首位复原为 Windows Boot Manager,**不得用 `efibootmgr -o`** | L2 基线与 `02-firmware-entries.txt` |
| 17 引导菜单阶段黑屏 | 键盘仍可用:直接选菜单项或用一次性入口进系统;进系统后打开 `GRUB_TERMINAL=console` 再 `update-grub`;**不要重装** | [templates/grub-defaults.snippet](../templates/grub-defaults.snippet) |
| 27 重装 Ubuntu 时误格 ESP | 立刻停止后续安装动作;挂载 ESP 检查 `\EFI\Microsoft\` 是否还在;不在则按 [07-rescue.md](07-rescue.md) 第 3 节还原 + `bcdboot`;`\EFI\ubuntu\` 按 3.1 节两条来源重建 | ESP 备份(必先备份后动手) |
| 11 `ntfs3` 写入损坏 / 4 Fast Startup 双写 | 立即停止写入(必要时改为只读挂载或卸载共享盘);用第二份备份评估恢复;**先回 Windows 关 Fast Startup 与休眠**再排查其余写入路径 | 关键目录的第二份备份 |
| 12 共享盘被加密 / 13 POSIX 语义报错 | 第 12 条:先在 Windows 解密,解密前 Linux 侧只读挂载或直接停用共享盘;第 13 条:把该工作流搬回 Linux 本地 root,共享盘只留文档类数据 | 只读挂载 / 独立共享分区变体 |
| 14 内核或驱动被自动更新后进不了桌面 | 重启在 GRUB "Advanced options" 选旧内核;进系统后从 `/snapshots` 回滚;随后修回更新策略(黑名单) | R3 + R1/R2 + [templates/unattended-upgrades.snippet](../templates/unattended-upgrades.snippet) |
| 25 `GRUB_DEFAULT=saved` 被误改 | 用 `/etc/default/grub.dbk.bak` 恢复该键,`sudo update-grub`;重启确认默认项符合预期 | 备份文件 |
| 24 快照创建失败 | **不得执行本次变更**;清理旧快照(保留上限 3 份)、检查 `/snapshots` 挂载与空间后重试 | [L4 手册](05-first-boot.md)快照章节 |
| 15 反复长按电源强断之后 | 启动前先做一次 `fsck`(必要时从 live 环境);以后用 REISUB 代替长按电源 | [07-rescue.md](07-rescue.md) 第 8 节 |
| 16 怀疑硬件故障 | **硬件优先 triage**:内存测试、`smartctl`、温度与电源;同时停掉一切重装/退役动作,避免带故障盘做不可逆操作 | F8 判据 + 验收"失败处理" |
| 1 / 18 / 19 安装期选错盘或看不到盘 | 立即停手,不继续安装;回 L0 核对 `FIRMWARE_MODE`、`DISK_MODEL`/`DISK_SIZE`;两盘机型确认 ESP 在第一块盘 | [L0 手册](01-firmware.md)、[L3 手册](04-ubuntu.md) |
| 2 BitLocker 索要恢复密钥 | 输入已备份的 48 位恢复密钥;进系统后恢复保护状态;下次涉及 `C:` 或其相邻布局的变更前先挂起保护 | [L2 手册](03-preflight.md) |
| 20 / 21 / 22 / 28 环境与兼容类 | 第 20 条:重新下载并核对官方校验值;第 21 条:换内核(HWE)或换驱动,**不降发行版**;第 22 条:回退 `user-dirs.dirs`;第 28 条:重做一遍重定向核对 | [L0](01-firmware.md)、[L3](04-ubuntu.md)、[L4](05-first-boot.md) |
| 10 KMS 激活失效 | 检查续期任务与 KMS 主机可达性,手动触发一次续期;仍失败则重新执行一次在线激活流程 | [L1 手册](02-windows.md)激活章节 |
| 23 合规问题 | 立即下架仓库内任何激活脚本本体或密钥材料,只保留外链与流程说明;在 README 与相关手册加风险与责任声明 | 治理动作,无技术兜底 |

**纪律**(三条最容易犯的错):

1. 两个系统一起异常时,**先按硬件问题排查**(第 16 条),不要归因于"双系统互相影响"——运行期两系统不共享状态。
2. 任何引导类处置都不得改写 `{bootmgr}` 的 `path`、不得用第三方"一键引导修复"工具(I3),"删除条目"永远优于"改顺序"(I2)。
3. 数据侧风险(第 11、12、26 条)出现时,**停写优先于修复**:先让盘冷静下来,再考虑恢复。

## 回滚

- **风险登记本身没有"回滚"**:条目一旦登记不删除,只有"修订"与"标注失效"。历史条目被证明过时(如某事故已被厂商修复到不可能复发)时,在条目里标注判断依据与日期,而不是删掉——同一条目第二次出现时,历史判断正是最有用的信息。
- **风险发生后的回滚**,按[设计文档](design/00-design.md)7.2 节的三种粒度执行:
  | 粒度 | 场景 | 手段 |
  |---|---|---|
  | 单步回滚 | 第 17、22、25 条:菜单黑屏、重定向、GRUB 键被误改 | 回到该步骤的"回滚方式"(移除 `GRUB_TERMINAL` 行、还原 `user-dirs.dirs`、恢复 `.dbk.bak`) |
  | 阶段回滚 | 不再需要 Linux(第 6、27 条的预防性做法) | [L5 退役手册](06-decommission.md)五步,顺序不可换 |
  | 基线回滚 | 第 3、6、27 条:ESP 或固件启动项被破坏 | `baseline/02-esp-backup/` 还原 + `bcdboot` + NVRAM 清理 + 巡检四项([07-rescue.md](07-rescue.md) 第 3 节) |
- **不可逆项(动手前先读一遍)**:第 26 条(误格 `D:` 或 Linux 分区)、第 27 条(误格 ESP 且无备份)、第 21 条(降级发行版后支持期已缩短)、第 11 条(`ntfs3` 写入已损坏且无第二份备份)。这四条一旦发生,只能用"重装 + 数据恢复"补救,所以缓解动作全部前置在"动手之前"。
- **与验收的闭环**:风险发生并处置完成后,回到[验收清单](08-verification.md)重跑受影响的那一组(A-C 组对应引导与切换,F 组对应健壮性,D 组对应可撤除性),并把结果与残余风险写进该设备的"已知例外"(E4),再来修订本表。
