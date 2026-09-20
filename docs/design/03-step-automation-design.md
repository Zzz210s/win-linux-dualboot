# 设计:每一步一个脚本(步骤自动化)

日期:2026-09-18
状态:待实施(实施前需用户复审)
适用:本仓库全部动作卡与 `scripts/`
相关设计:`01-playbook-reshape-design.md`(卡格式与文档结构)、`02-fedora-atomic-variant-design.md`(Fedora 44 Silverblue 原子版:部署级回滚、ublue NVIDIA 路径、独立 ESP 与 `/boot`)。本设计为第三层:**把"卡"与"脚本"一一绑定**。

---

## 1. 背景与目标

现状:**43 张动作卡**(底座 4 / 轨道 W 10 / 轨道 L 4 / 首启收敛 12 / 退役与救援 13;卡号按 `01-playbook-reshape-design.md` 第 4 节的三轨道结构)对应 **18 个脚本**,其中真正覆盖动作的约 10 个,缺的恰是最危险的 L5(删分区、清 NVRAM)与 07(救援)。

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
| `--json` | 机器可读输出(供总控与验收汇总消费);字段:`step`、`status`、`message`(结论与失败原因的文本)、`checks[]`、`actions[]`、`changed` |
| `--log <path>` | 日志路径;**不给就不落盘**——库层不主动建 `/var/log/dbk/`,也不向默认路径写任何东西。需要缺省日志的步骤脚本在 source 库之后显式调 `dbk_log_default <脚本名>`(Linux,得 `/var/log/dbk/<脚本名>.log`)或 `Set-DbkLogDefault -Name <脚本名>`(Windows,得 `%LOCALAPPDATA%\dbk\logs\<脚本名>.log`);落这份日志是**步骤脚本**的决定,不是库的决定 |
| `--step <NN-K>` | 显式声明本脚本服务的卡号;**集合成员判断**:必须落在脚本头 `# 对应卡:` 声明的卡号集合里(支持一脚本服务多张卡的逗号列表),否则报用法错误退出 |

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
2. 脚本头必须有一行 `# 对应卡:NN-K`(或 `# Card: NN-K`),与卡一一对应;一脚本服务多张卡时写逗号列表(`# 对应卡:02-9,07-10`);
3. 库文件(不被卡直接调用的)写 `# 库文件:非步骤脚本`,并进入 C9 白名单;
4. 脚本默认 dry-run 的语义**不允许反转**(任何脚本都不许"默认就执行");
5. 未在真机验证过的命令,脚本内注释标 `# 待核实(以官方文档为准)`,并在 `--check` 输出里以 `需人工` 呈现;
6. 脚本一律不得使用 `efibootmgr -o`、不得写 `\EFI\Microsoft\`、不得改 `{bootmgr}` 的 `path`(违反即视为缺陷);
7. 库层不设 shell 选项:`dbk-cli.sh` 不再替调用方打开 `errexit`——失败必须中断的步骤脚本自己 `set -euo pipefail`,逐项汇总型的脚本(`hardening.sh`、`first-boot.sh`:单模块失败不中断、整体仍返回 0)不得 `set -e`;
8. 破坏性脚本必须在脚本头声明 `# 破坏性:1`:`--apply` / `-Apply` 缺 `--yes` / `-Yes` 时由**库层**直接退 64(不指望作者记得调 `dbk_need_yes` / `Assert-DbkYes`);条件性破坏动作(静态声明不适用)仍在动作前调后者;
9. 失败必须可表现(见 2.1):不得只给退出码、不得吞 stderr。

### 2.1 可观测性:失败必须可表现(硬要求)

脚本的价值一半在"判定",一半在"出了事能看见"。以下五条与 CLI 契约同级:

