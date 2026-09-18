#!/usr/bin/env bash
# L4:显卡驱动与 Wayland 收敛校验(决策 3.3/3.17/3.18、设计 4.5、第 7 节故障矩阵、11.1 评论区证据)。
#
# 用法:bash scripts/linux/graphics.sh [--apply] [--log <path>]
#   默认 dry-run:打印显卡与 Secure Boot 采集结果、将执行的动作、回退指引,不改动系统。
#   --apply(需要 root)才真正收敛驱动:
#     1) 采集:lspci -nn | grep -E 'VGA|3D';mokutil --sb-state;cat /proc/cmdline(查残留 nomodeset)
#     2) 只用 Ubuntu 仓库的**预签名**模块包:缺则 apt install ubuntu-drivers-common -> ubuntu-drivers list(候选与版本)-> ubuntu-drivers install(装完需重启 + 重跑本脚本复核);
#        **不做 DKMS 编译、不用 nvidia-open 源码构建** —— Secure Boot 保持开启,自编译模块签名会被拒(决策 3.3)
#     3) 校验 lsmod 里的 nvidia;dmesg 报 'key was rejected'/lockdown 即打印回退 nouveau 的命令并返回非零;刚装完的同一轮模块通常未载入当前内核,该情形只记 hint(需重启后重跑),不判失败(dry-run 不改系统,本脚本所有 DBK-RESULT fail 行降为 dry-run-fail,避免 first-boot.sh 摘要"状态 ok + key 列 fail"并存)
#     4) 混合显卡打印 PRIME offload 用法;5) 校验 XDG_SESSION_TYPE=wayland 与 wayland-info/modetest 存在性(判据第 7-9 行);取不到会话类型时按用户查 loginctl(docs/05-first-boot.md 同款命令),置"未判定"而非"通过"
#     6) 打印黑屏/闪烁、引导菜单黑屏与 MUX 分支(BIOS 切独显直连)指引及其代价;7) 提示内核/驱动不参与自动更新(决策 3.18)
#   环境开关:DBK_SKIP_APT=1 只跳过 apt 安装,用于无 apt/无网络的静态校验;DBK_CMDLINE=<文件> 可替换 /proc/cmdline(离线校验 nomodeset 判据用)。
#   日志追加到 /var/log/dbk/graphics.log(目录不可写时只输出到终端);结果打成 DBK-RESULT 行供 first-boot.sh 摘要提取。
#   退出码:0 = 校验通过(dry-run 恒为 0);1 = 有失败项;hint/未判定项(刚装驱动需重启、取不到会话类型、SKIP_APT)走未判定分支,不宣称通过。
#   依据:决策 3.3(Secure Boot 保持开启、不自签)、3.17(MUX 分支与代价)、3.18(内核/驱动不自动更新)、4.5(L4 显卡行)。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for f in dbk-log.sh dbk-apt.sh; do [ -r "$HERE/$f" ] || { echo "错误: 缺少 $HERE/$f" >&2; exit 1; }; done
LOG="${DBK_LOG:-/var/log/dbk/graphics.log}"
source "$HERE/dbk-log.sh"
source "$HERE/dbk-apt.sh"

DRV_CMD="${DBK_DRIVER_CMD:-ubuntu-drivers}"
DRV_PKG="${DBK_DRIVER_PKG:-ubuntu-drivers-common}"
GRUB_TPL="${DBK_GRUB_TPL:-$ROOT/templates/grub-defaults.snippet}"
SKIP_APT="${DBK_SKIP_APT:-0}"; CMDLINE="${DBK_CMDLINE:-/proc/cmdline}"
APPLY=0; RC=0; N_NV=0; N_IG=0; HYBRID=0; INCONCLUSIVE=0; JUST_INSTALLED=0

usage() { sed -n '2,15p' "$0"; }
have() { command -v "$1" >/dev/null 2>&1; }
# 已装 NVIDIA 驱动包清单(包名=版本,排序后一行):用于安装前后比对,判断本轮是否真的改变了包状态
nv_pkgs() { dpkg-query -W -f='${Package}=${Version} ' 'nvidia-driver-*' 2>/dev/null | sort | tr '\n' ' '; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply|--dry-run) [ "$1" = --apply ] && APPLY=1 || APPLY=0; shift ;;
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done
case "$SKIP_APT" in 1|0) ;; *) die "DBK_SKIP_APT 只接受 0/1: $SKIP_APT" ;; esac
RES_FAIL=fail; [ "$APPLY" -eq 1 ] || RES_FAIL=dry-run-fail

