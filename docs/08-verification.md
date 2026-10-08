# 验收:唯一判据与 A-G 七组勾选卡

本文件在流程中的位置:上一份 `07-rescue.md` -> 本份 -> 下一份 `10-faq.md`

**本文档是唯一判据:不以"装完了"为准,以"清单勾完"为准。** 每组一张勾选卡,条式为 `- [ ] 动作 -> 看到: 判据`;判据必须**可观测**(屏幕上的具体文字、命令输出的具体行、文件/分区是否存在),不允许"确认无误""检查是否正常"这类写法。设计依据统一是[设计文档](design/00-design.md):(设计 8)验收标准、(设计 2)I1-I4、(设计 7)回滚矩阵。

**记录载体**:每台设备把本文件复制一份、就地填写勾选与证据(命令输出、脚本退出码、产物路径),落盘为 `baseline/08-verification.md`(多设备时 `baseline/<设备别名>/08-verification.md`);`baseline/` 全部内容不入库(仅 [baseline/README.md](../baseline/README.md) 例外),命名规范见该文件。

**条目的唯一真源 = `scripts/verification-items.tsv`**(制表符分隔、LF;列 = 编号 / 组 / 卡 / 侧(L\|W\|B) / 判定脚本(`-` 表示需人工) / 判定参数 / 标签)。两侧总控都只读它,不再各写一份;本文件的勾选卡是它的**人读视图**,`check-docs` 会逐条比对两边(编号集合不一致即 FAIL)。表读不到时必须报错退 64、**禁止回退到硬编码条目**(用 `DBK_ITEMS_TSV` / `-ItemsTsv` 指向另一张表即可整体替换,夹具用它验这一点)。

**判定侧与脚本(两侧各跑一遍)**:总控是**执行器**——只做只读判定与汇总,绝不执行任何 `--apply`:

- Fedora 侧:`scripts/linux/verify-all.sh [--check|--apply] [--out-dir <目录>] [--confirm-manual]`
- Windows 侧:`scripts/windows/verify-all.ps1 [-Check|-Apply] [-BaselineDir <目录>] [-OutDir <目录>] [-ConfirmManual]`

能自动的项由脚本判定(下表条式末尾标 `脚本判定`),不能自动的由脚本输出 `需人工` 并给手动核对步骤(标 `需人工`,提示写在条式里)。**自动化覆盖的侧别**(两侧合计 48 项中的 26 项有自动判定):Fedora 侧 `scripts/linux/verify-all.sh` 自动判定 **A1 / A5 / A7 / B1 / B2 / B3 / B4 / B5 / B6 / B8 / B9 / B11 / E1 / E2 / F2 / F4 / F5 / F6 / F7 / F8 / F9 / G1 / G2 / G3**;Windows 侧 `scripts/windows/verify-all.ps1` 自动判定 **A1 / A3 / A4 / A5 / A7 / E1 / E2**;其余按「需人工」登记。`--check`/`-Check` 只打印(零写);`--apply`/`-Apply` 才把汇总写到缺省落点 `<baseline>/auto/08-verification.md`(汇总含「已知例外」表与结论行,失败项带编号与关联卡)。两侧都跑时用 `--out-dir`/`-OutDir` 指向两个不同目录(如 `baseline/auto/win/` 与 `baseline/auto/linux/`),再把两份汇总人工合并进填写版(避免互相覆盖)。**汇总落点(2026-10-04 改)**:两个总控的**缺省汇总落点是 `<baseline>/auto/08-verification.md`**——不再落在人填写版 `baseline/08-verification.md` 上,那份填写版只手工维护;带 `--out-dir`/`-OutDir` 时按参数指到别的目录。人工项默认让退出码为 2;执行人按清单逐条核对完成后加 `--confirm-manual`/`-ConfirmManual`,人工项记为「需人工(已确认)」并不再计入退出码。

