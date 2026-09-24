#!/usr/bin/env bash
# 对应卡:02-3,04-2,07-5
# L3 前置核对(在 Kubuntu live 环境里跑):读当前磁盘布局(lsblk / blkid / sgdisk -p)与定稿分区计划比对,
# 输出"下一步该建什么";并硬断言 Windows ESP 未被挂载、未被改动(读不到 → FAIL 并提示停手)。
# 定稿值(设计 5.1 / 设计 04 第 4 节,一字不改):ESP-Windows 2048MiB / MSR 16MiB / C: 204800MiB / D: 650240MiB /
#   ESP-Ubuntu 1024MiB(FAT32,挂 /boot/efi)/ /boot 1024MiB(ext4)/ root ≈113GiB(ext4);轨道 D 预留区 115GiB。
# 人工边界:分区与 Calamares 的点击都是人工(设计 S2);本脚本无写动作,--apply 与 --check 输出相同。
# 轨道:--track D(缺省;双系统,Ubuntu 三块建在 115GiB 预留区内)/ --track L(只装 Kubuntu,整盘三块)。
# 夹具级验证,真机未跑。用法:
#   check-partition-plan.sh [--track L|D] [--disk <设备>] [--check|--apply] [--json] [--log <路径>] [--step NN-K]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

TRACK="${DBK_TRACK:-D}"; DISK="${DBK_DISK:-}"; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --track) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --track 缺取值(L / D)"; exit "$DBK_USAGE"; }; TRACK="$2"; shift 2 ;;
    --track=*) TRACK="${1#*=}"; shift ;;
    --disk) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --disk 缺取值(如 /dev/nvme0n1)"; exit "$DBK_USAGE"; }; DISK="$2"; shift 2 ;;
    --disk=*) DISK="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "check-partition-plan"
case "$TRACK" in L|D) ;; *) dbk_usage; dbk_note "用法错误: --track 只认 L / D(实为 '$TRACK')"; exit "$DBK_USAGE" ;; esac
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本无写动作(分区与 Calamares 的点击都是人工);--apply 与 --check 输出相同。"; fi

WIN_ESP_MIB=2048; UBU_ESP_MIB=1024; BOOT_MIB=1024; ROOT_MIN_MIB=115712; RESERVE_MIB=117760
lb_get() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=\"\(.*\)\"\$/\1/p" | head -n1; }
to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/1048576}'; }

if ! command -v lsblk >/dev/null 2>&1; then
  dbk_add_check "缺少 lsblk"
  dbk_exit FAIL "缺少 lsblk,无法读取磁盘布局;请在 Kubuntu live 环境里运行本脚本"
fi
# shellcheck disable=SC2054  # 逗号是 lsblk -o 的列分隔符(有意为之,不是数组元素分隔符)
LSB_ARGS=(-P -b -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,PARTUUID,MOUNTPOINT)
if [ -n "$DISK" ]; then
  LAYOUT="$(lsblk "${LSB_ARGS[@]}" "$DISK" 2>&1)" || { dbk_add_check "lsblk 读取失败"; dbk_exit FAIL "lsblk 读取失败: $LAYOUT"; }
else
  LAYOUT="$(lsblk "${LSB_ARGS[@]}" 2>&1)" || { dbk_add_check "lsblk 读取失败"; dbk_exit FAIL "lsblk 读取失败: $LAYOUT"; }
fi
[ -n "$LAYOUT" ] || { dbk_add_check "lsblk 无输出"; dbk_exit FAIL "lsblk 读不到任何磁盘;停手并核对存储控制器模式(见 01-3)"; }

P_NAME=(); P_SIZE=(); P_FS=(); P_TYPE=(); P_MNT=(); D_NAME=(); D_SIZE=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$(lb_get "$line" TYPE)" in
    disk) D_NAME+=("$(lb_get "$line" NAME)"); D_SIZE+=("$(lb_get "$line" SIZE)") ;;
    part)
      P_NAME+=("$(lb_get "$line" NAME)"); P_SIZE+=("$(lb_get "$line" SIZE)"); P_FS+=("$(lb_get "$line" FSTYPE)")
      P_TYPE+=("$(lb_get "$line" PARTTYPENAME)"); P_MNT+=("$(lb_get "$line" MOUNTPOINT)") ;;
  esac
done <<<"$LAYOUT"
[ "${#P_NAME[@]}" -gt 0 ] || { dbk_add_check "磁盘上没有分区"; dbk_exit FAIL "磁盘上没有分区(lsblk 只有盘);停手并核对目标盘(见 01-3)"; }

# Windows ESP:vfat 且尺寸在定稿值 2048MiB 附近(允许 ±100MiB 的扇区对齐误差)
WIN_ESP=-1; VFAT_ANY=-1
for i in "${!P_NAME[@]}"; do
  [ "$(printf '%s' "${P_FS[$i]}" | tr 'A-Z' 'a-z')" = vfat ] || continue
  VFAT_ANY="$i"; m="$(to_mib "${P_SIZE[$i]}")"
  if [ "$m" -ge $((WIN_ESP_MIB - 100)) ] && [ "$m" -le $((WIN_ESP_MIB + 100)) ]; then WIN_ESP="$i"; fi
