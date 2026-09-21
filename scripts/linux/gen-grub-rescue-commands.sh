#!/usr/bin/env bash
# 对应卡:07-2
# 卡 07-2「从 GRUB 提示符回去」:按当前磁盘参数生成**两套可复制**的救援命令(纯打印,不执行、不写盘):
#   ① 从 GRUB 提示符回 Windows(insmod chain → search --file → chainloader → boot);
#   ② 修 GRUB 自身(ls → set root → set prefix → insmod normal → normal)。
# 只读保证:本脚本只读 lsblk/findmnt 做参数校验,不执行任何生成的命令、不写任何文件,--apply 与 --check 输出完全相同。
# 纪律(与设计第 2 节硬规则一致,生成文本里也不出现反向建议):只走 GRUB 提示符,**不改永久启动顺序**(不执行 efibootmgr 的 -o 写操作)、
#   不改 {bootmgr} 的 path、不建议关闭 Secure Boot(签名与 MOK 见卡 07-7 的 check-signature.sh)。
# 参数: -d|--disk <n> 缺省 0(GRUB 盘号,生成 (hd0,...));从 lsblk 可读时校验盘存在。
#       --esp-part <n> 缺省 1(Windows ESP 分区号,生成 (hd0,gpt1));--root-part <n> 缺省现场探测,取不到用 <ROOT> 占位;
#       --boot-part <n> 独立 /boot 分区号(探测到独立 /boot 时会自动采用;它的 GRUB 文件通常在该分区根下的 grub / grub2)。
# 退出码:0 = 两套命令已生成;1 = 参数非法或磁盘不存在(指出是哪一项);2 = 探测不到现场分区(用 <ROOT> 占位生成,提示人工替换);9 = 非 Linux。
# 注入钩子(真机留空;夹具用。取值 = 命令名/可带参数的命令行(由夹具注入假命令),或一个存在的文件路径(回放该文件)):
#   DBK_LSBLK / DBK_FINDMNT / DBK_UNAME
# 待核实(以官方文档为准):GRUB 的 (hdX,gptN) 命名、prefix 路径与「看到:」判据未在真机验证;hd 号是 GRUB 看到的盘序,
#   通常与 Linux 盘序一致但**不保证** —— 不确定时先在 grub 提示符用 ls 逐个确认。
# 夹具级验证,真机未跑。用法: gen-grub-rescue-commands.sh [-d <n>] [--esp-part <n>] [--root-part <n>] [--boot-part <n>] [--check|--apply] [--json] [--log <路径>] [--step NN-K]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

DISK=0; ESP_P=1; ROOT_REQ=""; BOOT_REQ=""; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--disk) dbk_cli_val "$1" "${2:-}"; DISK="$2"; shift 2 ;;
    --esp-part) dbk_cli_val "$1" "${2:-}"; ESP_P="$2"; shift 2 ;;
    --root-part) dbk_cli_val "$1" "${2:-}"; ROOT_REQ="$2"; shift 2 ;;
    --boot-part) dbk_cli_val "$1" "${2:-}"; BOOT_REQ="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "gen-grub-rescue-commands"
dbk_enable_errtrap

LSB_HOOK="${DBK_LSBLK:-lsblk}"; FM_HOOK="${DBK_FINDMNT:-findmnt}"
hook_avail() { local spec="${1:-}" p=(); [ -e "$spec" ] && return 0; read -r -a p <<<"$spec"; command -v "${p[0]}" >/dev/null 2>&1; }
hook_out() {
  local spec="${1:-}"; shift || true
  if [ -e "$spec" ]; then cat -- "$spec" 2>&1 || true; return 0; fi
  local p=(); read -r -a p <<<"$spec"; "${p[@]}" "$@" 2>&1 || true; return 0
}
is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
count_of() { printf '%s\n' "${1:-}" | grep -cE "${2:-}" || true; }
# /dev/nvme0n1p5 -> 5;/dev/sda3 -> 3(只对 TYPE="part" 的设备名取号,避免把整盘当分区)
part_of() { printf '%s' "${1:-}" | sed -n 's|.*p\([0-9]\+\)$|\1|p' | head -n1; }
emit() { if [ "${DBK_JSON:-0}" -eq 1 ]; then dbk_add_action "$1"; else printf '%s\n' "$1"; fi; }

