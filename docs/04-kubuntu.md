# 04:Kubuntu 26.04 LTS 安装(轨道 L:L3,不侵犯 Windows 引导)

本文件在流程中的位置:`02-partitioning`(底座:分盘)-> **本文件(轨道 L:L3 安装)** -> `05-first-boot`。

目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;分区数值与分盘动作在 `02-partitioning.md`(本文件不复述);依据见[设计文档](design/00-design.md) 4.4 节(L3)、5.1 节(分区表)与第 7 节(故障矩阵),以及[变体设计](design/04-kubuntu-variant-design.md) 第 4 节(分区表)与第 5 节(Calamares 与三轨道)。

**本阶段最危险的动作只有一个:把某块分区勾成"格式化"。** 它会在几秒内清空 `\EFI\Microsoft\`(或 Ubuntu 侧的 `\EFI\ubuntu\` 与 `/boot`),让系统进不去;此时唯一的退路是 L2 基线。L3 其余步骤都可以慢,这一条不能错。

## 开始前

- 前提:L2 硬闸门已通过(`baseline/02-preflight-report.md` 末行是 `结论: 允许进入 L3`、红项为"无");基线四件齐备;BitLocker 处于挂起状态,L3 期间不重新启用。
- 需要的东西:Kubuntu 26.04 LTS 官方安装 U 盘(ISO 已在 L0 按官方 `SHA256SUMS` 校验)、参数表 `DISK_MODEL` / `DISK_SIZE`、厂商 `BOOT_MENU_KEY`。
- 产物落点:`baseline/03-efi-layout.txt`(六节);多设备放 `baseline/<设备别名>/`,全部不入库(见 [baseline/README.md](../baseline/README.md))。
- 纪律:全程不改 `BootOrder`、不执行 `efibootmgr -o`、不覆盖 `\EFI\Microsoft\`、不改 `{bootmgr}` 的 path(I1-I3);Secure Boot 全程开启,不自签密钥。

### 04-1 以 UEFI 模式从安装 U 盘启动,进 live 环境

做:从 Windows 侧把"下次启动"设成一次性从安装 U 盘启动,再重启进 live;不动永久启动顺序。
  1. 管理员会话先空跑看计划,确认后加 `-Apply -Yes` 执行(脚本只设一次性 `bootsequence`,用过即消失)
     看到:`-Device USB -Check` 打印目标条目与 `bcdedit /set {fwbootmgr} bootsequence {GUID}`;`-Device USB -Apply -Yes` 执行后打印"I1 断言通过:BootOrder 首位仍是 Windows Boot Manager";只给 `-Apply` 漏 `-Yes` 会以用法错误 64 退出且零写
  2. 重启,在厂商启动菜单里选带 `UEFI:` 前缀的 Kubuntu 条目
     看到:进入 live 桌面(不是 `grub>`、不是黑屏);终端里 `/sys/firmware/efi` 存在,`lsblk` 能看到目标盘
脚本:scripts/windows/set-bootnext.ps1 -Device USB -Check / -Device USB -Apply -Yes
坑:缺 `-Yes` 会以用法错误 64 退出且一个命令都不执行(一次性引导切换算破坏性写);在固件设置界面把 U 盘拖到永久首位、或用 `bcdedit displayorder` / `efibootmgr -o` 改序,都会破坏 I2(设计 I2);U 盘与目标盘同时列出时选错盘,后果到 `04-2` 才暴露。
出错时:看不到 U 盘条目 -> 回 `01-2` 核对介质与写入方式;`\EFI\Microsoft\` 或 `BootOrder` 有异常 -> 停下按 `07-1` 判层,不要重装。

### 04-2 手动分区:三块建在 115GiB 预留区内,Calamares 只指定挂载点

做:在 live 里手工建 Ubuntu 三块(ESP-Ubuntu 1024MB FAT32 / `/boot` 1024MB ext4 / root 约 113GiB ext4),三块都落在 `02-partitioning` 预留的 115GiB 未分配区内;Calamares 里**只指定挂载点**,不新建、不删除、不改尺寸(设计 04 第 5 节)。
  1. 先用核对脚本读现状,按输出的"下一步该建什么"建这三块
     看到:脚本报 PASS 且列出待建项;它同时断言 Windows ESP 未被挂载、尺寸仍是 2048MB(读不到就提示停手)
  2. Calamares 手动分区页里只把三块指定挂载点:`/boot/efi`(ESP-Ubuntu)、`/boot`、`/`(ext4);Windows 各分区一律不挂载、不格式化、不改尺寸
     看到:分区列表新增三行且 Windows 各分区原值不变;点"下一步"前没有任何 Windows 分区被标成"格式化"
脚本:scripts/linux/check-partition-plan.sh --track D --check
坑:**Calamares 没有独立的"引导器位置"选项**,它把引导装到 `/boot/efi` 所指的那块 ESP —— 把 Windows 的 2GiB ESP 设成 `/boot/efi` 就等于当场毁掉 Windows 引导(不变量 I3);ESP-Ubuntu 或 `/boot` 勾了格式化 = Ubuntu 引导丢失;把三块建在预留区之外会挤压 Windows 分区。
出错时:分区表对不上 -> 不要就地重排,按 `07-1` 判层后走救援;Calamares 写引导前中止 -> 按 `07-1` 在 live 环境手工修,最坏退回轨道 W(`03-windows`)。

### 04-3 装完重启验证

做:装完重启,默认应仍进 Windows;进 Kubuntu 后用校验脚本逐项核对,而不是只看"能不能进桌面"。
  1. 进 Kubuntu(厂商菜单键一次性选 ubuntu 条目),跑校验脚本
     看到:脚本报 PASS,逐条列出 `grub-efi-amd64-signed` 与 `shim-signed` 在位、`/boot` 独立且为 ext4、两块 ESP 内容齐全、GRUB 落在 `\EFI\ubuntu\`、`BootOrder` 首位仍是 Windows Boot Manager
  2. 不做任何引导改动直接重启一次,看默认进哪个系统
     看到:默认进 Windows(预期结果,不是失败);ubuntu 条目在 `BootOrder` 尾部
脚本:scripts/linux/verify-l3.sh --check
坑:把 ubuntu 条目设成默认首位会破坏 I1;在 L3 就配驱动或共享盘会把两件事混在一起(那是 `05-first-boot`)。
出错时:任一 FAIL -> 按 checks 里的失败项处置,引导层问题走 `07-1` 判层(不重装);`BootOrder` 首位被改 -> 只在固件设置界面改回,不得用 `efibootmgr -o`。

### 04-4 落 L3 产物

做:在 Kubuntu 里采集六节内容落成 `baseline/03-efi-layout.txt`;先 `--check` 预览,确认后再 `--apply` 写文件。
  1. `--check` 预览六节:`\EFI\` 两棵树(Windows ESP 与 Ubuntu ESP)、`efibootmgr -v`、`BootOrder`、`lsblk`、`findmnt`、引导包与内核版本摘要
     看到:输出含这六节;此时零写(没有生成任何文件)
  2. `--apply` 落盘,再把文件带回 Windows 侧放进仓库的 `baseline/`(不入库)
     看到:脚本报"产物已落盘";`git status` 里 `baseline/` 无变化
脚本:scripts/linux/collect-l3.sh --check / --apply
坑:把产物写进仓库跟踪范围(或写进 ESP)会污染基线;只写四节而漏掉 `findmnt` 或引导包摘要会让 L4 的复检缺证据。
出错时:读不到 Windows ESP 树 -> 在 Windows 侧采集该节或只读挂载后重跑;写不进 `baseline/` -> 核对目录权限,不要改产物路径。

A 组验收见 [08-verification.md](08-verification.md);本阶段收尾(恢复 BitLocker 保护)见 [回滚清单](../checklists/rollback.md)。
