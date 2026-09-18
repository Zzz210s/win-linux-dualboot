# 设计:每一步一个脚本(步骤自动化)

日期:2026-09-18
状态:待实施(实施前需用户复审)
适用:本仓库全部动作卡与 `scripts/`
相关设计:`01-playbook-reshape-design.md`(卡格式)、`02-fedora-variant-design.md`(Fedora 变体)。本设计为第三层:**把"卡"与"脚本"一一绑定**。

---

## 1. 背景与目标

现状:**43 张动作卡**(L0 4 / L1 6 / L2 4 / L3 4 / L4 12 / L5 5 / 07 救援 8)对应 **18 个脚本**,其中真正覆盖动作的约 10 个,缺的恰是最危险的 L5(删分区、清 NVRAM)与 07(救援)。

目标:**每个动作卡都有一个脚本**,卡里的"做:"就是"跑哪个脚本、看什么判据";人工只保留两类无法自动化的动作(固件设置界面的开关、Anaconda 里的点击)。

已定的三项(用户逐条确认):

| # | 决定 |
|---|---|
| S1 | **双模式型**:每步一个脚本,**默认 `--check`**(只读,自动判定该卡的 `看到:` 判据,输出 `PASS`/`FAIL`/`需人工`)、**`--apply`** 才执行(幂等 + 前置断言 + 破坏性动作显式 `--yes`)。**不做阶段级一键连跑编排**(被否理由:无法在真机上做到彻底,且放大连跑改分区表的风险) |
| S2 | **L3 的 Fedora 安装保持人工**(Anaconda 交互);用"L3 前置核对脚本(`check-partition-plan.sh`)+ L3 后置校验脚本(`verify-l3.sh`)"把这步包住。kickstart 无人值守**不作为 v1 路径**(被否理由:出错时无人拦,分区写错即毁 Windows) |
| S3 | **危险三步**(删 Linux 分区、清 NVRAM、改引导顺序)允许 `--apply`,但必须:默认 `--check`、需 `--yes`、脚本内前置断言(基线存在 + `BootOrder` 首位仍是 Windows Boot Manager)、执行后立刻复读断言并在输出里打印结果 |

## 2. 统一的 CLI 契约(所有步骤脚本)

```
<script> [--check] [--apply] [--json] [--log <path>] [--yes] [--step <NN-K>]
```

| 参数 | 语义 |
|---|---|
| `--check`(缺省) | 只读;判定本步是否达成;不写任何系统状态 |
| `--apply` | 执行本步;必须幂等(重复执行结果一致);执行前跑前置断言 |
| `--yes` | 破坏性动作(删分区、清 NVRAM、改引导顺序、写 fstab)必需;缺省时打印将执行的命令与影响并要求加上 |
| `--json` | 机器可读输出(供总控与验收汇总消费);字段:`step`、`status`、`checks[]`、`actions[]`、`changed` |
| `--log <path>` | 缺省 `/var/log/dbk/<script>.log`(Linux)或 `%LOCALAPPDATA%\dbk\logs\`(Windows) |
| `--step <NN-K>` | 显式声明本脚本服务的卡号;与脚本头 `# 对应卡:` 不一致时报用法错误退出 |

**退出码语义(全仓统一,PowerShell 与 Bash 一致)**

| 码 | 含义 |
|---|---|
| 0 | `PASS`(该步已达成 / `--apply` 执行成功且后置断言通过) |
| 1 | `FAIL`(判据未达成、或执行失败) |
| 2 | `需人工`(脚本无法判定的项,必须人看;不视为失败) |
| 9 | 跳过(显式 `DBK_SKIP_*` 或环境不适用,如非 Linux 上跑 Linux 脚本) |
| 64 | 用法错误(参数缺失、`--yes` 未给、`--step` 冲突) |

**硬规则**

