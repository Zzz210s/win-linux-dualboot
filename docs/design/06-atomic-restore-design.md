# 设计:回切 Fedora 44 原子版(Silverblue)+ 发行版薄接口层

> **本文档取代 `04-kubuntu-variant-design.md`**(Kubuntu 26.04 变体),并**恢复 `02-fedora-atomic-variant-design.md` 为现行内容真源**。02 号设计仍是"原子版怎么落地"的权威参考;本文档负责"为什么回切、这次回切怎么做、以及把发行版差异收敛成薄接口"。

日期:2026-09-25
状态:**已获用户逐节确认(第 1–5 节),待 spec 复审 → 转实施计划**
适用:本仓库(win-linux-dualboot)除 Windows 侧之外的全部文档与 Linux 侧脚本
相关设计:`00-design.md`(方案本体,本次需同步修订)、`01-playbook-reshape-design.md`(卡格式 R1–R7 与自检 C1–C9,不变)、`02-fedora-atomic-variant-design.md`(原子版内容真源,恢复为现行)、`03-step-automation-design.md`(每卡一脚本与契约,本次需同步)

---

## 0. 用户决定(2026-09-25)

| # | 决定 | 原话/依据 |
|---|---|---|
| 1 | **把 Linux 侧从 Kubuntu 变回 Fedora 44 原子版** | 动因 = **snap 清不干净**(见第 1 节:这是设计缺口,不是错觉) |
| 2 | 桌面形态取 **甲**:Silverblue(GNOME 50)+ ublue `bluefin-nvidia` | 官方原子旗舰;ublue 的 GNOME NVIDIA 镜像验证最充分;02 号设计的 D2/镜像名/判据可直接复用 |
| 3 | 回切方式取 **B:在现有结构上重新落原子版设计** | 以 02 号为内容清单重写发行版耦合层,保留全部后置修复;不采用"机械回退历史提交" |
| 4 | 额外目标:把发行版差异**收敛成薄接口层** | 理由:三个月内已两次同向切换,两次都在同一片表面重写(约 20 脚本 + 4 手册) |

## 1. 背景与依据

**为什么"snap 清不干净"成立**:当前(Kubuntu 口径)的规避只覆盖了一个包名与两个目录 ——

- 压制只写 `Package: snapd` + `Pin-Priority: -1`(单个包名);
- 清理只有 `snap remove --purge <应用>` + `apt purge snapd` + `umount`/`rm -rf` 处理 `/var/snap` 与 `/snap`;
- 设计 04 明确写着"不追求系统里一个 snap 相关文件都没有"。

未覆盖的部分包括:其它带 snap 依赖的包名、`~/.snap`、`/var/lib/snapd`、`/etc/apt/apt.conf.d/20snapd.conf`、`snapd.socket/timer/seeded` 单元、`snap` 用户组,以及"别的包被装时又把 snapd 拖回来"。**Fedora 原子版从根上消掉这一类**:RPM 体系 + Flatpak 一等公民,系统里没有 snapd 可清。(事实等级:高 —— Ubuntu 官方包元数据 + 本仓库自身实现。)

**上次切换的规模(用于对齐本次)**:`git diff --stat 361fa1a^..7f547ea` = **51 个文件 / +1984 / −1633**,分布为 `scripts/linux` 31、手册 9、模板 6、清单 2、README 2、自检器 1、设计 1。

**决定性的取舍证据**:切换之后仍有 **13 个耦合文件的修复压在其上**(`cd38172` 11 个 linux 脚本的 shellcheck/行为修复与"自动重启闸门扩到整个 `apt.conf.d`";`9d8ae63` 2 个脚本的 `--yes` 门槛)。任何"整段回退切换提交"的做法都会把它们一起砸掉并需要重新推导 —— 这排除了方式 A。

## 2. 决策表

