# 设计方案:Windows 11 专业版 + Fedora 44 Silverblue(原子版)双系统

日期:2026-09-17(初版)/ 2026-09-19(修订七)
状态:已定稿(待实施计划)
适用:单块 NVMe、UEFI、混合显卡、允许整盘格式化的设备类

---

## 0. 文档定位与阅读顺序

| 文档 | 作用 |
|---|---|
| 本文件 [docs/design/00-design.md](00-design.md) | **为什么**这样设计:目标、轨道结构、不变量、决策记录、风险依据 |
| [docs/design/02-fedora-atomic-variant-design.md](02-fedora-atomic-variant-design.md) | **本次改动的依据**:Fedora 44 Silverblue 原子版的取舍、证据等级与须复核项 |
| [docs/design/01-playbook-reshape-design.md](01-playbook-reshape-design.md) | 手册的**卡格式**(R1–R7)与自检规则(C1–C9) |
| [docs/design/03-step-automation-design.md](03-step-automation-design.md) | 每张卡对应一个脚本(CLI 契约、卡与脚本双向绑定) |
| [docs/00-overview.md](../00-overview.md) ~ [docs/10-faq.md](../10-faq.md) | **怎么做**:按执行顺序编号的分步手册 |
| `README.md` / `README.zh-CN.md` | 面向第一次接触者的入口 |

阅读顺序:先本文件第 1、2 节(目标、轨道结构与四条不变量),再进入手册的 `00-overview.md`。

---

## 1. 目标、适用设备类与非目标

### 1.1 目标

在一台**全新的同规格设备**上建立双系统,同时满足三件事:

1. **能装成**:Windows 11 专业版 + Fedora 44 Silverblue(原子版桌面),Linux 侧默认 Wayland 会话;
2. **能安全撤除**:删除 Linux 后仍能自动进入 Windows,不出现 `grub>` / `grub rescue>`;
3. **能重复**:同一套手册可用于多台同规格设备,不绑定任何一台具体机器的序列号、机器名或历史状态。

原子版带来的额外目标(本次修订新增):**系统回滚不依赖任何第三方快照体系** —— 用 ostree 的**部署级回滚**(开机菜单选旧部署 或 `rpm-ostree rollback`)替代 btrfs 快照/`snapper`/`grub-btrfs`。

### 1.2 适用设备类

**必须同时满足**

- 单块 NVMe SSD,**标称 1TB 级**、UEFI + GPT 引导;**容量口径**:若为 1024GB 型号则实际可用约 **953.7GiB**(本方案默认按此定表),若为 1000GB 型号则只有约 **931.3GiB** —— 两者相差约 22GiB,见 5.1 的偏离分支;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化(Windows 与 Linux 都是全新安装);
- 目标系统组合:Windows 11 专业版 + **Fedora 44 Silverblue**(Linux 侧)。

**偏离项的处置**

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP,不变量不变 |
| 磁盘容量明显偏离 1TB 级(如 512GiB / 2TiB) | 按比例调整 C:、D: 与 Fedora 侧容量,分区布局与四条不变量不变 |
| 已有 ESP 且不愿整盘重排 | **不适用**:本方案依赖整盘重排时按计划定尺寸的两块 ESP(Windows 2GiB + Fedora 1GiB,见 3.4) |
| BitLocker 已启用 | 先执行挂起与恢复密钥备份,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 模式已锁定且无法改为 AHCI/NVMe | **不适用**(Linux 侧看不到磁盘) |
| 仅独显(无集显) | 走"NVIDIA 单显卡分支":不配置 PRIME offload,显示输出直接由独显承担 |
| 无法接受 Linux 写入 NTFS | 把共享挂载降级为只读,或改用独立共享分区(第 10 节变体) |
| 桌面非 GNOME 50 | 走"桌面替换分支":改用原子 KDE 版 **Kinoite 44**(Plasma 6.6.4)+ ublue 的 KDE NVIDIA 变体;本文件其余各条不变,**镜像名与分支须实施时核实** |
| 需要磁盘加密 | **不适用**于 v1;见第 10 节 LUKS 变体 |
| 双盘机型且固件只从第一块盘引导(部分厂商) | **两块 ESP 都必须留在第一块盘**;Linux 数据分区可放第二块盘,但两块 ESP 不能放第二块盘 |
| 机型固件只认第一个 ESP(同盘双 ESP 不支持) | 记录为偏离项并评估"共用 ESP 分支"(第 10 节):退回 Windows 与 Fedora 共用一个 ESP,仍然保留独立 `/boot`;此分支需重新评估 I3 的保障方式 |
| 不接受第三方(ublue)预构建镜像 | 走"stock Silverblue + 手工自签 akmods"回退分支(见 3.3 与第 10 节):在原子版上自建密钥并纳入部署,上游已知易碎,**列为回退而非默认** |

### 1.3 非目标(v1 明确不做)

用户数据与浏览器凭据迁移 / 磁盘加密与 TPM-FDE / 休眠 / **`snapper`、`grub-btrfs` 与一切 btrfs 快照回滚**(本次修订明确剔除:改用部署级回滚)/ 自定义 Secure Boot 密钥(改用上游预签名镜像 + 上游 MOK 注册)/ 图形化安装器 / 多发行版模板 / kickstart 无人值守安装。

砍掉这些不是省事,而是它们的失败模式(凭据泄露、TPM 与引导链测量冲突、休眠与 NVIDIA + Wayland 冲突、自签密钥触发 BitLocker 恢复、无人值守写错分区即毁 Windows)会把方案从"可复现"拖成"每次都得现场救火"。

**注意**:"两个系统都能访问的共享数据分区"(决策 3.16 / 5.3)**不在非目标内**,它是 v1 的正式组成部分。

### 1.4 轨道结构(W / L / D 与共用底座)

本方案由三条**可独立执行**的轨道组成,满足"任一系统可单独安装":

| 轨道 | 场景 | 步数 | 内容 |
|---|---|---|---|
| **共用底座** | 三条轨道都要 | 3 步 | 固件设置 -> 安装介质 -> 目标盘核对 |
| **W** | 只装 Windows | 5 步 | 分区 -> 装 -> 激活 -> 关快速启动与休眠 -> 收敛 |
| **L** | 只装 Silverblue | 6 步 | 装 -> 首启(驱动/挂载/时间/分层) -> 收敛 -> 回滚演练 |
| **D** | 双系统 | 底座 + W + L + **共存增量 4 步** | 预留 115GiB / 引导不变量核查 / `ntfs3` 共享盘 / 退役与救援 |

机器上的动作量(粗算):只装 Windows **约 9 步**;只装 Silverblue **约 10 步**;双系统 **约 19 步**(按本表轨道口径;若按 L0–L5 阶段逐个动作口径,则为 30 步)。

**共用卡 vs 专属卡**:固件、安装介质、目标盘核对、KMS 激活与"部署回滚演练"属于共用或双轨复用;**双系统专属**只有 4 条 —— 预留分区(115GiB)、引导不变量核查(`BootOrder` 首位 = Windows)、`ntfs3` 共享盘、退役与救援。

**"简化"落在哪里**:落在单系统场景的步骤数与文档按轨道拆分后的阅读路径上,**不来自砍掉机制** —— 见决策 3.23 与 `02-fedora-atomic-variant-design.md` 的 D6。

---

## 2. 四条不变量

整个方案的骨架。手册中任何步骤不得违反;违反即视为设计缺陷,而非操作失误。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| **I1** | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向失效的 `\EFI\ubuntu\grubx64.efi`,重启停在 `grub rescue>` |
| **I2** | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| **I3** | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| **I4** | 改分区表或固件设置之前,先完成基线备份(BitLocker 挂起 + ESP 镜像 + 固件启动项快照)——**首次装机时**,分区表在 L1 一次定稿、基线在 L2 生成;**此后的任何分区表或固件变更,都必须先有可用的基线备份** | 除重装外无路可退 |

