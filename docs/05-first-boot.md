# 05:L4 首启收敛(轨道 L/D)

本文件在流程中的位置:`04-silverblue`(轨道 L:L3 安装)-> **本文件(轨道 L:L4 首启收敛)** -> `07-rescue`(退役与救援)。

L4 是收敛与加固,不是再装一遍系统:本阶段不动分区表、不动固件设置、不改 `BootOrder`(不变量 I1-I4)。目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;依据见[设计文档](design/00-design.md) 4.5 节(L4)、4.7 节(R1-R9 健壮性)、3.16 与 5.3 节(共享盘)、7.1 节(巡检)与[变体设计](design/02-fedora-atomic-variant-design.md) 第 2 节(D1-D6)、第 3 节(NVIDIA 与 Secure Boot)、第 4 节(更新、升级与回滚)。

Fedora 44 Silverblue(原子版,GNOME 50)的三条硬事实贯穿全文:系统**按部署整体更新**——更新与分层安装都写进**下一部署、重启后才生效**,回滚的单位也是整个部署;桌面**只有 Wayland 会话**;**Secure Boot 全程开启**(显卡走 ublue 的 NVIDIA 预签名镜像 + 一次性 MOK 注册,不关 Secure Boot、不自签密钥)。`/home` 是 `/var/home` 的符号链接,**不属于部署**,回滚不丢用户数据。

## 开始前