| # | 要求 | 实现位置 |
|---|---|---|
| O1 | **失败不得只给退出码**:`FAIL`/`需人工` 必须给非空说明(空说明 → 用法错误 64);库把说明同时写进 JSON 的 `message` 与 `checks[]`(作者没登记判据时自动补一条 `失败项: …`) | `dbk_report` / `Write-DbkReport` |
| O2 | **三处可见**:任何失败都要能在 stderr、`--log` 日志文件、`--json` 的 `checks[]` 里同时看到 | `dbk_obs` / `Write-DbkObs` |
| O3 | **ERR trap(opt-in)**:用 `set -e` 的步骤脚本在 source 库后调 `dbk_enable_errtrap`;命令失败时 `dbk_on_err` 立即写 stderr + 日志,并在 `checks[]` 追加 `{"id":"errtrap","ok":false,"detail":"line 42 rc=1: <命令>"}`,再输出一行报告(JSON 模式输出完整 JSON 行)。**"失败不中断"的脚本(`hardening.sh`、`first-boot.sh`)不得启用**——那会把逐项失败升级成中断 | `dbk_enable_errtrap`/`dbk_on_err`;PS 侧 `Enable-DbkErrTrap`/`Write-DbkErrTrap` |
| O4 | **不吞 stderr**:库层禁止 `2>/dev/null` 式吞错(日志目录/文件写不进去时必须把失败打到 stderr) | `dbk-log.sh` 的 `log()`、`dbk-obs.sh` 的 `dbk_log_write` |
| O5 | **PowerShell 侧等价物**:PS 没有 ERR trap,库不装 trap(免得改变"失败不中断"脚本的默认语义);用 try/catch 的脚本在 catch 里调 `Write-DbkErrTrap -Reason …`。PS 5.1 的 stdout 编码在库加载时固定为 UTF-8 无 BOM,保证 `-Json` 过管道不乱码 | `dbk-obs.ps1` |

脚本头声明(库与仓库自检 C9b/C9d 用**同一个读法**):

| 声明 | 写法 | 谁消费 |
|---|---|---|
| 对应卡(必需) | `# 对应卡:NN-K[,NN-K…]`(也认 `# Card:`) | `dbk_assert_step` / `Assert-DbkStep`;C9b/C9d |
| 破坏性(可选) | `# 破坏性:1` | `dbk_parse_args` / `Parse-DbkArgs` 的门槛(见硬规则 8) |

读法细节:行首允许 UTF-8 BOM(`.sh` 允许、`.ps1` 必须带);BOM 不算「#」行,所以 `.ps1` 里 `# 对应卡:` 要写在 `#Requires` 之类文件头指令之后。`dbk_assert_step` 靠 `BASH_SOURCE[1]` 定位调用方,必须由步骤脚本**顶层直接调用**。

errtrap 的退出码与误用防护(与 O3 同级,修复轮 2 补齐):

1. **退出码不得泄漏**:errtrap 触发后,`dbk_on_err` 报完即由 trap 以 `DBK_FAIL`(1)结束进程,不得沿用失败命令自身的状态(否则 `(exit 3)` 会退 3、不存在的命令会退 127,违反全仓 0/1/2/9/64 契约);JSON 因此只输出一次,`status:"fail"` 与进程码一致。
2. **误用防护两层**:`dbk_enable_errtrap` 校验当前 shell 已开 `errexit`(`$-` 含 `e`),未开则打印用法错误并退 64(不装 trap);第二道防线在 `dbk_report`,一旦 `checks[]` 里已有 errtrap 失败条目就拒绝再报 PASS(退 64),避免出现 `status:"pass"` 与 `checks[].ok:false` 并存的自相矛盾输出。
3. **PS 侧两条已知差异**(不强行改 PowerShell 参数绑定行为,由总控在调用前自行校验):`-Log`/`-Step` 缺值会被 PS 参数绑定先拦下,实测退 1(不是 bash 侧的用法错误 64);`-Log ''`/`-Step ''` 被 `dbk-cli.ps1` 归一成"未给"并静默接受。

文本行尾约定:仓库根 `.gitattributes` 固定 `*.sh`/`*.tsv`/`*.md` 为 LF、`*.ps1` 为 CRLF(与 BOM 约定配套),避免本机 `core.autocrlf=true` 把 `steps.tsv` 转成 CRLF 后 C9d 的破坏性列比较(只认 `0`/`1`)误判。

