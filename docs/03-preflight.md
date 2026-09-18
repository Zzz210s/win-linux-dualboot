# L2:预检与基线(硬闸门)

本文件是 L2 阶段的手册。目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;前提由 [L1 手册](02-windows.md)交付;动机与依据见[设计文档](design/00-design.md) 4.3 节(L2 步骤)、第 2 节(I4)、第 6 节(阶段产物与交接规则)、第 7 节(L2 两行)与第 9 节(风险登记)。本阶段的工具是 `scripts/windows/preflight.ps1` 与 `scripts/windows/backup-esp.ps1` 两个 PowerShell 脚本,产物落盘到 `baseline/`。

## 目标

L2 是**全流程唯一的硬闸门**。做完本阶段,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | 只读体检已完成,逐项有实测值 | `baseline/02-preflight-report.md` 存在,含"检查项 / 实测值 / 判定"表 |
| 2 | 闸门结论明确且无红项 | 报告最后一行为 `结论: 允许进入 L3`(出现红项时该行是 `结论: 禁止进入 L3`) |
| 3 | 基线齐备(I4 的最低要求) | `baseline/02-esp-backup/` 含 `EFI/` 子树与 `manifest.sha256`;`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt`、`baseline/01-partitions.txt` 均在位 |
| 4 | BitLocker 不阻挡后续操作 | 报告"BitLocker 保护状态"行为 `未加密` 或 `卷已加密、保护已关闭`(已挂起) |
| 5 | L1 记录已核验(不重做 L1) | 分区表、激活状态与隔离结论与 L1 产物一致,且隔离结论已转记进报告 |
| 6 | 全程没有改动系统 | 未写 ESP、未改固件设置、未改 `BootOrder`、未执行 `efibootmgr -o` |

本阶段的产物逐字为:

- `baseline/02-preflight-report.md`:闸门报告(逐项判定表 + 结论行);
- `baseline/02-esp-backup/`:ESP 全量文件树(含 `EFI\` 子树)+ `manifest.sha256` 文件级清单;
- `baseline/02-firmware-entries.txt`:`bcdedit /enum firmware` 与 `bcdedit /enum {bootmgr}` 快照;
- `baseline/02-partitions.txt`:`diskpart` 与 `Get-Partition` 分区快照。

多设备时按 [baseline/README.md](../baseline/README.md) 的布局放到 `baseline/<设备别名>/` 下,四份产物都不入库。

**术语约定**:本方案里的"ESP 基线""ESP 镜像"一律指 `baseline/02-esp-backup/` 的**文件树 + 文件级清单**,而不是磁盘镜像文件。Windows 原生没有 `dd`,块级整块镜像不属主路径(需要时另行用第三方工具制作,不改变上述产物名与判据)。旧手册里出现的"ESP 镜像"按本约定理解。

### 闸门规则(硬)

| 判定 | 含义 | 动作 |
|---|---|---|
| 红 | 存在导致 L3 必然失败或不可回滚的状态 | **禁止进入 L3**;修复后重跑 `preflight.ps1`,直到报告无红项 |
| 黄 | 有风险但可带着风险继续 | 记录在报告里后继续;恢复保护、核对偏差等收尾动作在 L4/L5 处理 |
| 绿 | 通过 | 无 |

红项共六项,逐条来自[设计文档](design/00-design.md) 4.3 与四条不变量:

1. 存储控制器命中 VMD / RAID(Linux 侧看不到磁盘);
2. BitLocker 保护已开启(改分区表会索要恢复密钥);
3. Fast Startup 已开启(`HiberbootEnabled = 1`,NTFS 双写风险);
4. **最大连续未分配空间**不足 115GiB(root 100 + 快照 15)。本方案的目标布局是 `ESP → MSR → C: → D: → [115GiB 未分配] → WinRE`(设计文档 5.1),WinRE 占磁盘末尾,所以"盘尾空隙"必然接近 0——判据取**最大连续未分配间隙**,脚本把"最大连续未分配"与"盘尾未分配"两个值都写进报告,便于人工复核;
5. **I4 基线产物缺任一**(改分区表之前必须先有可用基线);
6. **非管理员会话**(报告不可用):存储控制器、BitLocker、固件启动项、分区表这些项在非管理员会话里都读不到,脚本把这一项计入红项并把结论强制为 `禁止进入 L3`。

第 5 项是"产物齐备性"、第 6 项是"会话前提"而非"设备风险":前者初检时通常是红的,跑完基线备份再重跑一次即转绿——这正是本阶段两步一收尾的用意;后者用管理员身份重跑即消失。

## 前置条件

- **L1 完成**:[L1 手册](02-windows.md)"验证"一节 9 项通过(激活失败的设备按该节例外计,并在 L2 作为黄项登记),`baseline/01-partitions.txt` 与 `baseline/01-activation.md` 存在。
- **L0 产物在位**:`baseline/00-firmware.md` 存在,且**含"启动顺序(`BootOrder` 首位)原值"一行**。这一行是 L2 比对启动顺序的基准;缺它脚本会把"L0 基准:启动顺序原值"判为黄,并在报告里写明"L0 产物字段缺失,无法比对启动顺序"。补记该字段后重跑脚本即可转绿。
- **参数表已填**(每台设备一份,见[入口文档](00-overview.md)):`DISK_MODEL` / `DISK_SIZE`(防选错盘)、`ESP_SIZE = 2GiB`、`ROOT_SIZE = 100GiB`、`SNAPSHOT_SIZE = 15GiB`。
- **权限与环境**:Windows 11 专业版自带的 Windows PowerShell 5.1(桌面快捷方式右键"以管理员身份运行")。非管理员时脚本仍能跑,但存储控制器、BitLocker、固件启动项、分区表等项会读不到并**判红**——脚本在非管理员会话下把"管理员权限"计入红项、结论强制为 `禁止进入 L3`,**闸门报告必须在管理员会话里生成**,否则结论不可用。
- **时间窗口**:L1 与 L2 必须在同一次会话内连续完成(交接规则第 4 条)。L1 之后如果 Windows 完成过一次更新,基线即失效,回到 L1 复核后重做 L2。
- **口径:L2 只核验 L1 记录,不重做 L1。** 本阶段不重新安装、不重新分区、不改动 C:/D: 的隔离设置;发现 L1 记录与实际不符时,写进报告的"补充说明"并按失败处理一节处置,而不是在 L2 里动手改系统。

## 步骤

### 1. 初检:跑 `preflight.ps1`(只读)

在**仓库根目录**打开管理员 PowerShell(多设备时把路径换成 `baseline\<设备别名>\`):

```powershell
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\preflight.ps1 `
  -OutFile baseline\02-preflight-report.md -BaselineDir baseline
```

脚本只读:它不改动任何系统设置,唯一的写动作是生成报告文件。它会检查 14 项——管理员权限、存储控制器模式、Secure Boot、BitLocker 保护状态、Fast Startup、休眠文件、磁盘 0 未分配空间(最大连续间隙 + 盘尾空隙)、ESP 大小与剩余、固件启动项、L0 启动顺序基准、L1 产物复核、L1 隔离结论转记、I4 基线产物齐备、系统版本。判定规则与本文"验证"一节的表逐条一致;报告顶部写明"结论有效性前提:必须在管理员会话中生成"。

产物:第一版 `baseline/02-preflight-report.md`(此时"I4 基线产物齐备"通常为红)。

### 2. 处置红项(黄项只登记)

| 红项 | 处置 |
|---|---|
| 管理员权限不足(报告不可用) | 不是设备问题:用管理员身份重开 Windows PowerShell 再跑。非管理员会话下存储控制器、BitLocker、固件启动项、分区表都读不到,脚本已把该行计红并把结论强制为 `禁止进入 L3` |
| 存储控制器命中 VMD / RAID | 停在 L2,回 [L0 手册](01-firmware.md) 步骤 2 把存储模式改为 AHCI / NVMe。**若 Windows 已经按 RAID On 装好**,按该手册的附录分支(驱动预置 + 安全模式切换)处理;无法改动则该设备不适用本方案 |
| BitLocker 保护已开启 | ①用 `manage-bde -protectors -get C:` 取得 48 位恢复密钥并**存到设备之外**(不写进本仓库、不写进 `baseline/`);②`manage-bde -protectors -disable C: -rebootcount 0` 挂起保护(`-rebootcount 0` 是完整参数名,该版本只认缩写时写作 `-rc 0`;它表示"一直挂起到手工重新启用",**不会**自己恢复,闭环见"回滚"第 2 条);③重跑 `preflight.ps1`,确认该行转绿。挂起窗口就是 L2→L3,期间不要做无关的关机搁置 |
| Fast Startup 已开启 | 按 [L1 手册](02-windows.md) 步骤 3 关闭:`powercfg /h off`(同时消掉休眠文件)+ 注册表 `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power` 的 `HiberbootEnabled = 0`。两项都做,缺一项会在下次大版本更新后被改回来 |
| 最大连续未分配空间不足 115GiB | 回 L1 处理:整盘 `clean` 后按 [templates/partitions.txt](../templates/partitions.txt) 重排重装(设计文档 3.5、5.1)。**不做任何事后缩容**,也不得削减 ESP 来凑数。盘尾空隙小是正常的(WinRE 占盘尾),判据只看最大连续间隙 |
| I4 基线产物缺失 | 不是设备问题:执行步骤 3 生成基线,再执行步骤 4 重跑脚本 |

黄项按设计文档 4.3 的闸门规则**记录后继续**,但要在报告里能看懂:BitLocker 读不到、ESP 小于 1GiB(目标 2GiB,属偏差)、`bcdedit /enum firmware` 读不到、L0 启动顺序字段缺失、L1 产物缺失、L1 隔离结论未转记、`hiberfil.sys` 仍存在。

### 3. 生成基线:`backup-esp.ps1`

```powershell
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir baseline
```

脚本的动作顺序(全部只写 `-OutDir`):

1. 找一个空闲盘符(`S`/`T`/`U`/`V`/`W`,可用 `-EspLetter` 指定),用 `mountvol <盘符>: /s` 临时挂载 ESP;
2. 确认挂载点是 ESP(存在 `EFI` 目录),再用 `robocopy` 把 ESP **全量文件树**复制到 `<OutDir>\02-esp-backup\`:带 `/PURGE`,重复运行时目标目录与源严格同步(ESP 侧删改过的旧文件会被清掉,不会永久残留在备份树里);
3. 对复制结果逐文件算 SHA256,写成 `<OutDir>\02-esp-backup\manifest.sha256`(每行 `<哈希>  <相对路径>`,`sha256sum` 风格,路径相对 ESP 根;清单文件自身不参与枚举,否则会自引用);
4. `bcdedit /enum firmware` 与 `bcdedit /enum {bootmgr}` 输出写入 `<OutDir>\02-firmware-entries.txt`;
5. `diskpart`(`select disk 0` / `list disk` / `list partition` / `list volume` / `detail disk`)与 `Get-Partition` 输出写入 `<OutDir>\02-partitions.txt`;
6. 无论成功失败,收尾都用 `mountvol <盘符>: /d` 卸载 ESP。**脚本不修改 ESP 的任何内容**,也不改分区表与固件设置。

产物形态与复原方式直接相关:文件树是"能原样复制回 ESP"的形态,清单是"能证明复制回去的东西没变"的形态。复原流程见"回滚"一节。

### 4. 重跑 `preflight.ps1`,定稿报告

```powershell
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\preflight.ps1 `
  -OutFile baseline\02-preflight-report.md -BaselineDir baseline
```

这一步有两个作用:让"I4 基线产物齐备"由红转绿;让 BitLocker 状态反映**挂起之后**的实测值。**闸门看的是这一版报告**,不是步骤 1 的初检版。

### 5. 核验 L1 记录(只核验,不重做)

| 核验对象 | 做法 | 不一致时 |
|---|---|---|
| 分区表未被后续操作改变 | 把报告里实测的"最大连续未分配空间"与"ESP 大小"对照 `baseline/01-partitions.txt` 的定稿值(设计文档 4.3 基线复核;盘尾空隙只作参考,WinRE 占盘尾) | 写进报告"补充说明",按黄项处理;偏离到会影响 L3(最大连续未分配 < 115GiB 或 ESP 被削减)则按红项回 L1 |
| 激活状态 | 读 `baseline/01-activation.md`;脚本检查该文件是否存在、是否含失败字样 | 缺失或含失败:报告该行为黄,激活不阻塞 L2(设计文档第 7 节 L1 行) |
| **L1 隔离核对结论** | 脚本把 `baseline/01-partitions.txt` 注记段里"已知文件夹重定向 / C: 内容核对"相关行**转记**进报告的"L1 隔离核对结论"一节 | 注记段没有相关行:报告该行为黄,并把结论补记进 `baseline/01-partitions.txt` 后重跑 |

第三条是 L1 与 L2 的内容契约,写在这里以免歧义:[baseline/README.md](../baseline/README.md) 把 `01-partitions.txt` 定义为"分区表输出",[L1 手册](02-windows.md) 要求它同时承载"重定向核对结果与 C: 内容核对结果(注记段)"——两者以 L1 手册为准。L2 **不重做**这项核对(那是 L1 步骤 4 的事),只做两件事:确认结论存在于 L1 产物里,并把它转记进闸门报告。转记的意义是:验收 D 组"系统盘隔离生效"最终看的是 `baseline/02-preflight-report.md`,而 L1 产物可能在后续阶段被更新或丢弃。

### 6. 读结论,确认闸门

打开报告,只认最后一行:`结论: 允许进入 L3` 或 `结论: 禁止进入 L3`。**不要手工改写判定列**——要改状态就改系统,然后重跑脚本。确认"允许"之后,再目视核对一遍产物齐备(目标表第 3 行)与 BitLocker 行,然后进入 L3(`04-ubuntu.md`)。

## 验证

逐项核对,全部通过 = L2 完成。

| # | 检查项 | 命令 / 来源 | 期望 |
|---|---|---|---|
| 1 | 闸门报告存在且结论为允许 | 报告最后一行 | `结论: 允许进入 L3` |
| 2 | 报告无红项 | 报告"结论"节 | 红项一行为 `无` |
| 3 | 报告在**管理员会话**里生成 | 报告"管理员权限"行 | `是`(非管理员时该行为红,结论必为 `禁止进入 L3`) |
| 4 | 存储控制器不含 VMD / RAID | 报告"存储控制器模式"行 | 列出的是 AHCI / NVMe 控制器,不含 `RAID` 字样 |
| 5 | Secure Boot 保持开启 | 报告"Secure Boot"行 | `UEFISecureBootEnabled = 1` |
| 6 | BitLocker 不阻挡 | 报告"BitLocker 保护状态"行 | `未加密` 或 `卷已加密、保护已关闭(挂起或暂停)` |
| 7 | Fast Startup 与休眠已关 | 报告对应两行;`powercfg /a` | `HiberbootEnabled = 0`;`hiberfil.sys` 不存在;`powercfg /a` 里休眠不可用 |
| 8 | 最大连续未分配空间 ≥ 115GiB | 报告"磁盘 0 未分配空间"行 | `最大连续未分配` 数值 ≥ 115 GiB(盘尾未分配可比它小得多——WinRE 占盘尾,这是正常形态) |
| 9 | ESP 达目标尺寸 | 报告"ESP 大小与剩余"行 | `2 GiB`(低于 2048MB 按黄项记偏差,不得低于 1GiB) |
| 10 | 基线产物四件齐备 | `ls baseline\`(多设备时 `baseline\<别名>\`)与报告"I4 基线产物齐备"行 | 报告该行为绿;`02-esp-backup\EFI\`、`02-esp-backup\manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt` 都在 |
| 11 | 清单可用 | `Get-Content baseline\02-esp-backup\manifest.sha256` | 每行 `<64 位十六进制>  <EFI 开头相对路径>`;行数 = ESP 上的文件数 |
| 12 | ESP 未被改动 | 报告"固件启动项"行与 `baseline\02-esp-backup\manifest.sha256` | 备份期间只挂载与读取;备份后 `mountvol` 输出里不再有那个临时盘符 |
| 13 | 启动顺序基准可比对 | 报告"L0 基准:启动顺序原值"行 | `已记录:<值>`;对照 `baseline/00-firmware.md` 的值一致 |
| 14 | L1 记录已核验且隔离结论已转记 | 报告"L1 产物复核"与"L1 隔离核对结论"两行 | 两行均为绿(或黄项已在"补充说明"里登记) |
| 15 | 产物未入库 | `git status` | `baseline/` 下的产物一个都不出现(`baseline/README.md` 除外) |

## 失败处理

| 症状 | 立即动作 |
|---|---|
| 报告结论为 `禁止进入 L3` | 先看红项一行的列表,按"步骤 2"逐项处置;全部修好后重跑脚本。**红项一条都不许带着进 L3** |
| BitLocker 行报红且无法挂起 | 该设备**不适用**本方案(设计文档 1.2 偏离表):硬改分区表会索要恢复密钥。先备份恢复密钥,再走厂商/企业策略路径,不要"先试试看" |
| 存储控制器为 VMD / RAID 且固件里改不动 | 停在这里,记录到设备偏差;按 L0 附录分支重装一次 Windows 是唯一出路,不要指望 L3 安装器能绕过 |
| 最大连续未分配空间不足 115GiB | 回 L1 整盘重排(见步骤 2 该行)。**不要**用缩容或削减 ESP 来腾空间,也不要因为盘尾空隙小而误判(先看报告里的"最大连续未分配"值) |
| `bcdedit /enum firmware` 读不到 | 确认是管理员会话;仍读不到则记录为黄项,并保留 `bcdedit /enum firmware` 的手工输出副本(它是启动顺序证据) |
| L0 产物的启动顺序字段缺失 | 补记到 `baseline/00-firmware.md`(字段名逐字:`启动顺序(BootOrder 首位)原值`),重跑脚本;补不出原值时按黄项登记,并在 L3 后用 `efibootmgr` 重新建立基准 |
| ESP 小于 1GiB | 记录偏差:这是 L1 分区表偏离目标的信号,回 L1 复核;确认无法重排则按黄项带风险继续,并在 L4 关注 ESP 剩余空间 |
| `backup-esp.ps1` 报"需要管理员权限" | 用管理员会话重跑。非管理员时 `mountvol /s` 必然失败,脚本会在改动任何东西之前退出 |
| `backup-esp.ps1` 报挂载点上没有 `EFI` 目录 | 停:说明 `mountvol /s` 挂上的东西不是预期 ESP(或 ESP 上没有 EFI 目录)。脚本已自动卸载,先人工核对分区表再重跑 |
| 脚本报语法错误或中文变成乱码 | 两个 `.ps1` 必须是 **UTF-8 with BOM**;用 ANSI(GBK)保存会被 Windows PowerShell 5.1 误解码。从仓库重新取一份,不要用编辑器"另存为 ANSI" |
| 结论为禁止进入 L3 且红项只有"管理员权限" | 不是设备问题:当前不是管理员会话,**报告不可用**。用管理员身份重开 Windows PowerShell 后重跑脚本 |
| 报告里出现"L1 产物缺失"黄项 | 回到 [L1 手册](02-windows.md) 补齐 `01-partitions.txt` / `01-activation.md`;**不要**在 L2 里凭记忆补写记录 |
| 核验时发现实际分区表与 L1 记录不符 | 先查是不是 Windows 更新或第三方工具改过。若只是记录笔误,按实际值更新 L1 注记段并在报告补充说明里写明;若是分区真被改动,回 L1 复核(必要时重排重装) |
| 临时盘符被长期占用 | 核对:备份脚本收尾必然执行 `mountvol <盘符>: /d`;若被中断,手动执行一次 `mountvol S: /d`(盘符按实际替换),再确认 ESP 未被写入 |

## 回滚

**L2 自身几乎没有可回滚的动作**(它只读 + 只写 `baseline/`),所以这一节分两块:基线怎么用(复原),以及 L2 完成后状态怎么退回去。

### 1. 基线复原(引导层损坏而系统分区完好时用,设计文档 4.8 "第三选择")

1. 校验备份完整性:逐行核对 `baseline\02-esp-backup\manifest.sha256` 里的哈希与 `baseline\02-esp-backup\` 下的文件一致(`Get-FileHash -Algorithm SHA256` 逐文件比对);
2. 挂载 ESP:`mountvol S: /s`(S 按可用盘符替换);
3. 把 `baseline\02-esp-backup\EFI\` 复制回 ESP:`robocopy baseline\02-esp-backup\EFI S:\EFI /E`。**只复制 `EFI\` 子树**:`manifest.sha256` 是清单文件,不属于 ESP 内容,不得复制回 ESP;
4. 重建 Windows 引导:`bcdboot C:\Windows /s S: /f UEFI`(Windows 盘符按实际替换);
5. 卸载 ESP:`mountvol S: /d`;
6. 复查四条不变量:`BootOrder` 首位仍为 Windows Boot Manager;`\EFI\Microsoft\` 文件哈希与 `manifest.sha256` 一致;`{bootmgr}` 的 `path` 与本阶段 `02-firmware-entries.txt` 一致;Ubuntu 条目仍存在。(若复原过程中执行过 `bcdboot`,`\EFI\Microsoft\Boot\BCD` 与 `bootmgfw.efi` 的差异属预期,此时以"能正常启动 + `{bootmgr}` 的 `path` 一致 + `BootOrder` 首位未变"为准)

这一步的价值来自本阶段的产物形态:**文件树 + 清单**能复原被删改的引导文件并证明复原结果;`02-firmware-entries.txt` 是固件启动项与 `{bootmgr}` 的比对基准。

### 2. BitLocker 恢复保护

L3 完成、系统可正常启动后,在 Windows 里执行 `manage-bde -protectors -enable C:`,并用 `manage-bde -status` 确认保护已开启。本方案用 `-rebootcount 0` 挂起,**不会**随时间或重启自动恢复:漏掉这一步,C: 会停在"卷仍加密、保护关闭"的状态。所以 L3 完成后必须手工执行 `manage-bde -protectors -enable C:` 并核对 `manage-bde -status` 的输出,这一步做完才算闭环;闭环之前不要做与分区表有关的事。

### 3. L2 之后的退回

| 想退回到 | 做法 |
|---|---|
| 重新做一次闸门判定 | 直接重跑 `preflight.ps1`(覆盖报告)。没有改过系统时结论不变 |
| 改过分区表或固件设置 | 旧基线立即失效:重做 L2。**任何分区表/固件变更之前都必须先有可用基线**(I4),没有基线就没有回滚点 |
| 退回到 L1 的记录状态 | L2 不改系统,所以不存在"退回 L1";需要重排分区时按 [L1 手册](02-windows.md) 的整盘重来路径执行 |
| 丢弃本阶段产物 | 删掉 `baseline\02-*` 即可——但代价是失去 I4 的回滚点,下次改分区表之前必须重做本阶段 |
