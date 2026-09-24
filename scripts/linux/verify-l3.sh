#!/usr/bin/env bash
# 对应卡:04-3
# L3 后置校验(装完 Kubuntu 重启进系统后跑;设计依据:docs/design/04-kubuntu-variant-design.md 第 5 节
#   "装完的验证:GRUB 落 \EFI\ubuntu\、BootOrder 首位仍是 Windows Boot Manager")。
# 判据:① `dpkg -l` 里 grub-efi-amd64(或 grub-efi-amd64-signed)在位;② `shim-signed` 在位;
#   ③ GRUB 落 $ESP_DIR/EFI/ubuntu/(shimx64.efi 或 grubx64.efi);④ /boot 独立且为 ext4;
#   ⑤ 两块 ESP 内容互不干扰(Linux ESP 上没有 Microsoft 子树,Windows ESP 上没有 ubuntu 子树);
#   ⑥ 固件条目:ubuntu 条目指向 \EFI\ubuntu\,且 BootOrder 首位仍是 Windows Boot Manager。
#   任一不满足 → FAIL 并逐项指明(默认仍进 Windows、ubuntu 条目在 BootOrder 尾部)。
# 本卡无写动作:--apply 与 --check 输出相同(只读)。退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: verify-l3.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 夹具注入(真机不需要设置):DBK_DPKG_QUERY / DBK_BOOT_DIR(缺省 /boot)/ DBK_ESP_DIR(缺省 /boot/efi)/
#   DBK_WIN_ESP_MNT(Windows ESP 挂载点)/ DBK_EFIBOOTMGR / DBK_LSBLK。
# 待核实(以官方文档为准):efibootmgr -v 与 lsblk -P 的文本解析、Ubuntu 的固件条目描述串("ubuntu")均未在真机验证。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "verify-l3"
BOOT_DIR="${DBK_BOOT_DIR:-/boot}"; ESP_DIR="${DBK_ESP_DIR:-/boot/efi}"; WIN_MNT="${DBK_WIN_ESP_MNT:-}"
DQ_STR="${DBK_DPKG_QUERY:-dpkg-query}"; EFI_STR="${DBK_EFIBOOTMGR:-efibootmgr}"; LSB_STR="${DBK_LSBLK:-lsblk}"
DQ=(); EFI=(); LSB=(); read -r -a DQ <<<"$DQ_STR"; read -r -a EFI <<<"$EFI_STR"; read -r -a LSB <<<"$LSB_STR"
# 包装函数体内用 command:名字若与外部命令同名,函数查找优先于 PATH 会无限递归。
dq() { command "${DQ[@]}" "$@"; }
efi() { command "${EFI[@]}" "$@"; }
lsb() { command "${LSB[@]}" "$@"; }
TMP_MNT=""; ISSUES=(); MANUAL=()
to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/1048576}'; }
cleanup() { if [ -n "$TMP_MNT" ]; then umount "$TMP_MNT" 2>/dev/null || true; rmdir "$TMP_MNT" 2>/dev/null || true; fi; }
trap cleanup EXIT
# 只读探针:stdout+stderr 收进 PROBE_OUT(不吞输出)。
# 只读探针:stdout+stderr 收进 PROBE_OUT(不吞输出)。
# 注:原先还有一个 PROBE_RC 想在探针层区分 127(缺命令)与执行失败,但调用点都先做了 `command -v` 守卫,
#   它从未被读取 —— 2026-09-24 复查时删除(避免死代码;缺命令一律走各处的「需人工」分支)。
PROBE_OUT=""
probe() { local out; out="$("$@" 2>&1)" || true; PROBE_OUT="$out"; return 0; }
pkg_installed() {   # <包名>:dpkg-query 的 Status 含 install ok installed → 0
  [ -n "${1:-}" ] || return 1
  probe dq -W -f='${Status}' "$1"
  case "$PROBE_OUT" in *"install ok installed"*) return 0 ;; esac
  return 1
}

# 1) 引导包:grub-efi-amd64(或 -signed)与 shim-signed 在位
if ! command -v "${DQ[0]}" >/dev/null 2>&1; then
  MANUAL+=("未找到 ${DQ[0]}:无法核对 grub-efi-amd64 / shim-signed 是否安装")
