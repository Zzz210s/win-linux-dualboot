# 术语表(本项目自己的行话)

本文件解释 `win-linux-dualboot` 仓库里反复出现、但对新读者并不自明的术语。每条给:定义 + 在本项目里的具体所指 + 定义它的真源位置。写得简短,便于回查。

约定:术语按"工程方法 → 流程 → 引导与系统 → 协作"分组;英文原词放在括号里,方便去上游文档检索。

---

## 一、工程方法类

**夹具(fixture)**
预置的假命令与假数据环境,让脚本在**没有真机**的情况下也能跑通并被断言。本项目 51 个步骤脚本**全部**有夹具,断言合计 320 条(k1 77 / Windows 174 / 文档校验器 69)。
相关词:**runner**(跑夹具的入口,末行打印 `PASS=n FAIL=m`)、**假件(stub)**(夹具里的假命令,如假的 `efibootmgr`)、**零写断言**(快照对比,证明只读路径没改任何文件)。
真源:`docs/design/03-step-automation-design.md` 第 7 节。

**门禁 / 自检闸门(gate, self-check)**
提交前必须全绿的自动检查。本项目两道:
- `scripts/repo/check-docs.sh` —— 文档规则 **C1–C9**(卡格式、编号引用可解析、脚本与卡双向绑定、占位符/emoji/相对链接);
- `scripts/repo/check-scripts.sh` —— 每个脚本 ≤200 行、bash/PowerShell 语法解析、**shellcheck** 与 **PSScriptAnalyzer**(只跑高信号规则)。
不过门禁不允许提交;跳过检查项必须显式打印 `SKIP`,不能默默通过。
真源:`docs/design/01-playbook-reshape-design.md` 第 6 节、`docs/design/03-step-automation-design.md` 第 4 节。

**仓库(repo / repository)**
版本库。本项目本地在 `F:\0-code\20-active\tool-win-linux-dualboot`,远端是公开仓库 `github.com/Zzz210s/win-linux-dualboot`。
注意区分:**笔记库**(`F:\0-Note`,存笔记正文)与**代码工作区**(`F:\0-code`,按 `seed/active/stable/paused/archived` 分 lane 存代码项目)是两个不同的库。

**动作卡(card)**
执行手册里的最小操作单元。一张卡固定四段:**做**(动作与命令)、**看到**(判据)、**坑**(做错会怎样)、**出错时**(指向别的卡或文档)。
限制:一张卡 ≤25 行;编号形如 `04-2`(文档号-序号),全仓可机器校验。
真源:`docs/design/01-playbook-reshape-design.md` 第 3 节(R1–R7)。

**步骤脚本(step script)**
"一张卡一个脚本"。统一 CLI:`--check`(缺省,只读判定)、`--apply`(执行)、`--json`、`--log`、`--yes`;脚本头必须写 `# 对应卡:NN-K`。
真源:`docs/design/03-step-automation-design.md` 第 2 节。

**契约(contract)**
脚本之间、文档与脚本之间的**共同约定**:CLI 形状、退出码、脚本头声明、`steps.tsv` 索引字段。
相关词:**卡↔脚本双向绑定**(任何脚本必须被某张卡引用,任何被引用的脚本必须存在,由 C9a–C9d 校验)。

**退出码(exit code)**
`0` PASS / `1` FAIL / `2` 需人工 / `9` 跳过 / `64` 用法错误(含"破坏性动作缺 `--yes`")。

**零写(zero-write)**
只读路径(`--check`)不得改动**任何**文件。夹具用"改动前后快照对比"来证明,而不是靠脚本自述。

**破坏性门槛(destructive gate)**
会改系统状态的脚本必须在脚本头写 `# 破坏性:1`;此时 `--apply` 若缺 `--yes`,库层直接拒(退出码 64)且**零写**。索引 `steps.tsv` 的破坏性列必须与脚本头一致。

**幂等(idempotent)**
同一个脚本重复跑不会叠加副作用,只补缺失的部分(例如 fstab 已有目标行就不再追加)。

**判据(criterion,"看到:"行)**
"怎么算这一步成功"的**可观测**条件:屏幕上的具体文字、命令输出的具体行、文件/分区是否存在。禁止"确认无误"这类不可观测表述。

**人工项(manual)**
脚本判不了、必须人去看的项(grep 不到读数、需要进固件界面)。脚本输出"需人工"并以退出码 `2` 结束;验收时由人确认后加 `--confirm-manual` / `-ConfirmManual` 才不再计入退出码。