**I1–I4 的落地方式(本次修订更新)**:Linux 侧条目(`\EFI\fedora\`)现在写在自己独立的 1GiB ESP 上(I3 由**结构**保证,不再只靠纪律),启动项名称的匹配串以实施时实测为准。另注:I1 举例中的 `\EFI\ubuntu\`(该举例按"逐字不改"要求保留)在本方案对应 `\EFI\fedora\`。

**为什么是这四条**:网络上"卡 grub 命令行"的根因不是 GRUB 坏了,而是固件 NVRAM 里的启动条目仍指向已被删除的引导文件,且它排在启动顺序前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目后继续回落到 Windows。这比"记得先修引导再删分区"可靠——后者依赖人的记忆。

---

## 3. 关键决策记录

| # | 决策 | 选择 | 理由 | 被否方案与原因 |
|---|---|---|---|---|
| 3.1 | 系统组合 | Windows 11 专业版 + **Fedora 44 Silverblue(原子版)** | 2026-04-28 GA,支持到约 2027-06;GNOME 50 且 Wayland 会话;**回滚是系统部署级**(不依赖第三方快照工具);NVIDIA 有上游预签名镜像 + 一次性 MOK 注册;`/var` 与家目录不在部署内,回滚不丢用户数据 | **原方案 Ubuntu 26.04 LTS**(改动前的基础系统;回滚要另建快照体系,且本次用户明确不要 snapper 类工具);**Fedora 44 Workstation(传统可变系统)**:13 个月生命周期下仍需 btrfs + snapper + grub-btrfs 才能一键回滚,体系更脆;Debian 13(内核与驱动偏旧);CachyOS(滚动更新与"稳定"冲突) |
| 3.2 | 桌面环境 | **GNOME 50**(Silverblue 旗舰),Wayland 会话 | 与既有设计与 ublue 的 GNOME 变体验证最充分;KDE 对等替代是 Kinoite 44(Plasma 6.6.4)+ ublue 的 KDE NVIDIA 变体 | 非原子 KDE(Fedora KDE Spin):无部署级回滚;Kubuntu 类 LTS 桌面:本方案已不在 Debian 系 |
| 3.3 | 引导栈 | **GRUB2 + shim**,写入 `\EFI\fedora\`,**使用 Fedora 自己的 ESP** | 上游在 Secure Boot 下原生可用;官方签名链,无需自签;原子版的每个部署都要在 GRUB 菜单里可选 | **systemd-boot + UKI**:Anaconda 的 systemd-boot 支持不完整(上游 Bugzilla 2402975),且原子版的部署菜单依赖 GRUB;在 SB 下要自签,属新增风险。**rEFInd**:需改 `{bootmgr}` 路径(违反 I3)或额外引入一层。**自定义 Secure Boot 密钥**:改动签名链会新增风险(见 1.3) |
| 3.4 | ESP 布局 | **Windows 独占 2GiB + Fedora 独立 1GiB(两个 ESP)** | 上游与社区一致要求 Fedora 用**自己的** ESP 与 `/boot`,并明确不要让 Anaconda 使用 Windows 的 EFI 分区;I3 由结构保证;Windows 侧工具只认第一个 ESP 的习惯也不再被牵动 | **单个 2GiB 共用 ESP**:Anaconda 在已有系统/ESP 的盘上装 Silverblue 有已知失败(上游 `fedora-silverblue/issue-tracker#284`),且 I3 只能靠纪律;后续 Windows 更新可能重写共用 ESP 的 `\EFI\BOOT\` |
| 3.5 | 分区策略 | **整盘重排,一次分好** | 消除"缩容"这一整类事故(不可移动文件挡路、BitLocker 触发恢复、缩容上限不足) | 被否:已有系统上缩容(本方案不提供该分支;需要改尺寸就整盘重排) |
| 3.6 | Linux 容量 | 合计 **115GiB**:ESP-Fedora **1GiB** + `/boot` **1GiB**(ext4)+ root **≈113GiB** | 定位是"轻量远程 AI 开发 + 办公":文档类数据全部落在共享数据盘(3.16 / 5.3),不占 root;**`/boot` 必须独立**是原子版的硬要求(每个部署的内核与 initrd 都在此,部署切换才能工作) | 不单独分 `/boot`(把内核放 root 内):与 ostree 部署模型冲突,部署切换/回滚不可靠;root 140GiB 级(共享盘被压缩,收益不足);保留旧方案的"独立 15GiB 快照分区":原子版下无意义(回滚由部署承担) |
| 3.7 | 根文件系统 | **btrfs + ostree 部署**(`/home` 是到 `/var/home` 的符号链接) | 原子桌面的默认布局;部署级回滚由 ostree 承担,不需要文件系统层快照 | **ext4 + Timeshift**(旧方案:第三方 rsync 快照要吃掉数十 GiB);**btrfs 子卷 + snapper + grub-btrfs**(传统 Fedora 变体的方案:**已作废**,与部署模型重叠且更脆) |
| 3.8 | 交换空间 | **无 swap 分区**:zram(原子桌面默认带 `zram-generator`)+ swapfile 4GiB | 可随时调整、不动分区表、兼容任意文件系统 | swap 分区(尺寸一旦定死);休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下风险高) |
| 3.9 | 磁盘加密 | **不做** | TPM-FDE 需整盘且与双系统引导链测量冲突,官方仍标实验性质 | LUKS 口令(留给第 10 节变体) |
| 3.10 | Windows 激活 | **成熟 KMS 激活**:采用上游项目的 **Online KMS**(180 天周期 + 每 7 天自动续期任务),**不引入任何自建 KMS 服务** | 按需求定调(采用成熟 KMS,而非购买密钥或 HWID);KMS 走的是微软官方激活协议,可重复、可验证、可续期;自建 KMS 已放弃,因为它需要一台常态在线的主机,收益(离线自主)不抵维护成本 | **KMS38**:微软在 build 26100.7019 起彻底废弃该机制,且已被上游项目移除,对 Windows 11 24H2+ 无效。**自建 KMS 服务**:已彻底放弃,需求中已删除。**HWID / TSforge**:虽为上游推荐,但按需求不使用(仅作文档中的回退说明) |
| 3.11 | 文档粒度 | **步骤级**(做什么 + 关键命令 + 验证方式) | 按需求定调;命令级会引入版本敏感的冗余细节 | 命令级(逐条可复制但难维护);说明级(信息不足) |
| 3.12 | 多设备适配 | **参数化 + 厂商差异表**,`baseline/` 每台设备一份且不入库 | 面向"多台同规格设备"重复部署;同时避免公开仓库泄露具体机器信息 | 绑定单台机器(不可复用,且泄露序列号) |
| 3.13 | 数据迁移 | **不做** | 高价值但高风险(iGloo 的整套迁移链路包含凭据解密/再加密) | iGloo 式迁移(见第 11 节) |
| 3.14 | Linux 健壮性(R1/R2 改为**部署级**) | 九项措施:**R1 变更前固定当前部署**(`rpm-ostree pin` + 记录部署号)+ **R2 部署级回滚**(开机菜单选旧部署 或 `rpm-ostree rollback`,并**真做一次演练**) + 其余七项(救援介质、journald 持久化、OOM 防护、常开 SSH、保守更新策略、SMART、共享盘 `nofail`) | 目标是"不会因为一次升级或一块盘的问题而失去可用系统";原子版的回滚粒度比文件系统快照更强:整个 `/usr` 与内核一起回退,而 `/var` 与家目录**不回退**(用户数据不丢) | **snapper + grub-btrfs**(传统 Fedora 变体方案:**已作废**;额外维护一套快照工具链,且与 ostree 部署语义重叠);仅靠"重装"作为恢复手段(等于放弃回滚);休眠(与 NVIDIA + Wayland 冲突) |
| 3.15 | **Windows 系统盘隔离** | C: 只承载系统与程序(**200GiB**);数据、游戏库、下载与容器镜像独立到 **D: 数据分区(≈635GiB)**;已知文件夹(桌面/文档/下载/图片/视频/音乐)统一重定向到 D: | 崩溃时**只需格式化系统分区**即可原地重装,数据与另一边系统不受影响(见 4.8);与 Linux 侧"root / `/var` 与家目录分离"形成对称的隔离结构;C: 的容量需求变得可预测 | 单一大 C:(重装等于清空全部数据,与"原地重装"目标直接冲突) |
| 3.16 | **跨系统共享数据分区** | 整块 **D: 作为共享盘**:Windows 原生 NTFS 访问,Silverblue 侧以 **`ntfs3` 读写** 挂载(自动挂载、`nofail`);`D:` **不启用 BitLocker**;办公文件集中放在约定目录(如 `D:\Shared\`) | 满足"两个系统都能访问同一批文件、切换系统即可继续办公"的需求;选 NTFS 而非 exFAT 是因为 Windows 侧原生访问、且两者都支持;Linux 写 NTFS 的风险用"关 Fast Startup + 不加密 + 不动权限敏感工作流 + 关键目录备份"四项约束兜住 | exFAT 专用共享分区(无日志、断电易损,除兼容性外无优势);同机网络共享(两个系统不能同时开机,同机 SMB 无意义);云同步(依赖外网与配额,只能作为补充) |
| 3.17 | **显卡模式排障分支(MUX)** | 默认**混合模式 + PRIME offload**;若在混合模式下安装器或首启无法点亮(黑屏),走分支:BIOS 切到**独显直连**先拿到可用系统,再评估是否切回混合 | 评论区高频报障显示:部分笔记本(联想拯救者等)混合模式下装完启动不了,切到独显直连后解决;但独显直连有真实代价(所有进程占显存、续航变差),所以不能作为默认 | 把"独显直连"当默认(续航与显存双输,且日后要跑本地推理时显存不够);因驱动问题**降级发行版**(支持期与硬件兼容双输,正确做法是在 ublue 的镜像/分支间切换或换内核) |
| 3.18 | **内核与驱动更新策略收紧(原子版语义)** | `rpm-ostreed-automatic` 的 `AutomaticUpdatePolicy` 设 **check / download**(只检查与下载,**不自动应用、不自动重启**;是否 `stage` 由卡决定并写清后果);**任何分层安装或 `rebase` 之前先 `rpm-ostree pin` 当前部署** | 评论区高频报障:自动更新内核后与显卡驱动不适配,进不了桌面;内核/驱动是这台机器上最大的可恢复风险点,不应无人值守执行。原子版下"应用"= 产生新部署,仍需一次重启才生效 | 全部自动更新(含应用与自动重启)—— 对 NVIDIA 混合显卡机器等于把"能否进桌面"交给无人值守任务 |
| 3.19 | **引导菜单阶段黑屏的处置** | 原子版的 GRUB 菜单由 ostree 生成(每行一个部署,带版本与时间戳,条目更多);日常切换优先用一次性 `BootNext`/厂商菜单键,不依赖"看得见菜单";提供 `GRUB_TERMINAL=console` 类条件项(实施时核实原子版下的落点) | 评论区有实例:装完独显驱动后每次开机在引导菜单阶段黑屏,但键盘仍可操作(数上下键能进 Windows);此时菜单黑屏不等于系统坏了,需要明确处置手段 | 把"引导菜单黑屏"当作系统损坏并重装(实际只需换终端模式或改用 BootNext) |

### 3.20 已验证与待验证的事实

| 事实 | 状态 | 来源等级 |
|---|---|---|
| Fedora 44 Silverblue 于 2026-04-28 GA,支持到约 2027-06(13 个月);GNOME 50;原子(ostree)桌面 | 已确认 | 高 |
| Kinoite 44 = 原子 KDE(Plasma 6.6.4),与 Workstation 同代 | 已确认 | 高 |
| 原子桌面的一键回滚 = 开机菜单选旧 deployment 或 `rpm-ostree rollback`;GRUB 列出各部署 | 已确认(Fedora 官方"Updates, Upgrades & Rollbacks") | 高 |
| 发行版升级 = `rpm-ostree rebase`(前置 pin 当前部署) | 已确认(Fedora Magazine) | 高 |
| 双系统需**独立** `/boot/efi` 与 `/boot`,且不应让 Anaconda 使用 Windows 的 ESP | 官方文档 + Fedora Discussion | 中高 |
| Anaconda 在已有 ESP 的盘上装 Silverblue 可能失败(`fedora-silverblue/issue-tracker#284`,自 F34 起) | 上游 issue 存在已确认;**F44 是否已修需在参考设备实测复核** | 中 |
| `rpm-ostree install` 时 akmods 不签名(`#499`);`akmod-nvidia` 会卡住内核升级(`#632`) | 已确认(上游 issue) | 高 |
| ublue NVIDIA 变体镜像内模块**已预签名**,配一次性 MOK 注册(`ujust enroll-secure-boot-key`,上游 MOK 密码 `universalblue`) | 待核实 | 中高(来源:文档与论坛)—— **镜像名、分支、`ujust` 任务名、MOK 密码均须在实施时复核** |
| `/var`(以及作为其子目录的 `/home`,`/home` 是符号链接)不属于部署,**不随回滚回退** | 已确认(ostree 部署模型) | 高 |
| `rpm-ostreed-automatic` 策略位于 `/etc/rpm-ostreed.conf`(`AutomaticUpdatePolicy = none/check/download/stage`) | 已确认(Fedora 文档) | 高 |
| 系统级工具用 `rpm-ostree install` 分层安装,**每次分层需重启**;GUI 应用优先 Flatpak;开发环境用 `toolbox`/`distrobox` | 已确认(官方原子桌面文档) | 高 |
| Fedora 内核同样包含 `ntfs3`,可读写 NTFS;但无 POSIX 权限语义(挂载时以固定 uid/gid/umask 呈现) | 已确认;需在挂载选项与工作流上适配(见 5.3) | 高 |
| 同盘两个 ESP 的固件支持:官方未承诺,社区实践可行 | **待实测**(列入 A 组验收) | 中 |
| Windows 11 ISO:微软不发布镜像 SHA256;Fedora ISO:官方发布 `CHECKSUM` 文件可比对 | 已确认 | 高 |
| Online KMS 激活周期为 180 天,需每 7 天联系 KMS 主机自动续期 | 已确认(上游文档) | 高 |
| 部分厂商笔记本固件**只从第一块盘引导**(用户报告:惠普官方明确不支持从第二块盘启动) | 社区报告;作为双盘分支的硬约束写入厂商差异表 | 中 |
| 装完独显驱动后,部分机器在**引导菜单阶段黑屏**(键盘仍可用) | 社区报告(2026 年的实例);处置见决策 3.19 | 中 |

### 3.21 生命周期与发行版升级

| 项 | 决定 |
|---|---|
| 生命周期 | Fedora 44 支持到约 **2027-06**;此后必须迁移到受支持的分支 |
| 升级方式 | **`rpm-ostree rebase`** 到目标分支(stock Silverblue 用 `fedora:fedora/45/x86_64/silverblue` 形式;ublue 变体用其对应分支,**分支名须实施时核实**) |
| 前置 | **先 `rpm-ostree pin` 固定当前部署**并记录部署号 |
| 后置 | 重启后复检:会话仍是 Wayland、`nvidia` 模块仍加载且签名有效、桌面可用、`rpm-ostree status` 的镜像来源与版本符合预期 |
| 失败处置 | 不满足后置判据 → 开机菜单选回被 pin 的部署(或 `rpm-ostree rollback`) |
| 支持期取舍 | 13 个月(比 LTS 短)换来更新的内核与桌面;升级被写成正式卡,不再是"怕动"的操作 |

### 3.22 原子版语义(本次修订新增,必须写进手册)

| 语义 | 内容 | 对文档/脚本的影响 |
|---|---|---|
| `/usr` 只读 | 系统本体由 ostree 管理,不能就地 `dnf install`;系统级工具必须 `rpm-ostree install` 分层 | 包管理脚本从 `dnf` 语义改为"分层安装 + 需重启";`hardening.sh` / `set-remote-health.sh` 等同步改写 |
| 分层安装需重启 | 每次分层产生新部署,**必须重启**才生效 | 卡的 `看到:` 要区分"命令成功"与"重启后生效";故障矩阵补"忘了重启"一条 |
| 应用分层 | GUI 应用优先 **Flatpak**;开发环境走 **`toolbox`/`distrobox`** | 文档给出口径,避免把 GUI 应用塞进系统层 |
| `/var` 与家目录不属于部署 | `/var/home` 是真正的家目录,`/home` 是指向它的符号链接;**回滚不回退 `/var`** | 这是"回滚不丢用户数据"的依据,也是重装 root 时"数据是否保留"的关键前提(见 4.8 办法二) |
| 更新即新部署 | 更新/分层/rebase 都产生新部署;旧部署按保留策略与 `rpm-ostree cleanup` 管理 | 新增 `dbk-rollback.sh` 负责列出部署、pin/unpin、回滚与回滚后复检 |
| 自动更新的落点 | `rpm-ostreed-automatic`(`/etc/rpm-ostreed.conf`) | `set-updates.sh` 改写 |

### 3.23 三轨道(W / L / D)结构(本次修订新增)

| 项 | 决定 |
|---|---|
| 内容 | 三条可独立执行的轨道 + 一个共用底座,定义见 1.4 |
| 目的 | 满足"任一系统可单独安装";让"简化"落在单系统场景与文档组织上 |
| 边界 | **不砍任何既有机制**(MOK 注册、`ntfs3` 共享盘、每卡一脚本、双模式 CLI、C1–C9 自检、A–F 验收、KMS 脚本激活全部保留) |
| 文档影响 | 手册按轨道重排(见第 4 节的文档映射),双系统专属内容收敛为 4 张增量卡 |

---

## 4. 分层结构

每个阶段 = 目的 + 输入 + 动作 + **产物** + 完成判据。产物缺失即视为该阶段未完成。

阶段到手册文档的映射(按轨道重排;本次修订后**手册 8 份 + 1 份入口页**,原 11 份按轨道合并,并新增"分盘"前置章节):

| 阶段 | 轨道 | 手册文档 |
|---|---|---|
| 入口(非流程) | 共用 | [docs/00-overview.md](../00-overview.md)(目标、四条不变量、参数表、三轨道地图;不写卡) |
| L0 共用底座 | 共用 | [docs/01-firmware.md](../01-firmware.md)(底座卡:固件设置 / 做两个安装介质 / 核对目标盘 / 落 L0 产物) |
| 分盘(安装前的前置章节) | 共用(W/L/D 三条轨道各自的分盘方式) | `02-partitioning.md`(本次新增:02-1 分盘总则与三种轨道的目标布局 + 02-2 轨道 W 分盘 / 02-3 轨道 L 分盘 / 02-4 轨道 D 分盘;值表:8 项分区目标值) |
| L1 + L2 | W(D 轨道也要) | [docs/03-windows.md](../03-windows.md)(Windows 全新安装与激活)+ L2 预检与基线闸门卡(原 `03-preflight.md` 并入;两者都在 Windows 侧、且必须在同一会话内连续完成)。本文档由 `02-windows.md` 改名而来:分盘抽为独立前置章节 `02-partitioning.md` 后,轨道 W 的卡整体改号为 03-K(9 卡) |
| L3 | L | `04-silverblue.md`(原 `04-ubuntu.md` 的改名目标;Silverblue 安装) |
| L4 | L + D | [docs/05-first-boot.md](../05-first-boot.md)(首启收敛与健壮性;其中"共享盘挂载""家目录重定向"两张卡是 D 轨道的共存增量) |
| L5 | D | [docs/07-rescue.md](../07-rescue.md)(退役与救援;原 `06-decommission.md` 并入) |
| 验收 | 全部 | [docs/08-verification.md](../08-verification.md) |
| 风险与速查 | 全部 | [docs/10-faq.md](../10-faq.md)(症状卡 + 阶段风险速查;34 条风险总表保留在第 9 节) |

| 阶段 | 名称 | 目的 | 产物 | 完成判据 |
|---|---|---|---|---|
| **L0** | 装机前准备 | 把固件与介质调成目标状态 | `baseline/00-firmware.md` | 固件设定值与介质校验值记录齐全 |
| **L1** | Windows 全新安装 | 整盘分区一次定稿 + 系统 + 激活 + 预留 115GiB | `baseline/01-partitions.txt`、`01-activation.md`(分区表与激活状态) | 分区表与目标布局一致(含 115GiB 未分配);激活完成;Fast Startup 与休眠已关 |
| **L2** | 预检与基线 | 只读体检 + 建立可回滚基线 | `baseline/02-preflight-report.md`、`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt` | 报告结论为"允许进入 L3"(无红项) |
| **L3** | Silverblue 安装 | 装 Linux 且不侵犯 Windows 引导 | `baseline/03-efi-layout.txt` | Silverblue 可启动;两个 ESP 各自完整且互不干扰;`\EFI\Microsoft\` 与基线一致;`BootOrder` 首项仍为 Windows |
| **L4** | 首启收敛 | 驱动(rebase + MOK)、Wayland、挂载、时间、蓝牙、分层包 | `baseline/04-first-boot.md`、`04-robustness.md`(首启收敛与健壮性核对) | 验收 B 组与 F 组全绿 |
| **L5** | 退役与救援 | 安全撤除与故障恢复 | [checklists/rollback.md](../../checklists/rollback.md) | L5 流程可执行(参考设备需真跑一次) |

### 4.1 L0 装机前准备

- 固件:SATA 操作模式设为 **AHCI / NVMe**(关闭 VMD 或 RAID On)、**Secure Boot 保持开启**、Fast Boot 关闭;
- 介质:Windows 11 官方安装 U 盘;**Fedora 44 Silverblue 官方安装 U 盘**(或 Ventoy 多 ISO);介质校验按各官方站点发布的校验值(Fedora 有官方 `CHECKSUM` 文件;Windows ISO 官方不发布镜像哈希,只做"官方下载域 + 官方安装器校验");
- **关键点**:VMD 必须在安装 Windows **之前**关闭。若 Windows 已按 RAID On 装好再关闭,系统将无法启动,需先预置存储驱动再进安全模式完成切换(该路径作为附录分支,不属于本方案主路径)。

### 4.2 L1 Windows 全新安装

- 整盘重排:ESP-Windows 2GiB -> MSR 16MiB -> **Windows 系统 C: 200GiB** -> **Windows 数据 D: ≈635GiB** -> **为 Fedora 预留 115GiB 未分配空间** -> WinRE;
- **`templates/partitions.txt` 不变**:预留仍是"D: 之后一段 115GiB 未分配";L3 再在这段空间里切出 Fedora 的 ESP 1GiB + `/boot` 1GiB + root ≈113GiB(见 5.1)。**该模板的操作逻辑(预留 115GiB)不变,但注释文本仍描述旧设计**:第 1 段写"Windows 与 Ubuntu 共用 ESP"、第 5 段写"L3 的 root 100GiB + Snapshot 15GiB"、`D:` 段写"Ubuntu 侧 ntfs3 读写",与 3.4/3.16/5.1 冲突,**须由脚本任务把注释同步为"两块 ESP + Fedora 侧三块分区(ESP 1GiB + `/boot` 1GiB + root 113GiB)"**;
- **系统盘隔离**:C: 只放系统与程序;桌面/文档/下载/图片/视频/音乐等**已知文件夹、游戏库与容器镜像全部重定向到 D:**。所以"崩溃后原地重装"只需格式化 C:,数据与 Linux 侧均不受影响(见 4.8);
- ESP-Windows 必须**预建**(Windows 安装界面无法把自动创建的 100MB ESP 改成 2GiB),因此使用 `diskpart` 预建分区表;
- 安装完成后立即:关闭 Fast Startup 与休眠文件、完成脚本激活、记录激活状态;
- 风险提示:Windows 安装程序对 WinRE 分区的放置有版本敏感性,若它把恢复分区放进预留空间,记录偏差并据实调整(**两块 ESP 与 Fedora root 的尺寸不允许被削减**)。

### 4.3 L2 预检与基线(硬闸门)

- 只读体检:BootOrder 与固件启动项、ESP 目录树与剩余空间、BitLocker 状态、存储控制器模式、Fast Startup/休眠、磁盘布局;
- 基线备份(**在 L2 内生成**):ESP 文件树备份 + 清单 -> `baseline/02-esp-backup/`(块级整块镜像可选,不属主路径——Windows 原生无 `dd`);`bcdedit /enum firmware` 固件启动项快照 -> `baseline/02-firmware-entries.txt`;分区快照 -> `baseline/02-partitions.txt`。产物名前缀取所在阶段号;
- **注意(L2 备份的边界)**:此时 Fedora 尚未安装,`02-esp-backup/` **只覆盖 Windows 的那块 ESP**,**不含** `\EFI\fedora\`,因此**不能用来还原 Fedora 引导**。Fedora 引导的还原来源有两处(L5 退役备份里的 `\EFI\fedora\`;或在 Fedora live 环境重装引导组件后 `efibootmgr` 补条目并断言 `BootOrder` 首位仍是 Windows Boot Manager),两处的唯一定义点在 `07-rescue.md` 的救援流程里;
- 基线复核:复核 L1 记录的分区表(`baseline/01-partitions.txt`)与激活状态(`baseline/01-activation.md`)未被后续操作改变;
- **闸门规则**:存在红项 -> 禁止进入 L3;存在黄项 -> 记录后带风险继续。

### 4.4 L3 Silverblue 安装

- **先手工预建 Fedora 的三块分区**(在 L1 预留的 115GiB 未分配空间里切出):**ESP-Fedora 1GiB(FAT32 / EFI System)** + **`/boot` 1GiB(ext4)** + **root ≈113GiB(btrfs)**;
- 安装器(Anaconda)里选择**手动分区**,**只做"指定挂载点"**,不让它重排分区表、不让它新建或改动其它分区:ESP-Fedora -> `/boot/efi`(格式化)、`/boot` -> `/boot`(格式化)、root -> `/`(格式化);
- **不让安装器动 Windows 的 ESP**(I3;上游明确"不要让 Anaconda 使用 Windows 的 EFI 分区");
- 不创建 swap 分区;首启后再配置 zram 与 swapfile;
- 引导写入 `\EFI\fedora\`(安装器默认;条目显示名须实测核实),**期间不改动 `BootOrder`**;
- Secure Boot 全程保持开启;
- **已知失败路径**:Anaconda 在已有系统/ESP 的盘上装 Silverblue 可能"在写 EFI 引导配置之前中止"(`#284`)。处置:① 本节的手工预建 + 只指定挂载点;② 若仍失败,按 `07-rescue.md` 在 live 环境手工修;③ 最坏情况退回轨道 W,损失可控(L2 基线可用)。

### 4.5 L4 首启收敛

| 项目 | 做法 | 回滚点 |
|---|---|---|
| 显卡驱动 | 安装后 **`rpm-ostree rebase` 到 ublue 的 NVIDIA 变体**(镜像名/分支**待核实**)+ **一次性 MOK 注册**(`ujust enroll-secure-boot-key` 任务名待核实、上游 MOK 密码待核实);镜像内模块已预签名 | `rebase` 回 stock Silverblue(部署级);保留 nouveau 作为兜底 |
| 显示策略 | 集成显卡主显示 + 独显 PRIME offload(独显单显卡设备跳过) | 恢复默认 PRIME 模式 |
| 共享数据分区挂载 | `ntfs3` **读写**挂载 `D:`,固定 `uid/gid/umask` + `windows_names` + `nofail` + `noatime`;`fstab` 写错时带 `nofail` 不阻断启动 | 改成只读挂载或移除该行 |
| 家目录数据重定向 | 用 `~/.config/user-dirs.dirs` 把**文档/下载/图片/桌面**指向共享盘;`~/.config`、`~/.ssh`、代码仓库**留在本地**(NTFS 无 POSIX 权限语义) | 改回默认目录即可 |
| 时间 | `RTC in local TZ: no`(Linux 用 UTC),Windows 侧可配合 `RealTimeIsUniversal=1` | 可逆 |
| 蓝牙 | 同步两系统配对密钥(上游 `bt-keys-sync`,依赖 `chntpw`);按上游建议"以 Windows 侧密钥为准",不做反向写入 | 注册表有备份,可还原 |
| 系统级工具 | 用 `rpm-ostree install` 分层安装,**每次分层需重启**;GUI 应用优先 Flatpak;开发环境走 `toolbox`/`distrobox` | `rpm-ostree uninstall` 该层 |
| 固件 | `fwupd` 识别设备即可;固件更新仍优先在 Windows 侧完成 | 无 |
| 回 Windows | 提供一键回 Windows 的入口(BootNext 或固件菜单) | 无 |

### 4.6 L5 退役与救援

退役流程顺序不可更换:

```
1. 在 Silverblue 中把 BootOrder 首项改回 Windows Boot Manager
2. 备份当前 NVRAM 与两块 ESP 的现状(最后一道保险;此备份含 \EFI\fedora\)
3. 重启进 Windows,用「磁盘管理」删除 Fedora 的三块分区(ESP-Fedora / /boot / root;确认引导已归位后再删)
4. 清理 NVRAM 中残留的 fedora 条目
5. 可选:把腾出的空间扩展进**相邻分区**(目标布局下未分配空间紧邻 D:,C: 不相邻不可扩)
```

**明确禁止**:先格式化 Linux 分区再修引导。

### 4.7 L4 附加:**Silverblue 健壮性设计(防崩溃)**

目标是"不会因为一次升级、一个驱动或一块盘的问题而失去可用系统"。九项措施,每项都对应一个可回滚点:

| # | 措施 | 做法 | 回滚点 |
|---|---|---|---|
| R1 | **变更前固定当前部署** | 在执行分层安装、`rebase`、发行版升级之前 `rpm-ostree pin` 当前部署并记录部署号;平时不额外固定 | 选回被固定的部署 |
| R2 | **部署级回滚** | 更新/分层/rebase 后桌面起不来:开机菜单选上一个部署,或 `rpm-ostree rollback`;由 `dbk-rollback.sh` 列出部署、pin/unpin、回滚并做回滚后复检;参考设备必须**真做一次演练** | 部署列表里的任一新旧部署 |
| R3 | **多部署保留 + 一次性启动** | 每个部署自带内核与 initrd(在独立 `/boot`),GRUB 菜单列出各部署;固件层 `BootNext` 与部署选择互补(不违反 I2) | 选旧部署 / `BootNext` |
| R4 | **永久救援介质** | 常备 Fedora 安装 U 盘(兼作 live 环境),并从第一台参考设备起记录"已验证可用"标记 | 从 U 盘进入 live 环境修复 |
| R5 | **崩溃可观测** | 启用 journald **持久化**(`/var/log/journal`);`/var` 不属于部署,日志**不随回滚丢失**;自建日志目录 `/var/log/dbk/` | 无(仅提升可诊断性) |
| R6 | **OOM 与内存压力防护** | 核对 zram 已启用(原子桌面默认带 `zram-generator`)+ swapfile 4GiB;确认 `systemd-oomd` 处于启用状态 | 调整 zram/swapfile 大小 |
| R7 | **常开 SSH 救援通道** | 启用 `sshd`:桌面挂死时仍可从另一台机器登录排障(对"远程开发"定位尤其关键;`/etc` 是持久化的,启用后跨部署保留) | 关闭服务 |
| R8 | **保守更新策略** | `rpm-ostreed-automatic` 只做 check/download(**不自动应用、不自动重启**,见 3.18);分层与 `rebase` 前必须先 R1 固定部署 | 选回被固定的部署 |
| R9 | **磁盘健康监控** | 分层安装 `smartmontools`(`smartd`)并确认日志告警生效;文件系统校验沿用发行版默认定时任务(实施时核对 `btrfs scrub` 是否已启用) | 无(提前发现硬件故障) |

**明确不做的**,以及原因:休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车)、**`snapper` / `grub-btrfs` / btrfs 快照回滚**(与部署级回滚重叠且更脆,见 3.7 与 3.14)、自定义 Secure Boot 密钥(改动签名链会新增风险)。

