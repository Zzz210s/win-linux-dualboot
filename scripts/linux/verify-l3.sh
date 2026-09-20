#!/usr/bin/env bash
# 对应卡:04-3
# L3 后置校验(装完重启进 Silverblue 后跑):ostree 部署存在、/boot 独立且为 ext4、两块 ESP 各自内容
# (\EFI\Microsoft\ 与 \EFI\fedora\)、GRUB 部署条目、BootOrder 首位仍是 Windows Boot Manager;
# 任一不满足 → FAIL 并逐项指明(默认仍进 Windows、Fedora 条目在 BootOrder 尾部)。
# 本卡无写动作:--apply 与 --check 输出相同(只读)。
# 夹具级验证,真机未跑。用法: verify-l3.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
# 夹具注入(真机不需要设置):BOOT_DIR(缺省 /boot)、ESP_DIR(缺省 /boot/efi)、WIN_ESP_MNT(Windows ESP 挂载点)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "verify-l3"
BOOT_DIR="${DBK_BOOT_DIR:-/boot}"; ESP_DIR="${DBK_ESP_DIR:-/boot/efi}"; WIN_MNT="${DBK_WIN_ESP_MNT:-}"
ISSUES=()
to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/1048576}'; }

# 1) ostree 部署存在(rpm-ostree status 的 Deployments 列表;退化到 ostree admin status)
OST=""
if command -v rpm-ostree >/dev/null 2>&1; then OST="$(rpm-ostree status 2>&1)" || OST=""; fi
if printf '%s' "$OST" | grep -qE '^(Deployments|部署)'; then
  dbk_add_check "ostree 部署:rpm-ostree status 列出了 Deployments"
else
  OST2=""
  if command -v ostree >/dev/null 2>&1; then OST2="$(ostree admin status 2>&1)" || OST2=""; fi
  if printf '%s' "$OST2" | grep -q 'ostree'; then
    dbk_add_check "ostree 部署:ostree admin status 有部署记录"
  else
    ISSUES+=("ostree 部署不存在(rpm-ostree status / ostree admin status 都读不到部署)")
  fi
fi

# 2) /boot 独立且为 ext4(靠 lsblk 的 MOUNTPOINT/FSTYPE;不是独立挂载点即 FAIL)
LSB=""
if command -v lsblk >/dev/null 2>&1; then LSB="$(lsblk -P -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>&1)" || LSB=""; fi
boot_line="$(printf '%s\n' "$LSB" | grep -F 'MOUNTPOINT="/boot"' | head -n1 || true)"
if [ -z "$boot_line" ]; then
  ISSUES+=("/boot 未独立挂载(lsblk 里没有 MOUNTPOINT=/boot 的独立分区)")
else
  boot_fs="$(printf '%s\n' "$boot_line" | sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p')"
  if [ "$boot_fs" = ext4 ]; then
    dbk_add_check "/boot 独立且为 ext4($boot_line)"
  else
    ISSUES+=("/boot 不是 ext4(实际 '$boot_fs');原子版要求独立 ext4 /boot")
  fi
fi

# 3) Fedora ESP 内容:ESP_DIR/EFI/fedora/ 下必须有 shimx64.efi 或 grubx64.efi
if [ -d "$ESP_DIR/EFI/fedora" ] && { [ -f "$ESP_DIR/EFI/fedora/shimx64.efi" ] || [ -f "$ESP_DIR/EFI/fedora/grubx64.efi" ]; }; then
  dbk_add_check "Fedora ESP:$ESP_DIR/EFI/fedora/(shim/grub 在位)"
else
  ISSUES+=("Fedora ESP 内容缺失:$ESP_DIR/EFI/fedora/ 下没有 shimx64.efi / grubx64.efi")
fi

# 4) Windows ESP 内容:靠固件条目与(可选)只读挂载点核对 \EFI\Microsoft\
if [ -n "$WIN_MNT" ] && [ -d "$WIN_MNT/EFI/Microsoft" ]; then
  dbk_add_check "Windows ESP 内容:$WIN_MNT/EFI/Microsoft/ 在位"
