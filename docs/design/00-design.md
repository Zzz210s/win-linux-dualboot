# 设计方案:Windows 11 专业版 + Kubuntu 26.04 LTS 双系统

日期:2026-09-17(初版)/ 2026-09-22(修订八)
状态:已定稿(待实施计划)
适用:单块 NVMe、UEFI、混合显卡、允许整盘格式化的设备类

---

## 0. 文档定位与阅读顺序

| 文档 | 作用 |
|---|---|
| 本文件 [docs/design/00-design.md](00-design.md) | **为什么**这样设计:目标、轨道结构、不变量、决策记录、风险依据 |
| [docs/design/04-kubuntu-variant-design.md](04-kubuntu-variant-design.md) | **本次改动的依据**:基础系统由 Fedora 44 Silverblue 改为 Kubuntu 26.04 LTS 的六项决定、snap 规避 S1–S6、证据等级与影响面 |
| [docs/design/01-playbook-reshape-design.md](01-playbook-reshape-design.md) | 手册的**卡格式**(R1–R7)与自检规则(C1–C9) |
| [docs/design/03-step-automation-design.md](03-step-automation-design.md) | 每张卡对应一个脚本(CLI 契约、卡与脚本双向绑定) |
| [docs/00-overview.md](../00-overview.md) ~ [docs/10-faq.md](../10-faq.md) | **怎么做**:按执行顺序编号的分步手册 |
| `README.md` / `README.zh-CN.md` | 面向第一次接触者的入口 |

阅读顺序:先本文件第 1、2 节(目标、轨道结构与四条不变量),再进入手册的 `00-overview.md`。

**历史文档**:[docs/design/02-fedora-atomic-variant-design.md](02-fedora-atomic-variant-design.md) 记录"上一版为什么选原子版、为什么又改回传统可变系统",**已被 04 号设计取代,只作历史,不作实施依据**。

---

## 1. 目标、适用设备类与非目标

### 1.1 目标

在一台**全新的同规格设备**上建立双系统,同时满足三件事:

1. **能装成**:Windows 11 专业版 + **Kubuntu 26.04 LTS**(Plasma 6.6,Wayland-only),Linux 侧默认 Wayland 会话;
2. **能安全撤除**:删除 Linux 后仍能自动进入 Windows,不出现 `grub>` / `grub rescue>`;
3. **能重复**:同一套手册可用于多台同规格设备,不绑定任何一台具体机器的序列号、机器名或历史状态。

本次修订带来的额外目标与代价(用户 2026-09-22 明确接受):**回滚策略降级** —— 不引入任何快照体系,用**包级回退**(`apt install <包>=<版本>` + `apt-mark hold`)+ **原地重装两法**替代"一条命令回到上一个可用系统"的能力。理由是"日常省心"(apt 生态、官方预签名显卡驱动、3 年 LTS 只收安全更新),代价登记在 3.14 与 7.2。

### 1.2 适用设备类

**必须同时满足**

- 单块 NVMe SSD,**标称 1TB 级**、UEFI + GPT 引导;**容量口径**:若为 1024GB 型号则实际可用约 **953.7GiB**(本方案默认按此定表),若为 1000GB 型号则只有约 **931.3GiB** —— 两者相差约 22GiB,见 5.1 的偏离分支;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化(Windows 与 Linux 都是全新安装);
- 目标系统组合:Windows 11 专业版 + **Kubuntu 26.04 LTS**(Linux 侧)。

**偏离项的处置**

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP,不变量不变 |
| 磁盘容量明显偏离 1TB 级(如 512GiB / 2TiB) | 按比例调整 C:、D: 与 Ubuntu 侧容量,分区布局与四条不变量不变 |
| 已有 ESP 且不愿整盘重排 | **不适用**:本方案依赖整盘重排时按计划定尺寸的两块 ESP(Windows 2GiB + Ubuntu 1GiB,见 3.4) |
| BitLocker 已启用 | 先执行挂起与恢复密钥备份,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 模式已锁定且无法改为 AHCI/NVMe | **不适用**(Linux 侧看不到磁盘) |
| 仅独显(无集显) | 走"NVIDIA 单显卡分支":不配置 PRIME offload,显示输出直接由独显承担 |
| 无法接受 Linux 写入 NTFS | 把共享挂载降级为只读,或改用独立共享分区(第 10 节变体) |
| 桌面不用 KDE(要 GNOME 或其他桌面) | **不适用**于 v1:本方案选定 Kubuntu(Plasma 6.6)。换桌面等于换发行版或 flavor,须重新评估安装器与引导口径(04 号设计 D1 的被否项) |
| 必须用 Ubuntu 主版镜像(不接受 Kubuntu) | **不适用**于 v1:主版走 Flutter 安装器(`ubuntu-desktop-bootstrap`),其手动安装创建 ESP 的已知缺陷与本方案"手工预建分区 + 只指定挂载点"的路径不同(04 号设计第 1.1 节) |
| 需要磁盘加密 | **不适用**于 v1;见第 10 节 LUKS 变体 |
| 双盘机型且固件只从第一块盘引导(部分厂商) | **两块 ESP 都必须留在第一块盘**;Linux 数据分区可放第二块盘,但两块 ESP 不能放第二块盘 |
| 机型固件只认第一个 ESP(同盘双 ESP 不支持) | 记录为偏离项并评估"共用 ESP 分支"(第 10 节):退回 Windows 与 Ubuntu 共用一个 ESP,仍然保留独立 `/boot`;此分支需重新评估 I3 的保障方式 |
| 不接受发行版自带安装器(要自研图形化安装器) | 不做:用 Calamares 的手动分区页 + 只指定挂载点即可,自研安装器是新增风险而非收益(见 1.3) |

### 1.3 非目标(v1 明确不做)

用户数据与浏览器凭据迁移 / 磁盘加密与 TPM-FDE / 休眠 / **`snapper`、`timeshift`、`grub-btrfs` 与一切 btrfs 快照回滚** / **ZFS root 快照**(见 04 号设计 2.1,明确被否)/ 自定义 Secure Boot 密钥(走 Ubuntu 官方预签名包)/ 自研图形化安装器(用 Calamares)/ 多发行版模板 / `preseed` / `autoinstall` 无人值守安装。

砍掉这些不是省事,而是它们的失败模式(凭据泄露、TPM 与引导链测量冲突、休眠与 NVIDIA + Wayland 冲突、自签密钥触发 BitLocker 恢复、无人值守写错分区即毁 Windows)会把方案从"可复现"拖成"每次都得现场救火"。

**注意**:"两个系统都能访问的共享数据分区"(决策 3.16 / 5.3)**不在非目标内**,它是 v1 的正式组成部分。

### 1.4 轨道结构(W / L / D 与共用底座)

本方案由三条**可独立执行**的轨道组成,满足"任一系统可单独安装":

| 轨道 | 场景 | 步数 | 内容 |
|---|---|---|---|
| **共用底座** | 三条轨道都要 | 3 步 | 固件设置 -> 安装介质 -> 目标盘核对 |
| **W** | 只装 Windows | 5 步 | 分区 -> 装 -> 激活 -> 关快速启动与休眠 -> 收敛 |
| **L** | 只装 Kubuntu | 6 步 | 装 -> 首启(驱动/挂载/时间/snap 规避) -> 收敛 -> 包级回退演练 |
| **D** | 双系统 | 底座 + W + L + **共存增量 4 步** | 预留 115GiB / 引导不变量核查 / `ntfs3` 共享盘 / 退役与救援 |

机器上的动作量(粗算):只装 Windows **约 9 步**;只装 Kubuntu **约 10 步**;双系统 **约 19 步**(按本表轨道口径;若按 L0–L5 阶段逐个动作口径,则为 30 步)。

**共用卡 vs 专属卡**:固件、安装介质、目标盘核对、KMS 激活与"包级回退演练"属于共用或双轨复用;**双系统专属**只有 4 条 —— 预留分区(115GiB)、引导不变量核查(`BootOrder` 首位 = Windows)、`ntfs3` 共享盘、退役与救援。

**"简化"落在哪里**:落在单系统场景的步骤数与文档按轨道拆分后的阅读路径上,**不来自砍掉机制** —— 见决策 3.23 与 `04-kubuntu-variant-design.md` 的 D6。

---

## 2. 四条不变量

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

## 3. 关键决策记录

