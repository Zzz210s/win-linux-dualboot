# 设计方案:Windows 11 专业版 + Ubuntu 26.04 LTS 双系统

日期:2026-09-17
状态:已定稿(待实施计划)
适用:单块 NVMe、UEFI、混合显卡、允许整盘格式化的设备类

---

## 0. 文档定位与阅读顺序

| 文档 | 作用 |
|---|---|
| 本文件 `docs/design/00-design.md` | **为什么**这样设计:目标、不变量、决策记录、风险依据 |
| `docs/00-overview.md` ~ `docs/09-risks.md` | **怎么做**:按执行顺序编号的分步手册 |
| `README.md` / `README.zh-CN.md` | 面向第一次接触者的入口 |

阅读顺序:先本文件第 1、2 节(目标与不变量),再进入手册的 `00-overview.md`。

---

## 1. 目标、适用设备类与非目标

### 1.1 目标

在一台**全新的同规格设备**上建立双系统,同时满足三件事:

1. **能装成**:Windows 11 专业版 + Ubuntu 26.04 LTS,Linux 侧默认 Wayland;
2. **能安全撤除**:删除 Linux 后仍能自动进入 Windows,不出现 `grub>` / `grub rescue>`;
3. **能重复**:同一套手册可用于多台同规格设备,不绑定任何一台具体机器的序列号、机器名或历史状态。

### 1.2 适用设备类

**必须同时满足**

- 单块 NVMe SSD,**标称 1TB 级(实际可用约 953GiB,即"近似但小于 1TB",不是 1TiB)**、UEFI + GPT 引导;
- 混合显卡(集成显卡 + 独立显卡);
- 允许整盘格式化(Windows 与 Linux 都是全新安装);
- 目标系统组合:Windows 11 专业版(Ubuntu 26.04 LTS 作为 Linux 侧)。

**偏离项的处置**

| 偏离 | 处置 |
|---|---|
| 两块及以上磁盘 | 走"双盘分支":Linux 独占一块盘 + 独立 ESP,不变量不变 |
| 磁盘容量明显偏离 1TB 级(如 512GiB / 2TiB) | 按比例调整 C: 与 Linux 侧容量,分区布局与四条不变量不变 |
| 已有 ESP 小于 1GiB 且不愿重装 | **不适用**:本方案依赖重装时可直接定尺寸的 ESP(见 3.4) |
| BitLocker 已启用 | 先执行挂起与恢复密钥备份,再进入 L1;无法挂起则**不适用** |
| VMD / RAID 模式已锁定且无法改为 AHCI/NVMe | **不适用**(Linux 侧看不到磁盘) |
| 仅独显(无集显) | 走"NVIDIA 单显卡分支":不配置 PRIME offload,显示输出直接由独显承担 |
| 桌面非 GNOME 50(如 Kubuntu) | 走"桌面替换分支";注意 Kubuntu LTS 支持期为 3 年而非 5 年 |
| 需要磁盘加密 | **不适用**于 v1;见第 10 节 LUKS 变体 |

### 1.3 非目标(v1 明确不做)

用户数据与浏览器凭据迁移 / 磁盘加密与 TPM-FDE / 休眠 / btrfs 快照回滚 / 自定义 Secure Boot 密钥 / 图形化安装器 / 多发行版模板 / Windows 侧写入 NTFS 分区。

砍掉这些不是省事,而是它们的失败模式(凭据泄露、TPM 与引导链测量冲突、休眠与 NVIDIA+Wayland 冲突、自签密钥触发 BitLocker 恢复)会把方案从"可复现"拖成"每次都得现场救火"。

---

## 2. 四条不变量

整个方案的骨架。手册中任何步骤不得违反;违反即视为设计缺陷,而非操作失误。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| **I1** | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 分区后,固件仍指向失效的 `\EFI\ubuntu\grubx64.efi`,重启停在 `grub rescue>` |
| **I2** | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不用 `efibootmgr -o` 调整顺序 | 留下一个"没人记得撤销"的永久启动顺序 |
| **I3** | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的 `path` | Windows 引导路径被第三方接管,系统更新后翻车 |
| **I4** | 改分区表或固件设置之前,先完成基线备份(BitLocker 挂起 + ESP 镜像 + 固件启动项快照) | 除重装外无路可退 |

**为什么是这四条**:网络上"卡 grub 命令行"的根因不是 GRUB 坏了,而是固件 NVRAM 里的启动条目仍指向已被删除的引导文件,且它排在启动顺序前面。只要 I1 与 I2 成立,即使 Linux 侧被彻底清除,固件也会在失效条目后继续回落到 Windows。这比"记得先修引导再删分区"可靠——后者依赖人的记忆。

---

## 3. 关键决策记录

