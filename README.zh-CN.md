# win-linux-dualboot

[English](README.md) | 简体中文

一套可复现、可安全撤除的 Windows 11 专业版 + Ubuntu 26.04 LTS 双系统部署手册,面向同规格的全新设备。

本仓库是**部署手册**,不是安装器。它提供 L0 到 L5 的分步手册、每个阶段必须留下的产物契约、4 个 Windows PowerShell 辅助脚本、10 个 Ubuntu 侧 shell 脚本与 2 个仓库自检脚本,以及把这一切钉死的分区表、验收清单与风险台账。目标是:把一台裸机、单块盘的设备装成可用的双系统,并且在需要时**完整删掉 Linux 而不弄坏 Windows 引导**。

材料分两层。设计文档([docs/design/00-design.md](docs/design/00-design.md))记录**为什么**这样设计:适用设备类、四条不变量、关键决策与被否方案、故障矩阵与风险台账;手册([docs/00-overview.md](docs/00-overview.md) 起)是可执行的那一层:阶段、步骤、期望输出、失败处理与回滚。

注意:**本仓库里的任何命令都还没有在目标机上实跑过**——动手之前请先看[当前状态](#当前状态)。

## 目录

- [背景](#背景)
- [怎么用](#怎么用)
- [仓库目录结构](#仓库目录结构)
- [四条不变量](#四条不变量)
- [适用设备类](#适用设备类)
- [目标分区表](#目标分区表)
- [两侧隔离与共享盘](#两侧隔离与共享盘)
- [崩溃后原地重装](#崩溃后原地重装)
- [Ubuntu 健壮性九项](#ubuntu-健壮性九项)
- [验收](#验收)
- [风险](#风险)
- [当前状态](#当前状态)
- [参与贡献](#参与贡献)
- [许可](#许可)

## 背景

多数双系统教程有两条典型死法:

1. **在已有生产力系统上"缩小分区"**。缩容失败、不可移动文件挡路、BitLocker 索要恢复密钥、安装器看不到 NVMe——这些事故几乎都出自这一步。
2. **启动顺序指向了 Linux**。等你哪天把 Linux 分区格式化掉,下次重启就停在 `grub>` / `grub rescue>`,Windows 也一起进不去。

本方案因此立两个前提:一是**整盘重装**(分区表一次定稿,而不是后期做手术);二是把"安全撤除 Linux"当作一等公民流程来设计与验收。两条死法的完整成因、被否方案与理由见 [docs/00-overview.md](docs/00-overview.md) 与设计文档第 1、3 节。

## 怎么用

从 [docs/00-overview.md](docs/00-overview.md) 开始读:四条不变量、设备参数表(字段名逐字固定,所有手册复用)、阶段到文档的映射都在那里。然后按阶段顺序推进,边做边勾 [checklists/deploy.md](checklists/deploy.md)。

| 阶段 | 手册 | 该阶段必须落盘的 `baseline/` 产物 |
|---|---|---|
| L0 装机前准备 | [docs/01-firmware.md](docs/01-firmware.md) | `00-firmware.md` |
| L1 Windows 全新安装 | [docs/02-windows.md](docs/02-windows.md) | `01-partitions.txt`、`01-activation.md` |
| L2 预检与基线(硬闸门) | [docs/03-preflight.md](docs/03-preflight.md) | `02-preflight-report.md`、`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt` |
| L3 Ubuntu 安装 | [docs/04-ubuntu.md](docs/04-ubuntu.md) | `03-efi-layout.txt` |
| L4 首启收敛 | [docs/05-first-boot.md](docs/05-first-boot.md) | `04-first-boot.md`、`04-robustness.md` |
| L5 退役与救援 | [docs/06-decommission.md](docs/06-decommission.md)、[docs/07-rescue.md](docs/07-rescue.md) | 勾选记录落在 [checklists/rollback.md](checklists/rollback.md) |

三条贯穿全程的规则:

- **没有产物的阶段视为未完成**,不得进入下一阶段;
- **L2 是唯一硬闸门**:报告末行结论为"结论: 禁止进入 L3"(存在红项)时,不得继续 Ubuntu 安装;
- **每个阶段都以可观测输出判定**,不以"看起来没问题"为准——每一步手册都写清了跑什么、什么算通过。

逐项勾选清单:[checklists/deploy.md](checklists/deploy.md)(L0 至 L4)与 [checklists/rollback.md](checklists/rollback.md)(L5:退役、引导救援、原地重装、基线回滚)。

脚本默认走安全方向:Ubuntu 侧脚本只打印计划,不加 `--apply`(且非 root)不改动系统;Windows 侧辅助脚本默认只读或空跑(`-WhatIf`),除非显式要求。具体选项见 `scripts/windows/` 与 `scripts/linux/` 各脚本头部注释,手册里也写明了每一步该用哪个脚本。

## 仓库目录结构

```
docs/                  执行手册,按执行顺序编号(00 至 10)
docs/design/           为什么这样设计(决策、风险、被否方案)
checklists/            deploy.md(L0-L4)与 rollback.md(L5)两份勾选清单
scripts/windows/       PowerShell 辅助:预检、ESP 备份、BootNext、基线巡检
scripts/linux/         Ubuntu 侧辅助:存储、加固、显卡、挂载、首启收敛
scripts/repo/          本仓库自检(文档结构、脚本语法)
templates/             diskpart 脚本与 fstab/GRUB/sysctl/配置文件片段
baseline/              每台设备的部署产物,永不入库(仅 README.md 入库)
```

## 四条不变量

每一步都服从这四条。真正防住引导锁死的是它们,而不是某个具体工具。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| I1 | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向已消失的 `\EFI\ubuntu\grubx64.efi`,重启停在 `grub rescue>` |
| I2 | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用调整 `BootOrder` 顺序的方式 | 留下一个没人记得撤销的永久启动顺序 |
| I3 | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的路径 | Windows 引导路径被第三方接管,系统更新后翻车 |
| I4 | 改分区表或固件设置之前,先有可用基线:BitLocker 挂起、ESP 已备份、固件启动项已快照 | 除重装外无路可退 |

这四条之所以管用,是因为"卡在 grub 命令行"的根因不是 GRUB 坏了,而是固件 NVRAM 里的条目仍指向已被删除的引导文件、且排在 Windows 前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目之后回落到 Windows(见 [docs/00-overview.md](docs/00-overview.md))。

## 适用设备类

需同时满足:

- 单块 NVMe SSD,**标称 1TB 级**(实际可用约 953GiB,即"近似但小于 1TB",不是 1TiB),UEFI + GPT;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化:Windows 与 Linux 都是全新安装,不存在"保留现有系统"的路径;
- 目标组合:Windows 11 专业版 + Ubuntu 26.04 LTS(GNOME 50,Wayland)。

偏离项要么给出适配分支(两块及以上磁盘、容量明显偏离 1TB、仅独显、非 GNOME 桌面、共享盘降级为只读),要么明确**不适用于 v1**:已有 ESP 小于 1GiB、BitLocker 已启用且无法挂起、VMD/RAID 模式锁定无法更改、需要磁盘加密、固件只从第一块盘引导的机型。吸收厂商差异的设备参数表(`DISK`、`VENDOR`、`BOOT_MENU_KEY`、`DISK_MODEL`、`DISK_SIZE` 等)定义在 [docs/00-overview.md](docs/00-overview.md),每台设备填一份。

## 目标分区表

标称 1TB 的 NVMe(实际可用约 953GiB):

| 序号 | 分区 | 大小 | 类型 | 用途 |
|---|---|---|---|---|
| 1 | ESP | 2GiB | EFI System(FAT32) | Windows 与 Ubuntu 共用;Linux 侧挂 `/boot/efi` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 `C:` | 200GiB | NTFS | 系统与程序;重装 Windows 时唯一被格式化的分区 |
| 4 | Windows 数据 `D:` | 约 635GiB | NTFS | 数据、游戏、容器镜像;双系统共享盘 |
| 5 | Ubuntu root | 100GiB | ext4 | `/`(内核在 root 内的 `/boot`,不额外分区) |
| 6 | Snapshot | 15GiB | ext4 | `/snapshots`,变更前快照 |
| 7 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计约 953GiB(2 + 0.016 + 200 + 635 + 100 + 15 + 1)。Linux 侧合计 115GiB(root 100 + 快照 15),共享数据盘约占全盘三分之二。不建 swap 分区,交换空间由首启阶段的 zram 与 swapfile 承担。ESP 尺寸不允许被削减:Windows 安装程序不会事后帮你建成 2GiB 的 ESP,所以分区表用 `diskpart` 预建([templates/partitions.txt](templates/partitions.txt)),这也是"允许整盘格式化"成为前提的原因。

## 两侧隔离与共享盘

方案在**两个系统上都把系统与数据分开**,所以任何一边崩都不会拖垮另一边:

- **Windows**:200GiB 系统分区(`C:`)+ 约 635GiB 数据分区(`D:`)。六个已知文件夹(桌面/文档/下载/图片/视频/音乐)、游戏库与容器镜像全部重定向到 `D:`,所以重装 Windows 只格式化 `C:`。分工是刻意的:`C:` 是可抛弃的那块,`D:` 是值得长期保护的那块。
- **Ubuntu**:100GiB root + 独立 15GiB 快照分区。文档、下载、图片与桌面放在共享盘上,这才让 root 保持 100GiB;升级翻车时回滚 root,不会连带毁掉快照历史。

`D:` 不是 Windows 私有卷,而是**共享分区**:Windows 侧原生访问,Ubuntu 侧以内核 `ntfs3` 驱动读写挂载——在 Windows 里编辑的办公文件,切到 Linux 直接打开,不需要拷贝或中转介质。四项前提让它安全,且都是前置条件而不是建议:

1. Windows 关闭 Fast Startup 与休眠,否则 NTFS 处于"混合关机"的脏状态,Linux 挂载会失败甚至损坏;
2. `D:` 不启用 BitLocker / 设备加密,否则 Linux 侧无法直接读写;
3. 挂载时固定 `uid`/`gid`/`umask` 并加 `windows_names`,因为 `ntfs3` 没有 POSIX 权限位(见 [templates/fstab.snippet](templates/fstab.snippet));
4. 不在共享盘上做依赖 POSIX 语义的工作:符号链接、硬链接、大小写敏感重命名、依赖权限位的脚本都留在 Linux 本地 root。

挂载由脚本完成([scripts/linux/mount-shared.sh](scripts/linux/mount-shared.sh)),Linux 侧家目录重定向同样脚本化([scripts/linux/xdg-redirect.sh](scripts/linux/xdg-redirect.sh))。验收包含**双向可见性测试**:Windows 写入标记文件 → Linux 读到,反向再做一次。

## 崩溃后原地重装

两个系统都能**在原盘上原地恢复**,这是设计目标而不是期望:

- **Windows 崩溃** → 只格式化 `C:` 重装 Windows;`D:`、Linux 各分区、ESP、MSR、WinRE 一律不动,`\EFI\Microsoft\` 由安装程序自己重建。
- **Ubuntu 崩溃** → 只格式化 root 分区重装 Ubuntu;ESP 复用且**不格式化**、`/snapshots` 挂上但不格式化,Windows 侧与快照历史都保住。
- **只是引导层损坏** → 不要重装:用 L2 基线还原 ESP + `bcdboot` 重建 + 清理 NVRAM 条目。

全流程最危险、因此在每个涉及处都写成第一号禁令的一步,是**误格 ESP**:它同时装着 `\EFI\Microsoft\`,一格式化就把两个系统一起弄挂。流程与判据见 [docs/07-rescue.md](docs/07-rescue.md) 与 [checklists/rollback.md](checklists/rollback.md) 第 4 节。

## Ubuntu 健壮性九项

失去一个可用系统的代价远高于重装,所以 Ubuntu 侧做了九项加固(设计文档第 4.7 节,R1 至 R9):

1. 内核/驱动/大版本升级之前先做快照,平时不自动创建;
2. 独立的 15GiB 快照分区挂 `/snapshots`,不与 root 争空间;
3. 保留旧内核 + `GRUB_DEFAULT=saved` 支持一次性启动,与固件层 `BootNext` 互补;
4. 常备救援 U 盘:安装 U 盘不回收,标记"已验证可用";
5. journald 持久化,崩溃或启动失败后仍可诊断;
6. zram + 已启用的 `systemd-oomd` 应对内存压力;
7. 常开 SSH 救援通道,桌面挂死时仍可从另一台机器排障;
8. 保守更新策略:只自动装安全更新、绝不自动重启,**内核与显卡驱动包特意排除**;
9. 磁盘健康监控(`smartmontools`/`smartd`)与 ext4 默认 `fsck` 策略。

每项对应的回滚点列在设计文档里;真正改系统的部分由 [scripts/linux/hardening.sh](scripts/linux/hardening.sh) 与 [scripts/linux/storage.sh](scripts/linux/storage.sh) 实现。

## 验收

是否完成,以 [docs/08-verification.md](docs/08-verification.md) 全绿为唯一判据,不以"装完了"为准。清单分六组:

- **A. 引导安全组(A1-A7)**:多次重启后 `BootOrder` 首位仍是 Windows Boot Manager、`\EFI\Microsoft\` 与 L2 基线一致、`{bootmgr}` 的路径未变、全程没写过永久启动顺序;并含一次**可逆的撤除演练**:临时删掉 `\EFI\ubuntu\`,确认机器仍能自动进 Windows 且不出现 `grub rescue>`,再用第 2 步另存的副本还原 `\EFI\ubuntu\`(L2 基线**不含**该子树)。
- **B. 系统功能组(B1-B10)**:Wayland 会话、显卡驱动正常且有 nouveau 兜底、Secure Boot 仍开启、`ntfs3` 读写挂载带 `nofail`、共享盘双向可见、家目录重定向生效、RTC 用 UTC、切换系统后蓝牙无需重配、`fwupd` 能识别设备。
- **C. 双系统切换组(C1-C4)**:一次性 `BootNext` 进 Linux 且不改默认项、一键回 Windows、切换三次后顺序仍稳定。
- **D. 可撤除性组(D1-D6)**:L5 五步退役完整推演、系统盘隔离逐项核对、两条原地重装路径各走一遍、非重装的引导修复路径已被证明可用。
- **E. 记录组(E1-E5)**:产物齐全且未入库、偏差回写到设备参数表。
- **F. 健壮性组(F1-F9)**:快照回滚真做一次、快照分区在 `df` 中可见、旧内核可启动、journald 持久化、更新策略与配置一致、SSH 可达、`systemd-oomd` 与 zram 生效、`smartd` 报告 PASSED、L4 写入的三条(共享盘、`/snapshots`、swapfile)带 `nofail`,而 `/boot/efi` 刻意不加。

未勾选项只有在落成"已知例外"并写明影响面时才可接受,否则该设备判为未完成。至少一台设备完整跑通,才能称为"参考实现"——目前还没有。

## 风险

已知故障类型连同缓解手段登记在 [docs/09-risks.md](docs/09-risks.md)(28 条):Intel VMD/RAID 控制器模式、改分区表或固件触发的 BitLocker 恢复提示、Windows 更新重写 ESP 与 SBAT/DBX 事件、Secure Boot 下 NVIDIA 模块签名、Fast Startup 与双写 NTFS、固件只认第一块盘、安装时选错目标盘、两系统间时间与蓝牙状态分裂、`ntfs3` 写入导致共享盘损坏、把硬件故障误判成双系统问题。

Windows 激活也作为一条风险登记:手册只写流程并外链上游项目,不随仓库分发任何激活脚本,仓库里也确实没有这类脚本。Windows ISO 的校验止于"官方下载域 + 官方安装器校验"——微软不发布 Windows 11 ISO 的 SHA256 值;只有 Ubuntu ISO 才按官方 `SHA256SUMS` 比对([docs/01-firmware.md](docs/01-firmware.md))。

## 当前状态

- **设计与手册:已完成。** 设计文档定稿,11 份手册([docs/00-overview.md](docs/00-overview.md) 至 [docs/10-faq.md](docs/10-faq.md))与两份勾选清单均已写出。
- **脚本:已交付,未实跑。** 16 个脚本都已入库,`bash scripts/repo/check-scripts.sh` 通过(它检查 200 行上限、`bash -n` 语法与 PowerShell 解析;本机未安装的检查器会显式报 `SKIP`)。但这些脚本没有在任何目标机上运行过,PowerShell 辅助脚本也没有在参考硬件上执行过。
- **尚无参考实现。** 没有任何设备完整走过 L0 至 L5,所以 `baseline/` 除自身的 README 之外是空的,验收清单也没有任何设备的填写版。请把这里的命令与判据当作"纸面复核过",而不是"现场验证过"。
- **单机产物永不入库。** `baseline/*` 被 `.gitignore` 排除,只保留 [baseline/README.md](baseline/README.md);它装的是分区表、ESP 镜像、固件启动项快照与激活状态,留在本地。

## 参与贡献

自检脚本就是契约:提交前跑 `bash scripts/repo/check-docs.sh` 与 `bash scripts/repo/check-scripts.sh`;每份手册保持六段式结构(目标 / 前置条件 / 步骤 / 验证 / 失败处理 / 回滚);每个脚本不超过 200 行;不得提交 `baseline/*` 产物、AI 过程文件与 emoji。改动若动到设计而不是某一步,先改 [docs/design/00-design.md](docs/design/00-design.md),再改手册。

## 许可

MIT,见 [LICENSE](LICENSE)。