elif pkg_installed grub-efi-amd64 || pkg_installed grub-efi-amd64-signed; then
  dbk_add_check "①引导包:grub-efi-amd64(或 -signed)在位"
else
  ISSUES+=("①缺少 grub-efi-amd64(或 grub-efi-amd64-signed):引导未按 Ubuntu 官方包安装")
fi
if command -v "${DQ[0]}" >/dev/null 2>&1; then
  if pkg_installed shim-signed; then dbk_add_check "②shim-signed 在位(Secure Boot 链完整)"
  else ISSUES+=("②缺少 shim-signed:Secure Boot 下无法验证引导链,按 07-6/07-5 处置"); fi
fi

# 2) GRUB 落 Linux ESP 的 \EFI\ubuntu\
if [ -d "$ESP_DIR/EFI/ubuntu" ] && { [ -f "$ESP_DIR/EFI/ubuntu/shimx64.efi" ] || [ -f "$ESP_DIR/EFI/ubuntu/grubx64.efi" ]; }; then
  dbk_add_check "③GRUB 落位:$ESP_DIR/EFI/ubuntu/(shim/grub 在位)"
else
  ISSUES+=("③GRUB 未落位:$ESP_DIR/EFI/ubuntu/ 下没有 shimx64.efi / grubx64.efi")
fi

# 3) /boot 独立且为 ext4(靠 lsblk 的 MOUNTPOINT/FSTYPE;不是独立挂载点即 FAIL)
LSB_OUT=""
if command -v "${LSB[0]}" >/dev/null 2>&1; then probe lsb -P -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT; LSB_OUT="$PROBE_OUT"; fi
boot_line="$(printf '%s\n' "$LSB_OUT" | grep -F "MOUNTPOINT=\"$BOOT_DIR\"" | head -n1 || true)"
if [ -z "$boot_line" ]; then
  ISSUES+=("④/boot 未独立挂载(lsblk 里没有 MOUNTPOINT=/boot 的独立分区)")
else
  boot_fs="$(printf '%s' "$boot_line" | sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p')"
  if [ "$boot_fs" = ext4 ]; then dbk_add_check "④/boot 独立且为 ext4($boot_line)"
  else ISSUES+=("④/boot 不是 ext4(实际 '$boot_fs');设计 04 第 4 节要求独立 ext4 /boot"); fi
fi

# 4) 两块 ESP 内容互不干扰
if [ -d "$ESP_DIR/EFI/Microsoft" ]; then
  ISSUES+=("⑤Linux ESP($ESP_DIR)上出现了 EFI/Microsoft/:两块 ESP 内容混了,Windows 引导文件被写进了 Linux 侧")
else
  dbk_add_check "⑤Linux ESP($ESP_DIR)上没有 EFI/Microsoft/(未越界写 Windows 引导)"