elif [ -n "$WIN_MNT" ]; then
  ISSUES+=("Windows ESP 内容缺失:$WIN_MNT/EFI/Microsoft/ 不存在")
fi

# 5) 固件条目:efibootmgr -v 里 Windows Boot Manager 指向 \EFI\Microsoft\,Fedora 条目指向 \EFI\fedora\
EFI=""
if command -v efibootmgr >/dev/null 2>&1; then EFI="$(efibootmgr -v 2>&1)" || EFI=""; fi
if [ -z "$EFI" ]; then
  ISSUES+=("读不到 efibootmgr -v(需要 root;efivarfs 只对 root 可读)")
else
  BO="$(printf '%s\n' "$EFI" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
  efi_entry() { printf '%s\n' "$EFI" | grep -E "^Boot$1" | head -n1 || true; }
  efi_desc() { printf '%s\n' "$EFI" | awk -v n="$1" -F'\t' '$1 ~ "^Boot" n { d=$1; sub(/^Boot[0-9A-Fa-f]+[*[:space:]]*/, "", d); print d; exit }'; }
  WBM_NUM="$(printf '%s\n' "$EFI" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i 'microsoft' | head -n1 | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' || true)"
  if [ -z "$WBM_NUM" ]; then
    ISSUES+=("固件条目里找不到指向 \\EFI\\Microsoft\\ 的 Windows Boot Manager 条目")
  else
    dbk_add_check "Windows 引导条目:Boot$WBM_NUM $(efi_desc "$WBM_NUM")"
  fi
  FED_NUM="$(printf '%s\n' "$EFI" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i 'fedora' | head -n1 | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' || true)"
  if [ -z "$FED_NUM" ]; then
    ISSUES+=("固件条目里找不到 Fedora 条目(\\EFI\\fedora\\shimx64.efi)")
  else
    dbk_add_check "Fedora 引导条目:Boot$FED_NUM $(efi_desc "$FED_NUM")"
  fi
  if [ -z "$BO" ]; then
    ISSUES+=("efibootmgr -v 里没有 BootOrder 行")
  else
    FIRST="${BO%%,*}"; LAST="${BO##*,}"
    FIRST_DESC="$(efi_desc "$FIRST")"
    case "$FIRST_DESC" in
      *Windows*Boot*Manager*|*Windows*启动管理器*) dbk_add_check "BootOrder 首位仍是 Windows Boot Manager(Boot$FIRST $FIRST_DESC)" ;;
      *) ISSUES+=("BootOrder 首位不是 Windows Boot Manager(首位 Boot$FIRST '$FIRST_DESC')") ;;
    esac
    if [ -n "$FED_NUM" ]; then
      if [ "$LAST" = "$FED_NUM" ]; then
        dbk_add_check "Fedora 条目在 BootOrder 尾部(Boot$LAST)"
      else
        ISSUES+=("Fedora 条目不在 BootOrder 尾部(尾部是 Boot$LAST,期望 Boot$FED_NUM)")
      fi
    fi
  fi
fi

# 6) GRUB 部署条目:/boot/loader/entries/ 下的 ostree-*.conf
if ls "$BOOT_DIR"/loader/entries/ostree-*.conf >/dev/null 2>&1; then
  dbk_add_check "GRUB 部署条目:$BOOT_DIR/loader/entries/ostree-*.conf 在位"
else
  ISSUES+=("GRUB 部署条目缺失:$BOOT_DIR/loader/entries/ 下没有 ostree-*.conf")
fi

if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "L3 校验未通过(${#ISSUES[@]} 项);逐条见 checks;引导问题按 07-* 处置,不要重装"
fi
dbk_exit PASS "L3 校验通过:ostree 部署在位、/boot 独立 ext4、两块 ESP 内容齐全、GRUB 部署条目在位、BootOrder 首位仍是 Windows Boot Manager"
