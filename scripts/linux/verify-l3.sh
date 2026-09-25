#!/usr/bin/env bash
# 对应卡:04-3
# L3 后置校验(装完原子版重启进系统后跑;设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D1/D2 ——
#   引导落 \EFI\fedora\、BootOrder 首位仍是 Windows Boot Manager)。
# 判据:① 部署列表可读且至少一个 ostree 部署(经 dbk-rollback.sh 的 deployments_count);② /boot 独立且为 ext4;
#   ③ $BOOT_DIR/ostree 存在(ostree 的引导目录);④ 引导文件落 $ESP_DIR/EFI/fedora/(shimx64.efi 或 grubx64.efi);
#   ⑤ 两块 ESP 内容互不干扰(Linux ESP 上没有 Microsoft 子树,Windows ESP 上没有 fedora 子树);
#   ⑥ 固件条目:fedora 条目指向 \EFI\fedora\,且 BootOrder 首位仍是 Windows Boot Manager。
#   任一不满足 → FAIL 并逐项指明(默认仍进 Windows、fedora 条目在 BootOrder 尾部)。
# 本卡无写动作:--apply 与 --check 输出相同(只读)。退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: verify-l3.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 夹具注入(真机不需要设置):DBK_BOOT_DIR(缺省 /boot)/ DBK_ESP_DIR(缺省 /boot/efi)/
#   DBK_WIN_ESP_MNT(Windows ESP 挂载点)/ DBK_EFIBOOTMGR / DBK_LSBLK / DBK_RPM_OSTREE(经 dbk-rollback.sh)。
# 本脚本不写发行版命令字面量(规则 S-1):部署读取一律走 dbk-rollback.sh 的接口。
# 待核实(以官方文档为准):efibootmgr -v 与 lsblk -P 的文本解析、原子版的固件条目描述串("Fedora")、
#   $BOOT_DIR/ostree 的目录名 —— 均未在真机验证。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-rollback.sh disable=SC1091
. "$HERE/dbk-rollback.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "verify-l3"
BOOT_DIR="${DBK_BOOT_DIR:-/boot}"; ESP_DIR="${DBK_ESP_DIR:-/boot/efi}"; WIN_MNT="${DBK_WIN_ESP_MNT:-}"
EFI_STR="${DBK_EFIBOOTMGR:-efibootmgr}"; LSB_STR="${DBK_LSBLK:-lsblk}"
EFI=(); LSB=(); read -r -a EFI <<<"$EFI_STR"; read -r -a LSB <<<"$LSB_STR"
# 包装函数体内用 command:名字若与外部命令同名,函数查找优先于 PATH 会无限递归。
efi() { command "${EFI[@]}" "$@"; }
lsb() { command "${LSB[@]}" "$@"; }
TMP_MNT=""; ISSUES=(); MANUAL=()
to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/1048576}'; }
cleanup() { if [ -n "$TMP_MNT" ]; then umount "$TMP_MNT" 2>/dev/null || true; rmdir "$TMP_MNT" 2>/dev/null || true; fi; }
trap cleanup EXIT
# 只读探针:stdout+stderr 收进 PROBE_OUT(不吞输出)。缺命令由各调用点的 `command -v` 守卫处理。
PROBE_OUT=""
probe() { local out; out="$("$@" 2>&1)" || true; PROBE_OUT="$out"; return 0; }

# 1) ostree 部署在位(经接口 dbk-rollback.sh 的 deployments_list;取不到 → 需人工,绝不 fail-open)
#   注意:这里用 deployments_list 而不是 deployments_count —— 后者在"列表已打印但随后护栏失败"时会
#   把退出码吞成 0,方向不保守(详见报告里的接口缺陷登记)。
DEP_LIST=""; DEP_RC=0; DEP_N=0
if DEP_LIST="$(deployments_list)"; then DEP_RC=0; else DEP_RC=$?; fi
if [ "$DEP_RC" -eq 0 ]; then
  DEP_N="$(printf '%s\n' "$DEP_LIST" | grep -c . || true)"
  if [ "${DEP_N:-0}" -ge 1 ]; then
    dbk_add_check "①ostree 部署在位:部署数 $DEP_N(经 dbk-rollback.sh 读取)"
  else
    MANUAL+=("①部署列表可读但一个部署都没有:无法确认本机是可回滚的 ostree 部署")
  fi
else
  MANUAL+=("①读不到部署列表(原因见上面 dbk-rollback 的报错):无法确认本机是可回滚的 ostree 部署")
fi

# 2) /boot 独立且为 ext4(靠 lsblk 的 MOUNTPOINT/FSTYPE;不是独立挂载点即 FAIL)
LSB_OUT=""
if command -v "${LSB[0]}" >/dev/null 2>&1; then probe lsb -P -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT; LSB_OUT="$PROBE_OUT"; fi
boot_line="$(printf '%s\n' "$LSB_OUT" | grep -F "MOUNTPOINT=\"$BOOT_DIR\"" | head -n1 || true)"
if [ -z "$boot_line" ]; then
  ISSUES+=("②/boot 未独立挂载(lsblk 里没有 MOUNTPOINT=$BOOT_DIR 的独立分区)")
