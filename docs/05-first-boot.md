# 05:L4 首启收敛(轨道 L/D)

本文件在流程中的位置:`04-kubuntu`(轨道 L:L3 安装)-> **本文件(轨道 L:L4 首启收敛)** -> `07-rescue`(退役与救援)。

L4 是收敛与加固,不是再装一遍系统:本阶段不动分区表、不动固件设置、不改 `BootOrder`(不变量 I1-I4)。目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;依据见[设计文档](design/00-design.md) 4.5 节(L4)、4.7 节(R1-R9 健壮性)、3.16 与 5.3 节(共享盘)、7.1 节(巡检)与[变体设计](design/04-kubuntu-variant-design.md) 第 2 节(D1-D6)、第 3 节(snap 规避)、第 7 节(回退与恢复)。

Kubuntu 26.04 LTS 的三条硬事实贯穿全文:系统是**传统可变系统**(`apt` 直接装包,装完即生效,没有"分层安装需重启"这回事)、桌面**只有 Wayland 会话**、**Secure Boot 全程开启**(显卡走 Ubuntu 官方预签名包,不需要自签密钥、也不需要向固件注册密钥)。

## 开始前

- 前提:已能进 Kubuntu 26.04 LTS 桌面(L3 收尾),`baseline/03-efi-layout.txt` 在位,`BootOrder` 首位仍是 Windows Boot Manager。
- 需要的东西:参数表 `SHARED_PART_UUID`(取值与 `baseline/02-partitions.txt` 交叉核对)、`BOOT_MENU_KEY`;救援介质保持"已验证可用"(显卡环节最容易进不去桌面)。
- 产物落点:`baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(多设备放 `baseline/<设备别名>/`,全部不入库)。
- 纪律:任何驱动、包或发行版升级之前先备份 `baseline/` 与 `/etc` 关键文件(R1),并按 `05-9` 想好包级回退路径;自动更新只装安全更新,**不自动重启**(设计 04 第 2 节 D2)。

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
     看到:`xdg-user-dir DOCUMENTS` 回到 `/home/<用户名>/Documents`(Ubuntu 下 `/home` 就是真目录,脚本用 `getent passwd` 解析家目录)
脚本:sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --check / --apply --yes
坑:NTFS 没有 POSIX 权限语义,别把 `.ssh`、代码仓库或整个家目录搬过去;重定向只影响"新建文件落在哪",旧文件不会自动搬(设计 5.3)。
出错时:目标目录缺失 -> 先让 `05-1` 通过再重跑;某应用仍写本地 -> 注销重登一次,不要为它把 `~/.config` 挪到共享盘。

### 05-3 显卡与 Secure Boot(装 Ubuntu 官方预签名 nvidia 包)

做:用 `ubuntu-drivers` 装 Ubuntu 官方**预签名**的 nvidia 包(不需要换镜像分支、不需要自签密钥),再核对 Wayland 会话与 PRIME offload(设计 04 第 2 节 D3)。
  1. 先看现状与将执行的动作:`sudo bash scripts/linux/graphics.sh --check`
     看到:输出五项判据(推荐驱动行 / `modinfo -F signer nvidia` / `nvidia-smi` / `XDG_SESSION_TYPE` / `xrandr --listproviders` 的 provider 数);零写;未装或未重启的项记"需人工",不是失败
  2. 按官方文档核实推荐驱动后执行:`sudo bash scripts/linux/graphics.sh --apply --yes`,装完按提示重启
     看到:脚本报"驱动已安装";重启后 `nvidia-smi` 有输出、`lsmod` 有 `nvidia`、`modinfo -F signer nvidia` 非空(签名者来自官方包)
  3. 会话与内核行校验:`echo "$XDG_SESSION_TYPE"` 为 `wayland`;`cat /proc/cmdline` 不含 `nomodeset`
     看到:两项都成立;`nomodeset` 会关掉 KMS,与默认 Wayland 会话冲突(设计 4.5、11.1)
  4. nouveau 兜底:桌面起不来时不要长按电源,按 `07-2` 从 GRUB 提示符回 Windows;能进系统则按 `05-9` 降级驱动版本
     看到:系统仍可用(退到 nouveau 或旧驱动版本);处置顺序是"换更新内核 -> 换驱动版本 -> 才考虑发行版问题"
脚本:sudo bash scripts/linux/graphics.sh --check / --apply --yes
坑:本步**不关 Secure Boot、不自签密钥、不注册固件密钥** —— 官方包自带签名链,自签反而破坏预签名路径(设计 04 第 2 节 D3);签名细查见 `07-7` 的 `scripts/linux/check-signature.sh`。
出错时:装完黑屏 -> 按 `10-21` 处置;驱动不认(`lsmod` 有 `nouveau`、无 `nvidia`)-> 按 `05-9` 降级并 `apt-mark hold` 后重评,不要在这一步反复试。

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

做:用 `apt` 装 `chntpw` 读 Windows 注册表 hive,再用上游脚本把配对密钥导入 Linux(设计 4.5;上游 KeyofBlueS/bt-keys-sync,本仓库不内置其代码)。
  1. 只读挂上 Windows 系统分区(如 `sudo mount -o ro /dev/nvme0n1p3 /mnt/win`),再跑 `sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check --win-mnt /mnt/win`
     看到:三项前置的判定(chntpw 已装 / hive 可读 / 上游脚本已就位);未装 chntpw 时记"需人工",不是失败
  2. 执行:`sudo bash scripts/linux/bt-keys-sync-wrapper.sh --apply --yes --win-mnt /mnt/win`
     看到:脚本用 `apt` 装上 `chntpw`(apt 装包**立即生效,不需要重启**),把上游脚本下到 `/opt/bt-keys-sync/` 后以 `--windows-keys` 运行
  3. 顺序(错了就得重来):先在 Linux 配对目标设备 -> 回 Windows 对同一设备再配对一次(让它成为权威来源)-> 回 Linux 以 `--windows-keys` 导入 -> 两系统各连一次复测
     看到:`bluetoothctl devices` 能看到该设备;两个系统都不再需要重新配对
脚本:sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check / --apply --yes --win-mnt /mnt/win
坑:**不做反向写 Windows 注册表** —— 上游建议的方向就是"以 Windows 侧密钥为准";hive 只需只读挂载,不要为了省事改成读写。
出错时:读不到 hive -> 确认只读挂载路径后重跑,不要强写注册表;仍要反复重配对 -> 按第 3 步顺序重做。

### 05-6 交换空间(zram 核对 + 4GiB swapfile)

做:核对 zram 已启用(**优先 `systemd-zram-generator`,退化 `zram-tools`**),并补一个 4GiB swapfile 与对应 `fstab` 行;不建 swap 分区、不做休眠(设计 04 第 7 节 R6)。
  1. 先空跑:`sudo bash scripts/linux/storage.sh --check`
     看到:四项判定(swapfile 是否已启用 / `fstab` 是否有该行且带 `nofail` / `zramctl` 是否有 `zram0` / `/proc/cmdline` 是否无 `resume=`);零写
  2. 执行:`sudo bash scripts/linux/storage.sh --apply --yes`
     看到:脚本报 PASS(swapfile 已启用 + `fstab` 行齐备 + `zram0` 已建立 + 未配休眠);`swapon --show` 与 `zramctl` 各列一行
  3. 若 `zram0` 缺失:脚本先试 `systemd-zram-generator`,装不上再退化装 `zram-tools` 并写 `/etc/default/zramswap`,重启后重跑本卡复核
     看到:重启后 `zramctl` 列出 `zram0`,容量约 `min(RAM/2, 8GiB)`
脚本:sudo bash scripts/linux/storage.sh --check / --apply --yes
坑:swapfile 的 `fstab` 行必须带 `nofail`,否则分区缺失时会挡住启动;**不做休眠** —— 休眠需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车(设计 3.8)。
出错时:`zramctl` 无 `zram0` -> 先确认包已生效(重启)再重跑;`fallocate` 失败 -> 查 root 可用空间,不要改分区表。

### 05-7 日志与更新(journald 持久化;只装安全更新、不自动重启)

做:打开 journald 持久化,并把自动更新限制成"只装安全更新、不自动重启"——两件事各一个脚本,同属本卡(设计 04 第 2 节 D2、第 7 节 R5 与 R8)。
  1. `sudo bash scripts/linux/set-journald.sh --check` -> `--apply`
     看到:配置片段含 `Storage=persistent`;`journalctl --disk-usage` 有输出;`systemctl is-active systemd-journald` 为 active
  2. `sudo bash scripts/linux/set-updates.sh --check` -> `--apply`
     看到:片段含 `Automatic-Reboot "false"`,且 `Allowed-Origins` 只列 `-security`;`systemctl is-enabled unattended-upgrades` 为 enabled
  3. 写入前先确认没有自动重启:`grep -rn 'Automatic-Reboot' /etc/apt/apt.conf.d/`
     看到:只出现 `false`;出现 `true` 时脚本判 FAIL 且 `--apply` 一个文件都不写
脚本:sudo bash scripts/linux/set-journald.sh --check / --apply;sudo bash scripts/linux/set-updates.sh --check / --apply
坑:自动重启与"变更前先备份与留档"直接冲突;只放开 `-security` 才符合 LTS 期间的保守口径,把 `updates` 一起放开等于把内核与驱动升级交给无人值守(设计 04 第 2 节 D2、第 7 节 R8)。
出错时:journald 起不来 -> 看 `journalctl -u systemd-journald` 定位;服务未 enabled -> 手工 enable 后重跑,不要改成自动重启。

### 05-8 SSH 救援通道与磁盘健康

做:启用 `sshd` 常开(桌面挂死时从另一台机器登录排障),并用 `apt` 装 `smartmontools`、启用 `smartd`(设计 04 第 7 节 R7 与 R9)。
  1. 先空跑:`sudo bash scripts/linux/set-remote-health.sh --check`
     看到:两项判定(`sshd` 是否 active、各盘 `smartctl -H` 是否 PASSED/OK);未装 `smartctl` 时记"需人工"
  2. 执行:`sudo bash scripts/linux/set-remote-health.sh --apply`
     看到:脚本用 `apt` 装上 `smartmontools`(立即生效,不需要重启),并执行 `systemctl enable --now sshd smartd`
  3. 复跑 `--check`
     看到:脚本报 PASS(`sshd` active 且各盘 SMART 健康检查通过);`ss -tlnp | grep :22` 能看到 22 端口监听(附加证据,不作为失败项)
脚本:sudo bash scripts/linux/set-remote-health.sh --check / --apply
坑:`apt` 装包立即生效,不需要重启(与旧原子版的分层安装不同);刚装完 `smartd` 时健康行可能读不到,复跑一次,不要就此判盘坏。
出错时:无 `smartctl` -> 确认包已装上(必要时 `sudo apt-get install -y smartmontools`);健康行不是 PASSED/OK -> 立刻备份数据并按磁盘告警处置。

### 05-9 包级回退与变更前备份(降级 + `apt-mark hold`)

做:变更前先备份、出事时按包降级。**本轨道没有一条命令回退整个系统**:包级回退覆盖"某次升级把某个软件搞坏",系统级损坏走原地重装(`07-4` / `07-5`)。
  1. 先看可用版本:`bash scripts/linux/rollback-pkg.sh --list <包名>`
     看到:列出该包在仓库里的可用版本(取自 `apt-cache madison`);零写
  2. 再空跑巡检:`bash scripts/linux/rollback-pkg.sh --check`
     看到:两项判据(已 `apt-mark hold` 的包清单 / `/var/log/apt/history.log` 的最近记录);两项都取不到时记"需人工"
  3. 降级并冻结:`sudo bash scripts/linux/rollback-pkg.sh --apply --pkg <包名> --version <版本> --yes`
     看到:脚本装上指定旧版本并 `apt-mark hold`;`apt-mark showhold` 能列出该包
  4. 要让该包重新跟随仓库升级:`sudo bash scripts/linux/rollback-pkg.sh --unhold --pkg <包名> --yes`
     看到:该包从 `apt-mark showhold` 里消失
脚本:bash scripts/linux/rollback-pkg.sh --list <包名> / --check / sudo bash scripts/linux/rollback-pkg.sh --apply --pkg <包名> --version <版本> --yes / --unhold --pkg <包名> --yes
坑:`hold` 只冻结**已装版本**的升级,不拦安装(拦安装是 `05-14` 的 apt pin);只装旧版本而不 hold,下一次 `apt upgrade` 会把它升回去。
出错时:找不到旧版本 -> 换更近的版本或确认该包来自官方仓库;降级后仍坏 -> 按 `07-1` 判层,再评估原地重装(`07-5`)。

### 05-10 发行版升级(约 3 年一次:`do-release-upgrade`)

做:先做前置备份与留档,再跑 `do-release-upgrade`,重启后复核版本、会话、驱动与 snap 四条判据(设计 04 第 2 节 D2、第 3 节 S5)。
  1. 先看现状:`sudo bash scripts/linux/upgrade-release.sh --check`
     看到:四项判据(版本可读 / `apt-get -s dist-upgrade` 无异常 / apt pin 与 Mozilla 源文件在位 / `do-release-upgrade` 可用);缺一项即 FAIL,先补齐再谈升级
  2. 执行:`sudo bash scripts/linux/upgrade-release.sh --apply --yes`
     看到:脚本先把 `baseline/` 备份到 `<backup-dir>/<时间戳>-baseline/`、把 apt pin 与 Mozilla 源内容写进日志留档,再跑 `do-release-upgrade`
  3. 重启后复核:`sudo bash scripts/linux/upgrade-release.sh --check` 与 `sudo bash scripts/linux/step-snap-free.sh --check`
     看到:版本已更新;会话仍为 `wayland`;`nvidia-smi` 与 `modinfo -F signer nvidia` 正常;snap 四条判据全过(升级会重新引入 snap,不过就按 `05-14` 重写 pin 与 Mozilla 源)
脚本:sudo bash scripts/linux/upgrade-release.sh --check / --apply --yes;sudo bash scripts/linux/step-snap-free.sh --check
坑:**没有留档就不要升级** —— 翻车后没有可对照的 pin 与源文件;`do-release-upgrade` 会重新引入 snap(设计 04 第 3 节 S5);升级不动 Windows 分区与启动顺序(I1-I4)。
出错时:pin 或源文件缺失 -> 先按 `05-14` 重建再升级;升级后起不来 -> 开机菜单选旧内核,或按 `07-1` 判层,不要直接重装。

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
     看到:脚本报"L4 产物已落盘";第一份含发行版版本 / 会话类型 / 显卡驱动来源与版本 / snap 四条判据 / 挂载与共享盘写测试 / 待升级包数;第二份是 R1-R9 逐项现状与证据(取不到的写"未取到")
  3. 带回 Windows 侧后核对:`git status`
     看到:`baseline/` 下的变化一个都不出现(仅 [baseline/README.md](../baseline/README.md) 入库)
脚本:bash scripts/linux/collect-l4.sh --check / --apply --out-dir baseline
坑:两份产物都不入库;漏掉 snap 四条判据或 `findmnt` 会让后续复检缺证据。
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
坑:退出码不能当判据(恒为 0);编排顺序是 `storage -> hardening -> mount-shared -> graphics`,其中 `hardening` 的 R1/R2 是**只读核对**;**本卡两个脚本都声明了 `# 破坏性:1`,`--apply` 缺 `--yes` 会退 64 且零写**(与其它破坏性脚本同口径)。
出错时:摘要未写出 -> 核对日志目录写权限后重跑;某模块 fail -> 按摘要的模块名看 `/var/log/dbk/<模块>.log` 定位,再单卡重跑。

