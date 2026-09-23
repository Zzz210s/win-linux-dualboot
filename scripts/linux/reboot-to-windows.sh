#!/usr/bin/env bash
# 对应卡:05-11
# L4 卡 05-11:以**一次性**启动项从 Kubuntu 切回 Windows(`efibootmgr -n`,等价 EFI BootNext),并断言 BootOrder 未变(I2)。
# 判据(--check,零写):① 有 efibootmgr(非 UEFI → 跳过 9);② 能读到 BootOrder(efivarfs 只对 root 可读,读不到 → 需人工);
#   ③ 能唯一定位 Windows Boot Manager 条目。三条齐 → PASS 并给出将执行的 `efibootmgr -n <编号>`。
# --apply(需要 root;本卡不改永久启动顺序,故不声明破坏性、不强制 --yes):执行 efibootmgr -n <编号>,
#   复读 BootNext 与 BootOrder 断言一致后提示手工 systemctl reboot(本脚本**不自动重启**)。
# 纪律(设计第 2 节 / 不变量 I2):进 Windows 只用一次性 BootNext,**绝不执行 `efibootmgr -o`**——改永久顺序即违反 I2。
# 注入:DBK_WIN_MATCH(描述关键字,缺省 Windows Boot Manager)/ DBK_EFIBOOTMGR(命令,可带参数)。夹具级验证,真机未跑。
# 用法:reboot-to-windows.sh [--match <关键字>] [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

MATCH="${DBK_WIN_MATCH:-Windows Boot Manager}"
EFI_STR="${DBK_EFIBOOTMGR:-efibootmgr}"; EFI=(); read -r -a EFI <<<"$EFI_STR"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --match) dbk_cli_val "--match" "${2:-}"; MATCH="$2"; shift 2 ;;
    --match=*) MATCH="${1#*=}"; shift ;;
    --dry-run) shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "reboot-to-windows"
dbk_enable_errtrap
efi_run() { "${EFI[@]}" "$@"; }
efi_available() { command -v "${EFI[0]}" >/dev/null 2>&1; }
read_order() { efi_run 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n 1; }
read_next() { efi_run 2>/dev/null | sed -n 's/^BootNext:[[:space:]]*//p' | head -n 1; }
# 目标条目:先按描述关键字找,再兜底按 loader 路径含 microsoft 找(不用多 -e:单模式匹配兼容性最好)
find_win_line() {
  local out=""
  out="$(efi_run -v 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i "$MATCH" | head -n 1 || true)"
  if [ -z "$out" ]; then out="$(efi_run -v 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i microsoft | head -n 1 || true)"; fi
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 0
}
win_num_of() { printf '%s' "${1:-}" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p'; }

# 共同前置:efibootmgr 可用、BootOrder 可读、Windows 条目可定位。取不到时返回非零并把原因写进 checks。
probe() {
  ORDER=""; WIN_LINE=""; WIN_NUM=""; NEXT=""
  if ! efi_available; then
    dbk_add_check "未找到 ${EFI[0]}(本机非 UEFI,或该工具未安装)"
    dbk_exit 跳过 "跳过:未找到 efibootmgr;若系统以 Legacy/BIOS 方式安装,请改用开机厂商启动菜单键(BOOT_MENU_KEY)选 Windows Boot Manager(sudo apt-get install -y efibootmgr 可装上)"
  fi
  ORDER="$(read_order || true)"
  if [ -z "$ORDER" ]; then
    dbk_add_check "读不到 BootOrder(efivarfs 通常只对 root 可读)"
    dbk_exit 需人工 "读不到 BootOrder:用 sudo 重跑(sudo bash $0),或人工执行 sudo efibootmgr 核对后再决定"
  fi
  dbk_add_check "BootOrder: $ORDER(首位 ${ORDER%%,*})"
  WIN_LINE="$(find_win_line || true)"; WIN_NUM="$(win_num_of "$WIN_LINE")"
  if [ -z "$WIN_NUM" ]; then
    dbk_add_check "未找到 Windows Boot Manager 条目(描述匹配 '$MATCH',兜底匹配 loader 路径含 microsoft)"
    dbk_exit FAIL "efibootmgr 里找不到 Windows Boot Manager 条目:核对 Windows 引导(见 docs/07-rescue.md);本次未做任何改动"
  fi
  dbk_add_check "目标条目:Boot$WIN_NUM $WIN_LINE"
  NEXT="$(read_next || true)"
  [ -z "$NEXT" ] || dbk_add_check "当前 BootNext=$NEXT(已有一次性启动项,可能来自上一次运行)"
  return 0
}

apply_run() {
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply"; }
  probe
  if ! efi_run -n "$WIN_NUM" >/dev/null; then
    dbk_add_check "efibootmgr -n $WIN_NUM 失败"
    dbk_exit FAIL "efibootmgr -n $WIN_NUM 失败(一次性启动项未设置);未做任何其他改动"
  fi
  dbk_add_action "执行 efibootmgr -n $WIN_NUM(一次性;未执行 efibootmgr -o,永久顺序不动)"; dbk_mark_changed
  AFTER="$(read_order || true)"
  if [ -z "$AFTER" ]; then
    dbk_add_check "重新读取 BootOrder 失败,I2 断言无法完成"
    dbk_exit FAIL "重新读取 BootOrder 失败:请人工执行 sudo efibootmgr 核对首位仍是 Windows Boot Manager"
  fi
  AFTER_NEXT="$(read_next || true)"
  if [ "$AFTER_NEXT" != "$WIN_NUM" ]; then
    dbk_add_check "BootNext 未按预期设置(期望 $WIN_NUM,回读到 '${AFTER_NEXT:-空}')"
    dbk_exit FAIL "BootNext 未按预期设置:efibootmgr -n 可能返回 0 但未写入,重启会进错误系统;请人工核对后再重启"
  fi
  if [ "$AFTER" != "$ORDER" ]; then
    dbk_add_check "I2 断言失败:BootOrder 前后不一致(前 '$ORDER',后 '$AFTER')"
    dbk_exit FAIL "I2 断言失败:BootOrder 被改动;立即在固件设置界面把 Windows Boot Manager 改回首位,并把偏差写进 L4 记录"
  fi
  dbk_add_action "I2 断言通过:BootOrder 未变(首位 ${AFTER%%,*})"
  dbk_add_action "下一步(手工执行):sudo systemctl reboot(本脚本不自动重启)"
  return 0
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
probe
if [ "$DBK_MODE" = apply ]; then
  dbk_exit PASS "一次性启动项 BootNext=$WIN_NUM 已设置且 BootOrder 未变;现在手工执行 sudo systemctl reboot 即进入 Windows"
fi
dbk_exit PASS "可切回 Windows:--apply 将执行 efibootmgr -n $WIN_NUM;本脚本不执行 efibootmgr -o,重启后一次性条目自动消失"