# 1) 采集:显卡型号与厂商 ID、核显/独显计数、Secure Boot、内核命令行(是否残留 nomodeset)
collect() {
  local gpu sb line
  log "步骤 1: 采集显卡、Secure Boot 与内核命令行"
  if have lspci; then
    gpu="$(lspci -nn 2>/dev/null | grep -E 'VGA|3D' || true)"
    if [ -n "$gpu" ]; then
      log "显卡(lspci -nn):
$(printf '%s\n' "$gpu" | sed 's/^/  /')"
      N_NV="$(printf '%s\n' "$gpu" | grep -ci '10de' || true)"
      N_IG="$(printf '%s\n' "$gpu" | grep -Eci '8086|1002' || true)"
      if [ "$N_NV" -gt 0 ] && [ "$N_IG" -gt 0 ]; then
        HYBRID=1; log "判定: 混合显卡(核显 $N_IG + NVIDIA 独显 $N_NV)-> 集成显卡主显示 + PRIME offload(设计 4.5)"
      elif [ "$N_NV" -gt 0 ]; then
        log "判定: 仅 NVIDIA 独显($N_NV)-> 单显卡设备,跳过 PRIME offload(设计 4.5)"
      fi
    else
      log "提示: lspci 未列出 VGA/3D 设备(受限环境或纯远程会话?)"
    fi
  else
    log "提示: 无 lspci(装 pciutils 后可识别);当前环境可能不是 Ubuntu/Linux,跳过显卡识别"
  fi
  if have mokutil; then
    sb="$(mokutil --sb-state 2>&1 | head -n 1)"; log "Secure Boot: $sb"
    case "$sb" in
      *enabled*) log "符合决策 3.3:Secure Boot 保持开启,驱动只走仓库预签名包" ;;
      *disabled*) log "提示: Secure Boot 处于关闭;仍按预签名包安装,不关 SB、不自签(偏差记入 baseline/04-first-boot.md)" ;;
      *) log "提示: 无法解析 mokutil 输出,请人工确认 Secure Boot 状态" ;;
    esac
  else
    log "提示: 无 mokutil,Secure Boot 状态待人工确认(mokutil --sb-state)"
  fi
  if [ -r "$CMDLINE" ]; then line="$(cat "$CMDLINE")"
    if printf '%s' "$line" | grep -qw nomodeset; then
      log "DBK-RESULT $RES_FAIL 内核命令行残留 nomodeset(判据第 7 行的 /proc/cmdline 半项):nomodeset 只是应急的临时手段,装好驱动后必须移除 —— 它关掉 KMS,Wayland 起不来(设计 11.1);移除:删掉 /etc/default/grub 里的它 -> sudo update-grub -> 重启"; RC=1
    else
      log "内核命令行未含 nomodeset(符合判据)"
    fi
  else
    log "提示: 读不到 $CMDLINE(非 Linux),跳过 nomodeset 检查"
  fi
  log "驱动路径: 只用 $DRV_CMD 的仓库预签名模块;**禁止 DKMS 编译与 nvidia-open 源码构建**(Secure Boot 下自编译模块签名必被拒);更新纪律(决策 3.18): 内核与显卡驱动不参与自动更新,升级/换内核前先做 R1 快照并保留旧内核作为退路"
}

