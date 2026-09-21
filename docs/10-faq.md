# 附录:症状速查与分阶段风险(FAQ)

**本文档是查询型:出事时按症状查,不顺着读。** 它只给"现象 -> 三步处置 -> 去哪张卡"的索引,不复述命令上下文,也不是规范:与阶段手册冲突时以阶段手册为准,并把冲突记下来修文档。

## 怎么用

1. 先在下面的症状速查表里按现象定位卡号(`10-1` … `10-20`);
2. 读该卡的 3 行处置;卡尾的 `脚本:` 行给出能一条 `--check` 判定的脚本(全部默认只读,`--apply` / `-Apply` / `-Yes` 才动手);
3. 按卡尾 `->` 的指向回阶段手册的操作卡执行,再回 [08-verification.md](08-verification.md) 复判。

三条边界:

- **风险总表不在这里。** 34 条风险(风险 / 后果 / 缓解)的唯一真源是 [design/00-design.md](design/00-design.md) 第 9 节;本文档只给按阶段的速查(5 张),不复制第二份真源。
- **先分清阶段。** 同一句"黑屏"在 L3(安装)、L4(首启)、L5(退役与救援)成因与处置不同;拿不准先跑 `scripts/linux/triage.sh --check`,或回 `07-1` 判层。
- **本文档不给新动作。** 每条处置都在对应手册的卡里有回退方式;动手前的最低保险是:进得去系统就先按 `05-9` 固定当前部署,进不去就先确认 `baseline/` 可读、救援 U 盘在位。

## 症状速查表

| 卡 | 现象 | 快速判定 |
|---|---|---|
| `10-1` | 装完黑屏 / 进不去桌面 | `scripts/linux/verify-l3.sh --check` |
| `10-2` | 装完没网 / 键盘失灵,要不要换发行版 | `scripts/linux/triage.sh --check` |
| `10-3` | 手动分区界面找不到"引导器位置"选项 | `scripts/linux/check-partition-plan.sh --track D --check` |
| `10-4` | 是不是必须切独显直连才能进系统 | `scripts/linux/graphics.sh --check` |
| `10-5` | 引导菜单阶段黑屏,但键盘还能用 | `scripts/windows/set-bootnext.ps1 -Device USB -WhatIf` |
| `10-6` | 更新后进不了桌面 | `scripts/linux/dbk-rollback.sh --check` |
| `10-7` | 反复强制重启对系统有什么影响 | `scripts/linux/triage.sh --check` |
| `10-8` | 两个系统运行期会不会互相影响 | `scripts/windows/verify-baseline.ps1 -BaselineDir baseline` |
| `10-9` | 删掉 Fedora 会不会影响 Windows 引导 | `scripts/windows/delete-linux-partition.ps1 -Check` |
| `10-10` | 每次切系统时间都错(差一个时区) | `scripts/linux/set-time.sh --check` |
| `10-11` | 蓝牙设备每次都要重新配对 | `scripts/linux/bt-keys-sync-wrapper.sh`(默认空跑) |
| `10-12` | 数据盘 / 第二块硬盘能不能用 MBR | `scripts/windows/check-partition-layout.ps1 -Track W` |
| `10-13` | 能不能装到移动硬盘 / USB SSD | `scripts/windows/preflight.ps1 -Only target-disk` |
| `10-14` | Fedora 分区能不能改小 | `scripts/windows/check-partition-layout.ps1 -Track D` |
| `10-15` | 双硬盘机型只能从第一块盘启动 | `scripts/windows/preflight.ps1 -Only target-disk` |
| `10-16` | 共享盘会不会被 Linux 写坏 | `scripts/linux/mount-shared.sh --check` |
| `10-17` | 国内下载慢,能不能用镜像站 | `scripts/windows/verify-install-media.ps1 -Check` |
| `10-18` | 一个系统崩溃后能不能只重装它 | `scripts/linux/triage.sh --check` |
| `10-19` | 怎么回滚到上一个部署 | `scripts/linux/dbk-rollback.sh --list` |
| `10-20` | 发行版 rebase 失败怎么办 | `scripts/linux/upgrade-release.sh --check` |

