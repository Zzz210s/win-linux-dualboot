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
     看到:空跑逐条列出 checks(首次执行时"fstab 尚未写入"判 FAIL 属预期);`--check` 用 `ntfs3` 的不带 `force` 的**读写探测**(挂到临时挂载点、成功即立刻卸载)判卷是否 dirty,探测失败记**需人工**并提示回 Windows 跑 `chkdsk /f`;`--apply` 报 PASS,`findmnt /mnt/shared` 为 `ntfs3`、选项含 `rw`/`windows_names`/`nofail`,写测试创建并删除 `/mnt/shared/.dbk-write-test` 成功
  4. 前提四(设计 5.3):抄下"不要在共享盘上做的事"——不放 `~/.config`/`~/.ssh`/`~/.gnupg` 等配置与凭据目录;不放依赖符号链接、硬链接、可执行位或大小写敏感重命名的代码仓库;不放需要权限位或 setuid 语义的脚本与服务数据;不在 Linux 侧对共享盘做大目录批量重命名或移动;不按"最近下载"整目录清理(`D:\Downloads` 两边共用);共用目录里不放依赖后缀匹配的临时产物;关键目录在别处保留第二份备份
     看到:这份清单已抄进本机部署记录;清单里的东西一律留在本地 root
脚本:sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --check / --apply --yes
坑:`fstab` 行必须带 `nofail`(分区缺失或写坏时不阻断启动,设计 4.5);Windows 处于休眠或快速启动状态时绝不让 Linux 挂载共享盘;卷 dirty(未在 Windows 跑 `chkdsk /f`)时**不要强挂**,`force` 会绕过探测把卷写坏。
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
     看到:四项判据(① `modinfo -F signer nvidia` 非空 ② `mokutil --list-enrolled` 含 ublue 密钥 ③ `lsmod` 有 `nvidia` ④ `XDG_SESSION_TYPE` 为 `wayland`);零写;未 rebase / 未重启 / 未注册 MOK 的 ①②③ 在 `--check` 下记 **FAIL**(退出 1),④不符也记 FAIL;只有 ①②③ 读不到时(接口返 2)才记"需人工"
  2. 提交 rebase:`sudo bash scripts/linux/graphics.sh --apply --yes`(镜像形态已核实 `ghcr.io/ublue-os/bluefin-nvidia:<stream>`,streams = `stable` / `latest` / `testing`(+ `beta`);`stable-daily` 已被上游移除)。**脚本在 rebase 前先做版本一致性前置断言**(`driver_release_guard`):本机 Fedora 主版本(读 `/etc/os-release` 的 `VERSION_ID`)必须等于你**按 ublue 官方文档核对后声明的目标版本** —— **不写死 stream ↔ 版本的映射**(stream 集合与对应版本会随版本演进变),先查文档再声明:`sudo DBK_UBLUE_FEDORA=44 bash scripts/linux/graphics.sh --apply --yes`;不一致或未声明 → 退出码 2 需人工且**不发出 rebase**;确实要跨版本时才显式给 `DBK_ALLOW_CROSS_RELEASE=1`,重启后生效
     看到:断言通过时报 PASS"已 rebase 到 ublue 的 NVIDIA 变体:需重启"(未通过则报"版本一致性前置断言未通过"且 `rpm-ostree rebase` 一次都没发),并提示重启后在 MOK 界面完成注册;重启后 `nvidia-smi` 有输出、`lsmod` 有 `nvidia`、`modinfo -F signer nvidia` 非空
  3. 一次性 MOK 注册(必须人工,接口不代跑):重启进 MOK 界面按提示完成注册(已核实:任务 `ujust enroll-secure-boot-key`、密码 `universalblue`、待导入密钥 `/etc/pki/akmods/certs/akmods-ublue.der`;若 Secure Boot 已开启,ublue/Bazzite 文档建议先关再注册、注册后重开),也可在会话内跑 `ujust enroll-secure-boot-key` 后再重启一次;随后复跑 `--check` 四项
     看到:`mokutil --list-enrolled` 含 ublue 密钥;四项全过;注册只需做一次,不是每次更新都重来
  4. 会话与内核行校验:`echo "$XDG_SESSION_TYPE"` 为 `wayland`;`cat /proc/cmdline` 不含 `nomodeset`
     看到:两项都成立;`nomodeset` 会关掉 KMS,与默认 Wayland 会话冲突(设计 4.5、11.1)
  5. nouveau 兜底:桌面起不来时不要长按电源,按 `07-2` 从 GRUB 提示符回 Windows;能在 GRUB 菜单选上一部署就用旧部署启动,或按 `05-9` 回滚到 stock 部署(回滚后由 nouveau 起桌面)
     看到:系统仍可用;处置顺序是"选上一部署 / 回滚 -> rebase 回 stock 部署 -> 才考虑发行版问题"