1. 每个脚本 ≤200 行;超出则拆文件(拆出的公共逻辑放库文件,不计入卡)。
2. 脚本头必须有一行 `# 对应卡:NN-K`(或 `# Card: NN-K`),与卡一一对应;
3. 库文件(不被卡直接调用的)写 `# 库文件:非步骤脚本`,并进入 C9 白名单;
4. 脚本默认 dry-run 的语义**不允许反转**(任何脚本都不许"默认就执行");
5. 未在真机验证过的命令,脚本内注释标 `# 待核实(以官方文档为准)`,并在 `--check` 输出里以 `需人工` 呈现;
6. 脚本一律不得使用 `efibootmgr -o`、不得写 `\EFI\Microsoft\`、不得改 `{bootmgr}` 的 `path`(违反即视为缺陷)。

## 3. 卡与脚本的绑定

| 项 | 约定 |
|---|---|
| 卡内引用 | "做:"行给出可复制的调用,如 `scripts/linux/mount-shared.sh --check`;末尾 `脚本:` 行给出路径与对应的 `--check`/`--apply` 组合 |
| 脚本命名 | **语义名**(如 `disable-faststartup.ps1`、`set-snapshots.sh`),不用 `step-NN-K` 编号名 —— 文件名可读性更重要,绑定关系靠脚本头的 `# 对应卡:` 与卡内的 `脚本:` 行双向记录 |
| 无脚本的卡 | 卡内写 `脚本:无(人工)` 或 `脚本:无(纪律条款)`,并说明为什么不能自动化 |
| 双向校验 | 新增自检规则 **C9**(见第 4 节) |

## 4. 自检规则新增 C9(卡 ↔ 脚本双向绑定)

在 `01-playbook-reshape-design.md` 第 6 节的 C1–C8 之后追加:

| 规则 | 内容 |
|---|---|
| C9a | 卡内出现的 `scripts/**/*.{sh,ps1}` 路径**必须存在**(正斜杠与反斜杠写法都认,如 `scripts\windows\x.ps1`) |
| C9b | 每个 `scripts/repo/*.sh`、`scripts/linux/*.sh` 与 `scripts/windows/*.ps1` **必须**含 `# 对应卡:` 行(或 `# Card:`),且该卡号在对应文档中真实存在(白名单:库文件与仓库自检脚本) |
| C9c | **反向覆盖**:每个步骤脚本必须被至少一张卡引用(`grep` 卡内路径,正斜杠与反斜杠写法都认) |
| C9d | 白名单(库/自检脚本:不要求 `# 对应卡:`、不要求被卡引用):`scripts/linux/dbk-log.sh`、`scripts/linux/dbk-cli.sh`、`scripts/linux/dbk-pkg.sh`、`scripts/linux/dbk.sh`、`scripts/linux/dbk-apt.sh`(legacy 库,将在任务 14 并入 `dbk-pkg.sh`)、`scripts/repo/check-docs.sh`、`scripts/repo/check-docs-lib.sh`(check-docs 公共解析库)、`scripts/repo/check-docs-repo.sh`(仓库级 C9b/c/d 检查)、`scripts/repo/check-scripts.sh`、`scripts/windows/dbk-cli.ps1`、`scripts/windows/dbk.ps1`。白名单以自检脚本内的 WL 为唯一实现,两处必须逐行一致(夹具额外校验 `extra-checks-c9.sh` 有断言);C9d 另校验 `scripts/{linux,windows}/steps.tsv` 与步骤脚本一一对应(索引行指向的脚本必须存在且是本侧步骤脚本,本侧步骤脚本必须登记进索引,缺索引时报「缺少步骤索引」) |

C9 的价值:文档与脚本从此不会脱钩——改脚本名而忘改文档、或写了脚本却没人调用,自检当场报错。

## 5. 新增总控入口

| 入口 | 作用 | 约束 |
|---|---|---|
| `scripts/windows/dbk.ps1 <step> [-Apply] [-Yes] [-Json]` | Windows 侧步骤分发(读步骤索引 → 调对应脚本 → 汇总输出) | 只做分发与汇总,**不含任何业务逻辑**;拒绝未知步骤名 |
| `scripts/linux/dbk.sh <step> [--apply] [--yes] [--json]` | Fedora 侧同上 | 同上 |
| `scripts/windows/verify-all.ps1` / `scripts/linux/verify-all.sh` | 按 `08-verification.md` 的 A–F 逐项自动判定,汇总写 `baseline/08-verification.md`(每台设备副本) | 只做判定与汇总;不得自动执行 `--apply` |

步骤索引文件:`scripts/windows/steps.tsv`、`scripts/linux/steps.tsv`(列:步骤号、脚本路径、是否破坏性、说明)。总控读它分发,C9 也校验它的一致性。

## 6. 逐卡脚本映射表(43 张动作卡 → 脚本)

**图例**:`[有]` 已存在(可能需加 `--check/--json` 契约);`新` = 本次新增;`人工` = 无法自动化(卡内标注)。