### 4.8 L5 附加:崩溃后**在原系统盘重装**的两法

两法共用前提:`baseline/` 产物齐全可用(分区表、ESP 镜像、固件启动项快照),救援 U 盘在位。**先判断崩溃在哪一层**——若只是引导层损坏,不要重装,先走 4.6 的引导复原。

#### 办法一:Windows 崩溃 -> 只重装 Windows(仅格式化 C:)

| 步骤 | 要点 |
|---|---|
| 1 | 用官方 ISO 引导,进入"自定义安装" |
| 2 | **只格式化 C:**;数据分区 D:、Fedora 的三块分区与两块 ESP 一律不动。逐分区核对,**禁止"删除所有分区"** |
| 3 | 安装程序只在**它自己那块 ESP**(第一块,ESP-Windows)上重建 `\EFI\Microsoft\` 与 BCD,并可能覆盖该 ESP 上的 `\EFI\BOOT\bootx64.efi`(属正常);**Fedora 的独立 ESP 不受影响** |
| 4 | 首次进桌面:关 Fast Startup 与休眠、重新完成 KMS 激活、恢复已知文件夹到 D: 的重定向 |
| 5 | **复查四条不变量**:BootOrder 首项、`\EFI\Microsoft\` 内容、`{bootmgr}` path、fedora 条目仍在;用厂商菜单键验证 Silverblue 仍可启动 |
| 风险 | 误格 D: 或 Fedora 分区 -> 灾难性;Windows 可能新建恢复分区并占用预留空间(记录偏差) |

#### 办法二:Silverblue 崩溃 -> 只重装 Silverblue(只格式化 root)

| 步骤 | 要点 |
|---|---|
| 1 | 用 Fedora 安装 U 盘引导,**动手前先把 `/var/home` 备份到共享盘(D:)**(见下方风险行) |
| 2 | Anaconda 里选手动分区:**只把 root 挂载点(≈113GiB btrfs)标记为格式化并挂 `/`**;**ESP-Fedora(挂 `/boot/efi`)与 `/boot` 绝不勾选格式化**;Windows 各分区一律不动 |
| 3 | 安装写入 `\EFI\fedora\`(与 Windows 引导并存),期间不改 `BootOrder` |
| 4 | 首启:按 4.5 与 4.7 的清单重放驱动(rebase + MOK)、挂载、时间、蓝牙与健壮性配置;`rpm-ostree status` 确认新部署 |
| 5 | 复查四条不变量;把 `/var/home` 的备份按需取回 |
| 风险 | **误格 ESP-Fedora 或 `/boot`** -> Fedora 引导丢失(可在 live 环境重装引导组件修复);**误格 ESP-Windows** -> 同时破坏 Windows 引导,这是全流程最危险的一步(ESP 镜像可复原,但必须先有基线)。另:用户数据在 `/var`(家目录是 `/var/home`)内,**能否在重装 root 时一并保留取决于安装器对 btrfs 子卷的处理 —— 该行为待核实**,因此第 1 步的备份是硬要求,不做"数据一定还在"的假设 |

**第三选择(不是重装)**:引导层损坏而系统分区完好 -> 按 `07-rescue.md` 的救援流程处置(ESP 镜像还原 + `bcdboot` 重建 Windows 引导;或 live 环境修复 Fedora 引导)。

---

## 5. 分区表与设备参数

### 5.1 目标分区表(标称 1TB 的 NVMe;下表按 **1024GB 型号 = 实际可用约 953.7GiB** 制定,合计 = 953.016GiB)

| 序号 | 分区 | 大小 | 类型 | 挂载 / 用途 |
|---|---|---|---|---|
| 1 | ESP-Windows | **2GiB** | EFI System(FAT32) | **只给 Windows**;只放 `\EFI\Microsoft\` 与 `\EFI\BOOT\` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 C: | **200GiB** | NTFS | 系统与程序;**原地重装时唯一被格式化的分区** |
| 4 | Windows 数据 D: | **≈635GiB** | NTFS | 游戏库、下载、文档、容器镜像;已知文件夹重定向的目标;**双系统共享分区(3.16 / 5.3)** |
| 5 | **ESP-Fedora** | **1GiB** | EFI System(FAT32) | Silverblue 独立 ESP;只放 `\EFI\fedora\`;挂 `/boot/efi` |
| 6 | **`/boot`** | **1GiB** | ext4 | 原子版**必须独立**;每个 deployment 的内核与 initrd 在此 |
| 7 | **Fedora root** | **≈113GiB** | btrfs | `/`;ostree 部署 + `var` 子卷(`/home` 是到 `/var/home` 的符号链接) |
| 8 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈ 953GiB:2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1。Fedora 侧合计 **115GiB**(= 1 + 1 + 113),与决策 3.6 一致;**共享数据盘 ≈635GiB,约占全盘三分之二**。

**容量偏离分支(必须执行)**:上表按 1024GB 型号(可用 953.7GiB)制定。若目标设备是 **1000GB 型号(可用仅 931.3GiB)**,则本表合计 953.016GiB **装不下**,须把 **`D:` 从 ≈635GiB 减到 ≈613GiB**(其余七项一律不动:Fedora 侧 115GiB、`C:` 200GiB、两块 ESP、`/boot`、WinRE),并把该偏差写进 `baseline/` 与参数表 `DISK_SIZE`;`02-partitioning` 的 `02-1`/`02-3`/`02-4` 卡与 `check-partition-layout.ps1` 的期望值同步使用调整后的数值。**不得为了塞进上表而削减 Fedora 侧那 115GiB 或关闭 115GiB 预留**。

### 5.1.1 为什么把 Windows 也拆成两个分区

单一大 C: 下,"原地重装 Windows"等于连数据带游戏一起清空;拆开之后,C: 是**唯一可抛弃的分区**,D: 是**唯一需要长期保护的分区**。这同时让容量规划变简单:C: 只需装得下系统与程序(实测经验值 60–90GiB 用量,给到 200GiB 是为多年升级留余量),剩余全部给数据。

需注意的代价:部分安装器默认装到 C:,需手动改路径;重装后必须重新做一次已知文件夹重定向(L1 与 4.8 办法一的第 4 步均已列为必做项)。

### 5.2 设备参数表(每台设备部署前填写)

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

对照说明:Linux 侧参数由旧方案的"`ROOT_SIZE` 100GiB + `SNAPSHOT_SIZE` 15GiB"改为"`FEDORA_ESP_SIZE` 1GiB + `BOOT_SIZE` 1GiB + `ROOT_SIZE` ≈113GiB"(快照分区参数不再存在)。

### 5.3 跨系统共享数据分区(两个系统都能访问的磁盘)

**结论:有,就是 Windows 数据分区 `D:`(≈635GiB,NTFS)。** Windows 侧原生访问,Silverblue 侧以 `ntfs3` **读写**挂载。办公文件集中放在约定目录(例如 `D:\Shared\`)下,切系统就能接着干,不需要拷贝或传输。

前置条件(缺一不可):

| # | 条件 | 原因 |
|---|---|---|
| 1 | Windows 关闭 Fast Startup 与休眠 | 否则 NTFS 处于"混合关机"的脏状态,Linux 挂载会失败甚至损坏 |
| 2 | `D:` **不启用 BitLocker / 设备加密** | 加密后 Linux 无法直接读写,需 dislocker 之类工具,复杂度不成比例 |
| 3 | 挂载选项固定 uid/gid/umask 并使用 `windows_names` | `ntfs3` 没有 POSIX 权限位;`windows_names` 阻止 Linux 侧创建 Windows 非法文件名 |
| 4 | 不把依赖 POSIX 语义的工作流放在共享盘 | 符号链接、硬链接、大小写敏感重命名、权限位相关脚本在 NTFS 上都不可靠 |

推荐挂载参数(实现时落到 [templates/fstab.snippet](../../templates/fstab.snippet)):

```
UUID=<D: 分区 UUID>  /mnt/shared  ntfs3  rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime  0 0
```

用法约定(与决策 3.6 的 root 容量直接相关):Silverblue 侧用 `~/.config/user-dirs.dirs` 把**文档 / 下载 / 图片 / 桌面**指向共享盘对应目录,文档类数据因此完全不占 root;**不要**把 `~/.config`、`~/.ssh`、代码仓库或其他依赖 POSIX 权限语义的工程放到共享盘上。

风险与缓解:

| 风险 | 缓解 |
|---|---|
| Linux 写入导致文件损坏 | 关键目录保留第二份备份(云端或外置盘);避免在 Linux 侧批量重命名/移动大目录 |
| "两系统同时写" | 结构上不可能(同一时刻只运行一个系统);但**绝不要**在 Windows 处于休眠状态时让 Linux 挂载共享盘 |
| 权限与文件名语义差异导致工具报错 | 文档中列出"不要在共享盘上做的事"清单;代码仓库与需权限语义的工程留在 Linux 本地 root |
| Windows 索引/预览进程锁文件 | 遇到"设备忙"时先在 Windows 侧关闭相关进程或索引再操作 |

验收(纳入第 8 节 B 组):**双向可见性测试**——在 Windows 写入标记文件后切到 Linux 读取,反向再测一次,内容必须一致。

---

## 6. 阶段产物与交接规则

1. **没有产物的阶段视为未完成**,不得进入下一阶段。
2. **`baseline/` 不入库**(含单机私产:分区表、ESP 镜像、固件启动项、激活状态);仓库内只保留结构与命名规范。每台设备一个子目录。
3. **L2 是唯一硬闸门**;红项禁止推进,黄项记录后继续。
4. **L1 与 L2 必须在同一次会话内连续完成**:中途若 Windows 发生更新,基线即失效。
5. **L3 期间不改动 `BootOrder`**(I2 的落地方式),且**不让安装器动 Windows 的 ESP**(I3 的落地方式)。
6. **L4 任何驱动/分层/升级变更之前**:先确认"回 Windows 的入口"可用,并先 `rpm-ostree pin` 当前部署(R1)。

---

## 7. 故障处理与回滚矩阵

| 阶段 | 症状 | 立即动作 | 回滚 |
|---|---|---|---|
| L0 | 介质校验值不符 | 重制安装介质 | 无副作用 |
| L1 | 分区表与计划不符 | 此时无数据,重装重分 | 重来 |
| L1 | 激活未成功 | 不阻塞:L1 与 L3 解耦,先推进,后续单独处理 | 后续处理 |
| **L2** | BitLocker 已启用 | 备份 48 位恢复密钥 -> 挂起保护 -> 复检 | 恢复保护 |
| **L2** | 存储控制器仍为 RAID/VMD | 停在 L2,回 L0 改固件;若 Windows 已装好才改,走附录分支(驱动预置 + 安全模式) | 改回 RAID On |
| L3 | 安装器看不到磁盘 | 回 L0 核查控制器模式 | 无副作用 |
| L3 | 重启直接进 Windows | 用厂商启动菜单键手动选 fedora(一次性);核对固件条目列表 | 无需回滚 |
| L3 | **Anaconda 在写 EFI 引导配置前中止**(已有系统/ESP 的盘) | 按 4.4 的手工预建 + 只指定挂载点重来;仍失败则按 `07-rescue.md` 在 live 环境手工修 | 退回轨道 W(Windows 单系统) |
| L3 | 两个 ESP 中只有一个被固件识别 | 记录为偏离项;按第 10 节评估"共用 ESP 分支" | 无副作用(记录) |
| L3 | 停在 `grub>` / `grub rescue>` | ① `ls` 找分区 -> `set prefix` -> `insmod normal` -> `normal`;② 直接回 Windows:`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` -> `chainloader` -> `boot` | 基线回滚(ESP 镜像) |
| L3 | Secure Boot 拒载 | 核查 `mokutil --sb-state`;先完成 4.5 的 MOK 注册,不在 L3 引入自签 | 无副作用 |
| L4 | 装驱动(rebase)后黑屏 / 闪烁 | 开机菜单选回上一个部署;或在 GRUB 里临时切 TTY 检查 | **部署级回滚**(R2) |
| L4 | 模块签名被拒(`nvidia` 不加载) | `mokutil --list-enrolled` 核对;重跑 `ujust enroll-secure-boot-key`(任务名待核实)并重启;`modinfo -F signer nvidia` 复核 | `rebase` 回 stock(用 nouveau 兜底) |
| L4 | `fstab` 写坏导致进不去系统 | GRUB 中追加 `systemd.unit=emergency.target` | 模板已含 `nofail` |
| L4 | 时间错乱 / 蓝牙反复重配对 | RTC=UTC(或 Windows `RealTimeIsUniversal=1`);密钥同步脚本 | 均可逆 |
| L4 | **分层安装后命令仍找不到**(忘了重启) | 重启使新部署生效;`rpm-ostree status` 确认当前部署 | 无副作用 |
| L4 | 升级(`rebase`)后系统不可用(内核/驱动) | 开机菜单选被 pin 的旧部署 | **部署级回滚**(R1 + R2) |
| L4 | 桌面无法进入 | 用另一台机器 SSH 登录排障(R7);必要时开机菜单选旧部署 | 选旧部署 |
| L4 | KMS 激活到期未续期 | 检查续期任务与 KMS 主机可达性,手动触发一次续期 | 重新执行一次在线激活流程 |
| L5 | **Windows 系统分区损坏** | 走 4.8 办法一:只格式化 C: 重装 | D: 数据、两块 ESP 与 Fedora 侧不受影响 |
| L5 | **Silverblue root 损坏** | 走 4.8 办法二:只格式化 root 重装(先备份 `/var/home`) | `/var` 与 Windows 侧不受影响(前提是已备份) |
| L5 | 引导层损坏而系统分区完好 | **不要重装**:按 `07-rescue.md` 处置(ESP 镜像还原 + `bcdboot` 重建 / live 修复 Fedora 引导 + NVRAM 清理) | 基线回滚 |
| L3 | U 盘启动或安装器黑屏 | 在引导菜单按 `e`,给内核行加 **`nomodeset`** 临时应急;**能进系统后立即装好显卡驱动并移除该参数**——它与 Wayland 冲突(Wayland 需 KMS),只是应急手段 | 移除参数 |
| L3 | 手动分区界面看不到"引导器位置"选项 | 这是 Anaconda 的**正常行为**:本方案**不依赖**安装器写 Windows 的 ESP,改用 4.4 的"手工预建 Fedora 分区 + 只指定挂载点";确认安装器没有把 Windows ESP 当目标即可继续 | 无 |
| L3 | 混合模式下安装器/首启黑屏 | 按决策 3.17 走 MUX 分支:BIOS 切独显直连拿到可用系统,再权衡是否切回混合 | 切回混合模式 |
| L4 | 装完独显驱动后,每次开关机在引导菜单阶段黑屏(键盘仍可用) | 按决策 3.19 处置:换终端模式;日常切换改用 BootNext/厂商菜单键 | 移除该配置行 |
| L4 | 内核/驱动更新后黑屏或不进桌面 | 更新策略已收紧(3.18);若已发生:开机菜单选被 pin 的旧部署 | 部署级回滚 |
| 任意 | **两个系统一起**异常、频繁死机/蓝屏 | **先按硬件问题排查**(内存测试、SMART、温度、电源),不要归因于"双系统互相影响"——两系统运行期不共享状态,只有引导层会互相干扰 | 无 |
| 任意 | 曾经长按电源强制重启过 | 下次启动前先做一次文件系统检查(btrfs 用 `btrfs scrub`,或从 live 环境检查);以后用 **REISUB(SysRq)** 代替长按电源 | 无 |

### 7.1 周期性巡检

每次 Windows 大版本更新或累积更新后,重跑基线核对:**四项**(与 `verify-baseline.ps1` 的输出一一对应):

1. `BootOrder` 首位仍是 Windows Boot Manager;
2. Windows ESP 的 `\EFI\Microsoft\` 与基线清单(`02-esp-backup/manifest.sha256`)逐文件一致;
3. `{bootmgr}` 的 `path` 与基线一致;
4. BitLocker 状态与基线一致。

**本次修订新增两项(Linux 侧)**:

5. **`nvidia` 模块签名**:`mokutil --list-enrolled` 含上游密钥、`modinfo -F signer nvidia` 非空、`lsmod` 有 `nvidia`(由 `check-signature.sh` 一类脚本承担);
6. **部署列表与固定状态**:`rpm-ostree status` 显示的部署数、当前部署与 pin 状态符合预期,且镜像来源与计划一致(由 `dbk-rollback.sh` 一类脚本承担)。

已知事故类型:2024-08 的 SBAT / Secure Boot DBX 更新曾导致双系统机器无法引导 Linux(微软已确认)。缓解:常备 Fedora 安装 U 盘(兼 live);必要时清理 SBAT 策略。

### 7.2 回滚的四种粒度

| 粒度 | 场景 | 手段 |
|---|---|---|
| 单步回滚 | 分层包装错、`/etc` 改错、`fstab` 写错 | 撤销该步(`rpm-ostree uninstall`、`/etc` 备份还原、改回挂载行) |
| **部署级** | 更新/分层/`rebase`/发行版升级后桌面起不来,驱动或内核翻车 | 开机菜单选上一个部署 或 `rpm-ostree rollback`;回滚后复检(会话/模块/桌面) |
| 基线回滚 | ESP 或固件启动项被破坏 | ESP 镜像 + 固件启动项快照(`bcdboot` 重建、NVRAM 清理) |
| 阶段回滚 | 不再需要 Linux | L5 退役流程 |

**注意**:**用户数据不随部署回滚** —— `/var`(含 `/var/home`)不在部署内,回滚系统不会丢家目录数据(见 3.22)。

---

## 8. 验收标准

唯一判据是 [docs/08-verification.md](../08-verification.md) 全绿;不以"装完了"为准。

**A. 引导安全组**

| 检查项 | 判据 |
|---|---|
| 默认启动项 | `BootOrder` 首位为 Windows Boot Manager;连续重启 3 次均默认进 Windows |
| Windows 引导未被污染 | `\EFI\Microsoft\` 与 L2 基线逐文件一致 |
| 引导路径未被篡改 | `{bootmgr}` 的 `path` 与基线一致 |
| 不变量落地 | Fedora 条目位于 `BootOrder` 末尾;全程未使用 `efibootmgr -o`;`\EFI\fedora\` 与 Windows ESP 分属两块不同分区 |
| **两个 ESP 互不干扰**(本次新增) | 在 Fedora 侧任何引导相关操作后:Windows ESP 的 `\EFI\Microsoft\` 逐文件不变;`BootOrder` 首位仍是 Windows Boot Manager;两块 ESP 可分别挂载并各自内容完整 |
| **可撤除性演练** | 备份 ESP 后临时删除 `\EFI\fedora\`(保留分区)-> 重启确认**自动进 Windows 且无 `grub rescue`** -> 用另存的副本还原 `\EFI\fedora\`(L2 基线**不含**该子树,见 4.3)并复测。**参考设备必做,其他设备推荐** |

**B. 系统功能组**:会话类型为 `wayland`(且无 X11 会话可选);GPU 驱动状态正常或有 nouveau 兜底且无签名拒绝日志;Secure Boot 保持开启;**新增:`rpm-ostree status` 显示 ublue 镜像来源**;**新增:分层包列表与计划一致**;共享数据分区以 `ntfs3` **读写**挂载成功且 `nofail`;**跨系统双向可见性**(Windows 写入 -> Linux 读到;Linux 写入 -> Windows 读到);**家目录重定向生效**(文档/下载/图片/桌面指向共享盘);`RTC in local TZ: no`;切换系统后蓝牙无需重新配对;`fwupd` 能识别设备。

**C. 双系统切换组**:从 Windows 用 BootNext(或厂商菜单键)一次性进 Linux 且**不改变**下次默认启动项;从 Linux 一键回 Windows;切换 3 次后 A 组首项检查仍成立。

**D. 可撤除性组**:按 L5 五步顺序完整推演(参考设备真做一次);结束后固件条目与实际状态一致。并额外核对:

| 检查项 | 判据 |
|---|---|
| 系统盘隔离生效 | 已知文件夹与游戏库均位于 D:;C: 不含用户数据(逐项核对重定向) |
| 原地重装两法可用 | 两法各至少完整推演一次(参考设备至少真做一法);重装后 A 组四条不变量复检通过 |
| 非重装逃生路径可用 | 引导层损坏场景已验证:ESP 镜像还原 + `bcdboot`(Windows)或 live 修复 Fedora 引导均可行 |

**E. 记录组**:`baseline/` 产物齐全且未入库(`git status` 干净);记录本次与设备参数表的偏差,回写到 [docs/00-overview.md](../00-overview.md)。

**F. 健壮性组(防崩溃)**

| 检查项 | 判据 |
|---|---|
| **部署回滚演练**(本次改写) | **真做一次**:`rpm-ostree rollback` -> 重启 -> 桌面可用 -> 复检模块加载与 Wayland -> 再回滚回来;并确认"**用户数据在回滚后仍存在**"(`/var` 不被回退) |
| 部署固定可用 | 变更前能用 `rpm-ostree pin` 固定当前部署;`rpm-ostree status` 能看到 pin 状态与多部署列表 |
| 多部署可回退 | GRUB 菜单列出至少两个部署(含版本与时间戳),且能从中选旧部署启动 |
| 崩溃可观测 | journald 为持久化模式:重启后能读取上一次启动的日志;且回滚后日志仍在(`/var` 不随部署回退) |
| 更新策略 | `rpm-ostreed-automatic` 只 check/download,**未启用自动应用与自动重启**(核对 `/etc/rpm-ostreed.conf`) |
| 远程救援通道 | 从另一台机器可 SSH 登录,且无需桌面会话 |
| OOM 防护 | `systemd-oomd` 处于启用状态;zram 生效 |
| 磁盘健康 | `smartd` 运行中且 `smartctl -H` 报告 PASSED |
| 挂载稳健 | L4 写入的挂载(共享盘、`/boot`、swapfile)带 `nofail`;`/boot/efi` 属必需挂载、**不加** `nofail`(加了会让 ESP 挂载失败被静默跳过) |

**通过定义**:任一组存在未勾选项且无在案记录的"已知例外" -> 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。

---

## 9. 风险登记

| # | 风险 | 后果 | 缓解 |
|---|---|---|---|
| 1 | **Intel VMD / RAID On** | Linux 安装器看不到磁盘 | 在装 Windows 之前就设为 AHCI/NVMe(全新设备的最大红利);已装好才改则走驱动预置分支 |
| 2 | **BitLocker** | 改分区表/固件设置触发恢复密钥索要 | 备份 48 位恢复密钥 -> 挂起保护 -> 操作 -> 恢复保护 |
| 3 | **Windows 更新重写 ESP / SBAT-DBX 事件** | Linux 引导消失或出现签名校验失败 | 两块 ESP 分离后 Windows 侧操作只触及第一块;ESP 镜像备份;常备 Fedora 安装 U 盘;必要时清理 SBAT 策略 |
| 4 | **Fast Startup + 双写 NTFS** | 共享数据分区损坏 | L1 强制关闭 Fast Startup 与休眠;共享盘禁止在 Windows 处于休眠状态时被 Linux 挂载 |
| 5 | **ESP 尺寸与部署数量不匹配**(ESP-Fedora 1GiB) | 引导文件放不下 | ESP-Fedora 定为 1GiB;内核与 initrd 在独立 `/boot` 而非 ESP;ESP 尺寸不可被安装器削减 |
| 6 | **引导顺序被改** | 删除 Linux 后卡 `grub rescue` | 四条不变量 + L5 退役流程 + L2 基线 |
| 7 | **NVIDIA 模块签名未就绪**(rebase 后未做 MOK 注册/注册未确认) | 驱动不加载,严重时无桌面 | 只用上游预签名镜像 + 一次性 MOK 注册;`mokutil --list-enrolled` 与 `modinfo -F signer nvidia` 双判据;保留 nouveau 兜底;巡检复核签名 |
| 8 | **Windows 安装程序对恢复分区放置的版本敏感性** | 预留空间被占用,分区表偏离计划 | L2 逐项核对分区表;偏离可接受(仅两块 ESP 与 Fedora root 尺寸不可削减) |
| 9 | **双系统时间 / 蓝牙状态分裂** | 时钟错乱、设备需反复重新配对 | RTC=UTC;上游 `bt-keys-sync` |
| 10 | **KMS 续期依赖可达的 KMS 主机** | 180 天周期内未成功续期会导致激活失效 | 保留续期任务并定期核对激活状态;失效时重新执行一次在线激活流程 |
| 11 | **`ntfs3` 写入导致共享盘数据损坏** | 办公文件丢失 | 关键目录保留第二份备份;避免在 Linux 侧批量重命名/移动大目录 |
| 12 | **共享盘被 BitLocker/设备加密** | Linux 侧无法挂载,共享方案失效 | 装机时 `D:` 保持不加密;若 Windows 自动启用设备加密,先解密再继续 |
| 13 | **POSIX 语义差异** | 依赖符号链接/权限位的工具在共享盘上报错 | 共享盘只放文档类数据;代码与工程目录留在 Linux 本地 |
| 14 | **更新被自动应用/自动重启** | 与显卡驱动不适配,黑屏或进不了桌面 | 3.18:`rpm-ostreed-automatic` 只 check/download,不自动应用与重启;变更前先 pin 当前部署 |
| 15 | **反复长按电源强制重启** | 文件系统损坏、满屏报错进不去 | 用 REISUB(SysRq)安全重启;事后做文件系统检查;把"不要反复强断"写进排障手册 |
| 16 | **把硬件故障误判为双系统问题** | 浪费时间、误删系统、掩盖真实故障 | 硬件优先 triage:内存 / 磁盘 / 温度;明确"运行期两系统互不影响" |
| 17 | **引导菜单阶段黑屏** | 误以为系统损坏而重装 | 决策 3.19:换终端模式 + 用 BootNext 切换;原子版菜单条目更多,更长,先确认键盘仍有效 |
| 18 | **安装时选错目标磁盘** | 误格数据盘或另一系统 | 参数表用 `DISK_MODEL`/`DISK_SIZE`,安装前逐盘核对 |
| 19 | **双盘机型固件只认第一块盘** | 引导文件放错盘导致装完无法启动 | 厂商差异表增加"能否从第二块盘引导"列;**两块 ESP 都必须在第一块盘** |
| 20 | **国内镜像站下载未校验** | 镜像损坏或被替换 | 下载后核对官方发布值:Fedora ISO 按官方 `CHECKSUM` 文件比对;Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验"。镜像站只作为下载加速,不作为信任源 |
| 21 | **在 ublue 镜像/分支之间乱切以迁就驱动** | 系统状态不可解释、来源不可信 | 记录当前镜像来源与版本(`rpm-ostree status`);切换前先 pin;不在非官方镜像间漂流,不降发行版 |
| 22 | **家目录重定向后的应用不兼容** | 个别程序不认自定义 XDG 目录,或在 NTFS 上无法保存权限位 | 只重定向文档类目录;需权限语义的留在本地;出问题回退 `user-dirs.dirs` 即可 |
| 23 | **激活方案的平台合规风险** | 仓库或账号层面的合规问题 | 公开仓库只做外链与流程说明,不分发任何激活脚本本体;附风险与责任声明 |
| 24 | **部署清理不当导致回滚点缺失** | 需要回滚时无旧部署可用 | 保留策略写进卡:变更前 pin,`rpm-ostree cleanup` 只在确认不需要旧部署时执行;巡检核对部署列表 |
| 25 | **部署固定(pin)状态被误改** | 回滚点静默消失 | 纳入周期性巡检(7.1 第 6 项)与 F 组验收 |
| 26 | **原地重装时误格分区** | 数据分区或另一边系统被清空 | 安装时逐分区核对;明确禁止"删除所有分区";动手前先做基线备份 |
| 27 | **重装 Silverblue 时误格 ESP 或 `/boot`** | 破坏 Fedora 引导;误格 Windows ESP 时连带破坏 Windows 引导 | 显式检查安装器里两块 ESP 的"格式化"勾选;`/boot` 与 ESP 绝不格式化;动手前先备份 `/var/home` |
| 28 | **已知文件夹重定向遗漏** | 数据落在 C:,重装即丢 | L1 完成后按验收 D 组逐项核对;重定向清单固化为文档步骤 |
| 29 | **Anaconda 在已有系统/ESP 的盘上装 Silverblue 失败**(上游 `fedora-silverblue/issue-tracker#284`,自 F34 起) | L3 卡住,拿不到 Linux 系统 | 4.4 的手工预建 Fedora 分区 + 只指定挂载点;失败时按 `07-rescue.md` 在 live 环境手工修;最坏退回轨道 W(L2 基线可用,损失可控) |
| 30 | **同盘两块 ESP 的固件支持不确定** | 固件只认第一块 ESP,Fedora 条目不可见 | 列为 A 组必做实测项;若某机型不支持,记录偏离并评估"共用 ESP 分支"(第 10 节) |
| 31 | **`rpm-ostree install` 下 akmods 不签名**(上游 `#499`) | 自签 akmods 路径在原子版上易碎,驱动可能拒载 | 默认走 ublue 预签名镜像 + 一次性 MOK 注册;自签路径仅作回退分支且必须标注"未在真机验证" |
| 32 | **`akmod-nvidia` 卡住内核升级**(上游 `#632`) | 内核/驱动更新被阻塞,长期停在旧内核 | 不在原子版上直装 akmod;驱动随 ublue 镜像的 `rebase` 一起更新,更新前先 pin |
| 33 | **`rebase` 后驱动与内核不配套** | 新部署里 `nvidia` 不加载或桌面异常 | rebase 前 pin;rebase 后立刻复检(会话/Wayland/模块签名/桌面),不满足判据就回滚到被 pin 的部署 |
| 34 | **ublue 镜像的命名/分支漂移与信任** | 沿用旧分支名写错、或来源不可核验 | 实施前复核镜像名与分支(`UBLUE_IMAGE` 标"待核实");每次操作后记录 `rpm-ostree status` 的镜像来源与版本;可随时 `rebase` 回 stock Silverblue |

