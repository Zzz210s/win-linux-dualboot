# 入口:三轨道地图、四条不变量与设备参数表

**本页是地图,不是流程**:它只回答"照着做之前必须知道什么"与"每一步去哪份文档、产出什么";动作级内容全部在手册的操作卡里,本页**不写操作卡**(不受卡格式约束,但仍受引用可解析、禁止跨文件锚点、相对链接存在性与 emoji 检查约束)。

本文件同时是整套手册的**命名契约**:四条不变量 I1-I4、设备参数表的字段名、各阶段产物名都在这里定义,手册与脚本引用这些名字时不得改名。

方案依据(目标、决策记录、事实清单、34 条风险)在 [设计文档](design/00-design.md);基础系统改用 Kubuntu 26.04 LTS 的决定、证据与影响面在 [04-kubuntu-variant-design.md](design/04-kubuntu-variant-design.md)(它**取代** Fedora 原子版设计,后者只留作历史),本页不复述。

**必须同时满足**(缺一项先按下方偏离表处置):

- 单块 NVMe SSD,标称 1TB 级(UEFI + GPT 引导);**容量口径**:1024GB 型号可用约 **953.7GiB**(方案分区表按此制定),1000GB 型号仅约 **931.3GiB**(此时把 `D:` 从 ≈635GiB 减到 ≈613GiB,其余七项不动 —— 详见设计 5.1 的容量偏离分支);混合显卡(集成显卡 + 独立显卡);允许整盘格式化(两个系统都是全新安装)。
- 目标系统:**Windows 11 专业版 + Kubuntu 26.04 LTS**(Plasma 6.6、**Wayland-only**、**Calamares 安装器**、LTS 支持窗口 3 年(到 2029-04)、内核 7.0;事实与来源等级见设计 04 第 1.1 节)。
- 覆盖范围:三轨道 **W**(只 Windows)/ **L**(只 Kubuntu)/ **D**(双系统)+ 共用底座;机器动作量约 9 / 10 / 19 步。

**偏离项处置**:

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP;四条不变量不变 |
| 容量明显偏离 1TB 级(512GiB / 2TiB) | 按比例调整 `C:` 与 Linux 侧容量;分区布局与四条不变量不变 |
| 双盘机型且固件只从第一块盘引导 | ESP **必须留在第一块盘**;Linux 分区可放第二块盘,但引导文件不能放第二块盘 |
| BitLocker 已启用 | 先挂起保护并备份 48 位恢复密钥,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 锁定、需要磁盘加密、需要快照式回滚 | VMD / RAID 锁定与磁盘加密**不适用于 v1**;快照式回滚已被用户否决,回退降级为**包级回退 + 原地重装**(设计 04 第 2 节 D4) |

---

## 四条不变量

整个方案的骨架。手册中任何步骤不得违反;违反即视为设计缺陷,而非操作失误。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| **I1** | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向失效的 `\EFI\ubuntu\shimx64.efi`,重启停在 `grub rescue>` |
| **I2** | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| **I3** | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| **I4** | 改分区表或固件设置之前,先完成基线备份(BitLocker 挂起 + ESP 镜像 + 固件启动项快照)——**首次装机时**,分区表在 L1 一次定稿、基线在 L2 生成;**此后的任何分区表或固件变更,都必须先有可用的基线备份** | 除重装外无路可退 |

