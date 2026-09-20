# L5:退役(安全撤除 Linux,Windows 仍自动启动)

本文件是 L5 阶段的手册之一(另一份是 [07-rescue.md](07-rescue.md),覆盖故障救援与原地重装)。目标状态、四条不变量(下称 I1-I4)与参数名在[入口文档](00-overview.md)中定义;前提由 [L4 手册](05-first-boot.md)交付;动机与依据见[设计文档](design/00-design.md)第 2 节(I1-I4)、4.6 节(L5 退役五步,**顺序不可更换**)、4.8 节(崩溃后原地重装两法与"第三选择")、第 7 节(故障矩阵 L5 三行)、7.2 节(回滚三粒度)与 8-D 组(可撤除性验收)。

执行时配套使用勾选清单 [checklists/rollback.md](../checklists/rollback.md)(退役、引导救援、原地重装、基线回滚四节),清单逐项有"判据 / 如何确认"列。

三条口径贯穿全文,越界即视为设计缺陷:

- **五步顺序不可更换**:① 在 Ubuntu 中把 `BootOrder` 首项改回 Windows Boot Manager → ② 备份当前 NVRAM 与 ESP 现状 → ③ 重启进 Windows 后删除 Linux 分区 → ④ 清理 NVRAM 中残留的 `ubuntu` 条目 → ⑤ 可选:把腾出的空间扩展进相邻分区(见步骤 5:本方案布局下能扩的是 `D:`,不是 `C:`)。
- **明确禁止:先格式化 Linux 分区再修引导。** 删掉分区的一瞬间,真正消失的是 **root/snapshot 分区上的 `/boot/grub`**(GRUB 的模块与 `grub.cfg` 都在那里);`\EFI\ubuntu\` 子树**通常仍留在 ESP 上**——ESP 在上一步被明确"保留、不碰",是否顺手清理见"失败处理"相应行。引导器真正失效的原因是"GRUB 所在的分区没了 + NVRAM 里的 `ubuntu` 条目仍指向它",所以**必须先把引导归位再删分区**:若那个条目还排在 `BootOrder` 前面,固件会先去找这个已失效的引导器,GRUB 找不到自己的模块与 `grub.cfg`,开机停在 `grub rescue>`。这正是设计第 2 节要防的事故形态,也是"必须先把引导改回 Windows、再删分区"的全部理由。
- **永久启动顺序只在固件设置界面里改**:全程不得执行 `efibootmgr -o`,也不得用等价的 `bcdedit /set {fwbootmgr} displayorder`(I2;口径与 [L3 手册](04-silverblue.md)"失败处理"里"重启默认进了 Ubuntu"一行一致)。一次性切换走 `BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)。

## 目标

退役完成后,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | `BootOrder` 首位是 `Windows Boot Manager`,且连续重启 3 次都默认进 Windows | 本文"验证"第 1、2、8 行 |
| 2 | "动手前"的 NVRAM 与 ESP 现状已另存一份(最后一道保险) | 本文"验证"第 3、4 行 |
| 3 | Ubuntu 的两块分区(root 100GiB 与快照 15GiB)已删除;ESP / MSR / `C:` / `D:` / WinRE 一字未动 | 本文"验证"第 5、6 行 |
| 4 | NVRAM 中不再有指向 `\EFI\ubuntu\...` 的残留条目 | 本文"验证"第 7 行 |
| 5 | 腾出的空间处置有明确结论:并入相邻分区,或按"不相邻不可扩"的实测结论放弃 | 本文"验证"第 9 行 |
| 6 | 全程未出现 `grub>` / `grub rescue>`,未执行 `efibootmgr -o`(I1、I2) | 本文"验证"第 1、2、8 行 |
| 7 | 清单逐项勾选,偏差有记录 | 本文"验证"第 10 行 |

本阶段的产物逐字就是入库的 [checklists/rollback.md](../checklists/rollback.md)(设计第 4 节 L5 行、[入口文档](00-overview.md)"阶段与文档映射"):它既是执行时的勾选清单,也是本阶段的执行记录。