# 0) 只在 Linux 上可用
UNAME_OUT="$(hook_out "${DBK_UNAME:-uname -s}")"
case "$UNAME_OUT" in
  Linux*) ;;
  *) dbk_add_check "环境: 当前不是 Linux(uname 输出 '$UNAME_OUT')"
     dbk_exit 跳过 "跳过:本脚本只在 Linux 救援环境可用(uname 输出 '$UNAME_OUT');Windows 侧引导修复见 07-3" ;;
esac

# 1) 参数合法性(非法 → 1,并指出是哪一项)
BAD=""; add_bad() { if [ -n "$BAD" ]; then BAD="$BAD; $1"; else BAD="$1"; fi; }
is_uint "$DISK" || add_bad "--disk 必须是非负整数(收到 '$DISK')"
if is_uint "$ESP_P"; then [ "$ESP_P" -ge 1 ] || add_bad "--esp-part 不能是 0(收到 '$ESP_P')"; else add_bad "--esp-part 必须是正整数(收到 '$ESP_P')"; fi
if [ -n "$ROOT_REQ" ] && ! is_uint "$ROOT_REQ"; then add_bad "--root-part 必须是正整数(收到 '$ROOT_REQ')"; fi
if [ -n "$BOOT_REQ" ] && ! is_uint "$BOOT_REQ"; then add_bad "--boot-part 必须是正整数(收到 '$BOOT_REQ')"; fi
if [ -n "$BAD" ]; then
  dbk_add_check "失败项: 参数非法:$BAD"
  dbk_exit FAIL "参数非法:$BAD;用法: $0 [-d <盘号>] [--esp-part <分区号>] [--root-part <分区号>] [--boot-part <分区号>]"
fi

# 2) 现场探测:盘是否存在 / root 分区号 / 是否独立 /boot
LSB=""; if hook_avail "$LSB_HOOK"; then LSB="$(hook_out "$LSB_HOOK" -P -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT)"; fi
DISK_N="$(count_of "$LSB" 'TYPE="disk"')"; PART_N="$(count_of "$LSB" 'TYPE="part"')"
LSB_OK=0; [ -n "$LSB" ] && [ "$PART_N" -gt 0 ] && LSB_OK=1
UNKNOWN=0
if [ "$DISK_N" -gt 0 ] && [ "$DISK" -ge "$DISK_N" ]; then
  dbk_add_check "失败项: 磁盘 hd$DISK 不存在(lsblk 只看到 $DISK_N 块盘)"
  dbk_exit FAIL "磁盘参数不存在:--disk $DISK 超出 lsblk 看到的 $DISK_N 块盘;先跑 lsblk -o NAME,SIZE,TYPE 确认盘序"
fi
root_src() { hook_out "$FM_HOOK" -n -o SOURCE "$1"; }
lsb_part() { printf '%s' "${1:-}" | grep -qE "NAME=\"[^\"]*p?${2}\"|NAME=\"[^\"]*p${2}\""; }
ROOT_P="$ROOT_REQ"; BOOT_P="$BOOT_REQ"
if [ -n "$ROOT_REQ" ]; then
  if [ "$LSB_OK" -eq 1 ] && ! lsb_part "$LSB" "$ROOT_REQ"; then
    dbk_add_check "失败项: --root-part $ROOT_REQ 在 lsblk 的分区列表里找不到"
    dbk_exit FAIL "--root-part $ROOT_REQ 不存在:lsblk 里没有这个分区;先跑 lsblk -o NAME,SIZE,TYPE,FSTYPE 确认"
  fi
fi
if [ -z "$ROOT_P" ] && [ "$LSB_OK" -eq 1 ]; then ROOT_P="$(part_of "$(root_src /)")"; fi
if [ -z "$BOOT_P" ] && [ "$LSB_OK" -eq 1 ]; then
  bp="$(part_of "$(root_src /boot)")"
  if [ -n "$bp" ] && [ "$bp" != "$ROOT_P" ]; then BOOT_P="$bp"; fi