**台账(ledger)**
本地过程记录:批次报告、审查发现、修复轮、口径裁定,落在 `.superpowers/sdd/.../progress.md` 与 `batches/*.md`。**不入库**(AI 产物不上远程)。

**回归(regression)**
改动之后重跑既有断言,确认没有把原来能跑的东西改坏。本项目常用手法:用 `git worktree` 拉一份改动前的副本,逐脚本对比退出码是否一致。

**静态分析闸门(static analysis gate)**
`shellcheck`(bash)与 `PSScriptAnalyzer`(PowerShell)接进门禁。注意历史教训:工具没装时门禁会打印 `SKIP` —— "没报错"不等于"检查过"。

**基线(baseline)**
装机前后采集的机器状态快照:ESP 镜像、分区表、固件启动项、体检结论。产物落在 `baseline/` 下、命名前缀 = 所在阶段号(如 `02-partitions.txt` 属 L2)。**`baseline/` 除 `README.md` 外一律不入库。**

**产物(artifact)**
每个阶段结束必须落盘的可验证文件;没有产物视为该阶段未完成。

**参考实现 / 首跑(reference implementation, first run)**
设计里的定义:**至少一台设备完整跑通 `docs/08-verification.md`** 才算这台机器部署完成。当前项目状态是"设计完备 + 夹具级验证",**真机从未跑过**。

---

## 二、流程类

**阶段 L0–L5**
L0 装机前固件与介质 → L1 Windows → L2 预检基线(**硬闸门**)→ L3 Kubuntu 安装 → L4 首启收敛 → L5 退役与救援。

**轨道 W / L / D**
三种装机目标:**W** 只装 Windows、**L** 只装 Kubuntu、**D** 双系统。分盘是三种轨道共用的**前置章节**。

**硬闸门(hard gate)**
L2 的预检结论:**有红项就禁止进入 L3**。红/黄/绿三态写进闸门报告,再由 `check-gate` 读出并给出"允许/禁止"。

**退役(decommission)**
安全移除 Linux 的顺序:先归位引导顺序 → 备份现状 → 删 Linux 分区 → 清 NVRAM ⇒ 可选扩回数据盘。**顺序不可交换**;反例就是"先格式化 Linux 分区再修引导",那正是卡在 `grub>` 提示符的成因。

**原地重装(in-place reinstall)**
只格式化系统分区重装(Windows 只格 `C:`、Kubuntu 只格 root),不动数据盘、不动对方的 ESP。