## 3. 卡与脚本的绑定

| 项 | 约定 |
|---|---|
| 卡内引用 | "做:"行给出可复制的调用,如 `scripts/linux/mount-shared.sh --check`;末尾 `脚本:` 行给出路径与对应的 `--check`/`--apply` 组合 |
| 脚本命名 | **语义名**(如 `disable-faststartup.ps1`、`dbk-rollback.sh`),不用 `step-NN-K` 编号名 —— 文件名可读性更重要,绑定关系靠脚本头的 `# 对应卡:` 与卡内的 `脚本:` 行双向记录 |
| 无脚本的卡 | 卡内写 `脚本:无(人工)` 或 `脚本:无(纪律条款)`,并说明为什么不能自动化 |
| 双向校验 | 新增自检规则 **C9**(见第 4 节) |

## 4. 自检规则新增 C9(卡 ↔ 脚本双向绑定)

在 `01-playbook-reshape-design.md` 第 6 节的 C1–C8 之后追加:

| 规则 | 内容 |
|---|---|
| C9a | 卡内出现的 `scripts/**/*.{sh,ps1}` 路径**必须存在**(正斜杠与反斜杠写法都认,如 `scripts\windows\x.ps1`) |
| C9b | 每个 `scripts/repo/*.sh`、`scripts/linux/*.sh` 与 `scripts/windows/*.ps1` **必须**含 `# 对应卡:` 行(或 `# Card:`),且该卡号在对应文档中真实存在;正则允许行首 UTF-8 BOM(`.ps1` 必须带 BOM),并支持逗号列表写法(一脚本服务多张卡,列表里至少一个卡号真实存在)(白名单:库文件与仓库自检脚本) |
| C9c | **反向覆盖**:每个步骤脚本必须被至少一张卡引用(`grep` 卡内路径,正斜杠与反斜杠写法都认) |
| C9d | 白名单(库/自检脚本:不要求 `# 对应卡:`、不要求被卡引用):`scripts/linux/dbk-log.sh`、`scripts/linux/dbk-cli.sh`、`scripts/linux/dbk-obs.sh`(可观测性库:报告/JSON/日志/errtrap)、`scripts/linux/dbk-pkg.sh`(**改名注**:该文件在脚本任务中改名为 `dbk-ostree.sh`;改名时必须同改本白名单与仓库自检库 `check-docs-lib.sh` 的 `WL` 两处,否则夹具 F7 立即变红)、`scripts/linux/dbk.sh`、`scripts/linux/dbk-apt.sh`(legacy 库,将在任务 14 并入 `dbk-pkg.sh`)、`scripts/repo/check-docs.sh`、`scripts/repo/check-docs-lib.sh`(check-docs 公共解析库)、`scripts/repo/check-docs-repo.sh`(仓库级 C9b/c/d 检查)、`scripts/repo/check-scripts.sh`、`scripts/windows/dbk-cli.ps1`、`scripts/windows/dbk-obs.ps1`(可观测性库:报告/JSON/日志/UTF-8 输出)、`scripts/windows/dbk.ps1`。白名单以自检脚本内的 WL 为唯一实现,两处必须逐行一致(夹具额外校验 `extra-checks-c9.sh` 有断言);C9d 另校验 `scripts/{linux,windows}/steps.tsv` 与步骤脚本一一对应(索引行指向的脚本必须存在且是本侧步骤脚本,本侧步骤脚本必须登记进索引,缺索引时报「缺少步骤索引」;破坏性列必须 ∈ {0,1};索引步骤号必须落在脚本头卡号集合里(支持列表头),脚本还没有卡头时由 C9b 报、不重复报;同一索引内步骤号不得重复) |

