# 部署核对清单(L0-L4,三轨道)

配合[入口文档](../docs/00-overview.md)使用:轨道划分、四条不变量、设备参数表与交接规则(尤其是"没有产物的阶段视为未完成")都在那里定义。本清单只做两件事:把三轨道的动作串成一条可勾选的线,并逐项指明**产物**、**跑哪个脚本**与**手册出处**。

**先认轨道**(三张表都从"共用底座"开始,任一系统都可单独安装):

| 轨道 | 要走的小节 | 机器动作量 | 说明 |
|---|---|---|---|
| **共用底座** | §1 L0 + §2 分盘 | 约 3 + 4 步 | 三条轨道都要:固件设置、两个安装介质、核对目标盘、按轨道分盘 |
| **W**(只 Windows) | 共用底座 + §3 | 约 9 步 | 装 Windows、关快速启动与休眠、重定向、激活、L2 闸门 |
| **L**(只 Kubuntu) | 共用底座 + §4 + §5 | 约 10 步 | 装 Kubuntu、首启收敛(Linux 占用整盘) |
| **D**(双系统) | 共用底座 + §3 + §4 + §5 | 约 19 步 | W 与 L 的并集 + 共存增量 4 步:115GiB 预留、引导不变量核查、`ntfs3` 共享盘、退役与救援 |

用法:执行到哪一项就把该行的 `[ ]` 改成 `[x]`,带 `____` 的地方填实测值;每一行都要能给出证据(命令输出、脚本退出码、产物文件路径)。**判据不成立就不要往下走**,先按对应卡的 `出错时:` 处置。脚本一律默认只读:Ubuntu 侧给 `--check`(改系统才加 `--apply` 且需 root 与 `--yes`),Windows 侧给 `-Check`,只有明确写 `-Apply` / 不带 `-Check` 的那一行才动手。

三条底线(与[回滚清单](rollback.md)相同,任何阶段都适用):

- 绝不执行 `efibootmgr -o`,也绝不用 `bcdedit /set {fwbootmgr} displayorder ...` 改永久启动顺序(不变量 I2);进另一个系统只用一次性 `BootNext` 或厂商 `BOOT_MENU_KEY` 菜单;
- 绝不覆盖 `\EFI\Microsoft\`,绝不改 `{bootmgr}` 的 `path`(I3);
- 改分区表或固件设置之前先确认基线可用(I4);**L2 未通过之前不得进入 L3**。

## 1. 共用底座之一:L0 装机前准备

**本阶段产物**:`baseline/00-firmware.md` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L0-1 先抄原值再改设置(存储控制器模式、Secure Boot、Fast Boot、启动顺序) | 脚本:`scripts/windows/check-firmware.ps1 -Check` | 判据:改动前的原值已落盘 | 卡:[01-firmware.md](../docs/01-firmware.md) 的 `01-1`
- `[ ]` L0-2 存储控制器设为 AHCI / NVMe(VMD / RAID On 关闭),**必须在安装任何系统之前** | 脚本:`scripts/windows/check-firmware.ps1 -Check` | 判据:固件界面显示 AHCI 或 NVMe | 卡:`01-1`
- `[ ]` L0-3 Secure Boot 保持开启、Fast Boot 关闭、仅 UEFI(CSM 关闭) | 脚本:`scripts/windows/check-firmware.ps1 -Check` | 判据:三项目标状态已记录 | 卡:`01-1`
- `[ ]` L0-4 做两个安装介质并校验:Fedora ISO 按官方 `CHECKSUM` 文件比对;Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验" | 脚本:`scripts/windows/verify-install-media.ps1 -Check` | 判据:校验结论写进产物 | 卡:`01-2`
- `[ ]` L0-5 安装前核对目标磁盘(`DISK_MODEL` / `DISK_SIZE`),防装错盘 | 脚本:`scripts/windows/preflight.ps1 -Only target-disk`(只打印磁盘段,零写) | 判据:实测值与设备参数表一致 | 卡:`01-3`
- `[ ]` L0-6 记下厂商启动菜单键 `BOOT_MENU_KEY`(它替代"改启动顺序") | 脚本:`scripts/windows/check-firmware.ps1 -Check` | 判据:写进产物 | 卡:`01-1`
- `[ ]` L0-7 生成 `baseline/00-firmware.md` | 脚本:`scripts/windows/collect-l0.ps1`(默认只打印,加 `-Apply` 落盘) | 判据:字段无空缺,且含"启动顺序(`BootOrder` 首位)原值"一行 | 卡:`01-4`

## 2. 共用底座之二:分盘(按轨道选一张卡)

**本阶段产物**:分区记录进 `baseline/`(W 与 D 落 `01-partitions.txt`;L 落 `03-efi-layout.txt` 的分区段)—— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` 分盘-1 认下本机轨道的目标布局(8 项分区表 + "Ubuntu 侧三块分区建在预留的 115GiB 未分配区内") | 脚本:`scripts/windows/check-partition-layout.ps1 -Track <W|L|D> -Check` | 判据:8 个数值已抄进分区记录,核对脚本对本轨道判 PASS | 卡:[02-partitioning.md](../docs/02-partitioning.md) 的 `02-1`
- `[ ]` 分盘-2 轨道 **W**:只建 Windows 侧四块,不给 Linux 预留空间 | 脚本:`scripts/windows/check-partition-layout.ps1 -Track W -Check` | 判据:ESP 2048MB + MSR 16MB + 系统 204800MB,顺序正确 | 卡:`02-2`
- `[ ]` 分盘-3 轨道 **L**:整盘只建 Ubuntu 三块(ESP-Ubuntu 1024MB / `/boot` 1024MB ext4 / root ext4) | 脚本:`scripts/linux/check-partition-plan.sh --track L --check` | 判据:分区列表只有这三块,没动到任何 Windows 分区 | 卡:`02-3`
- `[ ]` 分盘-4 轨道 **D**:装 Windows 前用 diskpart 预建四区并留出约 115GiB 未分配 | 脚本:`scripts/windows/create-partitions.ps1 -Check`(执行时才 `-Apply -Yes`);核对用 `scripts/windows/check-partition-layout.ps1 -Track D -Check` | 判据:四区尺寸与表一致,`D:` 之后仍有约 115GiB 未分配 | 卡:`02-4`