| # | 决策 | 内容 | 被否方案与原因 |
|---|---|---|---|
| **D1** | 基础系统 | **Fedora 44 Silverblue**(原子版,GNOME 50,Wayland;支持约 13 个月,2026-04 GA) | Kinoite(Plasma)列为等价替换(02 号设计已分析:ublue `Aurora-nvidia`),本次不选,理由是 bluefin 的 NVIDIA 路径验证最充分 |
| **D2** | 发行版薄接口 | 脚本层把差异压到**四个接口**(装包/更新/回滚/驱动),接口一律是**库文件**;步骤脚本不得出现包管理器字面量,由新规则 **S-1** 强制 | 散在各脚本(现状):下次切换仍要改 20 个文件 |
| **D3** | NVIDIA 与 Secure Boot | 安装后 `rpm-ostree rebase` 到 ublue 的 NVIDIA 变体(镜像内模块已预签名)+ **一次性 MOK 注册**;保留 nouveau 兜底 | RPM Fusion `akmods` 直装(原子版下不签名模块,已由 02 号设计否决);关闭 Secure Boot(降低整机安全基线) |
| **D4** | 回滚机制 | **部署级**:`rpm-ostree status` 列部署 + pin/unpin + `rpm-ostree rollback`,回滚后复检 | 包级回退(原子版里没有"改单个包再退回"的粒度)、快照体系(用户已明确否决) |
| **D5** | 更新策略 | 只**检查/下载**,绝不自动应用与自动重启(`/etc/rpm-ostreed.conf`) | "只装安全更新"(apt 粒度,原子版没有该维度):语义如实替换为"只检查/下载",并写进卡与术语表 |
| **D6** | L4 卡数 | 14 张 → **13 张**(删 snap 卡,编号仍连续) | 保留 snap 卡:原子版无 snap,留着就是死卡 |
| **D7** | 分区表 | **只改一个名字**:`ESP-Ubuntu` → **`ESP-Fedora`**;8 项数值与布局一字不动;`templates/partitions.txt` 不改 | 重排分区(无必要且破坏既有验收数值) |
| **D8** | 保留全部既有机制 | 四条不变量 I1–I4、卡格式 R1–R7、每卡一脚本与 CLI 契约、C1–C9 自检、静态分析闸门、夹具全覆盖、术语表、Windows 轨道 | 砍掉任一项都会让"可撤除性"与"可验证性"退化 |

## 3. 薄接口层(第 1 节,已确认)

四个接口一律为**库文件**(头 `# 库文件:非步骤脚本`),不带卡号;步骤脚本只调接口。

| 接口 | 覆盖 | 变量面(= Fedora 原子版) | 关键语义 |
|---|---|---|---|
| `dbk-pkg.sh` | 装包 | 查 `rpm-ostree status --json`;装 = `rpm-ostree install` | **分层安装需重启才生效**;新增 `pkg_needs_reboot()` 如实暴露;`pkg_ensure --now` 在原子版返回 2 需人工 |
| `dbk-update.sh` | 更新策略 | 写 `/etc/rpm-ostreed.conf`(`AutomaticUpdatePolicy=check|download`);判 `systemctl is-enabled rpm-ostreed-automatic.timer` | 绝不自动应用/自动重启 |
| `dbk-rollback.sh` | 回滚 | `rpm-ostree status` / `pin` / `unpin` / `rollback` / 回滚后复检 | 部署级(见 D4) |
| `dbk-driver.sh` | 显卡与 Secure Boot | `rebase` 到 `ostree-image-signed:docker://ghcr.io/ublue-os/bluefin-nvidia:latest` + `ujust enroll-secure-boot-key`;判 `modinfo -F signer nvidia`、`mokutil --list-enrolled` 含 ublue 密钥、`lsmod` 有 `nvidia` | `rebase` 可逆;nouveau 兜底保留 |

**接口命名纪律**:接口名**不带发行版或实现痕迹**(`dbk-pkg.sh`,不是 `dbk-ostree.sh` —— 后者等于承认"下次切换还要再改一遍名字";该文件历史上已被改名两轮)。

**强制手段 S-1(新增到 `scripts/repo/check-scripts.sh`)**:除上述四个接口文件外,任何 `scripts/linux/*.sh` 出现 `apt-get` / `apt ` / `dpkg` / `snap ` / `rpm-ostree` / `dnf` 字面量即 FAIL。没有这条,薄接口只是口号。(配套:`check-docs-lib.sh` 的白名单与 `03-step-automation-design.md` 的 C9d 名单同步,避免夹具 F7 变红。)

## 4. 脚本层语义回切(第 2 节,已确认)

