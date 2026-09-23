# 07:救援与退役(场景卡:先判断层级,再决定动不动分区)

本文件在流程中的位置:`05-first-boot`(轨道 L:L4 首启收敛)-> **本文件(L5:救援与退役)** -> `08-verification`。

目标状态、四条不变量(I1-I4)与参数名在[入口文档](00-overview.md)中定义;依据见[设计文档](design/00-design.md) 第 2 节(I1-I4)、4.6 节(L5 退役五步,**顺序不可更换**)、4.8 节(崩溃后原地重装两法与"第三选择")、第 7 节(故障矩阵、7.1 周期巡检与 SBAT 事故、7.2 回滚粒度)与第 9 节,以及[变体设计](design/04-kubuntu-variant-design.md) 第 7 节(回退降级为包级回退 + 原地重装后的替代方案);卡格式见[设计文档](design/01-playbook-reshape-design.md) 第 3 节(R1-R7)。

**先判断层级,再动手。** "进不去系统"有三种完全不同的原因——引导层损坏、系统分区损坏、硬件故障;**只有第二、三种才需要动分区**,引导层损坏一律先修引导(`07-2` / `07-3` / `07-6`),不要重装(设计 4.8 的"第三选择")。**明确禁止"先格式化 Linux 分区再修引导"**:删掉分区的一瞬间真正消失的是 `/boot` 上的内核与 GRUB 模块,而固件里的 `ubuntu` 条目仍指着已删除的 `\EFI\ubuntu\shimx64.efi` 并可能排在启动顺序前面,开机就停在 `grub rescue>`——这正是该事故形态的成因,也是"必须先把引导归位、再删分区"的全部理由(设计 4.6)。

## 开始前