脚本:sudo bash scripts/linux/graphics.sh --check / --apply --yes
坑:本步**不关 Secure Boot、不自签密钥** —— 模块签名由 ublue 镜像内预置,自签反而会破坏上游的预签名路径(设计 02 第 3 节 D2);Turing(RTX 2000 / GTX 16xx)及以后的显卡应走 `-nvidia-open` 变体(老 proprietary 镜像自 Aurora 43 起停建),镜像名按参考设备的显卡型号在 ublue 发布页复核;**本步只判"签名者非空 + ublue 密钥已注册 + nvidia 已加载"三项,不判镜像来源与 Secure Boot 链整体**,那两项由 `07-7` 的巡检承担;镜像名、`ujust` 任务名与 MOK 密码已于 2026-09-27 核实(见本卡第 2/3 步;上游端口或分支改名时以 ublue 发布页为准)。**stream ↔ Fedora 版本的对应关系随版本演进,以 ublue 官方文档为准**:不要凭记忆或旧笔记填 `DBK_UBLUE_FEDORA`,也不要在没核对的情况下用 `DBK_ALLOW_CROSS_RELEASE=1` 跨版本(跨版本 rebase 会换掉整个发行版基线)。
出错时:版本一致性前置断言未过(退出码 2)-> 按接口输出核对本机版本与所选 stream 的目标版本后重跑;确实要跨版本才给 `DBK_ALLOW_CROSS_RELEASE=1`。装完黑屏 -> 按 `10-1` 处置(显卡驱动专项见 `10-21`);驱动不认(`lsmod` 有 `nouveau`、无 `nvidia`)-> 按 `05-9` 回滚到上一部署,不要在这一步反复试。签名与 Secure Boot 状态细查见 `07-7` 的 `scripts/linux/check-signature.sh`。

### 05-4 时间(RTC 走 UTC)

做:核对硬件时钟按 UTC 记时并启用网络校时;Windows 侧如需要再配 `RealTimeIsUniversal=1`(设计 4.5)。
  1. 先空跑:`sudo bash scripts/linux/set-time.sh --check`
     看到:输出两项判据(RTC 基准与 NTP 状态);`timedatectl` 取不到时脚本记"需人工"而不是判失败
  2. 执行:`sudo bash scripts/linux/set-time.sh --apply --yes`
     看到:脚本报 PASS(两项判据全部达成);`timedatectl` 显示 `RTC in local TZ: no`
  3. Windows 侧(可选,与 Linux 侧成对):管理员执行 `reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f`
     看到:Windows 重启后与 Linux 时间一致(偏差在分钟级);该值只在 Windows 里改,不要在 Linux 里挂载并写 Windows 注册表
脚本:sudo bash scripts/linux/set-time.sh --check / --apply --yes
坑:只统一一侧会让另一侧漂移整时区 —— 两种口径只能选一种(`RTC in local TZ: no` 配 `RealTimeIsUniversal=1`,或反过来迁就本地时间);本脚本只改 RTC 基准与 NTP,不动时区。
出错时:读不到 `RTC in local TZ` 行 -> 人工跑 `timedatectl` 对照输出格式;NTP 起不来 -> 查网络与时间同步服务,不要手改系统时间。

