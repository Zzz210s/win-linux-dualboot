#!/usr/bin/env bash
# L4:以**一次性**启动项从 Ubuntu 切回 Windows(`efibootmgr -n`,等价于 EFI BootNext),并断言 BootOrder 未变。
#
# 用法:reboot-to-windows.sh [--apply] [--match <描述关键字>] [--log <path>]
#   默认 dry-run:只打印将执行的 `efibootmgr -n <编号>` 与后续提示,不改系统;加 --apply(需 root)才真正设置。
#   执行后重新读取 BootOrder 并断言与执行前逐字一致(I2);脚本**不自动重启**,最后提示手工执行 systemctl reboot。
#   --match 用于匹配 Windows 条目的描述,默认 "Windows Boot Manager"(同时也会匹配 loader 路径含 microsoft 的条目)。
# 纪律(设计文档第 2 节):进 Windows 只用一次性 BootNext,**绝不执行 `efibootmgr -o`**——改永久顺序等于违反 I2。
# 日志追加到 /var/log/dbk/reboot-to-windows.log(该目录不可写时只输出到终端)。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${DBK_LOG:-/var/log/dbk/reboot-to-windows.log}"
APPLY=0
MATCH="${DBK_WIN_MATCH:-Windows Boot Manager}"

# 日志与报错实现与其它 L4 脚本共用(见 dbk-log.sh);缺失时立刻停下(否则后续动作没有输出通道)
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
source "$HERE/dbk-log.sh"

usage() { sed -n '2,9p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --match) need_val "$#" "--match" "<Windows 条目描述关键字>"; MATCH="$2"; shift 2 ;;
    --match=*) MATCH="${1#*=}"; shift ;;
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

if [ "$APPLY" -eq 1 ]; then
  log "模式: apply(将设置一次性启动项)"
else
  log "模式: dry-run(只打印计划,不改系统)"
fi

if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "--apply 需要 root:请用 sudo 重跑,例如 sudo bash scripts/linux/reboot-to-windows.sh --apply"
fi

# 非 UEFI 或未装 efibootmgr:优雅降级(dry-run 照样结束,退出码 0)
if ! command -v efibootmgr >/dev/null 2>&1; then
  log "跳过: 未找到 efibootmgr(本机非 UEFI 启动,或未安装该包)。"
  log "提示: 先 sudo apt-get install -y efibootmgr;若系统以 Legacy/BIOS 方式安装,本路径不可用,请改用开机时厂商启动菜单键(BOOT_MENU_KEY)选 Windows Boot Manager。"
  if [ "$APPLY" -eq 1 ]; then exit 1; fi
  log "dry-run 结束:没有可执行的计划(退出码 0)。"
  exit 0
fi

# 读取 BootOrder(efivarfs 通常只对 root 可读,读不到时同样优雅降级)
read_order() { efibootmgr 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n 1; }

BEFORE_ORDER=""
if [ "$(id -u)" -eq 0 ]; then BEFORE_ORDER="$(read_order || true)"; fi
if [ -z "$BEFORE_ORDER" ]; then
  log "跳过: 读不到 BootOrder(需要 root:efivarfs 只对 root 可读)。"
  log "提示: 用 sudo 重跑,例如 sudo bash scripts/linux/reboot-to-windows.sh --apply"
  if [ "$APPLY" -eq 1 ]; then exit 1; fi
  log "dry-run 结束:没有可执行的计划(退出码 0)。"
  exit 0
fi
log "执行前 BootOrder: $BEFORE_ORDER"

VERBOSE="$(efibootmgr -v 2>/dev/null || true)"
WIN_LINE="$(printf '%s\n' "$VERBOSE" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -i -e "$MATCH" -e 'microsoft' | head -n 1 || true)"
WIN_NUM="$(printf '%s' "$WIN_LINE" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')"
if [ -z "$WIN_NUM" ]; then
  log "错误: efibootmgr 里找不到 Windows Boot Manager 条目(描述匹配 '$MATCH',兜底匹配 loader 路径含 microsoft)。"
  log "提示: 请核对 Windows 引导是否完好(见 docs/07-rescue.md);本次切换未做任何改动。"
  exit 1
fi
log "目标条目: Boot${WIN_NUM}  $WIN_LINE"

if [ "$APPLY" -ne 1 ]; then
  log "计划执行(一次性启动项): efibootmgr -n $WIN_NUM"
  log "计划随后: 重新读取 BootOrder 并断言与执行前逐字一致(全程不执行 efibootmgr -o,不改变永久启动顺序)。"
  log "计划最后: 提示手工执行 systemctl reboot(本脚本不自动重启)。"
  log "dry-run 结束:未改动系统;真正执行请用 sudo bash scripts/linux/reboot-to-windows.sh --apply"
  exit 0
fi

log "执行: efibootmgr -n $WIN_NUM"
efibootmgr -n "$WIN_NUM" >/dev/null || die "efibootmgr -n $WIN_NUM 失败(一次性启动项未设置)"

AFTER_ORDER="$(read_order || true)"
if [ -z "$AFTER_ORDER" ]; then
  die "重新读取 BootOrder 失败,I2 断言无法完成;请手工执行 sudo efibootmgr 核对首位仍是 Windows Boot Manager"
fi
log "执行后 BootOrder: $AFTER_ORDER"
AFTER_NEXT="$(efibootmgr 2>/dev/null | sed -n 's/^BootNext:[[:space:]]*//p' | head -n 1 || true)"
if [ -n "$AFTER_NEXT" ]; then
  log "已设置 BootNext: $AFTER_NEXT(一次性,只在下次启动生效,用过即消失)"
fi
[ "$AFTER_ORDER" = "$BEFORE_ORDER" ] || die "I2 断言失败: BootOrder 在执行前后不一致(执行前 '$BEFORE_ORDER',执行后 '$AFTER_ORDER');立即在固件设置界面把 Windows Boot Manager 改回首位,并把偏差写进 L4 记录"

FIRST="$(printf '%s' "$AFTER_ORDER" | cut -d, -f1)"
log "I2 断言通过: BootOrder 未变(首位 $FIRST);本脚本未执行 efibootmgr -o。"
log "下一步(手工执行): sudo systemctl reboot"
log "重启后进入 Windows;一次性条目用后自动消失。回 Ubuntu 仍走开机厂商启动菜单键或 Windows 侧 scripts/windows/set-bootnext.ps1(I2)。"
