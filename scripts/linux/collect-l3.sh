#!/usr/bin/env bash
# 对应卡:04-4
# 落 L3 产物:--apply 写 baseline/03-efi-layout.txt,六节固定——\EFI\ 两棵树(Windows ESP + Ubuntu ESP)、
# efibootmgr -v、BootOrder、lsblk、findmnt、引导包与内核版本摘要(dpkg-query + uname -r);--check(缺省)只打印,零写。
# 产物不入库(baseline/* 被 .gitignore 排除,仅 baseline/README.md 例外);多设备落 baseline/<设备别名>/。
# 夹具级验证,真机未跑。用法: collect-l3.sh [--check|--apply] [--out <文件>] [--json] [--log <路径>] [--step NN-K]
# 夹具注入(真机不需要设置):BOOT_DIR、ESP_DIR、WIN_ESP_MNT、OUT。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

OUT="${DBK_OUT:-$ROOT/baseline/03-efi-layout.txt}"; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --out 缺取值(产物文件路径)"; exit "$DBK_USAGE"; }; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "collect-l3"
BOOT_DIR="${DBK_BOOT_DIR:-/boot}"; ESP_DIR="${DBK_ESP_DIR:-/boot/efi}"; WIN_MNT="${DBK_WIN_ESP_MNT:-}"; TMP_MNT=""
to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/1048576}'; }
cleanup() { if [ -n "$TMP_MNT" ]; then umount "$TMP_MNT" 2>/dev/null || true; rmdir "$TMP_MNT" 2>/dev/null || true; fi; }
trap cleanup EXIT

# Windows ESP 树:优先用注入的挂载点;否则按"目标盘上 ≈2048MiB 的 vfat 分区"只读挂载
if [ -z "$WIN_MNT" ] && command -v lsblk >/dev/null 2>&1; then
  WIN_DEV=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    m="$(to_mib "$(printf '%s' "$line" | sed -n 's/.*SIZE="\([^"]*\)".*/\1/p')")"
    if [ "$m" -ge 1900 ] && [ "$m" -le 2200 ]; then WIN_DEV="/dev/$(printf '%s' "$line" | sed -n 's/^NAME="\([^"]*\)".*/\1/p')"; break; fi
  done <<<"$(lsblk -P -b -o NAME,SIZE,TYPE,FSTYPE 2>/dev/null | grep 'FSTYPE="vfat"' || true)"
  if [ -n "$WIN_DEV" ]; then
    TMP_MNT="$(mktemp -d)"
    if mount -o ro "$WIN_DEV" "$TMP_MNT" 2>/dev/null; then WIN_MNT="$TMP_MNT"; else rmdir "$TMP_MNT" 2>/dev/null || true; TMP_MNT=""; fi
  fi
fi

sec() { printf '%s\n' "$1"; printf '\n'; }
BODY="$(sec "# baseline/03-efi-layout.txt (L3 产物)"
  sec "## \\EFI\\ 目录树(Ubuntu ESP:$ESP_DIR)"
  if [ -d "$ESP_DIR/EFI" ]; then find "$ESP_DIR/EFI" -maxdepth 3 2>/dev/null | sort; else printf '%s\n' "(读不到 $ESP_DIR/EFI)"; fi
  printf '\n'
  sec "## \\EFI\\ 目录树(Windows ESP:${WIN_MNT:-读不到})"
  if [ -n "$WIN_MNT" ] && [ -d "$WIN_MNT/EFI" ]; then find "$WIN_MNT/EFI" -maxdepth 3 2>/dev/null | sort; else printf '%s\n' "(读不到 Windows ESP 的 \\EFI\\ 树:请在 Windows 侧或只读挂载后重跑)"; fi
  printf '\n'
  sec "## efibootmgr -v"
  if command -v efibootmgr >/dev/null 2>&1; then efibootmgr -v 2>&1 || true; else printf '%s\n' "(未安装 efibootmgr)"; fi
  printf '\n'
  sec "## BootOrder"
  if command -v efibootmgr >/dev/null 2>&1; then efibootmgr 2>&1 | grep '^BootOrder' || printf '%s\n' "(读不到 BootOrder:需要 root)"; else printf '%s\n' "(未安装 efibootmgr)"; fi
  printf '\n'
  sec "## lsblk"
  if command -v lsblk >/dev/null 2>&1; then lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME,MOUNTPOINT 2>&1 || true; else printf '%s\n' "(未安装 lsblk)"; fi
  printf '\n'
  sec "## findmnt"
  if command -v findmnt >/dev/null 2>&1; then findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true; else printf '%s\n' "(未安装 findmnt)"; fi
  printf '\n'
  sec "## 引导包与内核版本(dpkg-query + uname -r)"
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package} ${Version}\n' grub-efi-amd64 grub-efi-amd64-signed shim-signed 2>&1 | head -n 10 || true
  else printf '%s\n' "(未安装 dpkg-query)"; fi
  uname -r 2>&1 || true
)"

if [ -n "$WIN_MNT" ]; then dbk_add_check "Windows ESP 树:已采集($WIN_MNT/EFI)"; else dbk_add_check "Windows ESP 树:未采集(读不到;产物里会留占位说明)"; fi
if [ "$DBK_MODE" = apply ]; then
  mkdir -p "$(dirname "$OUT")" || dbk_exit FAIL "产物目录创建失败: $(dirname "$OUT")"
  if printf '%s\n' "$BODY" >"$OUT"; then
    dbk_add_action "写入 $OUT($(printf '%s\n' "$BODY" | wc -l | tr -d ' ') 行)"
    dbk_mark_changed
    dbk_add_check "产物已落盘:$OUT"
  else
    dbk_exit FAIL "产物写入失败:$OUT(检查目录权限与磁盘空间)"
  fi
  dbk_exit PASS "L3 产物已落盘:$OUT;回 Windows 侧粘贴进仓库 baseline/(不入库)"
fi
if [ "${DBK_JSON:-0}" -eq 1 ]; then dbk_note "$BODY"; else printf '%s\n' "$BODY"; fi
dbk_add_check "只打印(--check 零写);加 --apply 落盘到 $OUT"
dbk_exit PASS "L3 产物预览完成(--check 未写任何文件);加 --apply 落盘到 $OUT"