### 05-5 蓝牙配对密钥同步(以 Windows 侧密钥为准)

做:用**分层安装**装 `chntpw` 读 Windows 注册表 hive,再用上游脚本把配对密钥导入 Linux(设计 4.5;上游 KeyofBlueS/bt-keys-sync,本仓库不内置其代码)。
  1. 只读挂上 Windows 系统分区(如 `sudo mount -o ro /dev/nvme0n1p3 /mnt/win`),再跑 `sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check --win-mnt /mnt/win`
     看到:三项前置的判定(chntpw 已装 / hive 可读 / 上游脚本已就位);三项任一未就绪都记 **FAIL**(退出 1);只有 `DBK_SKIP_PKG=1` 跳过分层安装时,"chntpw 是否已装"才记"需人工"
  2. 执行:`sudo bash scripts/linux/bt-keys-sync-wrapper.sh --apply --yes --win-mnt /mnt/win`
     看到:脚本经 `dbk-pkg.sh` **分层安装** `chntpw`(原子版:写进下一部署,**必须重启后才生效**;脚本会显式提示),把上游脚本下到 `/opt/bt-keys-sync/` 后以 `--windows-keys` 运行
  3. 分层安装后**先不要重启**:接着做 `05-8` 的 `smartmontools` 分层安装,两者合到同一次重启,重启后再复跑 `--check`
     看到:重启后 `command -v chntpw` 有输出;分层已提交但未重启时,`--check` 走 `pkg_installed`(认已提交的分层)不记"需人工",只有 `--apply` 会报"已提交,需重启"(不是失败,但包还没进当前系统)
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
     看到:重启后 `zramctl` 列出 `zram0`;重启前"有 `zramctl` 但无 `zram0`"记 **FAIL**(硬前置),只有连 `zramctl` 都取不到时才记"需人工";有失败项时汇总就是 FAIL(`ISSUES` 优先于需人工项)
脚本:sudo bash scripts/linux/storage.sh --check / --apply --yes
坑:swapfile 的 `fstab` 行必须带 `nofail`,否则分区缺失时会挡住启动;**不做休眠** —— 休眠需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车(设计 3.8)。
出错时:`zramctl` 无 `zram0` -> 先确认配置已写并重启,再重跑;`fallocate` 失败 -> 查 root 可用空间,不要改分区表。

### 05-7 日志与更新策略(journald 持久化;只检查/下载,不自动应用)

做:打开 journald 持久化,并把自动更新配成**只检查/下载、绝不自动应用与自动重启**——两件事各一个脚本,同属本卡(设计 00 4.7 节 R5 与 R8、设计 06 第 2 节 D5)。
  1. `sudo bash scripts/linux/set-journald.sh --check` -> `--apply --yes`
     看到:配置片段含 `Storage=persistent`;`journalctl --disk-usage` 有输出;`systemctl is-active systemd-journald` 为 active
  2. `sudo bash scripts/linux/set-updates.sh --check` -> `--apply --yes`
     看到:写入的 `rpm-ostreed` 片段(`templates/rpm-ostreed.snippet`)含 `AutomaticUpdatePolicy=check`,不含"自动应用/自动重启"的取值;`systemctl is-enabled rpm-ostreed-automatic.timer` 为 enabled
  3. 变更(升级/分层)前复核一次:`sudo bash scripts/linux/set-updates.sh --check`
     看到:三项判据全过;配置被改回自动应用时这里变 FAIL,按 `05-9` 固定当前部署后再处理
  4. **重启前先跑** `sudo bash scripts/linux/check-bootloader.sh --check`
     看到:引导器更新后 `/boot/loader/grub.cfg` 必须在位、BLS 条目不得为 0;否则**不要重启**,先走 `07-2` / `07-6`(上游出过 `bootupctl update` 后 grub.cfg 丢失 -> 掉进 `grub>` 的形态)