done

ISSUES=()
if [ "$WIN_ESP" -lt 0 ]; then
  if [ "$TRACK" = D ]; then
    if [ "$VFAT_ANY" -ge 0 ]; then
      dbk_add_check "EFI 分区 ${P_NAME[$VFAT_ANY]} 为 $(to_mib "${P_SIZE[$VFAT_ANY]}")MiB,与 Windows ESP 定稿值 ${WIN_ESP_MIB}MiB 不符"
      dbk_exit FAIL "Windows ESP 与定稿值不符(期望 ${WIN_ESP_MIB}MiB);停手:不要继续分区,先核对盘与 01-3"
    fi
    dbk_add_check "未发现 Windows ESP"
    dbk_exit FAIL "读不到 Windows ESP(${WIN_ESP_MIB}MiB vfat);停手:核对是否选错盘,绝不在读不到 Windows ESP 时继续"
  fi
  dbk_add_check "未发现 Windows ESP(轨道 L 单系统,跳过 Windows ESP 断言)"
else
  dbk_add_check "Windows ESP: /dev/${P_NAME[$WIN_ESP]} ${WIN_ESP_MIB}MiB(vfat)"
  if [ -n "${P_MNT[$WIN_ESP]}" ]; then
    dbk_add_check "Windows ESP 被挂载在 ${P_MNT[$WIN_ESP]}"
    dbk_exit FAIL "Windows ESP 被挂载(${P_MNT[$WIN_ESP]});停手:绝不能挂载或改动 Windows ESP(不变量 I3)"
  fi
  dbk_add_check "Windows ESP 未被挂载"
  WIN_DEV="/dev/${P_NAME[$WIN_ESP]}"; BLK=""
  if command -v blkid >/dev/null 2>&1; then BLK="$(blkid "$WIN_DEV" 2>&1)" || BLK=""; fi
  if printf '%s' "$BLK" | grep -qi 'TYPE="vfat"'; then
    dbk_add_check "Windows ESP 可读:$WIN_DEV($BLK)"
  else
    dbk_add_check "Windows ESP 读不到:$WIN_DEV"
    dbk_exit FAIL "读不到 Windows ESP($WIN_DEV,blkid 无 vfat 输出);停手:核对盘与权限,不要继续分区"
  fi
fi

# 目标盘:优先 --disk,否则取 Windows ESP 所在的盘
TARGET_DISK=""; DISK_BYTES=0
if [ -n "$DISK" ]; then
  TARGET_DISK="$(basename "$DISK")"
  for j in "${!D_NAME[@]}"; do
    if [ "${D_NAME[$j]}" = "$TARGET_DISK" ]; then DISK_BYTES="${D_SIZE[$j]}"; fi
  done
elif [ "$WIN_ESP" -ge 0 ]; then
  for j in "${!D_NAME[@]}"; do
    case "${P_NAME[$WIN_ESP]}" in
      "${D_NAME[$j]}"p*|"${D_NAME[$j]}"[0-9]*) TARGET_DISK="${D_NAME[$j]}"; DISK_BYTES="${D_SIZE[$j]}" ;;
    esac
  done
fi
[ -n "$TARGET_DISK" ] || { dbk_add_check "无法确定目标盘"; dbk_exit FAIL "无法确定目标盘(Windows ESP 的父盘不在 lsblk 输出里);用 --disk <设备> 显式指定"; }

# Ubuntu 三块(只看目标盘;按文件系统类型 + 尺寸找候选,尺寸不符即 FAIL)
in_target() { case "${P_NAME[$1]}" in "${TARGET_DISK}"p*|"${TARGET_DISK}"[0-9]*) return 0 ;; *) return 1 ;; esac; }
UBU_ESP=-1; BOOT_P=-1; ROOT_P=-1
for i in "${!P_NAME[@]}"; do
  in_target "$i" || continue
  [ "$i" -eq "$WIN_ESP" ] && continue
  fs="$(printf '%s' "${P_FS[$i]}" | tr 'A-Z' 'a-z')"; m="$(to_mib "${P_SIZE[$i]}")"
  case "$fs" in
    vfat)
      if [ "$m" -ge $((UBU_ESP_MIB - 100)) ] && [ "$m" -le $((UBU_ESP_MIB + 100)) ]; then UBU_ESP="$i"
      else ISSUES+=("ESP-Ubuntu 尺寸错:期望 ${UBU_ESP_MIB}MiB,实际 ${m}MiB(${P_NAME[$i]})"); fi ;;
    ext4)
      if [ "$m" -ge $((BOOT_MIB - 100)) ] && [ "$m" -le $((BOOT_MIB + 100)) ]; then BOOT_P="$i"
      elif [ "$m" -ge "$ROOT_MIN_MIB" ]; then ROOT_P="$i"
      else ISSUES+=("ext4 分区尺寸不匹配:既不是 /boot(${BOOT_MIB}MiB)也不是 root(≥${ROOT_MIN_MIB}MiB),实际 ${m}MiB(${P_NAME[$i]})"); fi ;;
  esac
