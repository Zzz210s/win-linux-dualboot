#!/usr/bin/env bash
# 对应卡:07-1
# 卡 07-1「判层」:只读取证,把现场故障归到四层之一,并给出建议卡号。
# 只读保证:本脚本没有任何写动作(不 mount、不 mkfs、不调 efibootmgr 写操作、不改任何文件),--apply 与 --check 输出完全相同。
#   Windows ESP 不由本脚本挂载(挂载会改系统状态):未给 DBK_WIN_ESP_MNT 时只打印只读挂载建议并记为需人工。
# 判层优先级(多层同时命中取最高,其余命中层一并列出):硬件层 > 系统层 > ESP 层 > 引导层。
# 判据(全部可观测):硬件层 = 两块 ESP 上的引导文件都缺失(两系统一起进不去),或 smartctl 报某块盘不健康(提示按 07-8 处置,不要格式化);
#   系统层 = baseline/02-partitions.txt 分区行数与现场 lsblk 的 TYPE="part" 数不一致,或已进 ostree 部署但 / 不是 btrfs(建议 07-4 / 07-5);
#   ESP 层 = baseline/02-esp-backup/manifest.sha256 存在,且 Windows ESP 上 EFI/Microsoft/ 缺失或清单逐文件哈希不一致(建议 07-6);
#   引导层 = Fedora NVRAM 条目缺失 / 它指向的 \EFI\...\*.efi 在 ESP 上不存在 / EFI/fedora 内容缺失 / Windows 条目缺失而引导文件在位(建议 07-2,Windows 侧 07-3)。
# 退出码:0 = 判层结论明确(文本与 --json 的 message 都含「判层结论: <层>;建议卡号: …」);1 = 无法判定(探针可读却没有任何命中,或证据矛盾),逐条列出失败项;
#   2 = 关键信息读不到(非 root 读不到 efibootmgr、ESP 未挂载、baseline 缺失等),给 sudo / 挂载指引;9 = 非 Linux(DBK_UNAME 不是 Linux)。
# 注入钩子(真机留空;夹具用。取值 = 命令名或可带参数的命令行(由夹具在 PATH 注入假命令),或一个存在的文件路径(回放该文件)):
#   DBK_LSBLK / DBK_BLKID / DBK_FINDMNT / DBK_EFIBOOTMGR / DBK_RPM_OSTREE / DBK_SMARTCTL / DBK_SHA256SUM / DBK_UNAME
#   DBK_ESP_MNT(Fedora ESP 挂载点,缺省 /boot/efi)/ DBK_WIN_ESP_MNT(Windows ESP 挂载点,缺省空 = 未挂载)
#   DBK_BASELINE_DIR(基线目录,缺省 <仓库根>/baseline)/ DBK_SYS_CLASS_FIRMWARE(缺省 /sys/firmware/efi)
# 待核实(以官方文档为准):efibootmgr -v / rpm-ostree status / smartctl -H / findmnt 的文本解析均未在真机验证。
# 夹具级验证,真机未跑。用法: triage.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "triage"
dbk_enable_errtrap

REPO="$(cd "$HERE/../.." && pwd)"
BASE_DIR="${DBK_BASELINE_DIR:-$REPO/baseline}"; ESP_MNT="${DBK_ESP_MNT:-/boot/efi}"
WIN_MNT="${DBK_WIN_ESP_MNT:-}"; FW_DIR="${DBK_SYS_CLASS_FIRMWARE:-/sys/firmware/efi}"
LSB_HOOK="${DBK_LSBLK:-lsblk}"; BLKID_HOOK="${DBK_BLKID:-blkid}"; FM_HOOK="${DBK_FINDMNT:-findmnt}"
EFI_HOOK="${DBK_EFIBOOTMGR:-efibootmgr}"; OST_HOOK="${DBK_RPM_OSTREE:-rpm-ostree}"; SMART_HOOK="${DBK_SMARTCTL:-smartctl}"
SHA_HOOK="${DBK_SHA256SUM:-sha256sum}"
MANUAL=()