脚本:sudo bash scripts/linux/set-journald.sh --check / --apply --yes;sudo bash scripts/linux/set-updates.sh --check / --apply --yes;sudo bash scripts/linux/check-bootloader.sh --check
坑:自动应用与自动重启同"变更前先备份与留档"直接冲突;原子版没有"只装安全更新"这个粒度,别照搬 Ubuntu 的包粒度口径 —— 语义就是"只检查/下载"(设计 06 第 2 节 D5);`/var` 不属于部署,日志不随回滚丢失(`journalctl -b -1` 可回看上一轮启动)。
出错时:journald 起不来 -> 看 `journalctl -u systemd-journald` 定位;定时器未 enabled -> 手工 enable 后重跑,不要改成自动应用。

### 05-8 SSH 救援通道与磁盘健康

做:启用 `sshd` 常开(桌面挂死时从另一台机器登录排障),并**分层安装** `smartmontools`、启用 `smartd`(设计 00 4.7 节 R7 与 R9)。
  1. 先空跑:`sudo bash scripts/linux/set-remote-health.sh --check`
     看到:两项判定(`sshd` 是否 active、各盘 `smartctl -H` 是否 PASSED/OK);未装 `smartctl` 时记"需人工"
  2. 执行:`sudo bash scripts/linux/set-remote-health.sh --apply --yes`
     看到:脚本经 `dbk-pkg.sh` **分层安装** `smartmontools`(写进下一部署,**必须重启后才生效**;脚本会显式提示),并执行 `systemctl enable --now sshd smartd`
  3. 分层安装后**重启一次**(`05-5` 的 `chntpw` 已并入这一轮,不要在两卡之间各重启一次),重启后再复跑 `--check`
     看到:脚本报 PASS(`sshd` active 且各盘 SMART 健康检查通过);`ss -tlnp | grep :22` 能看到 22 端口监听(附加证据,不作为失败项)
脚本:sudo bash scripts/linux/set-remote-health.sh --check / --apply --yes
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
  5. 清理候选先看后做:`sudo bash scripts/linux/rollback-deploy.sh --check --prune` 报告会删掉哪些 pending 与 rollback 部署,确认后再 `sudo bash scripts/linux/rollback-deploy.sh --apply --prune --yes`
     看到:`--check --prune` 列出候选且零写;`--apply --prune --yes` **被 `pin` 的部署绝不删**,只删未被固定的 pending / rollback 部署
  6. 启动失败自动回滚:先 `sudo bash scripts/linux/setup-greenboot.sh --check`,再 `sudo bash scripts/linux/setup-greenboot.sh --apply --yes` 写健康检查(不自动装 `greenboot`,除非显式 `--install-greenboot`)
     看到:`--check` 报 `greenboot` 是否预装与 `/etc/greenboot/check/required.d/60-dbk-health.sh` 是否与模板逐字一致;健康检查失败时 greenboot 自动退回上一部署
  7. 回滚前后对比 `/etc`:`ostree admin config-diff`
     看到:回滚前后各跑一次并记下漂移条数 —— **回滚不回退 `/etc`**,漂移要人工处置
脚本:sudo bash scripts/linux/rollback-deploy.sh --check / --apply --yes / --pin <索引> --yes / --unpin <索引> --yes / --check --prune / --apply --prune --yes;sudo bash scripts/linux/setup-greenboot.sh --check / --apply --yes
坑:**"回滚可用"的唯一判据是部署数 ≥ 2**,不是"已 pin";索引随重启与新部署变化,必须即读即用;回滚只是把上一部署排为下次启动,不立刻替换正在运行的系统。
出错时:部署列表读不到 -> 用 `sudo` 重跑或人工 `sudo rpm-ostree status` 核对;回滚后仍起不来 -> 在 GRUB 菜单选上一部署,或按 `07-1` 判层,不要直接重装。