**夹具套件(已版本化入库)**:check-docs 自身的夹具(常驻样例、边界回归、样例仓库模板)位于 `scripts/repo/tests/check-docs/`,验证命令:`bash scripts/repo/tests/check-docs/run-fixtures.sh`(末行 `PASS=n FAIL=m`,可从仓库任意工作目录运行;运行时副本建在 `scripts/repo/tests/check-docs/.tmp/`,不入库)。夹具是测试数据:路径中含 `/tests/` 的文件**不参与 C9b/C9c/C9d 扫描**(夹具里的假 `*.sh`/`*.ps1` 不应被要求 `# 对应卡:`),也不参与 `scripts/repo/check-scripts.sh` 的语法与行数扫描。

C9 的价值:文档与脚本从此不会脱钩——改脚本名而忘改文档、或写了脚本却没人调用,自检当场报错。

## 5. 新增总控入口

| 入口 | 作用 | 约束 |
|---|---|---|
| `scripts/windows/dbk.ps1 <step> [-Apply] [-Yes] [-Json]` | Windows 侧步骤分发(读步骤索引 → 调对应脚本 → 汇总输出) | 只做分发与汇总,**不含任何业务逻辑**;拒绝未知步骤名 |
| `scripts/linux/dbk.sh <step> [--apply] [--yes] [--json]` | Fedora 侧同上 | 同上 |
| `scripts/windows/verify-all.ps1` / `scripts/linux/verify-all.sh` | 按 `08-verification.md` 的 A–F 逐项自动判定,汇总写 `baseline/08-verification.md`(每台设备副本) | 只做判定与汇总;不得自动执行 `--apply` |

步骤索引文件:`scripts/windows/steps.tsv`、`scripts/linux/steps.tsv`(列:步骤号、脚本路径、是否破坏性、说明)。总控读它分发,C9d 也校验它的一致性:脚本路径必须存在且属本侧、本侧步骤脚本必须登记进索引、破坏性列 ∈ {0,1}、索引步骤号必须落在脚本头卡号集合里、同一索引内步骤号不得重复(一脚本服务多张卡时按步骤号各占一行,同一脚本路径允许出现多行)。**索引行不是装饰**:它既是总控的分发表,也是“这一步会不会改系统”的第二道记录。

## 6. 逐卡脚本映射表(43 张动作卡 → 脚本)

**图例**:`[有]` 已存在(可能需加 `--check/--json` 契约);`新` = 本次新增;`人工` = 无法自动化(卡内标注)。卡号取 `01-playbook-reshape-design.md` 第 4 节的三轨道结构(底座 = 01 / 轨道 W = 02 / 轨道 L = 04 / 首启收敛 = 05 / 退役与救援 = 07)。

