# 验收:唯一判据与 A-F 六组清单

本文件是整套方案的**唯一判据**:不以"装完了"为准,只以本清单全绿为准。设计依据是[设计文档](design/00-design.md)第 8 节(验收标准)与第 2 节(I1-I4)、第 3 节(关键决策)、4.7 节(健壮性 R1-R9)、4.8 节(原地重装两法)、7.1 节(周期性巡检)、11.1 节(评论区实战证据);执行依据是已交付手册 [00 入口](00-overview.md)、[L0](01-firmware.md)、[L1](02-windows.md)、[L2](03-preflight.md)、[L3](04-ubuntu.md)、[L4](05-first-boot.md)、[L5 退役](06-decommission.md)、[L5 救援](07-rescue.md)与 [checklists/rollback.md](../checklists/rollback.md)。

**记录载体**:每台设备把本文件复制一份、就地填写勾选与证据,落盘为 `baseline/08-verification.md`(多设备时 `baseline/<设备别名>/08-verification.md`)。产物名前缀 = 所在阶段号;`baseline/` 全部内容不入库(仅 `baseline/README.md` 例外),规则见 [baseline/README.md](../baseline/README.md)。

**执行顺序建议**:A(引导安全)-> B(系统功能)-> C(双系统切换)-> F(健壮性)-> D(可撤除性)-> E(记录归档)。理由:D 组含"真做一次退役"与"真做一次原地重装",做完这台设备上可能已没有 Linux 或已被格式化,所以必须排在最后;E 组是归档,放最后一位。F 组要放在 D 组真做之前,否则快照分区已随退役消失,回滚演练无从谈起。

## 目标

验收后的目标状态:这台设备在 A-F 六组上**逐条勾选通过**,并留下可复核的证据(命令输出、截图或产物文件),证据与勾选一并写入 `baseline/08-verification.md`。

| 组 | 覆盖 | 通过条件 | 设计依据 |
|---|---|---|---|
| **A. 引导安全组** | 默认启动项、Windows 引导未被污染、引导路径未被篡改、四条不变量落地、**可撤除性演练** | A1-A7 全勾 | 第 8 节 A 组、第 2 节 I1-I3 |
| **B. 系统功能组** | Wayland、GPU 与 Secure Boot、共享盘 `ntfs3` 读写与 `nofail`、**跨系统双向可见性**、**家目录重定向生效**、时间口径、蓝牙、`fwupd` | B1-B10 全勾 | 第 8 节 B 组、4.5 节、5.3 节 |
| **C. 双系统切换组** | 从 Windows 一次性进 Linux 且不改默认项、从 Linux 一键回 Windows、切换 3 次后首项检查仍成立 | C1-C4 全勾 | 第 8 节 C 组、I2 |
| **D. 可撤除性组** | L5 五步推演(参考设备真做一次)、系统盘隔离生效、**原地重装两法可用**、非重装逃生路径可用 | D1-D6 全勾 | 第 8 节 D 组、3.15 节、4.8 节 |
| **E. 记录组** | `baseline/` 产物齐全且未入库、偏差回写、已知例外在案、参考实现判定 | E1-E5 全勾 | 第 8 节 E 组、第 6 节 |
| **F. 健壮性组** | 快照可用且**真做一次回滚演练**、`/snapshots` 独立、多内核与 `GRUB_DEFAULT=saved`、journald 持久化、更新策略、SSH 救援、OOM 防护、SMART、`nofail` | F1-F9 全勾 | 第 8 节 F 组、4.7 节 R1-R9、7.1 节 |

**通过定义**(逐字保留,第 8 节):任一组存在未勾选项且无在案记录的"已知例外" → 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。

据此,"未勾选"有两种合法归宿:要么当场补做通过;要么写成**已知例外**(E4),写明原因、影响面与后续动作。**沉默的未勾选项一律按未完成处理。**

## 前置条件

