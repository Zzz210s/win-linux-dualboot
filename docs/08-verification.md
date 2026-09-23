# 验收:唯一判据与 A-F 六组勾选卡

本文件在流程中的位置:上一份 `07-rescue.md` -> 本份 -> 下一份 `10-faq.md`

**本文档是唯一判据:不以"装完了"为准,以"清单勾完"为准。** 每组一张勾选卡,条式为 `- [ ] 动作 -> 看到: 判据`;判据必须**可观测**(屏幕上的具体文字、命令输出的具体行、文件/分区是否存在),不允许"确认无误""检查是否正常"这类写法。设计依据统一是[设计文档](design/00-design.md):(设计 8)验收标准、(设计 2)I1-I4、(设计 7)回滚矩阵。

**记录载体**:每台设备把本文件复制一份、就地填写勾选与证据(命令输出、脚本退出码、产物路径),落盘为 `baseline/08-verification.md`(多设备时 `baseline/<设备别名>/08-verification.md`);`baseline/` 全部内容不入库(仅 [baseline/README.md](../baseline/README.md) 例外),命名规范见该文件。

**判定侧与脚本(两侧各跑一遍)**:总控是**执行器**——只做只读判定与汇总,绝不执行任何 `--apply`:

- Kubuntu 侧:`scripts/linux/verify-all.sh [--check|--apply] [--out-dir <目录>] [--confirm-manual]`
- Windows 侧:`scripts/windows/verify-all.ps1 [-Check|-Apply] [-BaselineDir <目录>] [-OutDir <目录>] [-ConfirmManual]`

能自动的项由脚本判定(下表条式末尾标 `脚本判定`),不能自动的由脚本输出 `需人工` 并给手动核对步骤(标 `需人工`,提示写在条式里)。`--check`/`-Check` 只打印(零写);`--apply`/`-Apply` 才把汇总写到 `baseline/08-verification.md`(汇总含「已知例外」表与结论行,失败项带编号与关联卡)。两侧都跑时用 `--out-dir`/`-OutDir` 指向两个不同目录,再把两份汇总人工合并为填写版(避免互相覆盖)。**注意同名覆盖**:两个总控的**默认汇总落点就是 `baseline/08-verification.md`**,与上面那份「人填写的设备勾选版」同名——不带参数落汇总会把填写版直接盖掉。因此落汇总时**必须显式用 `--out-dir`/`-OutDir` 指到填写版之外的目录**(例如 `baseline/auto/` 或临时目录),再人工合并;填写版自身只手工维护。人工项默认让退出码为 2;执行人按清单逐条核对完成后加 `--confirm-manual`/`-ConfirmManual`,人工项记为「需人工(已确认)」并不再计入退出码。

**执行顺序建议**:A -> B -> C -> F -> D -> E。D 组含"真做一次退役"与"真做一次原地重装",做完这台设备上可能已没有 Linux 或已被格式化,必须排最后(F 组要在 D 组真做之前完成);E 组是归档收尾。**验收期间不改分区表、不改固件设置**(设计 I4)。

### A. 引导安全组(A1-A8)

