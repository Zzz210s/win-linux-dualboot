# 回滚与救援核对清单(L5)

配合 [07-rescue.md](../docs/07-rescue.md) 的 13 张场景卡使用。四节各管一件事:① 退役五步(`07-9` -> `07-10` -> `07-11` -> `07-12`,变体 `07-13`);② 引导救援(停在 `grub>` / `grub rescue>`,`07-1` / `07-2` / `07-3` / `07-6`);③ 原地重装两法(只格一块分区,`07-4` / `07-5`);④ 基线回滚(ESP 还原 + `bcdboot`,`07-6` / `07-3`)。

用法:执行到哪一项就把"勾选"列的 `[ ]` 改成 `[x]`,并把实测值/偏差写进该行末尾备注(本清单里带 `____` 的地方都要填实测值)。每项都有"判据 / 如何确认"列——**判据不成立就不要往下走**,先按对应卡处置。**部署级回滚**(不涉及分区表)用 [rollback-pkg.sh](../scripts/linux/rollback-pkg.sh)(卡 `05-9`),不属于本清单范围。

三条底线(任何一节都适用):

- **绝不执行 `efibootmgr -o`,也绝不用 `bcdedit /set {fwbootmgr} displayorder ...` 改永久启动顺序**(不变量 I2):进另一个系统只用一次性入口 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)、[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh) 或厂商 `BOOT_MENU_KEY` 菜单;
- **绝不覆盖 `\EFI\Microsoft\`,绝不改 `{bootmgr}` 的 `path`**(I3;唯一例外是按 `07-6` 用 L2 基线把 `\EFI\Microsoft\` 还原回基线状态);
- **绝不先格式化 Linux 分区再修引导**——那正是 `grub rescue>` 的成因;顺序永远是"先让 Windows 回到 `BootOrder` 首位,再删分区"。

## 1. 退役五步(顺序不可更换)

| 勾选 | 卡 | 动作 | 判据 / 如何确认 |
|---|---|---|---|
| `[ ]` | `07-9` | 进 Fedora(`BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)),`sudo efibootmgr -v` 抄下 `BootOrder:` 整行、`Windows Boot Manager` 编号、`fedora` 条目编号与 loader 路径 | 三样都记进本行备注;`fedora` 条目路径为 `\EFI\fedora\shimx64.efi` 或 `\EFI\fedora\grubx64.efi`(shim 与 grub 通常各一条) |
| `[ ]` | `07-9` | 进**固件设置界面**(优先在 Fedora 里 `sudo systemctl reboot --firmware-setup`;不支持时按厂商 Setup 键),把 `Windows Boot Manager` 移到 `BootOrder` 第一位(只用界面,不用工具) | 保存退出后**直接进 Windows**;`efibootmgr -v` 或 `bcdedit /enum firmware` 的 `BootOrder` 第一项是 `Windows Boot Manager`;连续重启 3 次都进 Windows |
| `[ ]` | `07-9` | 偏差分支(固件只给"删除条目"):**① 先回 Windows 备份 -> ② 回 Fedora `sudo efibootmgr -b <fedora 编号> -B` 删条目让固件回落 -> ③ 再重启进 Windows**,三段次序不可颠倒 | 备份**早于**删条目(删条目本身即 NVRAM 变更);删条目后 `BootOrder` 首位是 `Windows Boot Manager`;三段重启次序已写进备注 |
| `[ ]` | `07-10` | 重启进 Windows,管理员会话跑 `backup-esp.ps1 -OutDir D:\dbk-l5-backup`(**不要**用默认的 `-OutDir baseline`,那会覆盖 L2 基线) | `D:\dbk-l5-backup\02-esp-backup\manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt` 三份在位;备份树含 `EFI\Microsoft\` 与 `EFI\fedora\` 两棵子树 |
| `[ ]` | `07-10` | 跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) `-BaselineDir baseline` 复核"动手前"现场未被改动 | ①②③ 三项(引导)全部"通过";④ BitLocker 与 L2 报告的差异属**预期**(L3 收尾已恢复保护),记进备注;判据是"三项引导判据通过、差异被记录",不是"退出码必须为 0" |
| `[ ]` | `07-11` | 对账后精确删除 Fedora 三块分区(ESP-Fedora 1024MB、`/boot` 1024MB ext4、root 约 113GiB btrfs;分区号按 `baseline/02-partitions.txt` 实测)。用 [delete-linux-partition.ps1](../scripts/windows/delete-linux-partition.ps1) 先 `-Check` 看 diff 再 `-Apply -Yes -Partition <n,...>`;脚本拒绝把 Windows ESP / `C:` / `D:` / MSR / WinRE 当目标 | 删前用 `baseline/02-partitions.txt` 与 `D:\dbk-l5-backup\02-partitions.txt` 的偏移/大小逐项对上;删后 `Get-Partition -DiskNumber 0` 的分区数比删前少 3,且其它分区 offset/size 逐项未变 |
| `[ ]` | `07-11` | 复核 ESP / MSR / `C:` / `D:` / WinRE 未被触碰 | 这 5 项仍在,大小与基准一致;多出一处连续未分配空间约 115GiB(位于 `D:` 与 WinRE 之间),不是零散碎块 |
| `[ ]` | `07-12` | 清理 NVRAM 残留 `fedora` 条目([cleanup-nvram.ps1](../scripts/windows/cleanup-nvram.ps1)) | `bcdedit /enum firmware` 里没有 `path` 指向 `\EFI\fedora\...` 的条目;`BootOrder` 首位仍是 `Windows Boot Manager`(**没有**用改顺序代替删除);非目标条目仍在 |
| `[ ]` | `07-12` | 可选扩容:用 [extend-data-partition.ps1](../scripts/windows/extend-data-partition.ps1) 把腾出的 115GiB 扩给 `D:`;或记录"`C:` 不相邻、不扩"的结论 | 二选一写清:(a) `D:` 已扩到 ≈____GiB;(b) 明确记下"`C:` 与未分配空间不相邻"的实测结论(扩展上限 = 未分配空间起点 -> WinRE 起点) |
| `[ ]` | 收尾 | 若步骤 5 之前挂起过 BitLocker,恢复保护 | `manage-bde -protectors -enable C:` 已执行,`manage-bde -status` 显示保护已开启 |
| `[ ]` | 收尾 | 连续重启 3 次做实测 | 每次都直接进 Windows,不出现 `grub>` / `grub rescue>`,也不需要手工选择(设计 8-A、8-D) |
| `[ ]` | 记录 | 把本次偏差写进备注并回写设备参数表 | 偏差项(固件无顺序选项、`bcdedit /delete` 报错、`C:` 不可扩、`D:` 新容量等)都有文字记录;[00-overview.md](../docs/00-overview.md) 参数表已按需更新 |

## 2. 引导救援(停在 `grub>` 或 `grub rescue>`)

先按 `07-1` 判层,再看提示符形态:能敲 `ls`、能看到 `(hd0,gpt1)` 这类设备名的是 `grub>`;**只提示 `grub rescue>` 且 `normal` 用不了**说明 `prefix` 没设对。两条路都只在**引导层**动手,不碰分区表。

| 勾选 | 卡 | 动作 | 判据 / 如何确认 |
|---|---|---|---|
| `[ ]` | `07-1` | 跑 [triage.sh](../scripts/linux/triage.sh) `--check` 判层 | 输出含"判层结论: <引导层/系统层/ESP 层/硬件层>;建议卡号: …",证据逐条列出并记录 |
| `[ ]` | `07-2` | 认清设备名:`ls` 列出 `(hd0)` 与 `(hd0,gptN)`;逐个 `ls (hdX,gptY)/` 找含 `boot/` 的分区 | 记下 `(hdX,gptN)`;报 `unknown filesystem` 的不是目标;`msdosY` 是 MBR 写法,本方案用 GPT,照抄会报错 |
| `[ ]` | `07-2` | 路二(优先):[gen-grub-rescue-commands.sh](../scripts/linux/gen-grub-rescue-commands.sh) 生成后粘贴 `search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` -> `chainloader /EFI/Microsoft/Boot/bootmgfw.efi` -> `boot` | 命令无报错;`boot` 后直接进 Windows(不需要任何手工选择;整条路**不改** ESP / NVRAM / `BootOrder`) |
| `[ ]` | `07-2` | 路一(要进 Linux 排障):粘贴 `set root=(hdX,gptN)` -> `set prefix=(hdX,gptN)/boot/grub` -> `insmod normal` -> `normal` | `echo $prefix` 回显与设定一致;`insmod normal` 无报错(报 `file not found` 说明 prefix 指错);出现正常 GRUB 菜单。这是**临时**修复,进系统后还要按 `07-6` 复盘 |
| `[ ]` | `07-3` | Windows 引导文件缺失/损坏时,管理员会话跑 [repair-windows-boot.ps1](../scripts/windows/repair-windows-boot.ps1) 先 `-Check` 再 `-Apply -Yes` | 后置复读:`{bootmgr}` 的 path 与 `BootOrder` 首位与执行前**逐字一致**;`\EFI\Microsoft\Boot\bootmgfw.efi` 与 `BCD` 在位;ESP 已卸载;`\EFI\fedora\` 未被动过 |
| `[ ]` | `07-6` | ESP 文件树被改写时跑 [restore-esp.ps1](../scripts/windows/restore-esp.ps1) 先 `-Check` 再 `-Apply -Yes`(只复原 `\EFI\Microsoft\`) | 备份树与 `manifest.sha256` 逐条一致后才覆盖;复制后复读一致(`BCD.LOG*` 记"预期新增");`\EFI\fedora\` 执行前后清单完全一致 |
| `[ ]` | `07-3` + `07-6` | 复查四条不变量并留档 | `BootOrder` 首位是 `Windows Boot Manager`;`{bootmgr}` 的 path 与 `baseline/02-firmware-entries.txt` 一致;`\EFI\Microsoft\` 未被第三方接管。`bcdboot` 重建的 `bootmgfw.efi` / `BCD` 差异属**预期**,不作为失败判据 |

## 3. 原地重装两法(只格一块分区)

**共用前提**:`baseline/` 产物齐全可用(分区表、`02-esp-backup/`、固件启动项快照),救援 U 盘在位。**先判断崩溃在哪一层**:只是引导层损坏就**不要重装**,先走「引导救援」节(`07-2`)。

### 3.1 办法一:只重装 Windows(只格 `C:`,卡 `07-4`)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 官方 Windows ISO 引导,进入"自定义安装" | 能列出磁盘与全部分区(不是"看不到驱动器",后者回 [01-firmware.md](../docs/01-firmware.md) 查控制器模式) |
| `[ ]` | **只格式化 `C:`**(200GiB NTFS);`D:`、Fedora 三块、ESP、MSR、WinRE 一律不动 | 安装界面里逐分区核对大小与类型;**没有**执行"删除所有分区";`D:` 与 Fedora 分区的数据仍在(装完进系统后可见) |
| `[ ]` | 让安装程序在 ESP 上重建 `\EFI\Microsoft\` 与 BCD(可能一并覆盖 `\EFI\BOOT\bootx64.efi`,属正常) | 装完能正常进 Windows;`\EFI\fedora\` **仍在** ESP 上(未被安装器删掉) |
| `[ ]` | 首启收尾:关 Fast Startup 与休眠(卡 `03-2`)、重新完成 KMS 激活(`03-4`)、恢复已知文件夹到 `D:` 的重定向(`03-3`) | `powercfg /a` 与电源设置确认休眠关闭;`slmgr /dlv` 显示已激活;六个已知文件夹(`Desktop`/`Documents`/`Downloads`/`Pictures`/`Videos`/`Music`)的值全部以 `D:\` 开头 |
| `[ ]` | 复查四条不变量,并用厂商菜单键验证 Fedora 仍可启动 | `BootOrder` 首位是 `Windows Boot Manager`;`{bootmgr}` 的 path 与基线一致;一次性选 `fedora` 能进系统,重启后默认仍进 Windows |

### 3.2 办法二:只重装 Silverblue(只格 root,卡 `07-5`)

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 先从 live 环境抢救 Linux 侧数据:把 `~`(即 `/var/home`)下要留的代码/密钥/dotfile `rsync -a` 到 `/mnt/shared/` 或外置盘 | 数据已拷出(共享盘上的文档类数据不在格式化范围内) |
| `[ ]` | Fedora 安装 U 盘引导,选"手动分区";装前跑 [check-partition-plan.sh](../scripts/linux/check-partition-plan.sh) `--track D --check` | 分区界面能看到全部分区;目标磁盘与参数表 `DISK` / `DISK_MODEL` / `DISK_SIZE` 一致(防选错盘) |
| `[ ]` | **只格式化 root 并挂 `/`**(约 113GiB btrfs);`/boot`(1024MB ext4)与 ESP-Fedora(1024MB)挂上但**不格式化**;Windows 各分区不参与挂载 | 分区编辑界面里只有 root 那一行带"格式化"勾选;逐个分区核对后再点"下一步" |
| `[ ]` | ESP-Fedora 复用挂 `/boot/efi`,**绝不勾选"格式化 ESP"**(全流程最危险的一步,误格会同时清空 `\EFI\Microsoft\`) | ESP-Fedora 与 `/boot` 那两行的"格式化"未勾选;装完 `/boot/efi/EFI` 下同时存在 `Microsoft` 与 `fedora` 两个目录 |
| `[ ]` | 安装器写入 `\EFI\fedora\`(与 `\EFI\Microsoft\` 并存),期间不改 `BootOrder` | `BootOrder` 首位仍是 `Windows Boot Manager`,`fedora` 在末尾 |
| `[ ]` | 记录"能否保留 `/var` 子卷"的实测结论 | 安装器行为**待核实(以官方文档为准)**;按实测把结论写进备注(能保留 / 不能保留、怎么发现的) |
| `[ ]` | 首启:按 [05-first-boot.md](../docs/05-first-boot.md) 重放驱动、挂载、家目录重定向、时间、蓝牙与健壮性配置 | `baseline/04-first-boot.md` 与 `04-robustness.md` 的判据逐项复现;连续重启 3 次都默认进 Windows |

## 4. 基线回滚(引导层损坏而系统分区完好时用:卡 `07-6` + `07-3`)

设计 4.8 的"第三选择":**不是重装**,而是用 ESP 备份还原 `\EFI\Microsoft\` + `bcdboot` 重建 + 清理 NVRAM。**执行环境**:复原动作在 Windows 管理员会话或 WinRE 命令提示符中执行;WinRE 里若 `powershell` 起不来,用 `certutil -hashfile <文件> SHA256` 代替 `Get-FileHash`(不带算法参数时默认 SHA1,必须显式写 `SHA256`;输出为大写十六进制,与清单比对时忽略大小写),或回到 Windows 管理员会话执行。

| 勾选 | 动作 | 判据 / 如何确认 |
|---|---|---|
| `[ ]` | 先确认崩溃层级:系统分区数据完好、只是引导不进/进错 | 能从 live 环境看到 Windows `C:` 上的 `\Windows\` 与 `D:` 上的数据;分区数、大小与 `baseline/02-partitions.txt` 一致 |
| `[ ]` | 校验备份完整性(脚本 `-Check` 已做这一步) | `baseline/02-esp-backup/manifest.sha256` 与备份文件逐条一致、无清单外文件;清单本身不在清单内 |
| `[ ]` | 挂载 ESP:`mountvol S: /s`(盘符按可用的替换) | `S:\` 里能看到 `EFI\` 目录 |
| `[ ]` | 只把 `EFI\Microsoft\` 子树放回(脚本 `-Apply -Yes` 做这件事) | **只复原 `\EFI\Microsoft\`**;`manifest.sha256` 不复制回 ESP;`\EFI\fedora\` 一律不动(它不在 L2 基线里) |
| `[ ]` | 重建 Windows 引导:`bcdboot <Windows 盘符>:\Windows /s S: /f UEFI` | 命令成功(无 "Failure when attempting to copy boot files");Windows 盘符按实际替换 |
| `[ ]` | 卸载 ESP:`mountvol S: /d` | ESP 不再占用该盘符,ESP 内容未被后续写操作污染 |
| `[ ]` | 清理 NVRAM 残留条目(卡 `07-12`) | 指向已不存在文件的条目消失;**用删除代替改顺序**,没有用 `displayorder` / `efibootmgr -o`(I2) |
| `[ ]` | 复查四条不变量并跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 留档 | 以 ①(`BootOrder` 首位)与 ③(`{bootmgr}` 的 `path`)**通过 + Windows 能正常启动**为准;② 因 `bcdboot` 重建 BCD 报差异属**预期**(`BCD.LOG*` 同样属预期新增);④ BitLocker 差异按预期记录;结论写进备注 |
| `[ ]` | 复原后连续重启 3 次 | 都直接进 Windows,无 `grub>` / `grub rescue>`;需要 Linux 时用 `BOOT_MENU_KEY` 或在 Windows 侧跑 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1) |
| `[ ]` | 若 `\EFI\fedora\` 也已损坏,且不再需要 Linux | 它不在 L2 基线清单里(**L2 基线生成于装 Fedora 之前**):两条真实来源与完整命令见 `07-6` 的"出错时"与 [07-rescue.md](../docs/07-rescue.md) 文末一节;先修 `BootOrder` 再动条目,**不要**先删分区/先删目录 |

## 5. 不可逆项(动手前先读这一遍)

- **格式化分区不可逆**:`D:` 的文档数据、Fedora root 上的代码与密钥、`/boot` 上的旧部署,三者任一被格式化就只能靠外部备份或数据恢复;
- **误格 ESP 会连带毁掉 Windows 引导**,恢复手段是 `baseline/02-esp-backup/`(前提是它可用且未过期);`\EFI\fedora\` **不在**这份基线里,只能按 `07-6` 文末的两条来源重建;
- **`bcdboot` 重建的 BCD 与 `bootmgfw.efi` 无法"退回原样"**,只能重建——这也是判据改成"能正常启动 + `{bootmgr}` 的 path 一致"的原因;
- **删除 NVRAM 条目后,该系统的"默认启动能力"需要重新建立**(本方案里不需要:进 Linux 一律走一次性入口)。所以删条目永远排在"先备份"之后。