- **L0-L4 已全部收尾**:`baseline/` 产物齐备(L2 报告结论为"允许进入 L3"、L3 的 `03-efi-layout.txt`、L4 的 `04-first-boot.md` 与 `04-robustness.md` 在位);L2 的硬闸门已经过一次复核,见 [L2 手册](03-preflight.md)。
- **设备参数表已填**([00 入口](00-overview.md)的设备参数表):`DISK`、`VENDOR`、`BOOT_MENU_KEY`、`FIRMWARE_MODE`、`GPU`、`ESP_SIZE`、`WINDOWS_SYSTEM_SIZE`、`WINDOWS_DATA_SIZE`、`ROOT_SIZE`、`SNAPSHOT_SIZE`、`SECURE_BOOT`、`DISK_MODEL`、`DISK_SIZE`、`SHARED_PART_UUID`。验收中每一个"与基线/与目标值一致"的判据都要求先有这些取值,不允许现场凭记忆填。其中 `WINDOWS_SYSTEM_SIZE`/`WINDOWS_DATA_SIZE` 是 E3 回写对账的目标值(D3 选盘时也用于辨认 `C:`),缺任一项该条判据无法执行。
- **L2 基线可读**:`baseline/02-esp-backup/manifest.sha256`、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt` 三份都在且能逐行校验;A3/A4/A7、D3/D5/D6 全部依赖它们。
- **脚本在位**(全部 dry-run 优先):
  - Windows 侧:[verify-baseline.ps1](../scripts/windows/verify-baseline.ps1)(周期性巡检,A3/A4)、[set-bootnext.ps1](../scripts/windows/set-bootnext.ps1)(一次性进 Linux,C1)、[backup-esp.ps1](../scripts/windows/backup-esp.ps1)(基线重做时用);
  - Ubuntu 侧:[reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh)(一键回 Windows,C3)、[first-boot.sh](../scripts/linux/first-boot.sh) 及其模块([storage.sh](../scripts/linux/storage.sh)、[hardening.sh](../scripts/linux/hardening.sh)、[mount-shared.sh](../scripts/linux/mount-shared.sh)、[graphics.sh](../scripts/linux/graphics.sh)、[xdg-redirect.sh](../scripts/linux/xdg-redirect.sh))、[bt-keys-sync-wrapper.sh](../scripts/linux/bt-keys-sync-wrapper.sh)(B8)、[dbk-apt.sh](../scripts/linux/dbk-apt.sh) 与 [dbk-log.sh](../scripts/linux/dbk-log.sh)(被 source)。
- **救援介质在位**(R4):L3 用过的 Ubuntu 安装 U 盘保持"已验证可用"且不回收——A7 演练与 D 组推演都可能在"进不去系统"时需要它。
- **回 Windows 的入口可用**(设计第 6 节交接规则第 6 条):`BOOT_MENU_KEY` 或 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1);二者任一可用即可。**任何情况下不得用 `efibootmgr -o` / `displayorder` 调整永久顺序**(I2)。
- **另一台可 SSH 的机器**(用于 F6):F6 要求"从另一台机器 SSH 登录",需要第二台设备与目标机同网段。确无第二台设备时,按 [07-rescue.md](07-rescue.md) 第 8 节用本地 TTY 对照执行,并把"无第二台设备"记为**不阻塞的已知例外**(影响面:只能证明本地登录可用)。
- **时间与重启预算**:本清单包含 A2(连续重启 3 次)、C 组(至少 3 轮双系统切换)、F1(回滚演练)、D 组(退役与重装推演),建议单独安排一次连续会话,**中途不要插入 Windows 更新**(一旦更新,基线即失效,见第 6 节规则 4 与 7.1 节巡检)。
- **逐条执行记录**:本清单按勾选项给出判据,逐条动作用 `checklists/deploy.md` 记录(该清单属 Task 15 交付;交付前以各阶段手册的"验证"节与 [checklists/rollback.md](../checklists/rollback.md) 代替);高频疑问速查见 `docs/10-faq.md`(同为 Task 15 交付)。
- **口径**:验收期间**不改分区表、不改固件设置**;若某项处置确实要动分区表或固件(如 `fstab` 之外的存储设置),先按 I4 重做基线备份再动手(见 [L2 手册](03-preflight.md)的基线生成步骤)。

## 步骤

每一步都是可勾选项。勾选前必须能给出"证据来源"(命令输出、脚本退出码、产物文件路径),证据写进 `baseline/08-verification.md` 的同编号条目。

### A. 引导安全组(A1-A7)

- [ ] **A1 `BootOrder` 首位仍是 Windows Boot Manager**
  - 怎么做:Windows 管理员会话 `bcdedit /enum firmware`(或 live 环境 `sudo efibootmgr -v`);与 `baseline/02-firmware-entries.txt` 对账。
  - 判据:`BootOrder` 第一项对应 `Windows Boot Manager`,与 L2 基线逐字一致;不是 `ubuntu`,也不是 `UEFI OS` 之类条目。
  - 设计依据:第 8 节 A 组第 1 行;**I1**。

- [ ] **A2 连续重启 3 次都默认进 Windows**
  - 怎么做:正常重启 3 次,**每次都不按键、不选菜单**,记录每次进入的系统。
  - 判据:3 次都自动进 Windows,全程不出现 `grub>` / `grub rescue>`,也不需要任何手工选择。
  - 设计依据:第 8 节 A 组第 1 行(后半句)。

- [ ] **A3 `\EFI\Microsoft\` 与 L2 基线逐文件一致**
  - 怎么做:Windows 管理员会话执行 `powershell.exe -ExecutionPolicy Bypass -File scripts\windows\verify-baseline.ps1 -BaselineDir baseline`(见 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1));需要人工核对时再 `mountvol S: /s` 后对比。
  - 判据:输出第 ② 项"通过"(ESP 上的 `\EFI\Microsoft\` 相对 `baseline/02-esp-backup/manifest.sha256` 无差异)。
  - 例外口径:若刚做过 **D6 或 D3 真做**(D6 的基线还原 + `bcdboot`,或 D3 真做时安装器重建 `\EFI\Microsoft\` 与 `BCD`、并可能覆盖 `\EFI\BOOT\bootx64.efi`),`bootmgfw.efi` 与 `BCD` 的差异属**预期**(D6 见 [07-rescue.md](07-rescue.md) 第 2 节第 3 条,D3 见以下 D3 的判据),改判"Windows 能正常启动 + `{bootmgr}` 的 path 与基线一致 + `BootOrder` 首位未变"。D5 复检 A3 时沿用本口径。
  - 设计依据:第 8 节 A 组第 2 行;**I3**。

- [ ] **A4 `{bootmgr}` 的 `path` 与基线一致**
  - 怎么做:`bcdedit /enum {bootmgr}`(或 `bcdedit /enum firmware`);与 `baseline\02-firmware-entries.txt` 里的同名条目对账。
  - 判据:`path` 与基线逐字一致(基线值形如 `\EFI\Microsoft\Boot\bootmgfw.efi`);未被第三方工具改写成 `\EFI\ubuntu\shimx64.efi` 之类。
  - 设计依据:第 8 节 A 组第 3 行;**I3**。

- [ ] **A5 Ubuntu 条目位于 `BootOrder` 末尾**
  - 怎么做:`efibootmgr -v`(live 或 Ubuntu 内)读 `BootOrder` 序列。
  - 判据:`ubuntu`(或厂商固件给出的同义条目,如 `UEFI OS`)位于 `BootOrder` **最后一位**;固件条目表里没有任何 Linux 条目排在 Windows Boot Manager 之前。
  - 设计依据:第 8 节 A 组第 4 行前半;**I1**。

- [ ] **A6 全程未使用 `efibootmgr -o`**
  - 怎么做:复核本次部署的全部操作记录([L2](03-preflight.md)、[L3](04-ubuntu.md)、[L4](05-first-boot.md)、[L5 退役](06-decommission.md)各步骤的执行记录与 `checklists/rollback.md` 备注);辅助检查 `git grep -n 'efibootmgr -o'` 的输出只出现在各文档/脚本的"禁止"表述里。
  - 判据:没有任何一次用 `efibootmgr -o` 或 `bcdedit /set {fwbootmgr} displayorder ...` 调整过永久顺序;进 Linux 全部走一次性入口。
  - 设计依据:第 8 节 A 组第 4 行后半;**I2**。

- [ ] **A7 可撤除性演练(参考设备必做,其他设备推荐)**
  - 步骤(顺次执行,任何一步异常即停下并按"失败处理"处理):
    1. 确认 `baseline/02-esp-backup/`、`baseline/02-firmware-entries.txt` 可读(本组已依赖它们)。
    2. **另存 `\EFI\ubuntu\` 子树**(它不在 L2 基线里,原因见 [07-rescue.md](07-rescue.md) 3.1 节):Windows 管理员会话 `mountvol S: /s` -> `robocopy S:\EFI\ubuntu D:\dbk-verify\efi-ubuntu /E` -> `mountvol S: /d`。判据:`D:\dbk-verify\efi-ubuntu\` 里能看到该发行版实际的引导文件(如 `shimx64.efi`、`grubx64.efi`、`grub.cfg`,文件名以实机为准)。
    3. **删除 `\EFI\ubuntu\` 这一棵子树**,其他一律不动:ESP 分区保留、`\EFI\Microsoft\` 不碰、`ubuntu` 的 NVRAM 条目**故意保留**(本演练要证明的正是"条目指向的引导文件不存在时,固件会继续回落到 `BootOrder` 的下一个条目即 Windows")。
    4. **连续重启 3 次**:判据:每次都自动进 Windows;不出现 `grub>` / `grub rescue>`;不需要任何手工选择;`BootOrder` 首位始终是 Windows Boot Manager(I1 成立)。
    5. **还原**:把第 2 步的副本拷回 `S:\EFI\ubuntu\`;副本损坏或不可用时,改走 live 环境 chroot 重建(`grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu` + `update-grub`,它自建 `ubuntu` 条目;重复条目用 `efibootmgr -b <n> -B` 清理)。两条来源与完整命令见 [07-rescue.md](07-rescue.md) 3.1 节。
    6. **复测**:用一次性 `BootNext`(或 `BOOT_MENU_KEY`)进 Ubuntu 成功;再重启默认回 Windows;A1、A3、A4、A5 复检通过。
  - 判据:演练全程未执行 `efibootmgr -o`;演练后四不变量与演练前一致;整段过程与结果写进 `baseline/08-verification.md`。
  - 不做的设备:在本条写明"未演练"与理由,并按 E4 登记为**已知例外**(推荐设备,不阻塞"参考实现"判定,但参考设备不做即该设备的 A 组不成立)。
  - 设计依据:第 8 节 A 组第 5 行。

### B. 系统功能组(B1-B10)

- [ ] **B1 会话类型为 Wayland 且无 X11 会话可选**
  - 怎么做:Ubuntu 内 `echo $XDG_SESSION_TYPE`;注销回到 GDM 看会话列表;`grep -R 'WaylandEnable' /etc/gdm3/ 2>/dev/null`。
  - 判据:输出 `wayland`;登录界面的会话列表里**没有** "Ubuntu on Xorg" 之类 X11 会话;`custom.conf` 里没有 `WaylandEnable=false`(GNOME 50 为 Wayland-only)。
  - 设计依据:第 8 节 B 组第 1 句、决策 3.1/3.2。

- [ ] **B2 GPU 驱动状态正常或有 nouveau 兜底,且无签名拒绝日志**
  - 怎么做:`lsmod | grep -E '^(nvidia|nouveau)'`;`mokutil --sb-state`;`sudo dmesg | grep -iE 'key was rejected|module verification failed|lockdown'`(可另跑 `bash scripts/linux/graphics.sh` 采集同一组判据)。
  - 判据:仓库预签名 NVIDIA 模块已加载(`nvidia`),**或**明确记录"回退 nouveau 兜底"的偏差(如单显卡设备、驱动与内核不匹配时的已知例外);`dmesg` 无模块签名被拒/锁定相关行。
  - 设计依据:第 8 节 B 组第 2 句、决策 3.3、4.5 节显卡行。

- [ ] **B3 Secure Boot 保持开启且未引入自签密钥**
  - 怎么做:`mokutil --sb-state`;复核部署记录里是否出现过 `mokutil --import`、关闭 Secure Boot、DKMS 编译或 `nvidia-open` 源码构建的动作。
  - 判据:`SecureBoot enabled`;没有自签密钥导入、没有关闭过 Secure Boot、没有为驱动做过 DKMS(决策 3.3)。
  - 设计依据:第 8 节 B 组第 3 句、决策 3.3、4.4 节末句。

- [ ] **B4 共享数据分区以 `ntfs3` 读写挂载成功且带 `nofail`**
  - 怎么做:`findmnt /mnt/shared`;`grep -n ' /mnt/shared ' /etc/fstab`;写测试 `touch /mnt/shared/.dbk-write-test && rm -f /mnt/shared/.dbk-write-test && ls -a /mnt/shared`。
  - 判据:文件系统为 `ntfs3`,挂载选项含 `rw`、`windows_names`、`nofail`(选项集与 [templates/fstab.snippet](../templates/fstab.snippet) 一致);创建与删除都成功,根目录无 `.dbk-write-test` 残留。
  - 设计依据:第 8 节 B 组第 4 句、决策 3.16、5.3 节。

- [ ] **B5 跨系统双向可见性一致**
  - 怎么做(两趟):
    1. Windows 侧写 `D:\Shared\dbk-verify-win.txt`(内容含写入时间与一句原文)-> 重启进 Ubuntu -> `cat /mnt/shared/Shared/dbk-verify-win.txt`。
    2. Ubuntu 侧写 `/mnt/shared/Shared/dbk-verify-linux.txt` -> 重启进 Windows -> 打开 `D:\Shared\dbk-verify-linux.txt` 读取。
  - 判据:两次内容都逐字一致(含中文与换行),无乱码、无长度截断;测完两侧删除标记文件,`ls -a /mnt/shared/Shared` 无残留。
  - 设计依据:第 8 节 B 组第 5 句、5.3 节"验收"段。

- [ ] **B6 家目录重定向生效(文档/下载/图片/桌面等指向共享盘)**
  - 怎么做:Ubuntu 侧 `for k in DESKTOP DOCUMENTS DOWNLOAD PICTURES VIDEOS MUSIC; do echo "$k=$(xdg-user-dir $k)"; done`;Windows 侧 `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"`。
  - 判据:Linux 六项分别指向 `/mnt/shared/{Desktop,Documents,Downloads,Pictures,Videos,Music}`;Windows 侧对应项指向 `D:\Desktop`、`D:\Documents`、`D:\Downloads`、`D:\Pictures`、`D:\Videos`、`D:\Music`;`~/.config`、`~/.ssh` 与代码仓库仍在本地 root(共享盘上不存在它们的副本)。
  - 设计依据:第 8 节 B 组第 6 句、决策 3.15/3.16、4.5 节重定向行。