- 什么时候用:出事时才读(进不去、引导异常、要撤除 Linux);**先跑 `07-1` 判层,再按结论选卡**,不要跳过判层直接重装。
- 需要的东西:`baseline/02-esp-backup/`(含 `manifest.sha256`)、`02-firmware-entries.txt`、`02-partitions.txt` 在位可读(I4);常备 Kubuntu 安装 U 盘;BitLocker 48 位恢复密钥在手。
- 产物落点:救援**不改** `baseline/` 里 L0-L4 的既有产物;退役前的现状备份写到仓库外 `D:\dbk-l5-backup\`(见 `07-10`);巡检输出按 [baseline/README.md](../baseline/README.md) 留档。
- 纪律:进另一个系统只用一次性入口(`BOOT_MENU_KEY`、[set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)、[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh));不执行 `efibootmgr -o` / `bcdedit displayorder`、不覆盖 `\EFI\Microsoft\`、不改 `{bootmgr}` 的 `path`(I1-I3);反复长按电源会把"一次引导故障"升级成"文件系统损坏"。

### 07-1 判层:崩溃在哪一层,决定动不动分区

做:跑只读判层脚本采集现场,按结论选卡;本卡不改任何东西。
  1. `scripts/linux/triage.sh --check`(需 root 读 `efibootmgr -v`;读不到会报"需人工"并给 sudo 指引)
     看到:输出含 `判层结论: <引导层|系统层|ESP 层|硬件层>;建议卡号: …`,并逐条列出证据(分区/挂载/固件条目/两块 ESP 内容/包管理与错误日志)
  2. 按结论分派:引导层 -> `07-2`(GRUB 提示符)或 `07-3`(Windows 侧);ESP 层 -> `07-6`;系统层 -> `07-4` / `07-5`;硬件层 -> 按 `07-8` 处置,**不要格式化任何分区**
     看到:结论与建议卡号已写进文字记录(这行记录就是"崩溃层级有明确结论"的证据)
脚本:scripts/linux/triage.sh --check(只读,与 --apply 输出相同)
坑:跳过判层直接重装,会把"敲几条命令能修好的引导故障"升级成"格式化一块分区 + 重放一整天的配置";把硬件层误判成系统层会白格一块盘(设计 4.8 的"第三选择")。
出错时:读不到 `efibootmgr` -> 用 `sudo` 重跑或在 live 环境跑;证据互相矛盾 -> 先按 `07-8` 停手复核,不要写盘。

### 07-2 停在 `grub>` / `grub rescue>`:两条可复制的恢复命令

做:先认清设备名,再按生成脚本给出的命令走;优先"路二"先拿回 Windows。
  1. 生成两套命令(只打印,不执行):`-d 0 --esp-part 1 --root-part 7` 的盘号/分区号以 `baseline/02-partitions.txt` 为准
     看到:输出含两套——回 Windows 的 `insmod chain` + `search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` + `chainloader` + `boot`,以及修 GRUB 的 `ls` + `set root=` + `set prefix=(hdX,gptN)/boot/grub` + `insmod normal` + `normal`
  2. 路二(优先):在提示符里逐条粘贴回 Windows 的那组
     看到:进入 Windows 桌面、不需要任何手工选择;整条路不写 ESP、不改 NVRAM、不改 `BootOrder`
  3. 路一(要进 Linux 排障时):粘贴 `set prefix` 那组,进系统后还要做持久修复
     看到:`echo $prefix` 回显与设定一致;`insmod normal` 无报错;`normal` 后出现正常菜单
脚本:scripts/linux/gen-grub-rescue-commands.sh -d 0 --esp-part 1 --root-part 7
坑:现代 GPT 盘的分区写作 `(hdX,gptY)`,照抄旧教程的 `msdosY` 会报 `unknown filesystem`;`set prefix` 指到 ESP 的 `/EFI/ubuntu` 里会 `insmod normal` 报 `file not found`(那里只有 stub,没有模块目录);这是**临时**修复,重启照旧。
出错时:`ls` 列不出任何分区 -> 先 `insmod part_gpt` 再试,仍不行改从固件启动菜单选 `Windows Boot Manager` 后按 `07-3` 修;报 `invalid signature` -> 按 `07-7` / `07-8` 处置,不要关闭 Secure Boot。

### 07-3 Windows 侧修引导:挂 ESP + `bcdboot` 重建 `\EFI\Microsoft\`

做:`C:\Windows` 还在、只是 Windows 引导坏了时,在管理员会话跑脚本挂 ESP、重建引导、复读校验。
  1. 先空跑 `-Check`
     看到:打印将执行的 `mountvol <ESP>: /s`、`bcdboot <WindowsDir> /s <ESP>: /f UEFI`、`mountvol <ESP>: /d`,并给出当前 `{bootmgr}` 的 path;此时零写
  2. `-Apply -Yes` 执行
     看到:脚本报 PASS,复读打印 `{bootmgr}` 的 path 与 BootOrder 首位**与执行前逐字一致**、ESP 上 `\EFI\Microsoft\Boot\bootmgfw.efi` 与 `BCD` 在位、ESP 已卸载
脚本:scripts/windows/repair-windows-boot.ps1 -Check / -Apply -Yes
坑:`bcdboot` 会重写 `bootmgfw.efi` 与 `BCD`(这是它的职责,属预期),但**绝不允许** `{bootmgr}` 的 path 或 `BootOrder` 首位变化(I1/I3);`-WindowsDir` 盘符搞错会往错的卷上写引导文件;`\EFI\ubuntu\` 一律不动。
出错时:`bcdboot` 报 `Failure when attempting to copy boot files` -> 依次查盘符、ESP 是否已挂载且为 FAT32、ESP 剩余空间;ESP 上 `\EFI\Microsoft\` 已缺失 -> 先按 `07-6` 放回文件再重跑;仍不行 -> `07-4`。

### 07-4 办法一:只重装 Windows(只格式化 `C:`)

做:只在 Windows 系统分区已损坏时用;官方 ISO 引导 -> 自定义安装 -> **逐分区核对后只格式化 `C:`(200GiB NTFS)**。
  1. 能进系统就先按 `07-10` 备份现状,并确认 BitLocker 恢复密钥在手
     看到:备份树含 `EFI\Microsoft\` 与 `EFI\ubuntu\` 两棵子树,`manifest.sha256` 就位
  2. 安装界面里逐项核对:`C:` 200GiB NTFS、`D:` 约 635GiB NTFS、Ubuntu 三块(ESP-Ubuntu 1GiB FAT32 / `/boot` 1GiB ext4 / root 约 113GiB ext4)、ESP 2GiB、MSR 16MiB、WinRE 约 1GiB
     看到:安装器只对 `C:` 执行格式化;`D:`、Ubuntu 各分区、ESP、MSR、WinRE 未被标成格式化,也没有"删除所有分区"
  3. 装完让安装器在 ESP 上重建 `\EFI\Microsoft\` 与 BCD,再按 `03-2`(关快速启动)、`03-3`(已知文件夹重定向到 `D:`)、`03-4`(激活)收尾
     看到:能正常进 Windows;六个已知文件夹的值以 `D:\` 开头;装完先挂 ESP 看 `\EFI\ubuntu\` 是否还在
脚本:scripts/windows/verify-windows-baseline.ps1(装完核对版本/分区布局/WinRE 偏差;安装动作人工)
坑:格式化不可逆,`D:` 的文档数据、Ubuntu root 上的代码与密钥、`/boot` 上的旧内核都只能靠外部备份;**`\EFI\ubuntu\` 不在 L2 基线里**(基线生成于装 Kubuntu 之前);安装器新建或挪动 WinRE 属已登记偏差,写进 `baseline/` 即可,不要为此挪分区。
出错时:看不到驱动器 -> 回 [01-firmware.md](01-firmware.md) 查控制器模式(AHCI / NVMe、VMD 关闭),不要反复重试;`\EFI\ubuntu\` 被安装器清掉 -> 按文末「重建的两条来源」重建并补条目。

### 07-5 办法二:只重装 Kubuntu(只格式化 root,ESP 绝不勾格式化)

做:只在 root 损坏时用;Kubuntu U 盘引导 -> Calamares 手动分区 -> **只格式化 root 并挂 `/`**。
  1. 先从 live 环境抢救数据并确认现场:把 `~`(`/home/<用户名>`)下要留的东西 `rsync -a` 到 `/mnt/shared/` 或外置盘
     看到:数据已拷出;Windows `C:`、`D:` 都在、分区数与 `baseline/02-partitions.txt` 一致(这是"root 损坏"而不是"分区表故障")
  2. 装前跑核对脚本,再在 Calamares 里只指定挂载点:`/boot/efi`(ESP-Ubuntu,复用)、`/boot`(复用)、`/`(root,唯一勾格式化)
     看到:分区列表里只有 root 那行带"格式化";ESP-Ubuntu 与 `/boot` 的"格式化"**未勾选**;Windows 各分区不参与挂载
  3. 装完按 `04-3` 复核,再按 `05-1` 起的各卡重放配置
     看到:`/boot/efi/EFI` 下 `ubuntu` 与 `Microsoft` 并存;`BootOrder` 首位仍是 Windows Boot Manager
脚本:scripts/linux/check-partition-plan.sh --track D --check(安装动作人工)
坑:**勾了"格式化 ESP"会同时清空 `\EFI\Microsoft\`,让 Windows 也进不去——这是全流程最危险的一步**(I3、设计 4.8 办法二);`/boot` 勾格式化会丢掉旧内核与 GRUB 模块,装完要重跑 `update-grub`;点"下一步"之前退回取消是无损的。
出错时:只看到 U 盘 -> 回 [01-firmware.md](01-firmware.md) 查控制器模式;已误格 ESP -> 按 `07-6` 用基线放回 `\EFI\Microsoft\`、按 `07-3` 重建,`\EFI\ubuntu\` 按文末「重建的两条来源」重建。

### 07-6 第三选择:基线回滚(ESP 还原 + `bcdboot` + NVRAM 清理)

做:引导层损坏而系统分区完好时,用 L2 基线把 `\EFI\Microsoft\` 放回去再重建引导;这不是重装。
  1. 先 `-Check`:脚本先校验备份树自身(逐文件哈希 + 清单外文件)并打印将复原的清单
     看到:备份与 `baseline/02-esp-backup/manifest.sha256` 逐条一致;此时零写、ESP 未被挂载
  2. `-Apply -Yes`:只复制清单里 `EFI/Microsoft/` 的文件,复制后复读比对
     看到:脚本报 PASS;`\EFI\ubuntu\` 执行前后文件清单完全一致(本卡绝不还原、不创建它);比清单多出的 `BCD.LOG*` 记为"预期新增"
  3. 按 `07-3` 重建引导(`bcdboot`)、按 `07-12` 清理指向已不存在文件的 NVRAM 条目,最后连续重启 3 次
     看到:`{bootmgr}` 的 path 与 `baseline/02-firmware-entries.txt` 一致;每次都直接进 Windows,不出现 `grub>` / `grub rescue>`
脚本:scripts/windows/restore-esp.ps1 -Check -BaselineDir baseline / -Apply -Yes
坑:备份源不一致时脚本**拒绝覆盖**(64 零写),先用 `07-10` 重做备份;`bcdboot` 会重写 `bootmgfw.efi` 与 `BCD`,所以"ESP 逐文件哈希与基线一致"这一条**降级为参考信息**(差异属预期);复原动作要在管理员会话或 WinRE 里做。
出错时:`\EFI\ubuntu\` 也没了 -> 它不在 L2 基线里,按文末「重建的两条来源」处理;`mountvol` 挂不上 ESP -> 换盘符,仍失败说明分区表层有问题,回 `07-1` 重新判层。

### 07-7 周期巡检(Windows 大版本 / 累积更新之后)

做:每次更新之后复核四项基线,顺带看 Linux 侧的系统体检与模块签名;只看不改。
  1. 管理员会话跑 Windows 侧巡检
     看到:四项逐条给"通过 / 需人工介入"——① `BootOrder` 首位仍是 Windows Boot Manager;② `\EFI\Microsoft\` 与 `manifest.sha256` 逐文件一致;③ `{bootmgr}` 的 `path` 与基线一致;④ BitLocker 状态与 `02-preflight-report.md` 的记录一致
  2. 在 Kubuntu 里跑系统体检与模块签名
     看到:`scripts/linux/check-health.sh --check` 报 PASS(会话为 wayland、snap 零残留、`systemctl is-system-running` 为 running、根分区余量 ≥10%)或逐条给出失败项;`scripts/linux/check-signature.sh --check` 报 PASS(签名者非空且 Secure Boot enabled)或"需人工"
  3. 把巡检输出连同结论记进 `baseline/` 或清单备注
     看到:四项结论与偏差都有文字;没有为了"让基线成立"去改 `baseline/` 的既有记录
脚本:scripts/windows/verify-baseline.ps1 -BaselineDir baseline;scripts/linux/check-health.sh --check;scripts/linux/check-signature.sh --check
坑:更新之后 ESP 出现差异要当"引导被接管"处理,先按 `07-1` 判层,而不是先重做基线;`bcdboot` 重建过 BCD 的设备,②项的差异属预期(记备注);签名者取不到时不要关 Secure Boot(那会破坏预签名 NVIDIA 包路径),补救走 `05-3`。
出错时:① 或 ③ 不符 -> 按 `07-3` / `07-6` 复原并把偏差写进备注;更新后两个系统都进不去但分区与文件都在 -> 属 SBAT / DBX 类事故(微软 2024-08 起推送的 DBX 会把旧 SBAT 判为过旧):清 SBAT 策略(Windows 侧清 `SbatLevel` 注册表值,Linux 侧 `sudo mokutil --set-sbat-policy delete`)后再按 `07-3` / `07-6` 复原;具体键值名与命令**以官方公告为准**。

### 07-8 排障纪律(出事后最容易犯的四个错)

做:把四条纪律当硬约束;本卡无脚本。
  1. **不要反复长按电源强制重启**:优先切 TTY(`Ctrl + Alt + F3`),内核无响应时用 SysRq 安全重启(依次 `R` `E` `I` `S` `U` `B`;`/proc/sys/kernel/sysrq` 只开放 `S`/`U`/`B` 时直接按 `S` -> `U` -> `B`,位掩码以实测为准);已强断过就先 `fsck`(设备名按 `baseline/02-partitions.txt`,如 `sudo fsck -f /dev/nvme0n1p7`)
     看到:重启走"落盘 + 只读重挂"的干净路径;`fsck` 无报错或已修掉
  2. **桌面崩了不等于系统坏了**:先 SSH 进来(或切 TTY)看 `journalctl -b -1 -p err`,必要时在 GRUB "Advanced options" 选旧内核
     看到:拿到了日志;能在旧内核下进桌面
  3. **两个系统一起死机/蓝屏 -> 先查硬件**:`memtest86+`、`sudo smartctl -H /dev/nvme0n1`、温度与电源;**先不要格式化任何分区**
     看到:硬件结论明确;本步没有发生任何写盘动作
  4. **驱动不被识别时先换内核(HWE 内核栈)、再换驱动版本,不降发行版**
     看到:改动只落在内核/驱动层,发行版未变(设计 3.17 被否方案)
脚本:无(纪律条款)
坑:强断会把"一次引导故障"升级成"文件系统损坏",最后两个系统一起进不去;把硬件故障当成双系统互扰,会白格一块盘;"降发行版"换来的是更短支持期与更差的新硬件兼容性。
出错时:已经格式化错或已强断过 -> 先回 `07-1` 判层,再按本卡第 1 条修文件系统;`smartctl` 报 FAILED -> 先换盘再谈装系统。

### 07-9 退役第一步:把 Windows Boot Manager 归位为 `BootOrder` 首位

做:**先归位、再删分区**(退役五步顺序不可更换);永久顺序只能在固件设置界面改,脚本只用一次性 `bootsequence`。
  1. 只读记录现状:`sudo efibootmgr -v`,抄下 `BootOrder:` 整行、`Windows Boot Manager` 编号、`ubuntu` 条目的编号与 loader 路径(通常 shim 与 grub 各一条)
     看到:三样都记进备注;`ubuntu` 条目路径形如 `\EFI\ubuntu\shimx64.efi` 或 `\EFI\ubuntu\grubx64.efi`
  2. `-Check`:确认首位是否已是 Windows Boot Manager
     看到:已是 -> PASS 且给出"无需动作";不是 -> FAIL 并打印人工步骤(进固件设置界面 `Boot Order` 把 Windows Boot Manager 移到第一位)
  3. `-Apply -Yes`:设一次性 `bootsequence` 让下次启动落在 Windows,随后复读断言
     看到:复读打印 BootOrder 逐字未变且首位仍是 Windows Boot Manager、`{bootmgr}` 的 path 未变;保存退出后**直接进 Windows**
  4. 偏差分支(固件只给"删除条目"、不给顺序调整):① 先按 `07-10` 做备份 -> ② 回 Kubuntu 执行 `sudo efibootmgr -b <ubuntu 编号> -B` 删条目让固件回落 -> ③ 重启进 Windows 继续 `07-11`
     看到:备份**早于**删条目;条目删除后 `BootOrder` 首位是 Windows Boot Manager;三段重启的次序写进备注
脚本:scripts/windows/restore-boot-order.ps1 -Check / -Apply -Yes
坑:用 `bcdedit /set {fwbootmgr} displayorder` 或 `efibootmgr -o` 改永久顺序即违反 I2——固件才是永久顺序的权威,用工具"赢了"只是暂时现象;删条目本身是一次 NVRAM 变更,所以备份必须在前。
出错时:改完顺序重启仍进 Linux -> 回固件设置界面再设一次(部分固件要再确认一次退出),不要改用 `efibootmgr -o`;重启停在 `grub>` / `grub rescue>` -> 按 `07-2` 现场处置,**立即停手不要删任何分区**。

### 07-10 退役第二步:备份当前 NVRAM 与 ESP 现状(最后一道保险)

做:在不动任何东西的前提下,把"动手前"的现场整份存到**仓库外**;这份备份没做完,就不要往下走。
  1. 管理员会话把现状备份到数据盘(产物名沿用基线口径,但**不要**写进 `baseline/`)
     看到:`D:\dbk-l5-backup\02-esp-backup\manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt` 三份在位;备份树含 `EFI\Microsoft\` 与 `EFI\ubuntu\` 两棵子树
  2. 与 L2 基线比对,确认"动手前"现场未被改动
     看到:① `BootOrder` 首位、② `\EFI\Microsoft\` 逐文件、③ `{bootmgr}` 的 path 三项"通过";④ BitLocker 若与 L2 记录不同(L3 收尾已重新启用保护)属**预期差异**,记进备注
  3. 把只读取证输出(`efibootmgr -v`、`lsblk -o NAME,SIZE,FSTYPE,PARTUUID,MOUNTPOINT`)也拷到共享盘或外置盘,别留在 `~/`
     看到:仓库外可读;本步没有任何写 ESP / 写 NVRAM / 改分区的动作
脚本:scripts/windows/backup-esp.ps1 -OutDir D:\dbk-l5-backup;scripts/windows/verify-baseline.ps1 -BaselineDir baseline
坑:用默认 `-OutDir baseline` 会覆盖 L2 基线(它正是本阶段的比对基准与回滚源);这批产物是**仓库外产物、不是基线**,不要拷进 `baseline/`(见 [baseline/README.md](../baseline/README.md))。另:`backup-esp.ps1` **默认模式就执行备份**,本卡不加 `-Check`(它只校验已有备份),该脚本也没有 `-Apply` 参数(写了会被 PowerShell 参数绑定拦下、退 1)。
出错时:清单文件数与备份树对不上 -> 先解决磁盘/权限问题再继续;`verify-baseline.ps1` 退出码 1 但只有 ④ 有差异 -> 属预期,记备注后继续。

### 07-11 退役第三步:删 Ubuntu 分区(只按分区号 / GPT GUID 精确删)

做:**引导已归位、备份已做完**之后才动手;三块 Ubuntu 分区一并删除(ESP-Ubuntu 与 `/boot` 也在其中,别只删 root),Windows 侧一个都不动。
  1. 先 `-Check`,按 `baseline/02-partitions.txt` 与 `D:\dbk-l5-backup\02-partitions.txt` 的偏移/大小逐项对账确认目标(ESP-Ubuntu 1024MB、`/boot` 1024MB ext4、root 约 113GiB ext4;分区号以实测为准)
     看到:打印分区表 diff(执行前 / 计划执行后),列出将删除的分区号与大小;此时零写
  2. `-Apply -Yes -Partition <5,6,7> -WinEspNumber 1`(或 `-PartitionGuid <GUID>`;目标是 Windows ESP / `C:` / `D:` / MSR / WinRE 时脚本 64 拒绝、零写)
     看到:复读断言——目标分区消失、其它分区 offset/size 逐项未变、最大连续未分配空间约 115GiB、`BootOrder` 首位仍是 Windows Boot Manager、`{bootmgr}` path 未变
  3. 删完复核 ESP / MSR / `C:` / `D:` / WinRE 未被触碰,并把偏差记进备注
     看到:这 5 项的大小与基准一致;多出一处连续未分配空间(位于 `D:` 与 WinRE 之间)
脚本:scripts/windows/delete-linux-partition.ps1 -Check -Partition <n,...> / -Apply -Yes -Partition <n,...> -WinEspNumber <n>
坑:删分区不可逆,Ubuntu root 上的代码与密钥、`/boot` 上的旧内核全部消失;**Windows ESP 与 Windows 各分区绝不允许成为目标**;绝不用 `diskpart clean` / "删除所有分区";**绝不先格式化 Linux 分区再修引导**——那正是 `grub rescue>` 的成因(固件条目仍指着已删除的引导文件且排在前面)。
出错时:认不出哪块是 Ubuntu 分区 -> **停下不要猜**,用两份分区快照对账;误删了 `D:` 或 ESP -> 立刻停止一切写盘,ESP 走 `07-6`、`D:` 优先评估数据恢复,不要在盘上写新数据。

### 07-12 退役第四步:清 NVRAM 残留条目,并可选把空间扩给 `D:`

做:先删指向已不存在文件的 `ubuntu` 条目,再把腾出的空间扩给 `D:`(不是 `C:`);两件事各自有前置断言。
  1. 先 `-Check`:列出将删除的条目,并断言首位
     看到:列出 path 指向 `\EFI\ubuntu\` 或 description 含 ubuntu 的条目;`BootOrder` 首位仍是 Windows Boot Manager;此时零写
  2. `-Apply -Yes` 删除条目(执行前后都断言首位)
     看到:目标条目消失、非目标条目仍在、`BootOrder` 逐字未变且首位仍是 Windows Boot Manager、`{bootmgr}` path 未变;残留条目若删不掉,只要首位仍是 Windows 就不影响结论
  3. 可选扩容:先 `-Check` 确认 `D:` 紧邻那段未分配空间
     看到:输出"D: 紧邻连续未分配空间"的计划;`C:` 与未分配空间不相邻时脚本给"`C:` 不可扩"的结论并以 64 拒绝(不要为给 `C:` 扩容去动 `D:`)
  4. `-Apply -Yes` 扩展 `D:`,再复读
     看到:`D:` 变大且起点未变、`C:` 未被扩、其它分区 offset/size 未变;新容量约到 WinRE 起点为止(盘尾 WinRE 不可移动,扩不满 115GiB 是正常的)
脚本:scripts/windows/cleanup-nvram.ps1 -Check / -Apply -Yes;scripts/windows/extend-data-partition.ps1 -Check / -Apply -Yes
坑:不得用 `displayorder` 之类改序动作代替删除条目(I2);条目删不掉、或下次开机又出现,只要首位是 Windows 就不影响"能安全撤除"的结论;`C:` 在本方案布局下与未分配空间不相邻,扩不了是布局决定的,不是操作问题(设计 3.5)。
出错时:`bcdedit /delete` 报 `The delete command specified is not valid` -> 换固件设置界面的"删除启动项",或从 live 环境 `sudo efibootmgr -b <编号> -B`;扩展报空间不足/卷被占用 -> 确认无页面文件与休眠文件占用(快速启动保持关闭),并在两侧停掉相关进程。

### 07-13 只停用不删(变体:暂时不想再被 Linux 打断)

做:做到 `07-9` 就可以停;要更干净一点就再停用条目——**不删分区、不删条目**。
  1. `-Check`:确认分区数量与基线一致(证明前面没动过分区)
     看到:分区数与 `baseline/02-partitions.txt` 一致;`BootOrder` 首位仍是 Windows Boot Manager;此时零写
  2. `-Apply -Yes`:设一次性 `bootsequence` 回落 Windows,并提示人工在固件设置界面把 `ubuntu` 条目移到最后
     看到:复读断言 BootOrder 未变、首位仍是 Windows Boot Manager、`{bootmgr}` path 未变、分区一个没动
  3. 两种收尾选一个并记进备注:A 只做 `07-9`,条目保留(要用 Linux 时按 `BOOT_MENU_KEY` 或从 Windows 跑 `04-1` 的一次性入口);B 做 `07-9` + 本卡,体验等同已退役但仍能回到"两个系统都能用"
     看到:没有"删了分区却把条目留在首位"这种半程状态——那就是 `grub rescue>` 的成因;偏差已回写 [00-overview.md](00-overview.md) 的设备参数表
脚本:scripts/windows/disable-linux-entry.ps1 -Check / -Apply -Yes
坑:本卡与 `07-12` 的区别是那个**删条目**、本卡连条目都不删,所以可逆;Windows 大版本更新或 SBAT 更新仍可能改写 ESP 让 **Linux** 引导失效(设计 7.1),但那不会影响 Windows 启动。
出错时:分区数量与基线对不上 -> 说明分区表已被改动过,先人工核对(必要时按 `07-10` 重做备份)再重跑;想彻底撤除 -> 从 `07-11` 起走完退役。

## `\EFI\ubuntu\` 不在 L2 基线里:重建的两条真实来源

`baseline/02-esp-backup/` 由 L2 预检产出,而 L2 生成于装 Kubuntu **之前**,所以里面**没有** `EFI/ubuntu/`——不能用它还原 Ubuntu 引导(基线只能复原 `\EFI\Microsoft\`,固件条目现状看 `baseline/02-firmware-entries.txt`)。

**(a) 做过 L5 退役备份的**:用 `D:\dbk-l5-backup\02-esp-backup\EFI\ubuntu\`(那是 `07-10` 写出的备份,含两棵子树):

```powershell
mountvol S: /s
robocopy D:\dbk-l5-backup\02-esp-backup\EFI\ubuntu S:\EFI\ubuntu /E
mountvol S: /d
```

条目也丢了时补建一条:`sudo efibootmgr -c -d /dev/nvme0n1 -p 5 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'`(盘与分区号按 `baseline/02-partitions.txt` 替换),建完**立刻断言** `BootOrder` 首位仍是 `Windows Boot Manager`。