| # | 决策 | 选择 | 理由 | 被否方案与原因 |
|---|---|---|---|---|
| 3.1 | 系统组合 | Windows 11 专业版 + **Ubuntu 26.04 LTS** | 标准支持到 2031-04;GNOME 50 且**仅 Wayland 会话**;官方仓库提供**预签名** NVIDIA 模块包(Secure Boot 可保持开启);中文资料最丰富 | Fedora KDE(支持期 13 个月;systemd-boot 需自签);Debian 13(内核与驱动偏旧);Bazzite(原子化但 SB 需自签或关闭);CachyOS(滚动更新与"稳定"冲突) |
| 3.2 | 桌面环境 | **GNOME 50**(Ubuntu 旗舰) | Wayland 会话最成熟;支持期 5 年 | Kubuntu 26.04(Plasma 6.6,LTS 支持仅 3 年) |
| 3.3 | 引导栈 | **Ubuntu 官方 GRUB + shim** | Secure Boot 原生可用;官方签名链,无需自签;无人值守与文档生态最全 | **systemd-boot + UKI**:原设计用它绕开 200MB 小 ESP,但整盘重装后 ESP 可定为 2GiB,该理由消失;且在 Secure Boot 下不在微软签名链内,需要自签密钥,属新增风险。**rEFInd**:需改 `{bootmgr}` 路径(违反 I3)或额外引入一层 |
| 3.4 | ESP 布局 | **单个 2GiB ESP,Windows 与 Ubuntu 共用** | 整盘重装可在安装前用 `diskpart` 一次定尺寸;共用是各安装器的默认路径,文档最多 | 双 ESP(非主流;Windows 的 `bcdboot` 与部分工具只认第一个 ESP) |
| 3.5 | 分区策略 | **整盘重排,一次分好** | 消除"缩容"这一整类事故(不可移动文件挡路、BitLocker 触发恢复、缩容上限不足) | 在已有系统上缩容(仅作为附录分支保留) |
| 3.6 | Linux 容量 | 合计 **160GiB**:root **140GiB** + **快照分区 20GiB** | 定位是"轻量远程 AI 开发 + 办公":本地只有桌面、编辑器、终端与工具链,远程承担算力与数据;独立的 20GiB 快照分区为"防崩溃回滚"提供空间(见 4.7) | 535GiB(按本地重型开发估算,无依据);120GiB(过紧,升级与紧急空间不足) |
| 3.7 | 根文件系统 | **ext4** | 最稳、Ubuntu 默认、负载无快照刚需 | btrfs(Timeshift 的 rsync 快照要吃掉数十 GiB,对 140GiB 的 root 不成比例) |
| 3.8 | 交换空间 | **无 swap 分区**:zram(~8GiB)+ swapfile 4GiB | 可随时调整、不动分区表、兼容任意文件系统 | swap 分区(尺寸一旦定死);休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下风险高) |
| 3.9 | 磁盘加密 | **不做** | TPM-FDE 需整盘且与双系统引导链测量冲突,官方仍标实验性质 | LUKS 口令(留给第 10 节变体) |
| 3.10 | Windows 激活 | **成熟 KMS 激活路线**:主路线 = 上游项目的 Online KMS(180 天周期 + 每 7 天自动续期任务);备选 = 自建 KMS 模拟器(vlmcsd / py-kms)+ 微软官方公开的 KMS 客户端键(GVLK) | 按需求定调(采用成熟 KMS,而非购买密钥或 HWID);KMS 走的是微软官方激活协议,可重复、可验证、可续期 | **KMS38**:微软在 build 26100.7019 起彻底废弃该机制,且已被上游项目移除,对 Windows 11 24H2+ 无效。**HWID / TSforge**:虽为上游推荐,但按需求不使用(仅作为文档中的回退说明) |
| 3.11 | 文档粒度 | **步骤级**(做什么 + 关键命令 + 验证方式) | 按需求定调;命令级会引入版本敏感的冗余细节 | 命令级(逐条可复制但难维护);说明级(信息不足) |
| 3.12 | 多设备适配 | **参数化 + 厂商差异表**,`baseline/` 每台设备一份且不入库 | 面向"多台同规格设备"重复部署;同时避免公开仓库泄露具体机器信息 | 绑定单台机器(不可复用,且泄露序列号) |
| 3.13 | 数据迁移 | **不做** | 高价值但高风险(iGloo 的整套迁移链路包含凭据解密/再加密) | iGloo 式迁移(见第 11 节) |
| 3.14 | Ubuntu 健壮性 | 九项措施:变更前快照 + 一键回滚、独立快照分区、多内核保留与 GRUB `saved` 一次性启动、永久救援介质、崩溃可观测(journald 持久化)、OOM 防护(zram + systemd-oomd)、常开 SSH 救援通道、保守更新策略(仅安全更新、不自动重启)、磁盘健康监控(SMART) | 目标是"不会因为一次升级或一块盘的问题而失去可用系统";每项都对应一个可回滚点 | 仅依赖"重装"作为恢复手段(等于放弃回滚);休眠(与 NVIDIA + Wayland 冲突) |
| 3.15 | **Windows 系统盘隔离** | C: 只承载系统与程序(**200GiB**);数据、游戏库、下载与容器镜像独立到 **D: 数据分区(≈590GiB)**;已知文件夹(桌面/文档/下载/图片/视频/音乐)统一重定向到 D: | 崩溃时**只需格式化系统分区**即可原地重装,数据与另一边系统不受影响(见 4.8);与 Linux 侧"root / 快照分离"形成对称的隔离结构;C: 的容量需求变得可预测 | 单一大 C:(重装等于清空全部数据,与"原地重装"目标直接冲突) |

### 3.16 已验证与待验证的事实