- [ ] **B7 时间口径正确(`RTC in local TZ: no`)**
  - 怎么做:Ubuntu 侧 `timedatectl`;切到 Windows 复核系统时间。
  - 判据:`RTC in local TZ: no`、`System clock synchronized: yes`;两系统显示的时间差在分钟级内(切换系统后各看一次)。**离线设备(无 NTP 可达)只判 `RTC in local TZ: no`**,`System clock synchronized: no` 不算失败,记入已知例外。
  - 设计依据:第 8 节 B 组第 7 句、4.5 节时间行。

- [ ] **B8 切换系统后蓝牙无需重新配对**
  - 怎么做:在 Ubuntu 连接一台已配对设备(如鼠标/耳机)-> 重启进 Windows 连接同一台设备 -> 回 Ubuntu 再次连接;`bluetoothctl devices` 与 `bluetoothctl info <MAC>` 查配对状态;密钥同步脚本见 [bt-keys-sync-wrapper.sh](../scripts/linux/bt-keys-sync-wrapper.sh) 与 [L4 手册](05-first-boot.md)步骤 5。
  - 判据:同一台设备在三个来回里都能**直接连接**,不需要重新进入配对模式;同步结论(以 Windows 侧密钥为准)已记入 `baseline/04-first-boot.md`。
  - 设计依据:第 8 节 B 组第 8 句、4.5 节蓝牙行、设计 11 节 `bt-keys-sync`。

- [ ] **B9 `fwupd` 能识别设备**
  - 怎么做:`fwupdmgr get-devices`(可先 `fwupdmgr refresh`)。
  - 判据:至少列出一项本机固件设备(如 UEFI 系统固件、NVMe SSD),并给出当前版本。
  - 口径:只要求"识别",不要求有更新可装;LVFS 侧版本可能落后 Windows 侧固件(设计 11 节)。`fwupdmgr refresh` 因网络/镜像不可达而失败时,不判失败,记已知例外。
  - 设计依据:第 8 节 B 组第 9 句、4.5 节固件行。