**执行顺序建议**:A -> B -> C -> G -> F -> D -> E。G 组是活系统上的配置固化与快照,必须排在 D 组的退役/重装之前(G3 的快照就是重装后回到当前配置的依据);D 组含"真做一次退役"与"真做一次原地重装",做完这台设备上可能已没有 Linux 或已被格式化,必须排最后(F 组要在 D 组真做之前完成);E 组是归档收尾。**验收期间不改分区表、不改固件设置**(设计 I4)。

### A. 引导安全组(A1-A10)

- [ ] A1 默认启动项仍是 Windows Boot Manager -> 看到:Windows 管理员会话 `bcdedit /enum firmware` 的 `displayorder` 首位是 `{bootmgr}`(或 live 内 `sudo efibootmgr -v` 的 `BootOrder` 首位描述为 Windows Boot Manager),与 `baseline/02-firmware-entries.txt` 逐字一致(脚本判定;设计 I1)
- [ ] A2 连续重启 3 次都默认进 Windows -> 看到:3 次都不按键、不选菜单,每次都自动进 Windows,全程不出现 `grub>` / `grub rescue>`(需人工)
- [ ] A3 `\EFI\Microsoft\` 与 L2 基线逐文件一致 -> 看到:`scripts/windows/verify-baseline.ps1 -BaselineDir baseline` 的 ② 行是「通过」(`\EFI\Microsoft\` 逐文件哈希一致、ESP 上无新增文件)(脚本判定;Windows 侧;设计 I3)
- [ ] A4 `{bootmgr}` 的 `path` 与基线一致 -> 看到:同一巡检的 ③ 行是「通过」,`path` 与 `baseline/02-firmware-entries.txt` 逐字一致(脚本判定;Windows 侧;设计 I3)
- [ ] A5 fedora 条目位于 `BootOrder` 末尾 -> 看到:`efibootmgr -v` 的 `BootOrder` 最后一项指向 `\EFI\fedora\shimx64.efi`;固件条目表里没有任何 Linux 条目排在 Windows Boot Manager 之前(脚本判定;设计 I1)。注:清理/匹配类脚本里保留 `ubuntu` 字样属**预期**——为兼容历史固件条目,不是半改名
- [ ] A6 全程未使用 `efibootmgr -o` -> 看到:全部执行记录里没有 `efibootmgr -o` / `bcdedit /set {fwbootmgr} displayorder` 的实执行,进 Linux 一律走一次性入口(需人工;设计 I2)
- [ ] A7 两个 ESP 互不干扰 -> 看到:在 Fedora 侧任何引导相关操作之后,`\EFI\Microsoft\` 仍与基线逐文件一致(A3 通过)、`BootOrder` 首位仍是 Windows Boot Manager(A1 通过),且两块 ESP 可分别挂载、`\EFI\fedora\` 与 `\EFI\Microsoft\` 各自内容完整(脚本判定;涉及两块 ESP 的实测由 `scripts/linux/verify-l3.sh --check` 承担)
- [ ] A8 可撤除性演练(参考设备必做,其他设备推荐) -> 看到:另存 `\EFI\fedora\` 后删除该子树(保留分区),连续重启 3 次都自动进 Windows 且无 `grub rescue`;用副本还原(或 live chroot 重建)后 A1/A3/A4/A5 复检仍通过(需人工)
- [ ] A9 同盘两块 ESP 都被固件识别(设备侧必测;参考设备必做,其他设备推荐) -> 看到:① `sudo efibootmgr -v` 里 Windows Boot Manager(指向 `\EFI\Microsoft\Boot\bootmgfw.efi`)与 fedora 条目(指向 `\EFI\fedora\shimx64.efi`)**两条同时存在**,且 `BootOrder` 首位仍是 Windows Boot Manager;② **分别重启两次**:一次在固件启动菜单里选 fedora(或 `04-1` 的一次性入口)能进 Silverblue,一次不按键自动进 Windows,两次都不出现 `grub>` / `grub rescue>`;③ 进 Silverblue 后再看一次 `efibootmgr -v`,两条仍在。失败(只认第一个 ESP、fedora 条目不可见或选不中)-> 记偏离项(设计 1.2「机型固件只认第一个 ESP」)并按设计第 10 节走「共用 ESP 分支」:退回 Windows 与 Fedora 共用一个 ESP(**仍保留独立 `/boot`**),I3 改由 `02-esp-backup` 的逐文件备份/还原 + `07-6` 演练承担(不再由结构保证),补做还原演练后复判 A3/A7(需人工;设计 3.20 事实表、第 9 节第 30 条)
- [ ] A10 Anaconda 在已有 Windows ESP 的盘上装成功(参考设备必测) -> 看到:L3 前置核对 `bash scripts/linux/check-partition-plan.sh --track D --check` 报 PASS(它断言 Windows ESP 未被挂载、尺寸仍是 2048MiB);Anaconda 的手动分区页里只给 Fedora 三块指定挂载点并勾格式化,Windows 各分区一律未挂载、未格式化;安装连续走完且把引导写到 `\EFI\fedora\`(没有停在 `Failed to set new efi boot target`),装完 `bash scripts/linux/verify-l3.sh --check` 报 PASS。失败(上游 `fedora-silverblue/issue-tracker#284` 的形态,**截至 2026-09 仍开**) -> **不要重装、不要就地重排分区表**:先按 `07-1` 判层,再进 `07-rescue.md` 的 live 环境手工修(`ostree admin status` 核对 + `grub2-mkconfig -o /boot/grub2/grub.cfg` + 必要时 `efibootmgr -c` 补条目并断言 `BootOrder` 首位仍是 Windows),最坏退回轨道 W(Windows 单系统;L2 基线可用,损失可控)(需人工;设计 4.4 的已知风险路径)

