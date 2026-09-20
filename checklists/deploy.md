# 部署核对清单(L0-L4)

配合[入口文档](../docs/00-overview.md)使用:阶段划分、四条不变量、设备参数表与交接规则(尤其是"没有产物的阶段视为未完成")都在那里定义。本清单只做两件事:把 L0-L4 的动作串成一条可勾选的线,并逐项指明**产物**与**手册出处**。

用法:执行到哪一项就把该行的 `[ ]` 改成 `[x]`,带 `____` 的地方填实测值;每一行都要能给出证据(命令输出、脚本退出码、产物文件路径)。**判据不成立就不要往下走**,先按对应手册的"失败处理"处置。

三条底线(与[回滚清单](rollback.md)相同,任何阶段都适用):

- 绝不执行 `efibootmgr -o`,也绝不用 `bcdedit /set {fwbootmgr} displayorder ...` 改永久启动顺序(不变量 I2);进另一个系统只用一次性 `BootNext` 或厂商 `BOOT_MENU_KEY` 菜单;
- 绝不覆盖 `\EFI\Microsoft\`,绝不改 `{bootmgr}` 的 `path`(I3);
- 改分区表或固件设置之前先确认基线可用(I4);**L2 未通过之前不得进入 L3**。

## 1. L0 装机前准备

**本阶段产物**:`baseline/00-firmware.md` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L0-1 抄下固件原值(存储控制器模式、Secure Boot、Fast Boot、启动顺序)之后**再**动手改 | 判据:改动前的原值已落盘 | 见 [01-firmware.md](../docs/01-firmware.md) 步骤 1
- `[ ]` L0-2 存储控制器设为 AHCI / NVMe(VMD / RAID On 关闭),**必须在安装 Windows 之前** | 判据:固件界面显示 AHCI 或 NVMe | 步骤 2
- `[ ]` L0-3 Secure Boot 保持开启、Fast Boot 关闭、仅 UEFI(CSM 关闭) | 判据:三项目标状态已记录 | 步骤 3
- `[ ]` L0-4 制作安装介质并校验:Ubuntu ISO 按 `releases.ubuntu.com` 的 `SHA256SUMS` 比对;Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验" | 判据:校验结论写进产物 | 步骤 4
- `[ ]` L0-5 安装前核对目标磁盘(`DISK_MODEL` / `DISK_SIZE`),防装错盘 | 判据:实测值与设备参数表一致 | 步骤 5
- `[ ]` L0-6 记下厂商启动菜单键 `BOOT_MENU_KEY`(它替代"改启动顺序") | 判据:写进产物 | 步骤 6
- `[ ]` L0-7 生成 `baseline/00-firmware.md` | 判据:字段无空缺,且含"启动顺序(`BootOrder` 首位)原值"一行 | 步骤 7

## 2. L1 Windows 全新安装

**本阶段产物**:`baseline/01-partitions.txt`、`baseline/01-activation.md` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L1-1 从安装介质启动,`Shift + F10` 进命令行后按 [templates/partitions.txt](../templates/partitions.txt) 预建整盘分区表(ESP 2GiB → MSR 16MiB → `C:` 200GiB → `D:` ≈635GiB → 115GiB 未分配 → WinRE 1GiB) | 产物:`baseline/01-partitions.txt` | 见 [02-partitioning.md](../docs/02-partitioning.md) 的 `02-4`(双系统预建)或 `02-2`(只 Windows)
- `[ ]` L1-2 只在 200GiB 分区上安装 Windows 11 专业版,并记录 WinRE 落点 | 判据:ESP 尺寸未被削减、留给 Linux 的未分配空间不少于 115GiB;偏差据实记入产物 | [03-windows.md](../docs/03-windows.md) 的 `03-1`
- `[ ]` L1-3 首次进桌面:关闭 Fast Startup 与休眠 | 判据:`powercfg /a` 显示休眠不可用;两项均已关闭 | [03-windows.md](../docs/03-windows.md) 的 `03-2`
- `[ ]` L1-4 系统盘隔离:六个已知文件夹(桌面/文档/下载/图片/视频/音乐)、游戏库与容器镜像全部重定向到 `D:` | 判据:六个已知文件夹的路径值全部以 `D:\` 开头 | [03-windows.md](../docs/03-windows.md) 的 `03-3`
- `[ ]` L1-5 完成激活并落盘状态 | 产物:`baseline/01-activation.md`(激活失败不阻塞,但必须记下报错) | [03-windows.md](../docs/03-windows.md) 的 `03-4` 与 `03-5`
- `[ ]` L1-6 记录 L1 产物并复核四条不变量 | 判据:见[入口文档](../docs/00-overview.md)的不变量检查点表 | [03-windows.md](../docs/03-windows.md) 的 `03-5` 与 `03-6`
- `[ ]` L1-7 紧接着进入 L2(**同一会话内连续完成**,中途若 Windows 发生更新则基线失效、须重做) | 判据:L1 与 L2 之间没有插入系统更新 | [00-overview.md](../docs/00-overview.md) 交接规则第 4 条

## 3. L2 预检与基线(硬闸门)

**本阶段产物**:`baseline/02-preflight-report.md`、`baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L2-1 在**管理员** Windows PowerShell 里跑 [preflight.ps1](../scripts/windows/preflight.ps1)(只读体检) | 判据:输出逐项有实测值,不出现红项 | 见 [03-windows.md](../docs/03-windows.md) 的 `03-6`
- `[ ]` L2-2 红项就地修复后重跑(黄项登记后带风险继续) | 判据:报告无红项 | [03-windows.md](../docs/03-windows.md) 的 `03-6`
- `[ ]` L2-3 跑 [backup-esp.ps1](../scripts/windows/backup-esp.ps1) 生成 ESP 文件树基线与清单 | 产物:`baseline/02-esp-backup/`(含 `EFI/` 子树与 `manifest.sha256`) | [03-windows.md](../docs/03-windows.md) 的 `03-8`
- `[ ]` L2-4 重跑 [preflight.ps1](../scripts/windows/preflight.ps1) 定稿闸门报告 | 产物:`baseline/02-preflight-report.md` | [03-windows.md](../docs/03-windows.md) 的 `03-6` 与 `03-9`
- `[ ]` L2-5 核验 L1 记录(分区表、激活状态、重定向核对)未被后续操作改变 | 判据:与 `baseline/01-partitions.txt` 的定稿值一致 | [03-windows.md](../docs/03-windows.md) 的 `03-6`(报告的 L1 产物复核与隔离结论转记行)
- `[ ]` L2-6 读报告**最后一行**的结论 | 判据:结论为"结论: 允许进入 L3"(不得手工改写判定列) | [03-windows.md](../docs/03-windows.md) 的 `03-7`
- `[ ]` L2-7 闸门复核:结论为"禁止进入 L3"时**停在这里**;L2 是唯一硬闸门 | 判据:四项基线产物齐备且结论为允许 | [03-windows.md](../docs/03-windows.md) 的 `03-7`(闸门只看报告末行结论)