**退役不产出新的 `baseline/` 产物**:`baseline/` 的文件名契约(前缀 = 阶段号,见 [baseline/README.md](../baseline/README.md))只为 L0-L4 定义,退役阶段不在其中;`02-*` 基线是为"部署中的设备"服务的,设备退役后它不再需要(见"回滚"第 5 条)。退役期间真正要落盘的是"动手前现状"的备份,按步骤 2 写到仓库外的 `D:\dbk-l5-backup\`,不进 `baseline/`——它是**仓库外产物、不是 `baseline/` 基线**(虽然产物名沿用 `02-*`,只为与 L2 口径对齐,不要把它误当成 L2 基线)。

## 前置条件

- **L4 已收尾**:[docs/08-verification.md](08-verification.md) 的 B、F 组全绿;`baseline/04-first-boot.md`、`baseline/04-robustness.md` 在位。带着"系统还没收敛"的状态退役,会把"退役出错"与"系统本来就有病"两件事混在一起。
- **先盘点 Linux 侧要留的东西——这是本阶段唯一不可逆的损失来源**:退役会一并删掉 **root 上的本地数据**与 **`/snapshots` 里的全部快照**。按设计 5.3,代码仓库、`~/.ssh`、dotfile 等依赖 POSIX 权限语义的东西**本来就不在共享盘上**,它们只存在于 root 分区;而 `~/.config/user-dirs.dirs` 只把文档/下载/图片/桌面指向共享盘。动手前逐项确认:
  - `~` 下有无未同步的代码、密钥、笔记(需要就 `rsync -a` 到 `/mnt/shared/` 或外置盘);
  - `/snapshots` 里有无"还想要的旧版本"(快照会随分区一起消失);
  - 共享盘上是否有"半成品"目录(如已 `mv` 到共享盘的家文件)。把结论记进清单。
- **基线可用**(I4):`baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` 在位可读。退役要删分区、可能还要扩分区,属"分区表变更",**没有可用基线就没有回滚点**。
- **BitLocker 状态已知且恢复密钥在手**:48 位恢复密钥已备份(设计第 9 节)。**只有走步骤 5 的例外路径**(离线重排给 `C:` 扩容)才有必要先挂起保护:`manage-bde -protectors -disable C: -rebootcount 0`,扩容完成后按"回滚"第 4 条恢复。**标准路径不需要挂起**:它只删两块 ext4 分区并扩 `D:`,不改动 `C:` 的偏移。但分区表变更**整体**属于 BitLocker 的触发场景,所以"恢复密钥在手"是硬前提——不确认状态就不要动手。
- **救援 U 盘在位**(设计 4.7 的 R4):常备的 Ubuntu 安装 U 盘是"删到一半发现不对"时唯一可靠的入口,也是步骤 4 第三条路径要用到的工具。
- **回 Linux 的入口已知**(L4 步骤 7 已配):`BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)。退役期间**标准路径**只在步骤 1 需要进一次 Linux,之后**再也不需要**;偏差分支见步骤 1 的说明(需两次 Linux 会话:记录现状 + 删条目)。
- **参数表已填**:`DISK`、`DISK_MODEL` / `DISK_SIZE`、`ESP_SIZE = 2GiB`、`WINDOWS_SYSTEM_SIZE = 200GiB`、`WINDOWS_DATA_SIZE ≈ 635GiB`、`ROOT_SIZE = 100GiB`、`SNAPSHOT_SIZE = 15GiB`、`BOOT_MENU_KEY`。删分区时靠它与 `baseline/02-partitions.txt` 的偏移/大小逐项对账。
- **最后一次进 Linux 时收尾干净**:共享盘写入已落盘(`sync` 后 `sudo umount /mnt/shared`),不要在 Windows 处于休眠状态时让 Linux 挂载过共享盘(设计 5.3 前置条件第 1、2 条)。
- **口径:L5 只做"主动退役"**,不做新装、不做救援。若现状是"引导层损坏而系统分区完好",那是设计 4.8 的"第三选择",走 [07-rescue.md](07-rescue.md),不要顺手重装,也不要顺手删分区。

## 步骤

### 0. 动手前的只读取证(不属于五步,但先做)

先把"动手前"的现场抄一份,便于事后逐项比对。这一步只读,不写 NVRAM、不改 ESP:

```bash
sudo efibootmgr -v | tee ~/l5-before-efibootmgr.txt
sudo lsblk -o NAME,SIZE,FSTYPE,PARTUUID,MOUNTPOINT | tee ~/l5-before-lsblk.txt
```

把两份文件拷到共享盘或外置盘(`~/` 会随 root 分区一起消失)。**不要在这一步做任何写操作**,更不要"顺手"用 `efibootmgr -o` 调整顺序(I2)。

### 1. 在 Ubuntu 中把 `BootOrder` 首项改回 Windows Boot Manager

做什么:进 Linux → 只读记录现状 → 重启进固件设置界面 → 把 `Windows Boot Manager` 移到首位。