## 3. 轨道 W:L1 Windows 全新安装 + L2 闸门

**本阶段产物**:`baseline/01-partitions.txt`、`baseline/01-activation.md`、`baseline/02-preflight-report.md`、`baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` W-1 只在 200GiB 分区上安装 Windows 11 专业版,并记录 WinRE 落点 | 脚本:`scripts/windows/verify-windows-baseline.ps1 -Check -Track D` | 判据:两块 ESP 尺寸未被削减、Ubuntu root 与预留空间不少于 115GiB;偏差据实记入产物 | 卡:[03-windows.md](../docs/03-windows.md) 的 `03-1`
- `[ ]` W-2 首次进桌面:关闭 Fast Startup 与休眠 | 脚本:`scripts/windows/disable-faststartup.ps1 -Check`(执行时加 `-Apply -Yes`) | 判据:`powercfg /a` 显示休眠不可用;两项均已关闭 | 卡:`03-2`
- `[ ]` W-3 系统盘隔离:六个已知文件夹(桌面/文档/下载/图片/视频/音乐)与游戏库、容器镜像全部重定向到 `D:` | 脚本:`scripts/windows/redirect-known-folders.ps1 -Check`(执行时加 `-Apply -Yes`) | 判据:六个已知文件夹的路径值全部以 `D:\` 开头,`D:\Shared\` 存在 | 卡:`03-3`
- `[ ]` W-4 完成激活并落盘状态 | 脚本:`scripts/windows/check-activation.ps1 -Check` | 判据:状态已记录(激活失败不阻塞,但必须记下报错) | 卡:`03-4`
- `[ ]` W-5 落 L1 产物 | 脚本:`scripts/windows/collect-l1.ps1`(加 `-Apply` 落盘) | 判据:`baseline/01-partitions.txt` 与 `baseline/01-activation.md` 在位 | 卡:`03-5`
- `[ ]` W-6 L2 只读体检(管理员会话) | 脚本:`scripts/windows/preflight.ps1 -Check`(只读判定);`scripts/windows/preflight.ps1 -Apply -OutFile baseline\02-preflight-report.md`(落盘报告) | 判据:报告逐项有实测值,不出现红项;红项就地修复后重跑 | 卡:`03-6`
- `[ ]` W-7 读闸门结论:L2 是唯一硬闸门 | 脚本:`scripts/windows/check-gate.ps1 -Check` | 判据:结论为"结论: 允许进入 L3"(不得手工改写判定列) | 卡:`03-7`
- `[ ]` W-8 跑基线备份(ESP 文件树 + 清单 + 固件启动项 + 分区快照) | 脚本:`scripts/windows/backup-esp.ps1 -OutDir baseline`(复验用 `-Check`) | 判据:`baseline/02-esp-backup/manifest.sha256` 与三份快照在位 | 卡:`03-8`
- `[ ]` W-9 落 L2 产物并核对四件齐备(**与 L1 同一次会话内连续完成**,中途若 Windows 更新则基线失效须重做) | 脚本:`scripts/windows/collect-l2.ps1 -Check` | 判据:四件齐备且结论行为"允许进入 L3" | 卡:`03-9`

## 4. 轨道 L:L3 Kubuntu 安装(不侵犯 Windows 引导)

**本阶段产物**:`baseline/03-efi-layout.txt`(六节) —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L3-1 一次性从安装 U 盘启动进 live(先确认 `/sys/firmware/efi` 存在) | 脚本:`scripts/windows/set-bootnext.ps1 -Device USB -Check`(空跑看计划;执行加 `-Apply -Yes`,缺 `-Yes` 退 64 零写) | 判据:进 live 桌面,`lsblk` 能看到目标盘 | 卡:[04-kubuntu.md](../docs/04-kubuntu.md) 的 `04-1`
- `[ ]` L3-2 手动分区:三块建在预留区内,Calamares 只指定挂载点 | 脚本:`scripts/linux/check-partition-plan.sh --track D --check` | 判据:分区列表新增三行且 Windows 各分区原值不变,没有任何 Windows 分区被标成"格式化" | 卡:`04-2`
- `[ ]` L3-3 装完重启验证(默认仍进 Windows;进 Kubuntu 后逐项核对) | 脚本:`scripts/linux/verify-l3.sh --check` | 判据:`grub-efi-amd64-signed` 与 `shim-signed` 在位、GRUB 落 `\EFI\ubuntu\`、`/boot` 独立且为 ext4、两块 ESP 内容齐全、`BootOrder` 首位仍是 Windows Boot Manager | 卡:`04-3`
- `[ ]` L3-4 落 L3 产物(六节) | 脚本:`scripts/linux/collect-l3.sh --check`(落盘加 `--apply`) | 判据:两棵 `\EFI\` 树 + `efibootmgr -v` + `BootOrder` + `lsblk` + `findmnt` + 引导包与内核版本摘要齐全 | 卡:`04-4`

## 5. 轨道 L/D:L4 首启收敛

**本阶段产物**:`baseline/04-first-boot.md`、`baseline/04-robustness.md` —— 是否已生成:`[ ]` 是 / `[ ]` 否

- `[ ]` L4-1 挂载共享数据盘 `D:`:`ntfs3` 读写 + 固定 `uid`/`gid`/`umask` + `windows_names` + `nofail` + `noatime` | 脚本:`scripts/linux/mount-shared.sh --check`(动手加 `--apply --yes`) | 判据:挂载成功且跨系统双向可见(Windows 写入 -> Linux 读到,反向再测一次) | 卡:[05-first-boot.md](../docs/05-first-boot.md) 的 `05-1`
- `[ ]` L4-2 家目录数据重定向:只重定向文档类目录;`~/.config`、`~/.ssh`、代码仓库留在本地 root | 脚本:`scripts/linux/xdg-redirect.sh --check` | 判据:`xdg-user-dir` 六项都指向共享盘对应目录 | 卡:`05-2`
- `[ ]` L4-3 显卡:用 `ubuntu-drivers` 装 Ubuntu 官方**预签名** nvidia 包(不关 Secure Boot、不自签密钥),保留 nouveau 兜底 | 脚本:`scripts/linux/graphics.sh --check` | 判据:会话为 `wayland`、`lsmod` 有 `nvidia`、`modinfo -F signer nvidia` 非空、`xrandr --listproviders` 有 ≥2 个 provider | 卡:`05-3`
- `[ ]` L4-4 时间:`RTC in local TZ: no`(Linux 用 UTC,Windows 侧按需配 `RealTimeIsUniversal=1`) | 脚本:`scripts/linux/set-time.sh --check` | 判据:`timedatectl` 输出与目标一致 | 卡:`05-4`
- `[ ]` L4-5 蓝牙配对密钥同步(以 Windows 侧为权威来源) | 脚本:`scripts/linux/bt-keys-sync-wrapper.sh`(默认空跑,动手加 `--apply`) | 判据:切换系统后不需重新配对 | 卡:`05-5`
- `[ ]` L4-6 交换空间:zram 只核对 + 4GiB swapfile(fstab 行带 `nofail`) | 脚本:`scripts/linux/storage.sh --check` | 判据:`zramctl` 列出 `zram0`;`swapon` 列出 swapfile 且 fstab 行在位 | 卡:`05-6`
- `[ ]` L4-7 日志持久化与更新策略(journald 落盘;`unattended-upgrades` 只装安全更新、不自动重启) | 脚本:`scripts/linux/set-journald.sh --check`;`scripts/linux/set-updates.sh --check` | 判据:`/var/log/journal` 存在;apt 片段含 `Automatic-Reboot "false"` 且 `Allowed-Origins` 只列 `-security` | 卡:`05-7`
- `[ ]` L4-8 SSH 救援通道与磁盘健康(apt 装 `smartmontools`,`sshd` 与 `smartd` 启用) | 脚本:`scripts/linux/set-remote-health.sh --check` | 判据:两项 `systemctl is-active` 为 `active`;`smartctl -H` 报 PASSED | 卡:`05-8`
- `[ ]` L4-9 **包级回退与变更前备份**(降级 + `apt-mark hold`;本轨道没有一条命令回退整个系统) | 脚本:`scripts/linux/rollback-pkg.sh --check` | 判据:`--list` 能列出包的可用版本、`--check` 能读出已 hold 清单与 apt 历史;参考设备真做一次降级并 `--unhold` 还原 | 卡:`05-9`
- `[ ]` L4-10 **发行版升级**(约 3 年一次:`do-release-upgrade`,前置备份与留档) | 脚本:`scripts/linux/upgrade-release.sh --check`(执行加 `--apply --yes`) | 判据:pin 或 Mozilla 源文件缺失时脚本拒绝升级;重启后版本已更新、会话仍 `wayland`、snap 四条判据全过 | 卡:`05-10`
- `[ ]` L4-11 建立"回 Windows 的入口":一次性 `BootNext` 或厂商菜单键 | 脚本:`scripts/linux/reboot-to-windows.sh --check`;`scripts/windows/set-bootnext.ps1 -Check`(执行加 `-Apply -Yes`) | 判据:至少一个可用,且都不改 `BootOrder`(I1/I2) | 卡:`05-11`
- `[ ]` L4-12 落 L4 两份产物 | 脚本:`scripts/linux/collect-l4.sh --check`(落盘加 `--apply`) | 判据:`baseline/04-first-boot.md` 与 `baseline/04-robustness.md` 在位 | 卡:`05-12`
- `[ ]` L4-13 (可选)按顺序汇总跑一遍 L4 各模块 | 脚本:`scripts/linux/first-boot.sh --check`;`scripts/linux/hardening.sh --check` | 判据:单项失败不改整体退出码,只在摘要里标出失败项 | 卡:`05-13`
- `[ ]` L4-14 **snap 零残留**(四条判据 + apt pin 压制 + Mozilla 官方源) | 脚本:`scripts/linux/step-snap-free.sh --check`(清除加 `--apply --yes`) | 判据:`snap list` 空、`dpkg -l snapd` 无输出、`apt-cache policy snapd` 无候选、`apt-get install -s firefox` 不含 snapd | 卡:`05-14`

## 6. 完成判据

- **唯一完成判据**是 [08-verification.md](../docs/08-verification.md) 的 A-F 六组全部勾选;不以"装完了"为准。每台设备的填写版落盘为 `baseline/08-verification.md`(多设备时 `baseline/<设备别名>/08-verification.md`),随 `baseline/` 不入库。两侧总控([verify-all.sh](../scripts/linux/verify-all.sh)、[verify-all.ps1](../scripts/windows/verify-all.ps1))只做只读判定;落汇总时必须用 `--out-dir` / `-OutDir` 指到与"填写版"不同的目录,避免互相覆盖(见 [08-verification.md](../docs/08-verification.md) 的"记录载体")。
- **没有产物的阶段视为未完成**,不得进入下一阶段:本清单每一节开头的"本阶段产物"行就是该节的完成门槛。
- **L2 是硬闸门**:报告末行结论为"禁止进入 L3"时,不得继续 L3 及以后的动作。
- **共存增量 4 步**(只轨道 D 走):115GiB 预留(§2 分盘-4)、引导不变量核查(§3 全程 + A 组)、`ntfs3` 共享盘(§5 L4-1)、退役与救援(L5)。
- 未勾选项必须落成在案的"已知例外"并写明影响面,否则该设备判为未完成(判据见 [08-verification.md](../docs/08-verification.md) 的"通过定义")。
- L5 退役、引导救援、原地重装两法与基线回滚的勾选项在[回滚清单](rollback.md)。