---

## 10. 未决项与后续变体

| 项 | 状态 | 说明 |
|---|---|---|
| `autounattend.xml` + `diskpart` 模板(部署加速器) | **占位,先不实现** | 面向多台同规格设备的批量部署;代价是应答文件对 Windows 版本敏感、调试成本高 |
| 独立共享分区变体 | 待评估 | 从 D: 再切出一块专用共享分区,把"共享"与"Windows 私有数据"隔离,降低写入风险 |
| 共用 ESP 分支(单 ESP) | 待评估 | 若机型固件只认第一个 ESP:退回 Windows 与 Fedora 共用一个 ESP(**仍保留独立 `/boot`**),并重新评估 I3 的保障方式;需实测 |
| stock Silverblue + 手工自签 akmods(不用 ublue 镜像) | 回退分支 | 按上游 `#499` 的 workaround 自建密钥并纳入部署,每次内核更新重签;上游已知易碎,**仅在不愿用 ublue 镜像时启用** |
| Kinoite 变体(KDE 对等替代) | 待评估 | 差异仅在桌面(Plasma 6.6.4)与 ublue 对应的 NVIDIA 变体;**镜像名与分支须实测核实** |
| 外置 USB SSD / 移动硬盘安装分支 | 待评估 | 无第二盘位又不愿动内置盘时的可行路径(评论区有同类需求),需补 USB 供电、性能与引导条目保持的注意点 |
| 云端/网络同步补充 | 待评估 | 若需跨机器访问同一批办公文件,可叠加云同步或 NAS;同机双系统之间的 SMB 无意义(两系统不能同时开机) |
| LUKS 加密变体 | 待评估 | 需改为手动分区,首启需口令;原子版的加密安装与后续 rebase 行为**须先核实** |
| Windows 侧"回 Linux 一键切换"工具 | 待评估 | 现有开源实现多为第三方托盘程序;v1 先用 BootNext 与厂商菜单键 |
| 双盘设备分支 | 待编写 | Linux 独占一块盘 + 独立 ESP(**两块 ESP 都必须在第一块盘**) |
| btrfs 快照回滚变体 | **已作废** | 本次修订明确不做:回滚改由部署级承担(3.7 / 3.14) |

