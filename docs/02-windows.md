# L1:Windows 11 专业版全新安装、分区定稿与系统盘隔离

本文件是 L1 阶段的手册。目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;固件与介质前提由 [L0 手册](01-firmware.md)交付;动机与依据见[设计文档](design/00-design.md) 4.2 节(L1 步骤)、3.10 节(激活)、3.15 节(系统盘隔离)、3.16 与 5.3 节(共享盘)、5.1 节(分区表)与第 9 节(风险登记)。

## 目标

把整盘分区**在装系统之前一次定稿**,装好 Windows 11 专业版,并把激活状态与分区表落盘为 L1 产物。做完本阶段,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | 分区表按目标布局定稿:ESP 2GiB → MSR 16MiB → C: 200GiB → D: ≈635GiB → 磁盘末尾**约 115GiB 未分配** | `diskpart` 的 `list partition` 输出与本文"验证"第 1-3 行一致 |
| 2 | Windows 11 专业版装在第 3 个分区上,全程只动这一个分区 | 安装界面里只选 200GiB 分区,未点过"删除/新建" |
| 3 | **系统盘隔离**:C: 只承载系统与程序;已知文件夹(桌面/文档/下载/图片/视频/音乐)、游戏库与容器镜像全部落在 D: | 本文"验证"第 4 行逐项核对 |
| 4 | Fast Startup(快速启动)与休眠已关闭 | `powercfg /a` 与注册表 `HiberbootEnabled`(本文步骤 3) |
| 5 | 激活完成且状态已核对 | `slmgr /dlv` 输出(本文步骤 5) |
| 6 | 磁盘未加密:C: 与 D: 均不启用 BitLocker / 设备加密 | `manage-bde -status`;D: 不启用 BitLocker 是共享盘方案的前提(设计文档 5.3) |

本阶段的产物只有两份,逐字为:

- `baseline/01-partitions.txt`:分区表定稿记录(分区输出、卷标、WinRE 落点等偏差、C: 内容与重定向核对结果);
- `baseline/01-activation.md`:激活状态复核输出。

多设备时按 [baseline/README.md](../baseline/README.md) 的布局放到 `baseline/<设备别名>/` 下;两份产物都不入库。

两条边界,越界即视为设计缺陷:

- **ESP 备份(`02-esp-backup/`,文件树 + `manifest.sha256`)与固件启动项快照(`02-firmware-entries.txt`)是 L2 的基线产物**,L1 不生成,也不要把它们记成 L1 产物;
- **L1 全程不改 `BootOrder`、不执行 `efibootmgr -o`**(I1、I2)。Windows 安装程序自己新建 `Windows Boot Manager` 条目并把它排在首位,属安装的正常结果;本阶段要做的只是**照实记录**,不是调整顺序。

I4 在首次装机时的落地方式:**分区表在 L1 一次定稿、基线在 L2 生成**,所以 L1 动手之前没有基线是允许的;此后任何分区表或固件变更都必须先有可用基线。由此引出[入口文档](00-overview.md)"阶段产物与交接规则"第 4 条:**L1 与 L2 必须在同一次会话内连续完成**(中途若 Windows 发生更新,基线即失效)。

## 前置条件

