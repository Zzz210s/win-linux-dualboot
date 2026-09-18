# 设计:Fedora 变体(把 Linux 侧从 Ubuntu 26.04 LTS 换成 Fedora 44 Workstation)

日期:2026-09-18
状态:待实施(实施前需用户复审)
适用:本仓库(win-linux-dualboot)全部文档与 Linux 侧脚本
相关设计:`00-design.md`(方案本体,本次需修订其中若干条决策)、`01-playbook-reshape-design.md`(卡式改版,本次与内容替换合并执行)

---

## 1. 背景与本设计的作用

用户决定把 Linux 侧从 Ubuntu 26.04 LTS 换成 Fedora。这不是"换个发行版名字"——它牵动 **Secure Boot 与 NVIDIA 驱动路径、文件系统与快照机制、包管理与更新策略、12 个 Linux 脚本中的 7 个**。本设计把这些取舍定死,作为后续"内容替换 + 卡式改版"合并实施的依据。

已定的六项(用户逐条确认):

| # | 决定 | 备注 |
|---|---|---|
| D1 | **Fedora 44 Workstation(GNOME)**,传统可变系统(非原子版) | GNOME 50,与现方案的桌面层同代 |
| D2 | **接受 13 个月生命周期**,把"发行版升级"写成正式卡 | Fedora 44 支持至 2027-06-02 |
| D3 | **Secure Boot 保持开启** + RPM Fusion `akmod-nvidia` + 一次性 MOK 注册 + 保留 nouveau 兜底 | 用户授权按"最好"裁定 |
| D4 | **btrfs + snapper + grub-btrfs** 一键回滚 | 原独立快照分区取消 |
| D5 | 分区**为新方案适配**:ESP/MSR/C:/D:/WinRE 不变,Linux 侧改为单个 115GiB btrfs | 总量与预留大小不变 |
| D6 | **不依赖 snap:不安装 snapd** | Fedora 本身不含;文档明写一行口径 |

顺序决定:**内容换 Fedora 与结构换卡式合并成一次改版**(用户先前的"先内容后结构"已被纠正,理由见 9 节)。

## 2. 发行版与生命周期(D1/D2)

| 项 | 决定 | 依据与备注 |
|---|---|---|
| 版本 | **Fedora 44 Workstation** | 2026-04-28 GA;支持至 2027-06-02(约 13 个月) |
| 桌面 | GNOME 50,Wayland 为会话(Fedora 44 的 GNOME 50 不提供 X11 会话) | 与现方案 GNOME 50 同代,桌面层内容改动最小 |
| 生命周期取舍 | **接受**:每 6–12 个月做一次发行版升级(`dnf system-upgrade`),写成正式卡 | 被否:冻结在 44(2027-06 后无安全补丁) |
| 升级卡设计 | 前置=先做一次 btrfs 快照 + 记录当前版本;步骤=升级 + 重启;`看到:`=新版本号 + 会话仍是 Wayland + `nvidia` 模块仍加载且签名有效;出错时=回滚到升级前快照(指向 05 里的快照卡) | 与 D4 配套,升级不再是"怕动"的操作 |
| 被否方案 | Fedora 原子版(Silverblue/Kinoite)+ `rpm-ostree rollback` | 回滚体验更好,但 `/usr` 只读会推翻包管理、驱动(ublue 镜像)、开发环境(toolbox/distrobox)整套写法,改写量约翻倍,与"轻量远程开发 + 办公"收益不成比例 |

**"发行版升级"是本次新增的唯一流程步骤**(Ubuntu 版没有它)。

## 3. 引导栈:不变(继续 GRUB2 + shim)

