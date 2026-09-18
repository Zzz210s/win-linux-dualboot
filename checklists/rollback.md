# 回滚与救援核对清单(L5)

配合 [L5 退役手册](../docs/06-decommission.md) 使用。四节各管一件事:① 退役五步;② 引导救援(`grub>` / `grub rescue>`);③ 原地重装两法(只格一块分区);④ 基线回滚(ESP 还原 + `bcdboot`)。

用法:执行到哪一项就在"勾选"列把 `[ ]` 改成 `[x]`,并把实测值/偏差写进该行末尾的备注(清单里带 `____` 的地方都要填实测值)。每项都有"判据 / 如何确认"列——**判据不成立就不要往下走**,先按 L5 手册的"失败处理"处置。

三条底线(任何一节都适用):

- **绝不执行 `efibootmgr -o`,也绝不用 `bcdedit /set {fwbootmgr} displayorder ...` 改永久启动顺序**(不变量 I2):进另一个系统只用一次性 `BootNext`(见 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)、[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh))或厂商 `BOOT_MENU_KEY` 菜单;
- **绝不覆盖 `\EFI\Microsoft\`,绝不改 `{bootmgr}` 的 `path`**(I3);
- **绝不先格式化 Linux 分区再修引导**——那是 `grub rescue>` 的成因;顺序永远是"先让 Windows 回到 `BootOrder` 首位,再删分区"。

## 1. 退役五步(顺序不可更换)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 动手前只读取证:`sudo efibootmgr -v`、`sudo lsblk -o NAME,SIZE,FSTYPE,PARTUUID,MOUNTPOINT`,两份输出拷到共享盘/外置盘(不要留在 `~/`) | 两份文件在仓库外可读;本步**未做任何写操作**(NVRAM 与分区表未变) |
| `[ ]` | 步骤 1:进 Linux(`BOOT_MENU_KEY` 或 `set-bootnext.ps1`),`sudo efibootmgr -v` 抄下 `BootOrder:` 整行、`Windows Boot Manager` 编号、`ubuntu` 编号与 loader 路径 | 抄下来的三样都记进本行备注;`ubuntu` 条目路径为 `\EFI\ubuntu\shimx64.efi` 或 `grubx64.efi` |
| `[ ]` | 步骤 1:进**固件设置**(优先在 Ubuntu 里 `sudo systemctl reboot --firmware-setup`;该命令不被支持时关机后按厂商 Setup 键,键位见 [L1 手册](../docs/01-firmware.md) 的"厂商差异表"),把 `Windows Boot Manager` 移到 `BootOrder` 第一位(只用界面,不用工具) | 保存退出后**直接进 Windows**;`efibootmgr -v` 或 `bcdedit /enum firmware` 的 `BootOrder` 第一项是 `Windows Boot Manager`;连续重启 3 次都进 Windows |
| `[ ]` | 步骤 2:重启进 Windows,管理员会话跑 `backup-esp.ps1 -OutDir D:\dbk-l5-backup`(**不要**用默认的 `-OutDir baseline`,会覆盖 L2 基线) | `D:\dbk-l5-backup\02-esp-backup\manifest.sha256` 在位;脚本输出的"清单 N 个文件"与备份树文件数一致;备份树含 `EFI\Microsoft\` 与 `EFI\ubuntu\` 两棵子树 |
| `[ ]` | 步骤 2:跑 `verify-baseline.ps1 -BaselineDir baseline` 复核"动手前"现场未被改动 | ①②③ 三项(引导)全部"通过";④ BitLocker 若与 L2 报告不同属预期差异(备注写明);四项里只有 ④ 有差异,已记录,不是引导层问题 |
| `[ ]` | 步骤 1 的偏差分支(仅当固件不给顺序选项时;**次序见正文,勿提前执行**,含三段重启):① 先回 Windows 做步骤 2 的备份 → ② 用 `BOOT_MENU_KEY`(或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1))回 Ubuntu,`sudo efibootmgr -b <ubuntu 编号> -B` 删条目让固件回落 → ③ 再重启进 Windows 做步骤 3 | 备份**早于**删条目(删条目本身即 NVRAM 变更);条目删除后 `BootOrder` 首位是 `Windows Boot Manager`;三段重启的次序已写进备注;偏差已记录 |
| `[ ]` | 步骤 3:**对账后**在磁盘管理中删除两块无盘符的 ext4 分区(100GiB 与 15GiB),各右键"删除卷" | 删前用 `baseline\02-partitions.txt` 与 `D:\dbk-l5-backup\02-partitions.txt` 逐项对上偏移/大小;删后 `Get-Partition -DiskNumber 0` 的分区数比删前少 2 |
| `[ ]` | 步骤 3 后复核:ESP / MSR / `C:` / `D:` / WinRE 未被触碰 | 图形与 `Get-Partition` 里这 5 项仍在,大小与基准一致;多出一处连续未分配空间约 115GiB |
| `[ ]` | 步骤 4:清理 NVRAM 残留 `ubuntu` 条目(固件界面"删除启动项" → `bcdedit /enum firmware` + `bcdedit /delete {identifier}` → live U 盘 `sudo efibootmgr -b <编号> -B`) | `bcdedit /enum firmware` 里没有 `path` 指向 `\EFI\ubuntu\...` 的条目;`BootOrder` 首位仍是 `Windows Boot Manager`(**没有**用改顺序代替删除) |
| `[ ]` | 步骤 5(可选):处置腾出的 115GiB——扩 `D:`,或记录"`C:` 不相邻、不扩"的结论 | 写清二选一:(a) `D:` 已扩到 ≈____GiB;(b) 明确记下"`C:` 与未分配空间不相邻"的实测结论(WinRE 不可移动,上限为未分配空间起点到 WinRE 起点) |
| `[ ]` | 收尾:如果步骤 5 之前挂起过 BitLocker,恢复保护 | `manage-bde -protectors -enable C:` 已执行,`manage-bde -status` 显示保护已开启 |
| `[ ]` | 收尾:连续重启 3 次做实测 | 每次都直接进 Windows,不出现 `grub>` / `grub rescue>`,也不需要手工选择(设计 8-A、8-D) |
| `[ ]` | 记录:把本次偏差写进备注并回写设备参数表 | 偏差项(固件无顺序选项、`bcdedit /delete` 报错、`C:` 不可扩、`D:` 新容量等)都有文字记录;[入口文档](../docs/00-overview.md) 参数表已按需更新 |

## 2. 引导救援(停在 `grub>` 或 `grub rescue>`)

先判断进的是哪一个:能敲 `ls`、能看到 `(hd0,gpt1)` 这类设备名的是 GRUB 命令行;**只提示 `grub rescue>` 且 `normal` 用不了**,说明模块路径 `prefix` 没设对。两条路都只在**引导层**动手,不碰分区表。

### 2.1 路一:修好 GRUB,继续进 Linux

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | `ls` 列出设备与分区,找出含 `/boot/grub` 的分区(逐个 `ls (hd0,gptN)/` 看内容;Ubuntu root 通常是 `gpt5`) | 某个分区里能看到 `boot/`(而不是"unknown filesystem");记下 `(hdX,gptN)` |
| `[ ]` | `set prefix=(hdX,gptN)/boot/grub`(若 root 上有独立的 `/boot` 分区,则指向该分区的 `/grub`) | `echo $prefix` 回显与设定一致 |
| `[ ]` | `insmod normal` | 无报错(报 `file not found` 说明 `prefix` 指错了分区/路径,回到上一步重找) |
| `[ ]` | `normal` | 出现正常的 GRUB 菜单,能选到 Ubuntu 或 Windows |
| `[ ]` | 进入系统后做持久修复(否则下次开机照旧):确认 `\EFI\ubuntu\` 与 ESP 挂载正常,必要时从 live 环境重装 GRUB 引导文件;**不要**改 `BootOrder` | 重启后能正常进系统;`BootOrder` 首位仍是 `Windows Boot Manager`(I1);**没有**执行 `efibootmgr -o` |

### 2.2 路二:直接回 Windows(推荐优先试)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | `search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` | 命令无报错(找到文件即 `root` 已指向 ESP);若报 not found,先 `ls` 找 ESP 分区,再 `set root=(hdX,gptN)` 后重试 |
| `[ ]` | `chainloader /EFI/Microsoft/Boot/bootmgfw.efi` | 提示载入成功(无 `invalid signature` 之类报错;Secure Boot 下应能通过,因为用的是微软签名链) |
| `[ ]` | `boot` | 进入 Windows,不需要任何手工选择 |
| `[ ]` | 进 Windows 后查固件条目:`bcdedit /enum firmware` | `BootOrder` 首位是 `Windows Boot Manager`;若失效的 `ubuntu` 条目仍在最前,进固件设置界面把它调后或删除(仍**不得**用 `efibootmgr -o` / `displayorder`) |
| `[ ]` | 若引导文件已损坏、上面两步走不通 | 走第 4 节"基线回滚"(ESP 还原 + `bcdboot`),或按 `docs/07-rescue.md` 的完整救援流程;**不要**在没确认分区表状态前就开始重装 |

## 3. 原地重装两法(只格一块分区)

**共用前提**:`baseline/` 产物齐全可用(分区表、`02-esp-backup/`、固件启动项快照),救援 U 盘在位。**先判断崩溃在哪一层**:只是引导层损坏就**不要重装**,先走第 2 节。

**两法的第一号禁令:ESP 绝不能格式化。** 误格 ESP 会连带清空 `\EFI\Microsoft\`,让 Windows 与 Linux 一起进不去;它是全流程最危险的一步(设计 4.8 办法二的风险行)。

### 3.1 办法一:Windows 崩溃 → 只重装 Windows(只格 `C:`)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 官方 ISO 引导,进入"自定义安装" | 能列出磁盘与全部分区(不是"看不到驱动器") |
| `[ ]` | **只格式化 `C:`**(200GiB NTFS 那块);`D:`、Linux 各分区、ESP、MSR、WinRE 一律不动 | 安装界面里逐分区核对大小与盘符;安装器**没有**执行"删除所有分区"。判据:`D:` 与 Linux 分区的数据仍在(装完进系统后可见) |
| `[ ]` | 让安装程序在 ESP 上重建 `\EFI\Microsoft\` 与 BCD(可能一并覆盖 `\EFI\BOOT\bootx64.efi`,属正常) | 装完能正常进 Windows;`\EFI\ubuntu\` **仍在** ESP 上(未被安装器删掉) |
| `[ ]` | 首启收尾:关 Fast Startup 与休眠、重新完成 KMS 激活、恢复已知文件夹到 `D:` 的重定向 | `powercfg /a` 与电源设置确认休眠关闭;`slmgr /dlv` 显示已激活;六个已知文件夹(`Desktop`/`Personal`/下载/图片/视频/音乐)的值全部以 `D:\` 开头 |
| `[ ]` | 复查四条不变量 | `BootOrder` 首位是 `Windows Boot Manager`;`\EFI\Microsoft\` 与基线(`baseline\02-esp-backup\manifest.sha256`)逐文件一致;`{bootmgr}` 的 `path` 与基线一致;`ubuntu` 条目仍在。可用 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 复核前三项 |
| `[ ]` | 用厂商菜单键验证 Ubuntu 仍可启动 | 一次性选 `ubuntu` 能进系统;重启后默认仍进 Windows(`BootOrder` 未变) |

### 3.2 办法二:Ubuntu 崩溃 → 只重装 Ubuntu(只格 root)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | Ubuntu 安装 U 盘引导,选"手动分区" | 分区界面能看到全部分区(不是只看到 U 盘);目标磁盘与参数表 `DISK`/`DISK_MODEL`/`DISK_SIZE` 一致 |
| `[ ]` | **只格式化 root 分区并挂 `/`**(ext4,100GiB);`/snapshots` **挂上但不格式化**(保留历史快照);Windows 各分区一律不动 | 分区编辑界面里,只有 root 那一行带"格式化"勾选;逐个分区核对,`C:`/`D:`/MSR/WinRE 不参与挂载 |
| `[ ]` | ESP 复用挂 `/boot/efi`,**绝不勾选"格式化 ESP"** | ESP 那一行"格式化"未勾选;装完后 `\EFI\Microsoft\` 内容与基线一致([verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) ② 项"通过") |
| `[ ]` | 安装器写入 `\EFI\ubuntu\`(**与 Windows 引导并存**),期间不改 `BootOrder` | 装完 `/boot/efi/EFI` 下同时存在 `Microsoft` 与 `ubuntu` 两个目录;`BootOrder` 首位仍是 `Windows Boot Manager`,`ubuntu` 在末尾 |
| `[ ]` | 首启:按 [L4 手册](../docs/05-first-boot.md) 重放驱动、挂载、家目录重定向、时间、蓝牙与健壮性配置 | `baseline/04-first-boot.md` 与 `04-robustness.md` 的判据逐项复现(会话为 `wayland`、`ntfs3` 挂载成功、`/snapshots` 可见等) |
| `[ ]` | 复查四条不变量 | 同 3.1 最后两行的判据;连续重启 3 次都默认进 Windows |

## 4. 基线回滚(引导层损坏而系统分区完好时用)

设计 4.8 的"第三选择":**不是重装**,而是用 ESP 备份还原引导文件 + `bcdboot` 重建 + 清理 NVRAM。命令与判据以 [L2 手册](../docs/03-preflight.md)"回滚"第 1 条为准,本节只做勾选。

**执行环境**:复原动作在 Windows 管理员会话或 WinRE 命令提示符中执行——需要管理员权限的是 `mountvol /s` 与对 ESP/系统区的写操作(`robocopy`、`bcdboot`);`Get-FileHash` 本身不需要管理员权限。WinRE 里若 `powershell` 起不来,用 `certutil -hashfile <文件> SHA256` 代替 `Get-FileHash`(`certutil` 不带算法参数时会默认 SHA1,必须显式写 `SHA256`;它的输出为大写十六进制,与 `manifest.sha256` 比对时**忽略大小写**),或回到 Windows 管理员会话执行。注意两件事不在同一环境:首行的诊断可以在 live 环境做(从 live U 盘看到 Windows `C:`),而复原动作在 Windows/WinRE 做。

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 先确认崩溃层级:系统分区数据完好、只是引导不进/进错 | 能从 live U 盘看到 Windows `C:` 上的 `\Windows\` 与 `D:` 上的数据;没有分区表层面的损坏(分区数、大小与 `baseline\02-partitions.txt` 一致) |
| `[ ]` | 校验备份完整性:`baseline\02-esp-backup\manifest.sha256` 与备份文件哈希一致 | 逐文件 `Get-FileHash -Algorithm SHA256` 比对无差异;清单本身不在清单内 |
| `[ ]` | 挂载 ESP:`mountvol S: /s`(盘符按可用的替换) | `S:\` 里能看到 `EFI\` 目录 |
| `[ ]` | 把 `baseline\02-esp-backup\EFI\` 复制回 ESP:`robocopy baseline\02-esp-backup\EFI S:\EFI /E` | **只复制 `EFI\` 子树**;`manifest.sha256` 不复制回 ESP;复制后 `S:\EFI\Microsoft\` 与备份一致 |
| `[ ]` | 重建 Windows 引导:`bcdboot <Windows 盘符>:\Windows /s S: /f UEFI` | 命令成功(无 "Failure when attempting to copy boot files");Windows 盘符按实际替换 |
| `[ ]` | 卸载 ESP:`mountvol S: /d` | ESP 不再占用该盘符,ESP 内容未被后续写操作污染 |
| `[ ]` | 复查四条不变量 | `BootOrder` 首位为 `Windows Boot Manager`;判据以"Windows 能正常启动 + `{bootmgr}` 的 `path` 与 `baseline\02-firmware-entries.txt` 一致 + `BootOrder` 首位未变"为准;`bcdboot` 会从 `C:\Windows\Boot\EFI` 复制 `bootmgfw.efi`、并重建 `\EFI\Microsoft\Boot\BCD`,所以"ESP 逐文件哈希与基线比对"整体**降级为参考信息**(这两个文件的哈希差异记为**预期**,不作为失败判据);`ubuntu` 条目状态与预期一致(留着 / 已删,写进备注) |
| `[ ]` | 跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 复核并留档 | **以 ①(BootOrder 首位)与 ③(`{bootmgr}` 的 `path`)通过 + Windows 能正常启动为准;② 因 `bcdboot` 重建 BCD 报差异属预期**(另:`bcdboot` 还可能新增 `\EFI\Microsoft\Boot\BCD.LOG`、`BCD.LOG1`、`BCD.LOG2` 这类事务日志文件,同样属**预期新增**,不计为偏差),把差异清单记入 `baseline/` 留档;④ BitLocker 的差异按预期记录处理;结论写进备注 |
| `[ ]` | 复原后连续重启 3 次 | 都直接进 Windows,无 `grub>` / `grub rescue>`;需要 Linux 时用 `BOOT_MENU_KEY` 的一次性启动菜单,或在 Windows 侧跑 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(一次性 BootNext,不改启动顺序) |
| `[ ]` | 若 `\EFI\ubuntu\` 也已损坏,且不再需要 Linux | 按 [L5 退役手册](../docs/06-decommission.md) 的五步走:先修 `BootOrder`,再清理条目与残留目录;**不要**先删分区/先删目录 |