## 症状卡(20 张)

### 10-1 装完黑屏 / 进不去桌面(只有鼠标指针)

- 应急只做一件事:在引导菜单高亮该条目按 `e`,内核行尾加 `nomodeset`,按 `F10` 启动(它关掉 KMS,所以能点亮,但会与默认 Wayland 冲突)。
- 能进系统就立刻收尾:按 `05-3` rebase 到 ublue 的 NVIDIA 变体并做一次性 MOK 注册,再删掉 `nomodeset` 重启。
- 装完驱动仍点不亮:先在固件里切"独显直连"拿到可用系统,把续航与显存代价记进 `baseline/04-first-boot.md`(见 `10-4`)。
-> `04-1`、`04-3`、`05-3`
脚本:`scripts/linux/verify-l3.sh --check`;`scripts/linux/check-signature.sh --check`

### 10-2 装完没网 / 键盘失灵,要不要换个发行版

- 先在 live 里分清:`lspci -nn` / `lsusb` / `ip link` 有设备就是"识别了但缺固件/驱动",一个都看不到才是内核层面不认;两种都不是换发行版的理由。
- 用有线或手机 USB 网络共享先拿到网络,再按 `07-8` 第 4 条的口径处理:换内核 -> 换驱动版本,发行版不动。
- 原子版上驱动与内核是镜像的一部分:先按 `05-9` 固定当前部署,再按 `05-3` rebase 换镜像分支,不要就地装内核模块。
-> `07-8`、`05-3`、`05-9`;设计 3.17 被否方案
脚本:`scripts/linux/triage.sh --check`

### 10-3 手动分区界面找不到"引导器位置"选项

