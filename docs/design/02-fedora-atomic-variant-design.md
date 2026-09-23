# 设计:Fedora 44 Silverblue(原子版)变体

> **本文档已被 `04-kubuntu-variant-design.md` 取代,保留为历史记录**(记录"为什么曾选原子版、为什么改回传统可变系统");文中 Fedora/ostree/ESP-Fedora 等字样均为当时的命名,不作为实施依据。

日期:2026-09-19
状态:待实施(实施前需用户复审)
适用:本仓库(win-linux-dualboot)全部文档与 Linux 侧脚本
相关设计:`00-design.md`(方案本体,本设计需其同步修订)、`01-playbook-reshape-design.md`(卡格式,继续有效)、`03-step-automation-design.md`(每卡一脚本,继续有效)
**取代**:`02-fedora-variant-design.md`(传统 Fedora 44 Workstation 变体;其 btrfs 子卷 + snapper + grub-btrfs 的"一键回滚"体系作废)

---

## 1. 背景与本设计的作用

用户决定:改回纯双系统(Windows + Linux);要求**配置步骤简化**;**任一系统可单独安装**;**明确不要 snapper**;在对比了六种回滚方案后选定 **Fedora 原子版 + `rpm-ostree rollback`**(方案 B),并接受四项连带改变。

已冻结的六项决定:

| # | 决定 | 备注 |
|---|---|---|
| D1 | 基础系统 = **Fedora 44 Silverblue**(原子版,GNOME 50) | 2026-04-28 GA;支持到约 2027-06(13 个月);KDE 对等替代 = Kinoite(Plasma 6.6.4) |
| D2 | NVIDIA 路径 = 安装后 **`rpm-ostree rebase` 到 ublue 的 NVIDIA 变体** + 一次性 MOK 注册 | 放弃 RPM Fusion `akmods` 直装路径(原子版下已知不签名) |
| D3 | 回滚 = **部署级**(`rpm-ostree rollback` + GRUB 菜单选旧部署) | **不用 snapper、不用 grub-btrfs、不用 btrfs 快照** |
| D4 | 双系统需 **独立 ESP + 独立 `/boot`** | 不让 Anaconda 使用 Windows 的 ESP |
| D5 | **三轨道**:W(只 Windows)/ L(只 Silverblue)/ D(双系统) | 满足"任一系统可单独安装" |
| D6 | 保留全部既有机制**不砍**:MOK 注册、`ntfs3` 读写共享盘、**每卡一脚本**、双模式 CLI 与退出码、C1–C9 自检、A–F 验收、KMS 脚本激活 | "简化"来自按轨道拆分与文档合并,不来自砍机制 |

**本设计与先前方案的关键差别**(一句话):传统版的"一键回滚"是**文件系统快照级**(snapper/grub-btrfs),原子版的"一键回滚"是**系统部署级**(ostree deployment);后者更强,但要求独立 `/boot`、且包管理与驱动路径整体改写。

## 2. 基础镜像与桌面(D1)

| 项 | 决定 | 依据 |
|---|---|---|
| 镜像 | **Fedora 44 Silverblue**(原子 GNOME 桌面) | Fedora 官方原子桌面之一,F44 与 Workstation 同代(GNOME 50) |
| 桌面 | GNOME 50,Wayland 会话 | 与既有设计一致;ublue 的 GNOME 变体验证最充分 |
| 等价替换(可选) | **Kinoite**(原子 KDE,Plasma 6.6.4)+ ublue 的 **Aurora-nvidia** | 若改用 KDE,本设计其余各条不变 |
| 生命周期 | 13 个月;发行版升级 = `rpm-ostree rebase`(见第 4 节) | 与 D2/D3 同族 |

同族其他原子桌面(F44):Sway Atomic、Budgie Atomic、COSMIC Atomic —— 不纳入本方案,仅记录存在。

## 3. NVIDIA 与 Secure Boot(D2,本次最大的行为变化)

**上游事实(必须写进文档的坑)**:

| 事实 | 来源 | 等级 |
|---|---|---|
| `rpm-ostree install` 时 **akmods 不签名**模块(`rpm-ostree` 的新部署不共享宿主 `/etc/` 的密钥) | `fedora-silverblue/issue-tracker#499` | 高 |
| `akmod-nvidia` 会卡住内核升级 | `issue-tracker#632` | 中高 |
| 社区直言"在原子版上装 akmod 基本抵消了原子化的意义" | Fedora Discussion | 中(观点) |

**决定**:安装完成后执行一次 `rpm-ostree rebase` 到 ublue 的 NVIDIA 变体;其镜像内**模块已预签名**;再做**一次性 MOK 注册**。

