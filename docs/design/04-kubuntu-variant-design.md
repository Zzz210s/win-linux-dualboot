# 设计 04:Kubuntu 变体设计(基础系统由 Fedora 44 Silverblue 改为 Kubuntu 26.04 LTS,并规避 snap)

- 状态:待用户确认后进入实施
- 取代:`docs/design/02-fedora-atomic-variant-design.md`(该文件保留为历史,不再作为实施依据)
- 用户决定(2026-09-22):**A —— 换成 Kubuntu 26.04 LTS**,理由是"日常省心"(apt 生态、官方预签名显卡驱动、3 年 LTS 不用频繁大版本升级),并**规避 snap 包**

---

## 1. 背景与依据

用户原话:"网上说 kubuntu 用起来最省心,我希望用起来省心";在三个选项中选定 **A(换 Kubuntu)** 并附加约束 **规避 snap 包**。

"省心"在本方案里的含义与代价(已在对话中明确):

| 场景 | 换 Kubuntu 后的变化 |
|---|---|
| 日常装软件 / 驱动 | **变好**:`apt` 一条命令;NVIDIA 走官方预签名包(`ubuntu-drivers`),**不再需要 ublue rebase 与 MOK 注册** |
| 长期维护 | **变好**:LTS 3 年只收安全更新;Fedora 的"每 13 个月一次大版本升级"消失 |
| 出事之后 | **变差**:失去部署级原子回滚(`rpm-ostree rollback`),降级为"包级回退 + 原地重装" |

**用户已明确接受第三行的代价**(2026-09-22 确认 A 选项)。本设计不再追求原子回滚,并把该取舍登记为已接受的取舍(见第 7 节)。

### 1.1 事实清单(来源等级标注)

| 事实 | 等级 | 来源 |
|---|---|---|
| Kubuntu 26.04 LTS「Resolute Raccoon」:Plasma 6.6.4、Qt 6.10.2、KDE Frameworks 6.24、KDE Gear 25.12.3、内核 7.0、**Wayland-only** | 高 | Kubuntu 官方发布说明 |
| Kubuntu 是 Ubuntu 官方 flavor,基于 Ubuntu 26.04 LTS 基线;支持窗口由 flavor 自己的支持计划决定(历史上 3 年;Ubuntu 主版 5 年,ESM 只覆盖 main 仓库) | 高 | Ubuntu 官方 release-cycle 与 RecognizedFlavors 文档、Kubuntu 发布说明 |
| Kubuntu 使用 **Calamares** 安装器(不是 Ubuntu 的 Flutter 安装器) | 高 | KDE Discuss 的 Kubuntu 26.04 安装问答、Calamares 官方分区文档 |
| **最小安装(minimal)不含 snap**;完整安装默认带 snapd,Firefox 以 snap 分发 | 中 | r/Kubuntu 对 26.04 beta 的实测帖("minimal 安装里找不到 snap") |
| `apt install firefox` 即便已配 Mozilla 仓库,仍可能把 `snapd` 作为依赖拉进来;需要 apt pin 压制 | 中 | r/Kubuntu 报告与 Mozilla 官方安装文档的 pin 步骤 |
| **`do-release-upgrade` 升级路径会重新引入 snap**(即使当前系统无 snap) | 中 | r/Kubuntu 的 PSA 帖(25.10 -> 26.04 beta 实测) |
| Ubuntu 26.04 的 **Flutter 安装器**(`ubuntu-desktop-bootstrap`)在手动安装时创建 ESP 有已知问题 | 中 | 用户报告帖。**对 Kubuntu 不适用**(Kubuntu 用 Calamares),但实施时仍需核对 |
| Ubuntu 26.04 起 initramfs 由 **dracut** 生成(自 25.10 起为默认) | 高 | Ubuntu 发行说明 |

---

## 2. 六项决定