- [ ] A1 默认启动项仍是 Windows Boot Manager -> 看到:Windows 管理员会话 `bcdedit /enum firmware` 的 `displayorder` 首位是 `{bootmgr}`(或 live 内 `sudo efibootmgr -v` 的 `BootOrder` 首位描述为 Windows Boot Manager),与 `baseline/02-firmware-entries.txt` 逐字一致(脚本判定;设计 I1)
- [ ] A2 连续重启 3 次都默认进 Windows -> 看到:3 次都不按键、不选菜单,每次都自动进 Windows,全程不出现 `grub>` / `grub rescue>`(需人工)
- [ ] A3 `\EFI\Microsoft\` 与 L2 基线逐文件一致 -> 看到:`scripts/windows/verify-baseline.ps1 -BaselineDir baseline` 的 ② 行是「通过」(`\EFI\Microsoft\` 逐文件哈希一致、ESP 上无新增文件)(脚本判定;Windows 侧;设计 I3)
- [ ] A4 `{bootmgr}` 的 `path` 与基线一致 -> 看到:同一巡检的 ③ 行是「通过」,`path` 与 `baseline/02-firmware-entries.txt` 逐字一致(脚本判定;Windows 侧;设计 I3)
- [ ] A5 ubuntu 条目位于 `BootOrder` 末尾 -> 看到:`efibootmgr -v` 的 `BootOrder` 最后一项指向 `\EFI\ubuntu\shimx64.efi`;固件条目表里没有任何 Linux 条目排在 Windows Boot Manager 之前(脚本判定;设计 I1)
- [ ] A6 全程未使用 `efibootmgr -o` -> 看到:全部执行记录里没有 `efibootmgr -o` / `bcdedit /set {fwbootmgr} displayorder` 的实执行,进 Linux 一律走一次性入口(需人工;设计 I2)
- [ ] A7 两个 ESP 互不干扰 -> 看到:在 Kubuntu 侧任何引导相关操作之后,`\EFI\Microsoft\` 仍与基线逐文件一致(A3 通过)、`BootOrder` 首位仍是 Windows Boot Manager(A1 通过),且两块 ESP 可分别挂载、`\EFI\ubuntu\` 与 `\EFI\Microsoft\` 各自内容完整(脚本判定;涉及两块 ESP 的实测由 `scripts/linux/verify-l3.sh --check` 承担)
- [ ] A8 可撤除性演练(参考设备必做,其他设备推荐) -> 看到:另存 `\EFI\ubuntu\` 后删除该子树,连续重启 3 次都自动进 Windows 且无 `grub rescue`;用副本还原(或 live chroot 重建)后 A1/A3/A4/A5 复检仍通过(需人工)

脚本:BootOrder 与两块 ESP 的内容由两脚本各自判定(A1/A5/A7);A3/A4 由 Windows 侧的基线巡检判定,在 Kubuntu 侧记 `需人工`;A2/A6/A8 无脚本(人工)。

这组全绿才可以进下一步

### B. 系统功能组(B1-B11)

- [ ] B1 会话类型为 Wayland 且无 X11 会话可选 -> 看到:`echo $XDG_SESSION_TYPE` 输出 `wayland`;登录界面的会话列表里没有 X11/Xorg 会话(脚本判定)
- [ ] B2 GPU 驱动状态正常或有 nouveau 兜底,且无签名拒绝日志 -> 看到:`lsmod` 有 `nvidia`(或明确记录"回退 nouveau 兜底"的偏差),`modinfo -F signer nvidia` 非空,`dmesg` 无 "key was rejected" / "module verification failed"(脚本判定)
- [ ] B3 Secure Boot 保持开启且未引入自签密钥 -> 看到:`mokutil --sb-state` 输出 `SecureBoot enabled`;记录里没有自签密钥、没有关闭过 Secure Boot、没有为驱动做过 DKMS(脚本判定)
- [ ] B4 共享数据分区以 `ntfs3` 读写挂载成功且带 `nofail` -> 看到:`findmnt /mnt/shared` 的文件系统为 `ntfs3`、挂载选项含 `rw` 与 `nofail`;写测试文件后根目录无残留(脚本判定)
- [ ] B5 显卡驱动来源为 Ubuntu 官方包 -> 看到:`ubuntu-drivers devices` 的推荐驱动行与实装驱动一致;`modinfo -F signer nvidia` 的签名者非空(来自官方预签名包);`apt policy nvidia-driver-<版本>` 的候选来自 Ubuntu 归档,记录里没有任何自签或第三方驱动源(脚本判定;设计 04 第 2 节 D3)
- [ ] B6 snap 零残留 -> 看到:`snap list` 为空或 snap 命令不存在;`dpkg -l snapd` 无输出;`apt-cache policy snapd` 无候选或被 pin 到 -1;`apt-get install -s firefox` 的模拟输出不含 snapd(脚本判定;设计 04 第 3 节)
- [ ] B7 跨系统双向可见性一致 -> 看到:Windows 写 `D:\Shared\dbk-verify-win.txt` 后 Kubuntu 能读到逐字相同的内容(含中文与换行);反向再测一次,两侧标记文件测完删除(需人工)
- [ ] B8 家目录重定向生效 -> 看到:`xdg-user-dir` 六项(桌面/文档/下载/图片/视频/音乐)都指向 `/mnt/shared/...`;Windows 侧 `User Shell Folders` 六项都指向 `D:\...`;`~/.config`、`~/.ssh`、代码仓库仍在本地 root(脚本判定;Windows 侧六项需人工核对)
- [ ] B9 时间口径正确(`RTC in local TZ: no`) -> 看到:`timedatectl` 输出 `RTC in local TZ: no`;切到 Windows 复核两系统时间差在分钟级内(离线设备只判 `RTC in local TZ: no`)(脚本判定)
- [ ] B10 切换系统后蓝牙无需重新配对 -> 看到:同一台蓝牙设备在 Windows/Kubuntu 三趟往返里都能直接连接,不需要重新进配对模式(需人工)
- [ ] B11 `fwupd` 能识别设备 -> 看到:`fwupdmgr get-devices` 至少列出一项本机固件设备(如 UEFI 系统固件、NVMe SSD)及当前版本(脚本判定)

脚本:Kubuntu 侧由 `scripts/linux/verify-all.sh` 判定 B1-B6、B8、B9、B11(B2 复用 `scripts/linux/check-signature.sh --check`、B6 复用 `scripts/linux/step-snap-free.sh --check`),Windows 侧对 B1-B6、B8-B11 记 `需人工`;B7、B10 两侧都记 `需人工`。

这组全绿才可以进下一步

### C. 双系统切换组(C1-C3)

- [ ] C1 从 Windows 用一次性 BootNext(或厂商菜单键)进 Linux -> 看到:重启进入 Kubuntu;`scripts/windows/set-bootnext.ps1 -Apply -Yes` 退出码为 0(它自带"执行后 `BootOrder` 首位仍是 Windows Boot Manager"的断言;缺 `-Yes` 会以用法错误 64 退出且零写)(需人工)
- [ ] C2 一次性入口不改变下次默认启动项 -> 看到:用掉后再重启一次、不按任何键,自动回到 Windows;`bcdedit /enum {fwbootmgr}` 的 `displayorder` 与 `baseline/02-firmware-entries.txt` 逐字一致(需人工)
- [ ] C3 切换 3 次后 A 组首项检查仍成立 -> 看到:完成 3 轮 Windows -> Kubuntu -> Windows 之后重跑 A1/A3/A4(必要时加 A5)全部通过,3 轮里没有出现 `grub>` / `grub rescue>`(需人工)

脚本:本组必须实机切换,两侧都记 `需人工`;可复用的只读判定是 `set-bootnext.ps1 -Check`(带 `BootOrder` 断言)与 A 组复检。

这组全绿才可以进下一步

### D. 可撤除性组(D1-D6)

- [ ] D1 按 L5 五步顺序完整推演(参考设备真做一次) -> 看到:`07-9` -> `07-10` -> `07-11` -> `07-12` 按顺序勾完(第 5 步扩容可选),没有"先格式化 Linux 分区再修引导"这类跳序;走偏差分支时三段次序也写进备注(需人工)
- [ ] D2 结束后固件条目与实际状态一致 -> 看到:`efibootmgr -v` / `bcdedit /enum firmware` 里没有指向已删引导文件的残留条目,`BootOrder` 首位仍是 Windows Boot Manager(需人工)
- [ ] D3 系统盘隔离生效 -> 看到:Windows 侧逐项核对,六个已知文件夹(桌面/文档/下载/图片/视频/音乐)与游戏库都在 `D:`;`C:\Users\<用户名>` 下这些目录只是空壳或联接,`C:` 不含用户数据(需人工)
- [ ] D4 原地重装两法可用(参考设备至少真做一法) -> 看到:办法一(只格式化 `C:`)与办法二(只格式化 root)各完整推演一轮;只格 root 时 ESP 的"格式化"勾选**未被勾上**、`D:` 与 Windows 各分区未动(需人工)
- [ ] D5 重装后 A 组四条不变量复检通过 -> 看到:重跑 A1/A3/A4/A5 均通过;刚做过 D4 真做或 D6 时,`\EFI\Microsoft\` 与基线清单里 `bootmgfw.efi`/`BCD` 的差异按"预期差异"口径判读(需人工)
- [ ] D6 非重装逃生路径可用 -> 看到:从 `baseline/02-esp-backup/` 还原 `\EFI\Microsoft\` 并 `bcdboot` 重建后 Windows 能正常启动,`{bootmgr}` 的 `path` 与基线一致;"引导层损坏不要重装"这条路径确实走得通(需人工)

脚本:本组要动手退役/重装,两侧都记 `需人工`;相关脚本(退役五步与基线还原)在 `07-rescue.md` 的对应卡里。

这组全绿才可以进下一步

### E. 记录组(E1-E5)

- [ ] E1 `baseline/` 产物齐全且可读 -> 看到:十一件在位且内容为本次实测而非模板文字——`00-firmware.md`、`01-partitions.txt`、`01-activation.md`、`02-preflight-report.md`(结论行为「允许进入 L3」)、`02-esp-backup/manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt`、`03-efi-layout.txt`、`04-first-boot.md`、`04-robustness.md`、本文件的填写版(脚本判定)
- [ ] E2 `baseline/` 未入库 -> 看到:`git status --porcelain` 不含任何 `baseline/` 条目;`git ls-files baseline/` 只列出 `baseline/README.md`;`git check-ignore -v baseline/02-partitions.txt` 命中 `.gitignore` 的 `baseline/*` 规则(脚本判定)
- [ ] E3 本次与设备参数表的偏差已回写 -> 看到:每条偏差都有明确归属——设备级(分区偏移/UUID/实测容量)进 `baseline/`,方案级(固件只认第一块盘、WinRE 占用预留等)进 [00 入口](00-overview.md) 的偏离项处置表;没有只记在口头或聊天里的偏差(需人工)
- [ ] E4 已知例外在案 -> 看到:每个未勾选项都在汇总的「已知例外」表里有条目、原因、影响面、是否阻塞"参考实现"判定、后续动作;确实没有例外时该表保留「(无)」(需人工)
- [ ] E5 参考实现判定 -> 看到:至少一台设备 A-F 全绿(或未勾选项都在 E4 里有在案例外且不阻塞判定);未达到时明确写出"当前设备非参考实现"及其缺口(需人工)

脚本:E1 与 E2 由两侧总控自动判定(核对 `baseline/` 产物清单、`git status` 与 `git ls-files`);E3-E5 由执行人填写,总控只在汇总里留出「已知例外」表。

这组全绿才可以进下一步

### F. 健壮性组(F1-F9)

- [ ] F1 包级回退演练 + 原地重装演练(参考设备必做) -> 看到:**真做一次**:按 `05-9` 把某个包降到旧版本并 `apt-mark hold`,重启后该软件可用,再 `--unhold` 回到仓库版本;并按 `07-4` 或 `07-5` 完整推演一次原地重装(只格 `C:` 或只格 root),确认 `D:` 上的数据与 `~` 下要留的文件在重装前后哈希不变(需人工)
- [ ] F2 包级回退可用 -> 看到:`bash scripts/linux/rollback-pkg.sh --list <包名>` 能列出该包的可用版本;`bash scripts/linux/rollback-pkg.sh --check` 能读出已 `apt-mark hold` 的包清单与 apt 历史摘要(脚本判定)
- [ ] F3 变更前备份与留档可用 -> 看到:`baseline/` 与 `/etc` 关键文件都能按 `05-9` 与 `05-13` 的口径备份(`.dbk.bak` 存在),apt pin 与 Mozilla 源文件内容在升级前能写进日志留档(脚本判定)
- [ ] F4 崩溃可观测 -> 看到:`/var/log/journal` 存在;`journalctl --list-boots` 至少列出两条;重启后 `journalctl -b -1` 仍能读到上一次启动的日志行(脚本判定)
- [ ] F5 更新策略 -> 看到:apt 配置片段含 `Automatic-Reboot "false"`,且 `Allowed-Origins` 只列 `-security`;`systemctl is-enabled unattended-upgrades` 为 `enabled`(脚本判定;复用 `scripts/linux/set-updates.sh --check`)
- [ ] F6 远程救援通道 -> 看到:`systemctl is-active sshd` 为 `active`;从另一台机器能 SSH 登录,且**不依赖**目标机已登录桌面会话(脚本判定;能否从另一台机器连上需人工确认)
- [ ] F7 OOM 防护 -> 看到:`systemctl is-active systemd-oomd` 为 `active`;`zramctl` 有 `/dev/zram0`,大小约 `min(RAM/2, 8GiB)`(脚本判定)
- [ ] F8 磁盘健康 -> 看到:`systemctl is-active smartd` 为 `active`;`smartctl -H <DISK>` 报 `SMART overall-health self-assessment test result: PASSED`(脚本判定)
- [ ] F9 挂载稳健 -> 看到:`awk '!/^[[:space:]]*#/ && NF>=4 && $2!="/" {print $2, $4}' /etc/fstab` 逐行核对——L4 写入的共享盘行与 swapfile 行都带 `nofail`;`/boot/efi` 属必需挂载,**不加** `nofail`;`findmnt --verify` 不报 error(脚本判定)

脚本:Kubuntu 侧由 `scripts/linux/verify-all.sh` 判定 F2-F9(F5 复用 `scripts/linux/set-updates.sh --check`,F2 复用 `scripts/linux/rollback-pkg.sh --check`);F1 是"真做一次"的演练,两侧都记 `需人工`。

这组全绿才可以进下一步

## 验证

- **逐组按勾选判定**:A、B、C、D、E、F 六组各自"全勾"即该组通过;六组全通过且 E4 的例外清单核对无误,该设备验收通过。
- **通过定义**(逐字保留,来源:(设计 8)):任一组存在未勾选项且无在案记录的"已知例外" → 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。
- **结论落盘**:在 `baseline/08-verification.md` 末尾写四行——① 六组逐组结论(A-F:通过/未通过);② 已知例外条数与编号;③ 参考实现判定(是/否,否的话列出缺口);④ 验收日期与执行人。机器汇总本身以"结论: 通过|待人工|不通过"收尾,两者一并留档。
- **逐项判据优先于整体退出码**:总控退出码 0/1/2 只作参考(2 = 还有人工项未确认);`verify-baseline.ps1` 的退出码 1 也可能只来自 BitLocker 状态这一项的预期差异——判据看 ① ② ③ 三个逐项行,不是看整体退出码。
- **维持条件(不属于勾选范围)**:每次 Windows 大版本更新或累积更新之后,按 `07-7` 重跑四项巡检;验收通过不等于永久通过。
- **文档自检**:本文件改动后运行 `bash scripts/repo/check-docs.sh docs/08-verification.md`,期望 `check-docs: OK`;同时 `git status --porcelain` 里不得出现 `baseline/` 条目。

## 未通过怎么办

任一组出现未勾选项时,**停手**做三件事,不要靠"装完了"往前推:

1. **A 组不过**:先进固件设置界面把 `BootOrder` 首位设回 Windows Boot Manager(设计 I1),**不得**改用 `efibootmgr -o`(I2);引导本身有问题按 `07-rescue.md` 分类处置。
2. **B/C/F 组不过**:按对应卡的 `出错时:` 走;`fstab`/家目录/驱动这类改动都可逆,先回退到上一状态再做变更(回退动作见 [checklists/rollback.md](../checklists/rollback.md))。
3. **D 组不过或中途反悔**:退役/重装的不可逆项动手前先做一次基线备份(`07-10`);只想停用 Linux 而不删,走 `07-13` 的变体。

每一项的"怎么做"命令都能在本次设备上复跑并得到同一结论;证据(命令输出、脚本退出码、产物路径)与勾选一并写进 `baseline/08-verification.md`。