1. **进 Linux**:按 `BOOT_MENU_KEY` 在一次性启动菜单里选 `ubuntu`;或从 Windows 侧执行 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(默认空跑,确认后去掉 `-WhatIf`),它是**一次性** BootNext,不改 `BootOrder`;
2. **记录现状**:`sudo efibootmgr -v`,抄下 `BootOrder:` 整行、`Windows Boot Manager` 的条目编号、`ubuntu` 条目的编号与 loader 路径(`\EFI\ubuntu\shimx64.efi` 或 `grubx64.efi`;通常 shim 与 grub 各一条);
3. **进固件设置界面**(是 `Setup`,不是启动菜单)。两条入口,优先用第一条:
   - **在 Ubuntu 里直接重启进固件设置**:`sudo systemctl reboot --firmware-setup`(不用记键位,也不会错过按键时机);
   - **该命令不被支持时**(少数固件会直接普通重启;报 `Cannot indicate to EFI to boot into setup mode`(固件不支持该标志)或被会话 inhibitor 挡住(`Operation inhibited by ...`)):关机后按厂商的固件设置键开机——键位见 [L1 手册](01-firmware.md) 的"厂商差异表",该表的"启动菜单键"列在每个厂商格内同时给出固件设置键(如 Dell `F2`、HP `F10`、Lenovo `F2`、ASUS `F2` / `Del`、Acer `F2`、MSI `Del`、通用 `Del` 或 `F2`)。
4. 在 `Boot Order` / `Boot Sequence` 里把 `Windows Boot Manager` 移到第一位。不同固件的操作方式不同(方向键 + `+`/`-`、`F5`/`F6`、或用下拉框选中后 `Enter`),以"保存后 `BootOrder` 首位是 Windows"为准;
5. **保存退出**:保存退出后机器会**直接进 Windows**,步骤 2 就在这个 Windows 会话里做,**不要再回 Ubuntu 一趟**。

**只能用固件设置界面**——不得用 `efibootmgr -o`。理由不只是纪律:改永久顺序这件事,固件自己是唯一的权威,NVRAM 与固件的 BootOrder 视图不一致时会被固件在下一次开机时改回去,用工具"赢了"只是暂时现象(I2)。

**固件没有顺序选项时**(部分机型只给"删除条目",不给顺序调整):这不算违规,按偏差处置。这一支路是**全文唯一允许的次序调整**,而且比正文多走两次重启(共三段),物理闭环如下——先备份、后删条目,次序不可颠倒(理由:删条目本身就是一次 NVRAM 变更,必须先有备份):