---

## 11. 参考项目与调研结论(截至 2026-09-19)

调研了同类开源项目,按"解决什么问题 / 架构 / 活跃度 / 可复用 / 需避开"筛选:

| 项目 | 规模 | 参考价值 |
|---|---|---|
| `gillesduif/iGloo` | 50 星,alpha,.NET 9 WPF | **参考架构**:Windows 侧应用 + 每发行版一个安装器配置插件 + 首启 systemd oneshot + 通过暂存卷上的 manifest 交换状态;其 safety-model(BootNext 一次性启动、只用原生分区缩容、无人值守安装仅落在未分配空间、ISO 校验、保留 nouveau 兜底、全流程日志)**被本方案直接继承**;它支持"干净卸载 Linux 并还原 Windows 引导"这一等公民流程,与本方案 L5 同源。**需避开**:绑定单一 Windows GUI、NVIDIA 场景要求关闭 Secure Boot、浏览器凭据跨系统迁移的高风险链路 |
| `ublue-os/bazzite` / `bluefin` / `aurora` | 9k / 2.6k / 0.8k 星,每日提交 | **本次修订起成为 NVIDIA 路径的来源(决策 3.3 / 4.5)**:采用其预签名 NVIDIA 变体镜像的 `rebase` 路径与上游 MOK 注册(`ujust enroll-secure-boot-key`);其双系统文档的"先关 BitLocker 与 Fast Boot""双盘场景物理拔掉 Windows 盘""注意安装器会并入已有 ESP"等结论仍作为风险输入。**需避开**:**要求自定义 Secure Boot 密钥**的做法(本方案用上游预签名镜像 + MOK 注册,不引入自签密钥链);**镜像名与分支以实施时复核为准** |
| `fedora-silverblue/issue-tracker` | 官方 issue 库 | **坑位证据来源**:`#284`(Anaconda 在已有 ESP 的盘上装 Silverblue 失败,自 F34 起)、`#499`(`rpm-ostree install` 下 akmods 不签名)、`#632`(`akmod-nvidia` 卡内核升级) |
| `archlinux/archinstall`、`calamares/calamares` | 8.4k / 1.5k 星 | 分区与引导配置的工程化参考;但 Fedora 用 Anaconda,Fedora/Debian 不使用 Calamares,故本方案以各发行版原生无人值守入口为准 |
| `KeyofBlueS/bt-keys-sync` | 66 星 | **直接复用**:以 `chntpw` 读写 Windows 注册表中的蓝牙配对密钥,按上游建议以 Windows 侧为权威来源,避免反向写注册表 |
| `pgaskin/bootnext`、`mendhak/grub-reboot-picker` | 92 / 70 星 | **复用机制**:EFI `BootNext` 一次性启动语义,是 I2 的实现基础。前者自 2020 年未更新,故只取其机制,不依赖其产物 |
| `linuxmint/timeshift`、`Antynea/grub-btrfs` | 4.3k / 1.2k 星 | 快照回滚方案;**本次修订后已作废**(决策 3.7 / 3.14 明确不用:回滚改由 ostree 部署承担) |
| `bayasdev/envycontrol` | 1.9k 星 | 混合显卡模式切换参考,归入 L4 的备选工具 |
| `fwupd/fwupd` + LVFS | 4.2k 星 | Linux 侧固件更新路径;注意部分机型 LVFS 版本可能落后于 Windows 侧固件 |
| `massgravel/Microsoft-Activation-Scripts` | 190k 星,最近发布 v3.12(2026-07-04) | Windows **KMS 激活**的上游来源(Online KMS:180 天周期 + 每 7 天自动续期任务);其文档明确记录了 KMS38 的失效边界与移除决定,是本方案排除 KMS38 的依据;本仓库只做外链与流程说明 |
| `rezzcode/grub-rescue`、`blindma1den/windows-11-uefi-boot-repair` | 3 / 56 星 | L5 救援手册的内容来源(GRUB 恢复、`bcdboot` 重建,注意其命令写法偏 legacy) |
| `yannubuntu/boot-repair` | GitHub 仓库已不存在 | 只能作为离线救援 ISO 列入工具箱,**不可作为方案依赖** |