| 卡 | 动作 | 脚本 |
|---|---|---|
| 01-1 | 改固件设置 | 新 `windows/check-firmware.ps1`(--check 读 Secure Boot/VMD 推断;BIOS 内的开关本身只能人工) |
| 01-2 | 做两个安装介质 | 新 `windows/verify-install-media.ps1`(校验 ISO 存在与哈希、列出可移动盘;写入由 Ventoy 人工) |
| 01-3 | 核对目标盘 | [有] `windows/preflight.ps1 -Only target-disk`(需新增 `-Only`) |
| 01-4 | 落 L0 产物 | 新 `windows/collect-l0.ps1` |
| 02-1 | diskpart 预建分区 | 新 `windows/create-partitions.ps1`(--apply 生成并执行 diskpart 脚本;前置断言:磁盘当前无有效分区表) |
| 02-2 | 装 Windows | 新 `windows/verify-windows-baseline.ps1`(安装为人工;脚本核对版本/分区/WinRE 偏差) |
| 02-3 | 关 Fast Startup 与休眠 | 新 `windows/disable-faststartup.ps1` |
| 02-4 | 已知文件夹重定向 | 新 `windows/redirect-known-folders.ps1`(--check 读 `User Shell Folders` 比对) |
| 02-5 | KMS 激活 | 新 `windows/check-activation.ps1`(激活动作人工、外链;脚本只读状态) |
| 02-6 | 落 L1 产物 | 新 `windows/collect-l1.ps1` |
| 03-1 | 跑只读体检 | [有] `windows/preflight.ps1` |
| 03-2 | 读闸门结论 | 新 `windows/check-gate.ps1`(解析报告 → PASS/FAIL 并列红项) |
| 03-3 | 跑基线备份 | [有] `windows/backup-esp.ps1`(加 `--check`:校验已有备份的 `manifest.sha256`) |
| 03-4 | 落 L2 产物 | 新 `windows/collect-l2.ps1` |
| 04-1 | UEFI 启动进 live | [有] `windows/set-bootnext.ps1`(扩展 `-Device USB`:设置一次性从 U 盘启动) |
| 04-2 | 手动分区(Anaconda) | 新 `linux/check-partition-plan.sh`(在 live 里跑:读 `lsblk`/`blkid`/`sgdisk -p` 比对计划,输出"下一步该建什么";分区动作人工) |
| 04-3 | 装完重启验证 | 新 `linux/verify-l3.sh`(btrfs 挂载与子卷、ESP 内容、GRUB 条目名、`BootOrder` 首位) |
| 04-4 | 落 L3 产物 | 新 `linux/collect-l3.sh` |
| 05-1 | 共享盘挂载 | [有] `linux/mount-shared.sh` |
| 05-2 | 家目录重定向 | [有] `linux/xdg-redirect.sh` |
| 05-3 | 显卡驱动与 MOK | [有] 改写 `linux/graphics.sh` + 新 `linux/graphics-mok.sh` |
| 05-4 | 时间 | 新 `linux/set-time.sh` |
| 05-5 | 蓝牙 | [有] `linux/bt-keys-sync-wrapper.sh` |
| 05-6 | zram 与 swapfile | [有] `linux/storage.sh` |
| 05-7 | journald 与更新策略 | 新 `linux/set-journald.sh`、新 `linux/set-updates.sh`(dnf-automatic) |
| 05-8 | SSH 与 SMART | 新 `linux/set-remote-health.sh` |
| 05-9 | 快照与回滚 | 新 `linux/snapshot.sh`、新 `linux/set-snapshots.sh`(snapper + grub-btrfs) |
| 05-10 | 发行版升级 | 新 `linux/upgrade-release.sh` |
| 05-11 | 回 Windows 入口 | [有] `linux/reboot-to-windows.sh` |
| 05-12 | 落 L4 产物 | 新 `linux/collect-l4.sh` |
| 06-1 | 归位引导顺序 | 新 `windows/restore-boot-order.ps1`(前置断言;不改 `{bootmgr}` 路径) |
| 06-2 | 备份现状 | [有] `windows/backup-esp.ps1 -OutDir D:\dbk-l5-backup` |
| 06-3 | 删 Linux 分区 | 新 `windows/delete-linux-partition.ps1`(**破坏性**:`--yes` + 前置断言 + 只按分区号/GUID 精确删除 + 后置复读) |
| 06-4 | 清 NVRAM 与可选扩容 | 新 `windows/cleanup-nvram.ps1`、新 `windows/extend-data-partition.ps1` |
| 06-5 | 只停用不删 | 新 `windows/disable-linux-entry.ps1` |
| 07-1 | 判层 | 新 `linux/triage.sh`(只读采集:分区/挂载/`efibootmgr`/ESP 内容/固件) |
| 07-2 | 从 grub 提示符回去 | 新 `linux/gen-grub-rescue-commands.sh`(按当前磁盘参数生成可复制的 `search`/`chainloader` 与 `prefix/insmod normal` 两套命令;grub 内的输入本身人工) |
| 07-3 | Windows 侧修引导 | 新 `windows/repair-windows-boot.ps1`(`mountvol` + `bcdboot` + 后置校验) |
| 07-4 | 只重装 Windows | [有] `windows/verify-windows-baseline.ps1`(安装人工) |
| 07-5 | 只重装 Fedora | [有] `linux/check-partition-plan.sh`(安装人工;含"ESP 绝不格式化"断言) |
| 07-6 | 基线回滚 | 新 `windows/restore-esp.ps1`(从 `baseline/02-esp-backup` 还原 + 逐文件校验) |
| 07-7 | 周期巡检 | [有] `windows/verify-baseline.ps1`(加 `--json`)+ 新 `linux/check-signature.sh`(nvidia 模块签名) |
| 07-8 | 应急纪律 | 人工(纪律条款;卡内标注"本条无脚本") |
| 08-A…F | 验收六组 | 新 `windows/verify-all.ps1`、新 `linux/verify-all.sh` + 两个 `collect-*` 复用 |