- [ ] **B10 无残留的临时排障参数**
  - 怎么做:`cat /proc/cmdline`;`grep -R 'nomodeset' /etc/default/grub /etc/default/grub.d/ 2>/dev/null`;`grep -E '^GRUB_TERMINAL' /etc/default/grub`。
  - 判据:`/proc/cmdline` 与 GRUB 配置里**没有** `nomodeset`(它只允许作为 L3 应急手段,装好驱动后必须移除);`GRUB_TERMINAL=console` 只在"引导菜单阶段黑屏"真实发生时才允许打开(决策 3.19),未发生时保持注释。
  - 设计依据:11.1 节第 2 条、决策 3.19、第 8 节 B 组第 1-2 句(Wayland 与 KMS 的关系)。

### C. 双系统切换组(C1-C4)

- [ ] **C1 从 Windows 用一次性 BootNext(或厂商菜单键)进 Linux**
  - 怎么做(二选一,推荐先用脚本演练一次):
    - 脚本:`powershell.exe -ExecutionPolicy Bypass -File scripts\windows\set-bootnext.ps1 -WhatIf` 看计划 -> 去掉 `-WhatIf` 执行 -> 重启;
    - 或固件菜单:开机按 `BOOT_MENU_KEY`(见 [L0 手册](01-firmware.md)厂商差异表)选一次 `ubuntu`。
  - 判据:重启进入 Ubuntu;脚本路径下退出码为 0(脚本自带"执行后 `BootOrder` 首位仍是 Windows Boot Manager"的断言,见 [set-bootnext.ps1](../scripts/windows/set-bootnext.ps1))。
  - 设计依据:第 8 节 C 组第 1 句、I2。

- [ ] **C2 一次性入口不改变下次默认启动项**
  - 怎么做:上一步用掉后**再重启一次**,不按任何键。
  - 判据:自动回到 Windows(BootNext 用过即消失的一次性语义);`bcdedit /enum {fwbootmgr}` 的 `displayorder` 与 `baseline\02-firmware-entries.txt` 里记录的 `BootOrder` **逐字一致**。
  - 设计依据:第 8 节 C 组第 1 句"且不改变下次默认启动项"、I2。

- [ ] **C3 从 Linux 一键回 Windows**
  - 怎么做:Ubuntu 内 `sudo scripts/linux/reboot-to-windows.sh --apply`(默认 dry-run,先不加 `--apply` 看计划)-> 按脚本提示手工 `systemctl reboot`。
  - 判据:重启进入 Windows;脚本退出码为 0(它在执行前后各读一次 `BootOrder` 并断言逐字未变,见 [reboot-to-windows.sh](../scripts/linux/reboot-to-windows.sh));全程未用 `efibootmgr -o`。
  - 设计依据:第 8 节 C 组第 2 句、4.5 节"回 Windows"行。

- [ ] **C4 切换 3 次后 A 组首项检查仍成立**
  - 怎么做:完成 3 轮"Windows -> Linux -> Windows"(C1/C3 交替),然后重跑 A1、A3、A4,有演练条件时一并重跑 A5。
  - 判据:重跑项全部通过;3 轮切换过程里没有出现 `grub>` / `grub rescue>`;`BootOrder` 序列与第一次不一致的记录为零(有则说明一次性语义被破坏)。
  - 设计依据:第 8 节 C 组第 3 句。

### F. 健壮性组(F1-F9)

顺序说明:本组必须在 D 组真做退役之前完成——`/snapshots`、旧内核、SSH 通道都会随退役消失。

- [ ] **F1 快照可用,并真做一次回滚演练(参考设备必做)**
  - 怎么做(参考设备):确认回 Windows 入口可用 -> `sudo timeshift --create --comments "dbk-verify"` -> `sudo timeshift --list` 记下快照名 -> `sudo timeshift --restore --snapshot <名称>` -> 重启。
  - 判据:快照创建成功且 `sudo timeshift --list` 能看到它(对应内容落在 `/snapshots` 内);回滚后系统**能正常启动**(进得了桌面、`findmnt /` 正常、`/snapshots` 仍在、用户数据完好);整段过程写进 `baseline/04-robustness.md`。
  - 不做的设备:写明"未演练"与理由,按 E4 登记已知例外(参考设备不做即该设备 F 组不成立)。
  - 设计依据:第 8 节 F 组第 1 行、4.7 节 R1/R2。

- [ ] **F2 `/snapshots` 为独立分区且 `df` 可见**
  - 怎么做:`findmnt -no SOURCE,TARGET,FSTYPE /snapshots`;`findmnt -no SOURCE /`;`df -h /snapshots`;`ls /snapshots`。
  - 判据:`/snapshots` 的来源设备与 `/` **不是同一个分区**;`df` 显示容量与 `SNAPSHOT_SIZE`(15GiB)一致且已用未逼近上限;`/snapshots` 下有实际快照内容。
  - 设计依据:第 8 节 F 组第 2 行、决策 3.6、4.7 节 R2。

- [ ] **F3 多内核可回退且 `GRUB_DEFAULT=saved` 生效**
  - 怎么做:`grep -E '^GRUB_DEFAULT=|^GRUB_SAVEDEFAULT=|^GRUB_DISABLE_OS_PROBER=' /etc/default/grub`;`sudo grub-editenv list`;`ls /boot/vmlinuz-*`;`awk -F\' '/menuentry /{print $2}' /boot/grub/grub.cfg | grep -c 'Advanced options'`。
  - 判据:`GRUB_DEFAULT=saved` 命中([templates/grub-defaults.snippet](../templates/grub-defaults.snippet) 已合并);`grub-editenv list` 可读且有 `saved_entry`;`/boot` 下至少有**两个**内核版本;Advanced options 子菜单计数 `>= 1`。
  - 设计依据:第 8 节 F 组第 3 行、4.7 节 R3、决策 3.18。

- [ ] **F4 崩溃可观测:journald 持久化**
  - 怎么做:`ls -d /var/log/journal`;`journalctl --list-boots`;`journalctl -b -1 -n 5`。
  - 判据:`/var/log/journal` 目录存在;`--list-boots` 至少列出两条(本次启动与上一次);`journalctl -b -1` 能读出上一次启动的日志行。
  - 设计依据:第 8 节 F 组第 4 行、4.7 节 R5。

- [ ] **F5 更新策略:仅安全更新且不自动重启**
  - 怎么做:`grep -A5 'Package-Blacklist' /etc/apt/apt.conf.d/52-dbk-policy`;`grep -n 'Automatic-Reboot' /etc/apt/apt.conf.d/52-dbk-policy`;`grep -n 'Remove-Unused-Kernel-Packages' /etc/apt/apt.conf.d/52-dbk-policy`;`apt-config dump | grep -i 'Unattended-Upgrade::' | sort`。
  - 判据:黑名单含 `linux-` 与 `nvidia-`;`Automatic-Reboot` 与 `Automatic-Reboot-WithUsers` 都是 `false`;`Remove-Unused-Kernel-Packages` 为 `false`(保留旧内核);未放开 `-updates`/`-proposed`(只走默认的 `-security`)。策略片段与 [templates/unattended-upgrades.snippet](../templates/unattended-upgrades.snippet) 一致。
  - 设计依据:第 8 节 F 组第 5 行、决策 3.18、4.7 节 R8。

