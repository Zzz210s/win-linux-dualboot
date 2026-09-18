# 入口:目标、四条不变量与设备参数表

本文件是整套手册的入口与**命名契约**:四条不变量 I1-I4、设备参数表的字段名、阶段到文档的映射都在这里定义,`01-*` 至 `09-*` 全部引用本文档定义的名字。改名必须同时改这里。

为什么这样设计(目标、决策记录、事实清单)在 [设计文档](design/00-design.md)。本文件只回答"照着做之前必须知道什么"。

- 适用:单块 NVMe、UEFI + GPT、混合显卡、允许整盘格式化的设备。
- 目标系统:Windows 11 专业版 + Ubuntu 26.04 LTS(GNOME 50,默认 Wayland 会话)。
- 状态:设计已定稿,手册按执行顺序编号,01-09 逐份补齐。

---

## 这套方案解决什么问题

网上多数双系统教程有两条典型死法,本方案就是为绕开它们而设计的:

1. **在生产系统上"缩小分区"**。缩容失败、不可移动文件挡路、BitLocker 索要恢复密钥、安装器看不到 NVMe——这些事故几乎都出自"在已有系统上做分区手术"这一步。
2. **启动顺序指向了 Linux**。装完之后固件 NVRAM 里 Linux 的条目排到了前面。等你哪天格式化掉 Linux 分区,下一次重启就停在 `grub>` / `grub rescue>`,Windows 也一起进不去。

由此立两个前提:

- **整盘重装**:所有分区在安装 Windows 之前一次分好(见 L1),不做后期缩容。分区表只规划一次,容量规划因此可预测。
- **可撤除**:把"安全删掉 Linux 且不影响 Windows"当作一等公民流程来设计与验收,而不是事后补救。真正保证这一点的不是某个工具,而是下面四条不变量。

两条死法的完整成因分析、被否方案与理由见 [设计文档](design/00-design.md) 第 1 节与第 3 节。

---

## 四条不变量

这是整个方案的骨架。手册中的任何步骤都不得违反;违反视为设计缺陷,而不是操作失误。遇到"某步骤似乎与不变量冲突"时,先改设计文档,再改手册。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| **I1** | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向失效的 `\EFI\ubuntu\grubx64.efi`,重启停在 `grub rescue>` |
| **I2** | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| **I3** | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| **I4** | 改分区表或固件设置之前,先完成基线备份(BitLocker 挂起 + ESP 镜像 + 固件启动项快照)——**首次装机时**,分区表在 L1 一次定稿、基线在 L2 生成;**此后的任何分区表或固件变更,都必须先有可用的基线备份** | 除重装外无路可退 |

上表表述与 [设计文档](design/00-design.md) 第 2 节一致。

**为什么是这四条**:卡在 `grub` 命令行的根因不是 GRUB 坏了,而是固件 NVRAM 里的启动条目仍指向已被删除的引导文件,并且它排在启动顺序前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目之后继续回落到 Windows。这比"记得先修引导再删分区"可靠——后者依赖人的记忆。

**怎么在机器上证明每条不变量成立**(检查点,详细命令在 L1-L3 各文档中):

| 不变量 | 检查动作 | 通过判据 |
|---|---|---|
| I1 | 读固件启动顺序 | 第一位是 Windows Boot Manager(不是 ubuntu) |
| I2 | 安装 Ubuntu 期间与之后复查启动顺序 | 没有任何步骤写过 `efibootmgr -o`;进 Linux 走一次性 `BootNext` 或厂商菜单键 |
| I3 | 对比 ESP 上 `\EFI\Microsoft\` 与基线镜像 | 目录树与文件哈希与基线一致;`{bootmgr}` 的 `path` 未被改写 |
| I4 | **进入 L3 前的 L2 闸门检查** | `baseline/02-preflight-report.md` 结论为"允许进入 L3"(无红项),且四项齐备:ESP 备份 `baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、分区记录(`baseline/01-partitions.txt` 与 `baseline/02-partitions.txt`)、BitLocker 挂起记录(报告里的保护状态行) |

---

## 适用设备类

**必须同时满足**(缺一项就不是本方案的目标设备,先按下面的偏离表处置):

- 单块 NVMe SSD,标称 1TB 级(实际可用约 953GiB,即"近似但小于 1TB",不是 1TiB);
- UEFI + GPT 引导;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化(Windows 与 Linux 都是全新安装,不存在"保留现有系统"的路径);
- 目标组合:Windows 11 专业版 + Ubuntu 26.04 LTS。