else
  boot_fs="$(printf '%s' "$boot_line" | sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p')"
  if [ "$boot_fs" = ext4 ]; then dbk_add_check "②/boot 独立且为 ext4($boot_line)"
  else ISSUES+=("②/boot 不是 ext4(实际 '$boot_fs');要求独立 ext4 /boot"); fi
fi

# 3) ostree 的引导目录 $BOOT_DIR/ostree
if [ -d "$BOOT_DIR/ostree" ]; then dbk_add_check "③ostree 引导目录在位:$BOOT_DIR/ostree"
elif [ -d "$BOOT_DIR" ]; then ISSUES+=("③缺 $BOOT_DIR/ostree:引导目录不在(部署可能不是 ostree 形态)")
else MANUAL+=("③$BOOT_DIR 不可读:无法核对 $BOOT_DIR/ostree"); fi

# 4) 引导文件落 Linux ESP 的 \EFI\fedora\
if [ -d "$ESP_DIR/EFI/fedora" ] && { [ -f "$ESP_DIR/EFI/fedora/shimx64.efi" ] || [ -f "$ESP_DIR/EFI/fedora/grubx64.efi" ]; }; then
  dbk_add_check "④引导文件落位:$ESP_DIR/EFI/fedora/(shim/grub 在位)"
else
  ISSUES+=("④引导未落位:$ESP_DIR/EFI/fedora/ 下没有 shimx64.efi / grubx64.efi")
fi

# 5) 两块 ESP 内容互不干扰
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
  if [ -d "$WIN_MNT/EFI/fedora" ]; then ISSUES+=("⑤Windows ESP 上出现了 EFI/fedora/:引导被装到了 Windows 的 ESP 上(违反 I3)"); fi
elif [ -n "$WIN_MNT" ]; then
  ISSUES+=("⑤Windows ESP 内容缺失:$WIN_MNT/EFI/Microsoft/ 不存在")
else
  MANUAL+=("⑤未能只读挂载 Windows ESP:无法核对 EFI/Microsoft/(改以固件条目路径 \\EFI\\Microsoft\\ 核对)")
fi

# 6) 固件条目:fedora 条目指向 \EFI\fedora\;BootOrder 首位仍是 Windows Boot Manager
if ! command -v "${EFI[0]}" >/dev/null 2>&1; then
  MANUAL+=("未找到 ${EFI[0]}:无法核对固件条目与 BootOrder(需要 root 才能读 efivarfs)")
else
  probe efi -v
  if [ -z "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    MANUAL+=("读不到 efibootmgr -v 输出(需要 root;efivarfs 通常只对 root 可读)")
  else
    BO="$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
    efi_desc() { printf '%s\n' "$PROBE_OUT" | awk -v n="$1" -F'\t' '$1 ~ "^Boot" n { d=$1; sub(/^Boot[0-9A-Fa-f]+[*[:space:]]*/, "", d); print d; exit }'; }
    FED_NUM="$(printf '%s\n' "$PROBE_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i 'fedora' | head -n1 | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' || true)"
    if [ -z "$FED_NUM" ]; then
      ISSUES+=("⑥固件条目里找不到 fedora 条目(\\EFI\\fedora\\shimx64.efi);按 07-2 重建引导")
    else
      dbk_add_check "⑥fedora 引导条目:Boot$FED_NUM $(efi_desc "$FED_NUM")"
      FED_PATH="$(printf '%s\n' "$PROBE_OUT" | grep -E "^Boot$FED_NUM" | grep -oiE '\\EFI\\[A-Za-z0-9_./\\-]*\.efi' | head -n1 || true)"
      case "$FED_PATH" in
        *"\\EFI\\fedora\\"*) dbk_add_check "⑥fedora 条目指向 $FED_PATH" ;;
        "") MANUAL+=("⑥fedora 条目没给出可识别的 .efi 路径;请人工核对 efibootmgr -v") ;;
        *) ISSUES+=("⑥fedora 条目指向 $FED_PATH,不在 \\EFI\\fedora\\ 下") ;;
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
      if [ -n "$FED_NUM" ] && [ "$LAST" = "$FED_NUM" ]; then dbk_add_check "⑥fedora 条目在 BootOrder 尾部(Boot$LAST)"
      elif [ -n "$FED_NUM" ]; then MANUAL+=("⑥fedora 条目不在 BootOrder 尾部(尾部是 Boot$LAST);不影响默认启动,请人工确认"); fi
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
dbk_exit PASS "L3 校验通过:ostree 部署在位、/boot 独立 ext4、$BOOT_DIR/ostree 在位、引导落 \\EFI\\fedora\\、两块 ESP 互不干扰、BootOrder 首位仍是 Windows Boot Manager"