done
if [ "$UBU_ESP" -ge 0 ]; then dbk_add_check "ESP-Ubuntu: /dev/${P_NAME[$UBU_ESP]} ${UBU_ESP_MIB}MiB(vfat)"; fi
if [ "$BOOT_P" -ge 0 ]; then dbk_add_check "/boot: /dev/${P_NAME[$BOOT_P]} ${BOOT_MIB}MiB(ext4)"; fi
if [ "$ROOT_P" -ge 0 ]; then dbk_add_check "root: /dev/${P_NAME[$ROOT_P]}(ext4,≥${ROOT_MIN_MIB}MiB)"; fi

# 轨道 D:预留区(Windows 数据分区末端 -> WinRE 起点)不得被压缩到 115GiB 以下
if [ "$TRACK" = D ] && command -v sgdisk >/dev/null 2>&1; then
  SGD="$(sgdisk -p "/dev/$TARGET_DISK" 2>&1)" || SGD=""
  if [ -n "$SGD" ]; then
    DSEC=$((DISK_BYTES / 512))
    REG="$(printf '%s\n' "$SGD" | awk -v disk_end="$DSEC" '
      /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {
        code=$6; s=$2+0; e=$3+0
        if (code=="0700" && e>d) d=e
        if (code=="2700" && (w==0 || s<w)) w=s
      }
      END { if (w==0) w=disk_end; if (d==0) { print -1 } else { printf "%d", (w-d)*512/1048576 } }')"
    if [ "${REG:-0}" -lt 0 ]; then
      dbk_add_check "分区表里找不到 Windows 数据分区(0700);预留区检查跳过"
    elif [ "${REG:-0}" -lt "$RESERVE_MIB" ]; then
      ISSUES+=("预留区被压缩:期望 ≥${RESERVE_MIB}MiB(115GiB),实际 ${REG}MiB")
    else
      dbk_add_check "轨道 D 预留区:${REG}MiB(≥${RESERVE_MIB}MiB)"
    fi
  else
    dbk_add_check "sgdisk -p 读不到分区表;预留区检查跳过"
  fi
elif [ "$TRACK" = D ]; then
  dbk_add_check "未安装 sgdisk(或 parted);预留区检查跳过"
fi

if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "分区计划核对未通过(${#ISSUES[@]} 项);逐条见 checks,修好前不要继续安装"
fi

dbk_note "下一步该建什么(live 里手工建;Calamares 里只指定挂载点,不让它动 Windows ESP):"
step=1
if [ "$UBU_ESP" -lt 0 ]; then dbk_note "  $step. ESP-Ubuntu: ${UBU_ESP_MIB}MiB FAT32 -> 挂载点 /boot/efi"; step=$((step + 1)); fi
if [ "$BOOT_P" -lt 0 ]; then dbk_note "  $step. /boot: ${BOOT_MIB}MiB ext4 -> 挂载点 /boot"; step=$((step + 1)); fi
if [ "$ROOT_P" -lt 0 ]; then dbk_note "  $step. root: 约 113GiB ext4 -> 挂载点 /"; step=$((step + 1)); fi
if [ "$step" -eq 1 ]; then dbk_note "  三块已就绪:Calamares 里只指定挂载点(/boot/efi、/boot、/),不新建、不格式化 Windows 侧"; fi
dbk_note "  坑(设计 04 第 5 节):Calamares 没有独立的'引导器位置'选项,它把引导装到 /boot/efi 指向的那块 ESP ——"
dbk_note "    务必确认 /boot/efi 指向 ESP-Ubuntu(${UBU_ESP_MIB}MiB),绝不能指向 Windows 的 ESP(${WIN_ESP_MIB}MiB);装完用 efibootmgr -v 核对。"
if [ "$TRACK" = D ]; then dbk_note "  三块都建在 115GiB 预留区内;Windows 各分区一律不挂载、不格式化、不改尺寸。"; fi
dbk_add_check "Ubuntu 三块:ESP-Ubuntu=$([ "$UBU_ESP" -ge 0 ] && printf 就绪 || printf 待建) /boot=$([ "$BOOT_P" -ge 0 ] && printf 就绪 || printf 待建) root=$([ "$ROOT_P" -ge 0 ] && printf 就绪 || printf 待建)"
dbk_exit PASS "分区计划核对通过:Windows ESP 未被挂载/未被改动;下一步按上面的清单建 Ubuntu 三块(轨道 $TRACK)"
