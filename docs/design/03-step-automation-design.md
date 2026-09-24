# 设计:每一步一个脚本(步骤自动化)

日期:2026-09-18
状态:待实施(实施前需用户复审)
适用:本仓库全部动作卡与 `scripts/`
相关设计:`01-playbook-reshape-design.md`(卡格式与文档结构)、`04-kubuntu-variant-design.md`(Kubuntu 26.04 LTS:包级回退、Ubuntu 官方预签名驱动、独立 ESP 与 `/boot`;它取代原原子版设计,历史叙述仍留在 `02-fedora-atomic-variant-design.md`)。本设计为第三层:**把"卡"与"脚本"一一绑定**。

---

## 1. 背景与目标

现状:**48 张动作卡**(底座 4 / 分盘 4 / 轨道 W 9 / 轨道 L 4 / 首启收敛 14 / 退役与救援 13;卡号按 `01-playbook-reshape-design.md` 第 4 节的"三轨道 + 分盘前置章节"结构)对应 **18 个脚本**,其中真正覆盖动作的约 10 个,缺的恰是最危险的 L5(删分区、清 NVRAM)与 07(救援)。

目标:**每个动作卡都有一个脚本**,卡里的"做:"就是"跑哪个脚本、看什么判据";人工只保留两类无法自动化的动作(固件设置界面的开关、Calamares 里的点击)。

已定的三项(用户逐条确认):

| # | 决定 |
|---|---|
| S1 | **双模式型**:每步一个脚本,**默认 `--check`**(只读,自动判定该卡的 `看到:` 判据,输出 `PASS`/`FAIL`/`需人工`)、**`--apply`** 才执行(幂等 + 前置断言 + 破坏性动作显式 `--yes`)。**不做阶段级一键连跑编排**(被否理由:无法在真机上做到彻底,且放大连跑改分区表的风险) |
| S2 | **L3 的 Kubuntu 安装保持人工**(Calamares 交互);用"L3 前置核对脚本(`check-partition-plan.sh`)+ L3 后置校验脚本(`verify-l3.sh`)"把这步包住。无人值守安装(autoinstall)不作为 v1 路径(被否理由:出错时无人拦,分区写错即毁 Windows) |
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
| `--step <NN-K>` | 显式声明本脚本服务的卡号;**集合成员判断**:必须落在脚本头 `# 对应卡:` 声明的卡号集合里(支持一脚本服务多张卡的逗号列表),否则报用法错误退出。**执行器例外**:两侧 `verify-all.*` 不绑卡(没有 `# 对应卡:` 头),它们的 `--step`/`-Step` 语义见第 5 节 |

**退出码语义(全仓统一,PowerShell 与 Bash 一致)**

| 码 | 含义 |
|---|---|
| 0 | `PASS`(该步已达成 / `--apply` 执行成功且后置断言通过) |
| 1 | `FAIL`(判据未达成、或执行失败) |
| 2 | `需人工`(脚本无法判定的项,必须人看;不视为失败) |
| 9 | 跳过(显式 `DBK_SKIP_*` 或环境不适用,如非 Linux 上跑 Linux 脚本) |
| 64 | 用法错误(参数缺失、`--yes` 未给、`--step` 冲突) |

**缺省只读 + `-Yes` 门槛(2026-09-24 补全,与实现逐字一致)**

- `-Check`/`--check` 是**缺省**且零写:不给 `-Check` 也不给 `-Apply` 时脚本只做只读判定——**任何脚本都不许“默认就执行”**(硬规则 4);`-Apply`/`--apply` 才执行。
- 凡会改动系统状态的写动作都必须 `-Apply -Yes`/`--apply --yes`:`-Yes` 门槛不只覆盖删分区 / 清 NVRAM / 写 fstab / 重建 `\EFI\Microsoft\`,也覆盖**一次性引导切换**(`bcdedit /set {fwbootmgr} bootsequence <GUID>`、`efibootmgr -n <num>`)——它们改的是固件启动项,静默执行会把下次重启引到错误条目。
- 缺 `-Yes` 时按 **64** 退出且**零写**(一个命令都不调);声明了 `# 破坏性:1` 的脚本由库层在解析参数时拦下(不指望作者记得调 `Assert-DbkYes`/`dbk_need_yes`),条件性破坏动作仍在动作前调后者。
- `-WhatIf` 只在 `scripts/windows/set-bootnext.ps1` 保留(兼容手册与 FAQ 的既有写法),语义**等价于 `-Check`**(只打印将执行的命令,零写),与 `-Apply` 同时给按用法错误 64 处理。

**硬规则**