- 前提:已能进 Silverblue 桌面(L3 收尾),`baseline/03-efi-layout.txt` 在位,`BootOrder` 首位仍是 Windows Boot Manager。
- 需要的东西:参数表 `SHARED_PART_UUID`(取值与 `baseline/02-partitions.txt` 交叉核对)、`BOOT_MENU_KEY`;救援介质保持"已验证可用"(显卡环节最容易进不去桌面)。
- 产物落点:`baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(多设备放 `baseline/<设备别名>/`,全部不入库)。
- 纪律:任何驱动、分层或发行版升级之前先备份 `baseline/` 与 `/etc` 关键文件(R1),并按 `05-9` 固定(pin)当前部署、记下部署号与驱动版本,再动系统;自动更新只**检查/下载**,不自动应用、不自动重启(设计 06 第 2 节 D5)。

### 05-1 挂载共享数据盘(`D:` 整块以 `ntfs3` 读写挂到 `/mnt/shared`)

做:先逐条核对四条前提(缺一不可),再用脚本把挂载行写进 `fstab`、挂载并做写测试(设计 5.3)。
  1. 前提一/二(Windows 侧已完成,见 `03-2`):已关快速启动与休眠;`D:` 未加密(`manage-bde -status D:` 为 `Protection Off`)
     看到:两项都成立;缺任一项时脚本的写测试必然失败(NTFS 脏卷 / 加密卷无法读写)
  2. 前提三:挂载选项固定 `rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime`(`ntfs3` 没有 POSIX 权限位,`windows_names` 阻止创建 Windows 非法文件名)
     看到:`templates/fstab.snippet` 的共享盘行选项齐备;核对脚本对缺项记 FAIL
  3. 先空跑再执行:`sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --check` -> 加 `--apply --yes`
     看到:空跑逐条列出 checks(首次执行时"fstab 尚未写入"判 FAIL 属预期);`--apply` 报 PASS,`findmnt /mnt/shared` 为 `ntfs3`、选项含 `rw`/`windows_names`/`nofail`,写测试创建并删除 `/mnt/shared/.dbk-write-test` 成功
  4. 前提四(设计 5.3):抄下"不要在共享盘上做的事"——不放 `~/.config`/`~/.ssh`/`~/.gnupg` 等配置与凭据目录;不放依赖符号链接、硬链接、可执行位或大小写敏感重命名的代码仓库;不放需要权限位或 setuid 语义的脚本与服务数据;不在 Linux 侧对共享盘做大目录批量重命名或移动;不按"最近下载"整目录清理(`D:\Downloads` 两边共用);共用目录里不放依赖后缀匹配的临时产物;关键目录在别处保留第二份备份
     看到:这份清单已抄进本机部署记录;清单里的东西一律留在本地 root
脚本:sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --check / --apply --yes
坑:`fstab` 行必须带 `nofail`(分区缺失或写坏时不阻断启动,设计 4.5);Windows 处于休眠或快速启动状态时绝不让 Linux 挂载共享盘。
出错时:读不到 UUID -> 与 `baseline/02-partitions.txt` 交叉核对后重跑,不要改成 `C:` 或 Linux 分区;写测试失败 -> 先查 `03-2` 与 `manage-bde -status D:`,不要反复重挂。

### 05-2 家目录数据重定向(只重定向文档类目录)

做:用 `~/.config/user-dirs.dirs` 把桌面/文档/下载/图片/视频/音乐六类指向共享盘,与 Windows 侧已知文件夹重定向逐项对齐(`03-3`);配置、凭据与代码仓库留在本地 root(设计 3.16)。
  1. 先空跑:`sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --check`
     看到:脚本报 PASS 或列出待写内容;零写;共享盘未挂载时脚本直接拒绝(先做 `05-1`)
  2. 执行:`sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --apply --yes`(`05-1` 的 `--apply` 正常路径下会自动调用它,不必重复手工跑)
     看到:脚本报 PASS;六项分别指向 `/mnt/shared/{Desktop,Documents,Downloads,Pictures,Videos,Music}`;原文件备份为 `user-dirs.dirs.dbk.bak`(**只在备份不存在时创建**,始终是改动前的内容)
  3. 回退(随时可逆):`cp -a ~/.config/user-dirs.dirs.dbk.bak ~/.config/user-dirs.dirs && sudo -u <用户名> xdg-user-dirs-update --force`
     看到:`xdg-user-dir DOCUMENTS` 回到 `/var/home/<用户名>/Documents`(原子版下 `~` 实际在 `/var/home`,`/home` 是它的符号链接;脚本用 `getent passwd` 解析家目录,不受符号链接影响)
脚本:sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --check / --apply --yes
坑:NTFS 没有 POSIX 权限语义,别把 `.ssh`、代码仓库或整个家目录搬过去;重定向只影响"新建文件落在哪",旧文件不会自动搬(设计 5.3)。
出错时:目标目录缺失 -> 先让 `05-1` 通过再重跑;某应用仍写本地 -> 注销重登一次,不要为它把 `~/.config` 挪到共享盘。

### 05-3 显卡与 Secure Boot(rebase 到 ublue NVIDIA 变体 + 一次性 MOK 注册)

做:把系统 `rebase` 到 ublue 的 **NVIDIA 变体**(镜像内 nvidia 模块**已预签名**),再重启进 MOK 界面做**一次性密钥注册**(设计 02 第 3 节 D2、设计 06 第 2 节 D3)。
  1. 先看现状:`sudo bash scripts/linux/graphics.sh --check`
     看到:四项判据(① `modinfo -F signer nvidia` 非空 ② `mokutil --list-enrolled` 含 ublue 密钥 ③ `lsmod` 有 `nvidia` ④ `XDG_SESSION_TYPE` 为 `wayland`);零写;未 rebase 或未重启的项记"需人工",不是失败
  2. 提交 rebase:`sudo bash scripts/linux/graphics.sh --apply --yes`,脚本调接口把系统 rebase 到 ublue 的 NVIDIA 镜像(**镜像名与分支实施时按 ublue 官方文档核实**),重启后生效
     看到:脚本报"已提交 rebase,需重启";重启后 `nvidia-smi` 有输出、`lsmod` 有 `nvidia`、`modinfo -F signer nvidia` 非空
  3. 一次性 MOK 注册(必须人工,接口不代跑):重启进 MOK 界面按提示完成注册(MOK 密码与任务名以 ublue 官方文档为准),也可在会话内跑 `ujust enroll-secure-boot-key` 后再重启一次;随后复跑 `--check` 四项
     看到:`mokutil --list-enrolled` 含 ublue 密钥;四项全过;注册只需做一次,不是每次更新都重来
  4. 会话与内核行校验:`echo "$XDG_SESSION_TYPE"` 为 `wayland`;`cat /proc/cmdline` 不含 `nomodeset`
     看到:两项都成立;`nomodeset` 会关掉 KMS,与默认 Wayland 会话冲突(设计 4.5、11.1)
  5. nouveau 兜底:桌面起不来时不要长按电源,按 `07-2` 从 GRUB 提示符回 Windows;能在 GRUB 菜单选上一部署就用旧部署启动,或按 `05-9` 回滚到 stock 部署(回滚后由 nouveau 起桌面)
     看到:系统仍可用;处置顺序是"选上一部署 / 回滚 -> rebase 回 stock 部署 -> 才考虑发行版问题"
脚本:sudo bash scripts/linux/graphics.sh --check / --apply --yes
坑:本步**不关 Secure Boot、不自签密钥** —— 模块签名由 ublue 镜像内预置,自签反而会破坏上游的预签名路径(设计 02 第 3 节 D2);镜像名、`ujust` 任务名与 MOK 密码均标待核实,以官方文档为准。
出错时:装完黑屏 -> 按 `10-1` 处置;驱动不认(`lsmod` 有 `nouveau`、无 `nvidia`)-> 按 `05-9` 回滚到上一部署,不要在这一步反复试。签名与 Secure Boot 状态细查见 `07-7` 的 `scripts/linux/check-signature.sh`。

### 05-4 时间(RTC 走 UTC)

做:核对硬件时钟按 UTC 记时并启用网络校时;Windows 侧如需要再配 `RealTimeIsUniversal=1`(设计 4.5)。
  1. 先空跑:`sudo bash scripts/linux/set-time.sh --check`
     看到:输出两项判据(RTC 基准与 NTP 状态);`timedatectl` 取不到时脚本记"需人工"而不是判失败
  2. 执行:`sudo bash scripts/linux/set-time.sh --apply`
     看到:脚本报 PASS(两项判据全部达成);`timedatectl` 显示 `RTC in local TZ: no`
  3. Windows 侧(可选,与 Linux 侧成对):管理员执行 `reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f`
     看到:Windows 重启后与 Linux 时间一致(偏差在分钟级);该值只在 Windows 里改,不要在 Linux 里挂载并写 Windows 注册表
脚本:sudo bash scripts/linux/set-time.sh --check / --apply
坑:只统一一侧会让另一侧漂移整时区 —— 两种口径只能选一种(`RTC in local TZ: no` 配 `RealTimeIsUniversal=1`,或反过来迁就本地时间);本脚本只改 RTC 基准与 NTP,不动时区。
出错时:读不到 `RTC in local TZ` 行 -> 人工跑 `timedatectl` 对照输出格式;NTP 起不来 -> 查网络与时间同步服务,不要手改系统时间。

### 05-5 蓝牙配对密钥同步(以 Windows 侧密钥为准)

做:用**分层安装**装 `chntpw` 读 Windows 注册表 hive,再用上游脚本把配对密钥导入 Linux(设计 4.5;上游 KeyofBlueS/bt-keys-sync,本仓库不内置其代码)。
  1. 只读挂上 Windows 系统分区(如 `sudo mount -o ro /dev/nvme0n1p3 /mnt/win`),再跑 `sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check --win-mnt /mnt/win`
     看到:三项前置的判定(chntpw 已装 / hive 可读 / 上游脚本已就位);未装 chntpw 时记"需人工",不是失败
  2. 执行:`sudo bash scripts/linux/bt-keys-sync-wrapper.sh --apply --yes --win-mnt /mnt/win`
     看到:脚本经 `dbk-pkg.sh` **分层安装** `chntpw`(原子版:写进下一部署,**必须重启后才生效**;脚本会显式提示),把上游脚本下到 `/opt/bt-keys-sync/` 后以 `--windows-keys` 运行
  3. 分层安装后**先重启一次**,再复跑 `--check`(与 `05-8` 的 `smartmontools` 合到同一次重启,少重启一轮)
     看到:重启后 `command -v chntpw` 有输出;没重启就复跑会记"需人工"(不是失败,但包还没进当前系统)
  4. 顺序(错了就得重来):先在 Linux 配对目标设备 -> 回 Windows 对同一设备再配对一次(让它成为权威来源)-> 回 Linux 以 `--windows-keys` 导入 -> 两系统各连一次复测
     看到:`bluetoothctl devices` 能看到该设备;两个系统都不再需要重新配对
脚本:sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check / --apply --yes --win-mnt /mnt/win
坑:**不做反向写 Windows 注册表** —— 上游建议的方向就是"以 Windows 侧密钥为准";hive 只需只读挂载,不要为了省事改成读写;分层安装**不重启不生效**,别把它当成立即装好。
出错时:读不到 hive -> 确认只读挂载路径后重跑,不要强写注册表;仍要反复重配对 -> 按第 4 步顺序重做。

### 05-6 交换空间(zram 核对 + 4GiB swapfile)

做:核对 zram 已启用(原子版自带 `zram-generator`,`zramctl` 有 `zram0` 即通过),并补一个 4GiB swapfile 与对应 `fstab` 行;不建 swap 分区、不做休眠(设计 00 4.7 节 R6、设计 06 第 4 节 storage.sh 行)。
  1. 先空跑:`sudo bash scripts/linux/storage.sh --check`
     看到:四项判定(swapfile 是否已启用 / `fstab` 是否有该行且带 `nofail` / `zramctl` 是否有 `zram0` / `/proc/cmdline` 是否无 `resume=`);零写
  2. 执行:`sudo bash scripts/linux/storage.sh --apply --yes`
     看到:脚本报 PASS(swapfile 已启用 + `fstab` 行齐备 + `zram0` 已建立 + 未配休眠);`swapon --show` 与 `zramctl` 各列一行
  3. 若 `zram0` 缺失:脚本**只核对、不装提供者**(原子版自带 zram),按 `templates/zram-generator.conf` 写 `/etc/systemd/zram-generator.conf` 后 `daemon-reload`,**重启后**再跑本卡复核
     看到:重启后 `zramctl` 列出 `zram0`;重启前该项记"需人工",不假报 PASS
脚本:sudo bash scripts/linux/storage.sh --check / --apply --yes
坑:swapfile 的 `fstab` 行必须带 `nofail`,否则分区缺失时会挡住启动;**不做休眠** —— 休眠需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车(设计 3.8)。
出错时:`zramctl` 无 `zram0` -> 先确认配置已写并重启,再重跑;`fallocate` 失败 -> 查 root 可用空间,不要改分区表。

### 05-7 日志与更新策略(journald 持久化;只检查/下载,不自动应用)

做:打开 journald 持久化,并把自动更新配成**只检查/下载、绝不自动应用与自动重启**——两件事各一个脚本,同属本卡(设计 00 4.7 节 R5 与 R8、设计 06 第 2 节 D5)。
  1. `sudo bash scripts/linux/set-journald.sh --check` -> `--apply`
     看到:配置片段含 `Storage=persistent`;`journalctl --disk-usage` 有输出;`systemctl is-active systemd-journald` 为 active
  2. `sudo bash scripts/linux/set-updates.sh --check` -> `--apply`
     看到:写入的 `rpm-ostreed` 片段(`templates/rpm-ostreed.snippet`)含 `AutomaticUpdatePolicy=check`,不含"自动应用/自动重启"的取值;`systemctl is-enabled rpm-ostreed-automatic.timer` 为 enabled
  3. 变更(升级/分层)前复核一次:`sudo bash scripts/linux/set-updates.sh --check`
     看到:三项判据全过;配置被改回自动应用时这里变 FAIL,按 `05-9` 固定当前部署后再处理
脚本:sudo bash scripts/linux/set-journald.sh --check / --apply;sudo bash scripts/linux/set-updates.sh --check / --apply
坑:自动应用与自动重启同"变更前先备份与留档"直接冲突;原子版没有"只装安全更新"这个粒度,别照搬 apt 口径 —— 语义就是"只检查/下载"(设计 06 第 2 节 D5);`/var` 不属于部署,日志不随回滚丢失(`journalctl -b -1` 可回看上一轮启动)。
出错时:journald 起不来 -> 看 `journalctl -u systemd-journald` 定位;定时器未 enabled -> 手工 enable 后重跑,不要改成自动应用。

### 05-8 SSH 救援通道与磁盘健康

做:启用 `sshd` 常开(桌面挂死时从另一台机器登录排障),并**分层安装** `smartmontools`、启用 `smartd`(设计 00 4.7 节 R7 与 R9)。
  1. 先空跑:`sudo bash scripts/linux/set-remote-health.sh --check`
     看到:两项判定(`sshd` 是否 active、各盘 `smartctl -H` 是否 PASSED/OK);未装 `smartctl` 时记"需人工"
  2. 执行:`sudo bash scripts/linux/set-remote-health.sh --apply`
     看到:脚本经 `dbk-pkg.sh` **分层安装** `smartmontools`(写进下一部署,**必须重启后才生效**;脚本会显式提示),并执行 `systemctl enable --now sshd smartd`
  3. 分层安装后**先重启一次**(与 `05-5` 的 `chntpw` 合到同一次重启),重启后再复跑 `--check`
     看到:脚本报 PASS(`sshd` active 且各盘 SMART 健康检查通过);`ss -tlnp | grep :22` 能看到 22 端口监听(附加证据,不作为失败项)
脚本:sudo bash scripts/linux/set-remote-health.sh --check / --apply
坑:**分层安装需重启后生效**:装了没重启时 `smartctl` 仍不可用(记"需人工",不是失败);`sshd`/`smartd` 的 enable 是即时的,与分层包不同。
出错时:无 `smartctl` -> 先确认分层已提交并重启(不要改用别的方式装包);健康行不是 PASSED/OK -> 立刻备份数据并按磁盘告警处置。

### 05-9 部署级回滚与变更前 pin(回滚单位是整个部署)

做:原子版的回滚粒度是**整个部署**:变更前先 `--pin` 固定当前部署(唯一的退回目标),出事时回滚到上一部署,重启后生效(设计 06 第 2 节 D4、设计 02 第 4 节)。
  1. 先看现状:`sudo bash scripts/linux/rollback-deploy.sh --check`
     看到:三项判据逐条给出结论——① 部署列表可读(人读 `Version:` 行与 `--json` 两侧都能解析且部署数一致);② **部署数 ≥ 2**(存在回滚候选,索引 1 = 上一部署);③ 待重启状态可判定。①③ 读不到或两侧不一致记"需人工";②不成立记 FAIL(先完成一次更新或分层安装再回来)
  2. 变更前固定:`sudo bash scripts/linux/rollback-deploy.sh --pin 0 --yes`(索引 0 = 当前启动,序号即读即用)
     看到:脚本报固定成功,`rpm-ostree status` 里当前部署带 `pinned` 标记 —— **pin 是变更前的保护动作,不作为"回滚可用"的判据**
  3. 回滚:`sudo bash scripts/linux/rollback-deploy.sh --apply --yes`,脚本调接口把上一部署排为下次启动并提示重启
     看到:脚本报"已排入下次启动";**重启前当前系统照常可用、也未被改动**(想反悔,重启前再跑一次本步)
  4. 用完后解除固定:`sudo bash scripts/linux/rollback-deploy.sh --unpin 0 --yes`
     看到:该部署的 `pinned` 标记消失;`/home` 是 `/var/home` 的符号链接,**不属于部署,回滚不丢用户数据**
脚本:sudo bash scripts/linux/rollback-deploy.sh --check / --apply --yes / --pin <索引> --yes / --unpin <索引> --yes
坑:**"回滚可用"的唯一判据是部署数 ≥ 2**,不是"已 pin";索引随重启与新部署变化,必须即读即用;回滚只是把上一部署排为下次启动,不立刻替换正在运行的系统。
出错时:部署列表读不到 -> 用 `sudo` 重跑或人工 `sudo rpm-ostree status` 核对;回滚后仍起不来 -> 在 GRUB 菜单选上一部署,或按 `07-1` 判层,不要直接重装。

### 05-10 发行版升级(约 13 个月一次:`rpm-ostree rebase`)

做:先备份留档并**固定当前部署**,再 rebase 到下一个发行版分支,重启后复核版本、会话与驱动(设计 02 第 4 节、设计 06 第 2 节 D1/D4)。
  1. 先看现状:`sudo bash scripts/linux/upgrade-release.sh --check`
     看到:五项判据(部署列表可读 / 当前部署已 `pin` / `baseline/` 在位于可备份 / 更新策略仍是"只检查/下载" / 已指定升级目标分支 `DBK_RELEASE_REF`);缺一项即 FAIL,先补齐再谈升级
  2. 执行:`DBK_RELEASE_REF='<远程:分支>' sudo bash scripts/linux/upgrade-release.sh --apply --yes`
     看到:脚本先把当前部署固定(pin),再把 `baseline/` 备份到 `<backup-dir>/<时间戳>-baseline/`、复核五条前置,然后提交 rebase 到目标分支并提示重启(分支号每 6 个月推进一次,实施时按 Fedora 官方公告取值)
  3. 重启后复核:`sudo bash scripts/linux/upgrade-release.sh --check` 与 `sudo bash scripts/linux/graphics.sh --check`
     看到:版本已更新;会话仍为 `wayland`;`nvidia-smi` 与 `modinfo -F signer nvidia` 正常(签名与 Secure Boot 状态细查见 `07-7` 的 `scripts/linux/check-signature.sh`);不满意则按 `05-9` 回滚到已固定的部署
脚本:sudo bash scripts/linux/upgrade-release.sh --check / --apply --yes
坑:**没固定当前部署、没留档就不要升级** —— 翻车后没有唯一的退回目标;升级 = rebase 到下一个发行版分支,不是包管理器的 dist-upgrade;升级不动 Windows 分区与启动顺序(I1-I4)。
出错时:当前部署未 pin 或 `baseline/` 缺失 -> 先补齐再升级;升级后起不来 -> 开机菜单选旧部署启动,或按 `07-1` 判层,不要直接重装。

### 05-11 回 Windows 的入口(一次性,不改启动顺序)

做:确认本机有一条"一键回 Windows"的路径,并且它是**一次性**的(不变量 I2);三条路径任一可用即可。
  1. Linux 侧先空跑再执行:`sudo bash scripts/linux/reboot-to-windows.sh --check` -> `sudo bash scripts/linux/reboot-to-windows.sh --apply`
     看到:空跑打印 `BootOrder` 与目标条目;执行后报 PASS(一次性启动项已设置且 `BootOrder` 未变),再手工 `sudo systemctl reboot`
  2. 厂商菜单键兜底:开机按参数表 `BOOT_MENU_KEY`,选 `Windows Boot Manager`
     看到:进入 Windows;这条路径零副作用,也是 L3 进 Linux 用的同一条
  3. Windows 侧等价入口:`scripts/windows/set-bootnext.ps1 -Apply -Yes`(用 `bcdedit /set {fwbootmgr} bootsequence {GUID}` 做一次性切换;缺 `-Yes` 会以用法错误 64 退出且零写)
     看到:脚本断言 `BootOrder` 首位仍是 Windows Boot Manager
脚本:sudo bash scripts/linux/reboot-to-windows.sh --check / --apply
坑:**任何改永久顺序的做法都破坏 I2**(`efibootmgr -o`、`displayorder`);一次性设置只生效一次,进 Linux 后要再回 Windows 必须重新设置。
出错时:读不到 `BootOrder` -> 用 `sudo` 重跑或人工 `sudo efibootmgr` 核对;找不到 Windows 条目 -> 引导层问题按 `07-rescue.md` 处置,不要手工改永久顺序。

### 05-12 落 L4 产物(两份基线文档)

做:采集本阶段实测证据,落成 `baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(命名契约见 [baseline/README.md](../baseline/README.md));多设备放 `baseline/<设备别名>/`。
  1. 先看:`bash scripts/linux/collect-l4.sh --check`
     看到:打印两份产物的全部节;此时零写(不创建文件,也不碰共享盘做写测试)
  2. 再落盘:`bash scripts/linux/collect-l4.sh --apply --out-dir baseline`
     看到:脚本报"L4 产物已落盘";第一份含发行版版本 / 会话类型 / **部署列表与 pin** / **显卡驱动来源与模块签名** / **Secure Boot 密钥(MOK)** / 共享盘写测试 / 待更新(自动更新定时器);第二份是 R1-R9 逐项现状与证据(含 **`/boot` 独立挂载**那一节;取不到的写"未取到")
  3. 带回 Windows 侧后核对:`git status`
     看到:`baseline/` 下的变化一个都不出现(仅 [baseline/README.md](../baseline/README.md) 入库)