1. **第一段:回 Windows 做备份**。在当前的 Ubuntu 会话里先完成步骤 0 的只读取证与 `sudo efibootmgr -v` 记录(步骤 1 第 2 条),然后重启回 Windows,按步骤 2 把 NVRAM 与 ESP 现状备份到 `D:\dbk-l5-backup\`。**这份备份没做完,就不要往下走**;
2. **第二段:回 Ubuntu 删条目**。在 Windows 里按 `BOOT_MENU_KEY` 选 `ubuntu`,或执行 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(一次性 BootNext,不改顺序),回 Ubuntu 后执行 `sudo efibootmgr -b <ubuntu 条目编号> -B` 删除 `ubuntu` 条目,让固件回落到 `Windows Boot Manager`(设计 4.8 第三选择与 [L3 手册](04-silverblue.md)同一手段);删完用 `sudo efibootmgr -v` 确认条目已消失;
3. **第三段:重启回 Windows,接着做步骤 3**。此后**再也不需要进 Linux**。条目删掉后,"残留清理"就等于步骤 4 已完成,清单上照勾并在备注里写明;最后按 [07-rescue.md](07-rescue.md) 与 L2 基线(`baseline/02-firmware-entries.txt`)核对现场,并把这个偏差记进清单。

怎么知道成功了:

- `sudo efibootmgr -v` 的 `BootOrder:` 第一项对应 `Windows Boot Manager`;
- 连续重启 3 次都默认进 Windows(设计 8-A 的判据);
- 与 `baseline/02-firmware-entries.txt` 逐项对比:只允许"`ubuntu` 条目从首位退到后面或被删除",不允许 `\EFI\Microsoft\` 相关内容出现变化。

这一步是**零代价、可逆**的:Linux 仍然能启动,只是不再默认;需要它时按 `BOOT_MENU_KEY` 进(一次性的,不改顺序)。所以"想停用但还没决定要不要删"的诉求,做到这一步就可以停(见文末"变体")。

### 2. 备份当前 NVRAM 与 ESP 现状(最后一道保险)

做什么:重启进 Windows,**在不动任何东西的前提下**把"动手前"的现场整份存到仓库外,让后面任何一步出错都有可复原、可对照的基准。

```powershell
# 管理员 Windows PowerShell,在仓库根目录执行
# 1) NVRAM 与 ESP 现状整份备份(产物名沿用脚本固定口径:02-esp-backup/、02-firmware-entries.txt、02-partitions.txt)
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\backup-esp.ps1 -OutDir D:\dbk-l5-backup
# 2) 与 L2 基线比对,确认"动手前"现场未被改动(只读巡检)
powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline
```

要点:

- **不要用默认的 `-OutDir baseline`**:那会覆盖 `baseline\02-esp-backup\`、`02-firmware-entries.txt`、`02-partitions.txt`,而它们正是本阶段的比对基准与基线回滚的来源。备份写到 `D:\dbk-l5-backup`(数据分区,退役后仍在);再稳妥一点,只写外置盘;
- [backup-esp.ps1](../scripts/windows/backup-esp.ps1) 只写 `-OutDir`,ESP 只在备份期间临时挂一个盘符、收尾必然卸载,不改 ESP 内容;脚本产出的 `02-*` 名字表达的是"基线口径",与它落地在哪个目录无关。**这批文件是仓库外产物、非 `baseline/` 基线**:它们记录的是"动手前现状"这最后一道保险,不参与 L0-L4 的基线判定,也不要拷进 `baseline/`;
- [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 的期望:① `BootOrder` 首位、② `\EFI\Microsoft\` 逐文件比对、③ `{bootmgr}` 的 `path` 三项**全部"通过"**;④ BitLocker 一项若与 L2 报告里的记录不同(典型场景:L3 收尾已执行 `manage-bde -protectors -enable C:`,而 L2 记录的是"卷已加密、保护已关闭"),脚本会报"发生变化(提示人工确认)"并让整体退出码为 1——**这属预期差异,不是引导层问题**,记进清单即可。判据是"三项引导判据通过、差异被记录",而不是"退出码必须为 0"。

怎么知道成功了:

- `D:\dbk-l5-backup\02-esp-backup\manifest.sha256` 就位,且脚本输出里的"清单 N 个文件"与备份树里的文件数一致;
- 备份树里同时存在 `EFI\Microsoft\Boot\bootmgfw.efi` 与 `EFI\ubuntu\` 两棵子树(退役前两套引导都在);
- `D:\dbk-l5-backup\02-firmware-entries.txt` 的 `BootOrder` 首位是 `Windows Boot Manager`,与步骤 1 的结果一致。

### 3. 重启进 Windows,用「磁盘管理」删除 Linux 分区

做什么:**确认引导已归位(步骤 1 已验证)之后**,才动手删分区。`Win + X` → 磁盘管理:

1. **先对账,再动手**。图形里逐项确认分区对应关系(别凭印象):

   | 分区 | 大小 | 图形里的样子 | 归宿 |
   |---|---|---|---|
   | ESP | 2GiB | FAT32,可能有盘符或"EFI 系统分区" | 保留,**不碰** |
   | MSR | 16MiB | "保留" | 保留,**不碰** |
   | C: | 200GiB | NTFS,卷标含系统 | 保留,**不碰** |
   | D: | ≈635GiB | NTFS,数据分区(共享盘) | 保留,**不碰** |
   | Ubuntu root | 100GiB | 无盘符,"主分区"(ext4 不被识别) | **删除卷** |
   | Snapshots | 15GiB | 无盘符,"主分区" | **删除卷** |
   | WinRE | ≈1GiB | "恢复" | 保留,**不碰** |

   比对基准是 `baseline/02-partitions.txt` 与本阶段步骤 2 产出的 `D:\dbk-l5-backup\02-partitions.txt`:偏移与大小逐项对上,再动手。两块 ext4 分区没有盘符、也没有卷标,大小是 100GiB 与 15GiB 这两个数——**这是全流程里唯一能确认"删的不是 D:"的依据**;

2. 逐个右键那两块 ext4 分区 → **删除卷**(两次),让它们变成未分配空间。**只删这两块**:
   - **不要**碰 ESP:删掉 ESP 等于两个系统一起进不去,只能靠基线复原;
   - **不要**碰 MSR 与 WinRE:之后"重置此电脑"、恢复环境都依赖后者;
   - **不要**碰 `D:`:游戏库、文档、下载、`D:\Shared\` 都在上面,删了就是数据灾难;
   - **不要**用第三方工具的"删除所有分区",也不要 `diskpart` 的 `clean`;
3. **删完立即复核**:图形里两块 ext4 分区消失,多出一处连续未分配空间(目标布局下位于 `D:` 与 WinRE 之间,合计约 115GiB);`Get-Partition -DiskNumber 0 | Format-Table -AutoSize` 的分区数比删前少 2。

**为什么这个顺序是硬要求**:见文首"明确禁止"一条——删分区之前引导必须已经归位,否则固件会去找已经不存在的 `\EFI\ubuntu\grubx64.efi`,开机停在 `grub rescue>`。反过来说,先让 Windows 排在首位再删分区,固件根本不会去看那个失效条目,这就是 I1 买到的保险,比"记得先修引导"可靠。

怎么知道成功了:见"验证"第 5、6 行。另:Linux 侧要留的东西必须在**上一步之前**就拷走(步骤 0/前置条件的盘点),`/snapshots` 的快照在这两步之后全部消失。

### 4. 清理 NVRAM 中残留的 ubuntu 条目

做什么:此时系统里已经没有 Linux,唯一残留是固件启动项列表里的 `ubuntu`(常见不止一条:shim 与 grub)。按可达性依次尝试:

1. **首选:固件设置界面里的"删除启动项"**(`Delete Boot Option` / `Remove Boot Entry`)。与步骤 1 同一界面,不依赖任何工具,也不受操作系统影响,最干净;
2. 次选:Windows 侧管理员会话。

   ```
   bcdedit /enum firmware
   bcdedit /delete {<ubuntu 条目的 identifier>}
   ```

   `/enum firmware` 输出里,`Firmware Application (101fffff)` 段下的条目会标出 `path \EFI\ubuntu\shimx64.efi` 或 `\EFI\ubuntu\grubx64.efi`,`description` 可能是 `ubuntu`(中文系统上可能是别的标签,以 path 为准);`bcdedit /delete` 在部分固件/版本上会报 `The delete command specified is not valid`,报错就换第 1 或第 3 条,不要在这里反复试;
3. 再次:从 Ubuntu 安装 U 盘进 live 环境,`sudo efibootmgr` 找到 `ubuntu` 条目编号后 `sudo efibootmgr -b <编号> -B`(设计 4.8 第三选择里的同一手段)。

**不得**用 `bcdedit /set {fwbootmgr} displayorder ...` 之类的"改顺序"命令代替删除:那是 I2 禁止的动作,与 `efibootmgr -o` 等价([set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) 同样只做一次性 BootNext,绝不做改序操作)。

残留条目删不掉、或删了下次开机又出现,**不影响"能安全撤除"这个结论**:只要 I1 成立(`BootOrder` 首位是 Windows),失效条目排在后面时固件会继续回落到 Windows。收拾它属于"固件条目列表与实际状态一致"的整洁性要求(设计 8-D),记进清单的偏差即可,不要为此改动启动顺序。

怎么知道成功了:见"验证"第 7 行。

### 5. 可选:把腾出的空间扩展进相邻分区

先把布局摆清楚(设计 5.1 的目标布局,尺寸为 GUI 显示值):

```
[ESP 2G][MSR 16M][C: 200G][D: ≈635G][Ubuntu root 100G + Snapshots 15G][WinRE ≈1G]
                                     └─ 销毁后变成 115G 连续未分配空间 ─┘
