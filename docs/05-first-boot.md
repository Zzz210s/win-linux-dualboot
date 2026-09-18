# L4:首启收敛(共享盘、家目录、显卡、时间、蓝牙与健壮性)

本文件是 L4 阶段的手册。目标状态、四条不变量(下称 I1-I4)与参数名在[入口文档](00-overview.md)中定义;前提由 [L3 手册](04-ubuntu.md)交付;动机与依据见[设计文档](design/00-design.md) 3.6 节(容量与共享盘的关系)、3.8 节(交换空间)、3.14 与 4.7 节(健壮性 R1-R9)、3.16 与 5.3 节(共享盘与四条前提)、3.17 节(显卡模式 MUX 分支)、3.18 节(内核与驱动更新收紧)、3.19 节(引导菜单黑屏)、4.5 节(L4 步骤)、第 9 节(风险登记)与 11.1 节(评论区实战证据)。

L4 是**收敛与加固**,不是再装一遍系统:本阶段**不动分区表、不动固件设置,也不改 `BootOrder`**,所以不触发 I4 的"改分区表/固件前先重做基线"约束(设计文档 4.7 的 R1 仍适用于内核与驱动变更)。三条口径贯穿全文,越界即视为设计缺陷:

- **内核与显卡驱动不自动更新**:`linux-*`、`nvidia-*` 列入自动更新的黑名单,变更必须"先做快照、再手动执行"(决策 3.18);
- **不做休眠**:交换空间用 zram + swapfile,不是为了休眠——休眠需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车(决策 3.8);
- **不引入自签 Secure Boot 密钥**:显卡驱动只走 Ubuntu 仓库的预签名包,不做 DKMS、不开 Secure Boot(决策 3.3、4.5)。

## 目标

L4 完成后,这台设备应当达到:

| # | 目标状态 | 判据 |
|---|---|---|
| 1 | 共享数据盘(Windows 的 `D:`)以 `ntfs3` **读写**挂载到 `/mnt/shared`;L4 写入的三条 `fstab` 条目(共享盘、`/snapshots`、swapfile)都带 `nofail` | 本文"验证"第 1、2 行 |
| 2 | 共享盘写测试通过,且 Windows / Ubuntu **双向可见性**一致(设计 5.3 验收) | 本文"验证"第 3、4 行 |
| 3 | 文档类家目录指向共享盘;**配置、凭据与代码仓库留在本地 root** | 本文"验证"第 5、6 行 |
| 4 | 会话为 **Wayland**,NVIDIA 驱动走仓库预签名包,PRIME offload 可用,nouveau 兜底可达 | 本文"验证"第 7、8、9 行 |
| 5 | `RTC in local TZ: no`(Linux 用 UTC),两系统时间一致 | 本文"验证"第 10 行 |
| 6 | 蓝牙配对密钥已按上游建议从 Windows 侧同步,两系统不需反复重配对 | 本文"验证"第 11 行 |
| 7 | 健壮性 R1-R9 就绪:快照分区可用、journald 持久化、SSH 救援通道、更新策略收紧、SMART 监控 | 本文"验证"第 12 行 |
| 8 | 回 Windows 的入口可用(一次性 `BootNext` 或厂商菜单键),且 `BootOrder` 首位未变(I2) | 本文"验证"第 13 行 |
| 9 | 本阶段产物在位且不入库 | 本文"验证"第 14、15 行 |

本阶段的产物逐字为两份文件(命名契约见 [baseline/README.md](../baseline/README.md)):

- `baseline/04-first-boot.md`:六项字段——会话类型、GPU 模块状态、共享盘挂载与写测试结果、XDG 重定向核对、`timedatectl` 输出、蓝牙同步结论;由本文步骤 8 采集;
- `baseline/04-robustness.md`:健壮性核对——快照可用性与回滚演练、journald 持久化、SSH 可达、更新策略、SMART 状态;由本文步骤 6 的脚本产出整理而成。

多设备时按 [baseline/README.md](../baseline/README.md) 的布局落盘到 `baseline/<设备别名>/`;`baseline/*` 被 `.gitignore` 排除(仅 [baseline/README.md](../baseline/README.md) 例外)。

执行顺序上有一处交叉,必须先说清:**R1 要求"任何内核/驱动变更之前先有可回滚的快照点",而快照工具在步骤 6 才配置。** 因此实际操作时,先执行步骤 6 的第 1 小节(快照与旧内核)再回来做步骤 3(显卡驱动),或至少确认 GRUB "Advanced options" 里的旧内核可选、`/snapshots` 可写。本文正文仍按 1-8 编号,执行时按这句话调整先后。

## 前置条件