1. 每个脚本 ≤200 行;超出则拆文件(拆出的公共逻辑放库文件,不计入卡)。
2. 脚本头必须有一行 `# 对应卡:NN-K`(或 `# Card: NN-K`),与卡一一对应;一脚本服务多张卡时写逗号列表(`# 对应卡:03-9,07-10`);
3. 库文件(不被卡直接调用的)写 `# 库文件:非步骤脚本`,并进入 C9 白名单;
4. 脚本默认 dry-run 的语义**不允许反转**(任何脚本都不许"默认就执行");
5. 未在真机验证过的命令,脚本内注释标 `# 待核实(以官方文档为准)`,并在 `--check` 输出里以 `需人工` 呈现;
6. 脚本一律不得使用 `efibootmgr -o`、不得写 `\EFI\Microsoft\`、不得改 `{bootmgr}` 的 `path`(违反即视为缺陷);
7. 库层不设 shell 选项:`dbk-cli.sh` 不再替调用方打开 `errexit`——失败必须中断的步骤脚本自己 `set -euo pipefail`,逐项汇总型的脚本(`hardening.sh`、`first-boot.sh`:单模块失败不中断、整体仍返回 0)不得 `set -e`;
8. 破坏性脚本必须在脚本头声明 `# 破坏性:1`:`--apply` / `-Apply` 缺 `--yes` / `-Yes` 时由**库层**直接退 64(不指望作者记得调 `dbk_need_yes` / `Assert-DbkYes`);条件性破坏动作(静态声明不适用)仍在动作前调后者;
9. 失败必须可表现(见 2.1):不得只给退出码、不得吞 stderr。

### 2.1 可观测性:失败必须可表现(工程约定)

> 归因说明:本节最初因一条**后来被用户撤回的指令**(2026-09-20 声明该指令为错误输入)而写入。经裁定**保留为工程约定**——它对后续 24 个任务确实有价值,且与任何设计决策都不冲突;**但它不是用户需求**,任何文档与报告不得引用为"用户要求"。

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

**`-Json` 边界(2026-09-22 终审后澄清)**:契约 JSON(`step` / `status` / `checks[]`)只适用于**步骤脚本**与两个验收执行器(`verify-all.sh` / `verify-all.ps1`);**只读探测器类脚本**(如 `scripts/windows/preflight.ps1`、`scripts/windows/dbk-win-probe.ps1`)的 `-Json` 是它们各自的查询 schema,总控**不消费**其 JSON —— 只取退出码与文本输出。因此 `dbk.ps1 <步骤> -Json` 对探测器类步骤给出的是总控合成的记录,而不是探测器原生 JSON;这是有意约束,不是缺陷。

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
| C9d | 白名单(库/自检脚本:不要求 `# 对应卡:`、不要求被卡引用):`scripts/linux/dbk-log.sh`、`scripts/linux/dbk-cli.sh`、`scripts/linux/dbk-obs.sh`(可观测性库:报告/JSON/日志/errtrap)、`scripts/linux/dbk-pkg.sh`(**改名注**:Kubuntu 切换后由 apt/dpkg 语义的包助手承担原原子版 `dbk-ostree.sh` 的角色 —— `pkg_installed` 走 `dpkg-query -W`,`pkg_install` 走 `apt-get install -y`;旧名文件 `dbk-apt.sh` 与 `dbk-ostree.sh` 均已删除;本白名单与仓库自检库 `check-docs-lib.sh` 的 `WL` 两处必须逐行一致,否则夹具 F7 立即变红)、`scripts/linux/dbk.sh`、`scripts/repo/check-docs.sh`、`scripts/repo/check-docs-lib.sh`(check-docs 公共解析库)、`scripts/repo/check-docs-repo.sh`(仓库级 C9b/c/d 检查)、`scripts/repo/check-scripts.sh`、`scripts/windows/dbk-cli.ps1`、`scripts/windows/dbk-obs.ps1`(可观测性库:报告/JSON/日志/UTF-8 输出)、`scripts/windows/dbk-win-probe.ps1`(轨道 W 只读探测库:分区布局/模板目标值/版本)、`scripts/windows/dbk.ps1`、`scripts/linux/verify-all.sh` 与 `scripts/windows/verify-all.ps1`(验收总控/执行器:按 `08` 的 A-F 只读判定并汇总,自身不绑定任何卡、不登记步骤索引,故与库文件同列)。白名单以自检脚本内的 WL 为唯一实现,两处必须逐行一致(夹具额外校验 `extra-checks-c9.sh` 有断言);C9d 另校验 `scripts/{linux,windows}/steps.tsv` 与步骤脚本一一对应(索引行指向的脚本必须存在且是本侧步骤脚本,本侧步骤脚本必须登记进索引,缺索引时报「缺少步骤索引」;破坏性列必须 ∈ {0,1};索引步骤号必须落在脚本头卡号集合里(支持列表头),脚本还没有卡头时由 C9b 报、不重复报;同一 (步骤号, 脚本路径) 对不得重复——一张卡可以对应多个脚本,同一步骤号允许多行,只有「同一步骤号 + 同一脚本」才算索引笔误) |

**夹具套件(已版本化入库)**:check-docs 自身的夹具(常驻样例、边界回归、样例仓库模板)位于 `scripts/repo/tests/check-docs/`,验证命令:`bash scripts/repo/tests/check-docs/run-fixtures.sh`(末行 `PASS=n FAIL=m`,可从仓库任意工作目录运行;运行时副本建在 `scripts/repo/tests/check-docs/.tmp/`,不入库)。夹具是测试数据:路径中含 `/tests/` 的文件**不参与 C9b/C9c/C9d 扫描**(夹具里的假 `*.sh`/`*.ps1` 不应被要求 `# 对应卡:`),也不参与 `scripts/repo/check-scripts.sh` 的语法与行数扫描。

C9 的价值:文档与脚本从此不会脱钩——改脚本名而忘改文档、或写了脚本却没人调用,自检当场报错。

## 5. 新增总控入口

