# 03:Windows 轨道(L1 安装 + L2 闸门)

本文件在流程中的位置:`02-partitioning`(底座:分盘)-> **本文件(轨道 W)** -> 轨道 L 的 `04-silverblue`。

目标状态、四条不变量与参数名在[入口文档](00-overview.md)中定义;分区数值与分盘动作在 `02-partitioning.md`(本文件不复述);依据见[设计文档](design/00-design.md) 4.2 节(L1)、4.3 节(L2 闸门)、3.10 节(激活)、5.1 节(分区表)与 5.3 节(共享盘)。

## 开始前

- 前提:已完成 `02-partitioning.md` 里本机轨道对应的那一张分盘卡;`baseline/00-firmware.md` 已在位且固件是 UEFI + AHCI/NVMe、Secure Boot 开启、Fast Boot 关闭。
- 需要的东西:Windows 11 专业版官方安装 U 盘(来自微软官方下载域,官方未发布该镜像哈希,故不做 SHA256 比对)、参数表 `DISK_MODEL` / `DISK_SIZE`、厂商 `BOOT_MENU_KEY`。
- 产物落点:L1 两份 `baseline/01-partitions.txt` 与 `baseline/01-activation.md`;L2 四件 `baseline/02-preflight-report.md`、`baseline/02-esp-backup/`、`baseline/02-firmware-entries.txt`、`baseline/02-partitions.txt`。多设备时放 `baseline/<设备别名>/` 下,全部不入库(见 [baseline/README.md](../baseline/README.md))。
- 纪律:L1 与 L2 必须在同一次会话内连续完成(中途若 Windows 完成过一次更新,基线即失效);全程不改 `BootOrder`、不执行 `efibootmgr -o`(I1、I2)。

### 03-1 装 Windows(安装为人工,脚本核对基线)

做:从安装 U 盘以 UEFI 模式启动(菜单里选带 `UEFI:` 前缀的条目),只在 200GiB 的 `C:` 分区上装 Windows 11 专业版;装完进桌面用只读脚本核对版本与分区。分区表已在 `02-partitioning.md` 定稿(ESP 2048 / MSR 16 / `C:` 204800 / `D:` 650240,预留 115GiB 未分配)。
  1. 安装界面里只选 200GiB 那个分区(卷标 `Windows`),**不点"删除""新建""格式化"**
     看到:进桌面后 `Get-Partition -DiskNumber 0` 的序为 ESP 2048MB -> MSR 16MB -> `C:` 204800MB(轨道 D 之后还有 `D:` 650240MB)
  2. 管理员会话跑核对脚本(双系统用 `-Track D`,只 Windows 用 `-Track W`)
     看到:退出码 0,输出"Windows 11 专业版基线通过";同时列出 WinRE 落点与"最大连续未分配"实测值
脚本:scripts/windows/verify-windows-baseline.ps1 -Check -Track D
坑:让安装器自动分区会建 100MB 级 ESP,与定稿表不符(设计 3.4);WinRE 可能落进预留段,只要 ESP 未被削减且未分配仍 ≥115GiB 就接受并把偏差记进产物(设计 4.2)。
出错时:版本或分区不符 -> 回 `02-4` 整盘重排后重装,不做逐分区微调、不做事后缩容;激活未完成 -> `03-4`。

### 03-2 关快速启动与休眠

做:首次进桌面后关掉快速启动与休眠——这是 Linux 侧用 `ntfs3` 挂载共享盘 `D:` 的前提。
  1. 先跑 `-Check` 看读数,再跑 `-Apply -Yes`(`powercfg /h off` 会删掉 `hiberfil.sys`,并把 `HiberbootEnabled` 显式置 0)
     看到:脚本报 PASS;`HiberbootEnabled = 0` 且 `hiberfil.sys` 不存在
  2. 复核电源能力:`powercfg /a`
     看到:"休眠"与"快速启动"均显示为不可用(措辞随 Windows 版本而异)
脚本:scripts/windows/disable-faststartup.ps1 -Check / -Apply -Yes
坑:只删休眠文件而注册表值不为 0 时,快速启动会被下次大版本更新改回来,Linux 挂载共享盘会撞上脏 NTFS 卷(设计 5.3 前置条件第 1 条)。
出错时:改动后仍不达标 -> 确认是管理员会话、再查组策略与厂商电源软件;症状处置见 `10-faq.md`。

### 03-3 已知文件夹重定向(值表:重定向目录清单)