脚本:BootOrder 与两块 ESP 的内容由两脚本各自判定(A1/A5/A7);A3/A4 由 Windows 侧的基线巡检判定,在 Fedora 侧记 `需人工`;A2/A6/A8/A9/A10 无脚本(人工)。

这组全绿才可以进下一步

### B. 系统功能组(B1-B11)

- [ ] B1 会话类型为 Wayland 且无 X11 会话可选 -> 看到:`echo $XDG_SESSION_TYPE` 输出 `wayland`;登录界面的会话列表里没有 X11/Xorg 会话(脚本判定)
- [ ] B2 GPU 驱动状态正常或有 nouveau 兜底,且无签名拒绝日志 -> 看到:`lsmod` 有 `nvidia`(或明确记录"回退 nouveau 兜底"的偏差),`modinfo -F signer nvidia` 非空,`dmesg` 无 "key was rejected" / "module verification failed"(脚本判定;复用 `scripts/linux/check-signature.sh --check`)
- [ ] B3 Secure Boot 保持开启且未引入自签密钥 -> 看到:`mokutil --sb-state` 输出 `SecureBoot enabled`;记录里没有自签密钥、没有关闭过 Secure Boot(脚本判定)
- [ ] B4 共享数据分区以 `ntfs3` 读写挂载成功且带 `nofail` -> 看到:`findmnt /mnt/shared` 的文件系统为 `ntfs3`、挂载选项含 `rw` 与 `nofail`;写测试文件后根目录无残留(脚本判定)
- [ ] B5 显卡来源为 ublue 预签名 NVIDIA 变体 -> 看到:`sudo rpm-ostree status` 显示的目标镜像与 `05-3` 指定的 ublue 镜像/分支一致、`layered packages` 与计划一致;`modinfo -F signer nvidia` 的签名者非空(来自镜像内预签名模块);记录里没有任何自签或第三方驱动源(脚本判定;设计 06 第 2 节 D3)
- [ ] B6 Secure Boot 密钥已注册(ublue 一次性 MOK 注册) -> 看到:`mokutil --list-enrolled` 含 ublue 的密钥(`05-3` 的 MOK 注册已完成);`modinfo -F signer nvidia` 与 `mokutil --sb-state` 两项同时成立(脚本判定;设计 02 第 3 节)
- [ ] B7 跨系统双向可见性一致 -> 看到:Windows 写 `D:\Shared\dbk-verify-win.txt` 后 Fedora 能读到逐字相同的内容(含中文与换行);反向再测一次,两侧标记文件测完删除(需人工)
- [ ] B8 家目录重定向生效 -> 看到:`xdg-user-dir` 六项(桌面/文档/下载/图片/视频/音乐)都指向 `/mnt/shared/...`;Windows 侧 `User Shell Folders` 六项都指向 `D:\...`;`~/.config`、`~/.ssh`、代码仓库仍在本地 root(脚本判定;Windows 侧六项需人工核对)
- [ ] B9 时间口径正确(`RTC in local TZ: no`) -> 看到:`timedatectl` 输出 `RTC in local TZ: no`;切到 Windows 复核两系统时间差在分钟级内(离线设备只判 `RTC in local TZ: no`)(脚本判定)
- [ ] B10 切换系统后蓝牙无需重新配对 -> 看到:同一台蓝牙设备在 Windows/Fedora 三趟往返里都能直接连接,不需要重新进配对模式(需人工)
- [ ] B11 `fwupd` 能识别设备 -> 看到:`fwupdmgr get-devices` 至少列出一项本机固件设备(如 UEFI 系统固件、NVMe SSD)及当前版本(脚本判定)

