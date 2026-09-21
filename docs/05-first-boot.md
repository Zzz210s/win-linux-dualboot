# 05:L4 首启收敛(轨道 L/D)

本文件在流程中的位置:`04-silverblue`(轨道 L:L3 安装)-> **本文件(轨道 L:L4 首启收敛)** -> `07-rescue`(退役与救援)。

L4 是收敛与加固,不是再装一遍系统:本阶段不动分区表、不动固件设置、不改 `BootOrder`(不变量 I1-I4)。目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;依据见[设计文档](design/00-design.md) 4.5 节(L4)、4.7 节(R1-R9 健壮性)、3.16 与 5.3 节(共享盘)、7.1 节(巡检)与[变体设计](design/02-fedora-atomic-variant-design.md) 第 3、4 节(NVIDIA/MOK 与部署级回滚)。

三条原子版硬语义贯穿全文:**`/usr` 只读**(系统级工具只能 `rpm-ostree install` 分层)、**每次分层安装需重启**才生效、**`/var` 与 `/home` 不属于部署、不随回滚回退**(回滚系统不会丢家目录数据)。

## 开始前

- 前提:已能进 Fedora 44 Silverblue 桌面(L3 收尾),`baseline/03-efi-layout.txt` 在位,`BootOrder` 首位仍是 Windows Boot Manager。
- 需要的东西:参数表 `SHARED_PART_UUID`(取值与 `baseline/02-partitions.txt` 交叉核对)、`BOOT_MENU_KEY`;救援介质保持"已验证可用"(显卡环节最容易进不去桌面)。
- 产物落点:`baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(多设备放 `baseline/<设备别名>/`,全部不入库)。
- 纪律:任何分层安装、`rebase`、发行版升级之前先 `rpm-ostree pin` 当前部署(R1);自动更新只允许 check/download,**不自动应用、不自动重启**(设计 3.18)。

### 05-1 挂载共享数据盘(`D:` 整块以 `ntfs3` 读写挂到 `/mnt/shared`)

做:先逐条核对四条前提(缺一不可),再用脚本把挂载行写进 `fstab`、挂载并做写测试(设计 5.3)。
  1. 前提一/二(Windows 侧已完成,见 `03-2`):已关快速启动与休眠;`D:` 未加密(`manage-bde -status D:` 为 `Protection Off`)
     看到:两项都成立;缺任一项时脚本的写测试必然失败(NTFS 脏卷 / 加密卷无法读写)
  2. 前提三:挂载选项固定 `rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime`(`ntfs3` 没有 POSIX 权限位,`windows_names` 阻止创建 Windows 非法文件名)
     看到:`templates/fstab.snippet` 的共享盘行选项齐备;核对脚本对缺项记 FAIL
  3. 先空跑再执行:`sudo bash scripts/linux/mount-shared.sh --uuid <SHARED_PART_UUID> --check` -> 加上 `--apply --yes`
     看到:空跑逐条列出 checks(首次执行时"fstab 尚未写入"判 FAIL 属预期);`--apply` 报 PASS,`findmnt /mnt/shared` 为 `ntfs3`、选项含 `rw` 与 `windows_names` 与 `nofail`,写测试创建并删除 `/mnt/shared/.dbk-write-test` 成功
  4. 前提四:记下"不要在共享盘上做的事"(NTFS 无 POSIX 权限语义,设计 5.3 前提 4)——不放 `~/.config`、`~/.ssh`、`~/.gnupg` 等配置与凭据目录;不放代码仓库与依赖符号链接、硬链接、可执行位、大小写敏感重命名的工程;不放需要权限位或 setuid 语义的脚本与服务数据;不在 Linux 侧对共享盘做大目录批量重命名或移动;不按"最近下载"整目录清理(`D:\Downloads` 被两边共用);共用目录里不放依赖后缀匹配的临时产物;关键目录在别处保留第二份备份
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
     看到:`xdg-user-dir DOCUMENTS` 回到 `/var/home/<用户名>/Documents`(原子版里 `/home` 是指向 `/var/home` 的符号链接,两者等价)
脚本:sudo bash scripts/linux/xdg-redirect.sh --user <用户名> --check / --apply --yes
坑:NTFS 没有 POSIX 权限语义,别把 `.ssh`、代码仓库或整个家目录搬过去;重定向只影响"新建文件落在哪",旧文件不会自动搬(设计 5.3)。
出错时:目标目录缺失 -> 先让 `05-1` 通过再重跑;某应用仍写本地 -> 注销重登一次,不要为它把 `~/.config` 挪到共享盘。

### 05-3 显卡驱动与 MOK(rebase 到 ublue 的 NVIDIA 变体,一次性注册)

做:一次 `rpm-ostree rebase` 换到 ublue 的 NVIDIA 变体(镜像内模块已预签名),重启后注册一次 MOK,再复检签名与会话(设计 4.5、02 设计 3 节)。
  1. 先看现状与将执行的动作:`sudo bash scripts/linux/graphics.sh --check`
     看到:输出三项(当前部署来源 / `nvidia` 模块 / 会话类型)与逐条 checks;零写;rebase 前未加载 `nvidia` 时该行记"需人工",不是失败
  2. 按上游官方文档核实镜像名与分支后执行:`sudo bash scripts/linux/graphics.sh --apply --yes`,随后手工 `sudo systemctl reboot`
     看到:脚本报"rebase 已提交但需重启才生效";重启后 `rpm-ostree status` 的来源是 NVIDIA 变体,`lsmod` 有 `nvidia`
  3. 注册 MOK(任务名与上游 MOK 密码一律标"待核实"):`sudo bash scripts/linux/graphics-mok.sh --apply` -> 重启进 MOK 界面选 Enroll MOK -> Continue -> 输入上游密码 -> Reboot
     看到:回系统后 `--check` 报 PASS(`mokutil --list-enrolled` 含上游密钥、`modinfo -F signer nvidia` 非空)
  4. 会话与内核行校验:`echo "$XDG_SESSION_TYPE"` 为 `wayland`;`cat /proc/cmdline` 不含 `nomodeset`
     看到:两项都成立;`nomodeset` 会关掉 KMS,与默认 Wayland 会话冲突(设计 4.5、11.1)
脚本:sudo bash scripts/linux/graphics.sh --check / --apply --yes;sudo bash scripts/linux/graphics-mok.sh --check / --apply
坑:原子版上 akmods 在 `rpm-ostree install` 时**不签名**且会卡内核升级 —— 不要自签、不要关 Secure Boot;**镜像名/分支/`ujust` 任务名/MOK 密码上游会改,未核实前不要执行**(02 设计 3 节)。
出错时:rebase 后桌面起不来 -> 开机菜单选上一个部署,或 `sudo bash scripts/linux/dbk-rollback.sh --rollback --yes`;驱动不认(兜底迹象:`lsmod` 有 `nouveau`、无 `nvidia`)-> 按 `05-9` 回滚部署后重评,不要在这一步反复试。

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

做:分层安装 `chntpw` 读 Windows 注册表 hive,再用上游脚本把配对密钥导入 Linux(设计 4.5;上游 KeyofBlueS/bt-keys-sync,本仓库不内置其代码)。
  1. 只读挂上 Windows 系统分区(如 `sudo mount -o ro /dev/nvme0n1p3 /mnt/win`),再跑 `sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check --win-mnt /mnt/win`
     看到:三项前置的判定(chntpw 已装 / hive 可读 / 上游脚本已就位);未装 chntpw 时记"需人工",不是失败
  2. 执行:`sudo bash scripts/linux/bt-keys-sync-wrapper.sh --apply --yes --win-mnt /mnt/win`
     看到:脚本把 `chntpw` 写进下一部署并提示**需重启**;本次才装上时脚本停下要求重启后重跑本步
  3. 顺序(错了就得重来):先在 Linux 配对目标设备 -> 回 Windows 对同一设备再配对一次(让它成为权威来源)-> 回 Linux 以 `--windows-keys` 导入 -> 两系统各连一次复测
     看到:`bluetoothctl devices` 能看到该设备;两个系统都不再需要重新配对
脚本:sudo bash scripts/linux/bt-keys-sync-wrapper.sh --check / --apply --yes --win-mnt /mnt/win
坑:分层安装**需重启**才生效(`/usr` 只读,系统级工具走 `rpm-ostree install`);**不做反向写 Windows 注册表** —— 上游建议的方向就是"以 Windows 侧密钥为准"。
出错时:读不到 hive -> 确认只读挂载路径后重跑,不要强写注册表;仍要反复重配对 -> 按第 3 步顺序重做。

### 05-6 交换空间(zram 核对 + 4GiB swapfile)

做:核对 zram 已启用(原子桌面默认带 `zram-generator`),并补一个 4GiB swapfile 与对应 `fstab` 行;不建 swap 分区(设计 3.8)。
  1. 先空跑:`sudo bash scripts/linux/storage.sh --check`
     看到:三项判定(swapfile 是否已启用 / `fstab` 是否有该行且带 `nofail` / `zramctl` 是否有 `zram0`);零写
  2. 执行:`sudo bash scripts/linux/storage.sh --apply --yes`
     看到:脚本报 PASS(swapfile 已启用 + `fstab` 行齐备 + `zram0` 已建立);`swapon --show` 与 `zramctl` 各列一行
  3. 若 `zram0` 缺失:脚本分层安装 `systemd-zram-generator` 并提示**需重启**,重启后重跑本卡复核
     看到:重启后 `zramctl` 列出 `zram0`,容量约 `min(RAM/2, 8GiB)`
脚本:sudo bash scripts/linux/storage.sh --check / --apply --yes
坑:swapfile 的 `fstab` 行必须带 `nofail`,否则分区缺失时会挡住启动;**不做休眠** —— 休眠需 swap ≥ RAM,且 NVIDIA + Wayland 下易翻车(设计 3.8)。
出错时:`zramctl` 无 `zram0` -> 先确认分层包已生效(重启)再重跑;`fallocate` 失败 -> 查 root 可用空间,不要改分区表。

### 05-7 日志持久化与更新策略

做:打开 journald 持久化,并把自动更新限制成"只检查 / 只下载"——两件事各一个脚本,同属本卡(设计 4.7 的 R5 与 R8)。
  1. `sudo bash scripts/linux/set-journald.sh --check` -> `--apply`
     看到:配置片段含 `Storage=persistent`;`journalctl --disk-usage` 有输出;`systemd-journald` 为 active
  2. `sudo bash scripts/linux/set-updates.sh --check` -> `--apply`
     看到:目标配置的 `AutomaticUpdatePolicy` 是 `check` 或 `download`;`systemctl is-enabled rpm-ostreed-automatic.timer` 为 `enabled`
  3. 写入前先确认没有 `stage`:`grep -n AutomaticUpdatePolicy /etc/rpm-ostreed.conf`
     看到:只有 check/download;出现 `stage` 时脚本判 FAIL 且 `--apply` 一个文件都不写
脚本:sudo bash scripts/linux/set-journald.sh --check / --apply;sudo bash scripts/linux/set-updates.sh --check / --apply
坑:`stage` = 自动应用 + 自动重启,与"变更前先固定当前部署"直接冲突;**`/var` 不属于部署,日志不随部署回滚丢失**(设计 3.18、3.22)。
出错时:journald 起不来 -> 看 `journalctl -u systemd-journald` 定位;定时器未 enabled -> 手工 enable 后重跑,不要改成 `stage`。

### 05-8 SSH 救援通道与磁盘健康

做:启用 `sshd` 常开(桌面挂死时从另一台机器登录排障),并分层安装 `smartmontools`、启用 `smartd`(设计 4.7 的 R7 与 R9)。
  1. 先空跑:`sudo bash scripts/linux/set-remote-health.sh --check`
     看到:两项判定(`sshd` 是否 active、各盘 `smartctl -H` 是否 PASSED/OK);未装 `smartctl` 时记"需人工"
  2. 执行:`sudo bash scripts/linux/set-remote-health.sh --apply`
     看到:脚本分层安装 `smartmontools` 并提示**需重启**,且已执行 `systemctl enable --now sshd smartd`
  3. 重启后复跑 `--check`
     看到:脚本报 PASS(`sshd` active 且各盘 SMART 健康检查通过);`ss -tlnp | grep :22` 能看到 22 端口监听(附加证据,不作为失败项)
脚本:sudo bash scripts/linux/set-remote-health.sh --check / --apply
坑:`/usr` 只读,系统级工具只能分层安装且**每次分层需重启**,否则 `smartctl` 不存在;刚装完 `smartd` 时健康行可能读不到,重启后复跑,不要就此判盘坏。
出错时:无 `smartctl` -> 确认分层包已生效(重启);健康行不是 PASSED/OK -> 立刻备份数据并按磁盘告警处置。

### 05-9 部署回滚(开机菜单选旧部署,或 `rpm-ostree rollback`)

做:列出当前部署与固定状态;需要回退时把"下一次启动"切到上一个部署(部署级回滚,02 设计 4 节 D3)。
  1. `bash scripts/linux/dbk-rollback.sh --list` 与 `bash scripts/linux/dbk-rollback.sh --check`
     看到:`--list` 列出部署数 / 下一次启动 / 当前启动 / 版本 / pin 标记(列表第一项 = 下次默认启动,`●` = 当前已启动);`--check` 复检部署列表与固定状态、`nvidia` 签名、会话类型
  2. 变更前先固定当前部署:`sudo bash scripts/linux/dbk-rollback.sh --pin --yes`
     看到:脚本复读确认"已有 N 个部署处于固定状态";pin 只影响部署保留,不需要重启
  3. 回退:`sudo bash scripts/linux/dbk-rollback.sh --rollback --yes`,然后手工 `sudo systemctl reboot`(也可在开机菜单直接选旧部署)
     看到:脚本报已切换下一次启动的部署(`A -> B`)且提示需重启后生效;重启后 `--check` 通过(会话仍 wayland、`nvidia` 仍加载)
  4. 不再需要该回滚点时:`sudo bash scripts/linux/dbk-rollback.sh --unpin --yes`
     看到:复读确认"已无固定部署";本方案的回滚就是换部署,不用文件系统快照(02 设计 4 节)
脚本:bash scripts/linux/dbk-rollback.sh --list / --check / --pin --yes / --unpin --yes / --rollback --yes
坑:**用户数据不随部署回滚** —— `/var` 与 `/var/home` 不在部署内(`/home` 是 `/var/home` 的符号链接),回滚系统不会丢家目录数据;缺 `--yes` 时脚本停在 64 且零写。
出错时:只有一个部署 -> 变更前忘了 pin,先按本卡 pin 再改系统;回滚后仍起不来 -> 在开机菜单里直接选旧部署。

### 05-10 发行版升级(rebase 到新分支,前置 pin)

做:先固定当前部署,再 `rpm-ostree rebase` 到目标分支,重启后复检版本、会话与 `nvidia` 加载(设计 3.21、02 设计 4 节)。
  1. 先看现状:`sudo bash scripts/linux/upgrade-release.sh --check`
     看到:列出部署数、下一次启动的来源、当前版本;未给 `--branch` 时分支名标"待核实",按上游文档核实后再执行
  2. 执行:`sudo bash scripts/linux/upgrade-release.sh --apply --yes --branch <目标分支>`
     看到:脚本先 `rpm-ostree pin` 并复读确认"前置固定已确认"(确认不了就按纪律不执行 rebase),再提交 rebase 并提示**需重启**
  3. 手工 `sudo systemctl reboot`,再复检:`sudo bash scripts/linux/upgrade-release.sh --check --branch <目标分支>`
     看到:来源已是目标分支;版本可读;会话为 `wayland`;`lsmod` 有 `nvidia`(无独显时该项记"需人工")
脚本:sudo bash scripts/linux/upgrade-release.sh --check / --apply --yes --branch <目标分支>
坑:**没有 pin 就不要 rebase** —— 翻车后没有确定可回的部署;分支名上游会改;`rebase` 不动 Windows 分区与启动顺序(I1-I4)。
出错时:pin 复读确认不了 -> 脚本会拒绝 rebase,先修 pin;重启后起不来 -> 开机菜单选被固定的旧部署,或按 `05-9` 处置。

### 05-11 回 Windows 的入口(一次性,不改启动顺序)

做:确认本机有一条"一键回 Windows"的路径,并且它是**一次性**的(不变量 I2);三条路径任一可用即可。
  1. Linux 侧先空跑再执行:`sudo bash scripts/linux/reboot-to-windows.sh --check` -> `sudo bash scripts/linux/reboot-to-windows.sh --apply`
     看到:空跑打印 `BootOrder` 与目标条目;执行后报 PASS(一次性启动项已设置且 `BootOrder` 未变),再手工 `sudo systemctl reboot`
  2. 厂商菜单键兜底:开机按参数表 `BOOT_MENU_KEY`,选 `Windows Boot Manager`
     看到:进入 Windows;这条路径零副作用,也是 L3 进 Linux 用的同一条
  3. Windows 侧等价入口:`scripts/windows/set-bootnext.ps1`(用 `bcdedit /set {fwbootmgr} bootsequence {GUID}` 做一次性切换)
     看到:脚本断言 `BootOrder` 首位仍是 Windows Boot Manager
脚本:sudo bash scripts/linux/reboot-to-windows.sh --check / --apply
坑:**任何改永久顺序的做法都破坏 I2**(`efibootmgr -o`、`displayorder`);一次性设置只生效一次,进 Linux 后要再回 Windows 必须重新设置。
出错时:读不到 `BootOrder` -> 用 `sudo` 重跑或人工 `sudo efibootmgr` 核对;找不到 Windows 条目 -> 引导层问题按 `07-rescue.md` 处置,不要手工改永久顺序。

### 05-12 落 L4 产物(两份基线文档)

做:采集本阶段实测证据,落成 `baseline/04-first-boot.md` 与 `baseline/04-robustness.md`(命名契约见 [baseline/README.md](../baseline/README.md));多设备放 `baseline/<设备别名>/`。
  1. 先看:`bash scripts/linux/collect-l4.sh --check`
     看到:打印两份产物的全部节;此时零写(不创建文件,也不碰共享盘做写测试)
  2. 再落盘:`bash scripts/linux/collect-l4.sh --apply --out-dir baseline`
     看到:脚本报"L4 产物已落盘";第一份含会话类型 / 部署来源 / GPU 与 MOK / 内存压力防护 / 挂载 / 共享盘写测试;第二份是 R1-R9 逐项现状与证据(取不到的写"未取到")
  3. 带回 Windows 侧后核对:`git status`
     看到:`baseline/` 下的变化一个都不出现(仅 [baseline/README.md](../baseline/README.md) 入库)
脚本:bash scripts/linux/collect-l4.sh --check / --apply --out-dir baseline
坑:两份产物都不入库;只写六节而漏掉 `rpm-ostree` 或 `findmnt` 会让后续复检缺证据。
出错时:读不到共享盘证据 -> 先让 `05-1` 通过再重跑;写不进 `baseline/` -> 核对目录权限与磁盘空间,不要改产物路径。

### 05-13 L4 汇总执行(可选:按顺序跑各模块并聚合结果)

做:用编排脚本按固定顺序一次跑完 L4 各模块——这是**批量便利路径**,单卡仍可独立执行;排障时优先单卡单跑(各脚本幂等)。
  1. 先空跑:`bash scripts/linux/first-boot.sh --uuid <SHARED_PART_UUID>`
     看到:逐模块打印将执行的动作与判据;缺省/`--check` 是 dry-run,不改系统;非 root 时日志落 `<TMPDIR>/dbk-<uid>/` 并打印警告
  2. 再执行:`sudo bash scripts/linux/first-boot.sh --apply --uuid <SHARED_PART_UUID>`
     看到:模块顺序为 `storage -> hardening -> mount-shared -> graphics -> graphics-mok`;末尾写出 `/var/log/dbk/first-boot-summary.txt`(表头 `模块 | 状态 | 关键输出`,统计行含 `失败项: N;跳过项: M`)
  3. 看摘要而不是退出码:`cat /var/log/dbk/first-boot-summary.txt`
     看到:单模块失败不改变退出码(脚本恒为 0,只有用法/权限类错误才非 0),失败与跳过项在摘要里逐条列出;失败模块按对应卡单独重跑(如 `sudo bash scripts/linux/hardening.sh --apply`、`05-1` 至 `05-11`)
脚本:bash scripts/linux/first-boot.sh --uuid <SHARED_PART_UUID> / sudo bash scripts/linux/first-boot.sh --apply --uuid <SHARED_PART_UUID>;bash scripts/linux/hardening.sh --check / sudo bash scripts/linux/hardening.sh --apply
坑:退出码不能当判据(恒为 0);编排的顺序是 `storage -> hardening -> mount-shared -> graphics`,其中 `hardening` 的 R1/R2 是**只读核对**,真正固定部署请用 `05-9`。
出错时:摘要未写出 -> 核对日志目录写权限后重跑;某模块 fail -> 按摘要的模块名看 `/var/log/dbk/<模块>.log` 定位,再单卡重跑。

L4 的整机验收见 [08-verification.md](08-verification.md) 的 A-F 六组(B 组与 F 组覆盖本阶段的共享盘与健壮性判据);逐项回退动作见 [checklists/rollback.md](../checklists/rollback.md)。