**偏离项处置**:

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP;四条不变量不变 |
| 磁盘容量明显偏离 1TB 级(如 512GiB / 2TiB) | 按比例调整 C: 与 Linux 侧容量;分区布局与四条不变量不变 |
| 已有 ESP 小于 1GiB 且不愿重装 | **不适用**:本方案依赖重装时可直接定尺寸的 ESP |
| BitLocker 已启用 | 先执行挂起与恢复密钥备份,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 模式已锁定且无法改为 AHCI/NVMe | **不适用**(Linux 侧看不到磁盘) |
| 仅独显(无集显) | 走"NVIDIA 单显卡分支":不配置 PRIME offload,显示输出直接由独显承担 |
| 无法接受 Linux 写入 NTFS | 把共享挂载降级为只读,或改用独立共享分区(变体) |
| 桌面非 GNOME 50(如 Kubuntu) | 走"桌面替换分支";注意 Kubuntu LTS 支持期为 3 年而非 5 年 |
| 需要磁盘加密 | **不适用于 v1**(见本文档末节的非目标;LUKS 变体在设计文档第 10 节) |
| 双盘机型且固件只从第一块盘引导(部分厂商) | ESP **必须留在第一块盘**;Linux 分区可放第二块盘,但引导文件不能放第二块盘 |

偏离表对应的厂商差异(vendor 差异)在实际执行时落到下面的 `VENDOR` 与 `BOOT_MENU_KEY` 两项参数上。

---

## 设备参数表

**每台设备部署前填写一份**,与 `baseline/` 的子目录一一对应。手册与模板脚本里的 `DISK`、`ESP_SIZE` 这类写法全部指本表的字段;字段名逐字固定,不得改名、不得新增同义字段。

| 参数 | 含义 | 填写说明 | 示例 |
|---|---|---|---|
| `DISK` | Linux 侧设备名 | 在 Ubuntu 安装器的"手动分区"界面确认;与 `DISK_MODEL` 交叉核对 | `/dev/nvme0n1` |
| `VENDOR` | 固件厂商 | 决定 `BOOT_MENU_KEY` 与固件界面术语 | Dell / HP / Lenovo / ASUS |
| `BOOT_MENU_KEY` | 厂商启动菜单键 | 开机时按键进入一次性启动菜单(替代改 `BootOrder`) | Dell F12、HP F9、Lenovo F12/F10、通用 ESC |
| `FIRMWARE_MODE` | 存储控制器模式 | 目标值为 AHCI / NVMe,且 VMD 关闭;必须在装 Windows 之前设定 | AHCI / NVMe(VMD 关闭) |
| `GPU` | 显卡组合 | 决定 L4 是否配置 PRIME offload | Intel + NVIDIA(混合) |
| `ESP_SIZE` | 目标 ESP 大小 | 共用 ESP,Windows 与 Ubuntu 各占一部分 | 2GiB |
| `WINDOWS_SYSTEM_SIZE` | 目标 Windows 系统分区大小 | 只放系统与程序;原地重装时唯一被格式化的分区 | 200GiB |
| `WINDOWS_DATA_SIZE` | 目标 Windows 数据分区大小 | 同时是双系统共享盘;容量 = 全盘减去其余六项 | ≈635GiB |
| `ROOT_SIZE` | 目标 root 大小 | Ubuntu 的 `/`;内核在 root 内的 `/boot`,不额外分区 | 100GiB |
| `SNAPSHOT_SIZE` | 目标快照分区大小 | 挂 `/snapshots`,存放变更前快照 | 15GiB |
| `SECURE_BOOT` | Secure Boot 目标状态 | 全程保持开启,不关闭、不换密钥 | 开启 |
| `DISK_MODEL` | 目标磁盘型号(安装前核对,**防装错盘**) | 与整盘格式化前的分区表输出核对 | Samsung MZVLQ1T0HBLB |
| `DISK_SIZE` | 目标磁盘容量 | 用于验证"容量偏离"是否需要走偏离分支 | 标称 1TB / 约 953GiB |
| `SHARED_PART_UUID` | 共享数据分区(D:)的 UUID | L1 只记录 `D:` 的卷标与分区位置(不含 UUID);UUID 在 L3/L4 由 `blkid` 取得后回填本表,并写入 [templates/fstab.snippet](../templates/fstab.snippet) | 例如 `blkid` 输出的 UUID 值 |

说明:

- `ESP_SIZE` / `WINDOWS_SYSTEM_SIZE` / `ROOT_SIZE` / `SNAPSHOT_SIZE` 是"目标值",写入 L1 的 `diskpart` 脚本;实际分区表以 L1 产物为准并记录偏差。
- `SHARED_PART_UUID` 是唯一一个安装后才能确定的字段;它在 L4 挂载共享分区时使用,必须在 L3/L4 回填本表后与 `fstab` 里的值一致。
- 参数表任何一格都不允许写序列号、机器名、用户名;多设备适配靠本表,不靠文档分支。

---

## 阶段与文档映射

| 阶段 | 名称 | 手册文档 | 该阶段结束时该有的产物 |
|---|---|---|---|
| 入口 | 目标与契约 | 本文件 | 无(读,不执行) |
| **L0** | 装机前准备 | [01-firmware.md](01-firmware.md) | `baseline/00-firmware.md` |
| **L1** | Windows 全新安装 | [02-windows.md](02-windows.md) | `baseline/01-partitions.txt`、`01-activation.md`(分区表与激活状态) |
| **L2** | 预检与基线(硬闸门) | [03-preflight.md](03-preflight.md) | `baseline/02-preflight-report.md`、`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt` |
| **L3** | Ubuntu 安装 | [04-ubuntu.md](04-ubuntu.md) | `baseline/03-efi-layout.txt` |
| **L4** | 首启收敛 | [05-first-boot.md](05-first-boot.md) | `baseline/04-first-boot.md`、`04-robustness.md`(首启收敛与健壮性核对) |
| **L5** | 退役与救援 | [06-decommission.md](06-decommission.md) + [07-rescue.md](07-rescue.md) | [checklists/rollback.md](../checklists/rollback.md) |
| 验收 | 唯一判据 | [08-verification.md](08-verification.md) | 验收清单(A-F 组)全绿 |
| 风险 | 风险登记表 | [09-risks.md](09-risks.md) | 无(查,不执行) |
| 附录 | 高频疑问速查 | [10-faq.md](10-faq.md) | 无(查,不执行) |

注:产物名前缀 = 所在阶段号。L1 定稿分区表(`baseline/01-partitions.txt`)并记录激活状态(`baseline/01-activation.md`);ESP 文件树备份(`baseline/02-esp-backup/`,含 `manifest.sha256`)与固件启动项快照(`baseline/02-firmware-entries.txt`)是 **L2 生成的基线产物**(设计文档 4.3),L2 另产出分区快照 `baseline/02-partitions.txt`;四项是否齐备统一由 `baseline/02-preflight-report.md` 判定。

**从哪一节开始读**:

1. 第一次在本设备上部署:先读完本文件,然后严格按 L0 → L1 → L2 → L3 → L4 顺序推进,每阶段完成后再进入下一阶段。
2. 只想确认"能不能用这套方案":读本文件的"适用设备类"与"目标分区表",再读 [设计文档](design/00-design.md) 第 1、3 节。
3. 正在装、卡在某一步:回到对应阶段的文档;L2 报红项时不要跳过,先解决再进 L3。
4. 机器出问题了:先 [07-rescue.md](07-rescue.md)(判断是引导层还是系统盘),**不要直接重装**。
5. 想删掉 Linux:直接 [06-decommission.md](06-decommission.md),并先读本文档的"阶段产物与交接规则"与四条不变量。
6. 只想查一件事:先 [10-faq.md](10-faq.md);风险与已知事故看 [09-risks.md](09-risks.md)。
7. 想改设计:先 [设计文档](design/00-design.md),再回来改手册与参数名。

---

## 目标分区表

标称 1TB 的 NVMe,实际可用约 953GiB。下表为安装器 / 磁盘管理的 GUI 显示值,`diskpart` 脚本按同一组目标值编写。

| 序号 | 分区 | 大小 | 类型 | 挂载 / 用途 |
|---|---|---|---|---|
| 1 | ESP | **2GiB** | EFI System(FAT32) | Windows 与 Ubuntu 共用;Ubuntu 侧挂 `/boot/efi` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 C: | **200GiB** | NTFS | 系统与程序;**原地重装时唯一被格式化的分区** |
| 4 | Windows 数据 D: | **≈635GiB** | NTFS | 游戏库、下载、文档、容器镜像;已知文件夹重定向的目标;双系统共享分区 |
| 5 | Ubuntu root | **100GiB** | ext4 | `/`(内核位于 root 内的 `/boot`,不额外分区) |
| 6 | Snapshot | **15GiB** | ext4 | `/snapshots`,变更前快照的存放位置 |
| 7 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈953GiB(2 + 0.016 + 200 + 635 + 100 + 15 + 1)。其中:

- Linux 侧合计 115GiB(= root 100 + Snapshot 15);
- 共享数据盘 `D:` ≈635GiB,约占全盘(约 953GiB)三分之二;
- 无 swap 分区,交换空间由 zram 与 swapfile 在 L4 配置;
- ESP 尺寸不允许被削减;若 Windows 安装程序自行新建恢复分区并占用预留空间,记录偏差并据实调整。

为什么把 Windows 也拆成系统盘与数据盘,见 [设计文档](design/00-design.md) 第 5.1.1 节。

---

## 阶段产物与交接规则

1. **没有产物的阶段视为未完成**,不得进入下一阶段。
2. **`baseline/` 不入库**(含单机信息:分区表、ESP 镜像、固件启动项、激活状态);仓库内只保留结构与命名规范,每台设备一个子目录。
3. **L2 是唯一硬闸门**:存在红项则禁止进入 L3;存在黄项则记录后带风险继续。
4. **L1 与 L2 必须在同一次会话内连续完成**:中途若 Windows 发生更新,基线即失效,须重做。
5. **L3 期间不改动 `BootOrder`**(I2 的落地方式)。
6. **L4 任何驱动变更之前**,先确认"回 Windows 的入口"可用。

---

## 文档写作规范

`01-*` 至 `09-*` 各文档统一遵守下列约定:

1. **六段式章节**:每份手册依次包含 `## 目标`、`## 前置条件`、`## 步骤`、`## 验证`、`## 失败处理`、`## 回滚`。本文件不受此约束;[10-faq.md](10-faq.md) 为附录,已按同构的六段标题书写,`check-docs.sh` 仍在白名单里排除它(只跳过六段式校验,链接与 emoji 检查照常执行)。
2. **步骤级粒度**:每步写清"做什么 + 关键命令 + 怎么知道成功了";不追求逐条可复制的命令级,也不写只有结论的说明级。
3. **禁用 emoji**:文档、脚本、提交信息一律不用 emoji;需要视觉区分时用文字符号。
4. **步骤编号从 1 开始**:每份文档内的步骤独立编号,不跨文档连续编号。
5. **每条命令必须给出"期望输出"或"验证方式"**;无法给出可观测判据的步骤,应改为检查点或删除。
6. **自检**:改完任一文档后运行 [check-docs.sh](../scripts/repo/check-docs.sh)(`bash scripts/repo/check-docs.sh docs/<文件>.md`),期望输出 `check-docs: OK`。不传参数运行时会对尚未写出的文档报 `MISSING`,属预期。

---

## 不做什么(v1 非目标)

以下能力明确不在 v1 范围内,遇到相关需求应说明"不适用"并给出替代路径,不要现场扩展方案:

- 用户数据与浏览器凭据迁移;
- 磁盘加密与 TPM-FDE;
- 休眠;
- btrfs 快照回滚;
- 自定义 Secure Boot 密钥;
- 图形化安装器;
- 多发行版模板(本方案只针对 Ubuntu 26.04 LTS)。

砍掉这些不是省事:它们的失败模式(凭据泄露、TPM 与引导链测量冲突、休眠与 NVIDIA + Wayland 冲突、自签密钥触发 BitLocker 恢复)会把方案从"可复现"拖成"每次都得现场救火"。依据见 [设计文档](design/00-design.md) 第 1.3 节。

**注意**:"两个系统都能访问的共享数据分区"(即 `D:`)不属于非目标,它是 v1 的正式组成部分。

---

## 已知事故类型(先看这一条再动手)

**2024-08 SBAT / Secure Boot DBX 更新导致 Linux 无法引导**:微软通过 Windows 更新推送的 Secure Boot DBX 更新,会把若干 Linux 引导器的 SBAT 版本判为"过旧",在部分双系统设备上更新后无法引导进 Linux(微软已确认该问题存在)。装完 Windows 后第一次正常联网更新就可能触发,所以动手前先知道处置方式。

缓解手段两条:

1. **清理 SBAT 策略**:在 Windows 侧清除固件下发的 SBAT 策略(注册表中 `SbatLevel` 相关值),重启后固件不再因 SBAT 版本过旧而拒绝 Linux 引导器;随后按 [07-rescue.md](07-rescue.md) 复原引导。
2. **常备安装 U 盘**:Ubuntu 安装 U 盘在装机结束后不回收,保持"已验证可用"状态;引导被拒时从 U 盘进入 live 环境修复,而不是原地重装。

其余事故类型(Windows 更新重写 ESP、BitLocker 恢复提示、Secure Boot 下 NVIDIA 模块签名、两系统间时间与蓝牙状态分裂等)与完整缓解手段登记在 [09-risks.md](09-risks.md)。
