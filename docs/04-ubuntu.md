# L3:Ubuntu 26.04 LTS 安装(不侵犯 Windows 引导)

本文件是 L3 阶段的手册。目标状态、四条不变量(下称 I1-I4)与参数名在[入口文档](00-overview.md)中定义;前提由 [L2 手册](03-windows.md)交付;动机与依据见[设计文档](design/00-design.md) 3.3 节(引导栈:官方 GRUB + shim)、3.17 节(显卡模式 MUX 分支)、3.19 节(引导菜单黑屏)、4.4 节(L3 步骤)、5.1 节(分区表)、第 7 节(故障矩阵)与 11.1 节(评论区实战证据)。

**本阶段最危险的动作只有一个:把 ESP 勾成"格式化"。** 它会在几秒内清空 `\EFI\Microsoft\`,让 Windows 与 Ubuntu 一起进不去——而且此时唯一完整的退路是 L2 的 ESP 基线(见"回滚")。L3 的其余步骤都可以慢,这一条不能错。

## 目标

装好 Ubuntu 26.04 LTS,做到"三个系统并存且互不接管":Windows 仍默认启动,Ubuntu 可启动且可撤除,引导链上没有任何一处被第三方接管。做完本阶段,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | Ubuntu 装在第 5 个分区上,ext4 挂 `/`,容量 100GiB | 本文"验证"第 6 行 |
| 2 | **ESP 复用挂载**:2GiB ESP 挂 `/boot/efi`,**绝不格式化**,原内容保留(I3) | 本文"验证"第 2、8 行 |
| 3 | 快照分区 15GiB ext4 挂 `/snapshots` | 本文"验证"第 6 行 |
| 4 | **未创建 swap 分区** | 本文"验证"第 7 行 |
| 5 | 引导文件写入 `\EFI\ubuntu\`,**期间未改动 `BootOrder`**(I2),Ubuntu 条目位于末尾 | 本文"验证"第 3、4、5 行 |
| 6 | Secure Boot 全程保持开启,未自签密钥、未 MOK 注册 | 本文"验证"第 9 行 |
| 7 | Windows 引导未被污染:`\EFI\Microsoft\` 与 L2 基线逐文件一致 | 本文"验证"第 2 行 |
| 8 | 本阶段产物在位且不入库 | 本文"验证"第 10、11 行 |

本阶段的产物逐字为一份文件:

- `baseline/03-efi-layout.txt`:四节固定内容——`\EFI\` 目录树、`efibootmgr -v`、`BootOrder`、`lsblk` 输出。

多设备时按 [baseline/README.md](../baseline/README.md) 的布局落盘到 `baseline/<设备别名>/03-efi-layout.txt`;该产物不入库(`baseline/*` 被 `.gitignore` 排除,仅 [baseline/README.md](../baseline/README.md) 例外)。

三条边界,越界即视为设计缺陷:

- **不调整启动顺序**:全程不执行 `efibootmgr -o`,也不在固件界面改顺序;`ubuntu` 条目由安装器新建并**默认排在 `BootOrder` 末尾**,本方案直接使用这个默认行为(I1、I2)(该默认行为**以本方案之外的实测为准**:若装完发现 `ubuntu` 被排在首位或中间,按“失败处理”对应两行处置,并把偏差写进 L4 记录)。唯一例外是顺序被外力改动后的复原(见"失败处理"中"重启默认进了 Ubuntu"一行):那种情形只走固件设置界面、并须记录偏差,仍不得用 `efibootmgr -o`;
- **不覆盖 `\EFI\Microsoft\`,不改 `{bootmgr}` 的 `path`**(I3);也不手工执行 `grub-install`,引导写入位置由安装器一次做对;
- **不关 Secure Boot、不自签密钥**(设计 3.3:Ubuntu 官方 shim 已在微软签名链内,没有关闭它的理由;关闭它会把 L4 的预签名 NVIDIA 包路径一起破坏)。

## 前置条件

- **L2 硬闸门已通过**:`baseline/02-preflight-report.md` 最后一行是 `结论: 允许进入 L3`,且报告"结论"一节红项为 `无`。带红项进 L3 属越界,不要"先试试看"。
- **基线四件齐备**(I4 的最低要求):`baseline/02-esp-backup/`(含 `manifest.sha256`)、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt`、`baseline/01-partitions.txt`。其中两份分区记录是本节"只动预留空间"的比对依据,`02-esp-backup/manifest.sha256` 是验证段第 2 行的比对依据。
- **BitLocker 处于挂起状态**:报告"BitLocker 保护状态"行为 `未加密` 或 `卷已加密、保护已关闭(挂起或暂停)`。**L3 期间不要重新启用保护**;恢复保护是本阶段的收尾动作(步骤 8),闭环方式见 [回滚清单](../checklists/rollback.md) 第 1 节的 BitLocker 收尾行。
- **参数表已填**(每台设备一份,见[入口文档](00-overview.md)):`DISK`、`DISK_MODEL` / `DISK_SIZE`(防选错盘)、`ROOT_SIZE = 100GiB`、`SNAPSHOT_SIZE = 15GiB`、`ESP_SIZE = 2GiB`、`BOOT_MENU_KEY`、`GPU`。
- **介质**:Ubuntu 26.04 LTS 官方安装 U 盘,ISO 的 SHA256 已在 L0 按官方 `SHA256SUMS` 校验过。按健壮性设计 R4,这块 U 盘**装机结束后不回收**,保持"已验证可用"。
- **空间前提**:L1 已在盘尾预留 115GiB 未分配空间(root 100 + 快照 15),目标布局是 `ESP → MSR → C: → D: → [115GiB 未分配] → WinRE`(设计文档 5.1)。Ubuntu 的两块分区必须从这段未分配空间里切出来;**不要指望安装器帮你在别处腾空间**。
- **回 Windows 的入口已知**:`BOOT_MENU_KEY` 能在开机时调出一次性启动菜单(见 [L0 手册](01-firmware.md) 厂商差异表)。这是进 Linux 的正常方式,不是应急手段(I2)。
- **时间窗口**:L2 之后不要再让 Windows 联网完成更新。若中途进过一次 Windows 且它更新过(尤其固件更新或累积更新),基线即失效,回到 L2 重跑闸门后再继续(交接规则第 4 条)。
- **口径:L3 只做安装与本阶段留档**,不配置显卡驱动、共享盘挂载、时间与蓝牙——那些是 L4 的内容。本阶段唯一的例外是"黑屏应急"(步骤 5),它只为把系统装完服务。

## 步骤

### 1. 以 UEFI 模式从安装 U 盘启动,选"手动分区"

做什么:开机时按 `BOOT_MENU_KEY` 进入一次性启动菜单,选带 `UEFI:` 前缀的 Ubuntu 条目(不要选不带前缀的那条,那是 legacy 引导);进入 live 环境后开始安装。

到"安装类型 / 磁盘"这一步时:

1. **只选"手动分区"**(不同版本措辞可能是 `Manual partitioning` / "其他选项";以"我自己指定每个分区"这一语义为准);
2. **不要选"擦除磁盘并安装 Ubuntu"**——它会整盘重写,连 Windows 一起清掉;
3. **不要选"与 Windows 共存"**——它会在已有系统上自动缩容,正是本方案用整盘重排绕开的那一类事故(设计文档 1、3.5 节)。

怎么知道成功了:分区界面能列出该磁盘及其全部分区。逐项核对:

| 核对对象 | 依据 | 期望 |
|---|---|---|
| 目标磁盘 | 界面显示的设备名与容量 | 与参数表 `DISK`、`DISK_MODEL`、`DISK_SIZE` 一致(容量约 953G)。**不一致就停下**,选错盘没有撤销 |
| Windows 分区 | L1 / L2 的分区记录 | 能看到 2GiB 的 EFI System 分区、16MiB MSR、200GiB 与 ≈635GiB 的 NTFS 分区,以及盘尾 1GiB 恢复分区 |
| 预留空间 | L1 / L2 的分区记录 | 存在一段约 115GiB 的**未分配空间**,位置在 ≈635GiB 的 NTFS 分区之后(设计文档 5.1) |

看不到任何磁盘(或只看到 U 盘)时不要在这里折腾,按"失败处理"第 1 行回 L0 查存储控制器模式。

### 2. 手动分区:只切两块新分区,ESP 复用挂载且不格式化

做什么:在这一屏把所有分区一次性指定清楚。**下表是本步骤的定稿动作,逐行照做**:

| 分区 | 容量 | 文件系统 | 挂载点 | 格式化 | 说明 |
|---|---|---|---|---|---|
| ESP(已有) | 2GiB | EFI System(FAT32) | `/boot/efi` | **绝不格式化** | Windows 与 Ubuntu 共用;`\EFI\Microsoft\` 与 `\EFI\ubuntu\` 并存的地方 |
| 新建(来自未分配空间) | 100GiB | ext4 | `/` | 勾选 | Ubuntu 系统盘;内核位于 root 内的 `/boot`,不额外分区 |
| 新建(来自未分配空间) | 15GiB | ext4 | `/snapshots` | 勾选 | 变更前快照的存放位置(健壮性 R1/R2) |
| MSR / C: / D: / WinRE | 原值 | 原样 | **不挂载** | **不勾选** | Windows 各分区一律不挂载、不格式化、不改尺寸 |

三条铁律:

1. **只允许在 L1 预留的那段未分配空间内创建分区**;不得对 Windows 的 ESP / MSR / C: / D: / WinRE 做任何删除、新建、格式化或改大小的操作;
2. **ESP 复用挂 `/boot/efi`,绝不格式化**(在安装器里就是:不勾选该分区的格式化)——这是 I3 在安装器里的唯一落地点。ESP 一旦被格式化,`\EFI\Microsoft\` 随即消失,Windows 引导当场失效(设计文档 4.8 办法二的风险行);
3. **不创建 swap 分区**:交换空间由 zram 与 swapfile 在 L4 配置(设计文档 3.8)。安装器里不需要、也不要新建 swap 分区。

关于"引导器位置"下拉框(评论区高频卡点):**Ubuntu 24.04 及以后的新安装器在"手动分区"界面里没有独立的"引导器位置"选择项**,这是正常行为,ESP 由安装器自动复用(设计文档 3.20 的社区经验行、11.1 第 7 条)。确认 ESP 存在、且**未被勾选格式化**,就可以继续;**不必到处找一个不存在的选项**,更不要为了"找得到那个框"而退回旧安装器或换发行版。

动手前的最后一次核对:把分区界面里每个分区的**偏移与容量**对照 `baseline/02-partitions.txt`(L2 快照)读一遍,确认自己将要新建的两块分区落在未分配区间内、将要挂 `/boot/efi` 的那块确实是 2GiB 的 EFI System 分区。核对完再点"下一步"。

### 3. 确认引导写入 `\EFI\ubuntu\`,且不改 `BootOrder`

做什么:确认(而不是改动):

1. 引导文件写入 ESP 上的 `\EFI\ubuntu\`(shim 与 GRUB,即 `shimx64.efi` / `grubx64.efi`),这是安装器默认行为(设计文档 4.4);它**不覆盖** `\EFI\Microsoft\`,也不改写 `{bootmgr}` 的 `path`(I3);
2. **期间不改动 `BootOrder`**:不执行 `efibootmgr -o`,不在固件界面拖动启动顺序;安装器新建的 `ubuntu` 条目**按默认排在 `BootOrder` 末尾**(**未经本方案实测**,以 L3 验证第 4、5 行为准),这正是本方案要的形态(I1、I2);
3. 安装器若在收尾阶段询问是否更新或替换引导入口,一律选**默认/不额外改动**那一项;任何"设为默认启动项"之类的选项都不要勾。

怎么知道成功了:重启后的表现是"**默认仍然进 Windows,要用 Ubuntu 时用厂商菜单键一次性选它**"。如果重启直接进了 Ubuntu,说明启动顺序被改了,按"失败处理"第 3 行处置并把顺序还原。

### 4. Secure Boot 保持开启

做什么:全程不关 Secure Boot、不注册自签 MOK、不改自定义密钥。Ubuntu 官方 shim 走微软签名链,Secure Boot 开启是它的原生工作状态(设计文档 3.3)。

判据:安装完成后在 Ubuntu 里 `mokutil --sb-state` 输出 `SecureBoot enabled`(验证段第 9 行)。显卡驱动相关的签名问题不在本阶段处理——L4 走 Ubuntu 仓库的预签名 NVIDIA 模块包,**不在此处引入自签**。

### 5. 黑屏时的应急路径(临时手段,不是配置)

两条路径,按现象选。

**(a)U 盘启动或安装界面黑屏**:在引导菜单里高亮该条目,按 `e` 编辑内核行,在行尾加 `nomodeset`,再按 `F10`(部分版本 `Ctrl + X`)启动。

- `nomodeset` 关掉 KMS(内核模式设置),而本方案默认会话是 **Wayland**,Wayland 需要 KMS(设计文档 11.1 第 2 条)。所以它**只是应急**:
  - 它会让 live 环境以软件渲染跑起来,或在装好后导致会话异常/无法进桌面;
  - **装好显卡驱动后必须移除该参数**,方法:编辑 `/etc/default/grub` 去掉 `nomodeset`,执行 `sudo update-grub`,重启;
  - 判据:`cat /proc/cmdline` 不再包含 `nomodeset`,`echo $XDG_SESSION_TYPE` 输出 `wayland`。
- 不要把 `nomodeset` 写进模板或长期配置。把它当"万能修复"是评论区里被反复点名的坑。

**(b)混合显卡模式下安装器或首启反复点不亮**:按设计文档 3.17 走 **MUX 分支**——进固件把显示模式切到**独显直连**,先拿到一个可用系统,再评估是否切回混合模式。

- 代价必须记录在案:独显直连下**所有进程都占用独显显存**、**续航明显变差**,而且日后要在这台机器上做本地推理时显存会被显示输出吃掉一部分;
- 因此它**不是默认配置**:切回混合模式的评估与驱动安装一并放在 L4(预签名驱动装好后,混合模式 + PRIME offload 才是目标形态);
- 本台设备的当前状态(混合 / 独显直连)要写进 L4 记录,别让下一位执行者以为它一直是混合模式。

### 6. 首次进入 Ubuntu 后,生成 `baseline/03-efi-layout.txt`

做什么:安装完成、重启、用 `BOOT_MENU_KEY` 一次性选 `ubuntu` 进入系统,在终端里采集四类信息。产物逐字为 `baseline/03-efi-layout.txt`,四节内容固定为:`\EFI\` 目录树、`efibootmgr -v`、`BootOrder`、`lsblk` 输出。

`baseline/` 在本机的仓库目录里(Windows 侧),所以先把输出存成文本,再回 Windows 粘贴落盘——多设备时落到 `baseline/<设备别名>/`:

```bash
{
  echo "# baseline/03-efi-layout.txt (L3 产物)"
  echo
  echo "## \\EFI\\ 目录树"
  sudo find /boot/efi/EFI -maxdepth 3 | sort
  echo
  echo "## efibootmgr -v"
  sudo efibootmgr -v
  echo
  echo "## BootOrder"
  sudo efibootmgr | grep '^BootOrder'
  echo
  echo "## lsblk"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
} > ~/03-efi-layout.txt
```

命令只读,不改动任何引导内容;`sudo` 在终端里按需输入口令即可。把 `~/03-efi-layout.txt` 的内容取回 Windows 侧落盘。

- 目录树里应当同时看到 `EFI/Microsoft/`、`EFI/Boot/` 与**新增的** `EFI/ubuntu/`;这是"两个引导栈并存"的正常形态;
- 把文本带回 Windows 后落盘成 `baseline/03-efi-layout.txt`;**不要**把它写进仓库跟踪范围(`baseline/*` 已被 `.gitignore` 排除);
- 采集顺序在验证段之前:验证段第 2、3、4 行的证据都取自这份产物与即时命令。

### 7. 第一次重启:确认"默认仍进 Windows"

做什么:装完直接从 Ubuntu 重启,不做任何引导改动,看默认进哪个系统。

- 期望:默认进 **Windows**。因为本阶段没动 `BootOrder`,首位仍是 `Windows Boot Manager`(I1);
- 进 Windows 是**预期结果,不是失败**:要用 Ubuntu 时按 `BOOT_MENU_KEY` 一次性选 `ubuntu`,这条路径就是 I2 的落地方式;
- 若默认进了 Ubuntu,按"失败处理"第 3 行处置(把顺序还原,不要习惯性地接受)。

顺带完成本阶段最重要的两项核对:Windows 能正常进桌面;`\EFI\Microsoft\` 未被改动(验证段第 2 行)。

### 8. 收尾:恢复 BitLocker 保护

做什么:确认 Ubuntu 已可启动、`BootOrder` 首位仍是 `Windows Boot Manager` **之后**,在 Windows 里恢复保护:

```cmd
manage-bde -protectors -enable C:
manage-bde -status
```

L2 用的是 `-rebootcount 0` 挂起,**不会**随时间或重启自动恢复;漏做这一步,C: 会长期停在"卷仍加密、保护已关闭"的状态(闭环说明见 [回滚清单](../checklists/rollback.md) 第 1 节的 BitLocker 收尾行)。闭环之前不要做任何与分区表有关的事。

## 验证

逐项核对,全部通过 = L3 完成。第 2、3、4 行的证据取自 `baseline/03-efi-layout.txt` 与实际命令输出。

| # | 检查项 | 命令 / 来源 | 期望 |
|---|---|---|---|
| 1 | Ubuntu 可启动 | 重启后按 `BOOT_MENU_KEY` 选 `ubuntu` | 能进 GNOME 桌面/登录会话,不是黑屏、不是 `grub>` |
| 2 | Windows 引导未被污染 | 在 Ubuntu 里核对 ESP,清单来源 `baseline/02-esp-backup/manifest.sha256`:先**把清单副本放到家目录**(如 `~/manifest.sha256`),**清单副本不得写入 ESP**(写进 `/boot/efi` 本身就是一次 ESP 写操作,会污染该判据);再 `cd /boot/efi && sudo sha256sum -c ~/manifest.sha256 2>&1 \| grep -v ': OK$'` | `EFI/Microsoft/` 子树**全部 OK**、零差异(逐文件一致)。清单若报"无效的行格式",对家目录里的副本执行 `sed -i 's/\r$//'` 转成 LF 再核对,**不要改基线原文件、也不要把副本放进 ESP**;清单里 `EFI/ubuntu/` 属新增,不在基线行内 |
| 3 | `BootOrder` 首位仍是 Windows Boot Manager | `baseline/03-efi-layout.txt` 的 `efibootmgr -v` 一节;或 `sudo efibootmgr` | `BootOrder:` 列表第一项对应的条目是 `Windows Boot Manager` |
| 4 | Ubuntu 条目在末尾 | 同一份输出 | `BootOrder:` 列表最后一项对应的条目是 `ubuntu` |
| 5 | 全程未改启动顺序(I2) | 自证 + 与 L2 快照对比 | 本阶段未执行过 `efibootmgr -o`;`BootOrder` 与 `baseline/02-firmware-entries.txt` 相比只**在末尾新增**了 `ubuntu`,其余顺序未变 |
| 6 | 分区挂载正确 | `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT`、`findmnt / /boot/efi /snapshots` | `/` 为 100G ext4;`/boot/efi` 为 2G vfat;`/snapshots` 为 15G ext4 |
| 7 | 未创建 swap 分区 | `lsblk -o NAME,FSTYPE`、`swapon --show` | 分区列表里没有 `swap`;`swapon --show` 为空(swapfile 在 L4 配) |
| 8 | ESP 未被格式化 | 第 2 行同一证据 + `ls -la /boot/efi/EFI` | `Microsoft` 与 `ubuntu` 两个目录同时存在;`Microsoft` 内容与基线一致 |
| 9 | Secure Boot 仍开启 | `mokutil --sb-state` | `SecureBoot enabled` |
| 10 | 产物在位且四节齐备 | `baseline/03-efi-layout.txt`(多设备时 `baseline/<别名>/`) | 含 `\EFI\` 目录树、`efibootmgr -v`、`BootOrder`、`lsblk` 四节,内容为本次实测 |
| 11 | 产物未入库 | `git status`(Windows 侧仓库) | `baseline/` 下变化一个都不出现([baseline/README.md](../baseline/README.md) 除外) |

11 项全部通过 = 可进入 L4(首启收敛:[05-first-boot.md](05-first-boot.md))。任一项不通过则按"失败处理"解决后再推进;**第 2 行不通过是最严重的一种,先修复 Windows 引导,再谈 L4**。

## 失败处理

| 现象 | 立即动作 |
|---|---|
| 安装器看不到磁盘(分区界面空白,或只列出 U 盘) | 回 [L0 手册](01-firmware.md) 步骤 2 核查存储控制器模式:必须是 AHCI / NVMe,且 VMD / RAID On 关闭。可在 live 环境用 `lsblk -d -o NAME,MODEL,SIZE` 复核(`nvme0n1` 是否出现)。仍看不到则该设备不适用本方案(设计文档 1.2 偏离表),不要在安装器里反复重试 |
| 重启后直接进 Windows(没看到 Ubuntu 入口) | 这**通常是正常形态**:`BootOrder` 首位未变,I1 成立。用 `BOOT_MENU_KEY` 调出一次性启动菜单,选 `ubuntu` 进入;同时核对固件条目列表:`ubuntu` 条目是否存在、其 EFI 路径是否指向 `\EFI\ubuntu\shimx64.efi`。条目缺失时从 live 环境用显式盘/分区新建:`sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'`(盘/分区按 `baseline/02-partitions.txt` 替换;不给盘/分区时默认 loader 未必指向 `\EFI\ubuntu\` 的 shim/grub)。命令只新建条目,**绝不用 `-o` 调顺序**;随后立刻 `sudo efibootmgr` 复读并断言"`BootOrder` 首位仍是 `Windows Boot Manager`、`ubuntu` 在末尾",不满足则按下一行处置并把偏差写进 L4 记录;也可直接重跑安装器的引导安装部分 |
| 重启默认进了 Ubuntu(启动顺序被改) | 违反 I1,立即修:**只在固件设置界面**把 `Windows Boot Manager` 改回首位(与 `baseline/02-firmware-entries.txt` 记下的顺序一致)。固件没有顺序选项时,**不要用 `efibootmgr -o`**(I2 与交接规则第 5 条禁止):先记录当前 `BootOrder` 与偏差,再按 [docs/07-rescue.md](07-rescue.md) 与 L2 基线复原(必要时用 `efibootmgr -b <ubuntu 条目编号> -B` 删除该条目,让固件回落到 Windows),并把这次修动写进 L4 记录的偏差项 |
| 停在 `grub>` / `grub rescue>` | 引导层问题,**不要重装**:按 [07-rescue.md](07-rescue.md) 的 GRUB 恢复流程处置(`ls` 找分区 → `set prefix` → `insmod normal` → `normal`;或 `chainloader` 回 Windows)。同时确认 `\EFI\Microsoft\` 未被改动、`BootOrder` 首位仍是 `Windows Boot Manager`;修完按验证段第 2、3 行复查 |
| Secure Boot 拒载(`Verification failed` / `Security Violation` / `bad shim signature`) | 先核查 `mokutil --sb-state`(应为 `enabled`),再确认用的是官方 ISO(其 shim 在微软签名链内)。**不要自签密钥、不要关闭 Secure Boot**;显卡/驱动类模块签名被拒时,回退 nouveau 并把问题留给 L4 的预签名包路径(设计文档第 7 节 L3/L4 行)。若 live 环境也被拒,先查固件里 `Secure Boot Mode` 是否被改成 `Custom`(应保持 `Standard`) |
| 安装界面或首启黑屏 | 步骤 5(a):引导菜单按 `e`,内核行加 `nomodeset` 临时启动。它关掉 KMS,**与默认的 Wayland 会话冲突**,只是应急手段;能进系统后立即装好显卡驱动并移除该参数(`/etc/default/grub` 去掉 + `sudo update-grub`),不要把它当长期配置 |
| 混合显卡模式下安装器/首启反复点不亮 | 步骤 5(b):按设计文档 3.17 走 MUX 分支,固件切**独显直连**先拿到可用系统。记录代价:显存被显示输出占用、续航变差、日后本地推理显存不足;切回混合模式的评估放在 L4,不要在这里反复试 |
| 装完进不了桌面(黑屏、循环登录、卡在图形栈) | 切 TTY(`Ctrl + Alt + F3`)登录,看上一次启动的日志:`journalctl -b -1 -p err`。必要时在 GRUB "Advanced options" 选**旧内核**启动。属于 NVIDIA 驱动问题就按 L4 的预签名包路径处理;**不要因为驱动问题降级发行版**(设计文档 3.17 被否方案、第 9 节) |
| `\EFI\Microsoft\` 与基线不一致(验证段第 2 行报差异) | **立即停手**:说明 ESP 被改写,I3 已被违反。用 L2 基线复原:把 `baseline/02-esp-backup/EFI/` 复制回 ESP + `bcdboot C:\Windows /s S: /f UEFI`(完整步骤见 [回滚清单](../checklists/rollback.md) 第 4 节),复原并复查后再继续 |
| 发现自己把 ESP 勾成了"格式化" | **在点"安装/下一步"之前退回去取消勾选**,这是无损的。若已经安装完成才发现:`\EFI\Microsoft\` 大概率已被清空,按上一行做基线复原,并把这次记录为 L3 的严重偏差 |
| 安装器提供了"与 Windows 共存""擦除磁盘"选项 | 不使用。本方案只走手动分区:共存模式会自动缩容 Windows 分区(设计文档 1、3.5 节),擦除磁盘会整盘重写 |
| 装机中途回了 Windows,且它联网完成了更新 | 基线失效(L2 与 L3 之间 Windows 更新会改动 ESP 与固件状态):回 L2 用管理员会话重跑 `preflight.ps1`,重新核对分区表、ESP 与固件启动项;报告仍为 `结论: 允许进入 L3` 才继续。**不要带着过期基线往下走**(交接规则第 4 条) |
| `nomodeset` 加在安装器里,装完忘了移除 | 表现为会话异常或仍不进桌面:按步骤 5(a)的移除方法处理,判据是 `cat /proc/cmdline` 不再含该参数、`echo $XDG_SESSION_TYPE` 为 `wayland`。同时确认没有把它写进任何模板 |
| 提示需要"引导器位置"却找不到该选项 | 正常:Ubuntu 24.04+ 的新安装器没有这一项,ESP 由安装器自动复用(设计文档 3.20、11.1 第 7 条)。确认 ESP 存在且未勾选格式化即可继续,不必找 |

## 回滚

### 1. 安装进行中的回滚

在点"安装"之前,每一步都可以退回上一屏改配置,不改动磁盘,无副作用。**一旦开始写入磁盘,退回去的唯一方式就是重装**(此时还没有用户数据,重装的代价只是时间)。

### 2. 引导层回滚(最常用)

ESP 被改动、Windows 引导异常、或要放弃这次 Ubuntu 安装时:**用 L2 的基线复原,不要重装 Windows**——

1. 校验 `baseline/02-esp-backup/manifest.sha256` 与备份文件一致;
2. 挂载 ESP(`mountvol S: /s`),把 `baseline/02-esp-backup/EFI/` 复制回 ESP(`robocopy baseline\02-esp-backup\EFI S:\EFI /E`;清单文件本身不复制);
3. 重建 Windows 引导:`bcdboot C:\Windows /s S: /f UEFI`;
4. 卸载 ESP(`mountvol S: /d`),复查四条不变量(`BootOrder` 首位、`\EFI\Microsoft\` 哈希、`{bootmgr}` 的 `path`、Ubuntu 条目是否仍在)。

完整命令与判据见 [回滚清单](../checklists/rollback.md) 第 4 节。

### 3. 单步回滚:`\EFI\ubuntu\` 的删除与还原

只想验证"Linux 撤得干净"时(验收 A 组的可撤除性演练):备份 ESP 现状后删掉 `\EFI\ubuntu\`(**保留分区**),重启——因为 `BootOrder` 首位仍是 `Windows Boot Manager`,应该**自动进 Windows 且不出现 `grub rescue>`**。验完用基线或备份把 `\EFI\ubuntu\` 还原并复测。

### 4. 整体撤除 Linux

要彻底删掉 Ubuntu:走 [06-decommission.md](06-decommission.md) 的五步顺序——先把 `BootOrder` 首项改回 Windows Boot Manager → 备份 NVRAM 与 ESP 现状 → 再从 Windows 删除 Linux 分区 → 清理残留 `ubuntu` 条目 → 可选:扩展 `D:`(见 [06-decommission.md](06-decommission.md) 步骤 5;`C:` 与未分配空间不相邻,扩不了)。**顺序不可更换**:**明确禁止**"先格式化 Linux 分区再修引导"——那正是 `grub rescue>` 事故的成因。在 L5 之前不要手工删 Linux 分区。

### 5. 显卡模式回滚(MUX 分支)

步骤 5(b)把固件切到独显直连之后,想切回混合模式:固件改回混合即可。**切回前先确认 L4 的预签名驱动已装好**,否则会回到"点不亮"的起点(设计文档 3.17)。`nomodeset` 的回滚就是移除该参数 + `sudo update-grub`,不需要重装内核。

### 6. BitLocker 保护的恢复(本阶段收尾,不是可选项)

L3 完成后在 Windows 里执行 `manage-bde -protectors -enable C:`,并用 `manage-bde -status` 确认保护已开启。L2 用的是"挂起到手工启用",**不会**自动恢复;漏做这一步,C: 会停在"卷仍加密、保护已关闭"的状态,且不会随时间自愈(见 [回滚清单](../checklists/rollback.md) 第 1 节的 BitLocker 收尾行)。

### 7. I4 复核:L3 之后旧基线的状态

L3 既改了分区表(新增两块 ext4 分区),又改了固件 NVRAM(新增 `ubuntu` 条目),因此**L2 的基线在 L3 之后不再是"当前状态"的快照**:它仍是**回滚用的还原点**,但不再是"现状记录"。结论只有一条:**此后再要改动分区表或固件设置,必须先重做 L2 基线**(I4)。周期性巡检时同步核对本阶段的产物 `baseline/03-efi-layout.txt` 是否与实际一致(设计文档 7.1)。