- 原子版走 Anaconda 手动分区:按 `04-2` 只指定挂载点,不新建、不删除、不改尺寸。
- 先跑核对脚本,按它输出的"下一步该建什么"建 Fedora 三块(`ESP-Fedora` / `/boot` / root),三块都落在 115GiB 预留区内。
- 绝不把 Windows 的 ESP 勾成"格式化"——那一勾当场清空 `\EFI\Microsoft\`;Fedora 三块也一律不由安装器重建。
-> `02-3`、`02-4`、`04-2`
脚本:`scripts/linux/check-partition-plan.sh --track D --check`;`scripts/windows/check-partition-layout.ps1 -Track D`

### 10-4 是不是必须切独显直连才能进系统

- 不必:目标形态是混合显卡 + PRIME offload,只有 rebase 后反复点不亮时才走"独显直连"分支。
- 切了就把代价记进 `baseline/04-first-boot.md`(所有进程占用独显显存、续航明显变差),这是最容易被漏记的一行。
- 驱动正常后按 `05-3` 复检签名与会话,再评估是否切回混合模式。
-> `04-3`、`05-3`;设计 3.3、3.17
脚本:`scripts/linux/graphics.sh --check`

### 10-5 引导菜单阶段黑屏,但键盘还能用

- 这不等于系统坏了:方向键有反应、能盲选进系统,就不是重装的场景。
- 从 Windows 侧用一次性入口进 Silverblue(按 `04-1` 的 `-Device USB`,或厂商 `BOOT_MENU_KEY`),不改永久顺序。
- 进系统后按 [templates/grub-defaults.snippet](../templates/grub-defaults.snippet) 的注释行开 `GRUB_TERMINAL=console` 再 `update-grub`,让菜单可见;撤销就去掉该行重跑。
-> `04-1`、`05-11`、`05-13`;设计 3.19
脚本:`scripts/windows/set-bootnext.ps1 -Device USB -WhatIf`;`scripts/linux/reboot-to-windows.sh`

### 10-6 更新后进不了桌面

- 先明确:本方案的更新策略只 check / download,不自动应用、不自动重启(`05-7`),所以症状多半来自一次手动 rebase 或分层。
- 立刻走部署级回滚(`05-9`):开机菜单选旧部署,或 `dbk-rollback.sh --rollback --yes` 后手工重启。
- 回滚后看来源与签名:`rpm-ostree status` 与 `check-signature.sh --check`,把当时的来源记进备注再评估下一步。
-> `05-3`、`05-7`、`05-9`;设计 3.18、4.7 的 R1/R2/R8
脚本:`scripts/linux/dbk-rollback.sh --check`;`scripts/linux/set-updates.sh --check`

### 10-7 反复强制重启对系统有什么影响

- 先停掉长按电源:内核无响应时用 SysRq 的 `S` -> `U` -> `B`(Fedora 默认 `kernel.sysrq=176` 只开放这三位)。
- 已经强断过:下次启动前先做一次文件系统检查,设备名与命令按 `07-8` 第 1 条取值。
- "两个系统都不对劲"先按硬件排查:内存、`smartctl`、温度与电源(见 `10-8`)。
-> `07-1`、`07-8`;设计 9 第 15 条
脚本:`scripts/linux/triage.sh --check`

### 10-8 两个系统运行期会不会互相影响

- 不会:同一时刻只有一个系统在运行;唯一共享面是引导层(固件启动条目 + 两块 ESP 的内容)。
- 两边一起异常时先查硬件:`smartctl -H <DISK>`、`memtest86+`、温度与电源;先不要格式化任何分区。
- 引导层问题按 I1-I4 逐项对账:对照 `baseline/02-firmware-entries.txt` 与 `baseline/02-esp-backup/`。
-> `07-1`、`07-8`、`07-7`;设计 2、设计 9 第 16 条
脚本:`scripts/linux/triage.sh --check`;`scripts/windows/verify-baseline.ps1 -BaselineDir baseline`

### 10-9 删掉 Fedora 会不会影响 Windows 引导

- 做好就不会,前提是 I1 成立(`BootOrder` 首位始终是 Windows Boot Manager)——固件会在失效条目之后回落。
- 顺序不可更换:先 `07-9` 归位 -> 再 `07-10` 备份到仓库外 -> 再 `07-11` 删三块 Fedora 分区 -> `07-12` 清 NVRAM(扩容可选)。
- 只想停用不想删:做到 `07-9` 停下,或走 `07-13` 只停用条目,可逆。
-> `00-overview.md`、`07-9`、`07-10`、`07-11`、`07-12`、`07-13`
脚本:`scripts/windows/restore-boot-order.ps1 -Check`;`scripts/windows/delete-linux-partition.ps1 -Check`;`scripts/windows/cleanup-nvram.ps1 -Check`

### 10-10 每次切系统时间都错(差一个时区)

- 口径只在 Linux 侧定:`05-4` 让 RTC 走 UTC,判据是 `timedatectl` 输出 `RTC in local TZ: no`。
- Windows 侧可选配 `RealTimeIsUniversal=1`,但只在 Windows 里改,不要从 Linux 挂载并写 Windows 注册表。
- 两种口径只选一种并保持一致,不要两边各改一半。
-> `05-4`;设计 4.5
脚本:`scripts/linux/set-time.sh --check`

### 10-11 蓝牙设备每次都要重新配对

- 顺序固定:先在 Silverblue 里正常配对一次,再进 Windows 对同一设备重新配对(以 Windows 侧为权威来源)。
- 回 Silverblue 按 `05-5` 用包装脚本从 Windows hive 导入密钥(只读挂载 Windows 分区,不做反向写入)。
- 复测:同一设备两边都能直接连接,不需要重新进配对模式。
-> `05-5`、`07-7`;设计 5.3、设计 9 第 9 条
脚本:`scripts/linux/bt-keys-sync-wrapper.sh`(默认空跑)

### 10-12 数据盘 / 第二块硬盘能不能用 MBR

- 引导盘必须 GPT + UEFI,没有分支;纯数据盘用 MBR 不在 v1 验证范围,按偏离项登记。
- 双盘机型:两块 ESP 都必须在第一块盘(见 `10-15`);Linux 数据分区可放第二块盘,但引导文件不能。
- 任何偏离都按 [00-overview.md](00-overview.md) 的偏离项处置表定口径,并回写该设备的 `baseline/`。
-> `00-overview.md`、`02-1`;设计 1.2 偏离项
脚本:无(偏离项靠人工登记)

### 10-13 能不能装到移动硬盘 / USB SSD

- 可以,但属偏离分支(v1 未验证):供电、性能、引导条目、两块 ESP 落盘四件事必须自己补齐。
- 引导条目一旦指向移动盘,拔盘即失效,所以 I1/I2 更重要:进 Linux 一律走一次性入口(`04-1`、`05-11`)。
- 动手前先按 `01-3` 核对目标盘,把偏离登记进 `baseline/` 与 [00-overview.md](00-overview.md) 的偏离项处置表。
-> `01-3`、`02-1`、`05-11`;设计 10 的移动盘变体
脚本:`scripts/windows/preflight.ps1 -Only target-disk`

### 10-14 Fedora 分区能不能改小

- 不能事后缩容:分区表只在装机阶段一次定稿(见 `02-1` 的铁律),两侧都不提供缩容分支。
- 要改尺寸只能整盘重排,且动手前按 I4 先有可用基线:ESP 镜像 + 固件启动项快照 + BitLocker 已挂起。
- Fedora 侧三块(`ESP-Fedora` 1GiB + `/boot` 1GiB + root 约 113GiB)合计 115GiB 是不可削减量;预留区被 Windows 安装器占走即记偏差并重排。
-> `02-1`、`02-4`、`03-8`;设计 3.5、5.1
脚本:`scripts/windows/check-partition-layout.ps1 -Track D`

### 10-15 双硬盘机型只能从第一块盘启动

- 厂商硬约束:两块 ESP 都必须留在第一块盘;Linux 数据分区可以放第二块盘。
- 装机前用 `01-3` 核对目标盘型号与容量,不要先按第二块盘规划。
- 已装完才发现:记偏离并评估"共用 ESP 分支"(设计 10),该分支需实测。
-> `01-3`、`02-1`;设计 1.2、设计 9 第 19 条
脚本:`scripts/windows/preflight.ps1 -Only target-disk`;`scripts/windows/check-partition-layout.ps1 -Track D`

### 10-16 共享盘会不会被 Linux 写坏

- 可控,前提四条都在位:Windows 已关 Fast Startup 与休眠、`D:` 未加密、挂载带 `uid`/`gid`/`umask`/`windows_names`/`nofail`、不在共享盘上做依赖 POSIX 语义的工作。
- 关键目录留第二份备份;别在 Linux 侧批量重命名或移动大目录。
- 怀疑写坏:立刻停写(必要时改只读挂载或卸载),回 Windows 先确认 Fast Startup 与休眠仍是关闭状态。
-> `03-2`、`05-1`、`05-2`;设计 5.3、设计 9 第 11/12/13 条
脚本:`scripts/linux/mount-shared.sh --check`;`scripts/linux/xdg-redirect.sh --check`;`scripts/windows/disable-faststartup.ps1 -Check`

### 10-17 国内下载慢,能不能用镜像站

- 可以:镜像站只当下载加速器,不当信任源。Fedora ISO 必须按官方 `CHECKSUM` 文件比对。
- Windows ISO 官方未发布镜像哈希,只做"来自微软官方下载域 + 官方安装器校验"(见 `01-2`)。
- 校验结论写进 `baseline/00-firmware.md` 的介质段;校验不过就重下,不要"先装装看"。
-> `01-2`、`01-4`;设计 9 第 20 条
脚本:`scripts/windows/verify-install-media.ps1 -Check`

### 10-18 一个系统崩溃后能不能只重装它

- 先判层(`07-1`):只是引导层坏了就不要重装,按 `07-2` 从 GRUB 提示符回去、`07-3` 在 Windows 侧修、`07-6` 回基线。
- 只重装 Windows:按 `07-4` 只格式化 `C:`,其余分区一律不动。
- 只重装 Silverblue:按 `07-5` 只格式化 root;两块 ESP 与 `/boot` 都绝不勾"格式化"。
-> `07-1`、`07-2`、`07-3`、`07-4`、`07-5`、`07-6`;设计 4.8
脚本:`scripts/linux/triage.sh --check`;`scripts/linux/check-partition-plan.sh --track D --check`

### 10-19 怎么回滚到上一个部署

- 先看现状:`05-9` 的 `dbk-rollback.sh --list` 列出部署数、下一次启动与 pin 标记,`--check` 复检签名与会话。
- 变更前先固定:`--pin --yes`;要回退时 `--rollback --yes`,再手工重启(也可在开机菜单直接选旧部署)。
- 回滚只换系统部署:用户数据在 `/var/home`,不随部署回退;不再需要该回滚点时 `--unpin --yes`。
-> `05-9`、`05-10`;设计 3.7、7.2
脚本:`scripts/linux/dbk-rollback.sh --list`;`scripts/linux/dbk-rollback.sh --check`

### 10-20 发行版 rebase 失败怎么办

- 失败时系统通常仍可用:开机菜单选被 pin 的旧部署,或 `dbk-rollback.sh --rollback --yes` 后重启。
- 先 pin 再 rebase 是硬纪律(`05-10`):脚本读不到固定状态就会拒绝执行 rebase,不要绕过。
- 分支名与镜像名上游会改:未按官方文档核实前不要执行;每次操作后记录 `rpm-ostree status` 的来源与版本;可随时 rebase 回 stock。
-> `05-3`、`05-9`、`05-10`;设计 3.21、设计 9 第 33/34 条
脚本:`scripts/linux/upgrade-release.sh --check`;`scripts/linux/dbk-rollback.sh --check`

## 分阶段风险速查(5 张)

**总表在 [design/00-design.md](design/00-design.md) 第 9 节(34 条)。** 下面每张卡只给"本阶段最可能踩的坑 + 一句话缓解",首列条目号与总表逐条对应,不复制后果列。

### 阶段风险 1:共用底座与分盘(L0 + 02)

| 设计 9 | 本阶段的坑 | 一句话缓解 | 相关卡 |
|---|---|---|---|
| 1 / 18 / 19 | VMD 未关、装错盘、ESP 放错盘 | 装 Windows 之前先关 VMD;用 `DISK_MODEL`/`DISK_SIZE` 逐盘核对;两块 ESP 都必须在第一块盘 | `01-1`、`01-3`、`02-1` |
| 20 | 国内镜像未校验 | 镜像站只当加速器:Fedora 按官方 `CHECKSUM`,Windows 只认官方域 + 安装器校验 | `01-2` |
| 30 | 固件只认第一个 ESP | 两块 ESP 互不干扰是 A 组实测项;机型不支持就记偏离并评估共用 ESP 分支 | `02-1`、`08-verification.md` |
| 34 | ublue 镜像名 / 分支漂移 | `UBLUE_IMAGE` 标"待核实";动手前按官方文档核实镜像名与分支 | `05-3` |

脚本:`scripts/windows/check-firmware.ps1 -Check`;`scripts/windows/verify-install-media.ps1 -Check`;`scripts/windows/check-partition-layout.ps1 -Track D`

### 阶段风险 2:轨道 W(L1 安装 + L2 闸门)

| 设计 9 | 本阶段的坑 | 一句话缓解 | 相关卡 |
|---|---|---|---|
| 2 | BitLocker 索要恢复密钥 | 动手前备份 48 位恢复密钥并挂起保护,操作完恢复保护 | `03-8`、`03-9` |
| 3 | Windows 更新重写第一块 ESP / SBAT 事件 | 两块 ESP 分离让 Windows 侧只能碰自己那块;ESP 镜像备份 + 常备安装 U 盘 | `03-8`、`07-6`、`07-7` |
| 4 | Fast Startup + 双写 NTFS | L1 强制关闭 Fast Startup 与休眠;共享盘禁止在 Windows 休眠时被挂载 | `03-2`、`05-1` |
| 5 | ESP 尺寸与部署数量不匹配 | `ESP-Fedora` 1GiB + 独立 `/boot` 1GiB;两块 ESP 尺寸不允许被削减 | `02-1`、`03-8` |
| 8 | WinRE 摆放占走预留区 | L2 逐项核对分区表;只有两块 ESP 与 Fedora root 尺寸不可削减,其余记偏差据实调整 | `03-8`、`03-9` |
| 10 | KMS 续期失败 | 保留续期任务并定期核对激活状态;失效时重跑一次在线激活 | `03-4`、`03-5` |
| 23 | 激活方案的合规风险 | 仓库只做外链与流程说明,不分发任何激活脚本本体 | `03-4` |
| 26 / 28 | 重装误格分区 / 重定向遗漏 | 只格 `C:`;L1 完成后逐项核对六个已知文件夹 | `03-3`、`07-4` |

脚本:`scripts/windows/check-gate.ps1`;`scripts/windows/backup-esp.ps1 -OutDir baseline -Check`;`scripts/windows/check-activation.ps1 -Check`

### 阶段风险 3:轨道 L 与 L3 安装(02 分盘 + 04)

| 设计 9 | 本阶段的坑 | 一句话缓解 | 相关卡 |
|---|---|---|---|
| 27 | 误格两块 ESP 或 `/boot` | 装前跑核对脚本;Anaconda 里只指定挂载点,每个"格式化"勾选都要显式检查 | `04-2`、`07-5` |
| 29 | Anaconda 在已有系统/ESP 的盘上装 Silverblue 失败(上游已知失败) | 手工预建 Fedora 三块分区 + 只指定挂载点;失败按 `07-1` 后走救援,最坏退回轨道 W | `02-4`、`04-2`、`07-1` |
| 17 | 引导菜单阶段黑屏 | 先确认键盘仍有效;用一次性入口进系统,必要时开 `GRUB_TERMINAL=console`;不要重装 | `10-5`、`05-13` |
| 7 / 31 / 32 | 模块签名未就绪 / 自签 akmods 易碎 / akmod 卡内核升级 | 只走 ublue 预签名镜像 + 一次性 MOK;不在原子版直装 akmod | `05-3` |
| 33 | rebase 后驱动与内核不配套 | rebase 前 pin;rebase 后立刻复检会话 / Wayland / 模块签名 / 桌面,不满足判据就回滚 | `05-3`、`05-9` |
| 21 | 在 ublue 镜像 / 分支之间乱切 | 记录 `rpm-ostree status` 的来源与版本;切换前先 pin;不在非官方镜像间漂流 | `05-3`、`05-10` |

脚本:`scripts/linux/check-partition-plan.sh --track D --check`;`scripts/linux/verify-l3.sh --check`;`scripts/linux/graphics.sh --check`

### 阶段风险 4:首启收敛(L4)

| 设计 9 | 本阶段的坑 | 一句话缓解 | 相关卡 |
|---|---|---|---|
| 9 | 时间 / 蓝牙状态分裂 | RTC 走 UTC;蓝牙以上游 `bt-keys-sync`,以 Windows 侧密钥为准 | `05-4`、`05-5` |
| 11 / 13 | `ntfs3` 写入损坏 / POSIX 语义差异 | 关键目录留第二份备份;共享盘只放文档类数据,代码与密钥留本地 root | `05-1`、`05-2` |
| 12 | 共享盘被 BitLocker / 设备加密 | `D:` 保持不加密;被自动启用了就先解密再继续 | `05-1`、`05-2` |
| 14 / 24 / 25 | 更新被自动应用 / 回滚点缺失 / 固定状态被误改 | 只 check / download,不自动应用与重启;变更前 pin;巡检核对部署列表与固定状态 | `05-7`、`05-9`、`07-7` |
| 22 | 家目录重定向后应用不兼容 | 只重定向文档类目录;出问题还原 `user-dirs.dirs` 的 `.dbk.bak` 备份 | `05-2` |
| 15 / 16 | 反复强断电源 / 把硬件故障误判为双系统问题 | 用 SysRq `S` -> `U` -> `B`;两个系统一起异常先查硬件,先不要格式化分区 | `07-8`、`10-7`、`10-8` |

脚本:`scripts/linux/mount-shared.sh --check`;`scripts/linux/set-updates.sh --check`;`scripts/linux/dbk-rollback.sh --check`;`scripts/linux/set-remote-health.sh --check`

### 阶段风险 5:退役与救援 + 任意时刻(L5 + 长期项)

| 设计 9 | 本阶段的坑 | 一句话缓解 | 相关卡 |
|---|---|---|---|
| 3 | Windows 更新后 Linux 引导消失 | 按 `07-7` 周期巡检;必要时清理 SBAT 策略;按 `07-6` 回基线 | `07-6`、`07-7` |
| 6 | 引导顺序被改 / 卡 `grub rescue>` | 不要先删分区;按 `07-2` 的两条路处置;进系统后按 `07-9` 归位 | `07-2`、`07-9` |
| 27 | 重装 Silverblue 时误格 ESP 或 `/boot` | 显式检查两块 ESP 与 `/boot` 的格式化勾选;动手前先备份 `/var/home` | `07-5` |
| 26 | 原地重装时误格分区 | 逐分区核对,明确禁止"删除所有分区";动手前先做基线备份 | `07-4`、`07-5`、`07-10` |
| 15 / 16 | 强断与硬件误判 | 按 `07-8` 的四条排障纪律;两个系统一起异常先查硬件 | `07-8` |
| 23 | 合规 | 仓库内不得出现激活脚本本体或密钥材料,只留外链与流程说明 | `03-4` |

脚本:`scripts/linux/triage.sh --check`;`scripts/windows/verify-baseline.ps1 -BaselineDir baseline`;`scripts/windows/restore-esp.ps1 -Check`

## 验证

- **现象能对上**:速查表里能找到条目,且该条的判据可观测(如 `timedatectl` 的 `RTC in local TZ: no`、`efibootmgr -v` 的 `BootOrder` 首位、`rpm-ostree status` 的来源)。
- **处置后回手册复判**:做完动作重跑对应卡的 `看到:` 判据与 [08-verification.md](08-verification.md) 的对应组;本文档不替代验收。
- **引导类处置后**:重跑 A 组四项(`BootOrder` 首位、`\EFI\Microsoft\` 逐文件比对、`{bootmgr}` 的 `path`、BitLocker 状态),与本机 `baseline/` 逐字对账。
- **做了偏离动作就登记**:移动硬盘、MBR 数据盘、改分区容量等,写进该设备的 `baseline/08-verification.md` 填写版(只有填写版含勾选与证据,不入库)。
- **文档自检**:改动本文件后运行 `bash scripts/repo/check-docs.sh docs/10-faq.md`,期望 `check-docs: OK`。

## 处置失败怎么办

1. **速查表里找不到对应现象**:不要猜着动手。先跑 `scripts/linux/triage.sh --check` 判层(引导层 / 系统分区 / 硬件),再决定动作。
2. **处置后现象不消失或更糟**:立刻停掉同类动作——尤其停掉"重装"与"删分区",按 `07-8` 的四条排障纪律走。
3. **怀疑硬件**:硬件优先(内存、SMART、温度、电源)(见 `10-8`)。
4. **怀疑是文档本身错了**(本文档与阶段手册不一致):以阶段手册与 [08-verification.md](08-verification.md) 为准,并把它当文档缺陷记录下来修文档,不要按本文档硬做。

## 回滚

- 本文档不给新动作,因此不产生新的不可逆项:它推荐的每一条处置,都在对应手册的卡里有回退方式。
- 回退粒度与落点见 [checklists/rollback.md](../checklists/rollback.md):单步撤销 / 部署级(开机菜单选旧部署或 `rpm-ostree rollback`)/ 基线级(ESP 与 NVRAM)/ 阶段级(退役)。
- 动手前的最低保险:能进系统就先按 `05-9` 固定当前部署;进不去系统就先确认 `baseline/` 可读、救援 U 盘在位。
- **改分区表或固件设置之前**(含 `10-12`、`10-14`、`10-15` 里的偏离动作),按 I4 必须先有可用的基线备份;没有备份时,正确动作是不做。