| 脚本 | 现在(Kubuntu) | 回切后 |
|---|---|---|
| `dbk-pkg.sh` | apt/dpkg 语义 | **保留文件名**(接口面不变),内部改 ostree |
| `dbk-update.sh` / `dbk-rollback.sh` / `dbk-driver.sh` | 不存在 | **新增 3 个库文件** |
| `rollback-pkg.sh` | 包级降级 + `apt-mark hold` | **删除**(由部署级回滚取代) |
| **新增 `rollback-deploy.sh`** | 不存在 | 卡 `05-9` 的**步骤脚本**(薄):`--check` 调 `dbk-rollback.sh check`;`--apply --yes` 调回滚并向重启提示 —— 接口是库文件,卡仍需自己的步骤脚本(这是 50/50 计数的来源:51 − 2 + 1) |
| `step-snap-free.sh` | snap 四条判据 + 清残留 + apt pin + Mozilla 源 | **删除**(原子版无 snap) |
| `graphics.sh` | `ubuntu-drivers` 预签名包 | 薄脚本:`--check` 调 `dbk-driver.sh check`;`--apply` 调 rebase + MOK |
| `set-updates.sh` | `unattended-upgrades` | 调 `dbk-update.sh`;模板 `unattended-upgrades.snippet` → `rpm-ostreed.snippet` |
| `storage.sh` | zram 安装/配置 | zram 改**核对**(不符才用 `templates/zram-generator.conf` 兜底)+ 4GiB swapfile |
| `set-remote-health.sh` / `bt-keys-sync-wrapper.sh` | `apt install` 立即生效 | 走 `dbk-pkg.sh`;输出**显式提示"分层安装,重启后生效"** |
| `check-health.sh` | 判据含 snap 零残留 | 改为:部署数 + 是否有 pinned 部署 + `rpm-ostreed-automatic` 状态 + 会话类型 + 显卡来源 + 待更新 |
| `verify-l3.sh` | 查 `grub-efi-amd64`/`shim-signed`(dpkg) | 查 ostree 部署存在、`/boot/ostree` 存在、两块 ESP 互不干扰、BootOrder 首位仍是 Windows |
| `collect-l3.sh` / `collect-l4.sh` | apt 口径字段 | 字段回切:部署列表与 pin、MOK 状态、`nvidia` 模块签名、zram 核对结果;`/boot` 独立挂载那一节**保留** |
| `triage.sh` | `apt-get -s dist-upgrade` 等 | 改 ostree 部署列表 + `journalctl -b -p err` |
| `check-signature.sh` | Ubuntu 官方签名口径 | MOK 口径恢复(`mokutil --sb-state` + `--list-enrolled` 含 ublue 密钥) |
| `upgrade-release.sh` | `do-release-upgrade`(约 3 年一次) | pin 当前部署 → `rpm-ostree rebase <分支>` → 重启 → 后置复检(**约 13 个月一次**) |
| `hardening.sh` / `first-boot.sh` | 调 apt 语义 | 改调接口;`--apply --yes` 门槛与"逐项失败不中断 + 汇总"语义**保留** |
| `verify-all.sh` | B/F 组含 snap 判据、包级回退演练 | B 组换回显卡来源/MOK;F 组换成**部署回滚演练**;`--check` 零写语义保留 |
| `check-partition-plan.sh` | `ESP-Ubuntu 1GiB` | 改名 `ESP-Fedora 1GiB`(数值与布局不动) |
| `mount-shared.sh` / `xdg-redirect.sh` / `set-time.sh` / `set-journald.sh` | 与发行版无关 | **不动**(仅可能因 S-1 做措辞级调整) |
| `dbk.sh` / `dbk-cli.sh` / `dbk-obs.sh` / `dbk-log.sh` | 契约库 | **不动** |

## 5. 手册与配置层(第 3 节,已确认)

