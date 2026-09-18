# L5:救援与原地重装(先判断层级,再决定动不动分区)

本文件是 L5 阶段的手册之一(另一份是 [L5 退役手册](06-decommission.md),覆盖主动退役)。目标状态、四条不变量(下称 I1-I4)与参数名在[入口文档](00-overview.md)中定义;动机与依据见[设计文档](design/00-design.md)第 2 节(I1-I4)、4.8 节(崩溃后原地重装两法与"第三选择")、第 7 节(故障矩阵)、7.1 节(周期性巡检与 SBAT 事故)、7.2 节(回滚三粒度)、8-A / 8-D 组(引导安全与可撤除性验收)与第 9 节(风险登记)。

执行时配套使用勾选清单 [checklists/rollback.md](../checklists/rollback.md) 的第 2 节(引导救援)、第 3 节(原地重装两法)、第 4 节(基线回滚):清单逐项有"判据 / 如何确认"列,本文件给的是流程与命令,两者内容一一对应。

四条口径贯穿全文,越界即视为设计缺陷:

- **先判断层级,再动手。** "进不去系统"有三种完全不同的原因——引导层损坏、系统分区损坏、硬件故障。**只有第二、三种才需要动分区**;引导层损坏一律先修引导(本文步骤 1-3 与步骤 6),**不要重装**(设计 4.8 的"第三选择")。重装是最后手段,不是第一反应。
- **ESP 在任何重装路径里都绝不能格式化**(I3;设计 4.8 办法二的风险行)。误格 ESP 会同时清空 `\EFI\Microsoft\`,让 Windows 与 Ubuntu 一起进不去——这是全流程最危险的一步。
- **永久启动顺序只在固件设置界面里改**:全程不得执行 `efibootmgr -o`,也不得用等价的 `bcdedit /set {fwbootmgr} displayorder`(I2)。进另一个系统只用一次性入口:厂商 `BOOT_MENU_KEY`、[set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(Windows 侧,一次性 `BootNext`)或 [reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh)(Linux 侧,`efibootmgr -n`)。
- **反复长按电源强制重启会把"一次引导故障"升级成"文件系统损坏"**。排障期间一律用 REISUB(SysRq)安全重启,事后跑 `fsck`(设计第 9 节风险行)。

## 目标

救援结束后,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | 崩溃层级有明确结论并落到文字(引导层 / 系统分区 / 硬件三选一) | 本文"验证"第 1 行;结论文本按步骤 0.2 的判定表给出 |
| 2 | 引导层损坏的场景**没有触发重装** | 本文"验证"第 1、2 行 |
| 3 | Windows 与 Ubuntu 都能进:默认进 Windows,Linux 走一次性入口 | 本文"验证"第 2、3、6 行 |
| 4 | `BootOrder` 首位仍是 `Windows Boot Manager`,连续重启 3 次都默认进 Windows(I1) | 本文"验证"第 2 行 |
| 5 | `\EFI\Microsoft\` 与 `{bootmgr}` 的 `path` 与 L2 基线一致;`\EFI\ubuntu\` 仍在 ESP 上(I3) | 本文"验证"第 4、5、6 行 |
| 6 | 全程未使用 `efibootmgr -o` / `displayorder`;进 Linux 只用一次性入口(I2) | 本文"验证"第 7 行 |
| 7 | 走重装路径时,**只有目标系统分区被格式化**,另一系统分区、ESP、`D:`、`/snapshots` 一字未动 | 本文"验证"第 8、9 行 |
| 8 | 巡检已留档(在有 Windows 更新的场景下) | 本文"验证"第 10 行 |

救援**不改 `baseline/` 里 L0-L4 的既有产物**(它们是故障发生前的参照物,改动即失去比对意义)。需要新落盘的东西按 [baseline/README.md](../baseline/README.md) 的命名契约另存:救援前的现状备份写到仓库外的 `D:\dbk-l5-backup\`(与退役步骤 2 同一惯例),巡检输出记进 `baseline/` 或清单备注。

## 前置条件

- **已经知道"崩溃在哪一层"的大致方向**:至少要先回答问题清单(步骤 0.2)里的"能否进固件""能否进 Windows""提示符长什么样"三条,再往下走。
- **基线可用**(I4):`baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt`、`baseline/03-efi-layout.txt` 在位可读。它们是"引导层是否被改写"的唯一客观判据,也是基线回滚的来源(`baseline/02-esp-backup/` 与 `baseline/02-firmware-entries.txt` 只覆盖基线行内的东西与固件条目;装 Ubuntu 之后新增的 `\EFI\ubuntu\` 不在其中,不能用它还原,见步骤 3.1)。
- **救援介质在位**(设计 4.7 的 R4):常备的 Ubuntu 安装 U 盘,装机结束后不回收;需要时按 [L0 手册](01-firmware.md) 的厂商差异表调出启动菜单。
- **Windows 侧的入口已知**:`BOOT_MENU_KEY`、[set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)、[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh) 三条都在手上——救援期间经常要在两系统之间来回,不要依赖"记得按键时机"。
- **BitLocker 恢复密钥在手**(设计第 9 节):48 位恢复密钥已备份在设备之外。分区表变更、ESP 写入、重装系统都可能触发恢复提示;**密钥不在手就不要动手**。
- **参数表已填**:`DISK`、`DISK_MODEL` / `DISK_SIZE`(防选错盘)、`ESP_SIZE = 2GiB`、`WINDOWS_SYSTEM_SIZE = 200GiB`、`WINDOWS_DATA_SIZE ≈ 635GiB`、`ROOT_SIZE = 100GiB`、`SNAPSHOT_SIZE = 15GiB`、`BOOT_MENU_KEY`。重装时逐分区核对靠它与 `baseline/02-partitions.txt` 对账。
- **已知"哪些数据只在本地"**:`~` 下的代码/密钥/dotfile 与 `/snapshots` 里的快照只存在于 Linux 分区,`D:` 上的文档类数据才是共享的(设计 5.3)。这决定了重装 Ubuntu 会损失什么、而重装 Windows 不会损失什么。
- **口径:本文只做救援与原地重装,不做主动退役**。想把 Linux 彻底撤掉是 [L5 退役手册](06-decommission.md) 的五步流程,那边有"顺序不可更换"的硬要求;不要在这里顺手删分区。

## 步骤

### 0. 分类判断:崩溃在哪一层(先判断,不要重装)

重装的代价是"格式化一块分区 + 重放一整天的配置",而引导层故障的代价只是"敲五六条命令"。所以先花十分钟判断层级。

#### 0.1 三层与对应的动作

| 层 | 典型现象 | 结论 | 动作 |
|---|---|---|---|
| **引导层**(NVRAM 条目 / ESP 上的引导文件) | 停在 `grub>` 或 `grub rescue>`;或提示找不到引导设备;固件里有 `ubuntu` 条目但指向的 `\EFI\ubuntu\...` 已不存在;Windows 与 Ubuntu 都进不去但分区还在 | ESP 或 NVRAM 被改写,**系统分区完好** | 走本文步骤 1-3 或步骤 6;**不要重装**(设计 4.8 第三选择) |
| **系统分区** | 能进 GRUB 菜单、能选到目标条目,但内核/`winload` 加载失败、`fsck` 报大量错、系统盘读取异常;另一个系统仍能正常进 | 只有一侧系统分区损坏 | 走本文步骤 4(Windows)或步骤 5(Ubuntu);只格那一块分区 |
| **硬件**(内存/磁盘/温度/电源) | **两个系统一起**死机、随机蓝屏、装系统也报错、SMART 异常 | 大概率不是双系统问题——两系统运行期不共享状态,**只有引导层会互相干扰**(设计第 9 节) | 先按硬件 triage:内存检测、`smartctl -H`、温度与电源;不要格式化任何分区 |

#### 0.2 判据清单(逐条回答并写下来)

按顺序问自己,每条都给出实测答案:

1. **能进固件设置界面吗?** 能进,说明主板、内存最小自检与 NVRAM 都在工作,故障不在硬件基础层。顺带在固件里看一眼启动项列表:`Windows Boot Manager` 还在不在、`ubuntu` 条目的路径是什么(截图或抄下来)。
2. **能进 Windows 吗?** 能 → 引导链的 Windows 一侧完好,不用做步骤 2;把 Linux 侧当成"待修的一侧"。不能 → 先试步骤 1.3(GRUB 里直接引导 `bootmgfw.efi`),再试步骤 2(`bcdboot` 重建)。
3. **提示符长什么样?** 这一条区分的是 GRUB 的两种故障态(见步骤 1.1):
   - `grub rescue>`:只提示 `rescue`,通常连 `normal` 都用不了——`prefix` 没设对,或者 `grub.cfg` 所在分区找不到了;
   - `grub>`:能敲 `ls`,能看到设备名——核心镜像已加载,只差 `prefix` / 配置。
   - 两者都不是"系统坏了",**都属引导层**。
4. **`\EFI\ubuntu\` 目录还在吗?** 从 Windows 管理员会话挂载 ESP 后看 `S:\EFI\ubuntu\`(步骤 2 第 1 条),或从 live U 盘看 ESP 分区。在 → 引导文件大概率可复原;不在 → 可能是退役删条目后的残留现象,或是安装器/更新清理,按步骤 6 与步骤 3 处置。
5. **分区表还在吗?** 用 `baseline/02-partitions.txt` 与现场对账(分区数、大小、偏移)。一致 → 系统分区完好,禁止重装。不一致或读不到 → 才考虑重装路径。
6. **`D:` 上的数据还在吗?** 在 → 数据分区未受影响(这也是"只重装 C:"的价值所在);不在 → 先停下,确认是不是硬件/分区表故障,不要继续写盘。
7. **两个系统是否一起异常?** 是 → 转硬件 triage(0.1 第三行),不要归因于"双系统互相影响"。

#### 0.3 只读取证(不改任何东西)

在 Windows 管理员会话(能进 Windows 时)执行(目录不存在就先建 `New-Item -ItemType Directory -Force D:\dbk-l5-backup`):

```powershell
# 仓库根目录
bcdedit /enum firmware | Out-File -Encoding utf8 D:\dbk-l5-backup\rescue-firmware.txt
Get-Partition -DiskNumber 0 | Out-File -Encoding utf8 D:\dbk-l5-backup\rescue-partitions.txt
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
```

在 live 环境或 Ubuntu 里(能进 Linux 时)执行:

```bash
sudo efibootmgr -v | tee ~/rescue-efibootmgr.txt
sudo lsblk -o NAME,SIZE,FSTYPE,PARTUUID,MOUNTPOINT | tee ~/rescue-lsblk.txt
```

两份输出按退役步骤 0 的同一惯例**拷到共享盘或外置盘**(不要留在 `~/`,那个目录可能随重装一起消失)。这一步只读:不写 NVRAM、不改 ESP、不动分区表。

### 1. 停在 `grub>` / `grub rescue>`:两条命令行恢复路径

这是最常见的一种,也是最不该重装的一种。两条路都只在**引导层**动手,不碰分区表。

#### 1.1 先判读 `ls` 的输出

在提示符下敲:

```
ls
```

输出形如:

```
(hd0) (hd0,gpt1) (hd0,gpt2) (hd0,gpt3) (hd0,gpt4) (hd0,gpt5) (hd0,gpt6) (hd0,gpt7)
```

判读规则:

- `(hd0)` 是**整块盘**;`(hd0,gpt1)` 等是**分区**。带括号才是一个可用的设备名。
- **现代 GPT 磁盘的分区写作 `(hdX,gptY)`**;`(hdX,msdosY)` 是 MBR 磁盘的写法。本方案用 GPT,手册与网上的旧教程里大量出现 `msdosY`,照抄会报 `unknown filesystem` ——这是最常见的踩坑点。
- 分区名里的 `Y` 是**分区序号**,不是盘符:本方案布局下 `gpt1` = ESP、`gpt2` = MSR、`gpt3` = `C:`、`gpt4` = `D:`、`gpt5` = Ubuntu root、`gpt6` = `/snapshots`、`gpt7` = WinRE(设计 5.1)。
- 看不到任何 `(hdX,gptY)`、只有 `(hd0)`:先 `insmod part_gpt` 再 `ls`(模块没加载时分区不会被枚举)。

逐个分区看内容,找出 root 分区:

```
ls (hd0,gpt5)/
```

判据:

- 能看到 `boot/`、`etc/`、`usr/` 之类目录 → 这就是 Ubuntu root(本方案 root 内含 `/boot`,没有独立的 `/boot` 分区);
- 报 `unknown filesystem` 或列出的是 `EFI/` → 不是 root(`EFI/` 那个是 ESP);
- 报 `Filesystem is ntfs` 之类并列出 `Windows/` → 是 `C:`,别往里写。

#### 1.2 路一:修好 GRUB,继续进 Linux

适用:想进 Linux 排障,或想先修好再决定。**逐条命令,顺序不要换**:

```
ls                                   # 先按 1.1 找出 Ubuntu root,假设是 (hd0,gpt5)
set root=(hd0,gpt5)
set prefix=(hd0,gpt5)/boot/grub
insmod normal
normal
```

要点与判据:

- `set prefix` 必须指向**含 `grub.cfg` 与 `x86_64-efi/` 模块目录**的位置。本方案是 `(hd0,gpt5)/boot/grub`;若某台设备给 `/boot` 单独分了区,则指向该分区的 `/grub`。
- `echo $prefix` 回显应与设定一致——回显不对说明上一条命令没生效(常见于设备名打错)。
- `insmod normal` 报 `file not found` → `prefix` 指错分区/路径,回上一步重找,不要继续敲 `normal`。
- `normal` 之后应出现正常的 GRUB 菜单,能选到 Ubuntu 与 Windows 两项。
- **这是临时修复**:重启照旧。进系统后按 1.4 做持久修复。

#### 1.3 路二:直接回 Windows(推荐优先试)

目标不是"修好 Linux",而是"先拿到一个能用的系统"。**优先级高于路一**:Windows 侧有图形界面、有 `bcdboot`、有 `backup-esp.ps1` 与 `verify-baseline.ps1`,在 Windows 里收复引导比在 GRUB 命令行里盲敲安全得多。

```
insmod chain                                                  # 若提示 chainloader 不可用,先加载 chain 模块
search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
chainloader /EFI/Microsoft/Boot/bootmgfw.efi
boot
```

要点与判据:

- `search --file ...` 成功即把 `root` 指向 ESP(找到文件不报错)。报 not found → 先 `ls (hd0,gpt1)/EFI/Microsoft/Boot/` 确认路径大小写与拼写(UEFI 的 FAT 卷大小写不敏感,但 `EFI` 是目录、`Microsoft` 是子目录,层级不能少);
- `insmod chain` 报 `file not found` → `chain` 模块要从 `$prefix` 下加载,`$prefix` 未修好时它必然失败:先按 1.1 / 1.2 把 `set prefix` 指到 root 的 `/boot/grub`(即 `set prefix=(hd0,gpt5)/boot/grub`)再试;仍不行就改走固件启动菜单(`BOOT_MENU_KEY` 选 `Windows Boot Manager`),不要在这里硬敲;
- `chainloader` 提示载入成功即可;Secure Boot 下这里**应该**能通过——用的是微软签名链里的 `bootmgfw.efi`,在固件看来与正常启动 Windows 无异(设计 3.3);
- 报 `invalid signature` / `Verification failed` → 见"失败处理"中 Secure Boot 一行;
- `boot` 后直接进 Windows,不需要任何手工选择;
- 这条路**不改写任何东西**:不写 ESP、不改 NVRAM、不改 `BootOrder`。进 Windows 后再做步骤 2 或步骤 3 的复盘与修复。

#### 1.4 进系统之后的收尾(否则下次开机照旧)

1. **先确认现场**:在 Windows 管理员会话跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1)(后面步骤 2 第 4、5 条),确认 `\EFI\Microsoft\` 与 `{bootmgr}` 没被改动;
2. **判断要不要修 Linux 侧**:
   - 只是 NVRAM 条目指向的文件名不对(比如条目写 `grubx64.efi` 而 ESP 上只有 `shimx64.efi`)→ 在 Ubuntu 里用 `sudo efibootmgr -b <编号> -B` **删除该条目**,再从 live 环境用显式盘/分区重建:`sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'`(命令只新建条目,**绝不用 `-o` 调顺序**;口径与 [L3 手册](04-ubuntu.md) 的失败处理一致);
   - 文件真丢了(`\EFI\ubuntu\` 被更新重写或清掉)→ 先走步骤 3 复原 `\EFI\Microsoft\`,再按步骤 3.1(b) 的具体步骤从 live 环境重建 Ubuntu 引导文件:`chroot` 后 `grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu`(它自建 NVRAM `ubuntu` 条目,不要再手工 `efibootmgr -c`)+ `update-grub`,最后断言 `BootOrder` 首位仍是 `Windows Boot Manager`、`ubuntu` 在末尾(若出现重复条目,按 3.1 用 `sudo efibootmgr -b <编号> -B` 清理);
3. **不要顺手改启动顺序**:修完 `BootOrder` 首位必须仍是 `Windows Boot Manager`,`ubuntu` 在末尾(设计 8-A)。顺序被改动的场景走步骤 6;
4. **记一笔**:把这次故障的现象、层级结论、做过的命令写进 [checklists/rollback.md](../checklists/rollback.md) 第 2 节的备注。

### 2. 从 Windows 侧修复引导(挂载 ESP 与 `bcdboot` 重建)

适用:Windows 进不去(`winload`/BCD 损坏、`bootmgfw.efi` 被清理),但分区还在、`C:\Windows` 还在。这是"让 Windows 先活过来"的标准动作,也是"Windows 更新重写 ESP"事故(设计第 9 节)的正面对策。

执行环境:**Windows 管理员会话**,或 Windows 安装 U 盘进入的**修复模式 → 命令提示符**(WinRE;界面语言与盘符可能与系统内不同,`C:` 不一定是系统盘)。

1. **挂载 ESP**:

   ```powershell
   mountvol S: /s
   ```

   判据:`S:\` 里能看到 `EFI\` 目录。`S:` 被占用时换一个空闲盘符(如 `T:`),后续命令同步替换。

2. **核对要不要先做基线复原**:挂载后先看 `S:\EFI\Microsoft\` 与 `S:\EFI\ubuntu\` 是否齐全——若 `\EFI\Microsoft\` 已被清空,直接跳到步骤 3(基线回滚),先复原文件再重建;若齐全、只是 BCD 坏了,继续本步骤。

3. **重建 Windows 引导**:

   ```
   bcdboot C:\Windows /s S: /f UEFI
   ```

   - `C:` 是**含 `\Windows` 的那个卷**;WinRE 里盘符常变(可能是 `D:`)。先 `dir C:\Windows\System32\winload.efi` 之类确认,再执行。**盘符搞错会往错的卷上写引导文件**;
   - 命令成功即无 `Failure when attempting to copy boot files` 之类报错;
   - `bcdboot` 会从 `C:\Windows\Boot\EFI` 复制 `bootmgfw.efi`,并**重建 `\EFI\Microsoft\Boot\BCD`**——所以"ESP 逐文件哈希与基线一致"这条判据在此场景下**降级为参考信息**:这两个文件的差异是**预期**,不作为失败判据。判据改为"**Windows 能正常启动 + `{bootmgr}` 的 `path` 与基线一致 + `BootOrder` 首位未变**"(口径与 [checklists/rollback.md](../checklists/rollback.md) 第 4 节一致,不另立标准);
   - `\EFI\ubuntu\` 不受 `bcdboot` 影响,不要顺手删它。

4. **卸载 ESP**:

   ```powershell
   mountvol S: /d
   ```

   判据:该盘符不再被占用,ESP 内容未被后续写操作污染。

5. **复核与留档**:

   ```powershell
   bcdedit /enum firmware                     # BootOrder 首位 与 {bootmgr} 的 path
   powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
   ```

   - 判据(与 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 输出的四项一一对应):① `BootOrder` 首位为 `Windows Boot Manager`(与 `baseline\02-firmware-entries.txt` 一致);② `\EFI\Microsoft\` 与 `baseline\02-esp-backup\manifest.sha256` 逐文件比对的差异,按第 3 条的"预期差异"解释并写进备注(`bcdboot` 会重写 `bootmgfw.efi` 与 `BCD`);③ `{bootmgr}` 的 `path` 与 `baseline\02-firmware-entries.txt` 一致;④ BitLocker 状态有变化即转人工;
   - 把巡检输出连同这次救援的说明记入 `baseline/`(或清单备注);
   - 连续重启 3 次都直接进 Windows,才算这一步收尾(设计 8-A)。

### 3. 第三选择:基线回滚(ESP 还原 + `bcdboot` + NVRAM 清理)

适用:**引导层损坏而系统分区完好**——ESP 上的引导文件被删改(Windows 更新重写 ESP、误删 `\EFI\ubuntu\`(按 3.1 处置)、`\EFI\Microsoft\` 与基线不一致),但 `C:`、`D:`、Linux 分区都在、数据都在。设计 4.8 的"第三选择"就是这一条:**不是重装**。

这一节只做勾选级指引,完整命令与判据以 [L2 手册](03-preflight.md)"回滚"第 1 条为准(**避免同一段命令两处维护**),与 [checklists/rollback.md](../checklists/rollback.md) 第 4 节逐项对应:

1. **校验备份完整性**:逐行核对 `baseline\02-esp-backup\manifest.sha256` 与备份树里的文件哈希(`Get-FileHash -Algorithm SHA256`)。备份与清单由 [backup-esp.ps1](../scripts/windows/backup-esp.ps1) 生成(清单格式见该脚本说明);备份本身坏了,这一条路就不成立;
2. **挂载 ESP**:`mountvol S: /s`;
3. **还原文件树**:`robocopy baseline\02-esp-backup\EFI S:\EFI /E` —— **只复制 `EFI\` 子树**;`manifest.sha256` 是清单文件,不属于 ESP 内容,不得复制回 ESP。备份树里**没有** `EFI\ubuntu\`(它不在 L2 基线里,见 3.1),这一行只复原 `\EFI\Microsoft\` 等内容;
4. **重建 Windows 引导**:`bcdboot C:\Windows /s S: /f UEFI`(与步骤 2 同一命令,判据同步骤 2 第 3 条);
5. **卸载 ESP**:`mountvol S: /d`;
6. **清理 NVRAM 残留条目**:删掉指向已不存在文件的条目(`bcdedit /enum firmware` + `bcdedit /delete {identifier}`,或 live 环境 `sudo efibootmgr -b <编号> -B`)。**用删除代替改顺序**——任何情况下都不用 `efibootmgr -o` / `displayorder`(I2);
7. **复查四条不变量**并重跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1);② 若因 `bcdboot` 报差异,按步骤 2 第 3 条的"预期差异"解释;
8. **连续重启 3 次**都默认进 Windows,需要 Linux 时用一次性入口。

**与步骤 2 的分工**:步骤 2 是"`\EFI\Microsoft\` 齐全、只重建 BCD";步骤 3 是"`\EFI\Microsoft\` 被删改、先用基线把文件树放回去再重建"。两者最后都收敛到同一套判据;涉及 `\EFI\ubuntu\` 的部分见 3.1(基线里没有它)。

#### 3.1 `\EFI\ubuntu\` 不在 L2 基线里:两条真实来源

**`\EFI\ubuntu\` 不在 L2 基线清单里**(`baseline\02-esp-backup\` 由 L2 预检产出,而 L2 生成于装 Ubuntu **之前**,产出阶段见 [baseline/README.md](../baseline/README.md);[L3 手册](04-ubuntu.md) 的验证第 2 行已写死同一口径:"清单里 `EFI/ubuntu/` 属新增,不在基线行内")。**所以不能用 `baseline\02-esp-backup\EFI\ubuntu\` 还原 Ubuntu 引导文件——那个目录根本不存在**;基线只能复原 `\EFI\Microsoft\` 相关内容,固件条目现状看 `baseline\02-firmware-entries.txt`。

`\EFI\ubuntu\` 被清掉或损坏时,只有两条真实来源(任何依赖 L2 基线的写法都无效):

**(a) 做过 L5 主动退役备份的** → 用 `D:\dbk-l5-backup\02-esp-backup\EFI\ubuntu\`(那是 [L5 退役手册](06-decommission.md) 步骤 2 写出的备份;该备份树含 `EFI\Microsoft\` 与 `EFI\ubuntu\` 两棵子树,是唯一"含 ubuntu 的现成备份"):

```powershell
mountvol S: /s
robocopy D:\dbk-l5-backup\02-esp-backup\EFI\ubuntu S:\EFI\ubuntu /E
mountvol S: /d
```

若 `ubuntu` 的 NVRAM 条目也已丢失(被清过),补建一条:`sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'`(盘与分区号按 `baseline/02-partitions.txt` 替换),建完立刻断言 `BootOrder` 首位仍是 `Windows Boot Manager`。

**(b) 没有现成备份的** → 从 live 环境重建:挂上 root 与 ESP、`chroot` 后重装 GRUB 的 EFI 文件(**条目由 `grub-install` 自动新建**,见下)。

```bash
# live 环境(必须以 UEFI 启动:先 ls /sys/firmware/efi 确认存在;CSM/Legacy 启动的 U 盘会让 grub-install 走非 EFI 目标)
# 盘与分区号按 baseline/02-partitions.txt 替换
sudo mount /dev/nvme0n1p5 /mnt                  # Ubuntu root
sudo mount /dev/nvme0n1p1 /mnt/boot/efi         # ESP
for d in dev dev/pts proc sys run; do sudo mount --rbind /$d /mnt/$d; done
sudo chroot /mnt /bin/bash
grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu   # 它自己会建 NVRAM ubuntu 条目,不要再手工 efibootmgr -c(会多一条重复项)
update-grub
exit
sudo umount -R /mnt
sudo efibootmgr -v
```

若 `grub-install` 结束时提示未能写入 NVRAM(或 `efibootmgr -v` 里看不到 `ubuntu`),用 `sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'` 补建一条(盘/分区按 `baseline/02-partitions.txt` 替换),再断言 `BootOrder` 首位仍是 `Windows Boot Manager`。该命令仍以 0 退出但只警告不建条目的情况确实存在(非 UEFI 启动、efivars 不可写),所以这一句是兜底而非可选步骤。

若上面跑完发现 `efibootmgr -v` 里出现**重复的 `ubuntu` 条目**(重装/换 ESP 后的常见残留),用 `sudo efibootmgr -b <编号> -B` 删掉多余项——保留 `BootOrder` 里实际生效的那一条。

判据与纪律:

- `/boot/efi/EFI/ubuntu/` 下出现 `shimx64.efi`、`grubx64.efi` 与 `grub.cfg`(与 `Microsoft/` 并存);
- 建完条目**立刻断言**:`BootOrder` 首位仍是 `Windows Boot Manager`、`ubuntu` 在末尾;顺序不对就走步骤 6 处置,**不用 `efibootmgr -o`**(I2);
- 全程保持 Secure Boot 开启:走的是 shim 签名链(设计 3.3),不自签密钥、不关 Secure Boot;`grub-install` 不加 `--no-nvram`(那是为了"不写 NVRAM",与 Secure Boot 无关,本手册也不需要这种变通——NVRAM 条目正是我们要的);
- **不要手工把别的机器或别的系统的 `\EFI\ubuntu\` 文件抄进来**:`shimx64.efi` 与 `grubx64.efi` 是一对,版本错配会被 Secure Boot 拒载(处置见"失败处理"的 `invalid signature` 一行)。

### 4. 办法一:只重装 Windows(仅格式化 `C:`)

适用:`Windows` 系统分区已损坏(引导修好了也进不去、`C:` 文件系统报错、系统文件大面积损坏),而 `D:` 数据与 Linux 侧完好。设计 4.8 办法一;清单同 [checklists/rollback.md](../checklists/rollback.md) 第 3.1 节。

**第一号禁令**:只格式化 `C:`(200GiB NTFS)。`D:`、Linux 各分区(root 100GiB、`/snapshots` 15GiB)、ESP、MSR、WinRE 一律不动;**禁止"删除所有分区"**。

五步:

1. **备份与准备**:能进系统就先把"动手前"的现场留一份——用 [backup-esp.ps1](../scripts/windows/backup-esp.ps1) 写到仓库外(`-OutDir D:\dbk-l5-backup`,不要覆盖 `baseline\`,那是 L2 基线的家);`D:` 上的数据不参与格式化,但仍建议把最关键的文档另拷一份到外置盘。BitLocker 恢复密钥必须在手。
2. **用官方 Windows ISO 引导,进入"自定义安装"**:在分区列表里能列出磁盘与全部分区(看不到驱动器 → 回 [L0 手册](01-firmware.md) 核查存储控制器模式为 AHCI / NVMe、VMD 关闭,不要在这个界面上反复重试)。
3. **逐分区核对后,只格式化 `C:`**:安装界面里按大小与类型核对(200GiB NTFS = `C:`、≈635GiB NTFS = `D:`、100GiB + 15GiB ext4 = Linux 侧、2GiB FAT32 = ESP、16MiB = MSR、1GiB = WinRE,与 `baseline\02-partitions.txt` 对账)。**逐个分区看清楚再点**,不确定就退回去重看。
4. **让安装程序在 ESP 上重建 Windows 引导**:它会写 `\EFI\Microsoft\` 与 BCD,并可能覆盖 `\EFI\BOOT\bootx64.efi`(属正常;`\EFI\ubuntu\` 不受影响)。
5. **首启收尾**:关 Fast Startup 与休眠、重新完成 KMS 激活、按 [L1 手册](02-windows.md) 重做已知文件夹到 `D:` 的重定向(这是重装后最容易漏的一项——数据落在 `C:` 就等于下次重装再丢一次);然后复查四条不变量并用厂商菜单键验证 Ubuntu 仍能启动。

风险与处置:

| 风险 | 后果 | 处置 |
|---|---|---|
| 误格 `D:` 或 Linux 分区 | **灾难性、不可逆** | 靠第 3 步的逐分区核对;已经格错就停手,`D:` 只能靠外部备份恢复,Linux 侧按步骤 5 重装并把 `/snapshots` 一起重建 |
| 安装程序新建恢复分区 / 挪动 WinRE | 分区表偏离计划(占掉预留空间) | 属设计第 9 节已登记的版本敏感性风险:**尺寸偏差可接受**(唯一不可削减的是 ESP),把偏差写进 `baseline/` 与设备参数表即可,不要为了"回到计划"去挪分区 |
| ESP 被安装器改写 | `\EFI\ubuntu\` 可能被清掉 → 重启停 `grub rescue>` | 装完先挂载 ESP 看 `S:\EFI\ubuntu\` 是否还在;不在则按步骤 3.1 的两条来源重建(**`\EFI\ubuntu\` 不在 L2 基线清单里——L2 基线生成于装 Ubuntu 之前,不能用 `baseline\02-esp-backup\EFI\ubuntu\` 还原**),再按该节的结论补建/清理 NVRAM 条目(不用 `-o`) |
| BitLocker 索要恢复密钥 | 进不去系统 | 密钥在手直接输入;`C:` 重装后保护状态会回到"未加密或待启用",按设计第 9 节登记状态变化,不要在救援期间顺手开新保护 |

### 5. 办法二:只重装 Ubuntu(仅格式化 root)

适用:Ubuntu root 损坏(内核/文件系统层面进不去,`fsck` 修不好),而 Windows 侧与 `D:` 完好。设计 4.8 办法二;清单同 [checklists/rollback.md](../checklists/rollback.md) 第 3.2 节。

**第一号禁令**:**绝不勾选"格式化 ESP"**。误格 ESP 会同时清空 `\EFI\Microsoft\`,让 Windows 也进不去——这是**全流程最危险的一步**(设计 4.8 办法二的风险行、验收 D 组的重点)。

五步:

1. **抢救 Linux 侧数据**:root 一格式化,`~` 下的代码/密钥/dotfile 与 `/snapshots` 里的快照就没了(共享盘上的文档类数据不在其中,设计 5.3)。能进 live 环境就先把 `~` 里要留的东西 `rsync -a` 到 `/mnt/shared/` 或外置盘。**先从 live 环境里看到 Windows `C:` 与 `D:` 都在、分区数与 `baseline\02-partitions.txt` 一致**,确认这是"root 损坏"而不是"分区表故障"。
2. **用 Ubuntu 安装 U 盘引导,选"手动分区"**:分区界面能看到全部分区(只看到 U 盘 → 回 [L0 手册](01-firmware.md) 核查控制器模式);目标磁盘与参数表 `DISK` / `DISK_MODEL` / `DISK_SIZE` 一致(防选错盘)。
3. **只格式化 root 并挂 `/`**:只有 root 那一行(ext4,100GiB)带"格式化"勾选;`/snapshots`(ext4,15GiB)**挂上但不格式化**(保留历史快照);`C:` / `D:` / MSR / WinRE 不参与挂载,一律不动。**逐分区核对后再点下一步**。
4. **ESP 复用挂 `/boot/efi`,绝不格式化**:ESP 那一行的"格式化"必须**未勾选**。安装器会往 `\EFI\ubuntu\` 写入 shim/grub(与 `\EFI\Microsoft\` 并存),期间**不改 `BootOrder`**(I2)。判据:装完 `/boot/efi/EFI` 下同时存在 `Microsoft` 与 `ubuntu` 两个目录。
5. **首启收敛与复检**:按 [L4 手册](05-first-boot.md) 重放驱动、挂载、家目录重定向、时间、蓝牙与健壮性配置(`baseline/04-first-boot.md`、`baseline/04-robustness.md` 的判据逐项复现);然后复查四条不变量,连续重启 3 次都默认进 Windows。

风险与处置:

| 风险 | 后果 | 处置 |
|---|---|---|
| **误勾"格式化 ESP"** | **同时毁掉 Windows 引导**(`\EFI\Microsoft\` 被清空),两系统一起进不去 | **在点"安装/下一步"之前退回去取消勾选,这一步是无损的**;若已经装完才发现,走步骤 3 的基线回滚(`\EFI\Microsoft\` 从 `baseline\02-esp-backup\EFI\` 放回 + `bcdboot`),`\EFI\ubuntu\` 按步骤 3.1 的两条来源重建(它不在 L2 基线里),并把这次记为严重偏差 |
| 误格 `C:` 或 `D:` | 灾难性 | 靠第 3 步的逐分区核对;发生即停手,按步骤 4 重装 Windows,`D:` 只能靠外部备份 |
| `/snapshots` 被一起格式化 | 丢失历史回滚点(R1) | 第 3 步明确"挂上但不格式化";已经格式化则重建分区并按 [L4 手册](05-first-boot.md) 重新启用快照 |
| 装完启动顺序被改 | 违反 I1 | **只在固件设置界面**把 `Windows Boot Manager` 改回首位;固件没有顺序选项时走步骤 6 |

### 6. 启动顺序偏差复原(固件没有顺序选项时)

适用:`BootOrder` 首位变成了 `ubuntu`(重启默认进 Ubuntu),而固件设置界面**只提供"删除条目"、不给顺序调整**。这是 [L3 手册](04-ubuntu.md) 失败处理里"重启默认进了 Ubuntu"一行所指的偏差分支,也是 [L5 退役手册](06-decommission.md) 步骤 1 的同一支路——**口径必须一致,本步骤以那两处为准**。

铁律:**不得用 `efibootmgr -o`**(I2 与交接规则第 5 条)。固件才是永久启动顺序的权威,NVRAM 与固件视图不一致时会被固件在下一次开机改回去,用工具"赢了"只是暂时现象。这里的次序调整手段是**删除条目、让固件回落到 Windows**,而删除本身就是一次 NVRAM 变更,所以**必须先有备份**——次序不可颠倒:

1. **记录现状**(在 Ubuntu 里,只读):`sudo efibootmgr -v`,抄下 `BootOrder:` 整行、`Windows Boot Manager` 条目编号、`ubuntu` 条目编号与 loader 路径,并写明本次偏差现象(什么时间、哪次操作/更新之后开始默认进 Ubuntu);
2. **第一段:回 Windows 做备份**。用厂商 `BOOT_MENU_KEY` 选 `windows`,或执行 [reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh)(一次性 `efibootmgr -n`,不改 `BootOrder`)。进 Windows 后在管理员会话里:

   ```powershell
   # 仓库根目录
   powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir D:\dbk-l5-backup
   powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
   ```

   **这份备份没做完,就不要往下走**。
3. **第二段:回 Ubuntu 删条目**。用 `BOOT_MENU_KEY` 选 `ubuntu`,或执行 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(默认空跑,确认后去掉 `-WhatIf`;一次性 `BootNext`,不改顺序)。进 Ubuntu 后:

   ```bash
   sudo efibootmgr -b <ubuntu 条目编号> -B      # 删除该条目,让固件回落到 Windows
   sudo efibootmgr -v                            # 确认条目已消失
   ```

   删完再 `sudo efibootmgr -v` 确认 `BootOrder` 首位对应 `Windows Boot Manager`。
4. **第三段:重启验证**。重启回 Windows,连续重启 3 次,判据:
   - 每次都直接进 Windows,不出现 `grub>` / `grub rescue>`(设计 8-A);
   - 与 `baseline/02-firmware-entries.txt` 逐项对比:**只允许"`ubuntu` 条目从首位退到后面或被删除"**,不允许 `\EFI\Microsoft\` 相关内容出现变化;
   - 需要 Linux 时仍能进:用 `BOOT_MENU_KEY`,或在 Windows 侧跑 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)。**这一步是零代价、可逆的**:Linux 没有被删,只是不再默认。
5. **偏差登记**:把这次修动写进 [checklists/rollback.md](../checklists/rollback.md) 的备注,并回写[入口文档](00-overview.md)的设备参数表(记明"该机型固件无顺序选项,处置方式是删条目回落"),避免下一台同型号设备重复踩;若这次删掉了 `ubuntu` 条目,在备注里一并写明"条目已删、进 Linux 需 `BOOT_MENU_KEY` 或重新 `efibootmgr -c` 新建"。

### 7. 周期性巡检(每次 Windows 大版本/累积更新之后)

**Windows 更新是这台设备上周期性地改写 `\EFI\Microsoft\` 与固件启动项的唯一外力**(Ubuntu 侧的 shim / grub 包更新也会周期性重写 `\EFI\ubuntu\`,但那是 Linux 引导自身、不碰 Windows 侧;2024-08 的 SBAT / Secure Boot DBX 事件就是"更新动引导"这一类的极端形态,见设计 7.1)。所以每次大版本升级或累积更新之后,重跑一次基线核对:

```powershell
# 管理员 Windows PowerShell,仓库根目录
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
```

核对四项(与脚本输出的 ①②③④ 一一对应,判据同步骤 2):

| # | 核对项 | 判据 |
|---|---|---|
| 1 | `BootOrder` 首位 | 仍是 `Windows Boot Manager`(与 `baseline\02-firmware-entries.txt` 一致) |
| 2 | ESP 目录树是否被改动 | `\EFI\Microsoft\` 与 `baseline\02-esp-backup\manifest.sha256` 逐文件一致(更新之后此处的差异要当回事,先判断是"Windows 更新正常写入"还是"引导被接管") |
| 3 | `{bootmgr}` 的 `path` | 与 `baseline\02-firmware-entries.txt` 一致;变化即提示人工介入 |
| 4 | `BitLocker` 状态 | 与 `baseline\02-preflight-report.md` 的记录一致;变化即提示人工介入 |

脚本退出码 0 = "巡检通过",1 = "需人工介入";输出留档到 `baseline/`(或清单备注)。**巡检通过不等于可以不动**:四项里任何一项报差异,先按步骤 0 判断层级,再按步骤 2 或步骤 3 处置。

**SBAT / Secure Boot DBX 事故(2024-08,微软已确认)**:微软通过 Windows 更新推送的 DBX 更新会把若干 Linux 引导器的 SBAT 版本判为"过旧",在部分双系统设备上更新后无法引导 Linux。现象与处置:

- **现象**:更新并重启后,固件直接跳过 `ubuntu` 条目,或停在 `grub>` / `grub rescue>`,或出现 `Verification failed: (0x1A) Security Violation` / `bad shim signature` 一类拒载提示;Windows 侧一切正常(设计第 9 节、[入口文档](00-overview.md)"已知事故类型");
- **处置**:清理固件下发的 SBAT 策略——在 Windows 侧清除注册表中 `SbatLevel` 相关值(与 [入口文档](00-overview.md) 第 1 条一致);在 Linux 侧立即可用的是 `sudo mokutil --set-sbat-policy delete`(需要 `mokutil` 可用;执行后重启生效)。清完策略再按步骤 1 或步骤 3 复原引导。**具体注册表键值名与命令以微软 / Ubuntu 官方公告为准**;
- **缓解**:①**常备 Ubuntu 安装 U 盘**并在装机结束后不回收、保持"已验证可用"(R4)——引导被拒时从 U 盘进 live 环境修,而不是原地重装;②**不要关闭 Secure Boot 解决问题**:关闭它会把 L4 的预签名 NVIDIA 包路径一起破坏,且不是本方案的做法(设计 3.3);
- **检**:事故本身不违反 I1-I4,处置完按步骤 7 的巡检四项复核一遍。

### 8. 排障纪律(出事后最容易犯的四个错)

**第一条:不要反复长按电源强制重启。** 强断会把"一次引导故障"升级成"文件系统损坏",最后两个系统一起进不去(设计第 9 节风险行、评论区 274 赞的那个案例)。替代手段:

- 优先切 TTY:`Ctrl + Alt + F3`(桌面崩了但内核还活着时最有用);
- 内核层面无响应时用 **REISUB(SysRq)** 安全重启:依次按 `Alt + SysRq + R`、`E`、`I`、`S`、`U`、`B`(键盘上 SysRq 常与 `PrtSc` 同键)。顺序本身是"交出键盘 → 终止进程 → 落盘 → 只读重挂 → 重启",每一步都在为下一步争取干净状态。**注意 Ubuntu 默认 `kernel.sysrq=176`,只开放 `S` / `U` / `B` 三位,`R` / `E` / `I` 往往空操作**(不报错也没反应):这种情况下直接按 `S -> U -> B`,同样达成"落盘 + 只读重挂 + 重启",前两步跳过即可;确实需要完整 REISUB 时,先把 `kernel.sysrq` 设为 `1`(写进 `/etc/sysctl.d/` 或内核命令行,重启后生效)再按六键;
- **如果已经反复强断过**:下次启动前先跑一次文件系统检查(ext4 在挂载次数到阈值时会自动跑,也可在 live 环境手动 `sudo fsck -f /dev/nvme0n1p5`,设备名按 `baseline/02-partitions.txt` 替换),把损坏先修掉再谈别的。

**第二条:桌面崩了不等于系统坏了。** 先拿到"还能用"的入口,再谈修复:

- **SSH 进去**(健壮性 R7,常开 `openssh-server`):从另一台机器登录,看 `journalctl -b -1 -p err`(R5,journald 持久化)——桌面挂死时这条通道几乎总是活的;
- 没有第二台机器时切 TTY(`Ctrl + Alt + F3`)在本地看同样的日志;
- 必要时在 GRUB "Advanced options" 里选**旧内核**启动(R3),这是驱动/内核翻车时最省事的回滚点;
- 真到了"内核也进不去"才考虑重装——而且先走步骤 0 的分类判断。

**第三条:两个系统一起出问题,先查硬件。** 两系统**运行期互不影响**,只有引导层会互相干扰(设计第 9 节)。表现是"两系统一起死机/蓝屏/随机重启"时,按硬件 triage:

- 内存:跑 `memtest86+`(Ubuntu 安装 U 盘的 GRUB 菜单里就有这一项),至少过一遍完整测试;
- 磁盘:`sudo smartctl -H /dev/nvme0n1`(R9,`smartmontools` 在 L4 已装),出现 FAILED 就先换盘再谈装系统;
- 温度与电源:满载温度、供电不足导致的随机重启,在装系统时也会表现为"装到一半失败";
- 结论是硬件故障时,**不要格式化任何分区**——修硬件不会让系统数据消失,格式化才会。

**第四条:不要为了迁就驱动而降级发行版。** 显卡/网卡/键盘不被识别时,优先级是:**先换内核(HWE 内核栈)→ 再换驱动版本**,不降发行版(设计 3.17 被否方案、11.1 第 10 条)。降发行版换来的是更短的支持期与更差的新硬件兼容性,问题往往在半年后以更难看的形式回来。

## 验证

逐行核对,全部通过才算救援闭环。带 `____` 的空格要填实测值。

| # | 检查项 | 判据 |
|---|---|---|
| 1 | 崩溃层级有文字结论 | 结论是"引导层 / 系统分区 / 硬件"三选一,并附判据(步骤 0.2 里回答了哪几条、实测值是什么);**引导层场景下未执行任何格式化** |
| 2 | 默认启动项与重启实测 | `bcdedit /enum firmware`(或 `sudo efibootmgr -v`)的 `BootOrder:` 第一项对应 `Windows Boot Manager`;连续重启 **3 次**都默认进 Windows(设计 8-A) |
| 3 | Windows 可正常启动 | 进桌面无异常;Fast Startup 与休眠处于关闭状态:`powercfg /a` 里"休眠"与"快速启动"均显示不可用,且 `reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled` 为 `0x0`(与 [L1 手册](02-windows.md) 验证第 5 行、[L4 手册](05-first-boot.md) 1.1 第 1 条同一颗粒度);若走过步骤 4,激活状态与已知文件夹重定向已重做 |
| 4 | Windows 引导未被污染 | `\EFI\Microsoft\` 与 `baseline\02-esp-backup\manifest.sha256` 逐文件一致;若过程中执行过 `bcdboot`,`bootmgfw.efi` 与 `BCD` 的差异属**预期**,以"能正常启动 + 第 5 行的 `path` 一致"为准([verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 的 ② 项) |
| 5 | 引导路径未被篡改 | `{bootmgr}` 的 `path` 与 `baseline\02-firmware-entries.txt` 一致(verify-baseline.ps1 的 ③ 项) |
| 6 | Linux 侧可用且不抢默认 | `\EFI\ubuntu\` 仍在 ESP 上;`ubuntu` 条目位于 `BootOrder` 末尾(或按已登记的偏差处理);用 `BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) 能进 Ubuntu,且重启后默认仍是 Windows |
| 7 | 不变量口径 | 全程未执行 `efibootmgr -o`,也未执行 `bcdedit /set {fwbootmgr} displayorder`(I1/I2);`\EFI\Microsoft\` 未被第三方接管(I3) |
| 8 | 走重装路径时"只格一块" | 只有目标系统分区被格式化:另一系统分区、ESP、MSR、`D:`、`/snapshots` 的偏移与大小与 `baseline\02-partitions.txt` 一致(可用 `Get-Partition -DiskNumber 0` 与图形磁盘管理双向核对) |
| 9 | 数据在位 | `D:` 上的文档类数据可读;`/mnt/shared/` 挂载正常(`ntfs3`);走过步骤 5 时 `/snapshots` 挂载可见(`df`) |
| 10 | 巡检留档 | 有 Windows 更新的场景下,`verify-baseline.ps1` 的输出已留档,四项核对结论与偏差写明;结论文字为"巡检通过"或"需人工介入(原因:____)" |
| 11 | 记录到位 | [checklists/rollback.md](../checklists/rollback.md) 对应节的勾选与备注已填;偏差已回写[入口文档](00-overview.md)设备参数表 |

## 失败处理

| 现象 | 立即动作 |
|---|---|
| `ls` 列不出任何分区(`(hd0)` 之后再无 `(hdX,gptY)`) | `insmod part_gpt` 后重试;仍不行说明 GRUB 的核心镜像/模块也丢了——不要在这里硬敲,改走步骤 1.3 直接回 Windows,或从 live U 盘进环境处理 |
| `insmod normal` 报 `file not found` | `prefix` 指错分区/路径。回步骤 1.1 用 `ls (hdX,gptY)/` 逐个分区重找含 `/boot/grub` 的那个;**不要**改成 `normal` 硬试,也不要 `set prefix` 到 ESP:`/EFI/ubuntu` 里**有**一个 stub `grub.cfg`,但没有 `x86_64-efi/` **模块目录**,`normal` 与各模块都加载不了(`insmod normal` 会报 `file not found`) |
| `chainloader` 报 `unknown command` | 先 `insmod chain` 再重试;`insmod chain` 报 `file not found` 时,`chain` 模块来自 `$prefix`,按 1.1 / 1.2 把 `set prefix` 指到 root 的 `/boot/grub` 再试;仍不行就从固件启动菜单选 `Windows Boot Manager`,进 Windows 后按步骤 2 修 |
| `chainloader` / 启动 Windows 报 `invalid signature`、`Verification failed`、`bad shim signature` | 属 Secure Boot 拒载:**不要关闭 Secure Boot、不要自签密钥**(设计 3.3)。先核查固件里 `Secure Boot Mode` 是否被改成 `Custom`(应为 `Standard`);用的是官方 ISO 吗?shim 是否在微软签名链内?SBAT 类事故按步骤 7 的处置清策略 |
| `bcdboot` 报 `Failure when attempting to copy boot files` | 三种常见原因依次查:① `C:` 盘符写错(WinRE 里先 `dir` 确认含 `\Windows` 的卷);② ESP 没挂上或不是 FAT32(`S:\EFI` 不可见);③ ESP 空间不足(`dir S:\` 看剩余;2GiB 的目标尺寸下极少见)。修好后重跑,不要改别的判据 |
| `mountvol S: /s` 报错或 `S:\` 里没有 `EFI\` | 换一个空闲盘符(`T:` 等);仍失败则说明 ESP 分区本身不可用(分区表问题)→ 停手,回步骤 0 重新判断层级,可能已是"系统分区/分区表"层 |
| 装完 Windows 重启进了 `grub rescue>` | `\EFI\ubuntu\` 被安装器清掉或 `ubuntu` 条目还在 `BootOrder` 前面。先按步骤 1.3 回 Windows → 按步骤 3 复原 `\EFI\Microsoft\` → `\EFI\ubuntu\` 按步骤 3.1 的两条来源重建(**它不在 L2 基线清单里:L2 基线生成于装 Ubuntu 之前,`baseline\02-esp-backup\EFI\ubuntu\` 不存在**)→ 条目按步骤 6 处置(**不用 `-o`**) |
| 装完 Ubuntu 重启直接进 Windows,没看到 Ubuntu 入口 | **通常是正常形态**:`BootOrder` 首位未变(I1)。用 `BOOT_MENU_KEY` 选 `ubuntu` 即可;条目缺失时从 live 环境 `sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'` 新建(盘/分区按 `baseline/02-partitions.txt` 替换;**不用 `-o`**),随后立刻复读 `efibootmgr` 断言首位仍是 Windows |
| 安装器用了"删除所有分区" | **在点"安装/下一步"之前退回去**——这一步还是无损的。若已经装完:两个系统分区与 ESP 都需重建,先按步骤 3 复原 ESP 引导文件,再按步骤 4(Windows)与步骤 5(Ubuntu)分别重装,并把这次记为严重偏差 |
| `\EFI\Microsoft\` 与基线不一致(巡检或救援中报差异) | **立即停手**:说明 ESP 被改写,I3 已被违反。按步骤 3 做基线回滚(ESP 文件树还原 + `bcdboot` + NVRAM 清理),复原并复查后再继续 |
| 更新之后两个系统都进不去,但分区与文件都在 | 典型 SBAT/DBX 事故(步骤 7):从 Ubuntu U 盘进 live 环境,清 SBAT 策略后复原引导;Windows 侧正常时也可以先在 Windows 里清注册表 `SbatLevel` 值再重启 |
| 反复进不去、装系统也失败、两系统一起死机 | 转硬件 triage(步骤 8 第三条):内存检测、`smartctl -H`、温度与电源。**先不要格式化任何分区** |
| 桌面崩了、图形栈起不来 | 先 SSH 进来(R7)或切 TTY(`Ctrl + Alt + F3`)看 `journalctl -b -1 -p err`(R5);必要时在 GRUB "Advanced options" 选旧内核(R3);不要因为驱动问题降级发行版(步骤 8 第四条) |
| 曾经反复长按电源强制重启 | 下次启动前先跑一次 `fsck`(步骤 8 第一条);有报错就先修文件系统,再谈重装 |
| 分不清"该修还是该重装" | 回步骤 0 的分类判断并按 0.1 的判定表执行。默认答案是"先修引导"(设计 4.8 第三选择);**只有系统分区本身损坏才重装** |

## 回滚

分三档,粒度与设计 7.2 一致:

| 粒度 | 本手册对应的场景 | 手段 |
|---|---|---|
| 单步回滚 | 命令敲错(设备名/盘符/`prefix`)、`bcdboot` 盘符写错、装完发现多删了一块分区 | 回到该步骤的"判据"重新做。**注意不可逆项**:分区一旦格式化,数据只能靠外部备份或数据恢复;所以动手前先备份(步骤 4 第 1 条、步骤 6 第 2 条) |
| 阶段回滚 | 决定不修了,把 Linux 撤掉;或重装到一半反悔 | 退役走 [L5 退役手册](06-decommission.md) 的五步(顺序不可更换);重装中途反悔见下文"重装中途反悔"一节 |
| 基线回滚 | ESP 或固件启动项被破坏、引导层损坏而系统分区完好 | 就是本文步骤 3:ESP 文件树还原 + `bcdboot` 重建 + NVRAM 清理;来源是 `baseline/02-esp-backup/` 与 `baseline/02-firmware-entries.txt`(基线只覆盖 `\EFI\Microsoft\` 与固件条目;`\EFI\ubuntu\` 按步骤 3.1 用 L5 备份或 live 重建) |

### 1. 救援后的基线状态(哪份还能用)

| 救援动作 | 旧基线是否仍有效 | 后续动作 |
|---|---|---|
| 只做步骤 1-3(修引导,不改分区表) | **有效**:分区表与固件启动项未变 | 重跑一次 `verify-baseline.ps1` 留档即可;若 `bcdboot` 重建过 BCD,把差异按"预期"记进备注 |
| 只做步骤 6(删 `ubuntu` 条目) | **部分有效**:固件启动项已变(条目少了一条),分区表未变 | 把条目现状写进备注;不要为了"让基线成立"去改 `baseline/02-firmware-entries.txt`——那份记录的是故障前的现场,改了就没有比对意义 |
| 走了步骤 4(重装 Windows,只格 `C:`) | **分区表仍有效**(偏移/大小未变);ESP 内容已变(BCD 重建) | 重跑 `preflight.ps1` 重做 L2 并重新生成 `baseline/02-*`(I4:分区表或固件变更前要有可用基线;此处虽只动了 `C:` 与 ESP,重做一份最省事),再按 [L4 手册](05-first-boot.md) 收敛 |
| 走了步骤 5(重装 Ubuntu,只格 root) | 同上(ESP 的 `\EFI\ubuntu\` 已重写) | 重做 L2 基线 + 按 [L4 手册](05-first-boot.md) 重放配置;`/snapshots` 未格式化时旧快照仍可用 |
| 走了步骤 4 或 5 且**误格了 ESP** | 分区表已变(ESP 被重建) | 先按步骤 3 从 `baseline\02-esp-backup\EFI\` 复原 `\EFI\Microsoft\` 并 `bcdboot`;`\EFI\ubuntu\` **不在 L2 基线清单里**(L2 基线生成于装 Ubuntu 之前),按步骤 3.1 的两条来源重建(有 L5 备份就用 `D:\dbk-l5-backup\02-esp-backup\EFI\ubuntu\`,否则从 live 环境 `chroot` 重建);再重做 L2 基线 |

### 2. 重装中途反悔

| 进行到 | 还能回到什么状态 | 做法 |
|---|---|---|
| 还在安装器的分区界面(没点"安装/下一步") | **什么都没丢**:所有分区数据完好 | 直接退出安装器并重启;这就是"逐分区核对"这一步存在的价值 |
| 只格式化了目标分区、还没开始安装 | 目标系统侧数据已丢,另一侧完好 | 继续装完是最省事的路径(半格不装会让两块系统都不可用);若目标侧有未备份数据,停手先评估数据恢复,不要再往该分区写任何东西 |
| 装完但首次进桌面发现配置缺失 | 系统可用,配置要重放 | 按 [L4 手册](05-first-boot.md) 重放驱动、挂载、重定向、时间、蓝牙、健壮性配置;这属于预期工作量,不是故障 |
| 装完发现 Ubuntu 侧排不进去(条目缺失/顺序异常) | 两系统都在,只是入口不对 | 步骤 6(条目偏差)或步骤 1.4 第 2 条(条目缺失时用 `efibootmgr -c` 新建);**不用 `efibootmgr -o`** |

### 3. 不可逆项清单(动手前先读这一遍)

- **格式化分区不可逆**:`D:` 的文档数据、Linux root 上的代码与密钥、`/snapshots` 里的快照,三者任一被格式化就只能靠外部备份;
- **误格 ESP 会连带毁掉 Windows 引导**,恢复手段是 `baseline\02-esp-backup\`(前提是它可用且未过期);`\EFI\ubuntu\` 不在这份基线里(L2 基线生成于装 Ubuntu 之前),只能按步骤 3.1 用 L5 备份或从 live 环境重建;
- **`bcdboot` 重建的 BCD 与 `bootmgfw.efi` 无法"退回原样"**,只能重建——这也是判据改成"能正常启动 + `{bootmgr}` 的 `path` 一致"的原因;
- **删除 NVRAM 条目后,该系统的"默认启动能力"需要重新建立**(本方案里不需要:进 Linux 一律走一次性入口)。所以删条目永远排在"先备份"之后。