**合计**:新增 **35 个步骤脚本**(L0 3 / L1 6 / L2 2 / L3 3 / L4 9 / L5 5 / 07 5 / 08 2)+ **2 个库**(`linux/dbk-cli.sh`、`windows/dbk-cli.ps1`)+ **2 个步骤索引**(`linux/steps.tsv`、`windows/steps.tsv`)+ **2 个总控**(`dbk.sh`、`dbk.ps1`)= **41 个新文件**。
另需给既有脚本补 `--check/--json` 契约:**7 个**(`preflight.ps1`、`backup-esp.ps1`、`verify-baseline.ps1`、`set-bootnext.ps1`、`mount-shared.sh`、`xdg-redirect.sh`、`storage.sh`);`graphics.sh`(拆 + 改 Fedora)与 `hardening.sh`(拆 + 改 Fedora)、`dbk-apt.sh`→`dbk-pkg.sh` 的改写归 `02-fedora-variant-design.md` 的任务。

## 7. 夹具测试要求(每个脚本的最低验证)

1. **通过路径**:夹具让判据全部为真 → 退出码 0;
2. **失败路径**:至少一处判据为假 → 退出码 1,且输出指明是哪一项;
3. **dry-run 不改系统**:`--check` 运行后夹具目录的时间戳/内容零变化;
4. **破坏性脚本额外**:缺 `--yes` 时退出码 64 且**不产生任何写操作**;后置断言失败时退出码 1 并打印复读结果;
5. 夹具放在 `.superpowers/sdd/fedora-reshape/fixtures/<script>/`,用假的 `rpm`/`dnf`/`efibootmgr`/`lsblk`/`sgdisk`/`diskpart`/`bcdedit` 可执行文件注入 PATH。

## 8. 诚实说明:这次扩充的代价

| 项 | 代价 |
|---|---|
| 规模 | 新增 41 个脚本类文件(其中 35 个是步骤脚本);仓库脚本总数从 **16 个**(不含 `.gitkeep`)增到 **57 个**;实施任务从 21 个增到约 28 个 |
| 审查 | 每个脚本都要过"实现 + 审查 + 修复轮",工作量约翻倍 |
| **验证等级** | 这些脚本**全部无法在真机上验证**(无 Fedora/无第二台 Windows)→ 只有夹具级验证。文档与**脚本头**都必须标注"夹具级验证,真机未跑";`08-verification.md` 的参考设备首次真跑即是对全套脚本的首次真机验证 |
| 收益 | 每步可自动判定(减少"照着文档敲错"),危险步骤有前置断言与复读(比人手工点更安全),卡与脚本双向绑定(C9)防脱钩 |

明确接受的取舍:**用"约一倍的工作量"换"每步可自动判定 + 危险步骤有断言"**;不接受的是"为了脚本数量而写无法验证的自动化"——因此 S2 明确放弃 kickstart,人工步骤(固件开关、Anaconda、Windows 安装、激活动作)一律不做假自动化。

## 9. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-18 | 初版:确立 S1 双模式型 / S2 L3 人工 + 前置后置脚本 / S3 危险三步的三条硬规则;统一 CLI 与退出码;卡↔脚本双向绑定(C9);总控入口与步骤索引;43 卡映射表(新增 35 个步骤脚本、共 41 个新文件);夹具测试五条;代价与验证等级说明 |