**可撤除性演练(retractability drill)**
验收 D 组:临时删掉 `\EFI\ubuntu\` 目录并重启,确认机器**自动进 Windows**、不会停在 `grub>`;再用 ESP 镜像还原。这是"删了 Linux 也不卡引导"这条承诺的实测证据。

**验收 A–F 组**
`docs/08-verification.md` 的六组检查:引导安全 / 系统功能 / 双系统切换 / 可撤除性 / 记录 / 健壮性。

---

## 三、引导与系统类

**不变量 I1–I4**
全案骨架,任何步骤不得违反:
I1 `BootOrder` 首位**永远是 Windows Boot Manager**;I2 进 Linux 只用**一次性** `BootNext`,不改永久顺序;I3 绝不覆盖 `\EFI\Microsoft\`、绝不改 `{bootmgr}` 的 `path`;I4 破坏性动作之前先有基线。

**ESP(EFI System Partition)**
固件唯一会读的引导分区(FAT32)。本项目**两块独立 ESP**:`ESP-Windows` 2GiB(只给 Windows)、`ESP-Ubuntu` 1GiB(只放 `\EFI\ubuntu\`)。独立的作用是让"不覆盖对方引导"从纪律变成结构。

**BootOrder / BootNext**
固件里的**永久**启动顺序 / **一次性**启动项(用完自动消失)。`efibootmgr -o` 会改永久顺序 → 违反 I2;`efibootmgr -n` 或用固件启动菜单键则符合 I2。

**GRUB / grub rescue**
Linux 引导器 / 它找不到 `/boot` 时掉落的最小 shell。项目提供两条恢复路径:在 `grub>` 里 `insmod normal` 等命令修回来,或直接从 GRUB 链式加载 `\EFI\Microsoft\Boot\bootmgfw.efi` 回 Windows。

**Secure Boot / shim / MOK**
固件验签 / 第三方引导的签名跳板 / 你自签名模块后要手动注册的密钥库(Machine Owner Key)。本项目走**官方预签名包**路线,所以保持 Secure Boot 开启且**不需要**自签与 MOK 注册。

**UEFI / GPT / VMD / AHCI**
固件接口 / 分区表格式 / Intel 的 RAID 模式(会遮蔽 NVMe,Linux 安装器看不到盘)/ 直通模式(目标状态)。

**快速启动(Fast Startup)与休眠**
Windows 的"混合关机"。开启时 NTFS 处于脏状态,Linux 侧挂载有**数据损坏**风险,所以装机前必须关掉;本项目也不配置休眠。

**共享盘(shared disk)**
`D:` 分区(NTFS),Windows 原生读写、Kubuntu 用内核 `ntfs3` 读写挂到 `/mnt/shared`。前提:`D:` 不加密、Windows 关快速启动、挂载选项带 `windows_names` 与 `nofail`。

**XDG 重定向(XDG redirect)**
把"文档/下载/图片/桌面"等家目录目录指到共享盘(`~/.config/user-dirs.dirs`),让两个系统看到同一批文件;`~/.config`、`~/.ssh`、代码仓库**留在本地**,因为它们依赖 POSIX 权限语义。

**zram / swapfile**
用压缩内存当交换(快) / 用文件当交换(可随时改大小)。本项目**不建 swap 分区、不配休眠**。

**snap 规避(S1–S6)**
Ubuntu 系默认用 snap 分发部分软件(Kubuntu 的 `kubuntu-desktop` 有 `Recommends: snapd`)。规避六招:最小安装、清残留、apt pin 到 -1、浏览器改用 Mozilla 官方 deb 源、升级后复核、用 deb/Flatpak 替代。四条可观测判据写在卡 `05-14`。

**Wayland-only / PRIME offload / nouveau 兜底**
Kubuntu 26.04 只有 Wayland 会话(X11 已移除) / 混合显卡下用独显按需渲染、核显负责显示 / 开源驱动作为"专有驱动装坏也能进桌面"的退路。

**Calamares / Anaconda**
Kubuntu 的安装器 / Fedora 的安装器(本项目的**历史**方案,Fedora 原子版已于 2026-09 被 Kubuntu 取代,相关设计文档保留作决策记录)。

**原子版(atomic,rpm-ostree)**
不可变系统 + 部署级回滚。属于**被否方案**:它的回滚优势被"包管理、驱动、开发环境整套要改"的代价抵消。

**磁盘隔离(disk isolation)**
系统盘与数据盘分离:Windows 侧 `C:` 200GiB 只放系统与程序、`D:` ≈635GiB 放数据;Kubuntu 侧 root ≈113GiB 只放系统。作用是"原地重装只格系统分区,数据不丢"。

---

## 四、协作类

**简报(brief)/ 简报集散地(brief-hub)**
跨会话的通知机制:会话把"我改了什么/出了什么错"投成一条简报,其它会话按**标签订阅**接收。
相关词:**标签**(如 `proj:0-note`、`sev:err`、`repo:owner/name`;订阅按标签匹配)、**投递级别 l1/l2**(只送标题 / 标题+正文)、**handle/defer**(处理掉 / 延后 4 小时)。

**会话 id(session id)**
每个 AI 会话的唯一标识(形如 `01a0af35-…`),简报订阅、`ais` 会话看板、心跳注册表都用它定位。

**子代理(subagent)/ 实现者 / 审查者**
把工作拆给隔离上下文的代理:一个负责写(实现者)、另一个独立复核(审查者)。本项目大改版就是"每任务一实现 + 一审查 + 修复轮"跑出来的。

**归因撤回(attribution retraction)**
发现自己把"自己加的工程约定"说成"用户的要求"时,主动改正并记进台账。本项目发生过一次:审计条款的归属被改成工程约定。

**已知例外(known exception)**
验收清单里允许存在的、明确记录的偏差。有它在案,该条不算不通过;没它就必须修。

---

## 相关文档

- 术语的规则真源:[`01-playbook-reshape-design.md`](01-playbook-reshape-design.md)(卡格式与自检规则 C1–C9)
- 脚本契约真源:[`03-step-automation-design.md`](03-step-automation-design.md)(CLI、退出码、每卡一脚本映射)
- 当前方案与决策记录:[`00-design.md`](00-design.md)
- 变体决策(当前用 Kubuntu):[`04-kubuntu-variant-design.md`](04-kubuntu-variant-design.md)