- **L3 已收尾且 11 项全绿**:`baseline/03-efi-layout.txt` 在位,`BootOrder` 首位仍是 `Windows Boot Manager`,`ubuntu` 条目在末尾(I1、I2 未被破坏)。L4 不修引导,带引导问题进来只会把两件事混在一起。
- **BitLocker 保护已恢复**:L3 步骤 8 的 `manage-bde -protectors -enable C:` 已完成。L4 不改分区表与固件,但共享盘方案的前提是 `D:` **不加密**,该状态要与 [L2 手册](03-preflight.md)的记录一致。
- **回 Windows 的入口可用**(设计文档交接规则第 6 条):`BOOT_MENU_KEY` 能调出一次性启动菜单(见 [L0 手册](01-firmware.md) 厂商差异表);或 [scripts/linux/reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh)、[scripts/windows/set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)| 二者任一可用即可,**不允许**用 `efibootmgr -o` 代替(I2)。
- **快照能力已就绪**(R1、R2):`/snapshots` 分区可写;Timeshift 由步骤 6 配置(目标为 `/snapshots`、保留 3 份(可调))。在第一次内核/驱动变更之前必须已有至少一个快照点,否则**不得**执行该变更。
- **参数表已填**(每台设备一份,见[入口文档](00-overview.md)):`SHARED_PART_UUID`(Windows `D:` 分区 UUID)、`SNAPSHOT_PART_UUID`(L3 建的 15GiB ext4 快照分区)、`GPU`(是否混合显卡)、`BOOT_MENU_KEY`、`DISK`。两个 UUID 的取值来源是 `baseline/02-partitions.txt` 与 L3 分区表交叉核对,**不要凭记忆填写**。
- **Windows 侧重定向清单已固化且不得再改名**(L1 的隐含约定,见 [L1 手册](02-windows.md) 第 4 节):`D:\Desktop`、`D:\Documents`、`D:\Downloads`、`D:\Pictures`、`D:\Videos`、`D:\Music` 与办公约定目录 `D:\Shared\`。Linux 侧逐项对应为 `/mnt/shared/{Desktop,Documents,Downloads,Pictures,Videos,Music}` 与 `/mnt/shared/Shared/`。
- **救援介质在位**(R4):L3 用过的 Ubuntu 安装 U 盘保持"已验证可用",不回收。显卡环节是本阶段最容易进不去桌面的地方。
- **网络与时间**:Ubuntu 能联网(`apt` 可用、`systemd-timesyncd` 正常),蓝牙同步脚本需要下载上游仓库。
- **口径**:**本阶段不做休眠、不关 Secure Boot、不自签密钥、不降级发行版**;驱动不认时优先换内核(HWE)或换驱动版本(设计 3.17 被否方案、第 9 节)。

## 步骤

### 1. 挂载共享数据盘(`D:`,ntfs3)

做什么:把 Windows 的 `D:` 以 `ntfs3` 读写挂载到 `/mnt/shared`,并把挂载行写进 `/etc/fstab`。这一步是"文档类数据不占 root"的前提——root 只给 100GiB(决策 3.6),办公文件全在共享盘上,切系统即可接着干(决策 3.16、5.3)。

#### 1.1 四条前提(缺一不可,先逐条核对)

| # | 前提 | 核对命令 | 期望 |
|---|---|---|---|
| 1 | Windows 已关闭 **Fast Startup 与休眠** | Windows 侧 `powercfg /a`、注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` 的 `HiberbootEnabled` | "休眠/快速启动"不可用;`HiberbootEnabled = 0`。否则 NTFS 处于混合关机的脏状态,Linux 挂载会失败甚至损坏数据 |
| 2 | `D:` **未启用 BitLocker / 设备加密** | Windows 侧 `manage-bde -status D:` | `Protection Off` / `未加密`。加密后 Linux 侧无法直接读写,共享盘方案直接失效 |
| 3 | 挂载选项固定 `uid/gid/umask` 并用 `windows_names` | 见 [templates/fstab.snippet](../templates/fstab.snippet) | 六项选项齐备:`rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime`;`ntfs3` 没有 POSIX 权限位,`windows_names` 阻止 Linux 侧创建 Windows 非法文件名 |
| 4 | **不把依赖 POSIX 语义的工作流放在共享盘** | 见本文 1.4 的清单 | 清单里的东西一律留在本地 root |

补充一条操作纪律(风险表"Fast Startup + 双写 NTFS"行):**Windows 处于休眠或快速启动状态时,绝不让 Linux 挂载共享盘**;两系统运行期互不影响,同一时刻只有一个系统在跑,但"从休眠恢复"会绕过正常关机流程。

#### 1.2 写挂载行

先 dry-run 看清将写入什么,确认无误再 `--apply`:

```bash
# 取值来源:baseline/02-partitions.txt(Windows 侧快照)与 L3 分区表交叉核对
sudo blkid -s UUID -o value /dev/nvme0n1p4        # 核对的是哪个分区以分区表为准
sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --snapshot-uuid <SNAPSHOT_PART_UUID>
```

脚本做四件事:校验分区存在(`blkid -U`)→ 校验模板里的挂载选项(`windows_names`、`uid=`、`gid=`、`umask=`、`nofail`)→ 打印将追加的两行 → 挂载成功后调用 [scripts/linux/xdg-redirect.sh](../scripts/linux/xdg-redirect.sh) 做家目录重定向(步骤 2)。

确认 dry-run 输出与设计 5.3 的推荐参数一致后执行:

```bash
sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --snapshot-uuid <SNAPSHOT_PART_UUID> --apply
```

`--apply` 的实际动作顺序:备份 `/etc/fstab` 为 `/etc/fstab.dbk.bak`(只在备份不存在时创建,重跑不会覆盖首次备份)→ `mkdir -p /mnt/shared` → 逐行核对后补写缺失的挂载行(**共享盘行与快照分区行各自独立判定**,重跑既不会重复也不会覆盖;第一次只给 `--uuid`、第二次才补 `--snapshot-uuid` 时会补上快照分区行)→ `systemctl daemon-reload` → `mount -a`(返回非零只告警,带 `nofail` 的条目失败不致命)→ 校验挂载 → **写测试** → 调用 `xdg-redirect.sh --apply`。日志追加到 `/var/log/dbk/mount-shared.log`。

未提供 `--snapshot-uuid` 时,脚本会显式提示"快照分区行未写入(未提供 `--snapshot-uuid`);该行缺失会导致 R1/R2 无落点"——此时步骤 6 的快照功能没有存放位置,要么补上该 UUID 重跑,要么按步骤 6 另行安排快照落点并记录偏差。

`nofail` 不是可选项:万一分区缺失或写坏,启动过程不能被它卡住(设计文档 4.5、第 7 节"`fstab` 写坏"行)。

#### 1.3 写测试与双向可见性测试

写测试由脚本自动完成:在 `/mnt/shared/.dbk-write-test` 上创建并删除一个文件,失败即判定"不可写"(常见原因是 Windows 未关 Fast Startup、或 `D:` 被加密)。手工复测:

```bash
touch /mnt/shared/.dbk-write-test && rm -f /mnt/shared/.dbk-write-test && echo "写测试通过"
```

双向可见性测试(设计 5.3 的验收项,纳入'验证'第 4 行),两遍都要做:

1. **Windows -> Linux**:在 Windows 里写入 `D:\Shared\dbk-visibility.txt`(内容任意,含时间戳更好),重启进 Ubuntu 后 `cat /mnt/shared/Shared/dbk-visibility.txt`;
2. **Linux -> Windows**:在 Ubuntu 里 `echo ok > /mnt/shared/Shared/dbk-visibility-linux.txt`,重启进 Windows 后在资源管理器里打开 `D:\Shared\` 并读取内容。

两边内容必须一致。测完把两个标记文件删掉。

#### 1.4 "不要在共享盘上做的事"清单

NTFS 没有 POSIX 权限语义(设计 5.3 与第 9 节"POSIX 语义差异"行),因此:

- **不把 `~/.config`、`~/.ssh`、`~/.gnupg` 等配置与凭据目录放到共享盘**(留在本地 root;这也正是步骤 2 只重定向文档类目录的原因);
- **不把代码仓库或任何依赖符号链接 / 硬链接 / 可执行位 / 大小写敏感重命名的工程放上去**——这类工具在 NTFS 上不可靠;
- **不在 Linux 侧对共享盘做批量重命名或大目录移动**(风险表"`ntfs3` 写入导致数据损坏"行的主要触发动作);
- **不把需要权限位或 setuid 语义的脚本、服务数据放在上面**;
- **同卷容量竞争**:`D:` 同时承载游戏库、容器镜像、WSL 发行版与桌面/下载/图片/文档,所以"共享盘要满了"的容量告警必须与游戏、镜像的安装计划一起看,不要只盯某一类文件;
- **跨系统产物混入**:Linux 侧在共用目录产生的 `.desktop`、dotfile、`~$` 开头的 Office 临时文件在 Windows 资源管理器里会显形,Windows 侧的 `desktop.ini`、`Thumbs.db` 会出现在 Linux 目录里——因此共用目录里不要放依赖命名约定或扩展名的临时产物(脚本、构建中间产物、按后缀匹配的清理规则);
- **下载目录合流**:同一个 `D:\Downloads` 被两边浏览器共用,Windows 侧的清理工具与搜索索引会扫到 Linux 产物(反过来也一样),清理前先确认文件来自哪个系统,不要按"最近下载"一把梭;
- **关键目录在别处保留第二份备份**(云端或外置盘)——共享盘上的办公文件是本方案唯一的"两系统都能写"的区域,也是最需要冗余的区域;
- 遇到"设备忙 / 目录非空"时,先在 Windows 侧关掉资源管理器预览、搜索索引或同步客户端(如 OneDrive),再回 Linux 操作。

### 2. 家目录重定向(只重定向文档类目录)

做什么:用 `~/.config/user-dirs.dirs` 把**文档类**目录指向共享盘上的对应目录,与 Windows 侧已知文件夹重定向逐项对齐(L1 第 4 节的清单):

| Windows 侧(L1 定稿) | Linux 侧目标 |
|---|---|
| `D:\Desktop` | `/mnt/shared/Desktop` |
| `D:\Documents` | `/mnt/shared/Documents` |
| `D:\Downloads` | `/mnt/shared/Downloads` |
| `D:\Pictures` | `/mnt/shared/Pictures` |
| `D:\Videos` | `/mnt/shared/Videos` |
| `D:\Music` | `/mnt/shared/Music` |
| `D:\Shared\`(办公约定目录) | `/mnt/shared/Shared/` |

先 dry-run,再 `--apply`:

```bash
sudo bash scripts/linux/xdg-redirect.sh --user <用户名>
sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --apply
```

脚本行为:校验模板 [templates/user-dirs.dirs.snippet](../templates/user-dirs.dirs.snippet) 里六条 `XDG_*_DIR` 齐备且**全部指向 `/mnt/shared`**→ 确认 `/mnt/shared` 已挂载(未挂载时拒绝执行,避免目标落在本地 root)→ 备份原文件为 `user-dirs.dirs.dbk.bak`(**只在备份不存在时创建,重跑不会覆盖首次备份**,所以它始终是改动前的内容,下方回退命令随时可用)→ 写入六行 → 以该用户身份执行 `xdg-user-dirs-update --force` → 建好缺失的目标目录并 `chown`(`chown` 被 NTFS 拒绝时只打印警告并继续——共享盘的属主由 `uid=`/`gid=` 挂载选项固定,这种情况属正常,不影响使用)→ 逐条回读打印。日志追加到 `/var/log/dbk/xdg-redirect.log`。挂载脚本在 `--apply` 时会自动调用它,所以正常路径下不需要手工再跑一次;若调用失败,挂载脚本会明确报出"家目录重定向失败(共享盘已挂载、写测试已通过)",修好后可单独重跑本脚本。

**留在本地 root 的东西**(与共享盘清单互为镜像):

- `~/.config`、`~/.ssh`、`~/.gnupg` 等配置与凭据目录;
- 代码仓库与所有依赖 POSIX 语义的工程目录;
- `~/Templates`、`~/Public`:模板里保持默认(注释掉即不动),不指到共享盘。

三条注意事项:

- 重定向只影响"新建文件落在哪";已经分散在本地 `~/Documents` 等处的旧文件**不会**自动搬走,需要时手工 `mv`(并注意不要在共享盘上做大目录批量移动,见 1.4);
- 个别程序不认自定义 XDG 目录,或在 NTFS 上无法保存权限位(风险表"家目录重定向后的应用不兼容"行)——只重定向文档类目录就是为了把影响面压到最小;出问题按本节回退;
- 改完之后新开会话(注销重登)再验证,部分应用会缓存旧路径。

**回退命令**(随时可逆):

```bash
cp -a ~/.config/user-dirs.dirs.dbk.bak ~/.config/user-dirs.dirs
sudo -u <用户名> xdg-user-dirs-update --force
xdg-user-dir DOCUMENTS     # 应回到 /home/<用户名>/Documents
```

该备份是**首次 `--apply` 之前**的内容——重跑脚本不会覆盖它,所以随时可以按上面三行回到改动前(而不是回到"上一轮重定向"的状态)。

更彻底的回退:删掉 `~/.config/user-dirs.dirs` 后以该用户执行 `xdg-user-dirs-update --force`,即可回到发行版默认目录。

### 3. 显卡驱动与显示策略

做什么:按设计 4.5 与决策 3.3 / 3.17 / 3.18 / 3.19 收敛显示栈。**本步骤的全部动作由 [scripts/linux/graphics.sh](../scripts/linux/graphics.sh) 承载**(已交付);下面只写口径与判据,排障时可单独重跑 `sudo bash scripts/linux/graphics.sh --apply`(默认 dry-run:不加 `--apply` 只打印采集结果、将执行的动作与回退指引,不改动系统)。

驱动路径(不可偏离):

1. **只用 Ubuntu 仓库的预签名 NVIDIA 模块包**:`ubuntu-drivers list` 查看候选 → `ubuntu-drivers install` 安装(或 `apt install linux-modules-nvidia-*-generic`);
2. **不做 DKMS 编译、不用 `nvidia-open` 源码构建**:Secure Boot 保持开启(决策 3.3),自签密钥属新增风险;仓库预签名包是唯一在"Secure Boot 开"状态下可用的路径(设计 4.5、事实表);
3. **nouveau 是天然回滚点**:卸载专有驱动即回 nouveau(设计 4.5 回滚列)。模块若被签名拒绝(`dmesg | grep -i 'key was rejected'`,或出现 `lockdown` 相关记录)→ 回退 nouveau,记录偏差,不要在这一步反复试;
4. **保留旧内核**:升级/安装驱动后确认 GRUB "Advanced options" 里仍有可用的旧内核(R3),这是驱动翻车时最快的一条退路。

显示策略(混合显卡默认):

- **集成显卡承担主显示 + 独显 PRIME offload**;
- 单显卡设备(仅独显)按[入口文档](00-overview.md)偏离表的"NVIDIA 单显卡分支"跳过 PRIME 配置,显示输出直接由独显承担;
- offload 的用法(按需渲染时才用独显):

```bash
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <命令>
```

会话与 Wayland 校验(判据在'验证'第 7 行):

```bash
echo "$XDG_SESSION_TYPE"                       # 期望 wayland
cat /proc/cmdline                              # 期望不含 nomodeset
loginctl show-session "$(loginctl | awk -v u="$USER" '$3==u {print $1; exit}')" -p Type
```

- **`nomodeset` 必须已移除**:它关掉 KMS,而默认会话是 Wayland(设计 11.1 第 2 条)。L3 应急用过的话,按 [L3 手册](04-ubuntu.md) 步骤 5(a)去掉并 `sudo update-grub`;判据就是上面两行;
- 若 `XDG_SESSION_TYPE` 仍是 `x11` 或会话异常,先确认驱动已加载、`nomodeset` 已移除,再考虑重建会话。

MUX 分支(指向 L3,不在本步骤展开):**混合模式下装完驱动仍点不亮/黑屏时**,按设计 3.17 走 [L3 手册](04-ubuntu.md) 步骤 5(b)的 MUX 分支——固件切"独显直连"先拿到可用系统,再权衡是否切回混合。必须记录代价:所有进程占用独显显存、续航明显变差、日后本地推理显存被显示输出吃掉。**不因驱动问题降级发行版**;驱动不认时的顺序是:换更新内核(HWE)→ 换驱动版本 → 才考虑发行版问题(设计第 9 节)。

引导菜单阶段黑屏(键盘仍可用):按决策 3.19 处置——`GRUB_TERMINAL=console` 后 `update-grub`(模板 [templates/grub-defaults.snippet](../templates/grub-defaults.snippet),合并动作见步骤 6 的 R3 行),日常切换系统改用步骤 7 的一次性入口。此时菜单黑屏**不等于**系统损坏,不要重装。

变更纪律(R1 + 3.18):装驱动、换内核之前先建快照点(步骤 6 第 1 小节);内核与驱动**不参与自动更新**;大版本升级前同样先快照。

### 4. 时间:RTC = UTC

做什么:让固件 RTC 以 UTC 记时,两系统时间一致(设计 4.5)。

```bash
timedatectl set-timezone Asia/Shanghai    # 时区按实际选择
sudo timedatectl set-local-rtc 0          # RTC 按 UTC,不用本地时间
sudo timedatectl set-ntp true             # 启用网络校时
timedatectl                               # 判据:RTC in local TZ: no
```

- 期望输出里 `RTC in local TZ: no`、`System clock synchronized: yes`、`NTP service: active`(判据见'验证'第 10 行);
- `systemd-timesyncd` 负责校时;若被禁用先 `sudo systemctl enable --now systemd-timesyncd`。

Windows 侧(可选,与 Linux 侧成对):

```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