| 卡 | 动作 | 脚本 |
|---|---|---|
| 01-1 | 改固件设置 | 新 `windows/check-firmware.ps1`(--check 读 Secure Boot/VMD 推断;BIOS 内的开关本身只能人工) |
| 01-2 | 做两个安装介质 | 新 `windows/verify-install-media.ps1`(校验 ISO 存在与哈希、列出可移动盘;写入由 Ventoy 人工) |
| 01-3 | 核对目标盘 | [有] `windows/preflight.ps1 -Only target-disk`(需新增 `-Only`) |
| 01-4 | 落 L0 产物 | 新 `windows/collect-l0.ps1` |
| 02-1 | diskpart 预建分区(含 115GiB 预留) | 新 `windows/create-partitions.ps1`(--apply 生成并执行 diskpart 脚本;前置断言:磁盘当前无有效分区表) |
| 02-2 | 装 Windows | 新 `windows/verify-windows-baseline.ps1`(安装为人工;脚本核对版本/分区/WinRE 偏差) |
| 02-3 | 关 Fast Startup 与休眠 | 新 `windows/disable-faststartup.ps1` |
| 02-4 | 已知文件夹重定向 | 新 `windows/redirect-known-folders.ps1`(--check 读 `User Shell Folders` 比对) |
| 02-5 | KMS 激活 | 新 `windows/check-activation.ps1`(激活动作人工、外链;脚本只读状态) |
| 02-6 | 落 L1 产物 | 新 `windows/collect-l1.ps1` |
| 02-7 | 跑只读体检 | [有] `windows/preflight.ps1` |
| 02-8 | 读闸门结论 | 新 `windows/check-gate.ps1`(解析报告 → PASS/FAIL 并列红项) |
| 02-9 | 跑基线备份 | [有] `windows/backup-esp.ps1`(加 `--check`:校验已有备份的 `manifest.sha256`) |
| 02-10 | 落 L2 产物 | 新 `windows/collect-l2.ps1` |
| 04-1 | UEFI 启动进 live | [有] `windows/set-bootnext.ps1`(扩展 `-Device USB`:设置一次性从 U 盘启动) |
| 04-2 | 手动分区(Anaconda) | 新 `linux/check-partition-plan.sh`(在 live 里跑:读 `lsblk`/`blkid`/`sgdisk -p` 比对计划,输出"下一步该建什么";分区动作人工;含"不让安装器动 Windows ESP"的前置提示) |
| 04-3 | 装完重启验证 | 新 `linux/verify-l3.sh`(btrfs 与 ostree 部署、两块 ESP 各自内容、GRUB 部署条目、`BootOrder` 首位) |
| 04-4 | 落 L3 产物 | 新 `linux/collect-l3.sh` |
| 05-1 | 共享盘挂载 | [有] `linux/mount-shared.sh` |
| 05-2 | 家目录重定向 | [有] `linux/xdg-redirect.sh` |
| 05-3 | 显卡驱动与 MOK | 改写 `linux/graphics.sh`(rebase 到 ublue NVIDIA 变体)+ 新 `linux/graphics-mok.sh`(`ujust enroll-secure-boot-key` 与签名复检) |
| 05-4 | 时间 | 新 `linux/set-time.sh` |
| 05-5 | 蓝牙 | [有] `linux/bt-keys-sync-wrapper.sh` |
| 05-6 | zram 与 swapfile | [有] `linux/storage.sh`(zram 由"安装"改"核对";分层安装走 `linux/dbk-ostree.sh`) |
| 05-7 | journald 与更新策略 | 新 `linux/set-journald.sh`、新 `linux/set-updates.sh`(`rpm-ostreed-automatic`:只 check/download,不自动应用与重启) |
| 05-8 | SSH 与 SMART | 新 `linux/set-remote-health.sh`(分层装 `smartmontools`;`sshd` 语义) |
| 05-9 | **部署回滚** | 新 `linux/dbk-rollback.sh`(列出部署 / pin / unpin / `rpm-ostree rollback` / 回滚后复检;被 07-7 的巡检复用) |
| 05-10 | 发行版升级 | 新 `linux/upgrade-release.sh`(`rpm-ostree rebase` 到新分支;**前置 pin** 当前部署) |
| 05-11 | 回 Windows 入口 | [有] `linux/reboot-to-windows.sh` |
| 05-12 | 落 L4 产物 | 新 `linux/collect-l4.sh` |
| 07-1 | 判层 | 新 `linux/triage.sh`(只读采集:分区/挂载/`efibootmgr`/两块 ESP 内容/固件) |
| 07-2 | 从 grub 提示符回去 | 新 `linux/gen-grub-rescue-commands.sh`(按当前磁盘参数生成可复制的 `search`/`chainloader` 与 `prefix/insmod normal` 两套命令;grub 内的输入本身人工) |
| 07-3 | Windows 侧修引导 | 新 `windows/repair-windows-boot.ps1`(`mountvol` + `bcdboot` + 后置校验) |
| 07-4 | 只重装 Windows | [有] `windows/verify-windows-baseline.ps1`(安装人工) |
| 07-5 | 只重装 Silverblue | [有] `linux/check-partition-plan.sh`(安装人工;含"ESP 与 `/boot` 绝不格式化、先备份 `/var/home`"断言) |
| 07-6 | 基线回滚 | 新 `windows/restore-esp.ps1`(从 `baseline/02-esp-backup` 还原 + 逐文件校验) |
| 07-7 | 周期巡检 | [有] `windows/verify-baseline.ps1`(加 `--json`)+ 新 `linux/check-signature.sh`(`nvidia` 模块签名)+ `linux/dbk-rollback.sh --check`(部署列表与固定状态) |
| 07-8 | 应急纪律 | 人工(纪律条款;卡内标注"本条无脚本") |
| 07-9 | 归位引导顺序 | 新 `windows/restore-boot-order.ps1`(前置断言;不改 `{bootmgr}` 路径) |
| 07-10 | 备份现状 | [有] `windows/backup-esp.ps1 -OutDir D:\dbk-l5-backup` |
| 07-11 | 删 Fedora 分区 | 新 `windows/delete-linux-partition.ps1`(**破坏性**:`--yes` + 前置断言 + 只按分区号/GUID 精确删除 + 后置复读) |
| 07-12 | 清 NVRAM 与可选扩容 | 新 `windows/cleanup-nvram.ps1`、新 `windows/extend-data-partition.ps1` |
| 07-13 | 只停用不删 | 新 `windows/disable-linux-entry.ps1` |
| 08-A…F | 验收六组 | 新 `windows/verify-all.ps1`、新 `linux/verify-all.sh` + 两个 `collect-*` 复用 |