# 3)+5) 校验:模块加载与签名(签名被拒即回退 nouveau)、会话类型与 Wayland/DRM 工具
verify() {
  local mods sig st sid tools=""
  log "步骤 3: 校验模块加载与签名"
  if have lsmod; then
    mods="$(lsmod 2>/dev/null | grep -E '^nvidia' | awk '{print $1}' | head -n 3 | tr '\n' ' ' || true)"
    if [ -n "$mods" ]; then
      log "DBK-RESULT ok nvidia 模块已加载: $mods"
    elif [ "$N_NV" -gt 0 ] && [ "$JUST_INSTALLED" -eq 1 ]; then
      log "DBK-RESULT hint 驱动刚安装,需重启后重跑复核(判据:重启后 lsmod 有 nvidia 且 XDG_SESSION_TYPE=wayland)"; INCONCLUSIVE=1
    elif [ "$N_NV" -gt 0 ]; then
      log "DBK-RESULT $RES_FAIL nvidia 模块未加载(lsmod 无 nvidia*):驱动未生效;若当前是 nouveau 兜底则桌面仍可用"; RC=1
    else
      log "DBK-RESULT skipped nvidia 模块:本机未见 NVIDIA 独显(或无 lspci 数据)"
    fi
  else
    log "DBK-RESULT skipped nvidia 模块:无 lsmod 命令(非 Linux)"; INCONCLUSIVE=1
  fi
  if have dmesg; then
    sig="$(dmesg 2>/dev/null | grep -iE 'key was rejected|lockdown' | tail -n 2 | tr '\n' ';' || true)"
    if [ -n "$sig" ]; then log "DBK-RESULT $RES_FAIL 模块签名被 Secure Boot 拒绝或出现 lockdown: $sig"; RC=1; fi
  fi
  log "步骤 5: 校验会话类型与 Wayland 工具"
  st="${XDG_SESSION_TYPE:-}"
  if [ -z "$st" ] && have loginctl; then
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="${SUDO_USER:-${USER:-root}}" '$3==u {print $1; exit}')"
    [ -n "$sid" ] && st="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
  fi
  if [ "$st" = wayland ]; then
    log "DBK-RESULT ok XDG_SESSION_TYPE=wayland(判据第 7 行)"
  elif [ -z "$st" ]; then
    log "DBK-RESULT 未判定 取不到会话类型(XDG_SESSION_TYPE 为空且 loginctl 未查到本用户会话):不构成通过;登录桌面后重跑本脚本复核(echo \$XDG_SESSION_TYPE)"; INCONCLUSIVE=1
  else
    log "DBK-RESULT $RES_FAIL XDG_SESSION_TYPE=$st:期望 wayland;先查 nomodeset 与驱动加载,再考虑重建会话"; RC=1
  fi
  for c in wayland-info modetest glxinfo; do have "$c" && tools="$tools $c"; done
  if [ -n "$tools" ]; then log "Wayland/DRM 工具可用:$tools(wayland-info 可查合成器,glxinfo 可配合 PRIME 校验渲染器)"
  else log "提示: wayland-info/modetest/glxinfo 均不存在(可选安装:sudo apt install -y wayland-utils libdrm-tests mesa-utils)"; fi
}

# 4)+6) 指引:PRIME 用法、黑屏/闪烁回退、引导菜单黑屏(3.19)、MUX 分支与代价(3.17)、不降级发行版
guide() {
  if [ "$HYBRID" -eq 1 ]; then
    log "PRIME offload(混合显卡): __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <命令>;校验渲染器: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B | grep 'OpenGL renderer'(期望 NVIDIA)"
  else
    log "PRIME offload: 非混合显卡(或未识别到核显)时跳过本项(设计 4.5)"
  fi
  log "若装完驱动黑屏/闪烁: 切 TTY(Ctrl+Alt+F3)登录 -> 卸载专有驱动回 nouveau -> 再调驱动版本/PRIME 模式"
  log "回退 nouveau 三步(纯指引,不自动执行;不要用 apt purge '^nvidia-.*' 通配:apt 正则会把 nvidia-cuda-toolkit / nvidia-container-toolkit(-base) / nvidia-docker2 / nvidia-settings 等非驱动包一起摘掉,-y 又抹掉确认):"
  log "  1) 先列将删项并人工过一眼: dpkg -l | grep -E '^(ii|iU) +(nvidia|libnvidia|linux-modules-nvidia|linux-signatures-nvidia)'"
  log "  2) 按上面清单用**精确包名**逐个移除(不要通配、不要 -y): sudo apt-get remove --purge <逐个包名>"
  log "  3) sudo apt-get autoremove -> sudo update-initramfs -u -> sudo reboot;装了 CUDA/容器运行时要单独评估(它们不会随 nouveau 一起回来)"
  log "  再确认 /etc/modprobe.d/*nouveau*.conf 无 blacklist 残留、/etc/default/grub 无残留的 nomodeset / nvidia-drm.modeset=1"
  log "  nouveau 是天然回滚点(设计 4.5 回滚列);不注册自签 MOK、不关 Secure Boot(决策 3.3);不要长按电源,用 REISUB(SysRq)"
  log "若每次开机在引导菜单阶段黑屏(键盘仍可用): 按决策 3.19 启用 GRUB_TERMINAL=console($GRUB_TPL 的条件项)-> sudo update-grub;菜单黑屏不等于系统坏了,不要重装"
  log "若混合模式下装完驱动仍点不亮/反复黑屏: 走设计 3.17 的 MUX 分支 —— BIOS 切'独显直连'先拿到可用系统,再评估是否切回混合"
  log "  独显直连的代价: 所有进程占用独显显存、续航明显变差、日后本地推理的显存被显示输出吃掉(不作默认);驱动不认时的顺序: 换更新内核(HWE)-> 换驱动版本 -> 才考虑发行版问题,不因驱动问题降级发行版(设计第 9 节)"
}