| 事实 | 状态 |
|---|---|
| Ubuntu 26.04 LTS 于 2026-04 发布,标准支持至 2031-04;GNOME 50,Wayland-only;内核 7.0;systemd 259;dracut 为默认 initramfs(自 25.10 起) | 已确认 |
| Kubuntu 26.04 LTS = Plasma 6.6,同样 Wayland-only,LTS 支持 3 年 | 已确认 |
| Ubuntu 默认引导仍为 GRUB;systemd-boot 非安装器选项,需手动迁移 | 已确认(无 26.04 安装器选项的权威文档) |
| TPM-backed FDE 在 26.04 有改进但仍带实验性质、需整盘、与 Absolute 固件不兼容 | 已确认(实验标签来自 25.10 文档) |
| Secure Boot 下 NVIDIA 模块可能因签名/MOK 未注册而被拒;`nvidia-open` 在 26.04 仓库曾报缺包 | 故障类型已确认;个别报告属单帖证据,需实测复核 |
| Ubuntu 官方仓库提供预签名 NVIDIA 模块包(`linux-modules-nvidia-*-generic`) | 已确认,方案依赖此路径 |
| KMS38 自 Windows build 26100.7019 起失效,并已被上游项目移除(其基于 `gatherosstate.exe` 的宽限期迁移机制已被微软废弃) | 已确认(上游文档明确标注) |
| Online KMS 激活周期为 180 天,需每 7 天联系 KMS 主机以自动续期;上游脚本默认创建续期计划任务并在注册表留下 KMS 主机地址 | 已确认(上游文档) |
| 自建 KMS 模拟器 `vlmcsd`(Wind4,8.8k 星)/ `py-kms`(2.2k 星)可实现离线自主 KMS | 已确认存在与活跃度;需常态在线主机 |

---

## 4. 分层结构

每个阶段 = 目的 + 输入 + 动作 + **产物** + 完成判据。产物缺失即视为该阶段未完成。

阶段到手册文档的映射(实施计划按此拆分):

| 阶段 | 手册文档 |
|---|---|
| 入口 | `docs/00-overview.md`(目标、四条不变量、设备参数表) |
| L0 | `docs/01-firmware.md` |
| L1 | `docs/02-windows.md`(含系统盘隔离、激活与重装前提) |
| L2 | `docs/03-preflight.md` |
| L3 | `docs/04-ubuntu.md` |
| L4 | `docs/05-first-boot.md`(含健壮性配置) |
| L5 | `docs/06-decommission.md` + `docs/07-rescue.md`(引导救援与**原地重装两法**) |
| 验收 | `docs/08-verification.md` |
| 风险 | `docs/09-risks.md` |

