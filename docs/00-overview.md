# 入口:三轨道地图、四条不变量与设备参数表

**本页是地图,不是流程**:它只回答"照着做之前必须知道什么"与"每一步去哪份文档、产出什么";动作级内容全部在手册的操作卡里,本页**不写操作卡**(不受卡格式约束,但仍受引用可解析、禁止跨文件锚点、相对链接存在性与 emoji 检查约束)。

本文件同时是整套手册的**命名契约**:四条不变量 I1-I4、设备参数表的字段名、各阶段产物名都在这里定义,手册与脚本引用这些名字时不得改名。

方案依据(目标、决策记录、事实清单、34 条风险)在 [设计文档](design/00-design.md);原子版变体的决定与证据在 [02-fedora-atomic-variant-design.md](design/02-fedora-atomic-variant-design.md),本页不复述。

**必须同时满足**(缺一项先按下方偏离表处置):

- 单块 NVMe SSD,标称 1TB 级(UEFI + GPT 引导);**容量口径**:1024GB 型号可用约 **953.7GiB**(方案分区表按此制定),1000GB 型号仅约 **931.3GiB**(此时把 `D:` 从 ≈635GiB 减到 ≈613GiB,其余七项不动 —— 详见设计 5.1 的容量偏离分支);混合显卡(集成显卡 + 独立显卡);允许整盘格式化(两个系统都是全新安装)。
- 目标系统:**Windows 11 专业版 + Fedora 44 Silverblue**(原子版,GNOME 50,默认 Wayland 会话)。
- 覆盖范围:三轨道 **W**(只 Windows)/ **L**(只 Silverblue)/ **D**(双系统)+ 共用底座;机器动作量约 9 / 10 / 19 步。

**偏离项处置**:

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP;四条不变量不变 |
| 容量明显偏离 1TB 级(512GiB / 2TiB) | 按比例调整 `C:` 与 Linux 侧容量;分区布局与四条不变量不变 |
| 双盘机型且固件只从第一块盘引导 | ESP **必须留在第一块盘**;Linux 分区可放第二块盘,但引导文件不能放第二块盘 |
| BitLocker 已启用 | 先挂起保护并备份 48 位恢复密钥,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 锁定、桌面非 GNOME 50、需要磁盘加密 | VMD / RAID 锁定与磁盘加密**不适用于 v1**;桌面走 Kinoite(原子 KDE,Plasma 6.6.4)对等替代 |

---

## 四条不变量

整个方案的骨架。手册中任何步骤不得违反;违反即视为设计缺陷,而非操作失误。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| **I1** | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向失效的 `\EFI\ubuntu\grubx64.efi`,重启停在 `grub rescue>` |
| **I2** | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| **I3** | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| **I4** | 改分区表或固件设置之前,先完成基线备份(BitLocker 挂起 + ESP 镜像 + 固件启动项快照)——**首次装机时**,分区表在 L1 一次定稿、基线在 L2 生成;**此后的任何分区表或固件变更,都必须先有可用的基线备份** | 除重装外无路可退 |