- [ ] **F6 远程救援通道:从另一台机器可 SSH 登录且无需桌面会话**
  - 怎么做:Ubuntu 侧 `systemctl is-active ssh`;`ss -tlnp | grep :22`;把 Ubuntu 注销到**登录界面**(不登入桌面),从另一台机器 `ssh <用户名>@<Ubuntu IP>`。
  - 判据:22 端口在听;从另一台机器登录成功,且**不依赖** Ubuntu 侧已登录桌面会话(R7 的用途正是桌面挂死时排障)。
  - 设计依据:第 8 节 F 组第 6 行、4.7 节 R7。

- [ ] **F7 OOM 防护:`systemd-oomd` 启用且 zram 生效**
  - 怎么做:`systemctl is-enabled systemd-oomd`;`systemctl is-active systemd-oomd`;`zramctl`;`swapon --show`;`free -h`。
  - 判据:`systemd-oomd` 为 `enabled`(或 `enabled-runtime`)且 `active`;`zramctl` 有 `/dev/zram0` 且大小约 `min(RAM/2, 8GiB)`(配置表达式见 [templates/zram-generator.conf](../templates/zram-generator.conf);16GiB 及以上内存的机器即约 8GiB,内存更小的机器按一半取值,不要按固定 8GiB 判);`swapon --show` 有 4GiB swapfile;`free -h` 的 swap 总量约 `4GiB + min(RAM/2, 8GiB)`(16GiB 及以上内存时即约 12GiB)。
  - 设计依据:第 8 节 F 组第 7 行、决策 3.8、4.7 节 R6、[templates/zram-generator.conf](../templates/zram-generator.conf)。

- [ ] **F8 磁盘健康:`smartd` 运行且 `smartctl -H` 报告 PASSED**
  - 怎么做:`systemctl is-active smartd`;`sudo smartctl -H /dev/nvme0n1`(`DISK` 按参数表取值);`journalctl -u smartd -n 20`。
  - 判据:`smartd` 为 `active`;`smartctl -H` 输出 `SMART overall-health self-assessment test result: PASSED`;`smartd` 日志里没有已升级的属性告警(有告警则按硬件问题处理,见"失败处理")。
  - 设计依据:第 8 节 F 组第 8 行、4.7 节 R9。

- [ ] **F9 挂载稳健:L4 写入的 `fstab` 条目均带 `nofail`**
  - 怎么做:`awk '!/^[[:space:]]*#/ && NF>=4 && $2!="/" {print $1, $2, $4}' /etc/fstab` 逐行核对(每一行都要判"该不该带 `nofail`",ESP 行按本条判据判"不加");`findmnt --verify`;`grep -c nofail /etc/fstab`(仅作辅助计数)。
  - 判据:**逐行核对是唯一判据**。L4 写入的三条——共享盘行、`/snapshots` 行、swapfile 行——挂载选项里都必须带 `nofail`(计数 `>= 3` 只作辅助;不足 3 条即说明有缺项);`/boot/efi` 属系统必需挂载,**不加** `nofail`(给 ESP 加 `nofail` 是负收益:ESP 挂载失败被静默跳过时 `/boot/efi` 退化成 root 上的空目录,内核/grub 更新"写入成功"而真实 ESP 陈旧;若发现已加,记偏差并说明理由);`findmnt --verify` 不报 error。缺 `nofail` 的条目按"失败处理"补齐后复测,并把补齐动作记入偏差。
  - 口径说明:本条是对设计第 8 节 F 组"`fstab` 中所有非 root 条目均带 `nofail`"**字面口径的收窄**——设计未区分"方案写入的条目"与"安装器生成的系统必需挂载",按 E3 的**方案级偏差**通道回写设计。
  - 设计依据:第 8 节 F 组第 9 行、4.5 节共享盘行、第 7 节 L4 `fstab` 行。

### D. 可撤除性组(D1-D6)

顺序说明:D1 真做之后这台设备上不再有 Linux(Linux 分区与 `ubuntu` 条目被清,一次性入口不复存在);D3/D4 是原地重装(至少真做一法)。所以**次序固定为:D6 -> D2 -> D3/D4 推演 -> D5 复检 -> D1 真做退役(全部动作的最后一步)**。理由:D6 依赖 ESP 与 Windows 引导,和是否有 Linux 无关;D5 的判据要求"`\EFI\ubuntu\` 与 `\EFI\Microsoft\` 两棵子树并存、Ubuntu 仍可经一次性入口启动",只有排在 D1 之前才可能成立。**动手前把 A-C、F 组的全部证据落盘**。

- [ ] **D1 按 L5 五步完整推演(参考设备真做一次)**
  - 怎么做:按 [L5 退役手册](06-decommission.md)与 [checklists/rollback.md](../checklists/rollback.md) 第 1 节执行,顺序为 1 -> 2 -> 3 -> 4 -> (5) 不可更换;第 5 步(扩展分区)可选。
  - 判据:五步的勾选顺序与文档一致,记录里**没有**"先格式化 Linux 分区再修引导"这类跳序动作;走偏差分支(固件无顺序选项)时,其"先备份 -> 回 Ubuntu 删条目 -> 再回 Windows"的三段次序也写进备注;结束后固件条目与实际状态一致(无指向已删引导文件的残留条目,或已按偏差分支处置),且 `BootOrder` 首位仍是 Windows Boot Manager。
  - 设计依据:第 8 节 D 组第 1 句、4.6 节、7.2 节。

- [ ] **D2 系统盘隔离生效**
  - 怎么做:Windows 侧逐项核对:六项已知文件夹(桌面/文档/下载/图片/视频/音乐)与游戏库、下载目录、容器镜像目录的实际位置;`C:\Users\<用户名>` 下这些目录是否只是空壳或联接。
  - 判据:逐项都位于 `D:`;`C:` 不含用户数据(只有系统与程序);结论与 L1 产物 `baseline/01-partitions.txt` 的"隔离核对结论"注记段一致。
  - 设计依据:第 8 节 D 组表格第 1 行、决策 3.15、4.2 节。