| 编号 | 决定 | 理由 | 被否方案 |
|---|---|---|---|
| **D1** | 基础系统:**Kubuntu 26.04 LTS**(Plasma 6.6,Wayland-only) | 用户选定;Plasma 在 Wayland 下成熟;桌面可深度定制且不影响系统层 | Fedora 44 Silverblue(现状,日常要学 ostree/容器,13 个月升级周期);Fedora 44 Kinoite(Plasma + 原子回滚,但仍是 Fedora 节奏);Ubuntu 主版 GNOME(用户要 KDE 的省心) |
| **D2** | 生命周期:**LTS 3 年**,期间只收安全更新;大版本升级(`do-release-upgrade`)写成正式卡,前置快照要求改为"前置备份 `baseline/` 与配置文件" | 与"省心"一致:3 年内不动大版本 | 冻结在 26.04 不升级(3 年后无补丁);改用 interim 版本(9 个月寿命) |
| **D3** | Secure Boot:**保持开启**;显卡走 Ubuntu 官方**预签名** `nvidia` 包(`ubuntu-drivers` 安装) | 官方签名链现成,**不需要自签、不需要 MOK 注册**;I3 由结构保证(独立 ESP) | 关 Secure Boot;只留 nouveau;自定义 SB 密钥 |
| **D4** | **回滚策略降级**:不引入任何快照体系;**包级回退**(`apt install <pkg>=<版本>` + `apt-mark hold`)+ **原地重装两法** + 数据隔离(`D:` 共享盘) | 用户已否决 snapper/timeshift/btrfs 快照;接受"坏了就重装,数据不丢" | btrfs + snapper + grub-btrfs;Timeshift;ZFS root 快照(见 2.1) |
| **D5** | 分区表 **8 项不变**,仅把 `ESP-Fedora 1GiB` 改名 **`ESP-Ubuntu 1GiB`**;`/boot` 1GiB ext4 保留(独立于 ESP);root 仍约 113GiB | 与 Windows 隔离的结构性保证不变;`/boot` 独立让重装 root 时可选择保留 | 复用 Windows ESP(违反 I3 的结构性保证);取消 `/boot`(重装 root 时内核随之丢失,反而更麻烦) |
| **D6** | **合并成一次改版**:文档换 Kubuntu 语义 + 卡式结构 + snap 规避,一段内容只写一次 | 与 01 号设计同一原则:分两次写会重复劳动 | 先改内容再改结构 |

### 2.1 被否方案:ZFS root 快照(明确记录)

Ubuntu 提供 ZFS root 安装选项,快照与回滚是 ZFS 原生能力(`zfs snapshot` / `zfs rollback`),**不使用 snapper/timeshift**。技术上它能恢复"一键回滚"且不违反用户对工具的禁令,但:

- ZFS root 在 Ubuntu 属实验性选项,内存开销与调优门槛高;
- 与"省心"目标冲突(用户要的是少折腾,不是多一层存储栈);
- 用户的取舍已明确:回滚降级为"重装"。

**结论:不纳入 v1。** 若日后用户觉得"没有回滚不踏实",这是第一个可以重新评估的选项。

---

## 3. snap 规避策略(用户约束"规避 snap 包")

六条措施,按执行顺序:

| 编号 | 措施 | 判据(可观测) | 依据 |
|---|---|---|---|
| **S1** | 安装时选 **最小安装(minimal)** | 装完 `snap list` 为空或命令不存在 | r/Kubuntu 26.04 beta 实测:minimal 不含 snap |
| **S2** | 首启核对并清除残留:`snap list`、`dpkg -l snapd`;若存在则先 `snap remove` 各应用再 `apt purge snapd` | `snap list` 报"no snaps installed"或命令不存在;`dpkg -l snapd` 无输出 | 常见清理流程 |
| **S3** | **apt pin 压制**:`/etc/apt/preferences.d/no-snap` 里 `Package: snapd` + `Pin: release a=*` + `Pin-Priority: -1` | `apt-cache policy snapd` 显示候选为"无"或优先级为负 | Mozilla 文档的 pin 思路(用于压制 Ubuntu 的过渡包) |
| **S4** | 浏览器来源改为**非 snap**:首选 Mozilla 官方 APT 仓库的 deb(并给该仓库较高优先级);备选 Flatpak | `apt policy firefox` 显示来源为 Mozilla 仓库;`snap list` 仍为空 | Mozilla 官方安装文档;r/Kubuntu 的 pin 报告 |
| **S5** | **升级后复核**:`do-release-upgrade` 会重新引入 snap(社区实测),故升级卡必须包含"升级后跑 S2/S3 复核" | 升级后 `snap list` 仍为空、`dpkg -l snapd` 无输出 | r/Kubuntu PSA 帖 |
| **S6** | 常用功能用 deb/Flatpak 替代:软件商店用 Plasma 自带的 `plasma-discover`(deb/Flatpak);固件更新用 `fwupd`(deb 已有) | `plasma-discover` 可列出并安装 deb 与 Flatpak;`fwupdmgr --version` 正常 | 通用做法 |

**边界(明确不做)**:不追求"系统里一个 snap 相关文件都没有"(`snapd` 的依赖痕迹可能由其它包引入,过度清理会牵连系统);验收判据取"`snap list` 为空 + `dpkg -l snapd` 未安装 + 浏览器来源非 snap"这三条可观测事实。