# 钩子:文件路径 → 回放该文件;否则按命令行执行(stderr 并入输出,不吞错);始终返回 0。
hook_avail() { local spec="${1:-}" p=(); [ -e "$spec" ] && return 0; read -r -a p <<<"$spec"; command -v "${p[0]}" >/dev/null 2>&1; }
hook_out() {
  local spec="${1:-}"; shift || true
  if [ -e "$spec" ]; then cat -- "$spec" 2>&1 || true; return 0; fi
  local p=(); read -r -a p <<<"$spec"; "${p[@]}" "$@" 2>&1 || true; return 0
}
count_of() { printf '%s\n' "${1:-}" | grep -cE "${2:-}" || true; }
note_manual() { dbk_add_check "需人工: $1"; MANUAL+=("$1"); }

# 1) 先判环境:只在 Linux 上可用(Windows 侧对应 07-3/07-9 的 PowerShell 脚本)
UNAME_OUT="$(hook_out "${DBK_UNAME:-uname -s}")"
case "$UNAME_OUT" in
  Linux*) ;;
  *) dbk_add_check "环境: 当前不是 Linux(uname 输出 '$UNAME_OUT')"
     dbk_exit 跳过 "跳过:本脚本只在 Linux 救援环境可用(uname 输出 '$UNAME_OUT');Windows 侧用 07-3/07-9 的 PowerShell 脚本" ;;
esac

