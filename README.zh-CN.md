# win-linux-dualboot

[English](README.md) | 简体中文

一套可复现的部署手册:在**全新、同规格的设备**上安装 **Windows 11 专业版 + Ubuntu 26.04 LTS** 双系统。面向"多台同规格设备"的批量部署,并且**能完整撤除而不损坏 Windows 引导**。

> 状态:**设计阶段**。设计文档已完成;分步手册与脚本正在编写。

## 这套方案要解决什么

多数双系统教程有两条典型死法:

1. 教你在已有生产力系统上"缩小分区"——"缩容失败""BitLocker 索要恢复密钥""安装器看不到 NVMe"这些事故都出自这里;
2. 装完之后固件启动顺序指向了 Linux。等你哪天把 Linux 分区格式化掉,下次重启就停在 `grub>` / `grub rescue>`,Windows 也进不去。

本方案假设**整盘重装**(所以分区只规划一次,而不是后期做手术),并把"安全撤除 Linux"当作一等公民流程来设计与验证,而不是事后补救。

## 四条不变量

手册里的每一步都服从这四条。真正防住引导锁死的是它们,而不是某个具体工具。

| 编号 | 不变量 | 防住的事故 |
|---|---|---|
| I1 | `BootOrder` 第一位**永远是 Windows Boot Manager** | 删除 Linux 后重启停在失效条目 |
| I2 | 进 Linux 只用**一次性 `BootNext`**(或厂商启动菜单键),绝不靠调整 `BootOrder` 顺序 | 留下一个没人记得撤销的永久顺序 |
| I3 | 绝不覆盖 `\EFI\Microsoft\`,绝不修改 `{bootmgr}` 的路径 | Windows 引导路径被第三方接管 |
| I4 | 改分区表或固件设置之前先做**基线备份**(BitLocker 挂起、ESP 镜像、固件启动项快照) | 除重装外无路可退 |

## 两侧都做隔离

方案在**两个系统上都把系统与数据分开**,所以任何一边崩都不会拖垮另一边:

- **Windows**:200GiB 系统分区(`C:`)+ ≈635GiB 数据分区(`D:`);桌面/文档/下载等已知文件夹、游戏库、容器镜像全部重定向到 `D:`。重装 Windows 只格式化 `C:`。
- **Ubuntu**:100GiB root + 独立 15GiB 快照分区。文档/下载/图片/桌面放在共享盘上,root 因此保持很小;升级翻车时回滚 root,不会连带毁掉快照历史。

两边都能**在原盘上原地恢复**:设计文档第 4.8 节给了两法——只格式化 `C:` 重装 Windows、只格式化 root 重装 Ubuntu(**绝不格式化 ESP**),以及引导层损坏时不需要重装的修复路径。

## 两个系统都能读写的共享盘

`D:` 是**共享分区**:Windows 侧原生访问,Ubuntu 侧以内核 `ntfs3` 驱动读写挂载。在 Windows 里编辑的办公文件,切到 Linux 就能直接打开——不需要拷贝,也不需要中转介质。四项前提保证它的安全:关闭 Fast Startup 与休眠、`D:` 不启用 BitLocker、挂载时固定 `uid`/`gid`/`umask` 并加 `windows_names`、以及不在共享盘上做依赖 POSIX 语义的工作(符号链接、权限位、大小写敏感重命名)。

## 适用设备类

需同时满足:

- 单块 NVMe SSD,标称 1TB(实际可用约 953GiB,属于「近似但小于 1TB」的容量级,不是 1TiB),UEFI + GPT;
- 混合显卡(集显 + NVIDIA/AMD 独显);
- Windows 侧目标为 Windows 11 专业版,Linux 侧为 Ubuntu 26.04 LTS;
- 允许整盘格式化。

偏离项(两块盘、已有 ESP 小于 1GiB、BitLocker 已启用、VMD/RAID 模式锁定无法更改、仅独显)会分别给出"适配分支"或明确标注**不适用**,详见 `docs/00-overview.md`。

## 目录结构

```
docs/                  执行手册,按执行顺序编号(00-09)
docs/design/           为什么这样设计
scripts/windows/       PowerShell 辅助脚本,默认只读或 dry-run
scripts/linux/         首启收敛辅助脚本
templates/             diskpart 脚本、fstab/sysctl 片段
checklists/            部署与回滚核对清单
baseline/              每台设备的部署产物(永不入库)
```

## 怎么用

从 `docs/00-overview.md` 开始,按阶段顺序推进。每个阶段结束时必须在 `baseline/` 留下可验证的产物;**没有产物的阶段视为未完成**。L2 是硬闸门:若报告红项,不得继续进入 Ubuntu 安装。

## 验收

是否完成,以 `docs/08-verification.md` 全绿为唯一判据,不以"装完了"为准。验收集包含一次**可逆的撤除演练**:临时删掉 `\EFI\ubuntu\`,确认机器仍能自动进 Windows、不出现 `grub rescue`,再用 ESP 镜像还原。另有一组健壮性验收:快照回滚演练一次、journald 持久化、SSH 救援通道可达、保守更新策略、SMART 磁盘健康。还有一组原地恢复验收:系统盘隔离真实生效,且两条重装路径均已完整推演。

## 健壮性措施

失去一个可用系统的代价远高于重装,所以 Ubuntu 侧做了九项加固:变更前快照(独立的 15GiB 快照分区)、保留旧内核配合 `GRUB_DEFAULT=saved` 支持一次性启动、常备救援 U 盘、journald 持久化以保留崩溃日志、zram + `systemd-oomd` 内存压力防护、常开 SSH 救援通道、保守更新策略(仅安全更新、绝不自动重启)、SMART 磁盘监控、所有非 root 挂载点均带 `nofail`。详见 `docs/design/00-design.md` 第 4.7 节。

## 风险

已知故障类型(Intel VMD/RAID、BitLocker 恢复提示、Windows 更新重写 ESP、Secure Boot 下 NVIDIA 模块签名、两系统间时间与蓝牙状态分裂)连同缓解手段列在 `docs/09-risks.md`。

## 许可

MIT,见 [LICENSE](LICENSE)。