**库文件与既有脚本的改写(不进卡映射表)**:

| 文件 | 处置 |
|---|---|
| `linux/dbk-pkg.sh`(原 `linux/dbk-apt.sh`) | 改写为 **`linux/dbk-ostree.sh`**:`pkg_installed` → `rpm-ostree status --json` 查询;**分层安装** `rpm-ostree install`(带"需重启"提示);保留 `DBK_SKIP_*` 与退出码语义。属库文件(C9d 白名单),被 05-6/05-7/05-8 等卡间接使用 |
| `linux/dbk-obs.sh` / `windows/dbk-obs.ps1` | **可观测性库**(本次修复轮新增):报告与 JSON(含 `message` 字段与 `checks[]` 里的失败项)、日志落盘、失败三处可见与 errtrap(见第 2.1 节)。属库文件(C9d 白名单),分别被同侧的 `dbk-cli.sh` / `dbk-cli.ps1` source |
| `linux/hardening.sh` | 逐项改原子版语义(分层装 `smartmontools`、`sshd` 用 `systemctl enable --now`、更新策略改 `rpm-ostreed-automatic`);`--check/--apply` 结构不变 |
| `linux/graphics.sh` | 由 `akmods + MOK` 改为 **rebase 到 ublue NVIDIA 变体 + `ujust enroll-secure-boot-key`**;判据改为 `mokutil --list-enrolled` + `modinfo -F signer nvidia`(与卡 05-3 绑定) |
| `linux/first-boot.sh` | 逐模块调用改原子版语义(`dbk-ostree.sh` / `rpm-ostreed-automatic` / 部署回滚);摘要与退出码语义不变 |
| **删除** `linux/snapshot.sh`、`linux/set-snapshots.sh` | 不再存在(快照体系已作废,回滚由卡 05-9 的 `dbk-rollback.sh` 承担) |
| 四个 PowerShell 脚本(`preflight` / `backup-esp` / `verify-baseline` / `set-bootnext`) | **不受原子版语义影响**,只需按上表补 `--check/--json`/`-Only`/`-Device` 契约 |