| 文档 | 改动 |
|---|---|
| `04-kubuntu.md` → **`04-silverblue.md`** | L3 四张卡改成 Anaconda 手动分区:ESP-Fedora 1GiB + `/boot` 1GiB ext4 + root ≈113GiB btrfs;**绝不让 Anaconda 使用 Windows 的 ESP**(上游 Anaconda 在含既有 ESP 的盘上的失败模式) |
| `05-first-boot.md` | 14 张 → **13 张**;`05-3` 改 rebase+MOK;`05-7` 更新策略改 rpm-ostreed;`05-5`/`05-8` 加"分层安装需重启";`05-9` 包级回退 → **部署回滚**;`05-10` 改 `rpm-ostree rebase` 升级;`05-12` 产物字段回切 |
| `02-partitioning.md` | ESP 改名 + 轨道 L 布局说明回切 |
| `03-windows.md` | 只同步引用;Windows 侧步骤不动 |
| `07-rescue.md` | `\EFI\ubuntu\` → `\EFI\fedora\`;原地重装 Linux 改为**先试部署回滚、再谈重装**(保留不可逆警告与次序) |
| `08-verification.md` | A–F 组判据回切;B 组换回 MOK/显卡来源;F 组换成部署回滚演练;删 snap 四条判据;自动化覆盖侧别表同步 |
| `10-faq.md` | snap 相关卡改写为"为什么选原子版:这类问题被结构性消灭";新增"分层安装为什么要重启""回滚还是重装""rebase 会不会丢数据" |
| `00-overview.md` / `01-firmware.md` | 系统名、寿命(13 个月)、轨迹同步;不变量与参数表数值不变 |
| `checklists/deploy.md` / `checklists/rollback.md` | 回滚清单改部署级 |
| `templates/` | 新增 `rpm-ostreed.snippet`;删 `unattended-upgrades.snippet` 与 Mozilla apt 源片段;`zram-generator.conf` / `fstab` / `user-dirs` / `grub` 保留 |
| `docs/design/05-glossary.md` | 改三条:snap 规避(标为**已废止的 Kubuntu 时代约束**)、Calamares/Anaconda(去"已被取代")、原子版(恢复为**现行**,补 rollback/rebase/分层安装术语) |

## 6. 夹具、验证与交付(第 4 节,已确认)

- **夹具重写**(Linux 侧):假命令从 apt/dpkg/snap/ubuntu-drivers/do-release-upgrade 换成 `rpm-ostree`/`rpm`/`systemctl`/`mokutil`/`ujust`/`modinfo`;新增 **4 个接口的单元夹具**(装包/更新/回滚/驱动各自的通过、失败、零写);删 snap 卡相关用例;Windows 夹具基本不动。
- **修复存活审计**:把 13 条后置修复逐条在新内容上勾验(`cd38172` 的行为修复与闸门扩目录、`9d8ae63` 的 `--yes` 门槛、`25d8b23` 的只读契约)。
- **门禁**:`check-docs`(卡数变更后)、`check-scripts`(含 S-1)、`check-docs` 夹具套件全绿;步骤脚本夹具覆盖 **50/50**、断言数**不少于当前 320**。
- **交付**:打 **v0.2.0**;README 双语同步;状态声明保持"设计完备 + 夹具级验证,**真机未跑**"。

## 7. 风险、取舍与非目标

| 风险 | 处置 |
|---|---|
| 13 个月升级节奏回来了 | 写成正式卡(`05-10`)+ 巡检项;02 号设计已有现成内容 |
| ublue 镜像名 / `ujust` 任务名 / MOK 密码未核实 | 标 `# 待核实(以官方文档为准)`;卡片给判据与官方文档指引 |
| 分层安装"装了但没生效" | 接口暴露 `pkg_needs_reboot`;L4 把分层安装**合并到一次重启**;卡片显式提示 |
| Anaconda 在含 Windows ESP 的盘上装 Silverblue 失败 | 独立 ESP + 独立 `/boot` 为硬要求;L3 前置核对,失败即回分区卡 |
| 双 ESP 固件支持未承诺 | 验收 A 组列为"参考设备必做"实测项 |
| 薄接口只保住脚本层,手册仍与发行版绑定 | 如实说明:下次切换 ≈ 4 份手册 + 4 个接口,不再是 6 批;S-1 守住脚本层不退化 |
| 夹具重写期覆盖率短暂下降 | 验收线 = 步骤脚本 50/50 且断言数 ≥320 |

**非目标**:不做 Kubuntu 与原子版的双变体并行维护;不动 Windows 侧流程与分区数值(仅 ESP 改名);不引入 bootc/容器化未来形态;不改四条不变量;不做真机执行(本轮仍只改仓库内容)。

## 8. 实施批次(供实施计划细化)

| 批次 | 内容 |
|---|---|
| 1 | 设计回切:本文档入库;`02` 升为现行内容真源;`04` 标 superseded;`00` / `03` 同步原子版口径 |
| 2 | 薄接口层:4 个库文件 + 契约说明 + **S-1 规则**与白名单/C9d 同步 |
| 3 | 20 个耦合脚本改走接口、恢复 ostree 语义 |
| 4 | 手册层:`04-kubuntu.md` → `04-silverblue.md`;`05-first-boot.md` 13 张卡;`02`/`03`/`07`/`08`/`10`/`00`/`01` 同步;清单与模板 |
| 5 | 夹具重写 + 修复存活审计 + 门禁全绿 + 术语表/README + 打 **v0.2.0** |

## 9. 事实等级与待核实

| 断言 | 等级 | 来源 |
|---|---|---|
| Fedora 44 Silverblue 于 2026-04-28 GA,支持约 13 个月 | 高 | Fedora 官方发布与生命周期文档(02 号设计已记录) |
| ublue 的 NVIDIA 变体镜像内模块预签名,MOK 注册密码为 `universalblue` | 中 | ublue 上游文档与社区指南(**实施时以官方文档为准**) |
| `ujust enroll-secure-boot-key` 的任务名与行为 | 中 | 同上(**待核实**) |
| Anaconda 在含既有 ESP 的盘上装 Silverblue 的失败模式 | 中 | 上游 issue 与社区实测(02 号设计已记录) |
| 双 ESP 的固件支持 | 低 | 无官方承诺;列"参考设备必做"实测项 |
| snap 残留的未覆盖面(包名、目录、单元、用户组) | 高 | 本仓库实现自查 + Ubuntu 包元数据 |

## 10. 变更历史

- 2026-09-25:首版。记录用户四项决定(回切、Silverblue、方式 B、薄接口),给出接口层契约、脚本/手册/夹具三层改动清单、13 条修复存活审计要求、风险与非目标、5 批实施批次。