---

### 11.1 实战评论区证据(BV1Cc41127B9)

来源:B 站《Windows11 安装 Ubuntu 避坑指南》(BV1Cc41127B9,2023-12 发布,72 万播放、4619 条评论)。抓取范围说明:**未登录状态下 B 站只开放顶层 3 条热评与其全部子回复**,共获取 52 条(已尽力展开子回复),并非全量样本;下文为其归纳,均为改写而非原文引用。本节为既有证据集的逐条保留(证据本身与发行版无关的部分继续有效)。

归纳出的坑与对应设计改动:

| # | 评论区里反复出现的问题 | 本方案对应改动 |
|---|---|---|
| 1 | 笔记本混合显卡模式下装完进不了系统/黑屏,改成 BIOS 独显直连后解决(542 赞热评) | 决策 3.17:显卡模式排障分支;默认仍走混合 + PRIME |
| 2 | `nomodeset` 被当成"万能修复",但同时失去 KMS,与 Wayland 直接冲突 | L3 应急步骤 + 明确"临时手段,装好驱动必须移除" |
| 3 | 自动更新内核后显卡驱动不适配,进不了桌面(子回复高赞) | 决策 3.18:更新策略收紧为只检查/下载,不自动应用与重启;变更前先 pin 当前部署 |
| 4 | 长时间使用后莫名崩溃、反复强制重启,最后两系统都出问题(274 赞) | 故障矩阵新增硬件优先 triage + REISUB 安全重启 + 事后文件系统检查 |
| 5 | 装完独显驱动后每次开机在引导菜单阶段黑屏(键盘仍可用) | 决策 3.19:换终端模式 + BootNext 切换 |
| 6 | "删掉 Ubuntu 会不会影响 Windows 引导?"(多人问) | 四条不变量 + L5 退役流程;FAQ 里显式回答 |
| 7 | Ubuntu 24.04 手动分区界面没有"引导器位置"选项,用户卡住不敢继续 | L3 步骤与故障矩阵里明确说明:本方案**不依赖**安装器写 Windows 的 ESP,改用"手工预建 Fedora 分区 + 只指定挂载点" |
| 8 | 部分厂商双硬盘机型只能从第一块盘启动(惠普) | 偏离项与厂商差异表增加硬约束(**两块 ESP 都必须在第一块盘**) |
| 9 | 选错安装目标盘导致重装 | 参数表用 `DISK_MODEL`/`DISK_SIZE`,安装前核对 |
| 10 | 新网卡/键盘不识别,担心要换发行版 | 驱动优先级:先在 ublue 的镜像/分支间切换或换内核,不降发行版 |
| 11 | 国内下载镜像的需求 | L0 手册补充国内镜像下载 + Fedora ISO 按官方 `CHECKSUM` 比对(Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验") |

---

## 12. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-17 | 初版:确定 Ubuntu 26.04 LTS + 官方 GRUB + 2GiB 共享 ESP + ext4 160GiB;确立四条不变量、L0–L5 分层、多设备参数化、验收标准 |
| 2026-09-17 | 修订一:设备类容量表述改为"标称 1TB 级、实际可用约 953GiB";激活路线改为成熟 KMS(排除 KMS38);新增 4.7 健壮性设计九项措施、验收 F 组,Linux 空间拆分为 root 140GiB + 快照分区 20GiB |
| 2026-09-17 | 修订二:新增决策 3.15 **Windows 系统盘隔离**(C: 200GiB 系统 / D: ≈590GiB 数据)、4.8 崩溃后**原地重装两法**、阶段到手册文档映射表、验收 D 组三项补充与对应风险条目;自建 KMS 维持"待评估",不提升为主路线 |
| 2026-09-17 | 修订三:**自建 KMS 方案彻底删除**(决策 3.10 收敛为仅 Online KMS);新增决策 3.16 与 5.3 **跨系统共享数据分区**(D: 以 `ntfs3` 读写共享),并相应更新非目标、L4 挂载、验收 B 组、风险表与未决项 |
| 2026-09-17 | 修订四:容量方案定型为 **P1**——Windows 系统 200 / Ubuntu root **100** / 快照 **15** / 共享数据盘 **≈635GiB**;新增家目录数据重定向到共享盘(与 100GiB root 的前提绑定),更新 L3 分区、L4 重定向项、参数表、5.3 用法约定、验收 B 组与风险表 |
| 2026-09-17 | 修订五:依据 B 站实战评论区证据(新增 11.1 节)补齐坑位——新增决策 3.17 **显卡模式(MUX)排障分支**、3.18 **内核/驱动更新收紧**、3.19 **引导菜单黑屏处置**;故障矩阵新增 8 行、风险表新增 9 条、参数表新增 `DISK_MODEL`/`DISK_SIZE`、偏离项新增"固件只认第一块盘"、未决项新增 HWE 内核与外置盘分支 |
| 2026-09-19 | **修订七:改用 Fedora 44 Silverblue 原子版**。基础系统由 Ubuntu 26.04 LTS(原方案)改为 Fedora 44 Silverblue;回滚由快照级改为**部署级**(`rpm-ostree rollback` + GRUB 选旧部署,**不做 `snapper`/`grub-btrfs`/btrfs 快照**);NVIDIA 路径改为 `rpm-ostree rebase` 到 ublue 预签名 NVIDIA 变体 + 一次性 MOK 注册;分区改为"Windows 独占 2GiB ESP + Fedora 独立 1GiB ESP + 独立 `/boot` 1GiB + root ≈113GiB btrfs";新增 **1.4 轨道结构(W/L/D 与共用底座)**、**决策 3.21 生命周期与升级**、**3.22 原子版语义**、**3.23 三轨道**;改写 3.1/3.2/3.3/3.4/3.6/3.7/3.8/3.14/3.16/3.20;4.4 改"L3 Silverblue 安装"(手工预建 Fedora 分区、Anaconda 只指定挂载点、不让它动 Windows ESP)、4.5 改原子版语义、4.7 的 R1/R2 改为"部署固定 + 回滚演练"、4.8 办法二改为 Silverblue 重装;5.1 分区表改 8 项、5.2 参数表新增 `FEDORA_ESP_SIZE`/`BOOT_SIZE`/`ROOT_SIZE`/`UBLUE_IMAGE`;7.1 巡检在四项之外新增"`nvidia` 模块签名"与"部署列表与固定状态"、7.2 改为四种粒度(单步/部署级/基线回滚/阶段回滚);8 组新增"两个 ESP 互不干扰"、F 组改为"部署回滚演练 + 用户数据仍在";9 节原 28 条风险逐条保留并替换其中 Ubuntu 专属项,追加 6 条新风险(Anaconda 双系统安装失败 `#284`、双 ESP 固件支持、`rpm-ostree` 下 akmods 不签名 `#499`、akmods 卡内核升级 `#632`、`rebase` 后驱动与内核配套、ublue 镜像命名/分支漂移与信任);10 节新增"共用 ESP 分支"与"stock Silverblue + 手工自签 akmods 回退分支"、标记"btrfs 快照回滚变体已作废";11 节新增 ublue 与上游 issue 库两条参考。本行取代原计划的"修订六:换 Fedora 44 Workstation(传统可变系统)"——该变体仅存在于 `02-fedora-variant-design.md`,已作废 |