| 入口 | 作用 | 约束 |
|---|---|---|
| `scripts/windows/dbk.ps1 <step> [-Apply] [-Yes] [-Json]` | Windows 侧步骤分发(读步骤索引 → 调对应脚本 → 汇总输出) | 只做分发与汇总,**不含任何业务逻辑**;拒绝未知步骤名 |
| `scripts/linux/dbk.sh <step> [--apply] [--yes] [--json]` | Kubuntu 侧同上 | 同上 |
| `windows/verify-all.ps1` / `linux/verify-all.sh` | 按 `08-verification.md` 的 A–F 逐项自动判定,汇总写 `baseline/08-verification.md`(每台设备副本) | **执行器**:只做判定与汇总,按`-out-dir`/`--out-dir` 落盘;**不得自动执行任何 `--apply`**(对所有子脚本只允许 `--check` 与只读子命令);不进卡映射表、不登记 steps.tsv(与库文件同列,见第 6 节 C9d 白名单) |

**执行器(`verify-all.sh` / `verify-all.ps1`)的 `-Step` 语义(2026-09-24 补,与实现逐字一致)**:执行器**不绑卡**(不进卡映射表、不登记 `steps.tsv`、没有 `# 对应卡:` 头),所以第 2 节的“脚本头卡号集合成员判断”对它们**不适用**——不能靠沉默豁免,故在此写明:

- `--step`/`-Step` 取**验收条目所关联的卡号**(`NN-K`;`08` 是 08-verification.md 自身的记录项)。可用集合 = 执行器自带条目表里出现过的卡号(去重排序),**非法取值时打印可用集合并以 64 退出**(不再静默忽略)。
- 给了合法 `-Step` 时**只判定关联到该卡号的条目**,其余条目记「跳过」、不计入退出码;退出码语义不变:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项(加 `--confirm-manual`/`-ConfirmManual` 后人工项不再计入退出码)。
- 不给 `-Step` 时判定全部条目;显式写 `08-A-F` 与缺省等价(“六组全判”),它是唯一不以卡号取值的合法写法。
- 两侧现状:`scripts/windows/verify-all.ps1` 已按上述语义实现;**Kubuntu 侧 `scripts/linux/verify-all.sh` 尚未做过滤与校验**(只认 `08-A-F` 的“六组全判”,其它取值按全判处理),其 `-Step` 过滤待后续批次同步——在此明写以免当成“已豁免”。

步骤索引文件:`scripts/windows/steps.tsv`、`scripts/linux/steps.tsv`(列:步骤号、脚本路径、是否破坏性、说明)。总控读它分发,C9d 也校验它的一致性:脚本路径必须存在且属本侧、本侧步骤脚本必须登记进索引、破坏性列 ∈ {0,1}、索引步骤号必须落在脚本头卡号集合里、同一 (步骤号, 脚本路径) 对不得重复(同一步骤号可以有多行 = 一张卡对应多个脚本;一脚本服务多张卡时按步骤号各占一行,同一脚本路径也允许出现多行)。**索引行不是装饰**:它既是总控的分发表,也是“这一步会不会改系统”的第二道记录。

**一张卡多个脚本(2026-09-21 放宽)**:同一步骤号在索引里可以有多行(每行一个脚本),总控按**索引行顺序**逐行执行该步骤号的全部行,再把它们的退出码一起聚合(任一 1 → 1;无 1 有 2 → 2;全 0/9 → 0);破坏性门槛也**逐行**判定——任一行标了破坏性,`--apply`/`-Apply` 就必须同时给 `--yes`/`-Yes`,否则整批退 64 且一个子脚本都不调用。改用例:卡 05-3(`graphics.sh` + `graphics-mok.sh`)、卡 05-7(`set-journald.sh` + `set-updates.sh`)、卡 05-13(`first-boot.sh` + `hardening.sh`)。

## 6. 逐卡脚本映射表(48 张动作卡 → 脚本)

> **状态说明(2026-09-22,K2 批次更新)**:本节映射表**已按 `docs/design/04-kubuntu-variant-design.md` 重写并取代原子版口径** —— 基础系统由 Fedora 44 Silverblue(原子版)改为 **Kubuntu 26.04 LTS**,因此表中不再出现原原子版专属脚本(已废弃:`dbk-ostree.sh`、`dbk-rollback.sh`、`graphics-mok.sh`),回滚由**包级回退**(`scripts/linux/rollback-pkg.sh`)承担,snap 规避由 `scripts/linux/step-snap-free.sh` 承担。表里的脚本名与 `scripts/linux/steps.tsv`、`scripts/windows/steps.tsv` 以及脚本头 `# 对应卡:` 三处必须一致,不一致时以自检 C9b/C9c/C9d 的输出为准。

**图例**:`[有]` 既有脚本(按 Kubuntu 语义改写后仍在用);`新` = 本方案新增;`人工` = 无法自动化(卡内标注)。卡号取 `01-playbook-reshape-design.md` 第 4 节的"三轨道 + 分盘前置章节"结构(底座 = 01 / **分盘(安装前的前置章节)= 02** / **轨道 W = 03** / 轨道 L = 04 / 首启收敛 = 05 / 退役与救援 = 07)。