### 05-10 发行版升级(约 13 个月一次:`rpm-ostree rebase`)

做:先备份留档并**固定当前部署**,再 rebase 到下一个发行版分支,重启后复核版本、会话与驱动(设计 02 第 4 节、设计 06 第 2 节 D1/D4)。
  1. 先看现状:`sudo bash scripts/linux/upgrade-release.sh --check`
     看到:五项判据(部署列表可读 / 当前部署已 `pin` / `baseline/` 在位、可备份 / 更新策略仍是"只检查/下载" / 已指定升级目标分支 `DBK_RELEASE_REF`);当前部署未 pin 或更新策略不符判 FAIL;部署列表读不到、`baseline/` 缺失与未给 `DBK_RELEASE_REF` 记"需人工"(退出 2),先补齐再谈升级
  2. 执行:`DBK_RELEASE_REF='<远程:分支>' sudo bash scripts/linux/upgrade-release.sh --apply --yes`
     看到:脚本先把当前部署固定(pin),再复核五条前置(任一未达成即不执行),然后把 `baseline/` 备份到 `<backup-dir>/<时间戳>-baseline/`,最后提交 rebase 到目标分支并提示重启(分支号每 6 个月推进一次,实施时按 Fedora 官方公告取值)
  3. **重启前先跑** `sudo bash scripts/linux/check-bootloader.sh --check`
     看到:引导器更新后 `/boot/loader/grub.cfg` 必须在位、BLS 条目不得为 0;否则**不要重启**,先走 `07-2` / `07-6`
  4. 重启后复核:`sudo bash scripts/linux/upgrade-release.sh --check` 与 `sudo bash scripts/linux/graphics.sh --check`
     看到:版本已更新;会话仍为 `wayland`;`nvidia-smi` 与 `modinfo -F signer nvidia` 正常(签名与 Secure Boot 状态细查见 `07-7` 的 `scripts/linux/check-signature.sh`);不满意则按 `05-9` 回滚到已固定的部署
脚本:sudo bash scripts/linux/upgrade-release.sh --check / --apply --yes;sudo bash scripts/linux/check-bootloader.sh --check
坑:**没固定当前部署、没留档就不要升级** —— 翻车后没有唯一的退回目标;升级 = rebase 到下一个发行版分支,不是包管理器的 dist-upgrade;升级不动 Windows 分区与启动顺序(I1-I4)。
出错时:当前部署未 pin 或 `baseline/` 缺失 -> 先补齐再升级;升级后起不来 -> 开机菜单选旧部署启动,或按 `07-1` 判层,不要直接重装。

### 05-11 回 Windows 的入口(一次性,不改启动顺序)

做:确认本机有一条"一键回 Windows"的路径,并且它是**一次性**的(不变量 I2);三条路径任一可用即可。
  1. Linux 侧先空跑再执行:`sudo bash scripts/linux/reboot-to-windows.sh --check` -> `sudo bash scripts/linux/reboot-to-windows.sh --apply --yes`
     看到:空跑打印 `BootOrder` 与目标条目;执行后报 PASS(一次性启动项已设置且 `BootOrder` 未变),再手工 `sudo systemctl reboot`
  2. 厂商菜单键兜底:开机按参数表 `BOOT_MENU_KEY`,选 `Windows Boot Manager`
     看到:进入 Windows;这条路径零副作用,也是 L3 进 Linux 用的同一条
  3. Windows 侧等价入口:`scripts/windows/set-bootnext.ps1 -Apply -Yes`(用 `bcdedit /set {fwbootmgr} bootsequence {GUID}` 做一次性切换;缺 `-Yes` 会以用法错误 64 退出且零写)
     看到:脚本断言 `BootOrder` 首位仍是 Windows Boot Manager