fi
if [ -z "$WIN_MNT" ] && [ -n "$LSB_OUT" ]; then   # 按"目标盘上 ≈2048MiB 的 vfat 分区"只读挂载核对
  WIN_DEV="$(printf '%s\n' "$LSB_OUT" | grep 'FSTYPE="vfat"' | while IFS= read -r line; do
    m="$(printf '%s' "$line" | sed -n 's/.*SIZE="\([^"]*\)".*/\1/p')"; mib="$(to_mib "$m")"
    if [ "$mib" -ge 1900 ] && [ "$mib" -le 2200 ]; then printf '/dev/%s' "$(printf '%s' "$line" | sed -n 's/^NAME="\([^"]*\)".*/\1/p')"; break; fi
  done)" || true
  if [ -n "$WIN_DEV" ]; then
    TMP_MNT="$(mktemp -d)"
    if mount -o ro "$WIN_DEV" "$TMP_MNT" 2>/dev/null; then WIN_MNT="$TMP_MNT"; else rmdir "$TMP_MNT" 2>/dev/null || true; TMP_MNT=""; fi
  fi
fi
if [ -n "$WIN_MNT" ] && [ -d "$WIN_MNT/EFI/Microsoft" ]; then
  dbk_add_check "⑤Windows ESP($WIN_MNT)上 EFI/Microsoft/ 在位"
  if [ -d "$WIN_MNT/EFI/ubuntu" ]; then ISSUES+=("⑤Windows ESP 上出现了 EFI/ubuntu/:GRUB 被装到了 Windows 的 ESP 上(违反 I3)"); fi
elif [ -n "$WIN_MNT" ]; then
  ISSUES+=("⑤Windows ESP 内容缺失:$WIN_MNT/EFI/Microsoft/ 不存在")
else
  MANUAL+=("⑤未能只读挂载 Windows ESP:无法核对 EFI/Microsoft/(改以固件条目路径 \\EFI\\Microsoft\\ 核对)")
fi

# 5) 固件条目:ubuntu 条目指向 \EFI\ubuntu\;BootOrder 首位仍是 Windows Boot Manager
if ! command -v "${EFI[0]}" >/dev/null 2>&1; then
  MANUAL+=("未找到 ${EFI[0]}:无法核对固件条目与 BootOrder(需要 root 才能读 efivarfs)")
else
  probe efi -v
  if [ -z "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    MANUAL+=("读不到 efibootmgr -v 输出(需要 root;efivarfs 通常只对 root 可读)")
  else
    BO="$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
    efi_desc() { printf '%s\n' "$PROBE_OUT" | awk -v n="$1" -F'\t' '$1 ~ "^Boot" n { d=$1; sub(/^Boot[0-9A-Fa-f]+[*[:space:]]*/, "", d); print d; exit }'; }
    UBU_NUM="$(printf '%s\n' "$PROBE_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i 'ubuntu' | head -n1 | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' || true)"
    if [ -z "$UBU_NUM" ]; then
      ISSUES+=("⑥固件条目里找不到 ubuntu 条目(\\EFI\\ubuntu\\shimx64.efi);按 07-2 用 grub-install 重建")
    else
      dbk_add_check "⑥ubuntu 引导条目:Boot$UBU_NUM $(efi_desc "$UBU_NUM")"
      UBU_PATH="$(printf '%s\n' "$PROBE_OUT" | grep -E "^Boot$UBU_NUM" | grep -oiE '\\EFI\\[A-Za-z0-9_./\\-]*\.efi' | head -n1 || true)"
      case "$UBU_PATH" in
        *"\\EFI\\ubuntu\\"*) dbk_add_check "⑥ubuntu 条目指向 $UBU_PATH" ;;
        "") MANUAL+=("⑥ubuntu 条目没给出可识别的 .efi 路径;请人工核对 efibootmgr -v") ;;
        *) ISSUES+=("⑥ubuntu 条目指向 $UBU_PATH,不在 \\EFI\\ubuntu\\ 下") ;;
      esac
    fi
    if [ -z "$BO" ]; then
      ISSUES+=("⑥efibootmgr -v 里没有 BootOrder 行")
    else
      FIRST="${BO%%,*}"; LAST="${BO##*,}"; FIRST_DESC="$(efi_desc "$FIRST")"
      case "$FIRST_DESC" in
        *Windows*Boot*Manager*|*Windows*启动管理器*) dbk_add_check "⑥BootOrder 首位仍是 Windows Boot Manager(Boot$FIRST $FIRST_DESC)" ;;
        *) ISSUES+=("⑥BootOrder 首位不是 Windows Boot Manager(首位 Boot$FIRST '$FIRST_DESC');按 07-9 归位") ;;
      esac
      if [ -n "$UBU_NUM" ] && [ "$LAST" = "$UBU_NUM" ]; then dbk_add_check "⑥ubuntu 条目在 BootOrder 尾部(Boot$LAST)"
      elif [ -n "$UBU_NUM" ]; then MANUAL+=("⑥ubuntu 条目不在 BootOrder 尾部(尾部是 Boot$LAST);不影响默认启动,请人工确认"); fi
    fi
  fi
fi

if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "L3 校验未通过(${#ISSUES[@]} 项);逐条见 checks;引导问题按 07-* 处置,不要重装"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "L3 校验有 ${#MANUAL[@]} 项脚本判不了(多为需要 root 或未挂载 Windows ESP);逐条见 checks"
fi
dbk_exit PASS "L3 校验通过:grub-efi-amd64/shim-signed 在位、GRUB 落 \\EFI\\ubuntu\\、/boot 独立 ext4、两块 ESP 互不干扰、BootOrder 首位仍是 Windows Boot Manager"