做:把六个已知文件夹与办公约定目录落到 `D:`;这套名字一旦定下不再改(值表逐字如下,L4 的家目录重定向与共享盘用法都对齐它)。
  1. 先跑 `-Check` 看差异,再跑 `-Apply -Yes`(建目标目录并写 `User Shell Folders` 六个值)
     看到:脚本报 PASS;六个值全部以 `D:\` 开头,且 `D:\Shared\` 已建
  2. 在桌面新建一个文件,再查注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
     看到:新文件出现在 `D:\Desktop`;`AppData`、`Local AppData`、`Cache`、`Fonts` 等值仍在 `C:\Users\<用户名>\...` 下

| 项目 | 目标位置 | 注册表值名(`User Shell Folders`) |
|---|---|---|
| 桌面 | `D:\Desktop` | `Desktop` |
| 文档 | `D:\Documents` | `Personal` |
| 下载 | `D:\Downloads` | `{374DE290-123F-4565-9164-39C4925E467B}` |
| 图片 | `D:\Pictures` | `My Pictures` |
| 视频 | `D:\Videos` | `My Video` |
| 音乐 | `D:\Music` | `My Music` |
| 办公约定目录 | `D:\Shared\` | (无;由脚本建目录) |

脚本:scripts/windows/redirect-known-folders.ps1 -Check / -Apply -Yes
坑:把整个 `C:\Users\<用户名>` 搬到 `D:`(或改 `ProfileList`)会破坏"只格式化 `C:` 即可原地重装"这条前提(设计 4.8);游戏库与容器镜像的目录也一并留在 `D:`。
出错时:个别程序不认新路径 -> 把它的工作目录改到 `D:` 下对应子目录;要回退就按 [回滚清单](../checklists/rollback.md) 把该文件夹改回默认路径并更新 `03-5` 的注记。

### 03-4 KMS 激活(人工 + 外链)

做:只读核对授权状态;**激活动作人工**——按上游项目 `massgravel/Microsoft-Activation-Scripts` 的官方入口 https://github.com/massgravel/Microsoft-Activation-Scripts 走 Online KMS 路径。本仓库不含也不分发任何激活脚本本体,不写购买路径,不引入自建 KMS;合规责任由操作者自担(设计 3.10)。
  1. 跑只读脚本核对状态
     看到:已授权时退出码 0(`LicenseStatus = 1`,`GracePeriodRemaining` 给出本周期剩余);未授权时退出码 2(需人工)并给出原因
  2. 激活后核对续期与可达性:打开 `taskschd.msc` 看上游流程创建的续期任务,并确认能访问 KMS 主机的 1688 端口
     看到:续期任务存在且处于启用;端口可达(企业网、校园网与代理环境常在此被拦)
脚本:scripts/windows/check-activation.ps1 -Check
坑:首次激活失败**不阻塞** L1(设计第 7 节 L1 行),但必须把失败状态与报错记进 `01-activation.md`(`03-5`);KMS38 与自建 KMS 都明确排除。
出错时:180 天周期内失效 -> 检查续期任务与 KMS 可达性后重跑一次在线激活流程;仍失败按 `10-faq.md` 登记已知例外。

### 03-5 落 L1 产物

做:把 L1 两份产物写进 `baseline/`:`01-partitions.txt`(分区表定稿值 vs 实测、WinRE 落点与未分配空间偏差、`diskpart` 原始输出、卷标、注记段)与 `01-activation.md`(`slmgr /dlv` 输出、执行日期、上游项目版本号)。
  1. 先跑 `-Check` 看将写入的内容(零写)
     看到:stderr 里逐行列出两份产物内容;`baseline/` 下没有新文件
  2. 加 `-Apply` 落盘;人工补记注记段(已知文件夹重定向核对 / `C:` 内容核对)后再重跑一次
     看到:两份产物在位;补记的行在重跑后被沿用(幂等);退出码由 2(需人工)转为 0
脚本:scripts/windows/collect-l1.ps1 -Check / -Apply
坑:注记段是 L2 判"系统盘隔离"的唯一输入,不补记会让 L2 把它登记为黄项(设计 4.3);产物不入库(`baseline/*` 已被 `.gitignore` 排除)。
出错时:分区表读不到 -> 用管理员会话重跑;激活未成功 -> `03-4`(记录后继续,不阻塞)。

### 03-6 跑只读体检(闸门判据)

做:在**管理员** Windows PowerShell 里跑只读预检,生成闸门报告(逐项实测值 + 红/黄/绿判定 + 末行结论)。红项共六类:存储控制器命中 VMD/RAID、BitLocker 保护已开启、Fast Startup 已开启、最大连续未分配 <115GiB、I4 基线产物缺任一、非管理员会话(报告不可用)。
  1. 跑 `preflight.ps1 -OutFile baseline\02-preflight-report.md -BaselineDir baseline`
     看到:报告在位;此时"I4 基线产物齐备"通常是红(还没做 `03-8`),末行是"结论: 禁止进入 L3"
  2. 逐条处置红项后重跑(黄项只在"补充说明"里登记,带风险继续)
     看到:报告"结论"节的红项一行为 `无`;黄项一行列出的是可带风险继续的项
脚本:scripts/windows/preflight.ps1 -OutFile baseline\02-preflight-report.md -BaselineDir baseline
坑:非管理员会话下存储控制器、BitLocker、固件启动项、分区表都读不到,脚本把结论强制为"禁止进入 L3",报告不可用(设计 4.3);盘尾空隙必然接近 0(WinRE 占盘尾),判据只看"最大连续未分配"。
出错时:BitLocker 保护已开启 -> 先备份 48 位恢复密钥再挂起保护,口径见 `09-risks.md`;最大连续未分配不足 115GiB 或 ESP 被削减 -> 回 `02-4` 整盘重排,不缩容。

### 03-7 读闸门结论(红项停)

做:用脚本解析闸门报告并给出"能否进入 L3"——**只有这一卡给这个结论**;不要手工改报告的判定列,要改状态就改系统后重跑 `03-6`。
  1. 跑 `check-gate.ps1 -Report baseline\02-preflight-report.md`
     看到:全绿时退出码 0,输出"闸门通过:结论允许进入 L3 且无红项(黄项 N 项已登记)";有红项时退出码 1 并逐条列出红项名
  2. 报告缺失或结论行不完整时停在这里,不凭印象判断
     看到:脚本报"闸门报告不存在"或"报告里找不到结论行",并指明回 `03-6` 重跑
脚本:scripts/windows/check-gate.ps1 -Check -Report baseline\02-preflight-report.md
坑:红项一条都不许带进 L3(设计 4.3);手工把判定列改成绿只是跳过闸门,系统状态并未改变。
出错时:红项 -> 按 `03-6` 的出错时:处置后重跑;黄项 -> 记入报告"补充说明"后继续,收尾在 L4/L5 处理。

### 03-8 跑基线备份

做:用脚本把 ESP 全量文件树 + 文件级清单 + 固件启动项与分区快照写进 `baseline/`(I4 基线的最低要求)。
  1. 管理员会话跑 `backup-esp.ps1 -OutDir baseline`
     看到:`baseline\02-esp-backup\EFI\` 子树与 `manifest.sha256` 在位;`02-firmware-entries.txt` 与 `02-partitions.txt` 在位;收尾输出"ESP 已卸载"
  2. 加 `-Check` 复验已有备份(逐文件重算 SHA256 比对,不重做备份)
     看到:退出码 0,输出"备份校验通过:清单 N 行,已比对 N 个文件,逐文件哈希一致"
脚本:scripts/windows/backup-esp.ps1 -OutDir baseline / -Check
坑:本脚本只写 `-OutDir`,**绝不改 ESP 内容**;`manifest.sha256` 是清单自身,既不进清单也不得复制回 ESP。旧手册里的"ESP 镜像"一律指这份文件树 + 清单。
出错时:报"需要管理员权限" -> 用管理员会话重跑;报挂载点上没有 `EFI` 目录 -> 人工核对分区表后再重跑;复原流程见 `07-rescue.md`。

### 03-9 落 L2 产物

做:核对 L2 四件产物齐全且可读——`02-preflight-report.md`(须含结论行)、`02-esp-backup/`(含 `EFI/` 子树与 `manifest.sha256`)、`02-firmware-entries.txt`、`02-partitions.txt`;另附核对 L1 两份产物。
  1. 跑 `collect-l2.ps1 -BaselineDir baseline`
     看到:退出码 0,逐项列出四件产物的字符数/行数与清单行数,末行"L2 四件产物齐备且结论为允许进入 L3"
  2. 再重跑一次 `03-6` 的体检让"I4 基线产物齐备"由红转绿,然后回 `03-7` 读定稿结论
     看到:报告该行为绿;末行为"结论: 允许进入 L3";此后才可进入轨道 L 的 `04-silverblue`
脚本:scripts/windows/collect-l2.ps1 -Check -BaselineDir baseline
坑:四件产物缺任一即 I4 不满足、禁止进入 L3(设计 4.3);本卡无自动写动作(产物由 `03-6` 与 `03-8` 生成),产物不入库,`baseline/` 只保留 `README.md`。
出错时:缺件或不合规 -> 按 checks 的失败项行回到生成者(`03-6` 或 `03-8`);结论为禁止 -> `03-7`。