- **L0 完成**:[L0 手册](01-firmware.md)"验证"一节的 7 项全部通过,且 `baseline/00-firmware.md` 字段无空缺。其中与本阶段直接相关的四项:`FIRMWARE_MODE` 已是 AHCI / NVMe(且 VMD / RAID On 关闭)、`SECURE_BOOT` 开启、Fast Boot 关闭、CSM 关闭。
- **参数表已填**(每台设备一份,见[入口文档](00-overview.md)):`ESP_SIZE = 2GiB`、`WINDOWS_SYSTEM_SIZE = 200GiB`、`WINDOWS_DATA_SIZE ≈ 635GiB`、`ROOT_SIZE = 100GiB`、`SNAPSHOT_SIZE = 15GiB`,以及 `DISK_MODEL` / `DISK_SIZE`(安装前核对用,防选错盘)。
- **介质**:Windows 11 专业版官方安装 U 盘。校验口径沿用 L0:来自微软官方下载域,官方未发布该镜像哈希,因此**不做 SHA256 比对**,以"能正常引导进入安装界面"为可用判据。
- **数据前提:这块盘上的数据不需要保留**。L1 会对整盘执行 `clean`。有任何要留下的东西,先拷到别的盘上。
- **加密前提**:装机过程中不要启停 BitLocker / 设备加密。若开始前发现盘上已有 BitLocker 或设备加密,按[入口文档](00-overview.md)偏离表先挂起保护并备份 48 位恢复密钥;**无法挂起则该设备不适用本方案**。
- **空间前提**:磁盘末尾必须留出**不少于 115GiB 的未分配空间**(root 100 + Snapshot 15)。它必须在步骤 1 的分区表里留出来,不能留到 L3 再想办法腾。
- **输入给 L3 的隐含约定**:D: 上的目录命名(已知文件夹同名目录与 `D:\Shared\`)一旦定下就不要改,L4 的家目录重定向与共享盘用法都对齐这套名字。

## 步骤

### 1. 用安装介质启动,预建整盘分区表

做什么:从 Windows 11 专业版安装 U 盘以 UEFI 模式启动(启动菜单里选带 `UEFI:` 前缀的条目;按键见参数表 `BOOT_MENU_KEY`),在"现在安装"界面按 `Shift + F10` 调出命令行,执行分区表脚本:

```cmd
diskpart
```

先核对目标盘(**不可跳过**):

```text
list disk
select disk 0
detail disk
```

型号与容量必须与参数表 `DISK_MODEL` / `DISK_SIZE` 一致(容量约 953G)。不一致就停下核对是哪一块盘——`clean` 会整盘清空,没有撤销(设计文档第 9 节"安装时选错目标磁盘")。

确认无误后,按 [templates/partitions.txt](../templates/partitions.txt) 逐条执行(`select disk 0` → `clean` → `convert gpt` → ESP 2048MB → MSR 16MB → C: 204800MB → D: 650240MB)。脚本里已经写明:磁盘末尾约 115GiB **必须保持未分配**,不要用不带 `size` 的 `create partition`(它会吃满整盘,让 L3 无空间可用)。

执行完立刻核对:

```text
list partition
list disk
```

判据:分区 1 = 2048MB(ESP)、分区 2 = 16MB(MSR)、分区 3 = 204800MB(Windows)、分区 4 = 650240MB(Data),四个分区之后仍有约 115GiB 未分配;ESP 尺寸不得小于 2048MB。核对结果(原始输出)进步骤 6 的产物。

为什么预建而不是让安装程序自己分:Windows 安装界面无法把自动创建的 100MB 级 ESP 改成 2GiB(设计文档 3.4),而整盘重装恰好是唯一能自由定尺寸的时机;同时"整盘重排、一次分好"消除了"事后缩容"这一整类事故(设计文档 3.5)。

回退点:此时还没有任何数据。分区表不满意,随时整盘 `clean` 重来(见"回滚"第 1 条)。

### 2. 在 200GiB 分区上安装 Windows 11 专业版,并记录 WinRE 落点

做什么:回到安装界面继续,在"你想将 Windows 安装在哪里?"处**只选 200GiB 那个分区**(卷标 `Windows`),然后下一步。

**不要点"删除""新建""格式化"任何分区**:分区表已在步骤 1 定稿;点"新建"会把预留空间切碎,点"删除"会打乱 ESP 与 MSR。

安装程序对恢复分区(Windows RE)的放置有版本敏感性(设计文档 4.2 与第 9 节):它可能在磁盘末尾自行创建恢复分区,也可能把 Windows RE 写进那段预留空间。装完后记录实际落点:

```cmd
reagentc /info
diskpart
list disk
select disk 0
list partition
```

`reagentc /info` 的"Windows RE 位置"会给出恢复环境所在分区号,再与 `list partition` 的分区序列表对照,即可确定它是否吃掉了预留空间。

偏差判据(逐字执行):**只要 ESP 尺寸未被削减**(仍为 2048MB)**且留给 Linux 的未分配空间仍不少于 115GiB**(root 100 + Snapshot 15),就**接受**该偏差,并把偏差(恢复分区位置与大小、未分配空间实测值)记录进 `baseline/01-partitions.txt`。

若未分配空间不足 115GiB:

- **不得削减 ESP**(设计文档第 9 节明确"仅 ESP 尺寸不可削减");
- 因为此时还没有数据,唯一正确的做法是回到步骤 1 整盘 `clean` 重排重装:先在 [templates/partitions.txt](../templates/partitions.txt) 里把 D: 的 `size` 改小(小到缺口补足、预留空间重新不少于 115GiB),再 `select disk 0` → `clean` → 重跑该脚本 → 重新安装 Windows;
- **任何情况下都不做 D:/C: 的事后缩容,也不修改 root / Snapshot 的目标值**(root 100GiB、Snapshot 15GiB 是 L3 的输入,两侧都不许改)——需要改尺寸就整盘重来,重排时同样不得削减 ESP。重排后的实际尺寸与未分配空间实测值记入 `baseline/01-partitions.txt`,由 L2 逐项核对。

本步骤**不生成** ESP 镜像与固件启动项快照(L2 产物),也不改动 `BootOrder`。

### 3. 首次进桌面:关闭 Fast Startup(快速启动)与休眠

做什么:装完首次进桌面后,用管理员权限的命令提示符执行:

```cmd
powercfg /h off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```

`powercfg /h off` 关闭休眠并删除休眠文件(顺带关掉快速启动);再把 `HiberbootEnabled` 显式置 0,确保快速启动不会因系统设置的"派生开关"而残留。

为什么必须在 L1 做完:快速启动本质是"混合关机",关机后 NTFS 卷仍处于脏状态,Linux 侧 `ntfs3` 挂载共享盘 D: 会失败甚至损坏数据——这是[设计文档](design/00-design.md) 5.3 节的前置条件第 1 条,也是第 9 节"Fast Startup + 双写 NTFS"这条风险的第一道防线;休眠本身也在 v1 非目标内(设计文档 1.3)。

验证:

```cmd
powercfg /a
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled
```

期望输出:`powercfg /a` 里"休眠"与"快速启动"均显示为**不可用**(措辞随 Windows 版本而异);注册表 `HiberbootEnabled` 为 `0x0`。两项都要看——只删休眠文件而注册表值不为 0 时,快速启动仍可能被重新打开。

注意:Windows 大版本更新可能把这两项改回来,所以它同时列入周期性巡检(设计文档 7.1)与 L2 的复检项。

### 4. 系统盘隔离:已知文件夹、游戏库与容器镜像全部落到 D:

做什么:把"用户会产生数据的地方"逐个搬到 D:。这份清单就是 L2 与验收 D 组的核对项,一项都不能漏:

| # | 项目 | 目标位置 | 操作路径 |
|---|---|---|---|
| 1 | 桌面 | `D:\Desktop` | 资源管理器 → 右键"桌面" → 属性 → `位置` → `移动` 到 `D:\Desktop` |
| 2 | 文档 | `D:\Documents` | 同上(右键"文档" → 属性 → `位置` → `移动`) |
| 3 | 图片 | `D:\Pictures` | 同上 |
| 4 | 视频 | `D:\Videos` | 同上 |
| 5 | 音乐 | `D:\Music` | 同上 |
| 6 | 下载 | `D:\Downloads` | Windows 11 专业版的"下载"没有 `位置` 选项卡:走 `设置` → `系统` → `存储` → `高级存储设置` → `保存新内容的地方` → `新的下载内容` 选 `D:`;或改注册表 `User Shell Folders` 的 `{374DE290-123F-4565-9164-39C4925E467B}` 后重启资源管理器 |
| 7 | 新内容的默认保存位置 | 均选 `D:` | `设置` → `系统` → `存储` → `高级存储设置` → `保存新内容的地方`(新应用、文档、音乐、照片和视频、电影和电视) |
| 8 | 游戏库 | `D:\SteamLibrary` 等 | Steam:`设置` → `存储` → `添加驱动器` → `D:\SteamLibrary`;其他启动器(Epic / Battle.net / Ubisoft / EA)在各自设置里把安装目录改到 `D:` |
| 9 | 容器镜像 | `D:\Docker`(或 `D:\WSL\...`) | Docker Desktop:`设置` → `Resources` → `Disk image location` 改到 D:;WSL 发行版:`wsl --manage <发行版名> --move D:\WSL\<发行版名>` |
| 10 | 办公文件约定目录 | `D:\Shared\` | 手工创建;它是两个系统共用的办公目录(L3/L4 侧在 Linux 里对应挂载点下的同名目录) |

**明确不做:不要搬迁整个用户配置文件目录。** 不要把 `C:\Users\<用户名>` 整体移到 D:(既不通过"用户配置文件"对话框搬移,也不改 `ProfileList` 注册表)。理由有三条:NTFS 上的 ACL 与系统更新对配置文件路径敏感;"已知文件夹重定向"是 Windows 原生支持的路径,出问题一条命令就能回退;而"只格式化 C: 即可原地重装"这条前提(设计文档 4.8 办法一)依赖的正是"系统留在 C:、数据在 D:",把整个配置文件搬走会同时破坏这三条。本节只重定向上表列出的已知文件夹与库目录。

顺带核对两项与本步骤同源的事:

- **磁盘加密**:确认 C: 与 D: 均未加密 —— C: 不启用 BitLocker 是因为本方案 v1 不做磁盘加密(设计文档 3.9);**D: 不启用 BitLocker / 设备加密是共享盘方案的前提**(设计文档 5.3 前置条件第 2 条),加密后 Linux 侧无法直接读写。登录微软账户后 Windows 可能自动开启"设备加密",所以要显式查一次:

  ```cmd
  manage-bde -status
  ```

  期望:两个卷都显示"保护已关闭 / Protection Off"。若已被自动加密,先备份 48 位恢复密钥,再 `manage-bde -off C:` 与 `manage-bde -off D:`,等解密完成后再继续。

- **共享盘的卷标与位置**:本阶段只记录 D: 的卷标(`Data`)与它在分区表中的位置(第 4 个分区);`SHARED_PART_UUID` 不在这里填——UUID 在 L3/L4 由 `blkid` 取得后回填参数表(见[入口文档](00-overview.md)参数表说明)。

验证:逐项核对六项已知文件夹的重定向结果,命令与期望输出如下(与"验证"第 4 行同一口径)。

```cmd
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
```

期望输出:下列六项的值全部以 `D:\` 开头——`Desktop`(桌面)、`Personal`(文档)、`{374DE290-123F-4565-9164-39C4925E467B}`(下载)、`My Pictures`(图片)、`My Video`(视频)、`My Music`(音乐);同一份输出里其余值(如 `AppData`、`Local AppData`、`Cache`、`Fonts`)仍应留在 `C:\Users\<用户名>\...`,它们不在本次重定向范围内。等价写法:`Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"`。

再用"新建文件落点"实测一次:在桌面新建一个文件(或改一次桌面壁纸),确认它出现在 `D:\Desktop` 而不是 `C:\Users\<用户名>\Desktop`。

### 5. KMS 激活(只做外链与流程,不分发脚本本体)

**合规与责任声明**:本节只说明使用哪个上游开源项目、从哪个官方入口获取、以及如何核对结果。本仓库与本文档**不包含、不复制、不转载任何激活脚本本体**,不提供购买密钥或数字许可证的获取路径,也不引入任何自建 KMS 服务。照本节操作即表示你自行判断并承担所在地法律与软件许可协议下的合规责任;本仓库与作者不提供任何授权,也不对激活结果与后续许可风险负责。依据见[设计文档](design/00-design.md) 3.10 节与第 9 节"激活方案的平台合规风险"条目。

做什么(路线与机制,均以上游项目文档为准):

- 上游项目:`massgravel/Microsoft-Activation-Scripts`,官方入口 https://github.com/massgravel/Microsoft-Activation-Scripts(设计文档第 11 节)。本项目只使用其中的 **Online KMS** 路径。
- **Online KMS 机制**:激活周期为 **180 天**;上游脚本会创建一个**每 7 天**联系 KMS 主机以自动续期的计划任务,并在注册表留下 KMS 主机地址。因此激活是可续期、可复核的状态,不是一次性动作。
- **明确排除**:KMS38(微软自 Windows build 26100.7019 起已废弃该机制、上游亦已移除,对 Windows 11 专业版 24H2 及以后的版本无效);自建 KMS 服务:本方案不采用;HWID / TSforge 不作主路径。
- **获取与执行**:按上游项目 README 的官方说明操作(在其官方仓库 / 发布页获取,并在 Windows 侧按其指引运行),**本文不粘贴任何脚本内容,也不转述其脚本正文**。执行前确认来源就是上述官方仓库 / 发布页。

核对激活状态:

```powershell
slmgr /dlv
slmgr /xpr
Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
  Select-Object Name, LicenseStatus, GracePeriodRemaining
```

期望输出:`LicenseStatus` 为 `1`(已授权);`GracePeriodRemaining` 显示本次激活周期的剩余时间(KMS 客户端对应 180 天周期);`slmgr /dlv` 中能看到 KMS 相关信息与剩余天数(具体措辞随 Windows 版本而异,判据以上述字段为准)。`slmgr /xpr` 只作辅助,它的文案随版本变化。

续期任务与可达性核对:打开 `taskschd.msc`,确认上游流程创建的续期任务存在且处于启用状态(**任务名与创建方式以上游项目的输出为准,本文不固化**);并确认这台机器能联网访问 KMS 主机的 1688 端口(企业网、校园网与代理环境常在此处被拦)。

落盘:把 `slmgr /dlv`、`slmgr /xpr` 的输出、执行日期与上游项目版本号写进 `baseline/01-activation.md`。

**首次激活失败不阻塞 L1**:L1 与 L3 解耦(设计文档第 7 节 L1 行),如实记录失败状态与报错后继续 L2,后续再单独处理(见"失败处理")。

### 6. 记录 L1 产物,并复核四条不变量

做什么:

1. **`baseline/01-partitions.txt`**:步骤 1 的 `list disk` / `list partition` 原始输出 + 分区表定稿值 + WinRE 落点与未分配空间的实测偏差 + 各分区卷标 + 步骤 4 的重定向核对结果与 C: 内容核对结果(注记段)。
2. **`baseline/01-activation.md`**:`slmgr /dlv` 与 `slmgr /xpr` 输出 + 执行日期 + 上游项目版本号。
3. 两份产物**不入库**(`baseline/*` 已被 `.gitignore` 排除,只保留 `baseline/README.md`)。
4. **紧接着进入 L2**:装完 Windows 后不要长时间停留,L1 与 L2 必须在同一次会话内连续完成(交接规则第 4 条),L2 会把这里的记录当作复核对象,并生成基线(`02-esp-backup/`、`02-firmware-entries.txt`、`02-partitions.txt`)。

不变量复核(I1-I4):

```cmd
bcdedit /enum firmware
```

- **I1**:`BootOrder` 首位为 `Windows Boot Manager`(L1 新建的条目,默认就在首位)。照实记录即可;若固件 NVRAM 里仍有前次部署残留的 `ubuntu` 条目,**保留原样**——该条目不属 L1 处理范围,处置指引见 `07-rescue.md` 与 L2 的 `02-firmware-entries.txt`。
- **I2**:本阶段未执行任何 `efibootmgr -o`,也未改过 `BootOrder`。
- **I3**:`\EFI\Microsoft\` 与 `{bootmgr}` 的 path 未被动过。Windows 安装程序自己写入这两处属正常,不算违反 I3——I3 约束的是"我们与第三方工具不去覆盖它",这条约束在 L3 才真正进入日常操作。
- **I4**:首次装机时 L1 之前没有基线是允许的;基线由紧接着的 L2 生成。

## 验证

在 Windows 11 专业版的桌面环境里执行(步骤 1 的命令在安装界面的 `Shift + F10` 命令行里执行):

| # | 检查项 | 命令 / 方式 | 期望输出 / 判据 |
|---|---|---|---|
| 1 | 分区表与目标布局一致 | `diskpart` → `list partition`(或 `Get-Partition`) | 分区 1 = 2048MB、分区 2 = 16MB、分区 3 = 204800MB、分区 4 = 650240MB,顺序与卷标(`ESP` / `Windows` / `Data`)与 [templates/partitions.txt](../templates/partitions.txt) 一致 |
| 2 | ESP 尺寸未被削减 | 同上 | ESP = 2048MB(即 `ESP_SIZE` = 2GiB);小于该值时不得继续 |
| 3 | 留给 Linux 的未分配空间 | `list disk`(`可用` 列)/ `Get-Disk` | 不少于 115GiB;不足则按步骤 2 的偏差处理,并已记入 `baseline/01-partitions.txt` |
| 4 | C: 不含用户数据(逐项核对重定向) | `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"`(或 `Get-ItemProperty -Path "HKCU:\...\User Shell Folders"`)+ "新建文件落点"实测 + `manage-bde -status` | 该输出里 `Desktop` / `Personal` / `{374DE290-123F-4565-9164-39C4925E467B}` / `My Pictures` / `My Video` / `My Music` 六项的值全部以 `D:\` 开头(桌面/文档/下载/图片/视频/音乐);在桌面新建的文件出现在 `D:\Desktop`;游戏库与容器镜像目录在 D:;D: 已建 `D:\Shared\`;`C:` 上只有系统与程序 |
| 5 | Fast Startup 与休眠已关闭 | `powercfg /a`;`reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled` | 休眠与快速启动均显示不可用;`HiberbootEnabled` 为 `0x0` |
| 6 | 磁盘未加密 | `manage-bde -status` | C: 与 D: 均为"保护已关闭";**D: 不启用 BitLocker** 是共享盘方案的前提(设计文档 5.3) |
| 7 | 激活状态已核对并落盘 | `slmgr /dlv`、`slmgr /xpr`、`Get-CimInstance SoftwareLicensingProduct` | `LicenseStatus` = 1、剩余天数为 KMS 周期值;输出已写入 `baseline/01-activation.md` |
| 8 | 四条不变量未破 | `bcdedit /enum firmware` | `BootOrder` 首位为 `Windows Boot Manager`;本阶段未执行 `efibootmgr -o`;`\EFI\Microsoft\` 未被第三方覆盖;残留的旧 `ubuntu` 条目保留原样 |
| 9 | L1 产物齐备且未入库 | 人工复核 + `git status` | `baseline/01-partitions.txt`、`baseline/01-activation.md` 存在、字段无空缺;`git status` 中不出现 `baseline/` 下的产物 |

9 项全部通过 = L1 完成,可进入 L2(`03-preflight.md`);第 7 行按"激活未成功不阻塞"的例外计——若确实失败,须在 `baseline/01-activation.md` 里留下失败记录与报错,并在 L2 的闸门报告里作为黄项登记。

## 失败处理

| 现象 | 处置 |
|---|---|
| 分区表与第 1 行的目标布局不符 | 此时还没有数据:**重装重分**——回步骤 1 重跑[分区表脚本](../templates/partitions.txt)(必要时整盘 `clean`),不做逐分区微调(设计文档第 7 节 L1 行) |
| 安装程序把 WinRE 放进预留空间,或另建恢复分区 | 属已知偏差(设计文档 4.2、第 9 节):只要 ESP 未被削减且未分配空间仍不少于 115GiB 就接受,记录进 `baseline/01-partitions.txt`;不足则按步骤 2 处理。**任何情况下都不得削减 ESP** |
| 安装界面里选错分区,或误点"删除 / 新建" | 立刻取消安装(不要点"下一步");已装错则按"回滚"第 1 条整盘重来——此刻还没有数据,是代价最低的时刻 |
| 激活未成功 | **不阻塞**:把失败状态与报错记入 `baseline/01-activation.md` 后继续 L2(设计文档第 7 节 L1 行);后续单独处理——先核对网络 / 代理能否访问 KMS 主机的 1688 端口,再重跑一次在线激活流程 |
| 180 天周期内激活失效 | 检查续期任务与 KMS 主机可达性,手动触发一次续期;仍失败则重跑一次在线激活流程(设计文档第 9 节"KMS 续期依赖可达的 KMS 主机") |
| 装完之后 Windows 自动启用了设备加密 / BitLocker | 先备份 48 位恢复密钥,再对 C: 与 D: 执行 `manage-bde -off`,待解密完成再继续;D: 处于加密状态时 Linux 侧无法挂载共享盘,共享方案直接失效(设计文档 5.3 与第 9 节) |
| 已知文件夹重定向后个别程序不认新路径 | 只重定向文档类目录;把该程序的工作目录改到 D: 下对应子目录,或按其设置单独指定;仍出问题就按"回滚"第 3 条把这个文件夹改回默认路径。依据:设计文档第 9 节"家目录重定向后的应用不兼容" |
| `powercfg /h off` 后 `HiberbootEnabled` 仍为 1 | 重跑步骤 3 的 `reg add` 命令;确认是在管理员权限的命令行里执行;再查一次 `powercfg /a`。仍未生效时核对组策略 / 厂商电源管理软件是否把它改回 |
| 固件启动项里出现残留的 `ubuntu` 条目 | 保留原样,不改 `BootOrder`(I1、I2);L2 会为固件启动项留档,处置指引见 `07-rescue.md` |
| `bcdedit /enum firmware` 看不到 `Windows Boot Manager` | 检查启动模式是否被装成 Legacy / MBR(回[L0 手册](01-firmware.md)验证第 1 行与步骤 3);确认为 UEFI 后重启一次再查。仍看不到则按"回滚"第 1 条重装 |

## 回滚

1. **整盘重来(本阶段唯一的回滚手段)**:从安装介质启动 → `Shift + F10` → `diskpart` → `select disk 0` → `clean` → 重跑[分区表脚本](../templates/partitions.txt) → 重装 Windows。**不做逐分区修补**:分区表一旦定稿,任何改动都从整盘 `clean` 开始(设计文档 3.5、5.1)。装完之后要改分区表,则须先有可用基线(I4),而基线此时还不存在——所以"改分区表"在本阶段的等价手段就是重装。
2. **激活不作回滚项**:KMS 激活没有"卸载"这一说;失效时按"失败处理"重跑一次在线激活流程。激活失败本身不构成回滚理由(它在 L1 属"后续处理")。
3. **重定向回滚**:把该已知文件夹的"位置"改回默认路径(`C:\Users\<用户名>\...`)即生效;回退后**必须同步更新** `baseline/01-partitions.txt` 里的核对记录,否则 L2 与验收 D 组的判据会失真。
4. **固件项不动**:L1 不回滚 L0 的固件设置;`Secure Boot` 全程开启且**不作为可回滚项**(关闭会破坏 L3/L4 的签名链前提,见 [L0 手册](01-firmware.md)回滚第 3 条)。
5. **I4 复核**:L1 之后任何分区表或固件变更都必须先有可用基线;首次装机时基线由紧接着的 L2 生成,所以 L1 与 L2 必须连续完成。ESP 镜像与固件启动项快照**不是** L1 产物,不要在本阶段顺手生成——那会让产物归属与阶段判据同时失真。