| # | 决策 | 选择 | 理由 | 被否方案与原因 |
|---|---|---|---|---|
| 3.1 | 系统组合 | Windows 11 专业版 + **Kubuntu 26.04 LTS** | 用户 2026-09-22 选定 A(换 Kubuntu),理由是"日常省心":apt 一条命令装软件、NVIDIA 走官方预签名包、LTS 3 年只收安全更新;**Plasma 6.6 在 Wayland 下成熟** | **Fedora 44 Silverblue(原子版,本方案的上一版)**:日常要学 ostree/容器,13 个月一次大版本升级,已由 04 号设计取代;**Fedora 44 Kinoite**:Plasma + 部署级回滚,但仍是 Fedora 节奏;**Ubuntu 主版 GNOME**:用户要 KDE 的省心,且其 Flutter 安装器的 ESP 行为与本方案的手工分区路径不同;Debian 13(内核与驱动偏旧);CachyOS(滚动更新与"稳定"冲突) |
| 3.2 | 桌面环境 | **KDE Plasma 6.6**(Kubuntu 旗舰),Wayland-only | 与"省心"一致:桌面可深度定制且不影响系统层;Plasma 在 Wayland 下已成熟;Wayland 是唯一会话类型,不提供 X11 回退 | 非 Plasma 桌面(GNOME 等):等于换 flavor 或换发行版,超出 v1 范围 |
| 3.3 | 引导栈 | **GRUB2 + shim**,写入 `\EFI\ubuntu\`,**使用 Kubuntu 自己的 ESP** | 上游在 Secure Boot 下原生可用;官方签名链现成(`shim-signed` + `grub-efi-amd64-signed`),**无需自签**;`grub-install` / `update-grub` 的救援路径有官方文档支撑 | **systemd-boot + UKI**:Ubuntu 上非默认,且与救援卡里 `grub-install` + `update-grub` 的口径不一致。**rEFInd**:需改 `{bootmgr}` 路径(违反 I3)或额外引入一层。**自定义 Secure Boot 密钥**:改动签名链会新增风险(见 1.3) |
| 3.4 | ESP 布局 | **Windows 独占 2GiB + Ubuntu 独立 1GiB(两个 ESP)** | 上游与社区一致要求 Linux 用**自己的** ESP 与 `/boot`;Calamares 会把引导装到 `/boot/efi` 所指的那块 ESP,独立后 I3 由**结构**保证;Windows 侧工具只认第一个 ESP 的习惯也不再被牵动 | **单个 2GiB 共用 ESP**:I3 只能靠纪律,且后续 Windows 更新可能重写共用 ESP 的 `\EFI\BOOT\` |
| 3.5 | 分区策略 | **整盘重排,一次分好** | 消除"缩容"这一整类事故(不可移动文件挡路、BitLocker 触发恢复、缩容上限不足) | 被否:已有系统上缩容(本方案不提供该分支;需要改尺寸就整盘重排) |
| 3.6 | Linux 容量 | 合计 **115GiB**:ESP-Ubuntu **1GiB** + `/boot` **1GiB**(ext4)+ root **≈113GiB** | 定位是"轻量远程 AI 开发 + 办公":文档类数据全部落在共享数据盘(3.16 / 5.3),不占 root;**`/boot` 独立**让重装 root 时可选择保留内核与 GRUB 模块 | 不单独分 `/boot`(重装 root 时内核随之丢失,反而更麻烦);root 140GiB 级(共享盘被压缩,收益不足);保留更早方案的"独立 15GiB 快照分区"(快照体系已被否决,见 3.7 与 3.14) |
| 3.7 | 根文件系统 | **ext4**(Ubuntu 默认) | 本方案不需要文件系统层快照(回退由包级回退 + 原地重装承担),故不引入 btrfs 子卷体系;ext4 是 Ubuntu 的默认选择,`/boot` 与 root 同族,救援文档口径统一 | **btrfs + snapper + grub-btrfs**(用户明确否决:额外维护一套快照工具链);**ZFS root 快照**(Ubuntu 上属实验性选项,内存开销与调优门槛高,见 04 号设计 2.1) |
| 3.8 | 交换空间 | **无 swap 分区**:zram + swapfile 4GiB | 可随时调整、不动分区表、兼容任意文件系统 | swap 分区(尺寸一旦定死);休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下风险高) |
| 3.9 | 磁盘加密 | **不做** | TPM-FDE 需整盘且与双系统引导链测量冲突,官方仍标实验性质 | LUKS 口令(留给第 10 节变体) |
| 3.10 | Windows 激活 | **成熟 KMS 激活**:采用上游项目的 **Online KMS**(180 天周期 + 每 7 天自动续期任务),**不引入任何自建 KMS 服务** | 按需求定调(采用成熟 KMS,而非购买密钥或 HWID);KMS 走的是微软官方激活协议,可重复、可验证、可续期;自建 KMS 已放弃,因为它需要一台常态在线的主机,收益(离线自主)不抵维护成本 | **KMS38**:微软在 build 26100.7019 起彻底废弃该机制,且已被上游项目移除,对 Windows 11 24H2+ 无效。**自建 KMS 服务**:已彻底放弃,需求中已删除。**HWID / TSforge**:虽为上游推荐,但按需求不使用(仅作文档中的回退说明) |
| 3.11 | 文档粒度 | **步骤级**(做什么 + 关键命令 + 验证方式) | 按需求定调;命令级会引入版本敏感的冗余细节 | 命令级(逐条可复制但难维护);说明级(信息不足) |
| 3.12 | 多设备适配 | **参数化 + 厂商差异表**,`baseline/` 每台设备一份且不入库 | 面向"多台同规格设备"重复部署;同时避免公开仓库泄露具体机器信息 | 绑定单台机器(不可复用,且泄露序列号) |
| 3.13 | 数据迁移 | **不做** | 高价值但高风险(iGloo 的整套迁移链路包含凭据解密/再加密) | iGloo 式迁移(见第 11 节) |
| 3.14 | Linux 健壮性(R1–R9 改为**包级**) | 九项措施:**R1 变更前备份**(`baseline/` 与 `/etc` 关键文件,脚本内置 `.dbk.bak`)+ **R2 包级回退**(`apt install <包>=<旧版本>` + `apt-mark hold`,并**真做一次演练**)+ R3 旧内核保留 + R4 救援介质 + R5 journald 持久化 + R6 OOM 防护(zram + swapfile + `systemd-oomd`)+ R7 常开 SSH + R8 保守更新策略 + R9 SMART 与共享盘 `nofail` | 目标是"不会因为一次升级或一块盘的问题而失去可用系统";**已接受的取舍:没有一条命令回退整个系统的能力** —— 系统级损坏只能走"包级回退 + 原地重装"(30–60 分钟,数据在 `D:` 不受影响),这是为"日常省心"付的价(04 号设计 D4 / 第 7 节) | **snapper + grub-btrfs**(用户明确否决);仅靠"重装"作为唯一恢复手段(等于放弃回退);休眠(与 NVIDIA + Wayland 冲突) |
| 3.15 | **Windows 系统盘隔离** | C: 只承载系统与程序(**200GiB**);数据、游戏库、下载与容器镜像独立到 **D: 数据分区(≈635GiB)**;已知文件夹(桌面/文档/下载/图片/视频/音乐)统一重定向到 D: | 崩溃时**只需格式化系统分区**即可原地重装,数据与另一边系统不受影响(见 4.8);与 Linux 侧"root / 家目录分离"形成对称的隔离结构;C: 的容量需求变得可预测 | 单一大 C:(重装等于清空全部数据,与"原地重装"目标直接冲突) |
| 3.16 | **跨系统共享数据分区** | 整块 **D: 作为共享盘**:Windows 原生 NTFS 访问,Kubuntu 侧以 **`ntfs3` 读写**挂载(自动挂载、`nofail`);`D:` **不启用 BitLocker**;办公文件集中放在约定目录(如 `D:\Shared\`) | 满足"两个系统都能访问同一批文件、切换系统即可继续办公"的需求;选 NTFS 而非 exFAT 是因为 Windows 侧原生访问、且两者都支持;Linux 写 NTFS 的风险用"关 Fast Startup + 不加密 + 不动权限敏感工作流 + 关键目录备份"四项约束兜住 | exFAT 专用共享分区(无日志、断电易损,除兼容性外无优势);同机网络共享(两个系统不能同时开机,同机 SMB 无意义);云同步(依赖外网与配额,只能作为补充) |
| 3.17 | **显卡模式排障分支(MUX)** | 默认**混合模式 + PRIME offload**;若在混合模式下安装器或首启无法点亮(黑屏),走分支:BIOS 切到**独显直连**先拿到可用系统,再评估是否切回混合 | 评论区高频报障显示:部分笔记本(联想拯救者等)混合模式下装完启动不了,切到独显直连后解决;但独显直连有真实代价(所有进程占显存、续航变差),所以不能作为默认 | 把"独显直连"当默认(续航与显存双输,且日后要跑本地推理时显存不够);因驱动问题**降级发行版**(支持期与硬件兼容双输,正确做法是换内核或改走官方预签名驱动的新版本) |
| 3.18 | **内核与驱动更新策略收紧(apt 语义)** | `unattended-upgrades` 只装**安全更新**(`Allowed-Origins` 只列 `-security`)且 `Automatic-Reboot "false"`(**不自动重启**);**内核/驱动升级之前先按 `05-9` 记下当前内核与驱动版本、备份 `/etc` 关键文件** | 评论区高频报障:自动更新内核后与显卡驱动不适配,进不了桌面;内核/驱动是这台机器上最大的可恢复风险点,不应无人值守执行 | 全部自动更新(含自动重启)—— 对 NVIDIA 混合显卡机器等于把"能否进桌面"交给无人值守任务 |
| 3.19 | **引导菜单阶段黑屏的处置** | GRUB 菜单条目比原子版少(每套内核一条,不按部署累加);日常切换优先用一次性 `BootNext`/厂商菜单键,不依赖"看得见菜单";提供 `GRUB_TERMINAL=console` 类条件项(实施时核实落点) | 评论区有实例:装完独显驱动后每次开机在引导菜单阶段黑屏,但键盘仍可操作(数上下键能进 Windows);此时菜单黑屏不等于系统坏了,需要明确处置手段 | 把"引导菜单黑屏"当作系统损坏并重装(实际只需换终端模式或改用 BootNext) |

### 3.20 已验证与待验证的事实

| 事实 | 状态 | 来源等级 |
|---|---|---|
| Kubuntu 26.04 LTS「Resolute Raccoon」:Plasma 6.6.4、Qt 6.10.2、KDE Frameworks 6.24、KDE Gear 25.12.3、内核 7.0、**Wayland-only** | 已确认 | 高(Kubuntu 官方发布说明) |
| Kubuntu 是 Ubuntu 官方 flavor,基于 Ubuntu 26.04 LTS 基线;支持窗口由 flavor 自己的支持计划决定(历史 3 年;Ubuntu 主版 5 年,ESM 只覆盖 main 仓库) | 已确认 | 高(Ubuntu release-cycle 与 RecognizedFlavors 文档) |
| Kubuntu 使用 **Calamares** 安装器(不是 Ubuntu 主版的 Flutter 安装器) | 已确认 | 高(KDE Discuss 安装问答、Calamares 分区文档) |
| 最小安装(minimal)不含 snap;完整安装默认带 snapd,Firefox 以 snap 分发 | 已确认(社区实测帖) | 中 |
| `apt install firefox` 即便已配 Mozilla 仓库,仍可能把 `snapd` 作为依赖拉进来;需要 apt pin 压制 | 已确认(社区报告 + Mozilla 官方安装文档的 pin 步骤) | 中 |
| `do-release-upgrade` 升级路径会**重新引入 snap**(即使当前系统无 snap) | 已确认(社区实测) | 中 |
| Ubuntu 26.04 的 **Flutter 安装器**(`ubuntu-desktop-bootstrap`)手动安装时创建 ESP 有已知问题 | 已确认(用户报告);**对 Kubuntu 不适用**(用 Calamares),但实施时仍需核对 | 中 |
| Ubuntu 26.04 起 initramfs 由 **dracut** 生成(自 25.10 起为默认) | 已确认 | 高(Ubuntu 发行说明) |
| NVIDIA 走 Ubuntu 官方**预签名**包,由 `ubuntu-drivers install` 安装;Secure Boot 下**不需要自签、不需要 MOK 注册** | 已确认 | 高(Ubuntu 官方文档) |
| `/home` 是本地真目录(不是 `/var/home` 的符号链接);`~/.config`、`~/.ssh`、`~/.gnupg` 在本地 root | 已确认 | 高 |
| Ubuntu 内核同样包含 `ntfs3`,可读写 NTFS;但无 POSIX 权限语义(挂载时以固定 uid/gid/umask 呈现) | 已确认;需在挂载选项与工作流上适配(见 5.3) | 高 |
| 同盘两个 ESP 的固件支持:官方未承诺,社区实践可行 | **待实测**(列入 A 组验收) | 中 |
| Windows 11 ISO:微软不发布镜像 SHA256;Kubuntu ISO:官方发布 `SHA256SUMS`(附 `SHA256SUMS.gpg` 签名)可比对 | 已确认 | 高 |
| Online KMS 激活周期为 180 天,需每 7 天联系 KMS 主机自动续期 | 已确认(上游文档) | 高 |
| 部分厂商笔记本固件**只从第一块盘引导**(用户报告:惠普官方明确不支持从第二块盘启动) | 社区报告;作为双盘分支的硬约束写入厂商差异表 | 中 |
| 装完独显驱动后,部分机器在**引导菜单阶段黑屏**(键盘仍可用) | 社区报告(2026 年的实例);处置见决策 3.19 | 中 |

### 3.21 生命周期与发行版升级

| 项 | 决定 |
|---|---|
| 生命周期 | Kubuntu 26.04 LTS 支持窗口约 **3 年**(flavor 自己的支持计划);期间只收安全更新 |
| 升级方式 | **`do-release-upgrade`**(约 3 年一次),由 `scripts/linux/upgrade-release.sh` 承担前置核对与后置复核 |
| 前置 | 备份 `baseline/` 与 `/etc` 关键文件;记下当前内核与驱动版本;把 apt pin 文件与 Mozilla 源文件内容写进日志留档 |
| 后置 | 复检:会话仍是 Wayland、`nvidia` 模块仍加载且 `modinfo -F signer nvidia` 非空、桌面可用、**`snap list` 仍为空且 `dpkg -l snapd` 无输出**(S5 复核) |
| 失败处置 | 不满足后置判据 -> 按 `05-9` 把出问题的包降级并 `apt-mark hold`;系统级损坏走 4.8 原地重装两法 |
| 支持期取舍 | 3 年只收安全更新,不追新内核与新桌面;升级被写成正式卡,不再是"怕动"的操作 |

### 3.22 snap 规避(S1–S6,真源见 04 号设计第 3 节)

用户约束是"规避 snap 包",2026-09-22 确认采用 **S1+S2+S3 全套**;浏览器来源为 **Mozilla 官方 APT 仓库的 deb**(Flatpak 备选)。

| 编号 | 措施 | 可观测判据 |
|---|---|---|
| **S1** | 安装时选**最小安装(minimal)** | 装完 `snap list` 为空或命令不存在 |
| **S2** | 首启核对并清除残留:`snap list`、`dpkg -l snapd`;若存在先 `snap remove` 各应用再 `apt purge snapd` | `snap list` 报"no snaps installed"或命令不存在;`dpkg -l snapd` 无输出 |
| **S3** | **apt pin 压制**:`/etc/apt/preferences.d/no-snap` 里 `Package: snapd` + `Pin: release a=*` + `Pin-Priority: -1` | `apt-cache policy snapd` 显示候选为"无"或优先级为负 |
| **S4** | 浏览器改用非 snap 来源:首选 Mozilla 官方 APT 仓库的 deb(并给该仓库较高优先级);备选 Flatpak | `apt policy firefox` 显示来源为 Mozilla 仓库;`snap list` 仍为空 |
| **S5** | **升级后复核**:`do-release-upgrade` 会重新引入 snap,故升级卡必须包含"升级后跑 S2/S3 复核" | 升级后 `snap list` 仍为空、`dpkg -l snapd` 无输出 |
| **S6** | 常用功能用 deb/Flatpak 替代:软件商店用 Plasma 自带的 `plasma-discover`;固件更新用 `fwupd` | `plasma-discover` 可列出并安装 deb 与 Flatpak;`fwupdmgr --version` 正常 |

**为什么必须成套**:S1/S2 只解决"现在干净",S3 解决"以后一直干净且破功时报警"—— 留着 snapd 会被四条机制静默拉回:`kubuntu-desktop` 的 `Recommends: snapd`、归档里的 `firefox` 过渡包、`do-release-upgrade`、`snapd.refresh.timer`。S3 用 `Pin-Priority: -1` 而非 `apt-mark hold`:`hold` 只冻结已装版本的升级,包不存在时拦不住安装;pin -1 遇到 `Recommends` 安静跳过、遇到硬 `Depends` **响亮失败**,正是我们要的行为。实现落在 `05-14` 与 `scripts/linux/step-snap-free.sh`。

**边界(明确不做)**:不追求"系统里一个 snap 相关文件都没有"(过度清理会牵连系统);验收判据取"`snap list` 为空 + `dpkg -l snapd` 未安装 + 浏览器来源非 snap"这三条可观测事实。

### 3.23 三轨道(W / L / D)结构

| 项 | 决定 |
|---|---|
| 内容 | 三条可独立执行的轨道 + 一个共用底座,定义见 1.4 |
| 目的 | 满足"任一系统可单独安装";让"简化"落在单系统场景与文档组织上 |
| 边界 | **不砍任何既有机制**(snap 规避、`ntfs3` 共享盘、每卡一脚本、双模式 CLI、C1–C9 自检、A–F 验收、KMS 脚本激活全部保留) |
| 文档影响 | 手册按轨道重排(见第 4 节的文档映射),双系统专属内容收敛为 4 张增量卡 |

---

## 4. 分层结构

每个阶段 = 目的 + 输入 + 动作 + **产物** + 完成判据。产物缺失即视为该阶段未完成。

阶段到手册文档的映射(按轨道重排;本次修订后**手册 8 份 + 1 份入口页**,原 11 份按轨道合并,并新增"分盘"前置章节):

| 阶段 | 轨道 | 手册文档 |
|---|---|---|
| 入口(非流程) | 共用 | [docs/00-overview.md](../00-overview.md)(目标、四条不变量、参数表、三轨道地图;不写卡) |
| L0 共用底座 | 共用 | [docs/01-firmware.md](../01-firmware.md)(底座卡:固件设置 / 做两个安装介质 / 核对目标盘 / 落 L0 产物) |
| 分盘(安装前的前置章节) | 共用(W/L/D 三条轨道各自的分盘方式) | [docs/02-partitioning.md](../02-partitioning.md)(02-1 分盘总则与三种轨道的目标布局 + 02-2 轨道 W 分盘 / 02-3 轨道 L 分盘 / 02-4 轨道 D 分盘;值表:8 项分区目标值) |
| L1 + L2 | W(D 轨道也要) | [docs/03-windows.md](../03-windows.md)(Windows 全新安装与激活)+ L2 预检与基线闸门卡(原 `03-preflight.md` 并入;两者都在 Windows 侧、且必须在同一会话内连续完成)。轨道 W 的卡整体改号为 03-K(9 卡) |
| L3 | L | [docs/04-kubuntu.md](../04-kubuntu.md)(原 `04-ubuntu.md` 的改名目标;Kubuntu 安装,Calamares 手动分区) |
| L4 | L + D | [docs/05-first-boot.md](../05-first-boot.md)(首启收敛与健壮性;其中"共享盘挂载""家目录重定向"两张卡是 D 轨道的共存增量;共 14 张卡 `05-1` … `05-14`) |
| L5 | D | [docs/07-rescue.md](../07-rescue.md)(退役与救援;原 `06-decommission.md` 并入) |
| 验收 | 全部 | [docs/08-verification.md](../08-verification.md) |
| 风险与速查 | 全部 | [docs/10-faq.md](../10-faq.md)(症状卡 + 阶段风险速查;34 条风险总表保留在第 9 节) |

| 阶段 | 名称 | 目的 | 产物 | 完成判据 |
|---|---|---|---|---|
| **L0** | 装机前准备 | 把固件与介质调成目标状态 | `baseline/00-firmware.md` | 固件设定值与介质校验值记录齐全 |
| **L1** | Windows 全新安装 | 整盘分区一次定稿 + 系统 + 激活 + 预留 115GiB | `baseline/01-partitions.txt`、`01-activation.md`(分区表与激活状态) | 分区表与目标布局一致(含 115GiB 未分配);激活完成;Fast Startup 与休眠已关 |
| **L2** | 预检与基线 | 只读体检 + 建立可回滚基线 | `baseline/02-preflight-report.md`、`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt` | 报告结论为"允许进入 L3"(无红项) |
| **L3** | Kubuntu 安装 | 装 Linux 且不侵犯 Windows 引导 | `baseline/03-efi-layout.txt` | Kubuntu 可启动;两个 ESP 各自完整且互不干扰;`\EFI\Microsoft\` 与基线一致;`BootOrder` 首项仍为 Windows |
| **L4** | 首启收敛 | 驱动(Ubuntu 官方预签名包)、Wayland、挂载、时间、蓝牙、snap 规避、包级回退 | `baseline/04-first-boot.md`、`04-robustness.md`(首启收敛与健壮性核对) | 验收 B 组与 F 组全绿 |
| **L5** | 退役与救援 | 安全撤除与故障恢复 | [checklists/rollback.md](../../checklists/rollback.md) | L5 流程可执行(参考设备需真跑一次) |

### 4.1 L0 装机前准备

- 固件:SATA 操作模式设为 **AHCI / NVMe**(关闭 VMD 或 RAID On)、**Secure Boot 保持开启**、Fast Boot 关闭;
- 介质:Windows 11 官方安装 U 盘;**Kubuntu 26.04 LTS 官方安装 U 盘**(或 Ventoy 多 ISO);介质校验按各官方站点发布的校验值(Kubuntu 有官方 `SHA256SUMS` 与 `SHA256SUMS.gpg`;Windows ISO 官方不发布镜像哈希,只做"官方下载域 + 官方安装器校验");
- **关键点**:VMD 必须在安装 Windows **之前**关闭。若 Windows 已按 RAID On 装好再关闭,系统将无法启动,需先预置存储驱动再进安全模式完成切换(该路径作为附录分支,不属于本方案主路径)。

### 4.2 L1 Windows 全新安装

- 整盘重排:ESP-Windows 2GiB -> MSR 16MiB -> **Windows 系统 C: 200GiB** -> **Windows 数据 D: ≈635GiB** -> **为 Ubuntu 预留 115GiB 未分配空间** -> WinRE;
- **`templates/partitions.txt` 的操作逻辑与注释均已同步**:预留仍是"D: 之后一段 115GiB 未分配";L3 再在这段空间里切出 Ubuntu 的 ESP 1GiB + `/boot` 1GiB + root ≈113GiB(见 5.1);
- **系统盘隔离**:C: 只放系统与程序;桌面/文档/下载/图片/视频/音乐等**已知文件夹、游戏库与容器镜像全部重定向到 D:**。所以"崩溃后原地重装"只需格式化 C:,数据与 Linux 侧均不受影响(见 4.8);
- ESP-Windows 必须**预建**(Windows 安装界面无法把自动创建的 100MB ESP 改成 2GiB),因此使用 `diskpart` 预建分区表;
- 安装完成后立即:关闭 Fast Startup 与休眠文件、完成脚本激活、记录激活状态;
- 风险提示:Windows 安装程序对 WinRE 分区的放置有版本敏感性,若它把恢复分区放进预留空间,记录偏差并据实调整(**两块 ESP 与 Ubuntu root 的尺寸不允许被削减**)。

### 4.3 L2 预检与基线(硬闸门)

- 只读体检:BootOrder 与固件启动项、ESP 目录树与剩余空间、BitLocker 状态、存储控制器模式、Fast Startup/休眠、磁盘布局;
- 基线备份(**在 L2 内生成**):ESP 文件树备份 + 清单 -> `baseline/02-esp-backup/`(块级整块镜像可选,不属主路径——Windows 原生无 `dd`);`bcdedit /enum firmware` 固件启动项快照 -> `baseline/02-firmware-entries.txt`;分区快照 -> `baseline/02-partitions.txt`。产物名前缀取所在阶段号;
- **注意(L2 备份的边界)**:此时 Kubuntu 尚未安装,`02-esp-backup/` **只覆盖 Windows 的那块 ESP**,**不含** `\EFI\ubuntu\`,因此**不能用来还原 Linux 引导**。Linux 引导的还原来源有两处(L5 退役备份里的 `\EFI\ubuntu\`;或在 live 环境挂 root+ESP 后 chroot `grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu` + `update-grub`,再 `efibootmgr` 补条目并断言 `BootOrder` 首位仍是 Windows Boot Manager),两处的唯一定义点在 `07-rescue.md` 的救援流程里;
- 基线复核:复核 L1 记录的分区表(`baseline/01-partitions.txt`)与激活状态(`baseline/01-activation.md`)未被后续操作改变;
- **闸门规则**:存在红项 -> 禁止进入 L3;存在黄项 -> 记录后带风险继续。

### 4.4 L3 Kubuntu 安装

- **先手工预建 Ubuntu 的三块分区**(在 L1 预留的 115GiB 未分配空间里切出):**ESP-Ubuntu 1GiB(FAT32 / EFI System)** + **`/boot` 1GiB(ext4)** + **root ≈113GiB(ext4)**;
- 安装器是 **Calamares**(不是 Ubuntu 主版的 Flutter 安装器),手动分区页里**只做"指定挂载点"**,不让它重排分区表、不让它新建或改动其它分区:ESP-Ubuntu -> `/boot/efi`(格式化)、`/boot` -> `/boot`(格式化)、root -> `/`(格式化);
- **不让安装器动 Windows 的 ESP**(I3;Calamares 把引导装到 `/boot/efi` 所指的那块 ESP,把 Windows 的 2GiB ESP 设成 `/boot/efi` 就等于当场毁掉 Windows 引导);
- 不创建 swap 分区;首启后再配置 zram 与 swapfile;
- 引导写入 `\EFI\ubuntu\`(安装器默认;条目显示名须实测核实),**期间不改动 `BootOrder`**;
- Secure Boot 全程保持开启;
- **已知风险路径**:Calamares 的分区界面**没有"引导器位置"独立选项**,容易误选 Windows ESP。处置:① `04-2` 卡的前置核对(`check-partition-plan.sh` 断言 Windows ESP 未被挂载、尺寸仍是 2048MB)+ 在分区页显式确认 `/boot/efi` 指向 ESP-Ubuntu;② 若仍写坏引导,按 `07-rescue.md` 在 live 环境手工修;③ 最坏情况退回轨道 W,损失可控(L2 基线可用)。

### 4.5 L4 首启收敛

| 项目 | 做法 | 回滚点 |
|---|---|---|
| 显卡驱动 | **`ubuntu-drivers install`** 装 Ubuntu 官方**预签名** `nvidia` 包;Secure Boot 下**不需要自签、不需要 MOK 注册**;保留 nouveau 作为兜底 | 卸载驱动包回 nouveau |
| 显示策略 | 集成显卡主显示 + 独显 PRIME offload(独显单显卡设备跳过) | 恢复默认 PRIME 模式 |
| 共享数据分区挂载 | `ntfs3` **读写**挂载 `D:`,固定 `uid/gid/umask` + `windows_names` + `nofail` + `noatime`;`fstab` 写错时带 `nofail` 不阻断启动 | 改成只读挂载或移除该行 |
| 家目录数据重定向 | 用 `~/.config/user-dirs.dirs` 把**文档/下载/图片/桌面/视频/音乐**指向共享盘;`~/.config`、`~/.ssh`、代码仓库**留在本地**(NTFS 无 POSIX 权限语义) | 还原 `user-dirs.dirs` 的 `.dbk.bak` 备份 |
| 时间 | `RTC in local TZ: no`(Linux 用 UTC),Windows 侧可配合 `RealTimeIsUniversal=1` | 可逆 |
| 蓝牙 | 同步两系统配对密钥(上游 `bt-keys-sync`,依赖 `chntpw`);按上游建议"以 Windows 侧密钥为准",不做反向写入 | 注册表有备份,可还原 |
| 系统级工具 | `apt install` 装完**立即生效**(没有"分层安装需重启");GUI 应用优先 deb / Flatpak,软件商店用 `plasma-discover` | `apt-get purge` 该包 |
| snap 规避 | 按 3.22 的 S1–S6 执行:最小安装 + 清除残留 + apt pin 压制 + Mozilla 官方 deb 浏览器 | 删除 pin 文件即可解除压制(不推荐) |
| 固件 | `fwupd` 识别设备即可;固件更新仍优先在 Windows 侧完成 | 无 |
| 回 Windows | 提供一键回 Windows 的入口(BootNext 或固件菜单) | 无 |

### 4.6 L5 退役与救援

退役流程顺序不可更换:

```
1. 在 Kubuntu 中把 BootOrder 首项改回 Windows Boot Manager
2. 备份当前 NVRAM 与两块 ESP 的现状(最后一道保险;此备份含 \EFI\ubuntu\)
3. 重启进 Windows,用「磁盘管理」删除 Ubuntu 的三块分区(ESP-Ubuntu / /boot / root;确认引导已归位后再删)
4. 清理 NVRAM 中残留的 ubuntu 条目
5. 可选:把腾出的空间扩展进**相邻分区**(目标布局下未分配空间紧邻 D:,C: 不相邻不可扩)
```

**明确禁止**:先格式化 Linux 分区再修引导。

### 4.7 L4 附加:**Kubuntu 健壮性设计(防崩溃)**

目标是"不会因为一次升级、一个驱动或一块盘的问题而失去可用系统"。九项措施,每项都对应一个可回滚点:

| # | 措施 | 做法 | 回滚点 |
|---|---|---|---|
| R1 | **变更前备份** | 变更(装驱动、改 `fstab`、改 `user-dirs.dirs`、升级)之前备份 `baseline/` 与 `/etc` 关键文件;脚本内置 `.dbk.bak` 备份 | 还原 `.dbk.bak` / 基线副本 |
| R2 | **包级回退** | 某次升级把某个软件搞坏:`apt install <包>=<旧版本>` + `apt-mark hold`;由 `scripts/linux/rollback-pkg.sh` 列出可用版本、读出已 hold 清单与 apt 历史;参考设备必须**真做一次演练** | 降级到旧版本,或 `--unhold` 回到仓库版本 |
| R3 | **旧内核保留** | 保留至少一个可用的旧内核与 GRUB 条目(`/boot` 独立 1GiB,不自动清空);不进桌面时可在 GRUB 菜单选旧内核启动 | 选旧内核条目 |
| R4 | **永久救援介质** | 常备 Kubuntu 安装 U 盘(兼作 live 环境),并从第一台参考设备起记录"已验证可用"标记 | 从 U 盘进入 live 环境修复 |
| R5 | **崩溃可观测** | 启用 journald **持久化**(`/var/log/journal`);自建日志目录 `/var/log/dbk/`;日志与系统版本无关,重装 root 前先导出 | 无(仅提升可诊断性) |
| R6 | **OOM 与内存压力防护** | 核对 zram 已启用 + swapfile 4GiB;确认 `systemd-oomd` 处于启用状态 | 调整 zram/swapfile 大小 |
| R7 | **常开 SSH 救援通道** | 启用 `sshd`:桌面挂死时仍可从另一台机器登录排障(对"远程开发"定位尤其关键) | 关闭服务 |
| R8 | **保守更新策略** | `unattended-upgrades` 只装安全更新、**不自动重启**(见 3.18);内核/驱动升级前先按 R1 备份并记录版本 | 降级并 hold 出问题的包 |
| R9 | **磁盘健康监控** | 安装 `smartmontools`(`smartd`)并确认日志告警生效;共享盘 `fstab` 行带 `nofail` | 无(提前发现硬件故障) |

**明确不做的**,以及原因:休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车)、**`snapper` / `grub-btrfs` / btrfs 快照回滚 / ZFS root 快照**(用户明确否决,见 3.7 与 04 号设计 2.1)、自定义 Secure Boot 密钥(改动签名链会新增风险)。

### 4.8 L5 附加:崩溃后**在原系统盘重装**的两法

两法共用前提:`baseline/` 产物齐全可用(分区表、ESP 镜像、固件启动项快照),救援 U 盘在位。**先判断崩溃在哪一层**——若只是引导层损坏,不要重装,先走 4.6 的引导复原。

#### 办法一:Windows 崩溃 -> 只重装 Windows(仅格式化 C:)

| 步骤 | 要点 |
|---|---|
| 1 | 用官方 ISO 引导,进入"自定义安装" |
| 2 | **只格式化 C:**;数据分区 D:、Ubuntu 的三块分区与两块 ESP 一律不动。逐分区核对,**禁止"删除所有分区"** |
| 3 | 安装程序只在**它自己那块 ESP**(第一块,ESP-Windows)上重建 `\EFI\Microsoft\` 与 BCD,并可能覆盖该 ESP 上的 `\EFI\BOOT\bootx64.efi`(属正常);**Ubuntu 的独立 ESP 不受影响** |
| 4 | 首次进桌面:关 Fast Startup 与休眠、重新完成 KMS 激活、恢复已知文件夹到 D: 的重定向 |
| 5 | **复查四条不变量**:BootOrder 首项、`\EFI\Microsoft\` 内容、`{bootmgr}` path、ubuntu 条目仍在;用厂商菜单键验证 Kubuntu 仍可启动 |
| 风险 | 误格 D: 或 Ubuntu 分区 -> 灾难性;Windows 可能新建恢复分区并占用预留空间(记录偏差) |

#### 办法二:Kubuntu 崩溃 -> 只重装 Kubuntu(只格式化 root)

| 步骤 | 要点 |
|---|---|
| 1 | 用 Kubuntu 安装 U 盘引导,**动手前先把 `~` 下要留的文件备份到共享盘(D:)**(见下方风险行) |
| 2 | Calamares 里选手动分区:**只把 root 挂载点(≈113GiB ext4)标记为格式化并挂 `/`**;**ESP-Ubuntu(挂 `/boot/efi`)与 `/boot` 绝不勾选格式化**;Windows 各分区一律不动 |
| 3 | 安装写入 `\EFI\ubuntu\`(与 Windows 引导并存),期间不改 `BootOrder` |
| 4 | 首启:按 4.5 与 4.7 的清单重放驱动(`ubuntu-drivers`)、挂载、时间、蓝牙、snap 规避与健壮性配置 |
| 5 | 复查四条不变量;把 `~` 的备份按需取回 |
| 风险 | **误格 ESP-Ubuntu 或 `/boot`** -> Kubuntu 引导丢失(可在 live 环境确认 `grub-efi-amd64-signed` 与 `shim-signed` 在位后 `grub-install` + `update-grub` 修复);**误格 ESP-Windows** -> 同时破坏 Windows 引导,这是全流程最危险的一步(ESP 镜像可复原,但必须先有基线)。另:用户数据在 root 分区内,**只格 root 就会丢**,因此第 1 步的备份是硬要求,不做"数据一定还在"的假设 |

**第三选择(不是重装)**:引导层损坏而系统分区完好 -> 按 `07-rescue.md` 的救援流程处置(ESP 镜像还原 + `bcdboot` 重建 Windows 引导;或 live 环境 `grub-install` + `update-grub` 重建 Kubuntu 引导)。

---

## 5. 分区表与设备参数

### 5.1 目标分区表(标称 1TB 的 NVMe;下表按 **1024GB 型号 = 实际可用约 953.7GiB** 制定,合计 = 953.016GiB)

| 序号 | 分区 | 大小 | 类型 | 挂载 / 用途 |
|---|---|---|---|---|
| 1 | ESP-Windows | **2GiB** | EFI System(FAT32) | **只给 Windows**;只放 `\EFI\Microsoft\` 与 `\EFI\BOOT\` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 C: | **200GiB** | NTFS | 系统与程序;**原地重装时唯一被格式化的分区** |
| 4 | Windows 数据 D: | **≈635GiB** | NTFS | 游戏库、下载、文档、容器镜像;已知文件夹重定向的目标;**双系统共享分区(3.16 / 5.3)** |
| 5 | **ESP-Ubuntu** | **1GiB** | EFI System(FAT32) | Kubuntu 独立 ESP;只放 `\EFI\ubuntu\`;挂 `/boot/efi` |
| 6 | **`/boot`** | **1GiB** | ext4 | 独立分区:重装 root 时可选择保留内核与 GRUB 模块 |
| 7 | **Ubuntu root** | **≈113GiB** | ext4 | `/`(Ubuntu 默认文件系统;不用 btrfs,因为不需要快照) |
| 8 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈ 953GiB:2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1。Ubuntu 侧合计 **115GiB**(= 1 + 1 + 113),与决策 3.6 一致;**共享数据盘 ≈635GiB,约占全盘三分之二**。

**容量偏离分支(必须执行)**:上表按 1024GB 型号(可用 953.7GiB)制定。若目标设备是 **1000GB 型号(可用仅 931.3GiB)**,则本表合计 953.016GiB **装不下**,须把 **`D:` 从 ≈635GiB 减到 ≈613GiB**(其余七项一律不动:Ubuntu 侧 115GiB、`C:` 200GiB、两块 ESP、`/boot`、WinRE),并把该偏差写进 `baseline/` 与参数表 `DISK_SIZE`;`02-partitioning` 的 `02-1`/`02-3`/`02-4` 卡与 `check-partition-layout.ps1` 的期望值同步使用调整后的数值。**不得为了塞进上表而削减 Ubuntu 侧那 115GiB 或关闭 115GiB 预留**。

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
| `UBUNTU_ESP_SIZE` | 目标 ESP-Ubuntu 大小 | 1GiB |
| `BOOT_SIZE` | 目标 `/boot` 大小 | 1GiB(ext4,独立于 ESP) |
| `ROOT_SIZE` | 目标 Ubuntu root 大小 | ≈113GiB(ext4) |
| `WINDOWS_SYSTEM_SIZE` | 目标 Windows 系统分区大小 | 200GiB |
| `WINDOWS_DATA_SIZE` | 目标 Windows 数据分区大小 | ≈635GiB |
| `SECURE_BOOT` | Secure Boot 目标状态 | 开启 |
| `DISK_MODEL` | 目标磁盘型号(安装前核对,**防装错盘**) | Samsung MZVLQ1T0HBLB |
| `DISK_SIZE` | 目标磁盘容量 | 标称 1TB / 约 953GiB |
| `SHARED_PART_UUID` | 共享数据分区(D:)的 UUID | 安装后由 `blkid` 获取 |

对照说明:Linux 侧参数由更早方案的"`ROOT_SIZE` 100GiB + `SNAPSHOT_SIZE` 15GiB"改为"`UBUNTU_ESP_SIZE` 1GiB + `BOOT_SIZE` 1GiB + `ROOT_SIZE` ≈113GiB"(快照分区参数不再存在,`SNAPSHOT_SIZE` 已删除)。**镜像来源类参数不再存在**:基础系统是 Kubuntu 官方镜像,不需要"第三方预构建镜像的分支引用"这类字段。

### 5.3 跨系统共享数据分区(两个系统都能访问的磁盘)

**结论:有,就是 Windows 数据分区 `D:`(≈635GiB,NTFS)。** Windows 侧原生访问,Kubuntu 侧以 `ntfs3` **读写**挂载。办公文件集中放在约定目录(例如 `D:\Shared\`)下,切系统就能接着干,不需要拷贝或传输。

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

用法约定(与决策 3.6 的 root 容量直接相关):Kubuntu 侧用 `~/.config/user-dirs.dirs` 把**桌面 / 文档 / 下载 / 图片 / 视频 / 音乐**指向共享盘对应目录,文档类数据因此完全不占 root;**不要**把 `~/.config`、`~/.ssh`、代码仓库或其他依赖 POSIX 权限语义的工程放到共享盘上。

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
6. **L4 任何驱动 / 包 / 升级变更之前**:先确认"回 Windows 的入口"可用,并按 `05-9` 记下要回退的包与版本、备份 `baseline/` 与 `/etc` 关键文件(R1)。

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
| L3 | 重启直接进 Windows | 用厂商启动菜单键手动选 ubuntu(一次性);核对固件条目列表 | 无需回滚 |
| L3 | **Calamares 在写引导前中止 / 误把 Windows ESP 设为 `/boot/efi`** | 按 4.4 的前置核对(显式确认 `/boot/efi` 指向 ESP-Ubuntu)+ 只指定挂载点重来;仍失败则按 `07-rescue.md` 在 live 环境手工修 | 退回轨道 W(Windows 单系统);Windows 引导被写坏时走 ESP 镜像还原 |
| L3 | 两个 ESP 中只有一个被固件识别 | 记录为偏离项;按第 10 节评估"共用 ESP 分支" | 无副作用(记录) |
| L3 | 停在 `grub>` / `grub rescue>` | ① `ls` 找分区 -> `set prefix` -> `insmod normal` -> `normal`;② 直接回 Windows:`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` -> `chainloader` -> `boot` | 基线回滚(ESP 镜像) |
| L3 | Secure Boot 拒载 | 核查 `mokutil --sb-state`;驱动走官方预签名包,不在 L3 引入自签 | 无副作用 |
| L4 | 装驱动后黑屏 / 闪烁 | 在 GRUB 菜单选旧内核启动;或从 live 环境卸载驱动包回 nouveau | **包级回退**(R2) |
| L4 | 驱动不加载 / 签名者取不到 | `modinfo -F signer nvidia` 与 `mokutil --sb-state` 双判据;`ubuntu-drivers install` 重装官方包;**不要关 Secure Boot** | 卸载驱动包回 nouveau |
| L4 | `fstab` 写坏导致进不去系统 | GRUB 中追加 `systemd.unit=emergency.target` | 模板已含 `nofail` |
| L4 | 时间错乱 / 蓝牙反复重配对 | RTC=UTC(或 Windows `RealTimeIsUniversal=1`);密钥同步脚本 | 均可逆 |
| L4 | 升级后系统不可用(内核/驱动) | 在 GRUB 菜单选旧内核启动,按 `05-9` 把出问题的包降级并 hold | **包级回退**(R2) |
| L4 | 桌面无法进入 | 用另一台机器 SSH 登录排障(R7);必要时选旧内核启动 | 选旧内核 / 降级包 |
| L4 | **snap 被装回来**(升级或 `apt install firefox` 拉入) | 跑 `scripts/linux/step-snap-free.sh --check` 定位来源,按 3.22 的 S2/S3 清除并恢复 pin | 重新执行 S2 + S3 |
| L4 | KMS 激活到期未续期 | 检查续期任务与 KMS 主机可达性,手动触发一次续期 | 重新执行一次在线激活流程 |
| L5 | **Windows 系统分区损坏** | 走 4.8 办法一:只格式化 C: 重装 | D: 数据、两块 ESP 与 Ubuntu 侧不受影响 |
| L5 | **Kubuntu root 损坏** | 走 4.8 办法二:只格式化 root 重装(先备份 `~`) | Windows 侧与 D: 不受影响(前提是已备份) |
| L5 | 引导层损坏而系统分区完好 | **不要重装**:按 `07-rescue.md` 处置(ESP 镜像还原 + `bcdboot` 重建 / live 环境 `grub-install` + `update-grub` + NVRAM 清理) | 基线回滚 |
| L3 | U 盘启动或安装器黑屏 | 在引导菜单按 `e`,给内核行加 **`nomodeset`** 临时应急;**能进系统后立即装好显卡驱动并移除该参数**——它与 Wayland 冲突(Wayland 需 KMS),只是应急手段 | 移除参数 |
| L3 | 手动分区界面看不到"引导器位置"选项 | 这是 Calamares 的**正常行为**:本方案**不依赖**安装器写 Windows 的 ESP,改用 4.4 的"手工预建 Ubuntu 分区 + 只指定挂载点";确认安装器没有把 Windows ESP 当目标即可继续 | 无 |
| L3 | 混合模式下安装器/首启黑屏 | 按决策 3.17 走 MUX 分支:BIOS 切独显直连拿到可用系统,再权衡是否切回混合 | 切回混合模式 |
| L4 | 装完独显驱动后,每次开关机在引导菜单阶段黑屏(键盘仍可用) | 按决策 3.19 处置:换终端模式;日常切换改用 BootNext/厂商菜单键 | 移除该配置行 |
| L4 | 内核/驱动更新后黑屏或不进桌面 | 更新策略已收紧(3.18);若已发生:选旧内核启动,并按 `05-9` 降级 + hold | 包级回退 |
| 任意 | **两个系统一起**异常、频繁死机/蓝屏 | **先按硬件问题排查**(内存测试、SMART、温度、电源),不要归因于"双系统互相影响"——两系统运行期不共享状态,只有引导层会互相干扰 | 无 |
| 任意 | 曾经长按电源强制重启过 | 下次启动前先做一次文件系统检查(`fsck` 或从 live 环境检查);以后用 **REISUB(SysRq)** 代替长按电源 | 无 |

### 7.1 周期性巡检

每次 Windows 大版本更新或累积更新后,重跑基线核对:**四项**(与 `verify-baseline.ps1` 的输出一一对应):

1. `BootOrder` 首位仍是 Windows Boot Manager;
2. Windows ESP 的 `\EFI\Microsoft\` 与基线清单(`02-esp-backup/manifest.sha256`)逐文件一致;
3. `{bootmgr}` 的 `path` 与基线一致;
4. BitLocker 状态与基线一致。

**Kubuntu 侧两项**:

5. **系统体检**:`scripts/linux/check-health.sh --check` 报 PASS(会话为 wayland、**snap 零残留**、`systemctl is-system-running` 为 running、根分区余量 ≥10%);
6. **驱动来源与签名**:`scripts/linux/check-signature.sh --check` 报 PASS(`modinfo -F signer nvidia` 非空且 `mokutil --sb-state` 为 SecureBoot enabled)。

已知事故类型:2024-08 的 SBAT / Secure Boot DBX 更新曾导致双系统机器无法引导 Linux(微软已确认)。缓解:常备 Kubuntu 安装 U 盘(兼 live);必要时清理 SBAT 策略(`mokutil --set-sbat-policy delete`)。

### 7.2 回滚的四种粒度

| 粒度 | 场景 | 手段 |
|---|---|---|
| **单包回退** | 某次升级把某个软件搞坏 | `apt install <包>=<旧版本>` + `apt-mark hold`;`rollback-pkg.sh` 列出可用版本与已 hold 清单 |
| **配置回退** | 自己改坏配置(`fstab`、`user-dirs.dirs`、apt 源) | 变更前备份 `baseline/` 与 `/etc` 关键文件;脚本内置 `.dbk.bak` |
| **系统级** | 系统级损坏,包级手段救不回 | **原地重装两法**(只格 `C:` / 只格 root,ESP 绝不格式化);数据在 `D:` 不受影响 |
| **引导级** | ESP 或固件启动项被破坏 | ESP 基线镜像还原 + `bcdboot` 重建 Windows 引导,或 live 环境 `grub-install` + `update-grub` 重建 Kubuntu 引导 |

**已接受的取舍(登记在案)**:**没有"一条命令回到上一个可用系统"的能力**。恢复时间从"几分钟"变为"30–60 分钟(脚本化重装 + 配置重放)"。这是为"日常省心"付的价(04 号设计 D4 / 第 7 节)。

**明确不引入**:snapper、timeshift、grub-btrfs、btrfs 快照、ZFS root 快照(见 3.7 与 04 号设计 2.1)。

---

## 8. 验收标准

唯一判据是 [docs/08-verification.md](../08-verification.md) 全绿;不以"装完了"为准。

**A. 引导安全组**

| 检查项 | 判据 |
|---|---|
| 默认启动项 | `BootOrder` 首位为 Windows Boot Manager;连续重启 3 次均默认进 Windows |
| Windows 引导未被污染 | `\EFI\Microsoft\` 与 L2 基线逐文件一致 |
| 引导路径未被篡改 | `{bootmgr}` 的 `path` 与基线一致 |
| 不变量落地 | ubuntu 条目位于 `BootOrder` 末尾;全程未使用 `efibootmgr -o`;`\EFI\ubuntu\` 与 Windows ESP 分属两块不同分区 |
| **两个 ESP 互不干扰** | 在 Kubuntu 侧任何引导相关操作后:Windows ESP 的 `\EFI\Microsoft\` 逐文件不变;`BootOrder` 首位仍是 Windows Boot Manager;两块 ESP 可分别挂载并各自内容完整 |
| **可撤除性演练** | 备份 ESP 后临时删除 `\EFI\ubuntu\`(保留分区)-> 重启确认**自动进 Windows 且无 `grub rescue`** -> 用另存的副本还原 `\EFI\ubuntu\`(L2 基线**不含**该子树,见 4.3)并复测。**参考设备必做,其他设备推荐** |

**B. 系统功能组**:会话类型为 `wayland`(且无 X11 会话可选);GPU 驱动状态正常或有 nouveau 兜底且无签名拒绝日志;**驱动来源为 Ubuntu 官方预签名包**(`ubuntu-drivers devices` 的推荐行与实装一致、`apt policy nvidia-driver-<版本>` 候选来自 Ubuntu 归档);Secure Boot 保持开启;**snap 零残留**(`snap list` 为空 + `dpkg -l snapd` 无输出 + `apt-cache policy snapd` 无候选或被 pin 到 -1);共享数据分区以 `ntfs3` **读写**挂载成功且 `nofail`;**跨系统双向可见性**(Windows 写入 -> Linux 读到;Linux 写入 -> Windows 读到);**家目录重定向生效**(桌面/文档/下载/图片/视频/音乐指向共享盘);`RTC in local TZ: no`;切换系统后蓝牙无需重新配对;`fwupd` 能识别设备。

**C. 双系统切换组**:从 Windows 用 BootNext(或厂商菜单键)一次性进 Linux 且**不改变**下次默认启动项;从 Linux 一键回 Windows;切换 3 次后 A 组首项检查仍成立。

**D. 可撤除性组**:按 L5 五步顺序完整推演(参考设备真做一次);结束后固件条目与实际状态一致。并额外核对:

| 检查项 | 判据 |
|---|---|
| 系统盘隔离生效 | 已知文件夹与游戏库均位于 D:;C: 不含用户数据(逐项核对重定向) |
| 原地重装两法可用 | 两法各至少完整推演一次(参考设备至少真做一法);重装后 A 组四条不变量复检通过 |
| 非重装逃生路径可用 | 引导层损坏场景已验证:ESP 镜像还原 + `bcdboot`(Windows)或 live 环境 `grub-install` + `update-grub`(Kubuntu)均可行 |

**E. 记录组**:`baseline/` 产物齐全且未入库(`git status` 干净);记录本次与设备参数表的偏差,回写到 [docs/00-overview.md](../00-overview.md)。

**F. 健壮性组(防崩溃)**

| 检查项 | 判据 |
|---|---|
| **包级回退演练 + 原地重装演练** | **真做一次**:按 `05-9` 把某个包降到旧版本并 `apt-mark hold` -> 重启 -> 该软件可用 -> `--unhold` 回到仓库版本;并按 `07-4` 或 `07-5` 完整推演一次原地重装(只格 `C:` 或只格 root),确认 `D:` 上的数据与要留的文件在重装前后哈希不变 |
| 变更前备份可用 | 变更前能按 `05-9` 与 `05-13` 的口径备份 `baseline/` 与 `/etc` 关键文件(`.dbk.bak` 存在);apt pin 与 Mozilla 源文件内容能写进日志留档 |
| 旧内核可回退 | GRUB 菜单里至少保留一个可用的旧内核条目,并能从中启动 |
| 崩溃可观测 | journald 为持久化模式:重启后能读取上一次启动的日志(`journalctl -b -1`) |
| 更新策略 | `unattended-upgrades` 只装 `-security` 且 `Automatic-Reboot "false"`(核对 apt 配置片段) |
| 远程救援通道 | 从另一台机器可 SSH 登录,且无需桌面会话 |
| OOM 防护 | `systemd-oomd` 处于启用状态;zram 生效 |
| 磁盘健康 | `smartd` 运行中且 `smartctl -H` 报告 PASSED |
| 挂载稳健 | L4 写入的挂载(共享盘、`/boot`、swapfile)带 `nofail`;`/boot/efi` 属必需挂载、**不加** `nofail`(加了会让 ESP 挂载失败被静默跳过) |

**通过定义**:任一组存在未勾选项且无在案记录的"已知例外" -> 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。

---

## 9. 风险登记

34 条;等级为来源可信度与发生概率的综合(高 = 官方文档/上游 issue 级证据,中 = 社区报告或需实测)。Kubuntu 变体增补的 snap 与 Calamares 两类风险另见 `04-kubuntu-variant-design.md` 第 9 节。

| # | 风险 | 后果 | 缓解 | 等级 |
|---|---|---|---|---|
| 1 | **Intel VMD / RAID On** | Linux 安装器看不到磁盘 | 在装 Windows 之前就设为 AHCI/NVMe(全新设备的最大红利);已装好才改则走驱动预置分支 | 高 |
| 2 | **BitLocker** | 改分区表/固件设置触发恢复密钥索要 | 备份 48 位恢复密钥 -> 挂起保护 -> 操作 -> 恢复保护 | 高 |
| 3 | **Windows 更新重写 ESP / SBAT-DBX 事件** | Linux 引导消失或出现签名校验失败 | 两块 ESP 分离后 Windows 侧操作只触及第一块;ESP 镜像备份;常备 Kubuntu 安装 U 盘;必要时清理 SBAT 策略 | 高 |
| 4 | **Fast Startup + 双写 NTFS** | 共享数据分区损坏 | L1 强制关闭 Fast Startup 与休眠;共享盘禁止在 Windows 处于休眠状态时被 Linux 挂载 | 高 |
| 5 | **ESP 尺寸与系统体量不匹配**(ESP-Ubuntu 1GiB) | 引导文件放不下 | ESP-Ubuntu 定为 1GiB;内核与 initrd 在独立 `/boot` 而非 ESP;两块 ESP 尺寸不可被安装器削减 | 中 |
| 6 | **引导顺序被改** | 删除 Linux 后卡 `grub rescue` | 四条不变量 + L5 退役流程 + L2 基线 | 高 |
| 7 | **驱动签名链缺失 / 自签易碎** | 驱动不加载,严重时无桌面 | 只用 Ubuntu 官方**预签名** `nvidia` 包(`ubuntu-drivers install`),不关 Secure Boot、不自签密钥;`modinfo -F signer nvidia` 与 `mokutil --sb-state` 双判据;保留 nouveau 兜底;巡检复核 | 高 |
| 8 | **Windows 安装程序对恢复分区放置的版本敏感性** | 预留空间被占用,分区表偏离计划 | L2 逐项核对分区表;偏离可接受(仅两块 ESP 与 Ubuntu root 尺寸不可削减) | 中 |
| 9 | **双系统时间 / 蓝牙状态分裂** | 时钟错乱、设备需反复重新配对 | RTC=UTC;上游 `bt-keys-sync` | 高 |
| 10 | **KMS 续期依赖可达的 KMS 主机** | 180 天周期内未成功续期会导致激活失效 | 保留续期任务并定期核对激活状态;失效时重新执行一次在线激活流程 | 中 |
| 11 | **`ntfs3` 写入导致共享盘数据损坏** | 办公文件丢失 | 关键目录保留第二份备份;避免在 Linux 侧批量重命名/移动大目录 | 中 |
| 12 | **共享盘被 BitLocker/设备加密** | Linux 侧无法挂载,共享方案失效 | 装机时 `D:` 保持不加密;若 Windows 自动启用设备加密,先解密再继续 | 中 |
| 13 | **POSIX 语义差异** | 依赖符号链接/权限位的工具在共享盘上报错 | 共享盘只放文档类数据;代码与工程目录留在 Linux 本地 | 高 |
| 14 | **自动更新被放开** | 内核或驱动在无人值守时变更,黑屏或进不了桌面 | `unattended-upgrades` 只装 `-security`、不自动重启(3.18);升级前先备份并记录版本 | 中 |
| 15 | **反复长按电源强制重启** | 文件系统损坏、满屏报错进不去 | 用 REISUB(SysRq)安全重启;事后做文件系统检查;把"不要反复强断"写进排障手册 | 中 |
| 16 | **把硬件故障误判为双系统问题** | 浪费时间、误删系统、掩盖真实故障 | 硬件优先 triage:内存 / 磁盘 / 温度;明确"运行期两系统互不影响" | 中 |
| 17 | **引导菜单阶段黑屏** | 误以为系统损坏而重装 | 决策 3.19:换终端模式 + 用 BootNext 切换;先确认键盘仍有效 | 中 |
| 18 | **安装时选错目标磁盘** | 误格数据盘或另一系统 | 参数表用 `DISK_MODEL`/`DISK_SIZE`,安装前逐盘核对 | 中 |
| 19 | **双盘机型固件只认第一块盘** | 引导文件放错盘导致装完无法启动 | 厂商差异表增加"能否从第二块盘引导"列;**两块 ESP 都必须在第一块盘** | 中 |
| 20 | **国内镜像站下载未校验** | 镜像损坏或被替换 | 下载后核对官方发布值:Kubuntu ISO 按官方 `SHA256SUMS`(并 `gpg --verify` 其签名);Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验"。镜像站只作为下载加速,不作为信任源 | 高 |
| 21 | **第三方 PPA 引入不可控包** | 系统不稳定、依赖被替换 | 默认只用 Ubuntu 官方仓库 + Mozilla 官方仓库;PPA 需逐条说明理由并留档 | 中 |
| 22 | **家目录重定向后的应用不兼容** | 个别程序不认自定义 XDG 目录,或在 NTFS 上无法保存权限位 | 只重定向文档类目录;需权限语义的留在本地;出问题还原 `user-dirs.dirs` 的 `.dbk.bak` 备份 | 中 |
| 23 | **激活方案的平台合规风险** | 仓库或账号层面的合规问题 | 公开仓库只做外链与流程说明,不分发任何激活脚本本体;附风险与责任声明 | 中 |
| 24 | **失去原子回滚 / 回退点缺失** | 系统级损坏只能重装,恢复时间从几分钟变成 30–60 分钟 | 数据隔离(`D:`)+ 原地重装两法 + 配置脚本化重放(R1);保留旧内核(R3) | 高 |
| 25 | **没有包级回退记录** | 需要降级时不知道目标版本,`apt install <包>=<版本>` 无从下手 | 变更前按 `05-9` 记下当前版本;`rollback-pkg.sh --list` 可列可用版本;巡检核对待升级包数 | 中 |
| 26 | **原地重装时误格分区** | 数据分区或另一边系统被清空 | 安装时逐分区核对;明确禁止"删除所有分区";动手前先做基线备份 | 高 |
| 27 | **重装 Kubuntu 时误格 ESP 或 `/boot`** | 破坏 Kubuntu 引导;误格 Windows ESP 时连带破坏 Windows 引导 | 显式检查安装器里两块 ESP 的"格式化"勾选;`/boot` 与 ESP 绝不格式化;动手前先备份 `~` | 高 |
| 28 | **已知文件夹重定向遗漏** | 数据落在 C:,重装即丢 | L1 完成后按验收 D 组逐项核对;重定向清单固化为文档步骤 | 中 |
| 29 | **安装器误把 Windows ESP 设为 `/boot/efi`**(Calamares 没有独立的"引导器位置"选项;Ubuntu 主版的 Flutter 安装器有同类已知缺陷,对 Kubuntu 不适用但需核对) | 当场写坏 Windows 引导 | `04-2` 卡的前置核对(`check-partition-plan.sh` 断言 Windows ESP 未被挂载、尺寸仍是 2048MB)+ 分区页显式确认 `/boot/efi` 指向 ESP-Ubuntu;L2 基线可还原 | 中 |
| 30 | **同盘两块 ESP 的固件支持不确定** | 固件只认第一块 ESP,ubuntu 条目不可见 | 列为 A 组必做实测项;若某机型不支持,记录偏离并评估"共用 ESP 分支"(第 10 节) | 中 |
| 31 | **自签或第三方驱动源易碎** | 驱动拒载、升级后需重签,Secure Boot 下更麻烦 | 默认走 Ubuntu 官方预签名包;自签路径仅作回退分支且必须标注"未在真机验证" | 中 |
| 32 | **第三方驱动包卡住内核升级** | 内核/驱动更新被阻塞,长期停在旧内核 | 不用 DKMS 自建驱动;驱动随 `ubuntu-drivers install` 的官方包更新,更新前先按 `05-9` 备份并记录版本 | 中 |
| 33 | **升级后驱动与内核不配套** | 新内核里 `nvidia` 不加载或桌面异常 | 升级前备份并留档;升级后立刻复检(会话 / Wayland / 驱动签名 / 桌面),不满足就按 `05-9` 降级并 hold,或选旧内核启动 | 中 |
| 34 | **snap 被静默装回**(`do-release-upgrade` 重新引入;`apt install firefox` 的过渡包拉入 `snapd`) | 违反用户"规避 snap"的约束 | S3 的 apt pin(-1)+ S4 的 Mozilla 官方仓库优先级;S5 要求升级后复核;失败则改 Flatpak | 中 |

---

## 10. 未决项与后续变体

| 项 | 状态 | 说明 |
|---|---|---|
| `autounattend.xml` + `diskpart` 模板(部署加速器) | **占位,先不实现** | 面向多台同规格设备的批量部署;代价是应答文件对 Windows 版本敏感、调试成本高 |
| 独立共享分区变体 | 待评估 | 从 D: 再切出一块专用共享分区,把"共享"与"Windows 私有数据"隔离,降低写入风险 |
| 共用 ESP 分支(单 ESP) | 待评估 | 若机型固件只认第一个 ESP:退回 Windows 与 Kubuntu 共用一个 ESP(**仍保留独立 `/boot`**),并重新评估 I3 的保障方式;需实测 |
| 外置 USB SSD / 移动硬盘安装分支 | 待评估 | 无第二盘位又不愿动内置盘时的可行路径(评论区有同类需求),需补 USB 供电、性能与引导条目保持的注意点 |
| 云端/网络同步补充 | 待评估 | 若需跨机器访问同一批办公文件,可叠加云同步或 NAS;同机双系统之间的 SMB 无意义(两系统不能同时开机) |
| LUKS 加密变体 | 待评估 | 需改为手动分区,首启需口令;与 Secure Boot 及预签名驱动的交互**须先核实** |
| 非 KDE 桌面变体(如 Ubuntu 主版 GNOME) | 待评估 | 换 flavor 或换发行版等于换安装器与引导口径(Flutter 安装器的 ESP 行为不同);须先核实 |
| Windows 侧"回 Linux 一键切换"工具 | 待评估 | 现有开源实现多为第三方托盘程序;v1 先用 BootNext 与厂商菜单键 |
| 双盘设备分支 | 待编写 | Linux 独占一块盘 + 独立 ESP(**两块 ESP 都必须在第一块盘**) |
| 快照回滚变体(snapper / timeshift / btrfs / ZFS root) | **已作废** | 用户明确否决:回退降级为**包级回退 + 原地重装**(3.7 / 3.14 / 04 号设计 D4) |

---

## 11. 参考项目与调研结论(截至 2026-09-22)

调研了同类开源项目,按"解决什么问题 / 架构 / 活跃度 / 可复用 / 需避开"筛选:

| 项目 | 规模 | 参考价值 |
|---|---|---|
| `gillesduif/iGloo` | 50 星,alpha,.NET 9 WPF | **参考架构**:Windows 侧应用 + 每发行版一个安装器配置插件 + 首启 systemd oneshot + 通过暂存卷上的 manifest 交换状态;其 safety-model(BootNext 一次性启动、只用原生分区缩容、无人值守安装仅落在未分配空间、ISO 校验、保留 nouveau 兜底、全流程日志)**被本方案直接继承**;它支持"干净卸载 Linux 并还原 Windows 引导"这一等公民流程,与本方案 L5 同源。**需避开**:绑定单一 Windows GUI、NVIDIA 场景要求关闭 Secure Boot、浏览器凭据跨系统迁移的高风险链路 |
| Kubuntu / Ubuntu 官方文档(release notes、release-cycle、RecognizedFlavors、`ubuntu-drivers` 与 Secure Boot 文档) | 官方 | **本次修订起成为基础系统与驱动路径的来源**:Plasma 6.6 / Wayland-only / Calamares / 3 年支持窗口、官方预签名 `nvidia` 包**不需要自签与 MOK 注册**、`SHA256SUMS` 与签名文件的校验口径 |
| Calamares 官方文档 + KDE Discuss 的 Kubuntu 26.04 安装问答 | 1.5k 星(calamares) | **坑位证据来源**:Calamares 手动分区页**没有独立的"引导器位置"选项**,引导装在 `/boot/efi` 所指的那块 ESP —— 这正是决策 3.4 与 `04-2` 卡前置核对的由来 |
| Mozilla 官方安装文档(APT 仓库与 pin 步骤)+ r/Kubuntu 的实测帖 | 官方 / 社区 | **snap 规避的证据来源**:`apt install firefox` 是过渡包(会装 snap)、`do-release-upgrade` 重新引入 snap、minimal 安装不含 snap;据此定下 3.22 的 S1–S6 |
| `KeyofBlueS/bt-keys-sync` | 66 星 | **直接复用**:以 `chntpw` 读写 Windows 注册表中的蓝牙配对密钥,按上游建议以 Windows 侧为权威来源,避免反向写注册表 |
| `pgaskin/bootnext`、`mendhak/grub-reboot-picker` | 92 / 70 星 | **复用机制**:EFI `BootNext` 一次性启动语义,是 I2 的实现基础。前者自 2020 年未更新,故只取其机制,不依赖其产物 |
| `bayasdev/envycontrol` | 1.9k 星 | 混合显卡模式切换参考,归入 L4 的备选工具 |
| `fwupd/fwupd` + LVFS | 4.2k 星 | Linux 侧固件更新路径;注意部分机型 LVFS 版本可能落后于 Windows 侧固件 |
| `massgravel/Microsoft-Activation-Scripts` | 190k 星,最近发布 v3.12(2026-07-04) | Windows **KMS 激活**的上游来源(Online KMS:180 天周期 + 每 7 天自动续期任务);其文档明确记录了 KMS38 的失效边界与移除决定,是本方案排除 KMS38 的依据;本仓库只做外链与流程说明 |
| `rezzcode/grub-rescue`、`blindma1den/windows-11-uefi-boot-repair` | 3 / 56 星 | L5 救援手册的内容来源(GRUB 恢复、`bcdboot` 重建,注意其命令写法偏 legacy) |
| `yannubuntu/boot-repair` | GitHub 仓库已不存在 | 只能作为离线救援 ISO 列入工具箱,**不可作为方案依赖** |
| `linuxmint/timeshift`、`Antynea/grub-btrfs` | 4.3k / 1.2k 星 | 快照回滚方案;**已作废**(3.7 / 3.14 明确不用:回滚降级为包级回退 + 原地重装) |

---

### 11.1 实战评论区证据(BV1Cc41127B9)

来源:B 站《Windows11 安装 Ubuntu 避坑指南》(BV1Cc41127B9,2023-12 发布,72 万播放、4619 条评论)。抓取范围说明:**未登录状态下 B 站只开放顶层 3 条热评与其全部子回复**,共获取 52 条(已尽力展开子回复),并非全量样本;下文为其归纳,均为改写而非原文引用。本节为既有证据集的逐条保留(证据本身与发行版无关的部分继续有效)。

归纳出的坑与对应设计改动:

| # | 评论区里反复出现的问题 | 本方案对应改动 |
|---|---|---|
| 1 | 笔记本混合显卡模式下装完进不了系统/黑屏,改成 BIOS 独显直连后解决(542 赞热评) | 决策 3.17:显卡模式排障分支;默认仍走混合 + PRIME |
| 2 | `nomodeset` 被当成"万能修复",但同时失去 KMS,与 Wayland 直接冲突 | L3 应急步骤 + 明确"临时手段,装好驱动必须移除" |
| 3 | 自动更新内核后显卡驱动不适配,进不了桌面(子回复高赞) | 决策 3.18:更新策略收紧为只装安全更新、不自动重启;变更前先备份并记录版本 |
| 4 | 长时间使用后莫名崩溃、反复强制重启,最后两系统都出问题(274 赞) | 故障矩阵新增硬件优先 triage + REISUB 安全重启 + 事后文件系统检查 |
| 5 | 装完独显驱动后每次开机在引导菜单阶段黑屏(键盘仍可用) | 决策 3.19:换终端模式 + BootNext 切换 |
| 6 | "删掉 Ubuntu 会不会影响 Windows 引导?"(多人问) | 四条不变量 + L5 退役流程;FAQ 里显式回答 |
| 7 | Ubuntu 24.04 手动分区界面没有"引导器位置"选项,用户卡住不敢继续 | L3 步骤与故障矩阵里明确说明:本方案**不依赖**安装器写 Windows 的 ESP,改用"手工预建 Ubuntu 分区 + 只指定挂载点" |
| 8 | 部分厂商双硬盘机型只能从第一块盘启动(惠普) | 偏离项与厂商差异表增加硬约束(**两块 ESP 都必须在第一块盘**) |
| 9 | 选错安装目标盘导致重装 | 参数表用 `DISK_MODEL`/`DISK_SIZE`,安装前核对 |
| 10 | 新网卡/键盘不识别,担心要换发行版 | 驱动优先级:先换内核或改走官方预签名驱动的新版本,不降发行版 |
| 11 | 国内下载镜像的需求 | L0 手册补充国内镜像下载 + Kubuntu ISO 按官方 `SHA256SUMS` 比对(Windows ISO 官方未发布镜像哈希,只做"官方下载域 + 官方安装器校验") |

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
| 2026-09-19 | **修订七:改用 Fedora 44 Silverblue 原子版**(已被修订八取代,保留为历史)。基础系统由 Ubuntu 26.04 LTS 改为 Fedora 44 Silverblue;回滚由快照级改为部署级(`rpm-ostree rollback`);NVIDIA 路径改为 `rpm-ostree rebase` 到第三方预签名 NVIDIA 变体 + 一次性 MOK 注册;分区改为"Windows 独占 2GiB ESP + Linux 独立 1GiB ESP + 独立 `/boot` 1GiB + root ≈113GiB btrfs";新增 1.4 轨道结构、决策 3.21 生命周期与升级、3.22 原子版语义、3.23 三轨道。该版的设计依据与取舍已归档到 `02-fedora-atomic-variant-design.md` |
| 2026-09-21 | 消除最后一处不和谐:I1 举例路径由 `\EFI\ubuntu\grubx64.efi` 改为原子版时代的 `\EFI\fedora\grubx64.efi`(仅举例路径,不变量语义未变),并同步 `docs/00-overview.md` 的同一处与说明句。**该行已废弃,保留为历史记录**(修订八已把举例路径改回 `\EFI\ubuntu\`) |
| 2026-09-22 | **修订八:基础系统由 Fedora 44 Silverblue 改为 Kubuntu 26.04 LTS**(见 `04-kubuntu-variant-design.md`)。按"逐节核对"重写全文:第 1 节补回滚降级目标与非目标(新增 **ZFS root 快照**为被否项);第 3 节决策表改 Kubuntu 口径(基础系统 Kubuntu 26.04 LTS / Plasma 6.6 Wayland-only / Calamares / LTS 3 年;回滚改**包级回退 + 原地重装**;Secure Boot 走 Ubuntu 官方预签名包、**不需要自签与 MOK**;根文件系统 **ext4**;新增 **snap 规避 S1–S6** 决策 3.22);第 4 节 L4 卡清单改 **14 张**(`05-1` … `05-14`)、4.7 的 R1–R9 改为新策略(变更前备份 / 包级回退 / 旧内核保留 / 救援 U 盘 / journald / OOM-zram / SSH / 保守更新 / SMART)、4.8 原地重装两法改 Ubuntu 口径(`grub-install` + `update-grub`、`grub-efi-amd64-signed`/`shim-signed`);第 5 节改 `ESP-Ubuntu 1GiB` 与 `UBUNTU_ESP_SIZE`、删除第三方镜像参数(**分区数值一律未变**);第 7 节回滚粒度表改按新策略重写(单包 / 配置 / 系统级 / 引导级);第 8 节 B 组新增 **snap 零残留**与**驱动来源为 Ubuntu 官方包**、去掉 `rpm-ostree status` 项,F 组把"部署回滚演练"换成 **包级回退演练 + 原地重装演练**;第 9 节删掉原子版专属风险(第三方镜像/MOK/分层安装/部署回滚),新增 Kubuntu 时代风险(第三方 PPA、失去原子回滚、安装器误选 ESP、snap 被静默装回),**总条数仍为 34**;第 11 节把第三方镜像相关条目替换为 Kubuntu/Ubuntu 侧证据(官方发布说明、Calamares 文档、Mozilla 官方安装文档与社区实测) |