**合计**:新增 **34 个步骤脚本**(底座 3 / 轨道 W 8 / 轨道 L 3 / 首启收敛 8 / 退役与救援 10 / 验收 2)+ **4 个库**(两侧各二:`linux/dbk-cli.sh`+`linux/dbk-obs.sh`、`windows/dbk-cli.ps1`+`windows/dbk-obs.ps1`)+ **2 个步骤索引**(`linux/steps.tsv`、`windows/steps.tsv`)+ **2 个总控**(`dbk.sh`、`dbk.ps1`)= **42 个新文件**(比上一版少 1 个步骤脚本:卡 05-9 由两个脚本缩为一个,`snapshot.sh`/`set-snapshots.sh` 删除;另加两侧可观测性库 2 个,见第 2.1 节)。
另需给既有脚本补 `--check/--json` 契约:**7 个**(`preflight.ps1`、`backup-esp.ps1`、`verify-baseline.ps1`、`set-bootnext.ps1`、`mount-shared.sh`、`xdg-redirect.sh`、`storage.sh`);`graphics.sh`(拆 + 改 rebase/MOK)与 `hardening.sh`(拆 + 改 rpm-ostree 语义)、`dbk-apt.sh`→`dbk-pkg.sh`→**`dbk-ostree.sh`** 的改写归 `02-fedora-atomic-variant-design.md` 第 8 节的任务(四个 PowerShell 脚本不受影响)。

## 7. 夹具测试要求(每个脚本的最低验证)

1. **通过路径**:夹具让判据全部为真 → 退出码 0;
2. **失败路径**:至少一处判据为假 → 退出码 1,且输出指明是哪一项;
3. **dry-run 不改系统**:`--check` 运行后夹具目录的时间戳/内容零变化;
4. **破坏性脚本额外**:缺 `--yes` 时退出码 64 且**不产生任何写操作**;后置断言失败时退出码 1 并打印复读结果;
5. 夹具放在 `.superpowers/sdd/fedora-reshape/fixtures/<script>/`,用假的 `rpm`/`dnf`/`efibootmgr`/`lsblk`/`sgdisk`/`diskpart`/`bcdedit` 可执行文件注入 PATH(本条指步骤脚本夹具;check-docs 自检脚本自身的夹具是例外,已入库到 `scripts/repo/tests/check-docs/`,见第 4 节)。
6. **失败必须可表现**(第 2.1 节,每条至少要有一个夹具):① 调了 `dbk_enable_errtrap` 的 `set -e` 脚本在命令失败时,stderr、`--log` 日志、`--json` 的 `checks[]` 三处都能看到 errtrap 条目与失败命令行;② 没调 errtrap 的脚本失败时,stderr 与 JSON 仍能看到失败项与原因(不允许只返回退出码);③ `--json` 模式下失败信息不丢失(`message` 有原因、`checks[]` 有失败项);④ 取值缺失/空值(`--log`、`--log ""`、`--step`)一律退 64 且零写。

## 8. 诚实说明:这次扩充的代价

| 项 | 代价 |
|---|---|
| 规模 | 新增 **42 个脚本类文件**(其中 34 个是步骤脚本、4 个契约库);仓库脚本总数(不含 `.gitkeep` 与测试夹具)从 **16 个**增到 **58 个**;实施任务从 21 个增到约 28 个 |
| 审查 | 每个脚本都要过"实现 + 审查 + 修复轮",工作量约翻倍 |
| **验证等级** | 这些脚本**全部无法在真机上验证**(无 Fedora/无第二台 Windows)→ 只有夹具级验证。文档与**脚本头**都必须标注"夹具级验证,真机未跑";`08-verification.md` 的参考设备首次真跑即是对全套脚本的首次真机验证 |
| 收益 | 每步可自动判定(减少"照着文档敲错"),危险步骤有前置断言与复读(比人手工点更安全),卡与脚本双向绑定(C9)防脱钩 |

明确接受的取舍:**用"约一倍的工作量"换"每步可自动判定 + 危险步骤有断言"**;不接受的是"为了脚本数量而写无法验证的自动化"——因此 S2 明确放弃 kickstart,人工步骤(固件开关、Anaconda、Windows 安装、激活动作)一律不做假自动化。