## 4. L3 Ubuntu 安装

**本阶段产物**:`baseline/03-efi-layout.txt` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L3-1 以 UEFI 模式从安装 U 盘启动(先确认 `/sys/firmware/efi` 存在),选"手动分区" | 见 [04-ubuntu.md](../docs/04-ubuntu.md) 步骤 1
- `[ ]` L3-2 只切两块新分区:root 100GiB ext4 挂 `/`、Snapshot 15GiB ext4 挂 `/snapshots`;ESP 复用挂 `/boot/efi` 且**不勾选格式化**;不建 swap 分区 | 判据:只有 root 那一行带格式化勾选 | 步骤 2
- `[ ]` L3-3 确认引导写入 `\EFI\ubuntu\`,期间**不改 `BootOrder`** | 判据:装完 `\EFI\` 下 `Microsoft` 与 `ubuntu` 并存,`BootOrder` 首位仍是 Windows Boot Manager | 步骤 3
- `[ ]` L3-4 Secure Boot 全程保持开启 | 判据:`mokutil --sb-state` 显示已启用 | 步骤 4
- `[ ]` L3-5 黑屏时走应急路径(内核行加 `nomodeset` 只为拿到可用系统,它与 Wayland 冲突,装好驱动后必须移除) | 判据:该参数未留在最终配置里 | 步骤 5
- `[ ]` L3-6 生成 `baseline/03-efi-layout.txt` | 产物:`\EFI\` 目录树 + `efibootmgr -v` + `BootOrder` + `lsblk` | 步骤 6
- `[ ]` L3-7 第一次重启:确认默认仍进 Windows | 判据:连续重启后默认进 Windows,不需要手工选择 | 步骤 7
- `[ ]` L3-8 收尾:恢复 BitLocker 保护(本阶段曾挂起过时) | 判据:`manage-bde -status` 显示保护已开启 | 步骤 8

## 5. L4 首启收敛

**本阶段产物**:`baseline/04-first-boot.md`、`baseline/04-robustness.md` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L4-1 挂载共享数据盘 `D:`:`ntfs3` 读写 + 固定 `uid`/`gid`/`umask` + `windows_names` + `nofail` + `noatime` | 判据:挂载成功且跨系统双向可见(Windows 写入 → Linux 读到,反向再测一次) | 见 [05-first-boot.md](../docs/05-first-boot.md) 步骤 1
- `[ ]` L4-2 家目录重定向:只重定向文档类目录(文档/下载/图片/桌面);`~/.config`、`~/.ssh`、代码仓库留在本地 root | 判据:`xdg-user-dir` 各值指向共享盘对应目录 | 步骤 2
- `[ ]` L4-3 显卡驱动走仓库预签名包(不做 DKMS)并保留 nouveau 兜底;混合显卡配 PRIME offload | 判据:会话为 `wayland`,日志里无模块签名拒绝 | 步骤 3
- `[ ]` L4-4 时间:`RTC in local TZ: no`(Linux 用 UTC,Windows 侧可按需配 `RealTimeIsUniversal=1`) | 判据:`timedatectl` 输出与目标一致 | 步骤 4
- `[ ]` L4-5 蓝牙配对密钥同步(以 Windows 侧为权威来源) | 判据:切换系统后不需重新配对;脚本 [bt-keys-sync-wrapper.sh](../scripts/linux/bt-keys-sync-wrapper.sh) 默认空跑 | 步骤 5
- `[ ]` L4-6 健壮性九项(R1-R9):变更前快照、独立快照分区、多内核保留 + `GRUB_DEFAULT=saved`、常备救援 U 盘、journald 持久化、zram + `systemd-oomd`、常开 SSH 救援通道、保守更新策略、SMART 监控 | 产物:`baseline/04-robustness.md` | 步骤 6
- `[ ]` L4-7 建立"回 Windows 的入口":一次性 `BootNext` 或厂商菜单键 | 判据:[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh) 与 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) 至少一个可用,且都不改 `BootOrder` | 步骤 7
- `[ ]` L4-8 生成 L4 两份产物 | 产物:`baseline/04-first-boot.md` 与 `baseline/04-robustness.md` | 步骤 8

## 6. 完成判据

- **唯一完成判据**是 [08-verification.md](../docs/08-verification.md) 的 A-F 六组全部勾选;不以"装完了"为准。每台设备的填写版落盘为 `baseline/08-verification.md`(多设备时 `baseline/<设备别名>/08-verification.md`),随 `baseline/` 不入库。
- **没有产物的阶段视为未完成**,不得进入下一阶段:本清单每一节开头的"本阶段产物"行就是该节的完成门槛。
- **L2 是硬闸门**:报告末行结论为"禁止进入 L3"时,不得继续 L3 及以后的动作。
- 未勾选项必须落成在案的"已知例外"并写明影响面,否则该设备判为未完成(判据见 [08-verification.md](../docs/08-verification.md) 的"通过定义")。
- L5 退役、引导救援、原地重装两法与基线回滚的勾选项在[回滚清单](rollback.md)。