- [ ] **D3 原地重装办法一(Windows 崩溃)可推演,参考设备至少真做一法**
  - 怎么做:按 [07-rescue.md](07-rescue.md) 第 4 节与设计 4.8 办法一推演(参考设备真做一次:用官方 ISO 引导 -> 自定义安装 -> **只格式化 `C:`**)。
  - 判据:只格式化 `C:`;`D:` 与两块 Linux 分区未动(用 `baseline/02-partitions.txt` 逐项对账偏移与大小);ESP 上只允许安装程序重建 `\EFI\Microsoft\` 与 BCD、以及可能被覆盖的 `\EFI\BOOT\bootx64.efi`(属正常,见设计 4.8 办法一第 3 步;`\EFI\ubuntu\` 不受影响);装完后重做三件事:关闭 Fast Startup 与休眠、重新完成激活、恢复已知文件夹重定向(设计与 L1 手册均列为必做);重定向恢复后**重跑 D2 的隔离核对**(重建 `C:` 会重做重定向,必须回到 D2 的判据重新确认一遍)。
  - 设计依据:第 8 节 D 组表格第 2 行、4.8 节办法一。

- [ ] **D4 原地重装办法二(Ubuntu 崩溃)可推演**
  - 怎么做:按 [07-rescue.md](07-rescue.md) 第 5 节与设计 4.8 办法二推演(Ubuntu 安装 U 盘 -> 手动分区 -> **只格式化 root 并挂 `/`**)。
  - 判据:ESP **复用且"格式化"勾选未被勾上**(这是全流程最危险的一步);`/snapshots` 挂上但**不**格式化;Windows 各分区未动;安装器写 `\EFI\ubuntu\`,期间不改 `BootOrder`。
  - 设计依据:第 8 节 D 组表格第 2 行、4.8 节办法二、决策 3.3。

- [ ] **D5 重装(或推演)后 A 组四条不变量复检**
  - 怎么做:重装或推演完成后重跑 A1、A3、A4、A5(A3 按 A3 的**例外口径**判读:刚做过 D3 真做或 D6 时,`\EFI\Microsoft\`/`BCD` 的差异属预期);并复核"本次没有出现过 `efibootmgr -o`"。
  - 判据:四条**逐项判据**通过(A3/A4 只认 `verify-baseline.ps1` 的 ① ② ③ 三项对应行,不认脚本整体退出码,见"验证"节);`\EFI\ubuntu\` 与 `\EFI\Microsoft\` 两棵子树并存且互不影响;Ubuntu 仍可经一次性入口启动。
  - 兜底口径:若设备在本次验收前已执行过 L5 退役(即 D5 排在 D1 之后复检),则本条降级为只复检 A1/A3/A4,A5 与"两棵子树并存""Ubuntu 仍可经一次性入口启动"三项标为**不适用**并写明理由(退役后 Linux 分区与 `ubuntu` 条目已被清、一次性入口不复存在,不存在"并存"可言;ESP 上残留的 `\EFI\ubuntu\` 子树即便还在也已失效,不作为判据)。
  - 设计依据:第 8 节 D 组表格第 2 行末句、4.8 节两法的第 5 步。

- [ ] **D6 非重装逃生路径可用(引导层损坏场景)**
  - 怎么做:按 [07-rescue.md](07-rescue.md) 第 3 节(基线回滚)+ 第 2 节(`bcdboot` 重建)演练:Windows 管理员会话 `mountvol S: /s` -> `robocopy baseline\02-esp-backup\EFI S:\EFI /E`(**只复制 `EFI\` 子树**,`manifest.sha256` 不得拷回 ESP)-> `bcdboot C:\Windows /s S: /f UEFI` -> `mountvol S: /d` -> 复核(其余按 [07-rescue.md](07-rescue.md) 第 3 节第 1、6、8 步执行:校验备份完整性、清理 NVRAM 残留条目、连续重启 3 次)。
  - 判据:还原后 Windows 能正常启动;`{bootmgr}` 的 `path` 与基线一致;`BootOrder` 首位未变;`\EFI\Microsoft\` 里由 `bcdboot` 重写的 `bootmgfw.efi` 与 `BCD` 差异按 [07-rescue.md](07-rescue.md) 第 2 节第 3 条的"预期差异"解释,不作为失败判据;最后重跑 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 并留档。
  - 顺序提醒:本项要在 D1 真做退役**之前**完成(退役后 `baseline/02-esp-backup/` 虽仍在,但设备状态已不同,复盘口径会乱)。
  - 设计依据:第 8 节 D 组表格第 3 行、4.8 节"第三选择"、7.2 节基线回滚。

### E. 记录组(E1-E5)

- [ ] **E1 `baseline/` 产物齐全**
  - 怎么做:逐项确认在位且可读:`00-firmware.md`、`01-partitions.txt`、`01-activation.md`、`02-preflight-report.md`(结论行必须是"结论: 允许进入 L3")、`02-esp-backup/`(含 `manifest.sha256`)、`02-firmware-entries.txt`、`02-partitions.txt`、`03-efi-layout.txt`、`04-first-boot.md`、`04-robustness.md`,以及本次填写版 `08-verification.md`;多设备时都在 `baseline/<设备别名>/` 下。
  - 判据:逐项在位、内容为本次实测而非模板文字;`baseline/02-esp-backup/manifest.sha256` 能逐行校验(与备份树哈希一致)。
  - 设计依据:第 8 节 E 组、第 6 节规则 1-2、[baseline/README.md](../baseline/README.md)。

- [ ] **E2 `baseline/` 未入库**
  - 怎么做:仓库根 `git status --porcelain`;`git ls-files baseline/`;`git check-ignore -v baseline/02-partitions.txt`。
  - 判据:`git status --porcelain` 无输出(或输出里不含任何 `baseline/` 条目);`git ls-files baseline/` 只列出 `baseline/README.md`;`check-ignore` 命中 `.gitignore` 的 `baseline/*` 规则。
  - 设计依据:第 8 节 E 组、第 6 节规则 2。

- [ ] **E3 本次与设备参数表的偏差已回写**
  - 怎么做:把实测值与[00 入口](00-overview.md)的设备参数表逐项对账(容量、`ESP_SIZE` 实测尺寸、`WINDOWS_SYSTEM_SIZE`/`WINDOWS_DATA_SIZE` 实测容量、`SHARED_PART_UUID`、`VENDOR`/`BOOT_MENU_KEY`、`DISK_MODEL`/`DISK_SIZE`、`FIRMWARE_MODE`);然后按归属分流:
    - **设备级偏差**(分区表偏移与大小、UUID、实测容量、固件无顺序选项等):写进 `baseline/`(见 [baseline/README.md](../baseline/README.md) 的"多设备用法");
    - **方案级偏差**(影响适用设备类或"偏离项处置"的,如固件只认第一块盘、WinRE 占用预留空间、Windows 更新重写 ESP):追加到 [00 入口](00-overview.md)的"偏离项处置"表,并在 `baseline/08-verification.md` 里写明改哪一行。
  - 判据:本设备的每一条偏差都有明确归属与落盘位置,**没有只记在口头或聊天里的偏差**。
  - 设计依据:第 8 节 E 组、[baseline/README.md](../baseline/README.md)。

- [ ] **E4 已知例外在案**
  - 怎么做:把 A-F 组所有未勾选项整理成"已知例外"清单,逐条写:条目编号、未通过的原因、影响面、是否阻塞"参考实现"判定、后续动作与责任/时间。
  - 判据:清单与勾选结果一一对应,没有"未勾选但没写原因"的条目;完全没有未勾选项时,该条写"无",同样视为通过。
  - 设计依据:第 8 节"通过定义"。

- [ ] **E5 参考实现判定**
  - 怎么做:核对该设备 A-F 六组是否全绿(或未勾选项都在 E4 里有在案例外且不阻塞判定)。
  - 判据:至少一台设备达到"完整跑通";未达到时明确写出"当前设备非参考实现"及其缺口,不得含糊。
  - 设计依据:第 8 节"通过定义"末句。

## 验证

- **逐组按勾选判定**:A、B、C、D、E、F 六组各自"全勾"即该组通过;六组全通过且 E4 的例外清单核对无误,**该设备验收通过**。
- **通过定义**(逐字保留):任一组存在未勾选项且无在案记录的"已知例外" → 该设备判为未完成。至少一台设备完整跑通,方可称为"参考实现"。
- **结论落盘**:在 `baseline/08-verification.md` 末尾写四行:① 六组逐组结论(A-F:通过/未通过);② 已知例外条数与编号;③ 参考实现判定(是/否,否的话列出缺口);④ 验收日期与执行人。
- **证据可复核**:每一项的"怎么做"命令都能在本次设备上复跑并得到同一结论;**逐项判据优先于整体退出码**:`verify-baseline.ps1` 的"巡检通过"= 0、"需人工介入"= 1 只作参考,**退出码 1 也可能只是第 ④ 项 BitLocker 状态在 L3/L4 恢复保护后的预期差异**(口径见 [06-decommission.md](06-decommission.md) 步骤 2 与 [07-rescue.md](07-rescue.md) 第 2 节:判据是"三项引导判据通过、差异被记录",不是"退出码必须为 0");A3/A4/D6 只认 ① ② ③ 三行的逐行结果(A3 看 ②、A4 看 ③、D6 看 ①③),不认脚本整体退出码。
- **维持条件(不属于勾选范围)**:每次 Windows 大版本更新或累积更新之后,按 7.1 节重跑巡检——`BootOrder` 首项、`\EFI\Microsoft\` 与基线比对、`{bootmgr}` 的 `path`、BitLocker 状态(即 [verify-baseline.ps1](../scripts/windows/verify-baseline.ps1) 的四项,见 [07-rescue.md](07-rescue.md) 第 7 节)。验收通过不等于永久通过。
- **文档自检**:本文件改动后运行 `bash scripts/repo/check-docs.sh docs/08-verification.md`,期望 `check-docs: OK`;同时 `git status --porcelain` 里不得出现 `baseline/`。

## 失败处理

| 现象 | 立即动作 |
|---|---|
| A 组任一项**逐项判据**不过(不是"脚本整体退出码非 0",见"验证"节) | **停手**,不进入 D 组真做(退役/重装)。`BootOrder` 首位不是 Windows Boot Manager 时,先进固件设置界面把它设回首位(**I1**);**不得**改用 `efibootmgr -o` 调整顺序(I2)。引导本身有问题时按 [07-rescue.md](07-rescue.md) 分类处置。注意:`verify-baseline.ps1` 退出码 1 若只来自第 ④ 项 BitLocker 的预期差异,不算 A 组不过(口径见 [06-decommission.md](06-decommission.md) 步骤 2 与 [07-rescue.md](07-rescue.md) 第 2 节) |
| A2/A7 出现 `grub>` 或 `grub rescue>` | 按 [07-rescue.md](07-rescue.md) 第 1 节两条路现场处置;若是 A7 演练中出现的,说明 I1 被破坏(固件仍在优先选失效的 `ubuntu` 条目),处置后按 [07-rescue.md](07-rescue.md) 第 6 节复原启动顺序,并**重做** A7 |
| A7 演练后 `\EFI\ubuntu\` 还原不回去 | 用副本拷回失败时改走 live chroot:`grub-install --efi-directory=/boot/efi --bootloader-id=ubuntu` + `update-grub`(自建条目;重复项用 `efibootmgr -b <n> -B` 删多余)(两条来源见 [07-rescue.md](07-rescue.md) 3.1 节)。**不要**为了"能启动"去改 `{bootmgr}` 的 `path`(I3) |
| A3 报 `\EFI\Microsoft\` 与基线不一致,且不是 D6/D3 真做所致 | 先判断是不是 Windows 更新重写了 ESP(设计第 9 节、7.1 节):按 [07-rescue.md](07-rescue.md) 第 3 节做基线还原 + `bcdboot`;若差异只涉及 `bootmgfw.efi` 与 `BCD`,按"预期差异"解释并留档 |
| B4/B5 挂载失败、只读或中文乱码 | 回 [L4 手册](05-first-boot.md)步骤 1 核对四条前提(Windows 已关 Fast Startup 与休眠、`D:` 未加密、`uid/gid/umask` 与 `windows_names`、未把 POSIX 语义工作流放上共享盘)。**数据可疑时立即停用共享盘并做第二份备份**,不要继续写入(设计第 9 节 `ntfs3` 写入风险) |
| B6 重定向指向错误目录,或某程序不认自定义 XDG 目录 | 按 [xdg-redirect.sh](../scripts/linux/xdg-redirect.sh) 的口径回退:`~/.config/user-dirs.dirs.dbk.bak` 换回去;只重定向文档类目录,**不要**把 `~/.config`、`~/.ssh`、代码仓库搬上 NTFS(设计第 9 节家目录兼容性) |
| B2/B3 出现模块签名被拒或 Secure Boot 被关 | 卸掉专有驱动回 `nouveau` 兜底,改走仓库预签名包;**不**做 DKMS、**不**自签密钥(决策 3.3)。检查是否有人执行过 `mokutil --import` 或关闭 Secure Boot |
| C1 的 `BootNext` 未生效(重启仍进 Windows) | 改用 `BOOT_MENU_KEY` 从固件菜单一次性进 Linux;核对固件是否支持 `bootsequence`;`BootOrder` 仍未变即可继续。**不要**改成永久顺序 |
| C4 发现 3 次切换里 `BootOrder` 发生过变化 | 这是 I2 被破坏:立刻记下变化前后序列,进固件设置界面把 Windows 设回首位,然后排查是哪个动作改了顺序(脚本断言、固件行为、第三方工具),并把该动作从流程里去掉后重跑 C1-C4 |
| F1 快照创建失败 | 视为"**不得执行本次变更**"(设计第 9 节快照容量):先清理旧快照(保留份数上限 3 份)或检查 `/snapshots` 空间与挂载,再重试;仍失败则登记为已知例外并暂停后续内核/驱动与重装类动作 |
| F3 没有旧内核可选 | 核对 `Unattended-Upgrade::Remove-Unused-Kernel-Packages` 是否为 `false`、`GRUB_DEFAULT=saved` 是否已合并;装一个新内核并重启一次让旧内核进入 Advanced options;仍无则登记已知例外并暂停内核更新 |
| F5 发现内核/驱动会被自动更新 | 立即修回 [templates/unattended-upgrades.snippet](../templates/unattended-upgrades.snippet) 的策略(黑名单 `linux-`/`nvidia-`),`systemctl restart unattended-upgrades`;在修回前**不要**做内核/驱动变更 |
| F6 从另一台机器无法 SSH | 检查 `systemctl is-active ssh`、防火墙、地址与网段、`PermitRootLogin` 口径;桌面会话相关故障时优先确认"不登桌面也能连"。仍不通则登记为已知例外并在排障前先解决(它是 L4 故障矩阵里"桌面进入不了"的主要通道) |
| F8 `smartctl -H` 非 PASSED 或 `smartd` 日志有告警 | 按硬件问题处理:先备份数据、评估更换;把它记入已知例外并**暂停** D 组真做(带故障盘做重装会放大风险) |
| F9 `fstab` 缺 `nofail`(限 L4 写入的共享盘/`/snapshots`/swapfile 三条) | 先 `cp /etc/fstab /etc/fstab.dbk.bak`,给缺项补 `nofail`,然后 `sudo systemctl daemon-reload`、`sudo findmnt --verify` 复测;补齐动作记入偏差。若缺的是 `/boot/efi` 的反向情形(ESP 行被加了 `nofail`),按同样备份口径**去掉**该选项并记偏差说明理由(见 F9 判据)。若补完仍进不去系统,在 GRUB 中追加 `systemd.unit=emergency.target` 进急救(第 7 节 L4 `fstab` 行) |
| D1 推演中途想反悔 | 按 [06-decommission.md](06-decommission.md) 的"变体:只想暂时停用 Linux"处理:分区与 `ubuntu` 条目保留、日常用一次性入口进 Linux;**不要**把 `BootOrder` 改成 Ubuntu 优先(I1) |
| D 组真做(退役/重装)后想恢复 Linux | 按设计 4.8 办法二重装:[07-rescue.md](07-rescue.md) 第 5 节。只格 root、ESP 复用且**绝不勾选格式化**、Windows 各分区不动;`/snapshots` 随退役消失,需按 [L3 手册](04-ubuntu.md)从预留空间重建(本方案不提供在已有系统上缩容的路径,决策 3.5) |
| D3/D4 发现误格了 `D:` 或 Linux 分区 | 立刻停止一切写盘动作(不再建分区、不跑安装器)。ESP 被破坏走 D6/D1 的基线还原;`D:` 被删以数据恢复优先,不要再写入原盘 |
| 验收期间两个系统一起异常、频繁死机 | **先按硬件问题排查**(内存测试、SMART、温度、电源),不要归因于"双系统互相影响"——两系统运行期不共享状态,只有引导层会互相干扰(设计第 7 节与第 9 节) |
| E2 发现 `baseline/` 内容会入库 | 先确认混入的具体路径,按 [.gitignore](../.gitignore) 的 `baseline/*` 规则排查;`git rm --cached` 移除索引后重查;**不得**把单机产物(分区表、ESP 镜像、固件条目、激活状态)提交到公开仓库(第 6 节规则 2) |
| E3 发现偏差只在口头/聊天里 | 当场补写:设备级进 `baseline/`,方案级进 [00 入口](00-overview.md) 的"偏离项处置"表;补完后重跑本组 |

## 回滚

验收本身以"只读核对"为主,所以回滚对象是**验收过程中为处置或演练而做的改动**。任何回滚动作同样受四条不变量约束:I2(绝不用 `efibootmgr -o` / `displayorder`);I3 的例外**仅限**"用基线镜像把 `\EFI\Microsoft\` 还原回基线状态"这一条(4.8 节"第三选择"、[07-rescue.md](07-rescue.md) 第 3 节),除此之外不得覆盖 Windows 引导文件、不得改 `{bootmgr}` 的 `path`。

| 改动 | 回滚方式 | 可逆性 |
|---|---|---|
| A7 演练删除了 `\EFI\ubuntu\` | 把 `D:\dbk-verify\efi-ubuntu\` 副本拷回 `S:\EFI\ubuntu\`;副本不可用时走 live chroot 的 `grub-install` + `update-grub`(3.1 节) | 可逆(前提:副本或 live 介质在位) |
| D6 用基线还原了 ESP | 还原本身即回到基线状态;由 `bcdboot` 重写的 `bootmgfw.efi` 与 `BCD` 差异属预期,不需再回滚(若要严格回到基线,再用同一份 `manifest.sha256` 校验并复制定稿文件) | 可逆 |
| B4/F9 给 `fstab` 补了 `nofail` | `cp /etc/fstab.dbk.bak /etc/fstab` -> `sudo systemctl daemon-reload` -> `sudo findmnt --verify` | 可逆 |
| B6 调整了家目录重定向 | 还原 `~/.config/user-dirs.dirs.dbk.bak` -> 以该用户身份 `xdg-user-dirs-update --force` | 可逆 |
| B2/B3 为排障卸了专有驱动 | 回 `nouveau` 兜底;要再装回时仍走仓库预签名包(决策 3.3) | 可逆 |
| F1 做了快照回滚演练 | 演练前先确认回 Windows 入口可用;需要回到演练前时 `sudo timeshift --restore --snapshot <演练前快照>`。演练只回滚系统文件,**不动** `/snapshots` 之外的共享盘数据 | 可逆 |
| F3/F5 调整了 GRUB 与更新策略 | 按 [templates/grub-defaults.snippet](../templates/grub-defaults.snippet) 与 [templates/unattended-upgrades.snippet](../templates/unattended-upgrades.snippet) 重放;`/etc/default/grub.dbk.bak` 与 `52-dbk-policy` 都可回退 | 可逆 |
| D3/D4 真做了原地重装 | **不可逆**:`C:` 或 root 上被格式化的内容无法恢复(这也是两条办法只格一块分区的原因);数据侧依赖 `D:` 与 `/snapshots` 未被触碰 | 不可逆 |
| D1 真做了 L5 退役(删除 Linux 分区) | **不可逆**:Linux 侧数据永久丢失;要恢复只能按设计 4.8 办法二重装 | 不可逆 |

三种回滚粒度(7.2 节)在本清单里的用法:**单步回滚**对应上表前五行(回到该步骤的"回滚方式");**阶段回滚**对应 D1 退役;若退役只做到第 1 步(改顺序)或第 4 步(删条目),按 [06-decommission.md](06-decommission.md) 的"变体"与"退役做到一半想反悔"表处理;**基线回滚**对应 A3/A7/D6 的 ESP 与固件条目复原。

**不可逆项清单(动手前先读一遍)**:删除 Linux 两块分区(100GiB root + 15GiB 快照);格式化 `C:` 或 root;`D:` 上的共享数据(含办公目录 `D:\Shared\`);删除 `\EFI\ubuntu\` 且没有副本与可用 live 介质;`D:` 被 BitLocker 加密后 Linux 侧不可读写(设计第 9 节)。

**验收结束的收尾**:把本组证据、结论与已知例外写进 `baseline/08-verification.md`,确认 `git status --porcelain` 里没有 `baseline/` 条目,再按 E3 把偏差回写到 [00 入口](00-overview.md)或 `baseline/`。