**I1–I4 的落地方式(本次修订更新)**:Linux 侧条目(`\EFI\ubuntu\`)写在自己独立的 1GiB ESP 上(I3 由**结构**保证,不再只靠纪律),启动项名称的匹配串以实施时实测为准。另注:**I1 举例已随发行版更新为 `\EFI\ubuntu\`**(仅替换举例路径,不变量语义未变)。

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
| 5 | **ESP-Ubuntu** | **1GiB** | EFI System(FAT32) | Kubuntu 独立 ESP;只放 `\EFI\ubuntu\`;挂 `/boot/efi` |
| 6 | **`/boot`** | **1GiB** | ext4 | 独立分区:重装 root 时可选择保留内核与 GRUB 模块 |
| 7 | **Ubuntu root** | **≈113GiB** | ext4 | `/`(Ubuntu 默认文件系统;不用 btrfs,因为不需要快照) |
| 8 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈ 953GiB:2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1。Ubuntu 侧合计 **115GiB**(= 1 + 1 + 113),与参数表一致。

- **Ubuntu 侧三块分区在 L1 预留的 115GiB 未分配区内创建**:L1 的 `diskpart` 只分到 `D:` 为止,余量**不分配**;L3 的 Calamares 在这个区间里切出上述三块(ESP-Ubuntu 1GiB + `/boot` 1GiB + root ≈113GiB)。共享数据盘 `D:` ≈635GiB NTFS(约占全盘三分之二,两个系统都能读写);无 swap 分区,交换空间由 zram 与 swapfile 在 L4 配置;ESP 尺寸不允许被削减,若 Windows 安装程序自行占用预留空间则记录偏差并据实调整。

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
| `UBUNTU_ESP_SIZE` | 目标 ESP-Ubuntu 大小 | 1GiB |
| `BOOT_SIZE` | 目标 `/boot` 大小 | 1GiB(ext4,独立于 ESP) |
| `ROOT_SIZE` | 目标 Ubuntu root 大小 | ≈113GiB(ext4) |
| `WINDOWS_SYSTEM_SIZE` | 目标 Windows 系统分区大小 | 200GiB |
| `WINDOWS_DATA_SIZE` | 目标 Windows 数据分区大小 | ≈635GiB |
| `SECURE_BOOT` | Secure Boot 目标状态 | 开启 |
| `DISK_MODEL` | 目标磁盘型号(安装前核对,**防装错盘**) | Samsung MZVLQ1T0HBLB |
| `DISK_SIZE` | 目标磁盘容量 | 标称 1TB / 约 953GiB |
| `SHARED_PART_UUID` | 共享数据分区(D:)的 UUID | 安装后由 `blkid` 获取 |

- Linux 侧参数由更早方案的"`ROOT_SIZE` 100GiB + `SNAPSHOT_SIZE` 15GiB"改为"`UBUNTU_ESP_SIZE` 1GiB + `BOOT_SIZE` 1GiB + `ROOT_SIZE` ≈113GiB"(`SNAPSHOT_SIZE` 不再存在);`UBUNTU_ESP_SIZE` 与 `BOOT_SIZE` 必须与 Windows 的 ESP 分开,尺寸不允许被安装器削减。
- `*_SIZE` 各字段是"目标值",写入 L1 的 `diskpart` 脚本,实际分区表以 L1 产物为准并记录偏差;`SHARED_PART_UUID` 是唯一一个安装后才能确定的字段,回填后必须与 [templates/fstab.snippet](../templates/fstab.snippet) 里的值一致。

---

## Kubuntu 硬语义与四项否决

- **传统可变系统**:系统本体就是普通 apt/dpkg 包,`sudo apt install` 装完**立即生效**,没有"分层安装需重启"这回事;大版本升级走 `do-release-upgrade`(设计 04 第 2 节 D2)。
- **Wayland-only**:Kubuntu 26.04 只提供 Wayland 会话,`XDG_SESSION_TYPE` 必须是 `wayland`;`nomodeset` 会关掉 KMS,与默认会话冲突(设计 4.5、11.1)。
- **Secure Boot 全程开启**:显卡走 Ubuntu 官方**预签名** nvidia 包(`ubuntu-drivers` 安装),不需要自签密钥、不需要向固件注册密钥(设计 04 第 2 节 D3)。
- **snap 零残留**(用户约束):最小安装 + 清除残留 + apt pin 压制三条**成套执行**,浏览器改用 Mozilla 官方 APT 仓库的 deb;判据是 `snap list` 为空 + `dpkg -l snapd` 无输出 + 浏览器来源非 snap(设计 04 第 3 节)。

口径补充:GUI 应用优先 deb / Flatpak,软件商店用 Plasma 自带的 `plasma-discover`,固件更新用 `fwupd`。**回退粒度四级已降级** —— 单包回退(`apt install <包>=<版本>` + `apt-mark hold`)-> 配置回退(`.dbk.bak` 备份)-> 基线级(ESP 与 NVRAM)-> 阶段级(退役);**没有"一条命令回到上一个可用系统"的能力**,系统级损坏走原地重装两法(设计 04 第 7 节)。

**明确被否四项**:不使用 **`snapd`**(用户约束,设计 04 第 3 节);不使用 **`snapper` / `timeshift` / `grub-btrfs` / btrfs 快照**(设计 04 第 2 节 D4);不使用 **ZFS root 快照**(设计 04 第 2.1 节);不使用**自定义 Secure Boot 密钥与自签驱动**(D3)。

---

## 三轨道地图

| 轨道 | 步骤(做什么) | 去哪份文档 | 产出什么 |
|---|---|---|---|
| **共用底座**(三条轨道都要) | 固件设置 -> 做两个安装介质(Windows 11 ISO + Kubuntu 26.04 ISO)-> 核对目标盘 -> 落 L0 产物 | [01-firmware.md](01-firmware.md) | `baseline/00-firmware.md`(含 `BootOrder` 首位原值) |
| **共用底座之二** | 分盘:认下本机轨道的目标布局 -> 按轨道分盘(整盘重排、一次分好,禁止事后缩容) | [02-partitioning.md](02-partitioning.md) | 分区记录进 `baseline/`(W/D 落 `01-partitions.txt`;L 落 `03-efi-layout.txt` 的分区段) |
| **W** L1 | 装 Windows -> 关快速启动与休眠 -> 已知文件夹重定向 -> 激活 -> 落 L1 产物 | [03-windows.md](03-windows.md) | `baseline/01-partitions.txt`、`baseline/01-activation.md` |
| **W** L2 闸门 | 只读体检 -> 读闸门结论(红项停)-> 基线备份 -> 落 L2 产物 | [03-windows.md](03-windows.md) | `baseline/02-preflight-report.md`、`baseline/02-esp-backup/`、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` |
| **L** L3 | UEFI 启动进 live -> 在 115GiB 预留区手工建 Ubuntu 三块分区(Calamares 只指定挂载点,不动 Windows 的 ESP)-> 装完重启验证 -> 落 L3 产物 | [04-kubuntu.md](04-kubuntu.md) | `baseline/03-efi-layout.txt` |
| **L / D** L4 | 首启收敛:共享盘挂载 / 家目录重定向 / 显卡驱动与 Secure Boot(Ubuntu 官方预签名包)/ 时间 / 蓝牙 / zram 与 swapfile / journald 与更新策略 / SSH 与 SMART / **包级回退与变更前备份** / 发行版升级 / **snap 零残留** / 回 Windows 入口 / 落 L4 产物 | [05-first-boot.md](05-first-boot.md) | `baseline/04-first-boot.md`、`baseline/04-robustness.md` |
| **D** 共存增量 4 步 | 115GiB 预留(在 `02-partitioning` 做)/ 引导不变量核查 / `ntfs3` 共享盘 / 退役与救援 | 落在 [02-partitioning.md](02-partitioning.md)、[03-windows.md](03-windows.md)、[05-first-boot.md](05-first-boot.md)、[07-rescue.md](07-rescue.md) | 见对应轨道的产物 |
| **D** L5 | 退役与救援:判层 / 从 grub 提示符回去 / Windows 侧修引导 / 只重装某一系统 / 基线回滚 / 周期巡检 / 应急纪律 / 退役五步 | [07-rescue.md](07-rescue.md) | [checklists/rollback.md](../checklists/rollback.md) |
| 验收 / 查询 | A-F 六组勾选(唯一判据);症状速查 + 分阶段风险(34 条风险总表在 [设计文档](design/00-design.md) 第 9 节) | [08-verification.md](08-verification.md)、[10-faq.md](10-faq.md) | 每台设备填写版落 `baseline/` |

- **共用卡 vs 专属卡**:固件、安装介质、目标盘核对、KMS 激活与"包级回退演练"属共用或双轨复用;**双系统专属**只有 4 条 —— 115GiB 预留、引导不变量核查(`BootOrder` 首位 = Windows Boot Manager)、`ntfs3` 共享盘、退役与救援。
- 逐项勾选:L0-L4 用 [checklists/deploy.md](../checklists/deploy.md),L5 用 [checklists/rollback.md](../checklists/rollback.md)。交接规则:没有产物的阶段视为未完成,不得进入下一阶段;`baseline/` 不入库(含单机信息,每台设备一个子目录);L2 是唯一硬闸门(红项禁止进 L3);L1 与 L2 必须在同一次会话内连续完成;L4 任何驱动 / 包 / 升级变更之前先确认"回 Windows 的入口"可用,并按 `05-9` 记下要回退的包与版本。
- 写作规范:旧的六段式体裁已作废、不再复述;卡格式(R1-R7)、文档级约定与引用写法见 [01-playbook-reshape-design.md](design/01-playbook-reshape-design.md) 第 3 节,依据只留指针;改完任一文档后运行 [check-docs.sh](../scripts/repo/check-docs.sh),期望 `check-docs: OK`(不传参数会对尚未写出的文档报 MISSING,属预期)。