---

## 4. 分区表(8 项,与 00 号设计 5.1 一致,仅改名)

| 分区 | 大小 | 说明 |
|---|---|---|
| ESP-Windows | 2GiB FAT32 | **只给 Windows**,Linux 侧绝不写入 |
| MSR | 16MiB | Windows 保留 |
| `C:` | 200GiB | Windows 系统盘(原地重装时唯一被格式化) |
| `D:` | ≈635GiB | 共享数据盘(`ntfs3` 读写,两系统都访问) |
| **ESP-Ubuntu** | **1GiB FAT32** | 新建,只放 `\EFI\ubuntu\`;Calamares 里设挂载点 `/boot/efi` |
| `/boot` | 1GiB ext4 | 独立,便于重装 root 时保留内核 |
| root | ≈113GiB | 文件系统:**ext4**(Ubuntu 默认;不用 btrfs,因为不需要快照) |
| WinRE | 1GiB | 磁盘末尾 |

**容量偏离分支**沿用 00 号设计 5.1:1000GB 型号需把 `D:` 减到 ≈613GiB,其余七项不动。

---

## 5. 安装器与三轨道(L3 的改动要点)

- **安装器是 Calamares**(不是 Ubuntu 的 Flutter 安装器,也不是 Anaconda):
  - 手动分区界面里,给 `ESP-Ubuntu` 设挂载点 `/boot/efi`、给 `/boot` 设 `/boot`、给 root 设 `/`;
  - **绝不格式化 Windows 的 ESP**(2GiB 那块)、**绝不把它设为 `/boot/efi`**;
  - Calamares 会把引导装到 `/boot/efi` 所指的那块 ESP,即 `ESP-Ubuntu`(实施时用 `efibootmgr -v` 核对);
  - 已知风险:Calamares 的分区界面**没有"引导器位置"独立选项**,容易误选 Windows ESP —— 因此 `04-2` 卡的 `坑:` 必须写明这一点,并要求先跑 `check-partition-plan.sh`(live 内核对)。
- 三轨道(W 只 Windows / L 只 Kubuntu / D 双系统)**结构不变**;`02-partitioning.md` 的四张卡只把"Fedora 三块分区"的措辞改成"Ubuntu 三块分区"(数值不变)。
- 装完的验证:GRUB 落 `\EFI\ubuntu\`、`BootOrder` 首位仍是 Windows Boot Manager、Fedora 条目名改为 `ubuntu`(条目匹配串以实测为准)。

---

## 6. 脚本与文档影响面

| 类别 | 动作 |
|---|---|
| 删除 | `scripts/linux/dbk-ostree.sh`、`dbk-rollback.sh`、`upgrade-release.sh`、`graphics-mok.sh`(原子版专属,Ubuntu 上无对应机制) |
| 恢复/新增 | `scripts/linux/dbk-pkg.sh`(apt/dpkg 语义,含 `DBK_SKIP_*` 兼容);**新增 snap 规避脚本**(对应 S2/S3/S6:核对 `snap list`、写 apt pin、装非 snap 浏览器) |
| 改写 | `graphics.sh`(改 `ubuntu-drivers install` + Wayland/PRIME 核对 + nouveau 兜底,去掉 ublue/MOK);`set-updates.sh`(改 `unattended-upgrades` 的 deb 语义,**恢复 `templates/unattended-upgrades.snippet`**);`storage.sh`(zram 与 swapfile 的 Ubuntu 适配);`hardening.sh`/`first-boot.sh`(去掉 ostree 语义);`verify-all.sh`(B 组判据改 apt/系统版本,去掉 `rpm-ostree status`) |
| 文档改名 | `docs/04-silverblue.md` -> **`docs/04-kubuntu.md`**;`docs/03-windows.md` 的措辞(轨道 W 不变,仅"Fedora"字样改"Ubuntu") |
| 文档内容 | `00-overview`、`01-firmware`(介质改 Kubuntu ISO + 校验值)、`02-partitioning`(措辞)、`03-windows`(措辞)、`04-kubuntu`(Calamares 手动分区)、`05-first-boot`(卡清单调整:去掉 ublue/MOK/部署回滚/发行版 rebase,新增 snap 规避与升级复核,卡数预计 13 -> **12**)、`07-rescue`(chroot 重建引导改 Ubuntu 的 `grub-install` + `update-grub`;**dracut** 而非 initramfs-tools 的措辞核对)、`08-verification`(F 组判据替换)、`10-faq`(新增 snap/驱动/升级相关症状) |
| 索引与契约 | `steps.tsv`(两侧)按新脚本重排;脚本头 `# 对应卡:` 同步;白名单(执行器)不变 |
| 夹具 | 受影响脚本的夹具重写(apt/dpkg 假命令、`snap`/`ubuntu-drivers`/`do-release-upgrade` 假命令) |