脚本:sudo bash scripts/linux/reboot-to-windows.sh --check / --apply --yes
坑:**任何改永久顺序的做法都破坏 I2**(`efibootmgr -o`、`displayorder`);一次性设置只生效一次,进 Linux 后要再回 Windows 必须重新设置;**本脚本声明了 `# 破坏性:1`——写固件一次性启动项算破坏性写,`--apply` 缺 `--yes` 会退 64 且零写**(与 Windows 侧 `set-bootnext.ps1 -Apply -Yes` 同口径)。
出错时:读不到 `BootOrder` -> 用 `sudo` 重跑或人工 `sudo efibootmgr` 核对;找不到 Windows 条目 -> 引导层问题按 `07-rescue.md` 处置,不要手工改永久顺序。

### 05-12 落 L4 产物(两份基线文档)

做:采集本阶段实测证据,落成 `baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(命名契约见 [baseline/README.md](../baseline/README.md));多设备放 `baseline/<设备别名>/`。
  1. 先看:`bash scripts/linux/collect-l4.sh --check`
     看到:打印两份产物的全部节;此时零写(不创建文件,也不碰共享盘做写测试)
  2. 再落盘:`bash scripts/linux/collect-l4.sh --apply --out-dir baseline`
     看到:脚本报"L4 产物已落盘";第一份含发行版版本 / 会话类型 / **部署列表与 pin** / **显卡驱动来源与模块签名** / **Secure Boot 密钥(MOK)** / 共享盘写测试 / 待更新(自动更新定时器)/ **`/boot` 独立挂载**那一节;第二份是 R1-R9 逐项现状与证据(取不到的写"未取到")
  3. 带回 Windows 侧后核对:`git status`
     看到:`baseline/` 下的变化一个都不出现(仅 [baseline/README.md](../baseline/README.md) 入库)
脚本:bash scripts/linux/collect-l4.sh --check / --apply --out-dir baseline
坑:两份产物都不入库;第一份里漏掉部署列表、MOK 或 `/boot` 独立挂载会让后续复检缺证据。
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

### 05-14 交互层(交互 shell 用 fish;脚本解释器仍是 bash)

做:交互 shell 换成 `fish`(走 ublue 自带的 **Homebrew** 通道,不用 `rpm-ostree install` 分层——分层会拖慢每次更新),同时**显式保持脚本解释器仍是 bash**(shebang 与 `/bin/sh` 一律不动)。
  1. 先空跑:`sudo bash scripts/linux/set-interactive.sh --check`
     看到:五项判定(brew 可用 / fish 在位 / 该用户登录 shell 已是 fish / `/etc/shells` 含 fish 路径 / `/bin/sh` 未被换成 fish);零写
  2. 装 fish(可选,也可手工 `brew install fish`):`sudo bash scripts/linux/set-interactive.sh --apply --install-fish --yes`
     看到:`brew install fish` 经 `dbk-brew.sh` 执行;brew 不可用时记**需人工**并给出通道说明(脚本不自动装 brew)
  3. 应用登录 shell:`sudo bash scripts/linux/set-interactive.sh --apply --yes`
     看到:备份 `/etc/shells`(`.dbk.bak`,仅首次)-> 追加 fish 路径 -> `chsh -s <fish> <user>` -> 复读五项;幂等(已是目标状态时不写)
  4. 复核:重开一个终端
     看到:`echo $SHELL` 指向 fish、`fish -c 'echo ok'` 输出 `ok`;再跑任一 `scripts/linux/*.sh` 仍由 bash 解释
脚本:sudo bash scripts/linux/set-interactive.sh --check / --apply --yes [--install-fish]
坑:fish 只能当**交互** shell —— 步骤脚本必须继续 `#!/usr/bin/env bash`(门禁会扫 shebang);`chsh` 只认 `/etc/shells` 里的路径,所以"追加"与"chsh"必须同一次执行;改 `/etc/shells` 前必须留备份(改坏会让所有用户登录失败)。
出错时:`chsh` 报 shell 不在 `/etc/shells` -> 确认追加成功再重跑;fish 不在 PATH -> 用 `--fish <绝对路径>` 指定(brew 缺省 `/home/linuxbrew/.linuxbrew/bin/fish`)。

### 05-15 默认应用绑定(按清单逐项核对 xdg-mime)

做:按 `templates/mimeapps.tsv`(文件管理器 / PDF / 图片 / 压缩包 / 文本)把默认应用钉死,省掉每次"打开方式"的手动选择。
  1. 先空跑:`sudo bash scripts/linux/set-default-apps.sh --check`
     看到:逐行打印 `mime -> 期望 desktop -> 当前值`;一致 = PASS;应用未安装(desktop 文件缺失)= **需人工**(先去 `05-17` 装),绑定与清单不符 = FAIL;零写
  2. 执行:`sudo bash scripts/linux/set-default-apps.sh --apply --yes`
     看到:备份 `~/.config/mimeapps.list`(`.dbk.bak`,仅首次)-> 逐行 `xdg-mime default <desktop> <mime>` -> 复读全绿
  3. 抽验:`xdg-mime query default application/pdf`
     看到:输出与清单一致;想换 okular / gwenview / Ark / kate 时改**清单**的说明列并重跑,不要手改 `mimeapps.list`
脚本:sudo bash scripts/linux/set-default-apps.sh --check / --apply --yes
坑:清单是唯一真源(`templates/mimeapps.tsv`);`xdg-mime` 必须按目标用户上下文跑(`sudo -u` + `--user`),否则写成 root 的 `~/.config` 而脚本仍可能报 PASS。
出错时:绑不上 -> 先确认该 `.desktop` 在 `/usr/share/applications` 或 `~/.local/share/applications`;查询为空 -> 该 mime 没注册任何应用,去 `05-17` 补装。

### 05-16 虚拟桌面工作流(工作区与核心快捷键)

做:按 `templates/workflow.tsv` 用 `gsettings` 固定虚拟桌面工作流(工作区数量、关掉动态工作区、前两个工作区的直达快捷键);**不换合成器**(niri / KDE 列为非目标)。
  1. 先空跑:`sudo bash scripts/linux/set-workflow.sh --check`
     看到:逐行打印 `schema key = 当前值(期望值)`;一致 = PASS,不符 = FAIL,schema/key 不存在或 `gsettings` 取不到 = **需人工**;零写
  2. 执行:`sudo bash scripts/linux/set-workflow.sh --apply --yes`
     看到:先 `dconf dump /org/gnome/` 备份到 `~/.config/dbk/workflow.dbk.bak`(仅首次)-> 逐行 `gsettings set` -> 复读全绿;幂等
  3. 复核:按 `Super+1` / `Super+2` 切工作区
     看到:直接跳到第 1/2 个工作区;`gsettings get org.gnome.desktop.wm.preferences num-workspaces` 与清单一致
脚本:sudo bash scripts/linux/set-workflow.sh --check / --apply --yes
坑:改 `gsettings` 要按目标用户跑(`sudo -u` + 该用户的 dbus 会话),root 改的是 root 自己的配置;`dynamic-workspaces` 为 true 时工作区数量由窗口数决定,清单里必须把它与 `num-workspaces` 一起钉住。
出错时:`gsettings set` 报 schema 不存在 -> 该 GNOME 版本没有这个键,**改清单去掉这行**而不是硬塞;改坏了用备份回灌:`dconf load /org/gnome/ < ~/.config/dbk/workflow.dbk.bak`。

### 05-17 应用清单与替代映射(必需项在位;Windows 独占怎么分流)

做:按 `templates/apps.tsv` 核对必需应用在位,并按通道分流:原生 / Flatpak / Homebrew / **网页版** / **回 Windows**(非 3D 的 Windows 独占才考虑轻量 VM)。
  1. 先空跑:`bash scripts/linux/check-apps.sh --check`
     看到:逐行打印 `名称(通道) -> 在位/缺失`;必需项缺失 = FAIL,可选项缺失只记一行;`flatpak`/`brew` 取不到 = **需人工**;零写(本脚本 `--apply` 与 `--check` 相同,不装任何东西)
  2. 缺东西时按通道装:`flatpak install flathub <id>` / `brew install <公式>`(脚本不代装,避免把"装哪个"变成隐式决定)
     看到:重跑 `--check` 由 FAIL 转 PASS,新装项出现在 `flatpak list` / `brew list` 里
  3. **明确否掉 VFIO / 显卡直通**(设计 02 决策表):单张 NVIDIA 卡、双系统已有原生 Windows、一份 LTSC 授权不能两处同时用;需要 Windows 专属软件时按清单里的 `win` 通道重启回 Windows
     看到:`templates/apps.tsv` 里每个常用 Windows 软件都有归属(原生 / Flatpak / 网页 / 回 Windows),没有"待定"项
脚本:bash scripts/linux/check-apps.sh --check(只读;`--apply` 同)
坑:清单是唯一真源;`web`/`win` 通道**不算缺失**(浏览器或重启回 Windows 即满足),别写成必需项;Flatpak 要写 application id(`org.gnome.Loupe`),不是显示名。
出错时:flatpak 报 remote 不存在 -> 先手工 `flatpak remote-add --if-not-exists flathub ...`(脚本不代做);brew 公式名不对 -> `brew search <关键词>` 后回填清单。

### 05-18 配置快照与复原(重装后一条命令回到当前配置)

做:把"能被快照带走"的配置落成五份文本快照,重装或换机后按快照复原;除 `dconf` 外还含 `/etc` 漂移、Flatpak 清单、Homebrew 清单与分层包。
  1. 先空跑:`bash scripts/linux/export-config.sh --check`
     看到:现场重新生成五份快照并与 `baseline/config/` 逐文件比对;快照缺失 = **需人工**(先做第 2 步),有漂移 = **需人工**并打印差异前几行,无差异 = PASS;零写
  2. 落快照:`sudo bash scripts/linux/export-config.sh --apply --yes`
     看到:写出 `baseline/config/{dconf.txt,etc-config-diff.txt,flatpak-apps.txt,brew-bundle.txt,layered-pkgs.txt}` 与 `manifest.txt`(时间戳 + 各文件 sha256);复读为 PASS
  3. 复原(重装或新机后跑):`sudo bash scripts/linux/import-config.sh --apply --yes`
     看到:先把现状另存到 `baseline/config/pre-import-<时间戳>/` -> 逐项复原(dconf 回灌、Flatpak 按清单补装、Homebrew 走 `brew bundle`)-> **分层包不自动装**(打印命令并记需人工)-> 末尾自检:重新 dump 与快照比对,不等即 FAIL
脚本:bash scripts/linux/export-config.sh --check / sudo bash scripts/linux/export-config.sh --apply --yes;sudo bash scripts/linux/import-config.sh --apply --yes
坑:**回滚不回退 `/etc`、也不回退 `~/.config`** —— "当前配置"要靠这套快照留档,不能指望 `rpm-ostree rollback`;`import` 前必须留 `pre-import-*` 备份(脚本自动做),否则会把现状盖掉;分层包是唯一"不可快照"的项,只能按打印的命令人工执行。
出错时:`dconf load` 报错 -> 看 `dconf.txt` 是否被编辑器改坏(必须原样文本);`brew bundle` 失败 -> 逐条 `brew install`,与清单对齐后重跑 `--check`。

L4 的整机验收见 [08-verification.md](08-verification.md) 的 A-G 七组(B 组与 F 组覆盖本阶段的共享盘与健壮性判据,G 组覆盖本页的体验层);逐项回退动作见 [checklists/rollback.md](../checklists/rollback.md)。