**I1–I4 的落地方式(本次修订更新)**:Linux 侧条目(`\EFI\fedora\`)现在写在自己独立的 1GiB ESP 上(I3 由**结构**保证,不再只靠纪律),启动项名称的匹配串以实施时实测为准。另注:I1 举例中的 `\EFI\ubuntu\`(历史举例,按"逐字不改"要求保留)在本方案对应 `\EFI\fedora\`。

**为什么是这四条**:网络上"卡 grub 命令行"的根因不是 GRUB 坏了,而是固件 NVRAM 里的启动条目仍指向已被删除的引导文件,且它排在启动顺序前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目后继续回落到 Windows。这比"记得先修引导再删分区"可靠——后者依赖人的记忆。

---

## 目标分区表(8 项)

标称 1TB 的 NVMe,实际可用约 953GiB。下表为安装器 / 磁盘管理的 GUI 显示值,`diskpart` 脚本按同一组目标值编写。

| 序号 | 分区 | 大小 | 类型 | 挂载 / 用途 |
|---|---|---|---|---|
| 1 | ESP-Windows | **2GiB** | EFI System(FAT32) | **只给 Windows**;只放 `\EFI\Microsoft\` 与 `\EFI\BOOT\` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 C: | **200GiB** | NTFS | 系统与程序;**原地重装时唯一被格式化的分区** |
| 4 | Windows 数据 D: | **≈635GiB** | NTFS | 游戏库、下载、文档、容器镜像;已知文件夹重定向的目标;**双系统共享分区** |
| 5 | **ESP-Fedora** | **1GiB** | EFI System(FAT32) | Silverblue 独立 ESP;只放 `\EFI\fedora\`;挂 `/boot/efi` |
| 6 | **`/boot`** | **1GiB** | ext4 | 原子版**必须独立**;每个 deployment 的内核与 initrd 在此 |
| 7 | **Fedora root** | **≈113GiB** | btrfs | `/`;ostree 部署 + `var` 子卷(`/home` 是到 `/var/home` 的符号链接) |
| 8 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈ 953GiB:2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1。Fedora 侧合计 **115GiB**(= 1 + 1 + 113),与参数表一致。

- **Fedora 侧三块分区在 L1 预留的 115GiB 未分配区内创建**:L1 的 `diskpart` 只分到 `D:` 为止,余量**不分配**;L3 安装器在这个区间里切出上述三块(ESP-Fedora 1GiB + `/boot` 1GiB + root ≈113GiB)。共享数据盘 `D:` ≈635GiB NTFS(约占全盘三分之二,两个系统都能读写);无 swap 分区,交换空间由 zram 与 swapfile 在 L4 配置;ESP 尺寸不允许被削减,若 Windows 安装程序自行占用预留空间则记录偏差并据实调整。

---

## 设备参数表

每台设备部署前填一份,与 `baseline/` 的子目录一一对应;字段名逐字固定,不得改名、不得新增同义字段。

| 参数 | 含义 | 示例 |
|---|---|---|
| `DISK` | Linux 侧设备名 | `/dev/nvme0n1` |
| `VENDOR` | 固件厂商 | Dell / HP / Lenovo / ASUS |
| `BOOT_MENU_KEY` | 厂商启动菜单键 | Dell F12、HP F9、Lenovo F12/F10、通用 ESC |
| `FIRMWARE_MODE` | 存储控制器模式 | AHCI / NVMe(VMD 关闭) |
| `GPU` | 显卡组合 | Intel + NVIDIA(混合) |
| `ESP_SIZE` | 目标 ESP-Windows 大小 | 2GiB |
| `FEDORA_ESP_SIZE` | 目标 ESP-Fedora 大小(**新增**) | 1GiB |
| `BOOT_SIZE` | 目标 `/boot` 大小(**新增**) | 1GiB(ext4,必须独立) |
| `ROOT_SIZE` | 目标 Fedora root 大小(**新增**) | ≈113GiB(btrfs) |
| `UBLUE_IMAGE` | ublue NVIDIA 变体的镜像与分支引用(**新增**;值**待核实**) | 形如 `ostree-image-signed:docker://ghcr.io/ublue-os/<变体>-nvidia:<分支>` |
| `WINDOWS_SYSTEM_SIZE` | 目标 Windows 系统分区大小 | 200GiB |
| `WINDOWS_DATA_SIZE` | 目标 Windows 数据分区大小 | ≈635GiB |
| `SECURE_BOOT` | Secure Boot 目标状态 | 开启 |
| `DISK_MODEL` | 目标磁盘型号(安装前核对,**防装错盘**) | Samsung MZVLQ1T0HBLB |
| `DISK_SIZE` | 目标磁盘容量 | 标称 1TB / 约 953GiB |
| `SHARED_PART_UUID` | 共享数据分区(D:)的 UUID | 安装后由 `blkid` 获取 |

- Linux 侧参数由旧方案的"`ROOT_SIZE` 100GiB + `SNAPSHOT_SIZE` 15GiB"改为"`FEDORA_ESP_SIZE` 1GiB + `BOOT_SIZE` 1GiB + `ROOT_SIZE` ≈113GiB"(`SNAPSHOT_SIZE` 不再存在);`UBLUE_IMAGE` 的镜像名与分支、`ujust` 任务名、MOK 密码**均须在实施时核实**,未核实前不得写成确定步骤。
- `*_SIZE` 各字段是"目标值",写入 L1 的 `diskpart` 脚本,实际分区表以 L1 产物为准并记录偏差;`SHARED_PART_UUID` 是唯一一个安装后才能确定的字段,回填后必须与 [templates/fstab.snippet](../templates/fstab.snippet) 里的值一致。

---

## 原子版硬语义与两项否决

- **`/usr` 只读**:系统本体由 ostree 管理,不能就地 `dnf install`;系统级工具必须用 `rpm-ostree install` 分层。
- **分层安装需重启**:每次分层 / 更新 / rebase 都产生**新 deployment**,必须重启才生效;判据要区分"命令成功"与"重启后生效"。
- **`/var` 与 `/home` 不随部署回滚**:`/var/home` 是真正的家目录,`/home` 是指向它的符号链接;回滚系统不回退用户数据(用户数据不丢),这也是"只重装 root 时数据可保留"的前提。

口径补充:GUI 应用优先 Flatpak,开发环境走 `toolbox` / `distrobox`;回滚粒度四级 —— 单步撤销 -> 部署级(`rpm-ostree rollback` 或 GRUB 菜单选上一个 deployment)-> 基线级(ESP / NVRAM)-> 阶段级(退役)。

**明确被否两项**:不使用 **`snapd`**(应用分发走 Flatpak,系统层走 `rpm-ostree` 分层);不使用 **`snapper` / `grub-btrfs` / btrfs 快照**(回滚是系统部署级,不是文件系统快照级,v1 非目标里已剔除一切 btrfs 快照回滚与第三方快照工具)。

---

## 三轨道地图

| 轨道 | 步骤(做什么) | 去哪份文档 | 产出什么 |
|---|---|---|---|
| **共用底座**(三条轨道都要) | 固件设置 -> 做两个安装介质(Windows 11 ISO + Fedora Silverblue 镜像)-> 核对目标盘 -> 落 L0 产物 | [01-firmware.md](01-firmware.md) | `baseline/00-firmware.md`(含 `BootOrder` 首位原值) |
| **共用底座之二** | 分盘:认下本机轨道的目标布局 -> 按轨道分盘(整盘重排、一次分好,禁止事后缩容) | [02-partitioning.md](02-partitioning.md) | 分区记录进 `baseline/`(W/D 落 `01-partitions.txt`;L 落 `03-efi-layout.txt` 的分区段) |
| **W** L1 | 装 Windows -> 关快速启动与休眠 -> 已知文件夹重定向 -> 激活 -> 落 L1 产物 | [03-windows.md](03-windows.md) | `baseline/01-partitions.txt`、`baseline/01-activation.md` |
| **W** L2 闸门 | 只读体检 -> 读闸门结论(红项停)-> 基线备份 -> 落 L2 产物 | [03-windows.md](03-windows.md) | `baseline/02-preflight-report.md`、`baseline/02-esp-backup/`、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` |
| **L** L3 | UEFI 启动进 live -> 在 115GiB 预留区手工建 Fedora 三块分区(Anaconda 只指定挂载点,不动 Windows 的 ESP)-> 装完重启验证 -> 落 L3 产物 | `04-silverblue.md` | `baseline/03-efi-layout.txt` |
| **L / D** L4 | 首启收敛:共享盘挂载 / 家目录重定向 / 显卡驱动与 MOK(rebase 到 ublue NVIDIA 变体)/ 时间 / 蓝牙 / zram 与 swapfile / journald 与更新策略 / SSH 与 SMART / **部署回滚** / 发行版升级 / 回 Windows 入口 / 落 L4 产物 | [05-first-boot.md](05-first-boot.md) | `baseline/04-first-boot.md`、`baseline/04-robustness.md` |
| **D** 共存增量 4 步 | 115GiB 预留(在 `02-partitioning` 做)/ 引导不变量核查 / `ntfs3` 共享盘 / 退役与救援 | 落在 [02-partitioning.md](02-partitioning.md)、[03-windows.md](03-windows.md)、[05-first-boot.md](05-first-boot.md)、[07-rescue.md](07-rescue.md) | 见对应轨道的产物 |
| **D** L5 | 退役与救援:判层 / 从 grub 提示符回去 / Windows 侧修引导 / 只重装某一系统 / 基线回滚 / 周期巡检 / 应急纪律 / 退役五步 | [07-rescue.md](07-rescue.md) | [checklists/rollback.md](../checklists/rollback.md) |
| 验收 / 查询 | A-F 六组勾选(唯一判据);症状速查 + 分阶段风险(34 条风险总表在 [设计文档](design/00-design.md) 第 9 节) | [08-verification.md](08-verification.md)、[10-faq.md](10-faq.md) | 每台设备填写版落 `baseline/` |

- **共用卡 vs 专属卡**:固件、安装介质、目标盘核对、KMS 激活与"部署回滚演练"属共用或双轨复用;**双系统专属**只有 4 条 —— 115GiB 预留、引导不变量核查(`BootOrder` 首位 = Windows Boot Manager)、`ntfs3` 共享盘、退役与救援。
- 逐项勾选:L0-L4 用 [checklists/deploy.md](../checklists/deploy.md),L5 用 [checklists/rollback.md](../checklists/rollback.md)。交接规则:没有产物的阶段视为未完成,不得进入下一阶段;`baseline/` 不入库(含单机信息,每台设备一个子目录);L2 是唯一硬闸门(红项禁止进 L3);L1 与 L2 必须在同一次会话内连续完成;L4 任何驱动 / 分层 / 升级变更之前先确认"回 Windows 的入口"可用,并先 `rpm-ostree pin` 当前部署。
- 写作规范:旧的六段式体裁已作废、不再复述;卡格式(R1-R7)、文档级约定与引用写法见 [01-playbook-reshape-design.md](design/01-playbook-reshape-design.md) 第 3 节,依据只留指针;改完任一文档后运行 [check-docs.sh](../scripts/repo/check-docs.sh),期望 `check-docs: OK`(不传参数会对尚未写出的文档报 MISSING,属预期)。