| 项 | 内容 |
|---|---|
| 目标镜像 | `ostree-image-signed:docker://ghcr.io/ublue-os/bluefin-nvidia:latest`(GNOME);KDE 用 Aurora 的 NVIDIA 变体 |
| MOK 注册 | `ujust enroll-secure-boot-key`;上游 MOK 密码为 `universalblue`;重启后在 MOK 界面确认 |
| 判据(`看到:`) | `mokutil --list-enrolled` 含 ublue 的密钥;`modinfo -F signer nvidia` 非空;`lsmod` 有 `nvidia`;`rpm-ostree status` 显示的镜像来源与版本与计划一致 |
| 可逆性 | `rebase` 可逆(可 rebase 回 stock Silverblue);该动作本身在回滚能力之内 |
| **实施时须核实** | ublue 在 2026-09 的**实际镜像名与分支**(上游会改品牌名/通道名);MOK 密码是否仍为 `universalblue`;`ujust` 任务名。**未核实前不得写成确定步骤** |

**被否路径**:

| 路径 | 否掉理由 |
|---|---|
| stock Silverblue + 手工自签 akmods(按 #499 的 workaround 自建密钥、纳入部署、每次内核更新重签) | 上游已知易碎,额外维护一套签名流程;**列为回退分支**,仅在不愿用 ublue 镜像时启用 |
| stock Silverblue + 仅 nouveau | 等于砍掉 RTX 3060,与"都不砍"冲突 |
| 关闭 Secure Boot | 推翻既有不变量,且牵动 Windows 侧策略 |

## 4. 更新、升级与回滚(D3,替代 snapper 体系)

| 项 | 决定 |
|---|---|
| 更新模型 | `rpm-ostree` 每次更新产生**新 deployment**;GRUB 菜单列出各部署(含版本/时间戳) |
| 一键回滚 | **开机菜单选上一个部署** 或 `rpm-ostree rollback`(切换下一此启动的部署) |
| 自动更新策略 | `rpm-ostreed-automatic`(`/etc/rpm-ostreed.conf` 的 `AutomaticUpdatePolicy = check`/`download`/`stage`);默认只下载不应用 → 与既有"**不自动重启、变更前先固定当前部署**"一致 |
| 发行版升级 | 先 `rpm-ostree pin` 固定当前部署 → `rpm-ostree rebase fedora:fedora/45/x86_64/silverblue`(ublue 变体用其对应分支)→ 重启 → 复检(会话仍 Wayland、`nvidia` 模块仍加载、桌面可用)→ 不满意则回滚到固定部署 |
| 部署固定与清理 | 新增脚本 `dbk-rollback.sh`:列出部署、pin/unpin、回滚、回滚后复检;清理用 `rpm-ostree cleanup`(保留策略见卡) |
| **关键语义(必须写清)** | `/var` 与 `/home`(`/home` 是到 `/var/home` 的符号链接)**不属于部署**,**不随回滚回退** → **回滚系统不会丢用户数据**(这是原子版相对 btrfs 快照回滚的固有优点) |
| 分层安装 | 系统级工具(如 `smartmontools`)用 `rpm-ostree install` 分层,**每次分层需重启**;GUI 应用优先 Flatpak;开发环境走 `toolbox`/`distrobox` |

回滚粒度(替代原"三种粒度"表述):

| 粒度 | 场景 | 手段 |
|---|---|---|
| 单步 | 分层包装错、`/etc` 改错 | 撤销该步(`rpm-ostree uninstall`、`/etc` 备份还原) |
| 部署级 | 更新后桌面起不来、驱动/内核翻车 | 开机菜单选上一部署 或 `rpm-ostree rollback` |
| 基线级 | ESP/NVRAM 被破坏 | 用 L2 基线复原 `\EFI\Microsoft\` + `bcdboot` + NVRAM 清理(与既有设计一致) |
| 阶段级 | 不想要 Linux 了 | L5 退役五步(与既有设计一致) |

## 5. 分区与布局(D4)

| 分区 | 大小 | 角色 |
|---|---|---|
| ESP-Windows | 2GiB | **只给 Windows**;Linux 不再共用 |
| MSR | 16MiB | 不变 |
| `C:` Windows 系统 | 200GiB | 不变(原地重装 Windows 时唯一被格式化) |
| `D:` 共享数据盘 | ≈635GiB | NTFS;Windows 原生访问,Linux 侧 `ntfs3` 读写(保留) |
| **ESP-Fedora**(历史名;现为 `ESP-Ubuntu`) | **1GiB** | 新建;只放 `\EFI\fedora\` |
| **`/boot`** | **1GiB ext4** | 原子版**必须独立**(每个 deployment 的内核与 initrd 在此) |
| **root** | **≈113GiB btrfs** | ostree 部署 + `var` 子卷;`/home` 是 `/var/home` 的符号链接 |
| WinRE | 1GiB | 盘尾;不变 |

- **`templates/partitions.txt`(L1 的 diskpart 脚本)不变**:仍然只在 `D:` 之后预留一段 **115GiB 未分配空间**;变的是 L3 在这 115GiB 里切出上述三块。
- **为何独立 ESP**:上游与社区一致要求 Fedora 用**自己的 `/boot/efi` 与 `/boot`**,并明确"**不要让 Anaconda 使用 Windows 的 EFI 分区**"(见第 6 节证据)。附带好处:I3(不覆盖 `\EFI\Microsoft\`)**由结构保证**,不再依赖纪律。
- **需实测项**:同盘两个 ESP 的固件支持(多数出厂固件支持;若某机型只认第一个 ESP,按"偏离项处置"记录并评估退回共用 ESP 分支)。

## 6. 双系统安装的已知风险与处置(证据驱动)

| 风险 | 证据 | 处置 |
|---|---|---|
| **Anaconda 在已有系统/ESP 的盘上装 Silverblue 会失败**("stops before the EFI boot configuration is correctly written",自 F34 起的已知问题) | `fedora-silverblue/issue-tracker#284` | ① L1 阶段**先手工建好三块 Fedora 分区**(ESP 1GiB + `/boot` 1GiB + root 113GiB),Anaconda 里只做"指定挂载点",不让它动分区表与 Windows ESP;② 若仍失败,按 `07` 救援流程在 live 环境手工修(`ostree admin status` 核对、`grub2-mkconfig -o /boot/grub2/grub.cfg`、必要时 `efibootmgr -c` 补条目并断言 `BootOrder` 首位仍是 Windows);③ 最坏情况退回轨道 W(Windows 单系统),**L2 基线已备份,损失可控** |
| 双 ESP 的固件支持 | 官方文档未承诺;社区实践中可行 | 列为"参考设备必做"的实测项(A 组新增判据) |
| Silverblue 双系统 + SB + NVIDIA 的实操摩擦("要重启很多次") | 社区指南(r/Fedora 2025) | 写进文档预期管理;把"分阶段可中断"作为本方案一贯原则 |
| 该 issue 自 F34 起存在 → **F44 是否已修需复核** | 同上 | 实施时在参考设备实测并回写文档 |

**架构上的一条纪律**:所有"可能失败"的动作都落在 **L3**,而 L3 之前已有 L2 基线备份;失败不会波及 Windows(不变量 I1–I4 与独立 ESP 共同保证)。

## 7. 三轨道结构(D5)

```
共用底座(三条轨道都要)      3 步:固件设置 -> 安装介质 -> 目标盘核对
轨道 W  只装 Windows          5 步:分区 -> 装 -> 激活 -> 关快速启动/休眠 -> 收敛
轨道 L  只装 Silverblue       6 步:装 -> 首启(驱动/挂载/时间/层级) -> 收敛 -> 回滚演练
轨道 D  双系统                底座 + W + L + 共存增量 4 步(预留分区/引导不变量/共享盘/退役救援)
```

| 场景 | 你在机器上的动作数 |
|---|---|
| 只装 Windows | **约 9 步**(底座 3 + W 5 + 收尾 1) |
| 只装 Silverblue | **约 10 步** |
| 双系统 | **约 19 步**(按本表轨道口径;若按 L0–L5 阶段逐个动作口径,则为 30 步;保留全部机制的前提下,减少有限,真正的"简化"落在单系统场景与文档组织上) |

**共用卡 vs 专属卡**:固件、介质、盘核对、KMS 激活、以及"部署回滚演练"属于共用或双轨道复用;**双系统专属**只有 4 条:分区预留(115GiB)、引导不变量核查(BootOrder 首位 = Windows)、`ntfs3` 共享盘、退役与救援。

## 8. 文档与脚本影响面

**死掉**(不再存在):`snapshot.sh`、`set-snapshots.sh`、snapper、grub-btrfs、以及一切 btrfs 快照相关的卡与验收项。

| 脚本 | 处置 |
|---|---|
| `dbk-pkg.sh`(原 `dbk-apt.sh`) | 改写为 **`dbk-ostree.sh`**:`pkg_installed` → `rpm-ostree status --json` 查询;**分层安装** `rpm-ostree install`(含"需重启"提示);保留 `DBK_SKIP_*` 与退出码语义 |
| **新增** `dbk-rollback.sh` | 列出部署(`rpm-ostree status`)、pin/unpin、`rpm-ostree rollback`(经确认后 `--reboot`)、回滚后复检(会话/Wayland/模块) |
| `hardening.sh` | 逐项改原子版语义:分层装 `smartmontools`;`sshd` 用 `systemctl enable --now`(`/etc` 持久化可用);journald 持久化不变(`/etc`);更新策略改 `rpm-ostreed-automatic` |
| `set-updates.sh` | `dnf-automatic` → **`rpm-ostreed-automatic`**(`/etc/rpm-ostreed.conf`) |
| `upgrade-release.sh` | `dnf system-upgrade` → **`rpm-ostree rebase`**(前置:pin 当前部署;后置:复检) |
| `graphics.sh` / `graphics-mok.sh` | `akmods + MOK` → **`rebase` 到 ublue NVIDIA 变体 + `ujust enroll-secure-boot-key`**;判据改为 `mokutil --list-enrolled` + `modinfo -F signer nvidia` |
| `set-remote-health.sh` | 分层装 `smartmontools`;`sshd` 开启;`smartctl -H` 判据不变 |
| `storage.sh` | zram 仍为"核对"(Silverblue 亦默认带 `zram-generator`);swapfile 逻辑保留 |
| `mount-shared.sh`、`xdg-redirect.sh`、`bt-keys-sync-wrapper.sh`、`reboot-to-windows.sh` | 仅文案/语义微调(路径与单元名不变) |
| PowerShell 四个脚本 | **完全不受影响** |

**文档**:11 份 → **约 8 份**(底座 / **分盘前置章节** / 轨道 W / 轨道 L / 轨道 D 共存增量 / 退役与救援 / 验收 / FAQ);`04-ubuntu.md` 当年改名 `04-fedora.md` 的动作,现改为 **`04-silverblue.md`**(安装手册)。

## 9. 验收与风险增补

**验收增补**:

| 组 | 增补项 |
|---|---|
| A(引导安全) | **两个 ESP 互不干扰**:Fedora 侧操作后 `\EFI\Microsoft\` 逐文件不变;`BootOrder` 首位仍是 Windows Boot Manager |
| F(健壮性) | **部署回滚演练**(真做一次):`rpm-ostree rollback` → 重启 → 桌面可用 → 复检模块加载 → 再回滚回来;并确认"**用户数据在回滚后仍存在**"(`/var` 不被回退) |
| B(系统功能) | 新增:`rpm-ostree status` 显示 ublue 镜像来源;分层包列表与计划一致 |

**风险增补 6 条**:Anaconda 双系统安装失败(#284)、双 ESP 固件支持、`rpm-ostree` 下 akmods 不签名(#499)、akmods 卡内核升级(#632)、`rebase` 后驱动状态变化(镜像内模块版本与内核需配套)、ublue 镜像的命名/分支漂移与信任(须记录来源与版本,可 rebase 回 stock)。

## 10. 事实来源与等级

| 事实 | 来源 | 等级 |
|---|---|---|
| F44 原子桌面含 Silverblue(GNOME 50)/ Kinoite(Plasma 6.6.4),与 Workstation 同代 | Fedora Magazine"F44 原子桌面新变化"、官方原子桌面页 | 高 |
| 原子桌面回滚:`rpm-ostree rollback` + GRUB 列出各部署 | Fedora 官方文档"Updates, Upgrades & Rollbacks"(原子桌面) | 高 |
| 发行版升级 = `rpm-ostree rebase` | Fedora Magazine"如何在 Silverblue 上 rebase 到 F44" | 高 |
| 双系统需独立 `/boot/efi` 与 `/boot`,不要让 Anaconda 用 Windows ESP | Silverblue 官方文档双系统页 + Fedora Discussion 两帖 | 中高 |
| Anaconda 在已有 ESP 的盘上装 Silverblue 失败(#284,自 F34) | 上游 issue | 中(需 F44 复核) |
| `rpm-ostree install` 下 akmods 不签名(#499)、akmods 卡内核升级(#632) | 上游 issue | 高 |
| ublue NVIDIA 镜像预签名 + `ujust enroll-secure-boot-key`(MOK 密码 `universalblue`)| `ublue-os/akmods` README、ublue 官方脚本与论坛帖 | 中高(**镜像名/分支/任务名须在实施时复核**) |
| `/var`(`/home`)不随部署回滚 | ostree 部署模型(官方文档) | 高 |

## 11. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-19 | 初版:取代传统版变体设计。基础系统改 Fedora 44 Silverblue(原子)、NVIDIA 改 ublue rebase + MOK、回滚改部署级(去 snapper/grub-btrfs/快照)、双系统改独立 ESP + 独立 `/boot`、引入三轨道结构、给出脚本与文档影响面、增补验收与 6 条风险、标注证据等级与须复核项 |