脚本:Fedora 侧由 `scripts/linux/verify-all.sh` 判定 B1-B6、B8、B9、B11(B2 复用 `scripts/linux/check-signature.sh --check`、B5 复用 `scripts/linux/graphics.sh --check`),Windows 侧对 B1-B6、B8-B11 记 `需人工`;B7、B10 两侧都记 `需人工`。

这组全绿才可以进下一步

### C. 双系统切换组(C1-C3)

- [ ] C1 从 Windows 用一次性 BootNext(或厂商菜单键)进 Linux -> 看到:重启进入 Fedora;`scripts/windows/set-bootnext.ps1 -Apply -Yes` 退出码为 0(它自带"执行后 `BootOrder` 首位仍是 Windows Boot Manager"的断言;缺 `-Yes` 会以用法错误 64 退出且零写)(需人工)
- [ ] C2 一次性入口不改变下次默认启动项 -> 看到:用掉后再重启一次、不按任何键,自动回到 Windows;`bcdedit /enum {fwbootmgr}` 的 `displayorder` 与 `baseline/02-firmware-entries.txt` 逐字一致(需人工)
- [ ] C3 切换 3 次后 A 组首项检查仍成立 -> 看到:完成 3 轮 Windows -> Fedora -> Windows 之后重跑 A1/A3/A4(必要时加 A5)全部通过,3 轮里没有出现 `grub>` / `grub rescue>`(需人工)

脚本:本组必须实机切换,两侧都记 `需人工`;可复用的只读判定是 `set-bootnext.ps1 -Check`(带 `BootOrder` 断言)与 A 组复检。

这组全绿才可以进下一步

### D. 可撤除性组(D1-D6)