## 9. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-18 | 初版:确立 S1 双模式型 / S2 L3 人工 + 前置后置脚本 / S3 危险三步的三条硬规则;统一 CLI 与退出码;卡↔脚本双向绑定(C9);总控入口与步骤索引;43 卡映射表(新增 35 个步骤脚本、共 41 个新文件);夹具测试五条;代价与验证等级说明 |
| 2026-09-18 | 修复轮 2:check-docs 夹具套件入库到 `scripts/repo/tests/check-docs/`(版本化,换机器可复跑);路径含 `/tests/` 的文件豁免 C9b/C9c/C9d 与 check-scripts 扫描 |
| 2026-09-19 | 与 `02-fedora-atomic-variant-design.md` 对齐:第 6 节映射表按原子版改写——卡号同步三轨道结构(原 03 的 4 张卡并入 02,编号 02-7…02-10;原 06 的 5 张卡并入 07,编号 07-9…07-13);卡 05-9 由"快照与回滚"改为"**部署回滚**"(删除 `snapshot.sh`/`set-snapshots.sh`,新增 `dbk-rollback.sh`);新增库文件 `dbk-ostree.sh`(取代 `dbk-pkg.sh`:分层安装 + `rpm-ostree status --json`);`graphics.sh`/`graphics-mok.sh` 改 rebase + MOK、`set-updates.sh` 改 `rpm-ostreed-automatic`、`upgrade-release.sh` 改 `rpm-ostree rebase`、`set-remote-health.sh`/`storage.sh` 改 rpm-ostree 语义;四个 PowerShell 脚本不受影响;第 8 节代价表按新表重算(34 个步骤脚本 / 40 个新文件 / 总数 56);第 2–5 节 CLI 契约与第 7 节夹具要求不动 |
| 2026-09-20 | 修复轮 1(任务 1 审查修正 + 用户新增硬要求 O-1):第 2 节新增 **2.1 可观测性**——失败不得只给退出码、三处可见(stderr / `--log` / JSON `checks[]`)、opt-in 的 `dbk_enable_errtrap`、库层不吞 stderr、PS 侧 UTF-8 输出;新增两侧可观测性库 `scripts/linux/dbk-obs.sh` 与 `scripts/windows/dbk-obs.ps1`(第 4 节 C9d 白名单与 `check-docs-lib.sh` 的 WL 两处同步);CLI 取值错误(`--log`/`--step` 缺值或空值)改为用法错误 64 且不落盘(不再经 `die()`);破坏性脚本必须在脚本头声明 `# 破坏性:1`,由库层在执行前拦 `--apply` 缺 `--yes`;卡头支持逗号列表(一脚本服务多张卡)与行首 BOM,C9b/C9d 同步升级并新增破坏性列、步骤号一致性、重复步骤号三项交叉校验;`--json` 增加 `message` 字段并在判据为空时补一条失败项;库不再替调用方打开 `errexit`;`--log` 缺省口径明确为“库不落盘、需要时由步骤脚本调 `dbk_log_default`/`Set-DbkLogDefault`”;第 6 节增库文件行与重算合计(42 个新文件 / 总数 58);第 7 节夹具新增第 6 条“失败必须可表现”;夹具套件新增 4 个样例仓库(带 BOM 的 `.ps1` 卡头、多卡列表头、破坏性列非法、步骤号重复) |
| 2026-09-20 | 修复轮 2(任务 1 收尾):errtrap 触发后进程必须以 1 退出(trap 报完即 `exit "$DBK_FAIL"`,不再泄漏失败命令自身状态;JSON 只输出一次);`dbk_enable_errtrap` 新增 `errexit` 断言(未开 `set -e` 误用 → 64),`dbk_report` 新增第二道防线(已有 errtrap 条目时拒绝 PASS → 64);PS 侧 `Get-DbkHeaderField` 改 `-CaseSensitive`,与 C9b 的 `CARDRE` 对齐;第 2.1 节补 errtrap 退出码/误用防护/PS 两条已知差异(`-Log`/`-Step` 缺值被 PS 参数绑定拦下退 1、空串被归一成“未给”)与 `.gitattributes` 行尾约定;`check-docs-repo.sh` 的重复步骤号改报真实行号;两侧夹具新增 6 条断言(errtrap 退出码 2、未开 `set -e` 误用 1、errtrap 后报 PASS 1、PS errtrap/opt-in 各 1) |
