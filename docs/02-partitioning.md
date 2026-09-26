# 02:分盘(安装系统前的前置章节)

本文件在流程中的位置:`01-firmware`(底座:L0)-> **本文件(底座:分盘)** -> 轨道 W 的 `03-windows` / 轨道 L 的 `04-silverblue`。

目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;分区数值的设计依据在[设计文档](design/00-design.md) 5.1 节,本文件不复述。

## 开始前

- 前提:已完成 L0(`01-firmware.md` 的四张卡),`baseline/00-firmware.md` 已落盘,固件已是 UEFI + AHCI / NVMe。
- 需要的东西:目标盘型号与容量(参数表 `DISK_MODEL` / `DISK_SIZE`)、本机要走的轨道(W 只 Windows / L 只 Kubuntu / D 双系统)。
- 产物落点:分区记录进 `baseline/`(W 与 D 落 `01-partitions.txt`;L 落 `03-efi-layout.txt` 的分区段);多设备放 `baseline/<设备别名>/`。

### 02-1 分盘总则与三种轨道的目标布局

做:先按本机轨道认下目标布局(下表是定稿值,一字不改),再用只读核对脚本对照当前磁盘,结果记进 `baseline/`。

| 序号 | 分区 | 数值 | 类型 | 用途 |
|---|---|---|---|---|
| 1 | ESP-Windows | 2048MB(2GiB) | EFI System(FAT32) | 只给 Windows,只放 `\EFI\Microsoft\` 与 `\EFI\BOOT\` |
| 2 | MSR | 16MB | Microsoft Reserved | Windows 保留 |
| 3 | Windows 系统 `C:` | 204800MB(200GiB) | NTFS | 系统与程序;原地重装时唯一被格式化的分区 |
| 4 | Windows 数据 `D:` | 650240MB(约 635GiB) | NTFS | 数据盘,双系统共享盘(L4 以 `ntfs3` 读写挂载) |
| 5 | ESP-Ubuntu | 1024MB(1GiB) | EFI System(FAT32) | Kubuntu 独立 ESP,只放 `\EFI\ubuntu\` |
| 6 | `/boot` | 1024MB(1GiB) | ext4 | 独立分区:重装 root 时可选择保留内核与 GRUB 模块 |
| 7 | Ubuntu root | 约 113GiB | ext4 | `/`(Ubuntu 默认;不用 btrfs,因为不需要快照);轨道 L 独占整盘时取更大值 |
| 8 | WinRE | 约 1GiB | Recovery | Windows 恢复环境(由 Windows 安装程序创建,在盘尾或预留段内) |

Ubuntu 侧三块分区(ESP-Ubuntu 1GiB + `/boot` 1GiB + root 约 113GiB)建在轨道 D 预留的 **115GiB 未分配区**内;轨道 W 的四块之外不预留;轨道 L 用整盘,不建 MSR / `C:` / `D:` / WinRE。
铁律:分区表只在装机阶段一次定稿、**禁止事后缩容**(设计 3.5);ESP-Ubuntu 与 `/boot` **绝不**与 Windows 共用(设计 3.4);绝不覆盖 `\EFI\Microsoft\`,绝不改 `{bootmgr}` 的 `path`(不变量 I3)。
看到:8 个数值已抄进 `baseline/` 的分区记录;核对脚本对本轨道判 PASS(判 FAIL 时"期望 / 实际"已逐条记下)。
坑:事后缩容会撞上不可移动文件或触发 BitLocker 恢复,本方案不提供该分支;要改尺寸只能整盘重排。
出错时:轨道选错 -> 回 `00-overview.md` 的三轨道地图;脚本报 FAIL -> 按 checks 的"期望 / 实际"改布局(W 改 `02-2`、L 改 `02-3`、D 改 `02-4`)。
脚本:scripts/windows/check-partition-layout.ps1 -Track <W|L|D>

### 02-2 轨道 W 的分盘(只装 Windows)

做:只装 Windows 时按上表建 Windows 侧四块(ESP-Windows / MSR / 系统 / WinRE),**不给 Linux 预留空间**。
  1. 在安装界面按 `Shift + F10` 调出命令行,先 `list disk` / `detail disk` 核对型号与容量,再建 ESP 2048MB + MSR 16MB + 系统分区 204800MB(数据盘按需再建)
     看到:`list partition` 里 ESP 是 2048MB(不是安装器默认的 100MB 级),顺序为 ESP -> MSR -> 系统
  2. 继续安装,只选那块 204800MB 的系统分区,不点"删除""新建""格式化"
     看到:进桌面后 WinRE 分区存在(约 1GiB,盘尾),系统盘容量显示 200GiB 级
脚本:scripts/windows/check-partition-layout.ps1 -Track W
坑:让安装器自动分区会建 100MB 级 ESP,与定稿表不符(设计 3.4);轨道 W 不预留 Linux 空间,以后想加 Kubuntu 只能整盘重排。
出错时:核对报 ESP / MSR / 系统分区不符 -> 回 `02-1` 的数值表重排;型号或容量对不上 -> 回 `01-3` 核对目标盘。

### 02-3 轨道 L 的分盘(只装 Kubuntu)

做:只装 Kubuntu 时整盘只建三块:ESP-Ubuntu 1024MB、`/boot` 1024MB(ext4)、root(约 113GiB,独占整盘时取更大值,ext4);不建 MSR / `C:` / `D:` / WinRE。
  1. 进 live 环境后先核对设备名与容量(`lsblk` / `sgdisk -p`),再进 Calamares 的手动分区
     看到:待分区的空间是目标盘上那段整块未分配空间,容量与 `DISK_SIZE` 一致
  2. 三块依次建:ESP 1024MB(FAT32,挂 `/boot/efi`)、`/boot` 1024MB(ext4)、root(ext4),Calamares 里只指定挂载点
     看到:分区列表只有这三块,没有动到任何 Windows 分区与它自己的 ESP
脚本:scripts/linux/check-partition-plan.sh --track L --check
坑:`/boot` 不独立会让重装 root 时连带丢掉内核与 GRUB 模块;把 ESP-Ubuntu 与 Windows 的 ESP 混用,一次 Windows 更新就可能覆盖引导(I3)。
出错时:三块分区对不上或找不到挂载点 -> 进 live 后按 `04-2` 手动分区卡(手册 `04-silverblue`)核对(用 `check-partition-plan.sh`),不要就地重排。

### 02-4 轨道 D 的分盘(双系统,含 115GiB 预留)

做:装 Windows 之前用 diskpart 预建整盘分区表(只建 Windows 四块),把约 115GiB 留给 L3 的 Ubuntu 三块分区。
  1. 先跑 `-Check`:打印将执行的 diskpart 命令与前置断言(目标盘必须当前无分区表;不一致时退 64 且零写)
     看到:命令里是 ESP 2048 / MSR 16 / C: 204800 / D: 650240,且磁盘型号与容量与 `DISK_MODEL` / `DISK_SIZE` 一致
  2. 加 `-Apply -Yes` 执行,再跑核对脚本对一遍写后的分区表
     看到:四个分区尺寸与上表一致,`D:` 之后仍有约 115GiB 未分配(`-Track D` 判 PASS)
脚本:scripts/windows/create-partitions.ps1 -Check / -Apply -Yes;scripts/windows/check-partition-layout.ps1 -Track D
坑:ESP-Win 之后的预留区一旦被占用(又建了分区、或安装时点了"新建"),L3 将无处安装 Kubuntu 三块分区,只能整盘 clean 重排;也绝不在这一步建 ESP-Ubuntu 与 `/boot`。
出错时:前置断言报"已有分区表" -> 先回 `01-3` 确认盘没选错,再人工 `clean` 后重跑;复读不符 -> 不缩容,整盘 clean 重排。
