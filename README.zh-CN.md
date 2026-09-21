# win-linux-dualboot

[English](README.md) | 简体中文

一套可复现、可安全撤除的 Windows 11 专业版 + Fedora 44 Silverblue 双系统部署手册,面向同规格的全新设备。

本仓库是**部署手册**,不是安装器。它提供三轨道、L0 到 L5 的分步手册,每个阶段必须留下的产物契约,每张卡一个脚本(Windows 侧 PowerShell 与 Silverblue 侧 shell)及其共享契约库,以及把这一切钉死的分区表、验收清单与风险台账。每张卡都点明判定它的脚本,且脚本默认走安全方向:`--check` / `-Check` 只打印结论、零写,只有显式 `--apply` / `-Apply`(通常还需 `--yes` / `-Yes`)才改动系统。

材料分两层。设计文档([docs/design/00-design.md](docs/design/00-design.md) 及其变体设计 / 卡格式设计 / 步骤自动化设计三份同伴)记录**为什么**这样设计:适用设备类、四条不变量、关键决策与被否方案、故障矩阵与 34 条风险总表;手册([docs/00-overview.md](docs/00-overview.md) 起)是可执行的那一层:每张卡给出「做」与「看到」判据,以及「出错时」的指针。

注意:**本仓库里的任何命令都还没有在真机上跑过**——所有脚本只到夹具级验证。动手之前请先看[当前状态](#当前状态)。

## 目录

- [背景](#背景)
- [怎么用](#怎么用)
- [三轨道结构](#三轨道结构)
- [仓库目录结构](#仓库目录结构)
- [四条不变量](#四条不变量)
- [适用设备类](#适用设备类)
- [目标分区表](#目标分区表)
- [原子版语义与回滚](#原子版语义与回滚)
- [两侧隔离与共享盘](#两侧隔离与共享盘)
- [崩溃后原地重装](#崩溃后原地重装)
- [健壮性九项](#健壮性九项)
- [验收](#验收)
- [风险](#风险)
- [当前状态](#当前状态)
- [参与贡献](#参与贡献)
- [许可](#许可)

## 背景

多数双系统教程有两条典型死法:

1. **在已有生产力系统上"缩小分区"**。缩容失败、不可移动文件挡路、BitLocker 索要恢复密钥、安装器看不到 NVMe——这些事故几乎都出自这一步。
2. **启动顺序指向了 Linux**。等你哪天把 Linux 分区格式化掉,下次重启就停在 `grub>` / `grub rescue>`,Windows 也一起进不去。

本方案因此立两个前提:一是**整盘重装**(分区表一次定稿,而不是后期做手术);二是把"安全撤除 Linux"当作一等公民流程来设计与验收。Linux 侧是原子版系统,所以同一个前提还有第二重回报:回滚变成"换一个部署"而不是维护一套文件系统快照体系,升级翻车也不必就地抢救。两条死法的完整成因、被否方案与理由见 [docs/00-overview.md](docs/00-overview.md) 与设计文档第 1、3、4 节。

## 怎么用

从 [docs/00-overview.md](docs/00-overview.md) 开始读:轨道划分、四条不变量、设备参数表(字段名逐字固定,所有手册复用)、阶段到文档的映射都在那里。然后按本机轨道推进,边做边勾 [checklists/deploy.md](checklists/deploy.md)(L0 至 L4)与 [checklists/rollback.md](checklists/rollback.md)(L5)。

| 轨道 / 阶段 | 手册 | 该阶段必须落盘的 `baseline/` 产物 |
|---|---|---|
| 共用底座 L0 装机前 | [docs/01-firmware.md](docs/01-firmware.md) | `00-firmware.md` |
| 共用底座 分盘 | [docs/02-partitioning.md](docs/02-partitioning.md) | 分区记录(W/D 落 `01-partitions.txt`;L 落 `03-efi-layout.txt` 的分区段) |
| W L1 Windows 安装 | [docs/03-windows.md](docs/03-windows.md) | `01-partitions.txt`、`01-activation.md` |
| W L2 预检与基线(硬闸门) | [docs/03-windows.md](docs/03-windows.md) | `02-preflight-report.md`、`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt` |
| L L3 Silverblue 安装 | [docs/04-silverblue.md](docs/04-silverblue.md) | `03-efi-layout.txt` |
| L / D L4 首启收敛 | [docs/05-first-boot.md](docs/05-first-boot.md) | `04-first-boot.md`、`04-robustness.md` |
| D L5 退役与救援 | [docs/07-rescue.md](docs/07-rescue.md) | 勾选记录落在 [checklists/rollback.md](checklists/rollback.md) |

三条贯穿全程的规则:

- **没有产物的阶段视为未完成**,不得进入下一阶段;
- **L2 是唯一硬闸门**:报告末行结论为"结论: 禁止进入 L3"(存在红项)时,不得继续 Linux 安装;
- **每个阶段都以可观测输出判定**,不以"看起来没问题"为准——每张卡都写清了跑什么、什么算通过(「看到:」行)。

每张卡还点明它对应的脚本,且"卡 ↔ 脚本"是双向机器校验的(`scripts/repo/check-docs.sh` 的 C9b/C9c/C9d 对着 `scripts/*/steps.tsv` 比)。脚本默认只读:Silverblue 侧任何写动作还要求 root 与 `--yes`。

## 三轨道结构

方案由三条**可独立执行**的轨道组成,共用一个底座,所以**任一系统都可以单独安装**:

| 轨道 | 场景 | 机器动作量 | 内容 |
|---|---|---|---|
| 共用底座 | 三条轨道都要 | 约 3 步 | 固件设置、做两个安装介质、核对目标盘 |
| **W** | 只装 Windows | 约 5 步 | 分区、安装、激活、关快速启动与休眠、收敛 |
| **L** | 只装 Silverblue | 约 6 步 | 安装、首启(驱动/挂载/时间/分层)、收敛、回滚演练 |
| **D** | 双系统 | 共用底座 + W + L + 共存增量 4 步 | 预留 115GiB、引导不变量核查、`ntfs3` 共享盘、退役与救援 |

双系统专属只有 4 项增量:115GiB 预留、引导不变量核查(`BootOrder` 首位始终是 Windows Boot Manager)、`ntfs3` 共享盘、L5 退役流程;其余部分与单系统安装共用或完全一致。

## 仓库目录结构

```
docs/                  执行手册,按执行顺序编号(00 至 10)
docs/design/           为什么这样设计(决策、风险、被否方案)
checklists/            deploy.md(L0-L4,三轨道)与 rollback.md(L5)两份勾选清单
scripts/windows/       每卡一个 PowerShell 脚本 + 共享契约库
scripts/linux/         Silverblue 侧每卡一个脚本 + 共享契约库
scripts/repo/          本仓库自检(文档结构、脚本语法)
templates/             diskpart 脚本与 fstab/GRUB/rpm-ostreed/journald/user-dirs 片段
baseline/              每台设备的部署产物,永不入库(仅 README.md 入库)
```

## 四条不变量

每一步都服从这四条。真正防住引导锁死的是它们,而不是某个具体工具。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| I1 | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向已消失的 `\EFI\fedora\grubx64.efi`,重启停在 `grub rescue>` |
| I2 | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| I3 | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| I4 | 改分区表或固件设置之前,先有可用基线:BitLocker 挂起、ESP 已备份、固件启动项已快照 | 除重装外无路可退 |

I3 在本方案里还有**结构**上的保障:Windows 与 Silverblue 各用一块独立 ESP,所以 Windows 更新只能改写装 `\EFI\Microsoft\` 的那一块,够不到 `\EFI\fedora\`。

这四条之所以管用,是因为"卡在 grub 命令行"的根因不是 GRUB 坏了,而是固件 NVRAM 里的条目仍指向已被删除的引导文件、且排在 Windows 前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目之后回落到 Windows(见 [docs/00-overview.md](docs/00-overview.md))。

## 适用设备类

需同时满足:

- 单块 NVMe SSD,**标称 1TB 级**,UEFI + GPT 引导。容量口径要说清:1024GB 型号实际可用约 **953.7GiB**,方案分区表按此制定;1000GB 型号只有约 **931.3GiB**,此时把 `D:` 从约 635GiB 减到约 613GiB,其余七项不动;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化:两个系统都是全新安装,不存在"保留现有系统"的路径;
- 目标组合:Windows 11 专业版 + **Fedora 44 Silverblue**(原子版,GNOME 50,默认 Wayland 会话)。

偏离项要么给出适配分支(两块及以上磁盘、容量明显偏离 1TB、仅独显、桌面换 Kinoite、共享盘降级为只读、共用 ESP 回退分支),要么明确**不适用于 v1**:需要磁盘加密、VMD/RAID 模式锁定无法更改、固件只从第一块盘引导的机型。吸收厂商差异的设备参数表(`DISK`、`VENDOR`、`BOOT_MENU_KEY`、`DISK_MODEL`、`DISK_SIZE`、`UBLUE_IMAGE` 等)定义在 [docs/00-overview.md](docs/00-overview.md),每台设备填一份。其中 ublue 的 NVIDIA 镜像名与分支**标"待核实"**,`UBLUE_IMAGE` 在按上游文档核实前不得当成定值。

## 目标分区表

标称 1TB 的 NVMe(实际可用约 953GiB)上共 **8 项**:

| 序号 | 分区 | 大小 | 类型 | 用途 |
|---|---|---|---|---|
| 1 | ESP-Windows | 2GiB | EFI System(FAT32) | 只给 Windows;只放 `\EFI\Microsoft\` 与 `\EFI\BOOT\` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 `C:` | 200GiB | NTFS | 系统与程序;重装 Windows 时唯一被格式化的分区 |
| 4 | Windows 数据 `D:` | 约 635GiB | NTFS | 游戏、下载、文档、容器镜像;双系统共享盘 |
| 5 | ESP-Fedora | 1GiB | EFI System(FAT32) | Silverblue 自己的 ESP,只放 `\EFI\fedora\`;挂 `/boot/efi` |
| 6 | `/boot` | 1GiB | ext4 | 原子版必须独立;每个部署的内核与 initrd 都在这里 |
| 7 | Fedora root | 约 113GiB | btrfs | `/`,ostree 部署 + `var` 子卷(`/home` 是到 `/var/home` 的符号链接) |
| 8 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计约 953GiB(2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1)。Fedora 侧合计 115GiB(1 + 1 + 113),共享数据盘约占全盘三分之二。

- **Fedora 侧三块分区在 L1 预留的 115GiB 未分配区内创建**:L1 的 `diskpart` 只分到 `D:` 为止,余量**不分配**;L3 安装器在这个区间里切出 ESP-Fedora 1GiB + `/boot` 1GiB + root 约 113GiB。
- **两块 ESP 绝不共用**:Windows 一块 2GiB,Silverblue 一块 1GiB;两者的尺寸都不允许被安装器削减。
- 不建 swap 分区:交换空间由 L4 配的 zram 与 4GiB swapfile 承担,休眠不在方案内。
- 分区表用 `diskpart` 预建([templates/partitions.txt](templates/partitions.txt)),这也是"允许整盘格式化"成为前提的原因。

## 原子版语义与回滚

Fedora Silverblue 是原子版系统,方案顺着它设计而不是对抗它:

- **`/usr` 只读**:系统本体由 ostree 管理,不能就地装包;系统级工具要用 `rpm-ostree install` 分层安装;
- **分层 / 更新 / rebase 都产生新部署**:必须重启才生效,"命令成功"与"系统可用"是两个判据;
- **回滚是部署级**:开机菜单选上一个部署,或 `rpm-ostree rollback`([scripts/linux/dbk-rollback.sh](scripts/linux/dbk-rollback.sh) 负责列出部署、pin/unpin 与回滚)。`/var` 与 `/var/home` 不属于部署,**用户数据不随回滚丢失**——系统退回去,文件留在原地;
- **明确不使用**:**`snapd`**(应用走 Flatpak,系统层走 `rpm-ostree`);**`snapper` / `grub-btrfs` / btrfs 快照回滚**(回滚是系统部署级,不是文件系统快照级,设计文档把它列为被否方案);
- **四级回滚粒度**:单步 <-> 卡的「出错时:」;部署级 <-> 开机菜单或 `rpm-ostree rollback`;基线级 <-> ESP 镜像 + 固件启动项快照;阶段级 <-> L5 退役流程。

## 两侧隔离与共享盘

方案在**两个系统上都把系统与数据分开**,所以任何一边崩都不会拖垮另一边:

- **Windows**:200GiB 系统分区(`C:`)+ 约 635GiB 数据分区(`D:`)。六个已知文件夹(桌面/文档/下载/图片/视频/音乐)、游戏库与容器镜像全部重定向到 `D:`,所以重装 Windows 只格式化 `C:`。分工是刻意的:`C:` 是可抛弃的那块,`D:` 是值得长期保护的那块。
- **Silverblue**:约 113GiB root + 独立 1GiB `/boot`。文档、下载、图片与桌面放在共享盘上,这才让 root 保持小;又因为 `/var/home` 不属于部署,升级翻车时一次部署回滚即可,用户数据毫发无伤。

`D:` 不是 Windows 私有卷,而是**共享分区**:Windows 侧原生访问,Silverblue 侧以内核 `ntfs3` 驱动读写挂载——在 Windows 里编辑的办公文件,切到 Linux 直接打开,不需要拷贝或中转介质。四项前提让它安全,且都是前置条件而不是建议:

1. Windows 关闭 Fast Startup 与休眠,否则 NTFS 处于"混合关机"的脏状态,Linux 挂载会失败甚至损坏;
2. `D:` 不启用 BitLocker / 设备加密,否则 Linux 侧无法直接读写;
3. 挂载时固定 `uid`/`gid`/`umask` 并加 `windows_names`,因为 `ntfs3` 没有 POSIX 权限位(见 [templates/fstab.snippet](templates/fstab.snippet));
4. 不在共享盘上做依赖 POSIX 语义的工作:符号链接、硬链接、大小写敏感重命名、依赖权限位的脚本都留在 Linux 本地 root。

挂载由脚本完成([scripts/linux/mount-shared.sh](scripts/linux/mount-shared.sh)),Linux 侧家目录重定向同样脚本化([scripts/linux/xdg-redirect.sh](scripts/linux/xdg-redirect.sh))。验收包含**双向可见性测试**:Windows 写入标记文件 → Linux 读到,反向再做一次。

## 崩溃后原地重装

两个系统都能**在原盘上原地恢复**,这是设计目标而不是期望:

- **Windows 崩溃** → 只格式化 `C:` 重装 Windows;`D:`、Fedora 三块分区、MSR 与 WinRE 一律不动。安装程序在 Windows 那块 ESP 上重建 `\EFI\Microsoft\`,可能顺带覆盖该 ESP 上的 `\EFI\BOOT\bootx64.efi`(属正常);Fedora 的独立 ESP 是另一块分区,不受影响。
- **Silverblue 崩溃** → 先把 `/var/home` 备份到共享盘,再只格式化 root(btrfs)重装 Silverblue;`/boot` 与 ESP-Fedora 挂上但**绝不勾选格式化**,Windows 侧与共享数据都保住。
- **只是引导层损坏** → 不要重装:用 L2 基线还原 ESP + `bcdboot` 重建 + 清理残留 NVRAM 条目(见 [docs/07-rescue.md](docs/07-rescue.md))。

全流程最危险、因此在每个涉及处都写成第一号禁令的一步,是**误格 ESP**:其中一块装着 `\EFI\Microsoft\`,一格式化就把两个系统一起弄挂。

## 健壮性九项

失去一个可用系统的代价远高于重装,所以 Silverblue 侧做了九项加固(设计文档 4.7 节,R1 至 R9),每项都对应一个可回滚点:

1. **变更前固定当前部署**(分层、rebase、发行版升级之前先 `rpm-ostree pin`);
2. **部署级回滚**:开机菜单或 `rpm-ostree rollback`,回滚后复检会话与模块;
3. **多部署保留 + 一次性启动**:每个部署自带内核与 initrd(在独立 `/boot`),固件层 `BootNext` 与部署选择互补且不违反 I2;
4. **常备救援介质**:安装 U 盘兼作 live 环境,不回收;
5. **崩溃可观测**:journald 持久化,启动失败后仍能 `journalctl -b -1` 回看(`/var` 不随部署回退);
6. **OOM 与内存压力防护**:zram 核对通过 + 4GiB swapfile,并确认 `systemd-oomd` 启用;
7. **常开 SSH 救援通道**:桌面挂死时仍可从另一台机器排障(`/etc` 持久化,跨部署保留);
8. **保守更新策略**:`rpm-ostreed-automatic` 只 check / download,**不自动应用、不自动重启**;
9. **磁盘健康监控**:分层装 `smartmontools`(`smartd`),配合发行版默认的文件系统校验策略。

## 验收

是否完成,以 [docs/08-verification.md](docs/08-verification.md) 全绿为唯一判据,不以"装完了"为准。清单分六组:

- **A. 引导安全组(A1-A8)**:多次重启后 `BootOrder` 首位仍是 Windows Boot Manager、`\EFI\Microsoft\` 与 L2 基线逐文件一致、`{bootmgr}` 的 `path` 未变、全程没写过永久启动顺序、Fedora 条目位于末尾、两块 ESP 互不干扰,并含一次**可逆的撤除演练**。
- **B. 系统功能组(B1-B11)**:Wayland 会话、显卡驱动正常且有 nouveau 兜底、Secure Boot 仍开启、`ntfs3` 读写挂载带 `nofail`、共享盘双向可见、`rpm-ostree status` 显示 ublue 镜像来源、分层包清单与计划一致、家目录重定向生效、RTC 用 UTC、切换系统后蓝牙无需重配、`fwupd` 能识别设备。
- **C. 双系统切换组(C1-C3)**:一次性 `BootNext` 进 Linux 且不改默认项、一键回 Windows、切换三次后顺序仍稳定。
- **D. 可撤除性组(D1-D6)**:L5 五步退役完整推演、系统盘隔离逐项核对、两条原地重装路径各走一遍、非重装的引导修复路径已被证明可用。
- **E. 记录组(E1-E5)**:产物齐全且未入库、偏差回写到设备参数表。
- **F. 健壮性组(F1-F9)**:真做一次部署回滚演练(并确认用户数据仍在)、固定(pin)可用、多部署可回退、journald 持久化、更新策略与配置一致、SSH 可达、`systemd-oomd` 与 zram 生效、`smartd` 报告 PASSED、L4 写入的挂载项带 `nofail` 而 `/boot/efi` 刻意不加。

两侧总控是 [scripts/linux/verify-all.sh](scripts/linux/verify-all.sh) 与 [scripts/windows/verify-all.ps1](scripts/windows/verify-all.ps1),都只做只读判定;两侧都落汇总时用 `--out-dir` / `-OutDir` 指到与人工填写版不同的目录,避免互相覆盖。未勾选项只有在落成"已知例外"并写明影响面时才可接受,否则该设备判为未完成。至少一台设备完整跑通,才能称为"参考实现"——目前还没有。

## 风险

已知故障类型连同缓解手段登记在 [docs/design/00-design.md](docs/design/00-design.md) 第 9 节(**34 条**),按阶段的速查与 20 张症状卡在 [docs/10-faq.md](docs/10-faq.md)。覆盖:Intel VMD/RAID 控制器模式、改分区表或固件触发的 BitLocker 恢复提示、Windows 更新重写自己那块 ESP 与 SBAT/DBX 事件、原子版上的 NVIDIA 模块签名、Fast Startup 与双写 NTFS、固件只认第一块盘、安装时选错目标盘、两系统间时间与蓝牙状态分裂、`ntfs3` 写入导致共享盘损坏、Anaconda 在已有系统的盘上装 Silverblue 的上游已知失败、把硬件故障误判成双系统问题。

Windows 激活也作为一条风险登记:手册只写流程并外链上游项目,不随仓库分发任何激活脚本,仓库里也确实没有这类脚本。安装介质校验按厂商现实分开写:Fedora ISO 按官方 `CHECKSUM` 文件比对;Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验"([docs/01-firmware.md](docs/01-firmware.md))。

## 当前状态

- **设计与手册:已完成。** 设计文档定稿,全部手册([docs/00-overview.md](docs/00-overview.md) 至 [docs/10-faq.md](docs/10-faq.md))与两份勾选清单均已写出。
- **脚本:已交付,只到夹具级验证。** 每张步骤卡都有自己的脚本,"卡 ↔ 脚本"双向机器校验;`bash scripts/repo/check-docs.sh` 报 `check-docs: OK`(卡格式、引用、链接),`bash scripts/repo/check-scripts.sh` 报 `check-scripts: OK`(200 行上限、`bash -n` 语法、PowerShell 解析;本机未安装的检查器会显式报 `SKIP`)。但**没有一个脚本在目标机上跑过**,PowerShell 辅助脚本也没有在真实硬件上执行过——它们的证据是 `.superpowers/` 下的夹具套件,不是设备。
- **尚无参考实现。** 没有任何设备完整走过 L0 至 L5,所以 `baseline/` 除自身的 README 之外是空的,验收清单也没有任何设备的填写版。请把这里的命令与判据当作"纸面复核 + 夹具验证过",而不是"现场验证过"。
- **单机产物永不入库。** `baseline/*` 被 `.gitignore` 排除,只保留 [baseline/README.md](baseline/README.md);它装的是分区表、ESP 镜像、固件启动项快照与激活状态,留在本地。

## 参与贡献

自检脚本就是契约:提交前跑 `bash scripts/repo/check-docs.sh` 与 `bash scripts/repo/check-scripts.sh`;每份手册保持卡格式(`### NN-K` 卡标题 + 「看到: / 坑: / 出错时:」与 `脚本:` 行);每个脚本不超过 200 行;不得提交 `baseline/*` 产物、AI 过程文件与 emoji。改动若动到设计而不是某一步,先改 [docs/design/00-design.md](docs/design/00-design.md),再改手册。

## 许可

MIT,见 [LICENSE](LICENSE)。