**规模**:约 **20 个脚本 + 4 份文档 + 索引/夹具**要动,相当于重跑一次 B1–B3 那样的批次;`templates/partitions.txt` 的数值**不变**(仅注释措辞)。

---

## 7. 回滚与恢复策略(降级后的替代方案)

| 粒度 | 手段 | 覆盖 |
|---|---|---|
| 单包回退 | `apt install <pkg>=<旧版本>` + `apt-mark hold` | 某次升级把某个软件搞坏 |
| 配置文件回退 | 变更前备份 `baseline/` 与 `/etc` 关键文件(脚本内置 `.dbk.bak`) | 自己改坏配置 |
| 系统级 | **原地重装两法**(只格 `C:` / 只格 root,ESP 绝不格式化)+ 数据在 `D:` 不受影响 | 系统级损坏 |
| 引导级 | ESP 基线镜像还原 + `bcdboot` / `grub-install` 重建 | 引导损坏 |

**已接受的取舍(登记在案)**:没有"一条命令回到上一个可用系统"的能力。恢复时间从"几分钟"变为"30–60 分钟(脚本化重装 + 配置重放)"。

**明确不引入**:snapper、timeshift、grub-btrfs、btrfs 快照、ZFS root(见 2.1)。

---

## 8. 验收(A–F)的调整

| 组 | 调整 |
|---|---|
| A 引导安全 | 不变(含"两个 ESP 互不干扰") |
| B 系统功能 | 去掉 `rpm-ostree status` 相关判据;新增"**snap 零残留**"(`snap list` 空 + `dpkg -l snapd` 无输出)、"显卡驱动来源为 Ubuntu 官方预签名包"、"Wayland 会话" |
| C 双系统切换 | 不变 |
| D 可撤除性 | 不变(参考设备真做一次 L5 退役) |
| E 记录 | 不变(产物齐全且未入库) |
| F 健壮性 | **判据替换**:"部署回滚演练" -> "**包级回退演练 + 原地重装演练**"(并确认数据在 `D:` 不受影响) |

---

## 9. 风险登记增补(并入 00 号设计第 9 节)

| 风险 | 影响 | 缓解 |
|---|---|---|
| `do-release-upgrade` 重新引入 snap | 违反用户约束 | S5:升级卡内置复核;升级前备份 apt pin 文件 |
| `apt install firefox` 拉入 `snapd` 依赖 | 同上 | S3 的 pin + S4 的 Mozilla 仓库优先级;失败则改 Flatpak |
| Calamares 误把 Windows ESP 设为 `/boot/efi` | 可能写坏 Windows 引导 | `04-2` 卡前置核对 + `check-partition-plan.sh` 断言 + L2 基线可还原 |
| 失去原子回滚 | 系统级损坏只能重装 | 数据隔离(`D:`)+ 原地重装两法 + 配置脚本化重放 |
| 第三方 PPA 引入不可控包 | 系统不稳定 | 默认只用官方仓库 + Mozilla 官方仓库;PPA 需逐条说明理由 |
| Ubuntu 26.04 的 Flutter 安装器 ESP 缺陷 | **不适用于 Kubuntu**(用 Calamares),但若误用 Ubuntu 主版镜像则会踩 | 介质卡明确"下载 Kubuntu ISO,不要用 Ubuntu 主版 ISO" |

---

## 10. 取代关系与后续

- 本文件**取代** `02-fedora-atomic-variant-design.md`;后者保留为历史(记录"为什么曾选原子版、为什么改回传统可变系统")。
- `01-playbook-reshape-design.md` 第 4 节的卡清单、`03-step-automation-design.md` 第 6 节的卡到脚本映射,都要按本文件第 6 节同步(在实施批次内完成)。
- 实施方式沿用既定节奏:**实现子代理 + 独立审查子代理 + 修复轮**,每批完成即推送远程。

---

## 11. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-22 | 初版:依据用户决定 A(换 Kubuntu 26.04 LTS)+ 约束"规避 snap 包"编写;六项决定 + 六条 snap 规避措施 + 分区改名 + 回滚降级 + 影响面清单 |
