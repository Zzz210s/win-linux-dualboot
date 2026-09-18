# baseline/ — 每台设备的本地部署产物(不入库)

本目录只保留本文件;其余内容全部被 `.gitignore` 排除,因为它们是**单台设备的私有数据**(分区表、ESP 镜像、固件启动项、激活状态)。

## 为什么存在

设计原则:每个阶段必须留下可验证的产物,下一阶段只读产物,不靠"记忆里的某个数字"。产物落盘在本目录,机器相关数据不进公开仓库。

## 命名规范

| 文件 | 由哪个阶段产出 | 内容 |
|---|---|---|
| `00-firmware.md` | L0 装机前 | 固件设定记录(SATA/NVMe 模式、Secure Boot、Fast Boot)、固件版本、CPU/GPU/网卡型号、安装介质校验值 |
| `01-partitions.txt` | L1 Windows 安装 | `diskpart` 分区表输出(各分区偏移与大小)+ L1 隔离核对结论(已知文件夹重定向与 C: 内容,注记段) |
| `01-activation.md` | L1 Windows 安装 | `slmgr /dlv` 与激活状态复核输出 |
| `02-esp-backup/` | L2 预检 | ESP 全量文件树(含 `EFI\` 子树)与 `manifest.sha256` 文件级清单,基线回滚用;块级整块镜像可选,不属主路径 |
| `02-partitions.txt` | L2 预检 | 分区快照(`diskpart` 与 `Get-Partition` 输出),用于核验 L1 定稿的分区表未被改动 |
| `02-firmware-entries.txt` | L2 预检 | `bcdedit /enum firmware` 快照 + `BootOrder` |
| `02-preflight-report.md` | L2 预检 | 闸门报告:红/黄/绿 + 是否允许进入 L3 |
| `03-efi-layout.txt` | L3 Ubuntu 安装 | `\EFI\` 目录树 + `efibootmgr -v` + `BootOrder` + `lsblk` |
| `04-first-boot.md` | L4 首启收敛 | 会话类型、GPU 模块状态、ntfs3 挂载、时间、蓝牙 key 同步结果 |
| `04-robustness.md` | L4 首启收敛 | 健壮性核对:快照可用性与回滚演练、journald 持久化、SSH 可达、更新策略、SMART 状态 |

## 多设备用法

每台设备一个子目录:

```
baseline/
├─ README.md
├─ device-a/01-partitions.txt
├─ device-b/01-partitions.txt
```

跑完 L4 后,把与 `docs/00-overview.md` 设备参数表的**偏差**回写进去:这是"同规格设备"适配表迭代的唯一输入来源。