| 卡 | 动作 | 脚本 |
|---|---|---|
| 01-1 | 改固件设置 | `windows/check-firmware.ps1`(BIOS 内的开关本身只能人工) |
| 01-2 | 做两个安装介质(Windows 11 + Kubuntu 26.04) | `windows/verify-install-media.ps1`(校验 ISO 与官方 `SHA256SUMS`、列出可移动盘;写入由 Rufus / Ventoy 人工) |
| 01-3 | 核对目标盘 | `windows/preflight.ps1 -Only target-disk` |
| 01-4 | 落 L0 产物 | `windows/collect-l0.ps1` |
| 02-1 | 分盘总则与三种轨道的目标布局 | `windows/check-partition-layout.ps1`(总则与铁律本身是纪律条款,无写动作) |
| 02-2 | 轨道 W 的分盘 | `windows/check-partition-layout.ps1 -Track W`(安装器自动分区为人工) |
| 02-3 | 轨道 L 的分盘 | `linux/check-partition-plan.sh --track L`(Calamares 分区动作人工;**与 04-2、07-5 同一脚本**) |
| 02-4 | 轨道 D 的分盘(含 115GiB 预留) | `windows/create-partitions.ps1` + `windows/check-partition-layout.ps1 -Track D` |
| 03-1 | 装 Windows | `windows/verify-windows-baseline.ps1`(安装为人工) |
| 03-2 | 关 Fast Startup 与休眠 | `windows/disable-faststartup.ps1` |
| 03-3 | 已知文件夹重定向 | `windows/redirect-known-folders.ps1` |
| 03-4 | KMS 激活 | `windows/check-activation.ps1`(激活动作人工、外链) |
| 03-5 | 落 L1 产物 | `windows/collect-l1.ps1` |
| 03-6 | 跑只读体检 | `windows/preflight.ps1` |
| 03-7 | 读闸门结论 | `windows/check-gate.ps1` |
| 03-8 | 跑基线备份 | `windows/backup-esp.ps1` |
| 03-9 | 落 L2 产物 | `windows/collect-l2.ps1` |
| 04-1 | UEFI 启动进 live | `windows/set-bootnext.ps1 -Device USB -Apply -Yes` |
| 04-2 | 手动分区(Calamares) | `linux/check-partition-plan.sh --track D`(分区动作人工;含"不让 Calamares 动 Windows ESP"的前置提示) |
| 04-3 | 装完重启验证 | `linux/verify-l3.sh`(引导包在位、GRUB 落 `\EFI\ubuntu\`、`/boot` 独立 ext4、两块 ESP、`BootOrder` 首位) |
| 04-4 | 落 L3 产物 | `linux/collect-l3.sh` |
| 05-1 | 共享盘挂载 | `linux/mount-shared.sh` |
| 05-2 | 家目录重定向 | `linux/xdg-redirect.sh` |
| 05-3 | 显卡与 Secure Boot(Ubuntu 官方预签名包) | `linux/graphics.sh` |
| 05-4 | 时间(RTC 走 UTC) | `linux/set-time.sh` |
| 05-5 | 蓝牙配对密钥同步 | `linux/bt-keys-sync-wrapper.sh` |
| 05-6 | zram 与 swapfile | `linux/storage.sh` |
| 05-7 | journald 与更新策略 | `linux/set-journald.sh` + `linux/set-updates.sh`(`unattended-upgrades` 只装安全更新、不自动重启) |
| 05-8 | SSH 与 SMART | `linux/set-remote-health.sh`(apt 装 `smartmontools`;`sshd` 与 `smartd` 用 `systemctl enable --now`) |
| 05-9 | **包级回退与变更前备份** | `linux/rollback-pkg.sh`(`--list` / `--check` / `--apply` 降级并 `apt-mark hold` / `--unhold`) |
| 05-10 | 发行版升级(约 3 年一次) | `linux/upgrade-release.sh`(前置备份与留档 -> `do-release-upgrade` -> 后置与 S5 复核) |
| 05-11 | 回 Windows 入口 | `linux/reboot-to-windows.sh` |
| 05-12 | 落 L4 产物 | `linux/collect-l4.sh` |
| 05-13 | L4 汇总执行(可选) | `linux/first-boot.sh` + `linux/hardening.sh` |
| 05-14 | **snap 零残留** | `linux/step-snap-free.sh`(四条判据 + 清除残留 + apt pin + Mozilla 官方源) |
| 07-1 | 判层 | `linux/triage.sh`(只读采集:分区/挂载/`efibootmgr`/两块 ESP 内容/包管理与错误日志) |
| 07-2 | 从 grub 提示符回去 | `linux/gen-grub-rescue-commands.sh`(生成两套可复制命令;grub 内的输入本身人工) |
| 07-3 | Windows 侧修引导 | `windows/repair-windows-boot.ps1` |
| 07-4 | 只重装 Windows | `windows/verify-windows-baseline.ps1`(安装人工) |
| 07-5 | 只重装 Kubuntu | `linux/check-partition-plan.sh --track D`(安装人工;含"ESP 与 `/boot` 绝不格式化"断言) |
| 07-6 | 基线回滚 | `windows/restore-esp.ps1` |
| 07-7 | 周期巡检 | `windows/verify-baseline.ps1` + `linux/check-health.sh` + `linux/check-signature.sh` |
| 07-8 | 应急纪律 | 人工(纪律条款;卡内标注"本条无脚本") |
| 07-9 | 归位引导顺序 | `windows/restore-boot-order.ps1` |
| 07-10 | 备份现状 | `windows/backup-esp.ps1 -OutDir D:\dbk-l5-backup` |
| 07-11 | 删 Ubuntu 分区 | `windows/delete-linux-partition.ps1`(破坏性:`--yes` + 前置断言 + 只按分区号/GUID 精确删除 + 后置复读) |
| 07-12 | 清 NVRAM 与可选扩容 | `windows/cleanup-nvram.ps1` + `windows/extend-data-partition.ps1` |
| 07-13 | 只停用不删 | `windows/disable-linux-entry.ps1` |
| 08-A…F | 验收六组 | `windows/verify-all.ps1` / `linux/verify-all.sh` + 两个 `collect-*` 复用 |

**一张卡多个脚本**:02-4、05-7、05-13、07-7、07-12 五处——同一卡号在 `steps.tsv` 里占多行,总控按索引行顺序逐行执行并聚合退出码(规则见第 5 节)。

**库文件与既有脚本的改写(不进卡映射表)**:

| 文件 | 处置 |
|---|---|
| `linux/dbk-pkg.sh` | **apt/dpkg 语义的包助手**(已由它取代原原子版的分层安装助手,后者已废弃):`pkg_installed` 走 `dpkg-query -W`,`pkg_install` 走 `apt-get install -y`;保留 `DBK_SKIP_*` 与退出码语义。属库文件(C9d 白名单),被 05-5/05-6/05-7/05-8 等卡间接使用 |
| `linux/dbk-obs.sh` / `windows/dbk-obs.ps1` | **可观测性库**(报告与 JSON、日志落盘、失败三处可见与 errtrap,见第 2.1 节)。属库文件(C9d 白名单),分别被同侧的 `dbk-cli.sh` / `dbk-cli.ps1` source |
| `windows/dbk-win-probe.ps1` | **轨道 W 的只读探测库**:分区布局读数、`templates/partitions.txt` 目标值解析、最大连续未分配间隙、系统版本/内部版本;被 `verify-windows-baseline.ps1`、`collect-l1.ps1` 与 07-9…07-13 五张退役卡 dot-source。属库文件(C9d 白名单),不登记进 `steps.tsv`、不被卡引用 |
| `linux/verify-all.sh` / `windows/verify-all.ps1` | **验收总控执行器**:按 `08-verification.md` 的 A-F 逐项只读判定,汇总落 `baseline/08-verification.md`(每台设备副本)。**不绑定卡**——验收六组不是一张动作卡,故与库文件同列(C9d 白名单)、**不登记 `steps.tsv`**;对子脚本一律只传 `--check`/`--list` |
| `linux/hardening.sh` | 逐项改为 apt/dpkg 语义(R1 变更前备份、R2 包级回退、R3 旧内核保留、R4 救援介质、R5 journald、R6 OOM/zram、R7 SSH、R8 保守更新、R9 SMART);`--check/--apply` 结构与"失败不中断"口径不变 |
| `linux/graphics.sh` | 已由 akmods/自签密钥改为 **`ubuntu-drivers install` 装官方预签名包 + Wayland/PRIME 核对 + nouveau 兜底**(与卡 05-3 绑定) |
| `linux/first-boot.sh` | 逐模块调用改为 `storage -> hardening -> mount-shared -> graphics`;摘要与退出码语义不变 |
| **已删除**(原原子版专属,已废弃;已由包级回退与 snap 规避脚本取代) | `linux/dbk-ostree.sh`(分层安装)、`linux/dbk-rollback.sh`(部署级回滚)、`linux/graphics-mok.sh`(密钥注册);Ubuntu 上没有对应机制 |
| 四个 PowerShell 脚本(`preflight` / `backup-esp` / `verify-baseline` / `set-bootnext`) | **不受基础系统切换影响**,只需按上表补 `--check/--json`/`-Only`/`-Device` 契约;四个都已在 2026-09-24 补齐(`backup-esp` 更早带 `-Check`;`set-bootnext` 见第 9 节 K5 行,`preflight` 与 `verify-baseline` 见第 9 节 K6 行):`-Check` 缺省且零写、`-Apply` 才落盘(`preflight` 的 `-Apply` 写体检报告,`verify-baseline` 无写动作故 `-Apply` 与 `-Check` 同义)、`-Json`/`-Log`/`-Yes`/`-Step` 与库层一致。唯一保留差异:`preflight` 的 `-Json` 仍是它自己的查询 schema(`script`/`only`/`rows[]`/`red`/`yellow`/`verdict`),不套用第 2 节的契约 JSON,所以 `dbk.ps1 <preflight 步骤号> -Json` 只能得到总控合成的失败记录(含原因文本,不静默) |

**合计**:动作卡 **48 张**(01 四 + 02 四 + 03 九 + 04 四 + 05 十四 + 07 十三),对应**步骤脚本 46 个**——其中 `check-partition-plan.sh` 服务 02-3/04-2/07-5 三张卡,`verify-windows-baseline.ps1` 服务 03-1/07-4,`backup-esp.ps1` 服务 03-8/07-10,`verify-baseline.ps1`+`check-health.sh`+`check-signature.sh` 共服务 07-7;另有**库与总控 11 个**(两侧 `dbk-cli`、两侧 `dbk-obs`、`dbk-pkg.sh`、`dbk-win-probe.ps1`、`dbk.sh`、`dbk.ps1`、`verify-all.sh`、`verify-all.ps1`)、**仓库自检 4 个**(`check-docs.sh`、`check-docs-lib.sh`、`check-docs-repo.sh`、`check-scripts.sh`)与**步骤索引 2 个**(`linux/steps.tsv`、`windows/steps.tsv`)。

## 7. 夹具测试要求(每个脚本的最低验证)

1. **通过路径**:夹具让判据全部为真 → 退出码 0;
2. **失败路径**:至少一处判据为假 → 退出码 1,且输出指明是哪一项;
3. **dry-run 不改系统**:`--check` 运行后夹具目录的时间戳/内容零变化;
4. **破坏性脚本额外**:缺 `--yes` 时退出码 64 且**不产生任何写操作**;后置断言失败时退出码 1 并打印复读结果;
5. 夹具放在 `.superpowers/sdd/kubuntu/fixtures/<批次或脚本名>/`(**不入库**),用假的 `apt-get`/`dpkg`/`snap`/`efibootmgr`/`lsblk`/`sgdisk`/`diskpart`/`bcdedit` 可执行文件或同名桩函数注入(本条指步骤脚本夹具;check-docs 自检脚本自身的夹具是例外,已入库到 `scripts/repo/tests/check-docs/`,见第 4 节)。
6. **失败必须可表现**(第 2.1 节,每条至少要有一个夹具):① 调了 `dbk_enable_errtrap` 的 `set -e` 脚本在命令失败时,stderr、`--log` 日志、`--json` 的 `checks[]` 三处都能看到 errtrap 条目与失败命令行;② 没调 errtrap 的脚本失败时,stderr 与 JSON 仍能看到失败项与原因(不允许只返回退出码);③ `--json` 模式下失败信息不丢失(`message` 有原因、`checks[]` 有失败项);④ 取值缺失/空值(`--log`、`--log ""`、`--step`)一律退 64 且零写。

## 8. 诚实说明:这次扩充的代价

| 项 | 代价 |
|---|---|
| 规模 | 新增 **46 个步骤脚本** + 两侧契约/可观测性库与两个总控入口;仓库脚本类文件总数(不含 `.gitkeep` 与测试夹具)从 **16 个**增到 **63 个**(46 步骤脚本 + 11 库与总控 + 4 仓库自检 + 2 步骤索引);实施任务从 21 个增到约 29 个 |
| 审查 | 每个脚本都要过"实现 + 审查 + 修复轮",工作量约翻倍 |
| **验证等级** | 这些脚本**全部无法在真机上验证**(无 Kubuntu 装机环境 / 无第二台 Windows)→ 只有夹具级验证。文档与**脚本头**都必须标注"夹具级验证,真机未跑";`08-verification.md` 的参考设备首次真跑即是对全套脚本的首次真机验证 |
| 收益 | 每步可自动判定(减少"照着文档敲错"),危险步骤有前置断言与复读(比人手工点更安全),卡与脚本双向绑定(C9)防脱钩 |

明确接受的取舍:**用"约一倍的工作量"换"每步可自动判定 + 危险步骤有断言"**;不接受的是"为了脚本数量而写无法验证的自动化"——因此 S2 明确放弃无人值守安装,人工步骤(固件开关、Calamares、Windows 安装、激活动作)一律不做假自动化。

## 9. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-09-18 | 初版:确立 S1 双模式型 / S2 L3 人工 + 前置后置脚本 / S3 危险三步的三条硬规则;统一 CLI 与退出码;卡↔脚本双向绑定(C9);总控入口与步骤索引;43 卡映射表(新增 35 个步骤脚本、共 41 个新文件);夹具测试五条;代价与验证等级说明 |
| 2026-09-18 | 修复轮 2:check-docs 夹具套件入库到 `scripts/repo/tests/check-docs/`(版本化,换机器可复跑);路径含 `/tests/` 的文件豁免 C9b/C9c/C9d 与 check-scripts 扫描 |
| 2026-09-19 | 与 `02-fedora-atomic-variant-design.md` 对齐(历史:该文档已被 `04-kubuntu-variant-design.md` 取代、只留作历史):第 6 节映射表按原子版改写(该口径已废弃,现行口径见第 6 节开头的状态说明)——卡号同步三轨道结构(原 03 的 4 张卡并入 02,编号 02-7…02-10;原 06 的 5 张卡并入 07,编号 07-9…07-13);卡 05-9 由"快照与回滚"改为"**部署回滚**"(删除 `snapshot.sh`/`set-snapshots.sh`,新增 `dbk-rollback.sh`);新增库文件 `dbk-ostree.sh`(取代 `dbk-pkg.sh`:分层安装 + `rpm-ostree status --json`);`graphics.sh`/`graphics-mok.sh` 改 rebase + MOK、`set-updates.sh` 改 `rpm-ostreed-automatic`、`upgrade-release.sh` 改 `rpm-ostree rebase`、`set-remote-health.sh`/`storage.sh` 改 rpm-ostree 语义;四个 PowerShell 脚本不受影响;第 8 节代价表按新表重算(34 个步骤脚本 / 40 个新文件 / 总数 56);第 2–5 节 CLI 契约与第 7 节夹具要求不动 |
| 2026-09-20 | 修复轮 1(任务 1 审查修正 + 用户新增硬要求 O-1):第 2 节新增 **2.1 可观测性**——失败不得只给退出码、三处可见(stderr / `--log` / JSON `checks[]`)、opt-in 的 `dbk_enable_errtrap`、库层不吞 stderr、PS 侧 UTF-8 输出;新增两侧可观测性库 `scripts/linux/dbk-obs.sh` 与 `scripts/windows/dbk-obs.ps1`(第 4 节 C9d 白名单与 `check-docs-lib.sh` 的 WL 两处同步);CLI 取值错误(`--log`/`--step` 缺值或空值)改为用法错误 64 且不落盘(不再经 `die()`);破坏性脚本必须在脚本头声明 `# 破坏性:1`,由库层在执行前拦 `--apply` 缺 `--yes`;卡头支持逗号列表(一脚本服务多张卡)与行首 BOM,C9b/C9d 同步升级并新增破坏性列、步骤号一致性、重复步骤号三项交叉校验;`--json` 增加 `message` 字段并在判据为空时补一条失败项;库不再替调用方打开 `errexit`;`--log` 缺省口径明确为“库不落盘、需要时由步骤脚本调 `dbk_log_default`/`Set-DbkLogDefault`”;第 6 节增库文件行与重算合计(42 个新文件 / 总数 58);第 7 节夹具新增第 6 条“失败必须可表现”;夹具套件新增 4 个样例仓库(带 BOM 的 `.ps1` 卡头、多卡列表头、破坏性列非法、步骤号重复) |
| 2026-09-20 | **用户撤回指令**:用户声明触发 2.1 节的那条指令为错误输入并撤回其相关生成内容。裁定:2.1 节与两侧可观测性库**保留为工程约定**(非用户需求,已在 2.1 开头加归因说明);同批提交中来自**审查者发现**的修复(C-1、I-1…I-5、M-1…M-5、F3/F5…F8)**不受影响**。 |
| 2026-09-20 | 修复轮 2(任务 1 收尾):errtrap 触发后进程必须以 1 退出(trap 报完即 `exit "$DBK_FAIL"`,不再泄漏失败命令自身状态;JSON 只输出一次);`dbk_enable_errtrap` 新增 `errexit` 断言(未开 `set -e` 误用 → 64),`dbk_report` 新增第二道防线(已有 errtrap 条目时拒绝 PASS → 64);PS 侧 `Get-DbkHeaderField` 改 `-CaseSensitive`,与 C9b 的 `CARDRE` 对齐;第 2.1 节补 errtrap 退出码/误用防护/PS 两条已知差异(`-Log`/`-Step` 缺值被 PS 参数绑定拦下退 1、空串被归一成“未给”)与 `.gitattributes` 行尾约定;`check-docs-repo.sh` 的重复步骤号改报真实行号;两侧夹具新增 6 条断言(errtrap 退出码 2、未开 `set -e` 误用 1、errtrap 后报 PASS 1、PS errtrap/opt-in 各 1) |
| 2026-09-20 | **结构重构:分盘抽为安装前的前置章节**(用户裁定,与 `01-playbook-reshape-design.md` 同步):第 1/6 节按新基数重算——动作卡 43 -> **46 张**(底座 4 / 分盘 4 / 轨道 W 9 / 轨道 L 4 / 首启收敛 12 / 退役与救援 13);映射表把原 02-1 diskpart 预建分区 一卡与其脚本 `windows/create-partitions.ps1` 移入分盘章节(落 02-4 轨道 D 的分盘),原 02-2…02-10 九张卡改号为 03-1…03-9,并新增 02-1/02-2/02-3 三行(核对脚本 `windows/check-partition-layout.ps1`、`linux/check-partition-plan.sh`);第 6 节合计与第 8 节代价表重算(**35 个步骤脚本 / 43 个新文件 / 总数 59**);第 2–5 节 CLI 契约与第 7 节夹具要求不动 |
| 2026-09-20 | **轨道 W 全量收口**(实施计划任务 7–10):7 个新步骤脚本(`windows/verify-windows-baseline.ps1`、`windows/disable-faststartup.ps1`、`windows/redirect-known-folders.ps1`、`windows/check-activation.ps1`、`windows/collect-l1.ps1`、`windows/check-gate.ps1`、`windows/collect-l2.ps1`)+ 1 个库(`windows/dbk-win-probe.ps1`);`windows/preflight.ps1` 卡头 03-7 → 03-6、`windows/backup-esp.ps1` 补 `# 对应卡:03-8` 与 `-Check`;`windows/steps.tsv` 登记 03-1…03-9(原有 preflight / backup-esp 两行按新卡号改写,不新增重复行);手册 `docs/03-windows.md` 由 `docs/02-windows.md` 改名并吸收 `docs/03-preflight.md`(9 卡 + 1 值表,后者删除) |
| 2026-09-21 | **轨道 L 的 L4 收口(B2 修复轮):C9d 唯一性放宽为 (步骤号, 脚本路径) 对**——第 4 节 C9d 行与第 5 节步骤索引段同步改写,并写明总控的多行执行与聚合规则;`check-docs-repo.sh` 的重复检测改按 (步骤号, 脚本) 对报错(夹具新增 `c9d-multi` 正例,`c9d-dup` 改为同对重复);两侧总控 `scripts/linux/dbk.sh` / `scripts/windows/dbk.ps1` 支持同一步骤号多行(按索引行顺序逐行执行、聚合退出码、破坏性门槛逐行判定),两侧总控夹具各新增 4 条多行断言;`scripts/linux/steps.tsv` 登记 `graphics-mok.sh`(05-3)、`set-updates.sh`(05-7)与卡 05-13 的 `first-boot.sh`/`hardening.sh`,两个脚本头补 `# 对应卡:05-13`;`windows/verify-baseline.ps1` 补回 `# 对应卡:07-7` |
| 2026-09-21 | **退役与救援收口(批次 C1,实施计划任务 18–21)**:第 6 节映射表的 13 张退役与救援卡全部落地,新增 10 个步骤脚本(`scripts/linux/triage.sh`、`scripts/linux/gen-grub-rescue-commands.sh`、`scripts/linux/check-signature.sh`、`scripts/windows/repair-windows-boot.ps1`、`scripts/windows/restore-esp.ps1`、`scripts/windows/restore-boot-order.ps1`、`scripts/windows/delete-linux-partition.ps1`、`scripts/windows/cleanup-nvram.ps1`、`scripts/windows/extend-data-partition.ps1`、`scripts/windows/disable-linux-entry.ps1`);其中 07-10 备份现状复用既有 `scripts/windows/backup-esp.ps1`(`-OutDir D:\dbk-l5-backup`,脚本头卡号扩为 03-8,07-10)、07-12 由 cleanup-nvram 与 extend-data-partition 两个脚本共卡、07-7 由 verify-baseline / check-signature / dbk-rollback 三个脚本共卡;库 `scripts/windows/dbk-win-probe.ps1` 追加固件条目与 `{bootmgr}` 断言(供 07-9…07-13 复用,白名单不变);两侧 `steps.tsv` 登记退役与救援的 11 行(含 07-12 的两行);`docs/07-rescue.md` 全量改写为 13 张场景卡并删除 `docs/06-decommission.md`(引用清扫后仅设计文档留历史叙述) |
| 2026-09-24 | **修复轮(批次 K5:补齐两处契约缺口)**:① `scripts/windows/set-bootnext.ps1` 按第 2 节改造——补 `-Check`(缺省、只读)/`-Apply`/`-Yes`/`-Json`/`-Log`/`-Step`,脚本头加 `# 破坏性:1`(一次性引导切换算破坏性写),`-Apply` 缺 `-Yes` 由库层退 64 且零写;`-WhatIf` 保留为 `-Check` 的等价写法(与 `-Apply` 互斥 64);`-Check` 判定 = 目标存在可设 0 / 找不到目标或固件不支持 1 / 非管理员读不到 2 / 参数非法 64;固件枚举与后置断言改用 `scripts/windows/dbk-win-probe.ps1`(不再自带一份解析);`windows/steps.tsv` 的 04-1 破坏性列 0 -> 1。② `scripts/windows/verify-all.ps1` 落实 `-Step`(第 5 节新段):取验收条目关联卡号,非法值 64 并打印可用集合,合法值只判定该卡号条目、其余记「跳过」。③ 第 2 节新增“缺省只读 + `-Yes` 门槛”段。已知待办(本批未动,见 K5 报告):`preflight.ps1` 与 `verify-baseline.ps1` 仍不带 `-Check`/`-Apply`/`-Json`/`-Log`(`dbk.ps1` 转发这些开关时参数绑定失败),补齐它们会改动已写入手册的输出与缺省写行为,需与手册同步的单独批次(K6 已补齐,见下一行) |
| 2026-09-24 | **修复轮(批次 K6:补齐 Windows 侧最后两处 CLI 契约)**:① `scripts/windows/preflight.ps1` 与 `scripts/windows/verify-baseline.ps1` 按第 2 节补齐 `-Check`(缺省、零写)/`-Apply`/`-Json`/`-Yes`/`-Log`/`-Step` 并 dot-source `dbk-cli.ps1`:`preflight` 的 `-Apply` 才落体检报告(此前“缺省就写报告”不符合缺省只读口径)、`verify-baseline` 无写动作故 `-Apply` 与 `-Check` 同义;两者 `-Check` 与 `-Apply` 同时给按用法错误 64。`dbk.ps1 01-3 / 03-6 / 07-7 -Check` 从此不再参数绑定失败(此前 rc=1 `NamedParameterNotFound`)。② 手册与索引同步:`docs/03-windows.md` 的 03-6、`docs/07-rescue.md` 的 07-7/07-10、`docs/04-kubuntu.md` 的 04-1、`docs/05-first-boot.md` 的 05-11、`docs/08-verification.md` 的 C1、`docs/10-faq.md`、`checklists/deploy.md` 的 L0-5/W-6/L3-1/L4-11 与 `windows/steps.tsv` 三行说明列——`set-bootnext.ps1` 的调用写法统一为 `-Check` 或 `-Apply -Yes`(旧写法“去掉 `-WhatIf` 才执行”已废,`-WhatIf` 只作为等价别名保留)。③ 夹具新增 CLI 契约用例:总控分发契约、`-Check` 零写、`-Apply` 落盘、`-Json` 单行、总控对**真** `verify-baseline` 的 ①/②/③ 文本解析仍成立、手册调用写法。④ 已知保留差异:`preflight` 的 `-Json` 仍是自有查询 schema(见第 6 节该行) |