```

由此有三条必须说清的结论:

- **`C:` 在本方案布局下扩不了**。「扩展卷」的硬条件是:未分配空间**紧邻该卷之后并且连续**。`C:` 的紧邻后继是 `D:`,腾出的空间与 `C:` 之间隔着整个 `D:`,所以磁盘管理里的"扩展卷"对 `C:` 是灰的——这不是操作问题,是布局决定的。要真把 `C:` 扩大,等价于"移动 `D:` 或重排分区表":离线移动分区的风险与代价都不成比例(设计 3.5 的立场是"整盘重排只在装机阶段做一次"),而 `C:` 是否够用已由系统盘隔离(设计 3.15)兜住——重装只需要 `C:`,数据在 `D:`,所以给 `C:` 扩容的收益很低。**记录结论即可,不要为此动 `D:`**;
- **能扩的是 `D:`**:它与未分配空间相邻,可以无损并入这 115GiB(共享数据盘从 ≈635GiB 变成 ≈750GiB)。这是本方案里**唯一无损**的扩展方向。`D:` 不加密,但扩展前确认上面没有正在写入的大文件(尤其 Linux 侧留下的半成品);
- **扩不满 115GiB 是正常的**:盘尾的 WinRE(≈1GiB 恢复分区)不可移动,扩展的上限是"未分配空间起点 → WinRE 起点"。

操作:磁盘管理 → 右键 `D:` → 扩展卷 → 用默认的"全部可用空间"(或按需填写容量)→ 完成。判据见"验证"第 9 行。

若确实要给 `C:` 扩容(例如 `C:` 长期吃紧、且不愿等到下次重装):把它记为设备参数偏差。**"离线移动分区"的第三方路线不在本方案交付范围,仅作偏差登记——本文不提供该路线的步骤**;真要试也得先确认基线可用与 BitLocker 状态,在**救援环境**里做,并且第三方工具**不得改 `{bootmgr}` 的 `path`、不得覆盖 `\EFI\Microsoft\`**(I3;越了这两条就不是"偏差"而是违规)。不要在 Windows 运行时对 `D:` 做"移动分区起点"的操作。本方案不提供运行中缩容/移动 Windows 分区的步骤(设计 3.5 明确否掉了"在已有系统上缩容"这一整类路径)。

### 变体:只想暂时停用 Linux(不删分区)

这不是退役的第六步,而是**从步骤 1 分出去的一条支路**:如果你只想"平时不再被 Linux 打断",做到步骤 1 就可以停,第 2-5 步都不做(第 2 步可做可不做:它只读、只写仓库外目录,做一次更安全)。两种收尾方式,后果不同:

| 做法 | 后果与代价 |
|---|---|
| **A. 只做步骤 1**:`BootOrder` 首位回到 Windows,`ubuntu` 条目**保留**在列表里 | 日常开机直接进 Windows;要用 Linux 时按 `BOOT_MENU_KEY` 选 `ubuntu`,或从 Windows 跑 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(一次性,不改顺序)。分区、`/snapshots`、配置全部保留,随时可回到"两个系统都能用"。代价:Windows 大版本更新或 SBAT 更新仍可能改写 ESP 导致 **Linux** 引导失效(设计 7.1),但那**不会**影响 Windows 启动 |
| **B. 步骤 1 + 步骤 4**(删掉 `ubuntu` 条目,分区保留) | 固件列表更干净,启动路径里没有任何失效项,日常体验等同"已退役"。代价:下次要用 Linux 得从 live U 盘重建条目(设计 4.8 第三选择、[07-rescue.md](07-rescue.md)),或干脆重装;Windows 更新再动 ESP 时也没有自动恢复的余地 |

两种做法下都**不要**出现"删了分区却把条目留在首位"这种半程状态——它就是 `grub rescue>` 的成因。走 A 却还想顺手清掉旧条目时,严格按步骤 4 做(删除条目,不改顺序)。

## 验证

逐项核对,全部通过 = L5 完成(即设计 8-D 组"可撤除性"在此设备上落地)。第 2、8 行的"连续 3 次重启"是实测,不是推理;参考设备必须真跑一次(设计第 4 节 L5 行、8-D 组)。

| # | 检查项 | 命令 / 来源 | 期望 |
|---|---|---|---|
| 1 | 五步顺序未跳序 | [checklists/rollback.md](../checklists/rollback.md) 第一节的勾选记录与备注 | 勾选顺序为 1 → 2 → 3 → 4 →(5);记录里没有"先删分区再修引导"的动作;走了步骤 1 的偏差分支时,其"先备份 → 回 Ubuntu 删条目 → 再回 Windows"的三段次序也写进备注(该分支在清单上排在步骤 2 之后,属步骤 1 的完成方式,不算跳序) |
| 2 | `BootOrder` 首位是 `Windows Boot Manager` | Windows 侧 `bcdedit /enum firmware`;或 live 环境 `sudo efibootmgr -v` | `BootOrder` 第一项对应 `Windows Boot Manager` |
| 3 | "动手前"备份已生成 | `D:\dbk-l5-backup\02-esp-backup\manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt` | 三份在位、可读;备份树含 `EFI\Microsoft\` 与 `EFI\ubuntu\` 两棵子树 |
| 4 | 动手前现场与 L2 基线一致 | `powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline` | ①②③ 三项"通过";④ 若有差异属预期(L3 已恢复 BitLocker 保护),已记入清单 |
| 5 | Linux 分区已删除,其余分区未动 | 磁盘管理图形 + `Get-Partition -DiskNumber 0 \| Format-Table -AutoSize`;比对基准 `baseline/02-partitions.txt` | 原 100GiB 与 15GiB 两块 ext4 分区不存在;ESP / MSR / `C:` / `D:` / WinRE 的偏移与大小与基准一致 |
| 6 | 未分配空间连续且约 115GiB | 磁盘管理图形 / `diskpart` → `list partition` | 一处连续未分配空间,约 115GiB(位于 `D:` 与 WinRE 之间),不是零散碎块 |
| 7 | NVRAM 无残留 `ubuntu` 条目 | `bcdedit /enum firmware`(或 live 里 `efibootmgr -v`) | 条目列表里没有 `path` 指向 `\EFI\ubuntu\shimx64.efi` / `grubx64.efi` 的项 |
| 8 | 无 `grub rescue`(可撤除性判据) | 连续重启 3 次(设计 8-A) | 每次都直接进 Windows,不出现 `grub>` / `grub rescue>`,也不需要任何手工选择 |
| 9 | 腾出空间的处置有明确结论 | 磁盘管理"扩展卷"可用性 + 实际结果 | 二选一,写在清单里:(a) `D:` 已扩到 ≈750GiB;(b) 记录"`C:` 与未分配空间不相邻、不扩"的结论(可附 `D:` 的实测容量) |
| 10 | 清单与偏差记录 | [checklists/rollback.md](../checklists/rollback.md) | 四节里与本次动作相关的项已勾选,偏差(固件无顺序选项、`bcdedit /delete` 报错、BitLocker 差异等)有备注;`git status` 里 `baseline/` 下无变化 |

全部通过 = 这台设备已安全退役:Windows 继续作为唯一系统自动启动,固件条目与实际状态一致(设计 8-D)。任一项不通过,按"失败处理"解决后再推进;**第 8 行不通过是最严重的一种**,先修引导,再谈其它。

## 失败处理

| 现象 | 立即动作 |
|---|---|
| 步骤 1 改完顺序,重启仍进 Linux | 先确认"保存"真的生效(部分固件要按 `F10` 再确认一次退出)。仍不进 Windows 就别急着往下走:**回到固件设置界面再设一次**;固件确实不支持顺序调整时,按步骤 1 的偏差分支处理(三段重启的次序:**先**回 Windows 做步骤 2 备份,**再**用 `BOOT_MENU_KEY` 回 Ubuntu `efibootmgr -b <n> -B` 删条目让固件回落,**然后**重启进 Windows 做步骤 3)。**不得**改用 `efibootmgr -o`(I2) |
| 重启停在 `grub>` / `grub rescue>` | 说明引导没有先归位,或 `ubuntu` 条目指向的引导文件已损坏。**立即停手,不要再删任何分区**。按 [07-rescue.md](07-rescue.md) 的两条路现场处置:`ls` 找分区 → `set prefix` → `insmod normal` → `normal`;或直接回 Windows:`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` → `chainloader` → `boot`。之后用基线复原(见"回滚"第 3 条)并复查四不变量 |
| 磁盘管理里认不出哪块是 Linux 分区 | **停下,不要猜**。用 `baseline/02-partitions.txt` 与 `D:\dbk-l5-backup\02-partitions.txt` 的偏移/大小逐项对账;或在 `diskpart` 里 `select disk 0` → `list partition` 看大小与位置。两块 ext4 分区是 100GiB 与 15GiB、无盘符;`D:` 是 ≈635GiB。**宁可停,不可试** |
| 误删了 `D:` 或 ESP | 立刻停止一切写盘动作(尤其不要再建分区、不要跑安装器)。ESP 被删:按"回滚"第 3 条用 ESP 备份 + `bcdboot` 复原;`D:` 被删:数据恢复优先于系统修复,先评估是否需要专业恢复,不要在原盘写入新数据 |
| 想删的 ext4 分区删不掉("删除卷"灰) | 确认选中的是那两块无盘符分区而不是"未分配空间";确认没有第三方分区工具正占用磁盘(关闭它们);若仍灰,用 `diskpart`:`select disk 0` → `select partition <编号>` → `delete partition override`(编号按 `list partition` 的实际输出;**只对这一块**执行,`clean` 是绝对禁止的) |
| `bcdedit /delete {GUID}` 报 `The delete command specified is not valid` | 换路径:固件设置界面的"删除启动项",或从 Ubuntu live U 盘 `sudo efibootmgr -b <编号> -B`。不要为了"删干净"去改 `displayorder`(I2) |
| 删掉条目后,开机又在列表里看到 `ubuntu` | 部分固件会从磁盘上残留的引导文件重建条目。确认 ESP 上是否还有 `\EFI\ubuntu\`:若在,按"回滚"第 3 条先把现场核清,再用 `robocopy`/资源管理器删除该子树(**只删 `\EFI\ubuntu\`,不要碰 `\EFI\Microsoft\`**);若已不存在,把它记成固件行为偏差;只要首位是 Windows,就不影响启动 |
| 「扩展卷」对 `C:` 是灰的 | 正常:见步骤 5,`C:` 与未分配空间不相邻。**不要**为了给 `C:` 扩容而删除或移动 `D:`;把结论记进清单第 9 行,或扩 `D:` |
| 扩展 `D:` 时报磁盘空间不足 / 卷被占用 | 确认无页面文件、无休眠文件、无第三方工具占用;`D:` 上有未落盘写入时先在 Linux/Windows 两侧都停掉相关进程(Fast Startup 必须保持关闭,设计 5.3) |
| 分区表变更后 Windows 索要 BitLocker 恢复密钥 | 输入已备份的 48 位恢复密钥,进系统后按"回滚"第 4 条恢复保护状态。为降低再次触发:下一次**涉及 `C:` 或其相邻布局**的分区表/固件变更之前先 `manage-bde -protectors -disable C: -rebootcount 0` |
| 退役中途 Windows 仍能看到 `ubuntu` 启动项且它排在最前 | 违反 I1,立即进固件设置界面把 `Windows Boot Manager` 设回首位(或删除失效的 `ubuntu` 条目)。**不要**因为"看着烦"去重装 Windows,更不要用第三方的"引导修复"一键工具改 `{bootmgr}` 的 `path`(I3) |
| 退役后想确认 Windows 侧一切正常 | 跑一次 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1):ESP 文件哈希与 `{bootmgr}` 的 path 应仍与基线一致(删掉 `\EFI\ubuntu\` 不影响 `\EFI\Microsoft\` 的比对),BitLocker 一项的差异按预期记录处理 |

## 回滚

### 1. 三种回滚粒度怎么用(设计 7.2)

| 粒度 | 对应场景 | 手段 |
|---|---|---|
| 单步回滚 | 步骤 1 改错了顺序、步骤 3 删错了卷、步骤 5 扩错了分区 | 回到该步骤的"怎么知道成功了"重新做;分区删除**不可逆**(只能靠重装或数据恢复) |
| 阶段回滚 | 不再需要 Linux | 就是本文的五步;半途反悔见下一条 |
| 基线回滚 | ESP 或固件启动项被破坏 | `baseline/02-esp-backup/` 文件树还原 + `bcdboot` 重建 + NVRAM 清理 |

### 2. 退役做到一半想反悔

| 进行到 | 还能回到什么状态 | 做法 |
|---|---|---|
| 只做完步骤 1 | **什么都没丢**:分区、`/snapshots`、Linux 系统、配置全在 | 用 `BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) 进 Linux 即可。**不要**把 `BootOrder` 改回 Ubuntu 在首位——I1 要求首位永远是 Windows,进 Linux 一律走一次性入口 |
| 做完步骤 3(分区已删) | Linux 侧数据永久丢失;Windows 侧一字未动 | 要 Linux 就按设计 4.8 办法二重装:只格 root 并挂 `/`、ESP **复用且绝不勾选格式化**、Windows 各分区不动;`/snapshots` 分区已随退役消失,重装时按 [L3 手册](04-silverblue.md) 从预留空间再切——本方案不提供"在已有系统上缩容 Windows 分区"的路径(设计 3.5 被否方案) |
| 做完步骤 4 | 同上 | 重装时安装器会重新创建 `ubuntu` 条目(设计 4.4);起步用 live U 盘或厂商启动菜单 |
| 做过步骤 5 的 `D:` 扩展 | 数据与引导都不受影响 | 想退回原容量需要"缩小 `D:`",而 NTFS 缩容受不可移动文件限制、且要先移出数据,**不建议**(设计 3.5);把这 115GiB 的归属记成设备参数偏差即可 |