脚本:bash scripts/linux/collect-l4.sh --check / --apply --out-dir baseline
坑:两份产物都不入库;漏掉部署列表、MOK 或 `/boot` 独立挂载会让后续复检缺证据。
出错时:读不到共享盘证据 -> 先让 `05-1` 通过再重跑;写不进 `baseline/` -> 核对目录权限与磁盘空间,不要改产物路径。

### 05-13 L4 汇总执行(可选:按顺序跑各模块并聚合结果)

做:用编排脚本按固定顺序一次跑完 L4 各模块——这是**批量便利路径**,单卡仍可独立执行;排障时优先单卡单跑(各脚本幂等)。
  1. 先空跑:`bash scripts/linux/first-boot.sh --uuid <SHARED_PART_UUID>`
     看到:逐模块打印将执行的动作与判据;缺省/`--check` 是 dry-run,不改系统;非 root 时日志落 `<TMPDIR>/dbk-<uid>/` 并打印警告
  2. 再执行:`sudo bash scripts/linux/first-boot.sh --apply --yes --uuid <SHARED_PART_UUID>`
     看到:模块顺序为 `storage -> hardening -> mount-shared -> graphics`;末尾写出 `/var/log/dbk/first-boot-summary.txt`(表头 `模块 | 状态 | 关键输出`,统计行含 `失败项: N;跳过项: M`)
  3. 看摘要而不是退出码:`cat /var/log/dbk/first-boot-summary.txt`
     看到:单模块失败不改变退出码(脚本恒为 0,只有用法/权限类错误才非 0),失败与跳过项在摘要里逐条列出;失败模块按对应卡单独重跑(`05-1` 至 `05-10`)
脚本:bash scripts/linux/first-boot.sh --uuid <SHARED_PART_UUID> / sudo bash scripts/linux/first-boot.sh --apply --yes --uuid <SHARED_PART_UUID>;bash scripts/linux/hardening.sh --check / sudo bash scripts/linux/hardening.sh --apply --yes
坑:退出码不能当判据(恒为 0);编排顺序是 `storage -> hardening -> mount-shared -> graphics`,其中 `hardening` 的 R1/R2 是**只读核对**(R2 的部署级回滚演练见 `05-9`);**本卡两个脚本都声明了 `# 破坏性:1`,`--apply` 缺 `--yes` 会退 64 且零写**(与其它破坏性脚本同口径)。
出错时:摘要未写出 -> 核对日志目录写权限后重跑;某模块 fail -> 按摘要的模块名看 `/var/log/dbk/<模块>.log` 定位,再单卡重跑。

L4 的整机验收见 [08-verification.md](08-verification.md) 的 A-F 六组(B 组与 F 组覆盖本阶段的共享盘与健壮性判据);逐项回退动作见 [checklists/rollback.md](../checklists/rollback.md)。