**(b) 没有现成备份的**:从 live 环境重建(必须以 UEFI 启动:先 `ls /sys/firmware/efi` 确认存在;盘与分区号按 `baseline/02-partitions.txt` 替换):

```bash
sudo mount /dev/nvme0n1p7 /mnt                  # Ubuntu root
sudo mount /dev/nvme0n1p5 /mnt/boot/efi         # ESP-Ubuntu
sudo mount /dev/nvme0n1p6 /mnt/boot             # /boot(独立 ext4)
for d in dev dev/pts proc sys run; do sudo mount --rbind /$d /mnt/$d; done
sudo chroot /mnt /bin/bash
dpkg -l grub-efi-amd64-signed shim-signed       # 两个包必须在位,缺了用 apt-get install --reinstall 补
grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu   # 它自建 NVRAM ubuntu 条目,不要再手工 efibootmgr -c
update-grub
exit
sudo umount -R /mnt
sudo efibootmgr -v
```

若 `grub-install` 未写入 NVRAM(或 `efibootmgr -v` 里看不到 `ubuntu`),用上面的 `efibootmgr -c` 兜底补建一条,再断言首位是 `Windows Boot Manager`;出现重复条目用 `sudo efibootmgr -b <编号> -B` 清理。`shimx64.efi` 与 `grubx64.efi` 是一对,不要从别的机器或别的系统抄文件;全程保持 Secure Boot 开启(走 shim 签名链,设计 3.3)。

**initramfs 由 dracut 生成**(Ubuntu 26.04 起):需要重建 initramfs 时用 `dracut -f`,不要照抄 Debian 系的 `update-initramfs -u` —— `# 待核实(以官方文档为准)`。

验收与回退:D 组"锚设备真做一次 L5 退役"见 [08-verification.md](08-verification.md);退役、引导救援、原地重装与基线回滚四节勾选清单见 [checklists/rollback.md](../checklists/rollback.md);症状速查见 [10-faq.md](10-faq.md)。