- 语义:告诉 Windows"固件时钟走 UTC",这样它就不会把 RTC 当本地时间读(否则两系统切换后常见偏差整时区);
- 需要管理员；这是 Windows 侧的一次性配置,**只在 Windows 里改**,不要在 Ubuntu 里挂载并写 Windows 注册表(该文件被系统独占,且容易写坏);
- 可逆:删掉该值即回到默认(Windows 把 RTC 当本地时间);
- 两种口径选一种并保持:要么"Windows 用 `RealTimeIsUniversal=1` + Linux RTC=UTC",要么"Linux 迁就本地时间(`set-local-rtc 1`)";本方案取前者(设计 4.5 写的是 `RTC in local TZ: no`)。

### 5. 蓝牙配对密钥同步

做什么:把两套系统的蓝牙配对密钥同步,避免每次切系统都要重新配对(设计 4.5、风险表"双系统时间 / 蓝牙状态分裂"行)。

- **上游工具**:`KeyofBlueS/bt-keys-sync`(https://github.com/KeyofBlueS/bt-keys-sync),依赖 `chntpw`。本仓库只调用上游脚本,**不内置其代码**(第 11 节的引用结论);
- **方向:以 Windows 侧密钥为准**,用上游的 `--windows-keys` 路径导入到 Linux;**不做反向写入 Windows 注册表**——上游自己的建议也是这个方向,反向写风险更高(4.5 回滚列:"注册表有备份,可还原");
- **包装脚本**:[scripts/linux/bt-keys-sync-wrapper.sh](../scripts/linux/bt-keys-sync-wrapper.sh)负责装 `chntpw`、确认 Windows 分区可读(只读即可读取注册表文件)、下载上游脚本到 `/opt/bt-keys-sync/`、按下面顺序提示操作;
- **操作顺序**(顺序错了就得重来):
  1. 先在 **Ubuntu** 里完成一次正常配对(生成 Linux 侧记录);
  2. 重启进 **Windows**,对同一设备**重新配对一次**(让 Windows 侧成为权威来源);
  3. 再回 **Ubuntu**,以 `--windows-keys` 从 Windows 注册表导入密钥;
  4. 复测:同一设备在两个系统里都能直接连接,不需要再次配对。
- **读写面**:读取 Windows 注册表只需挂载 Windows 分区(例如 `sudo mount -o ro /dev/nvme0n1p3 /mnt/win`),**不要**用可写方式挂载系统分区。

### 6. 健壮性配置(设计 3.14 与 4.7 的 R1-R9)

做什么:按九项措施把"不会因为一次升级、一个驱动或一块盘的问题而失去可用系统"落到机器上。全部动作由 [scripts/linux/storage.sh](../scripts/linux/storage.sh)(交换空间与 zram)、[scripts/linux/hardening.sh](../scripts/linux/hardening.sh)(R1-R9 六项)承载,由 [scripts/linux/first-boot.sh](../scripts/linux/first-boot.sh) 依次编排(四个脚本 storage / hardening / mount-shared / graphics 均已交付,位于 `scripts/linux/`);手动执行的等价命令见下表的"判据"列。

四个脚本都**默认 dry-run**:不加 `--apply` 只打印计划、不改系统。先看计划,再执行:

```bash
# 1) 先看计划(不需要 root;日志改落 <TMPDIR>/dbk-<uid>/)
bash scripts/linux/first-boot.sh --uuid <SHARED_PART_UUID> --snapshot-uuid <SNAPSHOT_PART_UUID>
# 2) 再真正执行(需要 root):模块顺序固定为 storage -> hardening -> mount-shared -> graphics
sudo bash scripts/linux/first-boot.sh --apply --uuid <SHARED_PART_UUID> --snapshot-uuid <SNAPSHOT_PART_UUID>
```

- **安装前置**:zram 单元由 `systemd-zram-generator` 提供,该包必须在 zram 配置落地前装好。`storage.sh --apply` 会自己 `apt-get install -y systemd-zram-generator` 一次(已装则跳过;`DBK_SKIP_APT=1` 时只跳过安装,便于无 apt 环境做静态校验)。若脚本报"必须先执行 `sudo apt install -y systemd-zram-generator` 再重跑",照提示装完重跑 `storage.sh --apply` 即可,否则 R6 的 zram 半项判据不成立;
- **`--uuid` 与 `--snapshot-uuid` 的先后**:两个 UUID 都先交给 `mount-shared.sh` 写 `fstab`(共享盘行与快照分区行各自独立判定,第一次只给 `--uuid` 也能跑,补上 `--snapshot-uuid` 重跑会补写快照行);`--snapshot-uuid` 决定 `/snapshots` 是否可用——**它是 R1/R2 的落点,缺了它 R1/R2 判据不可能达成**;
- **退出码不能当判据**:`first-boot.sh` 的模块失败不改变退出码(恒为 0;**仅用法/权限类错误才非 0**),要看的是 `/var/log/dbk/first-boot-summary.txt`——表头 `模块 | 状态 | 关键输出`,末尾有 `失败项: N;跳过项: M` 与失败模块清单。`--apply` 之后先看这个文件,再看 `/var/log/dbk/<模块>.log`;
- **`hardening.sh` 要在 `mount-shared.sh` 之后复跑一次**:编排顺序是 hardening 在 mount-shared 之前,所以首次 `--apply` 时 `/snapshots` 还没挂上,R1/R2 会记 `fail`(属预期,不是缺陷);`mount-shared` 记 `ok` 后执行 `sudo bash scripts/linux/hardening.sh --apply`,R1/R2 才会记为 `ok`;
- **单模块重跑**(排障,全部幂等):`sudo bash scripts/linux/storage.sh --apply`、`sudo bash scripts/linux/hardening.sh --apply`、`sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --snapshot-uuid <SNAPSHOT_PART_UUID> --apply`;
- **`graphics.sh`**(见 [graphics.sh](../scripts/linux/graphics.sh)):`first-boot.sh` 会按当前模式(`--apply`/`--dry-run`)调用它并记 `ok`/`fail`(沿用脚本退出码);只有当**仓库里 `graphics.sh` 文件不存在**时才会记 `skipped` 并打印提示级消息(**不改退出码、不阻塞登录**),此时显卡驱动按步骤 3 手工收敛;脚本内另有 `DBK-RESULT skipped` 的情形——**本机无 NVIDIA 独显或读不到显卡信息**(`lspci` 无 VGA/3D 数据、无 `pciutils`)时跳过模块加载判定,属正常跳过,不是失败。单独重跑:`sudo bash scripts/linux/graphics.sh --apply`(也可先 `bash scripts/linux/graphics.sh` 看 dry-run 采集结果);脚本支持 `DBK_CMDLINE=<文件>` 替换 `/proc/cmdline`、`DBK_LOG=<文件>` 替换日志路径,便于离线演练/复核。**dry-run 与 `--apply` 的判据差异**:dry-run 下 graphics 的真机判据失败以 `DBK-RESULT dry-run-fail` 呈现(状态列仍为 ok,不算失败项);`--apply` 下同一条件才是 `DBK-RESULT fail` 且 RC=1。

| # | 措施 | 落地 | 判据 / 回滚点 |
|---|---|---|---|
| R1 | **变更前快照** | Timeshift 目标为 `/snapshots`,**仅在变更前手动创建**(不强加定时任务),在装驱动/换内核之前先建一份 | `/snapshots` 下有快照;回滚 = 从快照整体还原 |
| R2 | **独立快照分区** | 15GiB ext4 挂 `/snapshots`(L3 已建,本步骤确认可写),保留 3 份(可调) | `findmnt /snapshots`;删除快照即回收空间 |
| R3 | **多内核保留 + 一次性启动** | 不启用 `Remove-Unused-Kernel-Packages`;`GRUB_DEFAULT=saved`(模板 [templates/grub-defaults.snippet](../templates/grub-defaults.snippet),由本步骤的 hardening 合并) | GRUB "Advanced options" 有旧内核;`grep GRUB_DEFAULT /etc/default/grub` |
| R4 | **永久救援介质** | L3 的安装 U 盘不回收,标记"已验证可用" | 介质在位;从 U 盘能进 live 环境 |
| R5 | **崩溃可观测** | journald 持久化(`/var/log/journal`)+ 自建日志目录 `/var/log/dbk/` | `ls -d /var/log/journal`;`journalctl -b -1` 可读 |
| R6 | **OOM 与内存压力防护** | zram(约 `min(RAM/2, 8GiB)`)+ swapfile 4GiB,确认 `systemd-oomd` 启用 | `zramctl`、`swapon --show`、`systemctl is-enabled systemd-oomd` |
| R7 | **常开 SSH 救援通道** | 安装并启用 `openssh-server`(桌面挂死时从另一台机器登录排障) | `ss -tlnp \| grep :22` |
| R8 | **保守更新策略** | `unattended-upgrades` 只装安全更新、**不自动重启**、`Remove-Unused-Kernel-Packages=false`,并把 `linux-`、`nvidia-` 列入 `Package-Blacklist` | 配置文件位在 `/etc/apt/apt.conf.d/`;大版本升级前先做 R1 快照 |
| R9 | **磁盘健康监控** | 安装 `smartmontools` 并启用 `smartd`;保留 ext4 周期性 `fsck` 默认策略 | `systemctl is-active smartd`、`smartctl -H <盘>` |

**明确不做**:休眠(需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车);btrfs 快照(与已选 ext4 冲突);自定义 Secure Boot 密钥(改动签名链等于新增风险)(设计 4.7 末段)。

交换空间的取值与理由(决策 3.8):zram 约 `min(RAM/2, 8GiB)` + swapfile 4GiB,**不建 swap 分区**——尺寸可随时调整,不必再动分区表。

### 7. 回 Windows 的入口

做什么:确认本机有一条"一键回 Windows"的路径,并且它是**一次性**的(I2)。

- **Ubuntu 侧**:[scripts/linux/reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh)用 `efibootmgr -n <Windows 条目编号>` 设置一次性启动项,执行后重新读取并断言 `BootOrder` 未变,再 `systemctl reboot`;
- **Windows 侧**:[scripts/windows/set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)用 `bcdedit /set {fwbootmgr} bootsequence {GUID}` 做等价的一次性切换,执行后同样断言第一条仍是 Windows Boot Manager;
- **厂商菜单键**:开机按 `BOOT_MENU_KEY`(参数表)选 `Windows Boot Manager`,这是零副作用的兜底路径,也是 L3 进 Linux 用的同一条路径(见 [L0 手册](01-firmware.md) 厂商差异表)。

三条纪律:

1. **绝对禁止 `efibootmgr -o`**(I2,交接规则第 5 条):一次性条目用后自动消失,永久顺序一旦被改就可能留下"没人记得撤销"的状态,而删除 Linux 分区时正需要"首位是 Windows";
2. 用厂商菜单键或 `BootNext` 都属于"一次性",**不构成对 `BootOrder` 的改动**;若发现首位变成了 `ubuntu`,按 [L3 手册](04-ubuntu.md)"失败处理"里"重启默认进了 Ubuntu"一行处置,并记录偏差;
3. 驱动/内核变更之前先确认这条入口可用(交接规则第 6 条)——它是显卡翻车时回 Windows 查资料的唯一通道。

### 8. 生成 `baseline/04-first-boot.md`(以及步骤 6 的 `04-robustness.md`)

做什么:把本阶段的实测状态落盘。`baseline/` 在本机的仓库目录里(Windows 侧),所以先在 Ubuntu 里把输出存成文本,再回 Windows 粘贴落盘;多设备时落到 `baseline/<设备别名>/`。

```bash
{
  echo "# baseline/04-first-boot.md (L4 产物)"
  echo
  echo "## 会话类型"
  echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
  echo "kernel=$(uname -r)"
  echo "cmdline=$(cat /proc/cmdline)"
  echo
  echo "## GPU 模块状态"
  lspci -nn | grep -E 'VGA|3D'
  echo "--- lsmod ---"
  lsmod | grep -E '^(nvidia|nouveau)' || echo "(无 nvidia/nouveau 模块)"
  mokutil --sb-state
  echo
  echo "## 共享盘挂载与写测试"
  findmnt /mnt/shared /snapshots
  grep -nE 'nofail' /etc/fstab
  echo "写测试: $(touch /mnt/shared/.dbk-write-test 2>/dev/null && rm -f /mnt/shared/.dbk-write-test && echo 通过 || echo 失败)"
  echo
  echo "## XDG 重定向核对"
  for k in DESKTOP DOWNLOAD DOCUMENTS PICTURES MUSIC VIDEOS; do
    echo "XDG_${k}_DIR=$(xdg-user-dir "$k")"
  done
  echo
  echo "## timedatectl"
  timedatectl
  echo
  echo "## 蓝牙同步结论"
  bluetoothctl devices
  echo "bt-keys-sync 执行结果: <按上游输出如实记录>"
} > ~/04-first-boot.md
```

命令只读(写测试会创建并立即删除一个临时文件);`~/04-first-boot.md` 的内容取回 Windows 侧落盘。字段固定六项:会话类型、GPU 模块状态、共享盘挂载与写测试结果、XDG 重定向核对、`timedatectl` 输出、蓝牙同步结论——与 [baseline/README.md](../baseline/README.md) 的命名规范一致。

`baseline/04-robustness.md` 由步骤 6 的同名核对整理:快照可用性与回滚演练、journald 持久化、SSH 可达、更新策略、SMART 状态五项。两份产物都**不入库**(`baseline/*` 已被 `.gitignore` 排除,仅 [baseline/README.md](../baseline/README.md) 例外);跑完 L4 后把与[入口文档](00-overview.md)设备参数表的**偏差**回写进产物,这是"同规格设备"适配表迭代的唯一输入来源。

## 验证

逐项核对,全部通过 = L4 完成。命令在 Ubuntu 里执行;第 14 行的证据取自 `baseline/04-first-boot.md` 与 `baseline/04-robustness.md`。

| # | 检查项 | 命令 / 来源 | 期望 |
|---|---|---|---|
| 1 | 共享盘已挂载且可写 | `findmnt /mnt/shared` | 目标为 `/mnt/shared`,文件系统 `ntfs3`,选项含 `rw`、`windows_names`、`nofail` |
| 2 | L4 写入的三条 `fstab` 条目都带 `nofail` | `grep -c nofail /etc/fstab`、`findmnt --verify` | L4 写入的三条(共享盘、`/snapshots`、swapfile)都带 `nofail`,计数 `>= 3`;`findmnt --verify` 不报 error。`/boot/efi` 属必需挂载,**不加** `nofail` |
| 3 | 写测试通过且无残留 | `touch /mnt/shared/.dbk-write-test && rm -f /mnt/shared/.dbk-write-test`;`ls -a /mnt/shared` | 创建与删除都成功;共享盘根目录下无 `.dbk-write-test` 残留 |
| 4 | 双向可见性一致 | Windows 写 `D:\Shared\dbk-visibility.txt` -> Ubuntu 读 `/mnt/shared/Shared/dbk-visibility.txt`;反向再测一次 | 两次内容一致(设计 5.3 验收项);测完删除标记文件 |
| 5 | 文档类家目录已重定向 | `xdg-user-dir DOCUMENTS`(及其余五项) | 六项分别指向 `/mnt/shared/{Desktop,Documents,Downloads,Pictures,Videos,Music}` |
| 6 | 配置/凭据/代码仓库仍在本地 root | `ls -ld ~/.config ~/.ssh`;`findmnt /mnt/shared` 的挂载点下不存在这些目录 | `~/.config`、`~/.ssh` 位于 `/home/<用户名>/`;共享盘上没有它们的副本 |
| 7 | 会话为 Wayland | `echo $XDG_SESSION_TYPE`、`cat /proc/cmdline` | 输出 `wayland`;`/proc/cmdline` **不含** `nomodeset` |
| 8 | 显卡驱动状态明确 | `lsmod \| grep -E '^(nvidia\|nouveau)'`、`mokutil --sb-state` | 预签名 NVIDIA 模块已加载,**或**明确记录"回退 nouveau"的偏差;`SecureBoot enabled` |
| 9 | PRIME offload 可用(混合显卡) | `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B \| grep 'OpenGL renderer'` | 渲染器为 NVIDIA;单显卡设备跳过本行并注明 |
| 10 | 时间口径正确 | `timedatectl` | `RTC in local TZ: no`、`System clock synchronized: yes`;与 Windows 侧时间一致(偏差在分钟级内) |
| 11 | 蓝牙无需重配对 | `bluetoothctl devices`、实际连接一台已配对设备 | 两系统里都能直接连接;`bt-keys-sync` 以 Windows 侧密钥导入成功并记录结论 |
| 12 | 健壮性 R1-R9 就绪 | 见步骤 6 的判据列:`findmnt /snapshots`、`ls -d /var/log/journal`、`ss -tlnp \| grep :22`、`grep -A3 Package-Blacklist /etc/apt/apt.conf.d/*`、`systemctl is-active smartd`、`swapon --show`、`zramctl` | 快照分区可写且有至少一份快照;`/var/log/journal` 存在;22 端口在听;黑名单含 `linux-` 与 `nvidia-`;`smartd` active;swapfile 与 zram 生效 |
| 13 | 回 Windows 入口可用且 `BootOrder` 未变 | `sudo scripts/linux/reboot-to-windows.sh`(或 `BOOT_MENU_KEY`);`sudo efibootmgr` | 重启进入 Windows;`BootOrder` 首位仍是 `Windows Boot Manager`,`ubuntu` 仍在末尾;全程未执行 `efibootmgr -o` |
| 14 | 产物六项字段齐备 | `baseline/04-first-boot.md`(多设备时 `baseline/<别名>/`) | 含会话类型、GPU 模块状态、共享盘挂载与写测试、XDG 重定向核对、`timedatectl`、蓝牙同步结论六节,内容为本次实测 |
| 15 | 产物未入库 | `git status`(Windows 侧仓库) | `baseline/` 下变化一个都不出现([baseline/README.md](../baseline/README.md) 除外) |

15 项全部通过 = L4 完成,可进入 L5([docs/06-decommission.md](06-decommission.md) 与 [docs/07-rescue.md](07-rescue.md))。任一项不通过按"失败处理"解决后再推进;**第 1-4 行不通过时,共享盘上的数据不可信,先停下把 Windows 侧前提改对**。

## 失败处理

| 现象 | 立即动作 |
|---|---|
| `mount -a` 报 `unknown filesystem type 'ntfs3'` | 内核缺 `ntfs3` 模块:确认用的是 26.04 默认内核(7.0 起内置);`modinfo ntfs3` 应有输出。仍没有则回退到 `ntfs`(FUSE 版,只读更稳)并记录偏差,不要为此改分区表 |
| 挂载失败或写测试失败(`Permission denied` / `Read-only file system`) | 按顺序排查四条前提:Windows 侧 `powercfg /a` 与 `HiberbootEnabled`(Fast Startup 与休眠必须关闭)、`manage-bde -status D:`(保护必须 Off)。**若 D: 已加密:先回 Windows 关闭设备加密/解密后再继续**——dislocker 之类工具不在本方案内(设计 5.3 前提 2) |
| Windows 处于休眠/快速启动状态时挂上了共享盘 | 立即 `sudo umount /mnt/shared`,回 Windows 执行完整关机(`shutdown /s /t 0`,不是休眠,也不是"关机并重启"),再回 Ubuntu 重挂。风险表"Fast Startup + 双写 NTFS"行的数据损坏正出自这一状态 |
| `blkid -U` 找不到 UUID | 分区没接入或 UUID 抄错:`sudo blkid` 全量列出,与 `baseline/02-partitions.txt` 交叉核对;确认目标确实是 `D:`(≈635GiB 的 NTFS 分区),**不要**改成 C: 或 Linux 分区 |
| 该分区已被自动挂载到别处(`/media/<用户>/...`) | 桌面环境的自动挂载先卸载:`sudo umount /media/<用户>/<卷名>`,确认 `findmnt -rn -S UUID=<UUID>` 为空后再 `mount -a`;必要时在文件管理器里关掉该盘的自动挂载 |
| 写测试通过但某应用仍在写本地目录 | 该应用不读 XDG 目录或缓存了旧路径:注销重登一次再试;仍不认就在该应用内单独指定路径。**不要**为了它把 `~/.config` 挪到共享盘(共享盘清单之外) |
| `xdg-user-dirs-update` 报 `command not found` | `sudo apt install -y xdg-user-dirs` 后重跑 `xdg-redirect.sh --apply`;文件已写入不影响 `xdg-user-dir` 查询 |
| 重定向后 `xdg-user-dir DOCUMENTS` 仍指向本地 | 目标目录不存在或挂载未就绪:先 `findmnt /mnt/shared` 确认挂载,再重跑脚本;仍不对按步骤 2 的回退命令恢复,查清原因后重来 |
| 家目录相关应用报错、无法保存权限位 | 风险表"家目录重定向后的应用不兼容"行:按步骤 2 的回退命令把 `user-dirs.dirs` 还原到 `user-dirs.dirs.dbk.bak`,把该应用的工作目录留在本地 root,**不为此放弃整个共享盘方案** |
| `XDG_SESSION_TYPE` 仍是 `x11`,或会话起不来 | 先查 `cat /proc/cmdline` 是否残留 `nomodeset`(它关掉 KMS,与 Wayland 冲突):去掉后 `sudo update-grub` 重启;再查驱动是否加载、`mokutil --sb-state` 是否 `enabled`。`x11` 属偏差,记录进产物而不要当作完成 |
| 装完专有驱动黑屏/闪烁 | 切 TTY(`Ctrl + Alt + F3`)登录 → 卸载专有驱动回 nouveau(设计 4.5 回滚列)→ 重新评估驱动版本或内核;必要时 GRUB "Advanced options" 选旧内核启动(R3)。**不要反复长按电源强制重启**,用 REISUB(SysRq)安全重启 |
| 模块被签名拒绝(`key was rejected by key 0`、`lockdown`) | 回退 nouveau,确认走的是仓库预签名包(不是 DKMS);不注册自签 MOK、不关 Secure Boot(设计 3.3、第 9 节"Secure Boot 下 NVIDIA 模块签名"行) |
| 装完独显驱动后引导菜单阶段黑屏(键盘仍可用) | 决策 3.19:启用 `GRUB_TERMINAL=console` 后 `update-grub`;日常切换改用步骤 7 的一次性入口。**菜单黑屏不等于系统坏了**,不要重装(L3 手册同类条目的镜像) |
| 混合模式下点不亮、反复黑屏 | 走 MUX 分支(设计 3.17):固件切"独显直连"先拿到可用系统,记录显存/续航代价,再评估是否切回混合;切回前确认预签名驱动已装好。**不降级发行版** |
| 两系统时间仍差整时区 | 两边口径不统一:Linux 侧确认 `timedatectl` 为 `RTC in local TZ: no`;Windows 侧配 `RealTimeIsUniversal=1` 或反过来,二者只能选一种;改完各自重启核对一次 |
| 蓝牙仍要反复重配对 | 按步骤 5 的顺序重做:**先在 Linux 配对 -> 回 Windows 重新配对 -> 再回 Linux 以 `--windows-keys` 导入**;顺序错了就以 Windows 侧为准重来一遍。反向写 Windows 注册表不在本方案内 |
| 共享盘上文件"设备忙 / 目录非空" | 先在 Windows 侧关掉资源管理器预览、搜索索引、同步客户端,再回 Linux 操作(设计 5.3 风险与缓解表末行) |
| `first-boot-summary.txt` 里 `hardening` 记 `fail`,关键输出提到 `/snapshots` 未挂载 | 属预期(编排顺序是 hardening 先于 mount-shared):先按步骤 1.2 用 `--snapshot-uuid` 把快照分区写进 `fstab` 并挂载,再复跑 `sudo bash scripts/linux/hardening.sh --apply`,让 R1/R2 记为 `ok` |
| 快照创建失败或 `/snapshots` 将满 | 删除最旧的一份(默认保留 3 份)后重试;**快照失败即视为"不得执行本次变更"**(第 9 节"快照分区容量耗尽"行):先解决快照,再谈装驱动/换内核 |
| 内核/驱动更新后黑屏或不进桌面 | 走 R3 + R1:GRUB "Advanced options" 选旧内核启动 → 从 `/snapshots` 快照回滚;同时核对 `Package-Blacklist` 是否含 `linux-`、`nvidia-`(决策 3.18),避免复发 |
| 桌面挂死但系统仍在 | 走 R7/R5:从另一台机器 SSH 登录(`ss -tlnp \| grep :22` 先确认在听),或切 TTY 看 `journalctl -b -1 -p err`;不要在桌面无响应时长按电源 |
| 共享盘上的办公文件损坏或丢失 | 用第二份备份恢复(步骤 1.4 的最后一条);核对损坏是否发生在 Linux 侧批量移动/重命名之后,并把该动作从工作流里去掉(设计 5.3 风险表) |
| 想把共享盘降级为只读 | 这是[入口文档](00-overview.md)偏离表认可的分支:把 `fstab` 行的 `rw` 改为 `ro` 后 `sudo mount -o remount /mnt/shared`,`xdg-redirect.sh` 的目标目录改为本地 `$HOME` 下的同名目录;记录为偏差 |
| 发现自己执行过 `efibootmgr -o` | 违反 I2:立即把 `BootOrder` 首位改回 `Windows Boot Manager`(**只走固件设置界面**),把这次改动写进 L4 产物与偏差记录;此后任何分区表或固件变更前必须先重做 L2 基线(I4) |

## 回滚

### 1. 共享盘挂载回滚

改回只读:`sudo mount -o remount,ro /mnt/shared`(或把 `fstab` 行的 `rw` 改成 `ro`)。彻底移除:

```bash
sudo cp -a /etc/fstab.dbk.bak /etc/fstab && sudo systemctl daemon-reload && sudo mount -a
```

移除前先把写在共享盘上的东西搬回本地(或确认不再需要);`nofail` 保证了即使挂载行存在而分区缺失,系统也能正常启动(设计 4.5 回滚列)。

### 2. 家目录重定向回滚

```bash
cp -a ~/.config/user-dirs.dirs.dbk.bak ~/.config/user-dirs.dirs
sudo -u <用户名> xdg-user-dirs-update --force
xdg-user-dir DOCUMENTS
```

或删掉 `~/.config/user-dirs.dirs` 后以该用户执行 `xdg-user-dirs-update --force` 回到发行版默认。已 `mv` 到共享盘的旧文件按需搬回。回滚后共享盘仍可用,只是不再是家目录的一部分。

### 3. 显卡驱动与显示策略回滚

- 驱动:卸载专有驱动即回 **nouveau**(设计 4.5 回滚列;**黑屏时先切 TTY(Ctrl+Alt+F3)或用旧内核启动**)。**不要**执行 `sudo apt purge '^nvidia-.*' '^linux-modules-nvidia-.*'` 这种通配写法:apt 的正则会把 `nvidia-cuda-toolkit`、`nvidia-container-toolkit(-base)`、`nvidia-docker2`、`nvidia-settings` 等非驱动包一并摘掉,`-y` 又会抹掉确认。与 `graphics.sh` 一致的三步:
  1. 先列出将被删的项并人工过一眼:`dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | grep -E '^(ii|iU) +(nvidia|libnvidia|linux-modules-nvidia|linux-signatures-nvidia)'`(用 `dpkg-query -W` 而非 `dpkg -l`:后者在非 tty 下按 80 列截断包名);
  2. 按上面清单用**精确包名**逐个移除(不通配、不加 `-y`):`sudo apt-get remove --purge <逐个包名>`;
  3. `sudo apt-get autoremove` -> `sudo update-initramfs -u` -> `sudo reboot`;
  装了 CUDA/容器运行时的要单独评估(它们不会随 nouveau 一起回来);再确认 `/etc/modprobe.d/*nouveau*.conf` 里无 `blacklist` 残留、`/etc/default/grub` 里无残留的 `nomodeset` / `nvidia-drm.modeset=1`,改完 `sudo update-grub`。
- 显示模式:从"独显直连"切回"混合模式"只需改回固件设置——**切回前先确认预签名驱动已装好**,否则会回到"点不亮"的起点(设计 3.17);
- `GRUB_TERMINAL=console`:移除该行后 `sudo update-grub`;
- `nomodeset`:只应存在于应急场景;若还在内核行上,去掉后 `sudo update-grub`。

### 4. 时间与蓝牙回滚

- 时间:Linux 侧 `sudo timedatectl set-local-rtc 1`(迁就本地时间)可立刻回到改动前口径;Windows 侧删掉 `RealTimeIsUniversal` 值即回到默认。两种口径**只能选一种**,改完重启核对;
- 蓝牙:Linux 侧重配设备(`bluetoothctl remove <MAC>` → 重新 `pair`/`trust`)即可回到同步前状态;Windows 注册表在本方案里**从未被写入**,所以不存在"注册表被改坏"的复原问题(4.5 回滚列)。

### 5. 健壮性项回滚

- zram / swapfile:`sudo swapoff /swapfile && sudo rm /swapfile`,并移除 `/etc/fstab` 的 swapfile 行与 `/etc/systemd/zram-generator.conf`;两者都不动分区表(决策 3.8 的可调整性);
- journald 持久化:删除 `99-dbk-persistent.conf` 后 `sudo systemctl restart systemd-journald`(回到易失日志,代价是丢失崩溃后诊断能力);
- 更新策略:还原 `unattended-upgrades` 片段并 `sudo systemctl restart unattended-upgrades`;黑名单是刻意保留项,**不建议**回滚;
- SSH:`sudo systemctl disable --now ssh`(关闭救援通道,失去 R7 的能力);
- SMART:`sudo systemctl disable --now smartd`;
- 快照:删除 `/snapshots` 快照即回收空间,但**变更前快照是 R1 的落地手段**,没有快照点就不要执行内核/驱动变更。

### 6. 整段 L4 回滚

要把 Ubuntu 回到"L3 刚装完"的状态:**从 `/snapshots` 快照整体还原**(R1);没有快照点时,手工按上面 1-5 逐项回退,并保留一份"回退前状态"记录(便于判断是否还有残留)。L4 全程未改分区表与固件设置,因此**不需要**动 ESP 基线,也不需要 `bcdboot`——那是引导层(L3/L5)的手段;一旦发现 `\EFI\Microsoft\` 或 `BootOrder` 有异常,立刻停下按 [L3 手册](04-ubuntu.md) 的引导复原流程处理(基线回滚),不要在 L4 里顺手改引导。