# 2) 取证:分区 / 设备 / 挂载 / 固件条目 / 两块 ESP 内容 / 固件 / ostree 部署 / SMART
LSB=""; if hook_avail "$LSB_HOOK"; then LSB="$(hook_out "$LSB_HOOK" -P -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT)"; fi
PART_N="$(count_of "$LSB" 'TYPE="part"')"; DISK_N="$(count_of "$LSB" 'TYPE="disk"')"; LSB_OK=0; [ -n "$LSB" ] && LSB_OK=1
BLKID=""; if hook_avail "$BLKID_HOOK"; then BLKID="$(hook_out "$BLKID_HOOK")"; fi
FM=""; if hook_avail "$FM_HOOK"; then FM="$(hook_out "$FM_HOOK" -n -o FSTYPE,SOURCE,TARGET /)"; fi
ROOT_FS="$(printf '%s\n' "$FM" | awk 'NR==1{print $1}' || true)"
EFI_OUT=""; if hook_avail "$EFI_HOOK"; then EFI_OUT="$(hook_out "$EFI_HOOK" -v)"; fi
WBM_LINE="$(printf '%s\n' "$EFI_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i microsoft | head -n1 || true)"
FED_LINE="$(printf '%s\n' "$EFI_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i fedora | head -n1 || true)"
FED_LOADER="$(printf '%s' "$FED_LINE" | grep -oE '\\EFI\\[^)]*\.efi' | head -n1 || true)"
FED_LOADER_P="$(printf '%s' "$FED_LOADER" | tr '\\' '/')"
ESP_READ=0; [ -d "$ESP_MNT" ] && ESP_READ=1
WIN_READ=0; [ -n "$WIN_MNT" ] && [ -d "$WIN_MNT" ] && WIN_READ=1
FED_OK=0; WIN_OK=0
if [ "$ESP_READ" -eq 1 ] && { [ -f "$ESP_MNT/EFI/fedora/shimx64.efi" ] || [ -f "$ESP_MNT/EFI/fedora/grubx64.efi" ]; }; then FED_OK=1; fi
if [ "$WIN_READ" -eq 1 ] && [ -f "$WIN_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]; then WIN_OK=1; fi
OST=""; if hook_avail "$OST_HOOK"; then OST="$(hook_out "$OST_HOOK" status)"; fi
OST_DEP="$(count_of "$OST" 'ostree-image|Deployments|●')"
SMART_BAD=0; SMART_MSG=""; SMART_SEEN=0
DISKS="$(printf '%s\n' "$LSB" | grep 'TYPE="disk"' | sed -n 's/.*NAME="\([^"]*\)".*/\1/p' | tr '\n' ' ' || true)"
if [ -n "$DISKS" ] && hook_avail "$SMART_HOOK"; then
  for d in $DISKS; do
    so="$(hook_out "$SMART_HOOK" -H "/dev/$d")"
    [ -n "$so" ] && SMART_SEEN=1
    if printf '%s' "$so" | grep -qiE 'FAILED|not capable|Unknown USB|Permission denied'; then
      SMART_BAD=1; SMART_MSG="$SMART_MSG /dev/$d:$(printf '%s' "$so" | head -n1);"
    fi
  done
fi

# 3) 判据:命中哪些层(硬件层 > 系统层 > ESP 层 > 引导层)
L_HW=0; L_SYS=0; L_ESP=0; L_BOOT=0; HITS=()
if [ "$SMART_BAD" -eq 1 ]; then L_HW=1; HITS+=("硬件层"); fi
if [ "$ESP_READ" -eq 1 ] && [ "$WIN_READ" -eq 1 ] && [ "$FED_OK" -eq 0 ] && [ "$WIN_OK" -eq 0 ]; then
  L_HW=1; case " ${HITS[*]-} " in *" 硬件层 "*) ;; *) HITS+=("硬件层(两系统引导文件都不在 ESP 上)") ;; esac
fi
BASE_PART="$BASE_DIR/02-partitions.txt"
if [ -f "$BASE_PART" ]; then
  bp="$(count_of "$(cat -- "$BASE_PART" 2>&1 || true)" '^[[:space:]]*(Partition|分区)[[:space:]]+[0-9]+')"
  if [ "$LSB_OK" -eq 1 ] && [ "$bp" -gt 0 ] && [ "$bp" -ne "$PART_N" ]; then
    L_SYS=1; HITS+=("系统层(分区数 baseline=$bp 现场=$PART_N)")
  fi
else
  note_manual "缺 baseline/02-partitions.txt($BASE_PART):无法比对分区是否被改动(先在 L2 跑 03-8)"
fi
if [ "$OST_DEP" -gt 0 ]; then
  if [ -z "$ROOT_FS" ]; then note_manual "已进 ostree 部署但读不到 / 的文件系统类型(findmnt)"
  elif [ "$ROOT_FS" != btrfs ]; then L_SYS=1; HITS+=("系统层(/ 是 $ROOT_FS,原子版要求 btrfs)"); fi
fi
MAN="$BASE_DIR/02-esp-backup/manifest.sha256"; HASH_N=0; HASH_BAD=0
if [ -f "$MAN" ] && [ "$WIN_READ" -eq 1 ]; then
  if [ ! -d "$WIN_MNT/EFI/Microsoft" ]; then
    L_ESP=1; HITS+=("ESP层(Windows ESP 上 EFI/Microsoft/ 缺失)")
  else
    while IFS= read -r line; do
      h="$(printf '%s' "$line" | awk '{print $1}')"; p="$(printf '%s' "$line" | awk '{print $2}')"
      case "$p" in EFI/Microsoft/*) ;; *) continue ;; esac
      [ -n "$h" ] && [ -n "$p" ] || continue
      HASH_N=$((HASH_N + 1)); f="$WIN_MNT/$p"
      if [ ! -f "$f" ]; then HASH_BAD=$((HASH_BAD + 1)); continue; fi
      if hook_avail "$SHA_HOOK"; then
        a="$(hook_out "$SHA_HOOK" "$f" | awk '{print $1}')"
        if [ "$(printf '%s' "$a" | tr 'a-f' 'A-F')" != "$(printf '%s' "$h" | tr 'a-f' 'A-F')" ]; then HASH_BAD=$((HASH_BAD + 1)); fi
      fi
    done <"$MAN"
    if [ "$HASH_BAD" -gt 0 ]; then L_ESP=1; HITS+=("ESP层(EFI/Microsoft/ 清单 $HASH_N 项中有 $HASH_BAD 项不一致)"); fi
  fi
elif [ -f "$MAN" ]; then
  note_manual "缺 Windows ESP 挂载点:无法用 manifest.sha256 比对 EFI/Microsoft/(sudo mount -o ro <ESP 分区> /mnt 后带 DBK_WIN_ESP_MNT=/mnt 重跑)"
else
  note_manual "缺 baseline/02-esp-backup/manifest.sha256($MAN):无法比对 ESP 层(先在 L2 跑 03-8)"
fi
if [ "$ESP_READ" -eq 0 ]; then
  note_manual "Fedora ESP 未挂载($ESP_MNT 不存在):看不到 EFI/fedora 内容(sudo mount -o ro <ESP 分区> /boot/efi 后重跑)"
elif [ "$FED_OK" -eq 0 ]; then L_BOOT=1; HITS+=("引导层(ESP 上 EFI/fedora 内容缺失)"); fi
if [ "$ESP_READ" -eq 1 ] && [ -n "$FED_LINE" ] && [ -n "$FED_LOADER_P" ] && [ ! -f "$ESP_MNT$FED_LOADER_P" ]; then
  L_BOOT=1; HITS+=("引导层(Fedora 条目指向 $FED_LOADER 但该文件不在 ESP 上)")
fi
if [ "$ESP_READ" -eq 1 ] && [ -z "$FED_LINE" ] && [ "$FED_OK" -eq 1 ]; then L_BOOT=1; HITS+=("引导层(NVRAM 无 Fedora 条目,但 ESP 上引导文件在位)"); fi
if [ "$WIN_READ" -eq 1 ] && [ -z "$WBM_LINE" ] && [ "$WIN_OK" -eq 1 ]; then L_BOOT=1; HITS+=("引导层(NVRAM 无 Windows Boot Manager 条目,但 bootmgfw.efi 在位)"); fi
if [ -z "$EFI_OUT" ]; then note_manual "读不到 efibootmgr -v(efivarfs 通常只对 root 可读):sudo bash $0 重跑,或人工核对 sudo efibootmgr -v"; fi
if [ "$LSB_OK" -eq 0 ]; then note_manual "lsblk 无输出:无法核对分区布局(确认在 Linux 环境且 lsblk 可用)"; fi
if [ -d "$FW_DIR" ]; then dbk_add_check "固件:UEFI 模式($FW_DIR 在位);BootCurrent/BootOrder 见上面 efibootmgr 证据"
else note_manual "未发现 $FW_DIR:可能是 Legacy/BIOS 启动或非 EFI 环境,固件条目判据需人工复核"; fi
if [ "$SMART_SEEN" -eq 0 ]; then note_manual "smartctl 读不到盘体健康(${SMART_HOOK} 缺命令或无权限):硬件层证据不完整,不要据此排除硬件"; fi

# 4) 证据登记(逐条可查)
dbk_add_check "取证:磁盘 $DISK_N 块、分区 $PART_N 个(lsblk);blkid 行数 $(count_of "$BLKID" '^/dev/'); / 文件系统=${ROOT_FS:-未取到}"
dbk_add_check "取证:ostree 部署标记 $OST_DEP 处(rpm-ostree status);Windows 条目=${WBM_LINE:-未取到};Fedora 条目=${FED_LINE:-未取到}"
dbk_add_check "取证:Fedora ESP=$ESP_MNT(可读=$ESP_READ,EFI/fedora 在位=$FED_OK);Windows ESP=${WIN_MNT:-未挂载}(可读=$WIN_READ,bootmgfw.efi 在位=$WIN_OK)"
[ "$SMART_BAD" -eq 0 ] || dbk_add_check "SMART 异常:$SMART_MSG"
dbk_add_check "命中层:$([ "${#HITS[@]}" -gt 0 ] && printf '%s ' "${HITS[@]}" || printf '无')"

# 5) 结论与退出码
LAYER=""; CARDS=""
if [ "$L_HW" -eq 1 ]; then LAYER="硬件层"; CARDS="无脚本:按 07-8 应急纪律处置,先不要在盘上做任何写操作(不要格式化、不要分区、不要重装)"
elif [ "$L_SYS" -eq 1 ]; then LAYER="系统层"; CARDS="07-4(只重装 Windows)/ 07-5(只重装 Silverblue)"
elif [ "$L_ESP" -eq 1 ]; then LAYER="ESP层"; CARDS="07-6(从 baseline/02-esp-backup 还原 Windows ESP 引导文件)"
elif [ "$L_BOOT" -eq 1 ]; then LAYER="引导层"; CARDS="07-2(从 GRUB 提示符回 Windows / 修 GRUB 自身);Windows 侧条目缺失时走 07-3"
fi
if [ -n "$LAYER" ]; then
  dbk_exit PASS "判层结论: $LAYER;建议卡号: $CARDS;命中层:$([ "${#HITS[@]}" -gt 0 ] && printf '%s ' "${HITS[@]}" || printf '无')"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  dbk_exit 需人工 "无法判层:关键信息读不到(${#MANUAL[@]} 项),逐条见 checks 里的「需人工」;补齐后用 sudo bash $0 重跑"
fi
dbk_add_check "失败项: 探针全部可读但没有命中任何一层(引导条目、分区数、ESP 清单、SMART 都看不出问题)"
dbk_exit FAIL "无法判定故障层:证据互相矛盾或不足;若两个系统都进不去,按 07-8 应急纪律人工复核硬件(内存/盘),不要在盘上做写操作"