| 项 | 决定 | 依据 |
|---|---|---|
| 引导器 | Fedora 官方 **GRUB2 + shim**,写入 `\EFI\fedora\` | Fedora 默认且 Secure Boot 友好 |
| 被否 | systemd-boot(`inst.sdboot`) | Anaconda 的 systemd-boot 支持不完整:Fedora 43 有实测 bug(Bugzilla 2402975:`inst.sdboot` 并不安装/配置 systemd-boot,仍装 GRUB);社区亦报告手动分区仍走 GRUB |
| 四条不变量 I1–I4 | **全部保留,一字不改** | 与发行版无关 |
| L5 退役五步 | **全部保留**;仅把 `\EFI\ubuntu\` 换成 `\EFI\fedora\`,`efibootmgr` 条目名从 `ubuntu` 换成 `Fedora` | 见 10 节替换清单 |
| 后续检查 | 实施时核实 Fedora 44 的 GRUB 条目实际显示名(可能是 `Fedora` 或 `fedora`) | 影响 L3 验证与 L5 清理的匹配字符串 |

## 4. Secure Boot 与 NVIDIA(D3,本次最大的行为变化)

Ubuntu 用官方**预签名** NVIDIA 模块(所以旧方案能"SB 全程开启且零自签");Fedora 没有这条路径,只能走 RPM Fusion 的 `akmod-nvidia` 并在 SB 下**自签 + MOK 注册**。

| 项 | 决定 |
|---|---|
| 选路 | RPM Fusion 的 `akmod-nvidia`;SB 保持开启;首次安装后做**一次性 MOK 注册**(重启进蓝色 MOK 界面确认) |
| 兜底 | 保留 nouveau:签名未完成的典型后果是"模块拒载、回落 nouveau、桌面仍可用",这本身是回滚点 |
| 卡与判据 | 新增卡"安装 NVIDIA 驱动与 MOK 注册",`看到:`=`mokutil --list-enrolled` 含 akmods 密钥、`modinfo -F signer nvidia` 输出非空、`lsmod` 有 `nvidia`;签名不完整时 `看到:` 明确写"回落 nouveau 的可见迹象" |
| 巡检 | 周期巡检卡新增一条:`nvidia` 模块的签名者与版本(内核或驱动更新后复核) |
| 实施时须核实 | MOK 注册的确切命令与密钥路径(候选:`sudo mokutil --import /etc/pki/akmods/certs/public_key.der`);akmods 是否自动签名、失败时的处置(`akmods --force` 等)。**以 RPM Fusion 与 akmods 官方文档为准**,核实前不得写成确定步骤 |
| 被否方案 | 关闭 Secure Boot(降低整机安全基线、牵动 Windows 侧策略)/ 只用 nouveau(放弃 3060 的 PRIME 与日后本地推理)/ 只用集显(浪费独显) |

## 5. 存储:分区与快照(D4/D5)

### 5.1 新分区表(与旧表对比)

| 分区 | 旧(Ubuntu 版) | 新(Fedora 版) |
|---|---|---|
| ESP | 2GiB | **不变**(Windows 与 Linux 共用) |
| MSR | 16MiB | **不变** |
| C: | 200GiB | **不变** |
| D: | ≈635GiB NTFS(双系统共享) | **不变** |
| Linux 预留 | 115GiB = root 100 + 快照 15 | **仍是 115GiB**,但改为**单个 btrfs 分区** |
| WinRE | 1GiB(盘尾) | **不变** |

**连带结论:`templates/partitions.txt`(L1 的 diskpart 脚本)不需要改** —— 预留空间总量与位置都没变,变的只是 L3 在这 115GiB 里建什么。

### 5.2 btrfs 子卷布局

| 子卷 | 挂载点 | 说明 |
|---|---|---|
| `@` | `/` | **含 `/boot`** |
| `@home` | `/home` | |
| `@snapshots` | `/.snapshots` | snapper 的快照位置 |
| `@log` | `/var/log` | 把日志从根子卷分离,回滚不带日志 |

**`/boot` 放进 `@` 是关键决定**:snapper 回滚时能连内核与 initramfs 一起回,避免"回滚了系统但内核没回"的经典故障(这是 Fedora + 独立 `/boot` 社区踩坑最多的地方)。

### 5.3 快照与一键回滚

| 项 | 决定 |
|---|---|
| 工具 | `snapper`(打快照、清理)+ `grub-btrfs`(把快照挂进 GRUB 菜单,重启即可选一个旧状态启动) |
| 一键入口 | `grub-btrfs` 的引导菜单条目(开机菜单选快照)+ **新增脚本** `scripts/linux/snapshot.sh` 做"手动打快照 / 列出快照 / 回滚到指定快照"三件事(≤200 行,dry-run 默认,与其它 L4 脚本同约定) |
| 快照时机 | **只在变更前手动打**(安装/升级驱动、发行版升级、大改配置);不设定时任务 —— 与旧方案"变更前快照"一致 |
| 空间管制 | 新增卡:snapper 清理定时器与保留份数;判据=`snapper list` 条目数受控、`df` 剩余空间高于阈值(避免快照吃满根分区,这是同一文件系统共享空间的固有代价) |
| 被否方案 | 独立 15GiB 快照分区(快照是同一 btrfs 内的子卷,独立分区无意义)/ 保留 ext4 + Timeshift(旧方案;Fedora 上要第三方源,且 btrfs 原生能力更强) |
| 与 R1–R9 的关系 | 健壮性的 R1/R2 由"独立快照分区 + 手动快照"改写为"btrfs 子卷快照 + grub-btrfs 回滚";其余 R3–R9 机制不变(内核保留份数由 Fedora 默认 `installonly_limit=3` 承担) |

## 6. 包管理、更新与系统组件的映射表

| 领域 | Ubuntu 版 | **Fedora 版** |
|---|---|---|
| 包管理 | `apt` / `dpkg` | `dnf`(dnf5)/ `rpm` |
| 装包 | `apt install -y X` | `dnf install -y X` |
| 列举已装版本 | `dpkg-query -W -f='${Package}=${Version}'` | `rpm -q --queryformat '%{NAME}=%{VERSION}-%{RELEASE}\n'` |
| 卸载驱动 | `apt-get remove --purge nvidia-*` | `dnf remove akmod-nvidia kmod-nvidia ...`(`rpm -qa \| grep nvidia` 先列) |
| 自动安全更新 | `unattended-upgrades` | `dnf-automatic`(`/etc/dnf/automatic.conf`,`upgrade_type = security`) |
| 不自动重启 | `Unattended-Upgrade::Automatic-Reboot "false"` | `apply_updates = yes` 且不启用 `reboot` 选项(不装/不启用 dnf-automatic-reboot 之类) |
| 内核/驱动不自动更新 | apt 黑名单 `linux-`/`nvidia-` | `/etc/dnf/dnf.conf` 的 `exclude=` 或 `dnf versionlock` |
| SSH 单元名 | `ssh` | **`sshd`** |
| 防火墙 | ufw(未用) | firewalld(默认启用,保留) |
| 磁盘健康 | `smartmontools` + `smartd` | 同名同单元名 |
| 固件 | `fwupd` | 同名 |
| 快照 | `timeshift` | `snapper` + `grub-btrfs` |
| 共享盘 | 内核 `ntfs3` 读写 | **不变**(Fedora 内核同样含 `ntfs3`) |
| zram | 需自装 `systemd-zram-generator` | **Fedora 通常预装并默认启用** `zram-generator`(实施时核对:`zramctl` 有 `zram0` 即已启用);卡于是从"安装并配置"改为"**核对**",核对失败才用 `templates/zram-generator.conf` |
| swapfile | 4GiB + `nofail` | 保留 4GiB swapfile + `nofail`(判据改为"zram0 存在且 swap 总量 ≥ 4GiB") |
| 蓝牙密钥同步 | 上游 `bt-keys-sync` + `chntpw` | 同上;装包命令改 `dnf install chntpw`(在 RPM Fusion) |
| 桌面 | GNOME 50 | GNOME 50(**同代,改动最小**) |
| 会话 | Wayland 唯一 | Wayland(Fedora 44 的 GNOME 50 不提供 X11 会话) |
| 无人值守入口(未来) | autoinstall(cloud-init) | kickstart |

## 7. 脚本影响面(7 个 Linux 脚本)

| 脚本 | 影响 | 处置 |
|---|---|---|
| `dbk-apt.sh` | 全部是 apt 语义 | **改名为 `dbk-pkg.sh`**(中性名,避免在 Fedora 上误导),内容改为 `dnf`/`rpm` 实现,保留 `DBK_SKIP_APT` 语义并新增别名 `DBK_SKIP_PKG`(旧名保留兼容) |
| `hardening.sh` | 28 处(Ubuntu 专属包名、单元名、`unattended-upgrades`、`timeshift`) | 改为 dnf/`dnf-automatic`/`snapper`+`grub-btrfs`/`sshd`;保持"逐项失败不中断 + 汇总 + dry-run/`--apply`"结构 |
| `graphics.sh` | 17 处(`ubuntu-drivers`、DKMS 禁令、签名判据) | 改为 `akmod-nvidia` 路径 + MOK 注册 + `modinfo -F signer` 判据;保留 nouveau 兜底分支 |
| `storage.sh` | 7 处(swapfile + zram 安装) | zram 由"安装"改"核对";swapfile 逻辑保留;包管理调用改用 `dbk-pkg.sh` |
| `bt-keys-sync-wrapper.sh` | 7 处(apt 装 `chntpw`) | 改 dnf 路径(RPM Fusion 源) |
| `xdg-redirect.sh` | 1 处 | 仅文案 |
| `reboot-to-windows.sh` | 1 处(注释里的 Ubuntu 措辞) | 仅文案 |
| 其余 5 个 Linux 脚本 + 4 个 PowerShell + `check-*.sh` | 无 apt/Ubuntu 依赖 | **不动**(PowerShell 侧完全不受影响) |
| **新增** `scripts/linux/snapshot.sh` | 新文件 | 打快照 / 列出 / 回滚三件事;dry-run 默认;受“≤200 行”约束 |

脚本仍受"每个 ≤200 行"约束;`graphics.sh` 已 200 行,改写时必须先拆文件或同步缩减。

## 8. 文档内容替换清单

| 文档 | 要改的点(要点,实施时逐条落实) |
|---|---|
| `docs/design/00-design.md` | 决策 3.1/3.2/3.3(发行版/桌面/引导栈:改为 Fedora 44 Workstation、GNOME 50、GRUB2+shim 保留)、3.6/3.7(D4/D5:115GiB btrfs 单分区、子卷布局)、3.8(zram 由 Fedora 默认承担)、3.14(R1/R2 改为 snapper+grub-btrfs)、新增 3.21(生命周期与发行版升级)、4.x 各阶段步骤、5.1 分区表、7.1 巡检、8 验收(F 组的快照判据)、9 风险(新增 MOK/签名失败、发行版升级、快照吃满空间)、10 未决项、11.1 证据 |
| `docs/00-overview.md` | 适用设备类里的发行版名、参数表(新增"发行版版本"字段)、阶段地图(新增"发行版升级"入口) |
| `docs/01-firmware.md` | L0 介质章节:从官方镜像站与校验值来源改为 Fedora 的 `Fedora-Workstation-Live` + `Fedora-Spins`/校验和文件;介质制作命令不变 |
| `docs/02-windows.md` | 仅文案(分区预留仍是 115GiB,无需改数值);WinRE 偏差判据不变 |
| `docs/03-preflight.md` | 存储控制器检查不变;新增"Fedora 安装介质可引导"的一条 |
| `docs/04-ubuntu.md` → **`docs/04-fedora.md`** | 文件名改;整个 L3 改为 Fedora Anaconda 手动分区(单个 btrfs 卷 + 子卷 `@`/`@home`/`@snapshots`/`@log` + `/boot` 在 `@` 内 + ESP 复用不格式化);引导写入 `\EFI\fedora\`;产物名 `baseline/03-efi-layout.txt` 不变 |
| `docs/05-first-boot.md` | 共享盘/家目录/时间/蓝牙不变;显卡卡改 MOK+NVIDIA;zram 改核对;硬化的更新策略改 dnf-automatic;快照卡改 snapper/grub-btrfs;新增"发行版升级"卡 |
| `docs/06-decommission.md` | `\EFI\ubuntu\` → `\EFI\fedora\`;NVRAM 条目名匹配串改 Fedora |
| `docs/07-rescue.md` | 同上替换;3.1(b) 的 live 重建从 `grub-install`(Debian 语义)改为 Fedora 的 `dnf reinstall grub2-efi-x64 shim-x64` + `grub2-mkconfig`;只重装 Fedora 的办法二改为 Anaconda 手动分区(只格 btrfs 分区、ESP 绝不格式化) |
| `docs/08-verification.md` | F 组快照判据改为 snapper/grub-btrfs;新增"发行版升级后复检"的条目;B 组新增"nvidia 模块签名有效" |
| `docs/09-risks.md` | 28 条里替换 Ubuntu 专属项;新增:签名未完成导致驱动拒载、发行版升级失败、快照吃满根分区、Fedora 13 个月期限 |
| `docs/10-faq.md` | 症状卡里 Ubuntu 专属的措辞与命令替换;新增"怎么回滚到上一个状态"(snapper/grub-btrfs)与"发行版升级失败怎么办" |
| `checklists/*.md`、`baseline/README.md` | 文件名与产物名的替换(`04-ubuntu.md` → `04-fedora.md`) |
| `README.md` / `README.zh-CN.md` | 发行版、分区、快照机制、生命周期与"不使用 snap"的口径;双语同步 |
| `templates/` | `partitions.txt` **不改**;`zram-generator.conf` 改为"备用模板"(Fedora 默认已启用 zram,核对失败才用它);`unattended-upgrades.snippet` → 重写为 `dnf-automatic.snippet`;`fstab.snippet` 的 `/snapshots` 行改为 `/.snapshots` 子卷挂载 |

**与 `01-playbook-reshape-design.md` 的关系**:本设计**取代**其对文档名的列举——`04-ubuntu.md` 按本设计改名为 `04-fedora.md`,卡编号随之变为 `04-K`;其余卡体系规则(格式、C1–C8、引用策略)以 `01-playbook-reshape-design.md` 为准。

## 9. 顺序与实施组织(D6)

**纠正**:先前"先切内容、再做卡式改版"是把同一段内容写两遍。正确顺序是**合并成一次改版**:

1. 先修订 `docs/design/00-design.md` 的 Fedora 决策(设计先行,避免文档与设计漂移);
2. 再把 `01-playbook-reshape-design.md`(卡式改版)与 Fedora 内容替换**合并**成同一个实施计划,按文档逐份推进:一份文档一次改到位(结构与内容同时改),改完即审查;
3. `04-ubuntu.md` → `04-fedora.md` 改名,并全仓重写引用;
4. 脚本改造(7 个)与文档并行的独立任务组:先 `dbk-pkg.sh`,再 `graphics.sh`/`hardening.sh`/`storage.sh`/`bt-keys-sync-wrapper.sh`;
5. 自检规则按 `01-playbook-reshape-design.md` 第 6 节(C1–C8)重写;
6. 全仓引用与锚点重写、README 双语同步、终检与抽检样本。

## 10. 完成判据

1. `bash scripts/repo/check-docs.sh` 全绿(C1–C8);`bash scripts/repo/check-scripts.sh` 全绿(脚本 ≤200 行、语法与 PowerShell 解析通过);
2. 全仓 `grep` 不再出现 Ubuntu 专属物:`ubuntu-drivers`、`apt `、`dpkg`、`unattended-upgrades`、`timeshift`、`\EFI\ubuntu`、`docs/04-ubuntu.md`、`Ubuntu 26.04`;
3. 手册中的命令与包名在 Fedora 44 上语义成立(实施时逐条对照 RPM Fusion / Fedora 文档);**未核实的命令必须标注"以官方文档为准",不得写成确定步骤**;
4. 卡式改版的五项判据(`01-playbook-reshape-design.md` 第 10 节)同时满足;
5. 抽检样本:给出 3 组"改版前(Ubuntu 六段式) vs 改版后(Fedora 卡片)"并排对照。

## 11. 风险与取舍

| 风险 | 缓解 |
|---|---|
| **MOK 自签路径写错**(最可能踩的坑) | 实施时以 RPM Fusion/akmods 官方文档核实命令与密钥路径;卡内给"回落 nouveau"的可见迹象作为安全网;巡检卡复核签名 |
| 13 个月生命周期导致"用久了无补丁" | 升级写成正式卡(前置快照 + 后置复检);README 明写"每 6–12 个月升级一次"的使用要求 |
| btrfs 快照与文件系统共享空间,可能吃满根 | 快照空间管制卡(snapper 清理 + 保留份数 + `df` 阈值) |
| `/boot` 进 btrfs 后 GRUB 读 btrfs 的兼容性 | Fedora 的 GRUB 支持 btrfs(含 zstd);实施时在参考设备首次重启时验证"能进 GRUB 菜单且能启动";若失败,退回独立 `/boot` 1GiB ext4 并把该偏差登记 |
| 引导条目名不是 `Fedora` 而是别的串 | 实施时核实;文档统一以"匹配 `fedora` 的条目"为判据 |
| 改写量大(7 个脚本 + 12 份文档)导致审查疲劳 | 合并改版但**逐文档/逐脚本交付与审查**(沿用上一次的执行方式:每份产物一个实现者 + 一个审查者) |

明确接受的取舍:**Fedora 的 13 个月生命周期换来"更新的内核与桌面"**;以及**SB 保持开启换来"必须做一次 MOK 注册"**。

## 12. 事实来源(实施时需复核的条目已标注)

| 事实 | 来源 | 等级 |
|---|---|---|
| Fedora 44 GA 2026-04-28;支持至 2027-06-02 | Red Hat 官方公告;endoflife.date | 高 |
| Fedora 44 Workstation = GNOME 50;KDE 版 = Plasma 6.6.4 | Fedora Magazine 官方博客 | 高 |
| 桌面默认 btrfs(Anaconda 默认建 `root`/`home` 子卷) | Fedora Wiki:`Changes/BtrfsByDefault`、`Changes/ImproveBtrfsPreset` | 高 |
| Anaconda 的 `inst.sdboot` 不生效(仍装 GRUB) | Red Hat Bugzilla 2402975;Fedora Discussion 帖 | 中(单一 bug 报告 + 社区复述) |
| SB + akmods 需 MOK 注册;密钥候选路径 `/etc/pki/akmods/certs/public_key.der` | 多篇社区指南(2025–2026,覆盖 F40/42/43) | **中——实施时必须核对官方文档** |
| snapper + grub-btrfs 在 Fedora 的步骤(含子卷布局建议) | 多篇社区指南(sysguides、computingforgeeks 等,含 F44 版) | **中——实施时必须核对** |
| `dnf-automatic` 配置位于 `/etc/dnf/automatic.conf` | Fedora 文档生态 | 高 |

## 13. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-18 | 初版:Fedora 44 Workstation(GNOME 50)、接受 13 个月生命周期并新增升级卡、SB 开启 + akmods + MOK、btrfs + snapper + grub-btrfs、Linux 侧单 115GiB btrfs(取消独立快照分区)、引导栈维持 GRUB2 + shim、7 个 Linux 脚本影响面、文档替换清单、合并一次改版的顺序 |
| 2026-09-18 | 自审修订:zram 改为“核对?”表述(不预设预装);新增 `scripts/linux/snapshot.sh` 入影响面;明确升级卡位于 05;明确本设计取代 01 对 `04-ubuntu.md` 的引用 |