| 阶段 | 名称 | 目的 | 产物 | 完成判据 |
|---|---|---|---|---|
| **L0** | 装机前准备 | 把固件与介质调成目标状态 | `baseline/00-firmware.md` | 固件设定值与介质校验值记录齐全 |
| **L1** | Windows 全新安装 | 整盘分区一次定稿 + 系统 + 激活 | `baseline/01-*`(分区表、ESP 镜像、固件启动项、激活状态) | 分区表与目标布局一致;激活完成;Fast Startup 与休眠已关 |
| **L2** | 预检与基线 | 只读体检 + 建立可回滚基线 | `baseline/02-preflight-report.md` | 报告结论为"允许进入 L3"(无红项) |
| **L3** | Ubuntu 安装 | 装 Linux 且不侵犯 Windows 引导 | `baseline/03-efi-layout.txt` | Ubuntu 可启动;`\EFI\Microsoft\` 与基线一致;BootOrder 首项仍为 Windows |
| **L4** | 首启收敛 | 驱动、Wayland、挂载、时间、蓝牙 | `baseline/04-first-boot.md` | 验收 B 组全绿 |
| **L5** | 退役与救援 | 安全撤除与故障恢复 | `checklists/rollback.md` | L5 流程可执行(参考设备需真跑一次) |

### 4.1 L0 装机前准备

- 固件:SATA 操作模式设为 **AHCI / NVMe**(关闭 VMD 或 RAID On)、**Secure Boot 保持开启**、Fast Boot 关闭;
- 介质:Windows 11 官方安装 U 盘;Ubuntu 26.04 LTS 安装 U 盘(或 Ventoy 多 ISO);
- **关键点**:VMD 必须在安装 Windows **之前**关闭。若 Windows 已按 RAID On 装好再关闭,系统将无法启动,需先预置存储驱动再进安全模式完成切换(该路径作为附录分支,不属于本方案主路径)。

### 4.2 L1 Windows 全新安装

- 整盘重排:ESP 2GiB → MSR 16MiB → **Windows 系统 C: 200GiB** → **Windows 数据 D: ≈590GiB** → **为 Ubuntu 预留 160GiB 未分配空间(root 140 + 快照 20)** → WinRE;
- **系统盘隔离**:C: 只放系统与程序;桌面/文档/下载/图片/视频/音乐等**已知文件夹、游戏库与容器镜像全部重定向到 D:**。所以"崩溃后原地重装"只需格式化 C:,数据与 Linux 侧均不受影响(见 4.8);
- ESP 必须**预建**(Windows 安装界面无法把自动创建的 100MB ESP 改成 2GiB),因此使用 `diskpart` 预建分区表;
- 安装完成后立即:关闭 Fast Startup 与休眠文件、完成脚本激活、记录激活状态;
- 风险提示:Windows 安装程序对 WinRE 分区的放置有版本敏感性,若它把恢复分区放进预留空间,记录偏差并据实调整(ESP 尺寸不允许被削减)。

### 4.3 L2 预检与基线(硬闸门)

- 只读体检:BootOrder 与固件启动项、ESP 目录树与剩余空间、BitLocker 状态、存储控制器模式、Fast Startup/休眠、磁盘布局;
- 基线备份:ESP 整块 dd 镜像 + `bcdedit /enum firmware` 快照 + 分区表输出;
- **闸门规则**:存在红项 → 禁止进入 L3;存在黄项 → 记录后带风险继续。

### 4.4 L3 Ubuntu 安装

- 手工分区:2GiB ESP 挂载到 `/boot/efi`(复用,不新建);160GiB 空间划分为 **root 140GiB ext4(挂 `/`)** + **快照分区 20GiB ext4(挂 `/snapshots`)**;内核位于 root 内的 `/boot`,不额外分区;
- 不创建 swap 分区;首启后再配置 zram 与 swapfile;
- 引导写入 `\EFI\ubuntu\`(安装器默认),**期间不改动 `BootOrder`**;
- Secure Boot 全程保持开启。

### 4.5 L4 首启收敛

| 项目 | 做法 | 回滚点 |
|---|---|---|
| 显卡驱动 | 走 Ubuntu 仓库的**预签名** NVIDIA 模块包(不经 DKMS 编译);保留 nouveau 作为兜底 | 卸载专有驱动即回 nouveau |
| 显示策略 | 集成显卡主显示 + 独显 PRIME offload(独显单显卡设备跳过) | 恢复默认 PRIME 模式 |
| Windows 分区挂载 | `ntfs3` **只读**挂载,`fstab` 带 `nofail` | 移除 fstab 行 |
| 时间 | `RTC in local TZ: no`(Linux 用 UTC),Windows 侧可配合 `RealTimeIsUniversal=1` | 可逆 |
| 蓝牙 | 同步两系统配对密钥(上游 `bt-keys-sync`,依赖 `chntpw`);按上游建议"以 Windows 侧密钥为准",不做反向写入 | 注册表有备份,可还原 |
| 固件 | `fwupd` 识别设备即可;固件更新仍优先在 Windows 侧完成 | 无 |
| 回 Windows | 提供一键回 Windows 的入口(BootNext 或固件菜单) | 无 |

### 4.6 L5 退役与救援

退役流程顺序不可更换:

```
1. 在 Ubuntu 中把 BootOrder 首项改回 Windows Boot Manager
2. 备份当前 NVRAM 与 ESP 现状(最后一道保险)
3. 重启进 Windows,用「磁盘管理」删除 Linux 分区(确认引导已归位后再删)
4. 清理 NVRAM 中残留的 ubuntu 条目
5. 可选:把 C: 扩展到腾出的空间
```

**明确禁止**:先格式化 Linux 分区再修引导。

### 4.7 L4 附加:**Ubuntu 健壮性设计(防崩溃)**

目标是"不会因为一次升级、一个驱动或一块盘的问题而失去可用系统"。九项措施,每项都对应一个可回滚点:

| # | 措施 | 做法 | 回滚点 |
|---|---|---|---|
| R1 | **变更前快照** | 在执行内核/驱动/大版本升级之前创建系统快照;平时不自动创建,避免空间与 IO 开销 | 从快照还原(整机回到变更前) |
| R2 | **独立快照分区** | 快照存放于 `/snapshots`(20GiB 独立分区),不与 root 争空间、不触发"同分区目标"告警 | 删除快照即回收空间 |
| R3 | **多内核保留 + 一次性启动** | 保留旧内核(GRUB "Advanced options" 可选);`GRUB_DEFAULT=saved` 支持一次性切换,与固件层 `BootNext` 互补(不违反 I2) | 选旧内核启动 |
| R4 | **永久救援介质** | 常备 Ubuntu 安装 U 盘,并从第一台参考设备起记录"已验证可用"标记 | 从 U 盘进入 live 环境修复 |
| R5 | **崩溃可观测** | 启用 journald **持久化**(`/var/log/journal`),保留系统崩溃/启动失败日志;自建日志目录 `/var/log/dbk/` | 无(仅提升可诊断性) |
| R6 | **OOM 与内存压力防护** | zram(~8GiB)+ swapfile 4GiB;确认 `systemd-oomd` 处于启用状态 | 调整 zram/swapfile 大小 |
| R7 | **常开 SSH 救援通道** | 启用 `openssh-server`:桌面挂死时仍可从另一台机器登录排障(对"远程开发"定位尤其关键) | 关闭服务 |
| R8 | **保守更新策略** | `unattended-upgrades` 只自动安装**安全更新**,**不自动重启**;大版本升级前必须先做 R1 快照 | 从快照还原 |
| R9 | **磁盘健康监控** | 安装 `smartmontools`(`smartd`)并确认日志告警生效;保留 ext4 周期性 `fsck` 默认策略 | 无(提前发现硬件故障) |

**明确不做的**,以及原因:休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车)、btrfs 快照(与已选 ext4 冲突,见第 10 节变体)、自定义 Secure Boot 密钥(改动签名链会新增风险)。

### 4.8 L5 附加:崩溃后**在原系统盘重装**的两法

两法共用前提:`baseline/` 产物齐全可用(分区表、ESP 镜像、固件启动项快照),救援 U 盘在位。**先判断崩溃在哪一层**——若只是引导层损坏,不要重装,先走 4.6 的引导复原。

#### 办法一:Windows 崩溃 → 只重装 Windows(仅格式化 C:)

| 步骤 | 要点 |
|---|---|
| 1 | 用官方 ISO 引导,进入"自定义安装" |
| 2 | **只格式化 C:**;数据分区 D:、Linux 各分区与 ESP 一律不动。逐分区核对,**禁止"删除所有分区"** |
| 3 | 安装程序会在 ESP 上重建 `\EFI\Microsoft\` 与 BCD,并可能覆盖 `\EFI\BOOT\bootx64.efi`(属正常;`\EFI\ubuntu\` 不受影响) |
| 4 | 首次进桌面:关 Fast Startup 与休眠、重新完成 KMS 激活、恢复已知文件夹到 D: 的重定向 |
| 5 | **复查四条不变量**:BootOrder 首项、`\EFI\Microsoft\` 内容、`{bootmgr}` path、Ubuntu 条目仍在;用厂商菜单键验证 Ubuntu 仍可启动 |
| 风险 | 误格 D: 或 Linux 分区 → 灾难性;Windows 可能新建恢复分区并占用预留空间(记录偏差) |

#### 办法二:Ubuntu 崩溃 → 只重装 Ubuntu(仅格式化 root 分区)

| 步骤 | 要点 |
|---|---|
| 1 | 用 Ubuntu 安装 U 盘引导,选"手动分区" |
| 2 | **只格式化 root 分区并挂 `/`**;ESP 复用挂 `/boot/efi`,**绝不勾选"格式化 ESP"**;`/snapshots` 挂上但不格式化(保留历史快照);Windows 各分区不动 |
| 3 | 安装写入 `\EFI\ubuntu\`(与 Windows 引导并存),期间不改 `BootOrder` |
| 4 | 首启:按 4.5 与 4.7 的清单重放驱动、挂载、时间、蓝牙与健壮性配置 |
| 5 | 复查四条不变量 |
| 风险 | **误格 ESP 会同时破坏 Windows 引导**——这是全流程最危险的一步;ESP 镜像可复原,但必须先备份再动手 |

**第三选择(不是重装)**:引导层损坏而系统分区完好 → ESP 镜像还原 + `bcdboot` 重建 + NVRAM 条目清理。

---

## 5. 分区表与设备参数

### 5.1 目标分区表(标称 1TB 的 NVMe,实际可用约 953GiB;下表为 GUI 显示值)

| 序号 | 分区 | 大小 | 类型 | 挂载 / 用途 |
|---|---|---|---|---|
| 1 | ESP | **2GiB** | EFI System(FAT32) | Windows 与 Ubuntu 共用;Ubuntu 侧挂 `/boot/efi` |
| 2 | MSR | 16MiB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 C: | **200GiB** | NTFS | 系统与程序;**原地重装时唯一被格式化的分区** |
| 4 | Windows 数据 D: | **≈590GiB** | NTFS | 游戏库、下载、文档、容器镜像;已知文件夹重定向的目标 |
| 5 | Ubuntu root | **140GiB** | ext4 | `/`(内核位于 root 内的 `/boot`,不额外分区) |
| 6 | Snapshot | **20GiB** | ext4 | `/snapshots`,变更前快照的存放位置(健壮性 R1/R2) |
| 7 | WinRE | 1GiB | Recovery | Windows 恢复环境,置于磁盘末尾 |

合计 ≈ 953GiB:2 + 0.016 + 200 + 590 + 140 + 20 + 1。Linux 侧合计 160GiB(= 140 + 20),与决策 3.6 一致。

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
| `ESP_SIZE` | 目标 ESP 大小 | 2GiB |
| `WINDOWS_SYSTEM_SIZE` | 目标 Windows 系统分区大小 | 200GiB |
| `WINDOWS_DATA_SIZE` | 目标 Windows 数据分区大小 | ≈590GiB |
| `ROOT_SIZE` | 目标 root 大小 | 140GiB |
| `SNAPSHOT_SIZE` | 目标快照分区大小 | 20GiB |
| `SECURE_BOOT` | Secure Boot 目标状态 | 开启 |

---

## 6. 阶段产物与交接规则

1. **没有产物的阶段视为未完成**,不得进入下一阶段。
2. **`baseline/` 不入库**(含单机私产:分区表、ESP 镜像、固件启动项、激活状态);仓库内只保留结构与命名规范。每台设备一个子目录。
3. **L2 是唯一硬闸门**;红项禁止推进,黄项记录后继续。
4. **L1 与 L2 必须在同一次会话内连续完成**:中途若 Windows 发生更新,基线即失效。
5. **L3 期间不改动 `BootOrder`**(I2 的落地方式)。
6. **L4 任何驱动变更之前**,先确认"回 Windows 的入口"可用。

---

## 7. 故障处理与回滚矩阵

| 阶段 | 症状 | 立即动作 | 回滚 |
|---|---|---|---|
| L0 | 介质校验值不符 | 重制安装介质 | 无副作用 |
| L1 | 分区表与计划不符 | 此时无数据,重装重分 | 重来 |
| L1 | 激活未成功 | 不阻塞:L1 与 L3 解耦,先推进,后续单独处理 | 后续处理 |
| **L2** | BitLocker 已启用 | 备份 48 位恢复密钥 → 挂起保护 → 复检 | 恢复保护 |
| **L2** | 存储控制器仍为 RAID/VMD | 停在 L2,回 L0 改固件;若 Windows 已装好才改,走附录分支(驱动预置 + 安全模式) | 改回 RAID On |
| L3 | 安装器看不到磁盘 | 回 L0 核查控制器模式 | 无副作用 |
| L3 | 重启直接进 Windows | 用厂商启动菜单键手动选 Ubuntu(一次性);核对固件条目列表 | 无需回滚 |
| L3 | 停在 `grub>` / `grub rescue>` | ① `ls` 找分区 → `set prefix` → `insmod normal` → `normal`;② 直接回 Windows:`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` → `chainloader` → `boot` | 基线回滚(ESP 镜像) |
| L3 | Secure Boot 拒载 | 核查 `mokutil --sb-state`;驱动回退 nouveau,不在 L3 引入自签 | 无副作用 |
| L4 | 装驱动后黑屏 / 闪烁 | 切 TTY → 卸载专有驱动回 nouveau → 再调 PRIME 模式 | nouveau 天然回滚点 |
| L4 | 模块签名被拒 | 改用仓库预签名包,不做 DKMS | 同上 |
| L4 | `fstab` 写坏导致进不去系统 | GRUB 中追加 `systemd.unit=emergency.target` | 模板已含 `nofail` |
| L4 | 时间错乱 / 蓝牙反复重配对 | RTC=UTC(或 Windows `RealTimeIsUniversal=1`);密钥同步脚本 | 均可逆 |
| L4 | 升级后系统不可用(内核/驱动) | 从 GRUB "Advanced options" 选旧内核启动 | 从 `/snapshots` 快照整体还原(R1) |
| L4 | 桌面无法进入 | 用另一台机器 SSH 登录排障(R7);必要时切 TTY 卸驱动 | 重启进旧内核 |
| L4 | KMS 激活到期未续期 | 检查续期任务与 KMS 主机可达性,手动触发一次续期 | 见第 10 节自建 KMS 变体 |
| L5 | **Windows 系统分区损坏** | 走 4.8 办法一:只格式化 C: 重装 | D: 数据与 Linux 侧不受影响 |
| L5 | **Ubuntu root 损坏** | 走 4.8 办法二:只格式化 root 重装 | `/snapshots` 与 Windows 侧不受影响 |
| L5 | 引导层损坏而系统分区完好 | **不要重装**:ESP 镜像还原 + `bcdboot` 重建 + NVRAM 清理 | 基线回滚 |

### 7.1 周期性巡检

每次 Windows 大版本更新或累积更新后,重跑基线核对:**BootOrder 首项**、**ESP 目录树是否被改动**、**BitLocker 状态**。

已知事故类型:2024-08 的 SBAT / Secure Boot DBX 更新曾导致双系统机器无法引导 Linux(微软已确认)。缓解:`mokutil --set-sbat-policy delete` + 常备 Ubuntu 安装 U 盘。

### 7.2 回滚的三种粒度

| 粒度 | 场景 | 手段 |
|---|---|---|
| 单步回滚 | BootNext 未生效、`fstab` 写错、驱动翻车 | 回到该步骤的"回滚方式" |
| 阶段回滚 | 不再需要 Linux | L5 退役流程 |
| 基线回滚 | ESP 或固件启动项被破坏 | ESP 镜像 + 固件启动项快照 |

---

## 8. 验收标准

唯一判据是 `docs/08-verification.md` 全绿;不以"装完了"为准。

**A. 引导安全组**

| 检查项 | 判据 |
|---|---|
| 默认启动项 | `BootOrder` 首位为 Windows Boot Manager;连续重启 3 次均默认进 Windows |
| Windows 引导未被污染 | `\EFI\Microsoft\` 与 L2 基线逐文件一致 |
| 引导路径未被篡改 | `{bootmgr}` 的 `path` 与基线一致 |
| 不变量落地 | Ubuntu 条目位于 `BootOrder` 末尾;全程未使用 `efibootmgr -o` |
| **可撤除性演练** | 备份 ESP 后临时删除 `\EFI\ubuntu\`(保留分区)→ 重启确认**自动进 Windows 且无 `grub rescue`** → 用镜像还原并复测。**参考设备必做,其他设备推荐** |

**B. 系统功能组**:会话类型为 `wayland`(且无 X11 会话可选);GPU 驱动状态正常或有 nouveau 兜底且无签名拒绝日志;Secure Boot 保持开启;Windows 分区只读挂载成功且 `nofail`;`RTC in local TZ: no`;切换系统后蓝牙无需重新配对;`fwupd` 能识别设备。

**C. 双系统切换组**:从 Windows 用 BootNext(或厂商菜单键)一次性进 Linux 且**不改变**下次默认启动项;从 Linux 一键回 Windows;切换 3 次后 A 组首项检查仍成立。

**D. 可撤除性组**:按 L5 五步顺序完整推演(参考设备真做一次);结束后固件条目与实际状态一致。并额外核对:

| 检查项 | 判据 |
|---|---|
| 系统盘隔离生效 | 已知文件夹与游戏库均位于 D:;C: 不含用户数据(逐项核对重定向)| 
| 原地重装两法可用 | 两法各至少完整推演一次(参考设备至少真做一法);重装后 A 组四条不变量复检通过 |
| 非重装逃生路径可用 | 引导层损坏场景已验证:ESP 镜像还原 + `bcdboot` 能恢复引导 |

**E. 记录组**:`baseline/` 产物齐全且未入库(`git status` 干净);记录本次与设备参数表的偏差,回写到 `docs/00-overview.md`。

**F. 健壮性组(防崩溃)**

| 检查项 | 判据 |
|---|---|
| 快照可用 | 能创建快照,且**真做一次回滚演练**:回滚后系统可正常启动(参考设备必做) |
| 快照分区独立 | `/snapshots` 为独立分区且挂载正常,`df` 可见 |
| 多内核可回退 | GRUB 菜单存在 Advanced options 且至少保留一个旧内核;`GRUB_DEFAULT=saved` 生效 |
| 崩溃可观测 | journald 为持久化模式:重启后能读取上一次启动的日志 |
| 更新策略 | `unattended-upgrades` 仅自动安装安全更新且未启用自动重启(核对配置) |
| 远程救援通道 | 从另一台机器可 SSH 登录,且无需桌面会话 |
| OOM 防护 | `systemd-oomd` 处于启用状态;zram 生效 |
| 磁盘健康 | `smartd` 运行中且 `smartctl -H` 报告 PASSED |
| 挂载稳健 | `fstab` 中所有非 root 条目均带 `nofail` |

**通过定义**:任一组存在未勾选项且无在案记录的"已知例外" → 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。

---

## 9. 风险登记

| 风险 | 后果 | 缓解 |
|---|---|---|
| **Intel VMD / RAID On** | Linux 安装器看不到磁盘 | 在装 Windows 之前就设为 AHCI/NVMe(全新设备的最大红利);已装好才改则走驱动预置分支 |
| **BitLocker** | 改分区表/固件设置触发恢复密钥索要 | 备份 48 位恢复密钥 → 挂起保护 → 操作 → 恢复保护 |
| **Windows 更新重写 ESP / SBAT-DBX 事件** | Linux 引导消失或出现签名校验失败 | ESP 镜像备份;救援 U 盘;必要时清理 SBAT 策略 |
| **Fast Startup + 双写 NTFS** | Windows 分区数据损坏 | 装前关闭 Fast Startup 与休眠;Linux 侧只读挂载 NTFS |
| **ESP 过小** | 后续内核/引导文件放不下 | 整盘重装时把 ESP 定为 2GiB(见 3.4) |
| **引导顺序被改** | 删除 Linux 后卡 `grub rescue` | 四条不变量 + L5 退役流程 + L2 基线 |
| **Secure Boot 下 NVIDIA 模块签名** | 驱动不加载,严重时无桌面 | 只用仓库预签名包,不做 DKMS;保留 nouveau 兜底 |
| **Windows 安装程序对恢复分区放置的版本敏感性** | 预留空间被占用,分区表偏离计划 | L2 逐项核对分区表;偏离可接受(仅 ESP 尺寸不可削减) |
| **双系统时间 / 蓝牙状态分裂** | 时钟错乱、设备需反复重新配对 | RTC=UTC;上游 `bt-keys-sync` |
| **KMS 续期依赖可达的 KMS 主机** | 180 天周期内未成功续期会导致激活失效 | 保留续期任务并定期核对;必要时切换自建 KMS 变体(第 10 节);回退说明中保留 HWID/TSforge 选项 |
| **激活方案的平台合规风险** | 仓库或账号层面的合规问题 | 公开仓库只做外链与流程说明,不分发任何激活脚本本体;附风险与责任声明 |
| **快照分区容量耗尽** | 变更前快照创建失败,回滚点缺失 | 限制保留份数(默认 3 份);快照失败即视为"不得执行本次变更" |
| **`GRUB_DEFAULT=saved` 被误改** | 默认启动项漂移 | 纳入周期性巡检(F 组 + 7.1) |
| **原地重装时误格分区** | 数据分区或另一边系统被清空 | 安装时逐分区核对;明确禁止"删除所有分区";动手前先做 L2 基线备份 |
| **重装 Ubuntu 时误格 ESP** | 连带破坏 Windows 引导 | 显式检查安装器里 ESP 的"格式化"勾选;ESP 镜像可复原,但必须先备份 |
| **已知文件夹重定向遗漏** | 数据落在 C:,重装即丢 | L1 完成后按验收 D 组逐项核对;重定向清单固化为文档步骤 |

---

## 10. 未决项与后续变体

| 项 | 状态 | 说明 |
|---|---|---|
| `autounattend.xml` + `diskpart` 模板(部署加速器) | **占位,先不实现** | 面向多台同规格设备的批量部署;代价是应答文件对 Windows 版本敏感、调试成本高 |
| 自建 KMS 服务变体(vlmcsd / py-kms + 官方 GVLK) | 待评估 | 离线自主、完全可重复、不依赖第三方 KMS 主机;需要一台常态在线的机器或本机服务 |
| Kubuntu 变体 | 待评估 | 差异仅在桌面与支持期(3 年) |
| btrfs + 快照回滚变体 | 待评估 | root 容量需同步上调 |
| LUKS 加密变体 | 待评估 | 需改为手动分区,首启需两次口令,恢复手册需增加 LUKS 头备份 |
| Windows 侧"回 Linux 一键切换"工具 | 待评估 | 现有开源实现多为第三方托盘程序;v1 先用 BootNext 与厂商菜单键 |
| 双盘设备分支 | 待编写 | Linux 独占一块盘 + 独立 ESP |

---

## 11. 参考项目与调研结论(截至 2026-09-17)

调研了同类开源项目,按"解决什么问题 / 架构 / 活跃度 / 可复用 / 需避开"筛选:

| 项目 | 规模 | 参考价值 |
|---|---|---|
| `gillesduif/iGloo` | 50 星,alpha,.NET 9 WPF | **参考架构**:Windows 侧应用 + 每发行版一个安装器配置插件 + 首启 systemd oneshot + 通过暂存卷上的 manifest 交换状态;其 safety-model(BootNext 一次性启动、只用原生分区缩容、无人值守安装仅落在未分配空间、ISO 校验、保留 nouveau 兜底、全流程日志)**被本方案直接继承**;它支持"干净卸载 Linux 并还原 Windows 引导"这一等公民流程,与本方案 L5 同源。**需避开**:绑定单一 Windows GUI、NVIDIA 场景要求关闭 Secure Boot、浏览器凭据跨系统迁移的高风险链路 |
| `ublue-os/bazzite` / `bluefin` / `aurora` | 9k / 2.6k / 0.8k 星,每日提交 | 其双系统文档的"先关 BitLocker 与 Fast Boot""双盘场景物理拔掉 Windows 盘""注意安装器会并入已有 ESP"等结论作为风险输入;**其原子化解法与 Secure Boot 自定义密钥要求被本方案避开** |
| `archlinux/archinstall`、`calamares/calamares` | 8.4k / 1.5k 星 | 分区与引导配置的工程化参考;但 Fedora/Debian/Ubuntu 不使用 Calamares,故本方案以各发行版原生无人值守入口为准 |
| `KeyofBlueS/bt-keys-sync` | 66 星 | **直接复用**:以 `chntpw` 读写 Windows 注册表中的蓝牙配对密钥,按上游建议以 Windows 侧为权威来源,避免反向写注册表 |
| `pgaskin/bootnext`、`mendhak/grub-reboot-picker` | 92 / 70 星 | **复用机制**:EFI `BootNext` 一次性启动语义,是 I2 的实现基础。前者自 2020 年未更新,故只取其机制,不依赖其产物 |
| `linuxmint/timeshift`、`Antynea/grub-btrfs` | 4.3k / 1.2k 星 | 快照回滚方案,归入第 10 节 btrfs 变体,不进 v1 |
| `bayasdev/envycontrol` | 1.9k 星 | 混合显卡模式切换参考,归入 L4 的备选工具 |
| `fwupd/fwupd` + LVFS | 4.2k 星 | Linux 侧固件更新路径;注意部分机型 LVFS 版本可能落后于 Windows 侧固件 |
| `massgravel/Microsoft-Activation-Scripts` | 190k 星,最近发布 v3.12(2026-07-04) | Windows **KMS 激活路线**的上游来源(Online KMS:180 天周期 + 每 7 天自动续期任务);其文档明确记录了 KMS38 的失效边界与移除决定,是本方案排除 KMS38 的依据;本仓库只做外链与流程说明 |
| `Wind4/vlmcsd`(8.8k 星)、`SystemRage/py-kms`(2.2k 星) | 均有维护记录 | **自建 KMS 变体**的技术来源:离线自主的 KMS 模拟器,配合微软官方公开的 GVLK 客户端键,实现可重复、不依赖第三方的激活 |
| `rezzcode/grub-rescue`、`blindma1den/windows-11-uefi-boot-repair` | 3 / 56 星 | L5 救援手册的内容来源(GRUB 恢复、`bcdboot` 重建,注意其命令写法偏 legacy) |
| `yannubuntu/boot-repair` | GitHub 仓库已不存在 | 只能作为离线救援 ISO 列入工具箱,**不可作为方案依赖** |

---

## 12. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-17 | 初版:确定 Ubuntu 26.04 LTS + 官方 GRUB + 2GiB 共享 ESP + ext4 160GiB;确立四条不变量、L0–L5 分层、多设备参数化、验收标准 |
| 2026-09-17 | 修订一:设备类容量表述改为"标称 1TB 级、实际可用约 953GiB";激活路线改为成熟 KMS(排除 KMS38);新增 4.7 健壮性设计九项措施、验收 F 组,Linux 空间拆分为 root 140GiB + 快照分区 20GiB |
| 2026-09-17 | 修订二:新增决策 3.15 **Windows 系统盘隔离**(C: 200GiB 系统 / D: ≈590GiB 数据)、4.8 崩溃后**原地重装两法**、阶段到手册文档映射表、验收 D 组三项补充与对应风险条目;自建 KMS 维持"待评估",不提升为主路线 |