### 3. 引导层损坏时的回滚(基线回滚)

若在校验或重启中发现 `\EFI\Microsoft\` 被改动、`{bootmgr}` 的 `path` 异常、或出现 `grub>` / `grub rescue>`:**不要重装**,走设计 4.8 的"第三选择"——

1. 校验 `baseline\02-esp-backup\manifest.sha256` 与备份文件一致;
2. 挂载 ESP(`mountvol S: /s`),把 `baseline\02-esp-backup\EFI\` 复制回 ESP(`robocopy baseline\02-esp-backup\EFI S:\EFI /E`;清单文件本身不复制);
3. 重建 Windows 引导:`bcdboot C:\Windows /s S: /f UEFI`;
4. 卸载 ESP(`mountvol S: /d`);
5. 复查四条不变量并重跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 复核;GRUB 命令行的现场处置见 [07-rescue.md](07-rescue.md)。

完整命令与判据见 [回滚清单](../checklists/rollback.md) 第 4 节(本节只做指向,避免同一段命令两处维护)。

### 4. 解除 BitLocker 挂起(若步骤 5 之前挂起过保护)

扩展完成后立刻恢复:`manage-bde -protectors -enable C:`,再用 `manage-bde -status` 确认保护已开启。`-rebootcount 0` 的挂起**不会**自动恢复,漏做会让 `C:` 长期停在"卷仍加密、保护已关闭"的状态(闭环口径与 [回滚清单](../checklists/rollback.md) 第 1 节的 BitLocker 收尾行一致)。这一步做完,退役流程才算全部闭环。

### 5. I4 复核:退役之后旧基线的状态

退役改动了分区表(删分区、可能扩 `D:`)与固件启动项,所以 `baseline/02-*` 代表的"退役前状态"与现场不再一致——**这是预期的、也是允许的**:该设备已无 Linux,不再需要这些基线,也不需要为退役重做一份(步骤 2 的 `D:\dbk-l5-backup` 只是最后一道保险,不是新基线)。

要在这台设备上**重新部署**时:回 L0 走整套流程(设计 4 节的 L0-L2),重新生成 `baseline/00`-`02`,并把这次退役的偏差(固件无顺序选项、`C:` 不可扩等)回写进[入口文档](00-overview.md)的设备参数表;不要把退役前的旧基线当成本次部署的判定基准。