- [ ] D1 按 L5 五步顺序完整推演(参考设备真做一次) -> 看到:`07-9` -> `07-10` -> `07-11` -> `07-12` 按顺序勾完(第 5 步扩容可选),没有"先格式化 Linux 分区再修引导"这类跳序;走偏差分支时三段次序也写进备注(需人工)
- [ ] D2 结束后固件条目与实际状态一致 -> 看到:`efibootmgr -v` / `bcdedit /enum firmware` 里没有指向已删引导文件的残留条目,`BootOrder` 首位仍是 Windows Boot Manager(需人工)
- [ ] D3 系统盘隔离生效 -> 看到:Windows 侧逐项核对,六个已知文件夹(桌面/文档/下载/图片/视频/音乐)与游戏库都在 `D:`;`C:\Users\<用户名>` 下这些目录只是空壳或联接,`C:` 不含用户数据(需人工)
- [ ] D4 原地重装两法可用(参考设备至少真做一法) -> 看到:办法一(只格式化 `C:`)与办法二(只格式化 root)各完整推演一轮;办法二动手前先按 `05-9` 试一次部署回滚(`07-5`);只格 root 时 ESP 的"格式化"勾选**未被勾上**、`D:` 与 Windows 各分区未动(需人工)
- [ ] D5 重装后 A 组四条不变量复检通过 -> 看到:重跑 A1/A3/A4/A5 均通过;刚做过 D4 真做或 D6 时,`\EFI\Microsoft\` 与基线清单里 `bootmgfw.efi`/`BCD` 的差异按"预期差异"口径判读(需人工)
- [ ] D6 非重装逃生路径可用 -> 看到:从 `baseline/02-esp-backup/` 还原 `\EFI\Microsoft\` 并 `bcdboot` 重建后 Windows 能正常启动,`{bootmgr}` 的 `path` 与基线一致;Fedora 侧引导按 `07-6` 文末的两条来源重建;"引导层损坏不要重装"这条路径确实走得通(需人工)

脚本:本组要动手退役/重装,两侧都记 `需人工`;相关脚本(退役五步与基线还原)在 `07-rescue.md` 的对应卡里。

这组全绿才可以进下一步

### E. 记录组(E1-E5)

- [ ] E1 `baseline/` 产物齐全且可读 -> 看到:十一件在位且内容为本次实测而非模板文字——`00-firmware.md`、`01-partitions.txt`、`01-activation.md`、`02-preflight-report.md`(结论行为「允许进入 L3」)、`02-esp-backup/manifest.sha256`、`02-firmware-entries.txt`、`02-partitions.txt`、`03-efi-layout.txt`、`04-first-boot.md`、`04-robustness.md`、本文件的填写版(脚本判定)
- [ ] E2 `baseline/` 未入库 -> 看到:`git status --porcelain` 不含任何 `baseline/` 条目;`git ls-files baseline/` 只列出 `baseline/README.md`;`git check-ignore -v baseline/02-partitions.txt` 命中 `.gitignore` 的 `baseline/*` 规则(脚本判定)
- [ ] E3 本次与设备参数表的偏差已回写 -> 看到:每条偏差都有明确归属——设备级(分区偏移/UUID/实测容量)进 `baseline/`,方案级(固件只认第一块盘、WinRE 占用预留等)进 [00 入口](00-overview.md) 的偏离项处置表;没有只记在口头或聊天里的偏差(需人工)
- [ ] E4 已知例外在案 -> 看到:每个未勾选项都在汇总的「已知例外」表里有条目、原因、影响面、是否阻塞"参考实现"判定、后续动作;确实没有例外时该表保留「(无)」(需人工)
- [ ] E5 参考实现判定 -> 看到:至少一台设备 A-G 全绿(或未勾选项都在 E4 里有在案例外且不阻塞判定);未达到时明确写出"当前设备非参考实现"及其缺口(需人工)

脚本:E1 与 E2 由两侧总控自动判定(E1 在 Windows 侧 `verify-all.ps1` 实现:核对 `baseline/` 十一件产物;E2 查 `git status` / `git ls-files`);E3-E5 由执行人填写,总控只在汇总里留出「已知例外」表。

这组全绿才可以进下一步

### F. 健壮性组(F1-F10)

- [ ] F1 部署回滚演练 + 原地重装演练(参考设备必做) -> 看到:**真做一次**:按 `05-9` 先 `--pin` 固定当前部署,更新或分层一次,再 `rollback-deploy.sh --apply --yes` 回到上一部署,重启后桌面可用、`nvidia` 模块仍加载、`/var` 下的用户数据仍在(`/home` 是 `/var/home` 的符号链接,回滚不回退数据),最后 `--unpin`;并按 `07-4` 或 `07-5` 完整推演一次原地重装(只格 `C:` 或只格 root),确认 `D:` 上的数据与 `~` 下要留的文件在重装前后哈希不变(需人工)
- [ ] F2 部署级回滚可用 -> 看到:`bash scripts/linux/rollback-deploy.sh --check` 能读出部署列表与回滚候选(部署数 ≥ 2,索引 1 = 上一部署);`--pin <索引> --yes` / `--unpin <索引> --yes` 能固定与解除当前部署(脚本判定)
- [ ] F3 变更前备份与留档可用 -> 看到:变更前能按 `05-9` 与 `05-13` 的口径备份 `baseline/` 与 `/etc` 关键文件(`.dbk.bak` 存在),并已 `--pin` 当前部署、把部署号写进日志留档(脚本判定)
- [ ] F4 崩溃可观测 -> 看到:`/var/log/journal` 存在;`journalctl --list-boots` 至少列出两条;重启后 `journalctl -b -1` 仍能读到上一次启动的日志行(脚本判定)
- [ ] F5 更新策略 -> 看到:`/etc/rpm-ostreed.conf` 的 `AutomaticUpdatePolicy` 取值为 `check` 或 `download`(不含"自动应用"与"自动重启"的取值);`systemctl is-enabled rpm-ostreed-automatic.timer` 为 `enabled`(脚本判定;复用 `scripts/linux/set-updates.sh --check`)
- [ ] F6 远程救援通道 -> 看到:`systemctl is-active sshd` 为 `active`;从另一台机器能 SSH 登录,且**不依赖**目标机已登录桌面会话(脚本判定;能否从另一台机器连上需人工确认)
- [ ] F7 OOM 防护 -> 看到:`systemctl is-active systemd-oomd` 为 `active`;`zramctl` 有 `/dev/zram0`,大小约 `min(RAM/2, 8GiB)`(脚本判定)
- [ ] F8 磁盘健康 -> 看到:`systemctl is-active smartd` 为 `active`;`smartctl -H <DISK>` 报 `SMART overall-health self-assessment test result: PASSED`(脚本判定)
- [ ] F9 挂载稳健 -> 看到:`awk '!/^[[:space:]]*#/ && NF>=4 && $2!="/" {print $2, $4}' /etc/fstab` 逐行核对——L4 写入的共享盘行与 swapfile 行(以及独立 `/boot` 行)都带 `nofail`;`/boot/efi` 属必需挂载,**不加** `nofail`;`findmnt --verify` 不报 error(脚本判定)
- [ ] F10 启动失败自动回滚演练(参考设备必做) -> 看到:在 `setup-greenboot.sh` 就位后**故意让健康检查失败**(例如临时把 `/etc/greenboot/check/required.d/60-dbk-health.sh` 改成 `exit 1`),重启两次后自动退回上一部署、桌面可用、`BootOrder` 首位仍是 Windows Boot Manager;随后复原该文件并重跑 `bash scripts/linux/setup-greenboot.sh --check` 复检为绿(需人工;设计 06 第 4 节)

脚本:Fedora 侧由 `scripts/linux/verify-all.sh` 判定 F2、F4–F9(F5 复用 `scripts/linux/set-updates.sh --check`,F2 复用 `scripts/linux/rollback-deploy.sh --check`);**引导器状态不在本组的自动条目内** —— 它由 `07-7` 周期巡检与 `05-7`/`05-10` 的重启前手工跑 `bash scripts/linux/check-bootloader.sh --check`(总控不调它);F1 是"真做一次"的演练,F10 是"故意失败"的回滚演练,两侧都记 `需人工`。

这组全绿才可以进下一步

### G. 体验组(G1-G3)

- [ ] G1 默认应用绑定与清单一致 -> 看到:`sudo bash scripts/linux/set-default-apps.sh --check` 退出码 0,逐行 `mime -> desktop` 与 `templates/mimeapps.tsv` 全对(文件管理器 / PDF / 图片 / 压缩包 / 文本);退出码 2 表示某个应用还没装(先做 `05-17`),退出码 1 才是绑定与清单不符(脚本判定)
- [ ] G2 必需应用在位 -> 看到:`bash scripts/linux/check-apps.sh --check` 退出码 0;清单里每个必需项都在位(Flatpak 查 `flatpak info`、Homebrew 查 `brew list --formula`、原生查 `command -v`);可选行缺失只记一行、不影响结论;每个 Windows 常用软件在清单里都有归属(原生 / Flatpak / 网页 / 回 Windows)(脚本判定)
- [ ] G3 配置快照与现状无漂移 -> 看到:`bash scripts/linux/export-config.sh --check` 退出码 0(五份快照 `dconf.txt` / `etc-config-diff.txt` / `flatpak-apps.txt` / `brew-bundle.txt` / `layered-pkgs.txt` 与现状逐文件一致);退出码 2 = 有漂移或快照缺失,核对差异后重跑 `--apply --yes` 刷新(脚本判定;漂移不是错误,是快照该更新了)

脚本:G1 由 `scripts/linux/set-default-apps.sh --check` 判定;G2 由 `scripts/linux/check-apps.sh --check` 判定;G3 由 `scripts/linux/export-config.sh --check` 判定;Windows 侧总控把三条都按「在 Fedora 侧跑」记入汇总。**回滚不回退 `/etc` 与 `~/.config`**(设计 06 第 4 节),所以 G3 的快照是重装后回到当前配置的唯一依据,必须在 D 组的退役/重装之前落一次。

这组全绿才可以进下一步

## 验证

- **逐组按勾选判定**:A、B、C、D、E、F、G 七组各自"全勾"即该组通过;七组全通过且 E4 的例外清单核对无误,该设备验收通过。
- **通过定义**(逐字保留,来源:(设计 8)):任一组存在未勾选项且无在案记录的"已知例外" → 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。
- **结论落盘**:在 `baseline/08-verification.md` 末尾写四行——① 七组逐组结论(A-G:通过/未通过);② 已知例外条数与编号;③ 参考实现判定(是/否,否的话列出缺口);④ 验收日期与执行人。机器汇总本身以"结论: 通过|待人工|不通过"收尾,两者一并留档。
- **逐项判据优先于整体退出码**:总控退出码 0/1/2 只作参考(2 = 还有人工项未确认);`verify-baseline.ps1` 的退出码 1 也可能只来自 BitLocker 状态这一项的预期差异——判据看 ① ② ③ 三个逐项行,不是看整体退出码。
- **维持条件(不属于勾选范围)**:每次 Windows 大版本更新或累积更新之后,按 `07-7` 重跑四项巡检;验收通过不等于永久通过。
- **文档自检**:本文件改动后运行 `bash scripts/repo/check-docs.sh docs/08-verification.md`,期望 `check-docs: OK`;同时 `git status --porcelain` 里不得出现 `baseline/` 条目。

## 未通过怎么办

任一组出现未勾选项时,**停手**做三件事,不要靠"装完了"往前推:

1. **A 组不过**:先进固件设置界面把 `BootOrder` 首位设回 Windows Boot Manager(设计 I1),**不得**改用 `efibootmgr -o`(I2);引导本身有问题按 `07-rescue.md` 分类处置。**A9 不过**(固件只认一个 ESP)-> 记偏离项并按设计第 10 节走「共用 ESP 分支」,不要反复重装;**A10 不过**(Anaconda 在含 Windows ESP 的盘上中止)-> 不要重装、不要就地重排分区表,按 `07-1` 判层后进 `07-rescue.md` 手工修,最坏退回轨道 W。
2. **B/C/F/G 组不过**:按对应卡的 `出错时:` 走;`fstab`/家目录/驱动这类改动都可逆,先回退到上一状态再做变更(回退动作见 [checklists/rollback.md](../checklists/rollback.md))。
3. **D 组不过或中途反悔**:退役/重装的不可逆项动手前先做一次基线备份(`07-10`);只想停用 Linux 而不删,走 `07-13` 的变体。

每一项的"怎么做"命令都能在本次设备上复跑并得到同一结论;证据(命令输出、脚本退出码、产物路径)与勾选一并写进 `baseline/08-verification.md`。