fi
if [ "$LSB_OK" -eq 0 ]; then UNKNOWN=1; fi
if [ -z "$ROOT_P" ]; then ROOT_P="<ROOT>"; UNKNOWN=1; fi
if [ -z "$BOOT_P" ]; then BOOT_P=""; fi
dbk_add_check "参数: 盘号 hd$DISK;Windows ESP 分区 hd$DISK,gpt$ESP_P;GRUB root=(hd$DISK,gpt$ROOT_P)$([ -n "$BOOT_P" ] && printf ';独立 /boot=(hd%s,gpt%s)' "$DISK" "$BOOT_P")"
if [ "$LSB_OK" -eq 0 ]; then
  case "$LSB" in
    '') dbk_add_check "需人工: lsblk 无输出,探测不到现场分区;已用占位符生成(--root-part <ROOT> 请人工替换)" ;;
    *) dbk_add_check "需人工: lsblk 里没有 TYPE=\"part\" 的行,探测不到现场分区;已用占位符生成(请人工替换 <ROOT>)" ;;
  esac
fi

# 3) 生成两套命令(纯打印;JSON 模式下进 actions[],stdout 只有一行 JSON)
D1="(hd$DISK,gpt$ESP_P)"
if [ -n "$BOOT_P" ]; then D2="(hd$DISK,gpt$BOOT_P)"; P2="$D2/grub"; else D2="(hd$DISK,gpt$ROOT_P)"; P2="$D2/boot/grub"; fi
B1="① 从 GRUB 提示符回 Windows(不执行 efibootmgr,永久启动顺序不动)
说明: 开机进固件启动菜单选 Fedora / GRUB,在 grub> 提示符下逐条输入下面 4 行(盘号与 Windows ESP 分区来自参数:hd$DISK / gpt$ESP_P)
  insmod chain
  search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
  chainloader /EFI/Microsoft/Boot/bootmgfw.efi
  boot
看到: insmod chain 无输出 = 成功;search 无输出 = 成功(成功定位到 Windows ESP)。若 search 报 file not found,
  说明 Windows ESP 不在 $D1:用 --esp-part 给实际分区号重跑本脚本(先人工核对,不要照抄)。"
B2="② 修 GRUB 自身(root / prefix 按现场给:root=$D2,prefix=$P2)
说明: 先 ls 看分区布局,再逐条输入
  ls
  set root=$D2
  set prefix=$P2
  insmod normal
  normal
看到: insmod normal 报 file not found = prefix 指错(分区号或 /boot/grub 路径不对);修正 prefix 后重来。
  normal 成功会回到正常 GRUB 菜单。Fedora 原子版若把 GRUB 放在分区根的 grub2 下,prefix 改成 $D2/grub2 再试。
  独立 /boot 分区由 --boot-part 指定(本脚本探测到独立 /boot 时会自动用它)。"
TAIL="纪律提醒:以上只走 GRUB 提示符。不要改永久启动顺序(不执行 efibootmgr 的 -o 写操作)、不要改 {bootmgr} 的 path、
不要关闭 Secure Boot(NVIDIA 签名与 MOK 见卡 07-7 的 check-signature.sh)。修好后进系统把偏差写进 L4 记录。"
emit "$B1"; emit "$B2"; emit "$TAIL"
dbk_add_check "已生成两套命令:① 回 Windows(4 条,目标 $D1);② 修 GRUB(root=$D2,prefix=$P2)"
if [ "$UNKNOWN" -eq 1 ]; then
  dbk_exit 需人工 "探测不到现场分区,已用占位符生成:请把命令里的 <ROOT> / 分区号替换成实际值(Linux 下用 lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 查到后再跑 --root-part <n>)"
fi
dbk_exit PASS "已按现场参数生成两套可复制的 GRUB 救援命令(root=$D2,prefix=$P2);在 grub> 提示符逐条输入,不要改永久启动顺序"