### 05-14 snap 零残留(四条判据 + apt pin 压制)

做:核对四条判据;不干净时用 `--apply --yes` 清除残留、写 apt pin 并配 Mozilla 官方仓库(设计 04 第 3 节 S2/S3/S4/S6)。
  1. 先空跑:`sudo bash scripts/linux/step-snap-free.sh --check`
     看到:四条判据逐条给出结论——① `snap list` 为空或 snap 命令不存在;② `dpkg -l snapd` 无输出;③ `apt-cache policy snapd` 无候选或被 pin 到 -1;④ `apt-get install -s firefox` 的模拟输出不含 snapd
  2. 不干净时执行:`sudo bash scripts/linux/step-snap-free.sh --apply --yes`
     看到:先逐个 `snap remove --purge`,再 `apt-get purge -y snapd` 并清理 `/var/snap` 与 `/snap` 残留;随后写 `/etc/apt/preferences.d/no-snap`(`Pin-Priority: -1`)并配置 Mozilla 官方 APT 仓库(keyring + `signed-by` + 高优先级)
  3. 复跑 `--check` 四条
     看到:四条全过;`apt policy firefox` 的来源是 Mozilla 仓库;`snap list` 仍为空
脚本:sudo bash scripts/linux/step-snap-free.sh --check / --apply --yes
坑:pin 用 `Pin-Priority: -1`(该包永不作为候选:遇 `Recommends` 安静跳过、遇硬 `Depends` 响亮失败),**不要**用 `apt-mark hold` 替代;边界是不追求"一个 snap 文件都没有",验收取 `snap list` 空 + `dpkg -l snapd` 无输出 + 浏览器来源非 snap。
出错时:`apt install firefox` 仍把 snapd 拉进来 -> 按 `10-22` 处置;升级后又出现 snap -> 按 `10-23` 重写 pin 与 Mozilla 源。

L4 的整机验收见 [08-verification.md](08-verification.md) 的 A-F 六组(B 组与 F 组覆盖本阶段的共享盘与健壮性判据);逐项回退动作见 [checklists/rollback.md](../checklists/rollback.md)。