log "=== 显卡与 Wayland 校验(mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run);日志 $LOG)==="
collect

log "步骤 2: 驱动安装(仅 Ubuntu 仓库预签名包)"
if [ "$APPLY" -ne 1 ]; then
  log "将执行: 缺 $DRV_CMD 时 apt-get install -y $DRV_PKG -> $DRV_CMD list(看候选与版本)-> $DRV_CMD install(仓库预签名模块,不编译)-> 装完需重启 + 重跑本脚本复核"
else
  [ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo bash $0 --apply"
  st_pkg=0
  if have "$DRV_CMD"; then
    log "$DRV_CMD 已可用,跳过 apt-get install $DRV_PKG"
  else
    st_pkg=0; apt_ensure "$DRV_PKG" "sudo apt install -y $DRV_PKG" || st_pkg=$?
    [ "$st_pkg" -eq 1 ] && RC=1
  fi
  if have "$DRV_CMD"; then
    out_list="$("$DRV_CMD" list 2>&1)"; log "$DRV_CMD list 候选(安装前可见性): $(printf '%s' "$out_list" | tail -n 10 | tr '\n' ';')"
    pkgs0="$(nv_pkgs)"; log "当前已装驱动版本: nvidia-smi=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '\r' || echo 无) dpkg=${pkgs0:-无}"
    out="$(DEBIAN_FRONTEND=noninteractive "$DRV_CMD" install 2>&1)"; st=$?
    if [ "$st" -eq 0 ]; then
      log "$DRV_CMD install: 成功(走 Ubuntu 仓库预签名包,无 DKMS 编译)"
      if [ "$(nv_pkgs)" != "$pkgs0" ]; then JUST_INSTALLED=1; log "已装驱动包清单发生变化 -> 标记刚安装(本轮模块未载入时走 hint,需重启后重跑复核)"; fi
    else
      log "错误: $DRV_CMD install 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; RC=1
    fi
  elif [ "$st_pkg" -eq 9 ]; then
    log "DBK_SKIP_APT=1:未安装 $DRV_PKG,$DRV_CMD 不可用,跳过驱动安装(仅做静态校验)"; INCONCLUSIVE=1
  else
    log "错误: 无 $DRV_CMD 命令(需 $DRV_PKG 包);硬前置: 必须先执行 sudo apt install -y $DRV_PKG 再重跑本脚本"; RC=1
  fi
fi

verify
log "步骤 6: 排障与回退指引(对应设计与第 7 节故障矩阵)"
guide

if [ "$APPLY" -ne 1 ]; then
  log "=== dry-run 完成:未改动系统;上面 DBK-RESULT 行仅供参考,正式判定在 --apply ==="
  exit 0
fi
if [ "$RC" -ne 0 ]; then
  log "结束: 有未通过项,见上面 DBK-RESULT 行与回退指引;修好后可重跑本脚本"
elif [ "$INCONCLUSIVE" -eq 1 ]; then
  log "未判定: 本次未能判定全部判据(驱动刚装待重启 / SKIP_APT / 非 Linux / 取不到会话类型);不构成通过,请在 Ubuntu 桌面会话内重跑 --apply 复核(判据:XDG_SESSION_TYPE=wayland 且 lsmod 有 nvidia)"
else
  log "完成: 显卡驱动与会话校验通过(判据:XDG_SESSION_TYPE=wayland 且 NVIDIA 模块已加载)"
fi
exit "$RC"
