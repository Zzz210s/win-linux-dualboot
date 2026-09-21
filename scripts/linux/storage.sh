#!/usr/bin/env bash
# 对应卡:05-6
# 破坏性:1
# L4 卡 05-6:交换空间落地与核对 —— swapfile 4GiB(不建 swap 分区、不做休眠)+ zram 核对(约 min(RAM/2, 8GiB))。
# 原子版语义(设计 02 第 8 节 / 设计 4.7 的 R6):zram 由发行版自带,本卡**只核对**(zramctl 列出 zram0 即通过);
#   仅当 zram0 缺失时,--apply 才分层安装 systemd-zram-generator(rpm-ostree install,# 待核实(以官方文档为准))+ 安装
#   templates/zram-generator.conf,并标明**需重启**(分层安装只写进下一部署)。
# 判据(--check,零写):① swapon 列出 <swapfile>;② /etc/fstab 有该 swapfile 行(缺 nofail 记需人工);
#   ③ zramctl 列出 zram0(无 zramctl 时退看 /sys/block/zram0,仍取不到 → 需人工)。
# --apply(需要 root,且必须 --yes):fallocate -l -> chmod 600 -> mkswap -> swapon -> 缺则备份 fstab 后追加
#   -> zram0 缺失时安装配置并分层装包 -> systemctl daemon-reload + start systemd-zram-setup@zram0.service -> 复读判据。
# 本脚本逐项汇总、整体返回 0/1/2:单项失败不中断(不 set -e、不启用 errtrap,与 hardening.sh 同口径)。
# 环境开关:DBK_SKIP_OSTREE=1 只跳过分层安装。注入:DBK_SWAPFILE / DBK_SWAP_SIZE / DBK_FSTAB / DBK_ZRAM_CONF /
#   DBK_ZRAM_TPL / DBK_SWAPON / DBK_ZRAMCTL / DBK_SYSTEMCTL(离线夹具用)。
# 回退:swapoff <swapfile> && rm -f <swapfile>;删 fstab 的 swapfile 行与 zram-generator.conf;都不动分区表(决策 3.8)。
# 夹具级验证,真机未跑。用法:storage.sh [--size 4G] [--swapfile /swapfile] [--check|--apply] [--json]
#   [--log <路径>] [--yes] [--step NN-K] [-h]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-ostree.sh disable=SC1091
. "$HERE/dbk-ostree.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)
log() { dbk_obs "$*"; }

FSTAB="${DBK_FSTAB:-/etc/fstab}"; FSTAB_BAK="$FSTAB.dbk.bak"
SWAPFILE="${DBK_SWAPFILE:-/swapfile}"; SWAP_SIZE="${DBK_SWAP_SIZE:-4G}"
ZRAM_CONF="${DBK_ZRAM_CONF:-/etc/systemd/zram-generator.conf}"
ZRAM_TPL="${DBK_ZRAM_TPL:-$ROOT/templates/zram-generator.conf}"
ZRAM_PKG="${DBK_ZRAM_PKG:-systemd-zram-generator}"
SWAPON="${DBK_SWAPON:-swapon}"; ZRAMCTL="${DBK_ZRAMCTL:-zramctl}"; SYSTEMCTL="${DBK_SYSTEMCTL:-systemctl}"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --size) dbk_cli_val "--size" "${2:-}"; SWAP_SIZE="$2"; shift 2 ;;
    --size=*) SWAP_SIZE="${1#*=}"; shift ;;
    --swapfile) dbk_cli_val "--swapfile" "${2:-}"; SWAPFILE="$2"; shift 2 ;;
    --swapfile=*) SWAPFILE="${1#*=}"; shift ;;
    --dry-run) shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "storage"
case "$SWAPFILE" in /*) ;; *) dbk_usage; dbk_note "用法错误: --swapfile 需要绝对路径: $SWAPFILE"; exit "$DBK_USAGE" ;; esac
case "$SWAP_SIZE" in ""|*[!0-9GgMmKk]*) dbk_usage; dbk_note "用法错误: --size 只允许数字与单位 G/M/K: $SWAP_SIZE"; exit "$DBK_USAGE" ;; esac

swap_names() { "$SWAPON" --show=NAME --noheadings 2>/dev/null | awk '{print $1}'; }
swap_active() { local n
  while IFS= read -r n; do [ "$n" = "$SWAPFILE" ] && return 0; done < <(swap_names)
  return 1
}
zram_present() {
  if command -v "$ZRAMCTL" >/dev/null 2>&1; then
    "$ZRAMCTL" 2>/dev/null | grep -q '^zram0' && return 0
    return 1
  fi
  [ -e /sys/block/zram0 ]
}
zram_detail() { "$ZRAMCTL" 2>/dev/null | grep '^zram0' | head -n 1 || printf '%s' "${ZRAMCTL} 不可用,看 /sys/block/zram0"; }
fstab_cur() { awk -v p="$SWAPFILE" '!/^[[:space:]]*#/ && $1==p' "$FSTAB" 2>/dev/null || true; }
fstab_add() {
  if [ ! -e "$FSTAB_BAK" ]; then
    if cp -a "$FSTAB" "$FSTAB_BAK"; then dbk_add_action "备份 $FSTAB -> $FSTAB_BAK(仅首次,重跑不覆盖)"
    else ISSUES+=("备份 $FSTAB 失败"); return 0; fi
  fi
  if printf '\n# L4 交换空间(决策 3.8):zram + swapfile,不做休眠\n%s\n' "$1" >>"$FSTAB"; then
    dbk_add_action "追加 fstab 行: $1"; dbk_mark_changed
  else ISSUES+=("写入 $FSTAB 失败"); fi
  return 0
}

ISSUES=(); MANUAL=(); EXTRA_MANUAL=(); REBOOT_NEEDED=0

judge() {
  local cur
  ISSUES=(); MANUAL=()
  if swap_active; then dbk_add_check "交换空间已启用:$SWAPFILE"
  else ISSUES+=("交换空间 $SWAPFILE 未启用(--apply 会创建并启用)"); fi
  cur="$(fstab_cur)"
  if [ -n "$cur" ]; then
    dbk_add_check "fstab 已有 $SWAPFILE 行"
    case "$cur" in *nofail*) ;; *) MANUAL+=("fstab 的 $SWAPFILE 行缺 nofail(设计第 8 节 F 组判据),请人工核对");; esac
  else ISSUES+=("fstab 缺少 $SWAPFILE 行(--apply 会追加)"); fi
  if zram_present; then dbk_add_check "zram0 已建立(核对通过):$(zram_detail)"
  elif command -v "$ZRAMCTL" >/dev/null 2>&1; then
    ISSUES+=("zramctl 未列出 zram0(硬前置: rpm-ostree install $ZRAM_PKG 后重启)")
  else MANUAL+=("无 zramctl 也无 /sys/block/zram0,脚本判不了 zram(请人工看 lsblk)"); fi
  if [ ! -r "$ZRAM_TPL" ]; then MANUAL+=("缺少 zram 模板 $ZRAM_TPL(zram0 缺失时 --apply 需要它)"); fi
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    dbk_add_check "systemd-oomd(R6): is-enabled=$("$SYSTEMCTL" is-enabled systemd-oomd 2>&1 || true) is-active=$("$SYSTEMCTL" is-active systemd-oomd 2>&1 || true)"
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#EXTRA_MANUAL[@]}" -gt 0 ]; then MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"}); fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了或需重启后复核;逐条见 checks"
  fi
  dbk_exit PASS "$msg:swapfile 已启用 + fstab 行齐备 + zram0 已建立"
}

apply_run() {
  local out st pkg_st cur
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; }
  # 1) swapfile:不存在则创建;存在则跳过创建(重跑幂等),未启用时补 swapon
  if [ ! -e "$SWAPFILE" ]; then
    if fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
      dbk_add_action "创建 $SWAPFILE($SWAP_SIZE)"; dbk_mark_changed
      chmod 600 "$SWAPFILE" 2>/dev/null || dbk_add_check "警告: chmod 600 $SWAPFILE 失败"
      out="$(mkswap "$SWAPFILE" 2>&1)"; st=$?
      if [ "$st" -eq 0 ]; then dbk_add_action "mkswap: $(printf '%s' "$out" | tail -n 1)"
      else ISSUES+=("mkswap $SWAPFILE 失败: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"); fi
    else ISSUES+=("fallocate -l $SWAP_SIZE $SWAPFILE 失败(root 空间不足?决策 3.6 给 root 约 113GiB)"); fi
  else dbk_add_action "$SWAPFILE 已存在,跳过创建(fallocate 不覆盖已有文件)"; fi
  if [ -e "$SWAPFILE" ] && ! swap_active; then
    if "$SWAPON" "$SWAPFILE" 2>/dev/null; then dbk_add_action "已启用 $SWAPFILE"; dbk_mark_changed
    else ISSUES+=("swapon $SWAPFILE 失败(mkswap 未成功或内核拒绝该文件)"); fi
  fi
  # 2) fstab:已有该路径条目则跳过;否则备份后追加
  cur="$(fstab_cur)"
  if [ -n "$cur" ]; then dbk_add_action "fstab 已有 $SWAPFILE 条目,跳过写入"
  else fstab_add "$SWAPFILE  none  swap  sw,nofail  0 0"; fi
  # 3) zram:默认只核对;缺失时才安装(原子版分层安装需重启)
  if zram_present; then
    dbk_add_action "zram0 已存在,跳过分层安装与配置(本卡 zram 只核对)"
  elif [ ! -r "$ZRAM_TPL" ]; then
    ISSUES+=("缺少 zram 模板 $ZRAM_TPL,无法补齐 zram 配置")
  else
    if [ -f "$ZRAM_CONF" ] && cmp -s "$ZRAM_TPL" "$ZRAM_CONF"; then dbk_add_action "$ZRAM_CONF 已是模板内容,跳过写入"
    else
      if [ -f "$ZRAM_CONF" ] && [ ! -e "$ZRAM_CONF.dbk.bak" ]; then cp -a "$ZRAM_CONF" "$ZRAM_CONF.dbk.bak" && dbk_add_action "备份 $ZRAM_CONF -> $ZRAM_CONF.dbk.bak"; fi
      mkdir -p "$(dirname "$ZRAM_CONF")" 2>/dev/null
      if cp -a "$ZRAM_TPL" "$ZRAM_CONF"; then dbk_add_action "安装 $ZRAM_TPL -> $ZRAM_CONF"; dbk_mark_changed
      else ISSUES+=("写入 $ZRAM_CONF 失败"); fi
    fi
    pkg_st=0; pkg_ensure "$ZRAM_PKG" "sudo rpm-ostree install $ZRAM_PKG && sudo systemctl reboot" || pkg_st=$?
    if [ "$pkg_st" -eq 9 ]; then EXTRA_MANUAL+=("DBK_SKIP_OSTREE=1:未分层安装 $ZRAM_PKG,zram 需人工确认")
    elif [ "$pkg_st" -eq 1 ]; then ISSUES+=("分层安装 $ZRAM_PKG 失败;硬前置: sudo rpm-ostree install $ZRAM_PKG && sudo systemctl reboot 后重跑")
    else dbk_add_action "已请求分层安装 $ZRAM_PKG"; pkg_reboot_hint; fi
    if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
      "$SYSTEMCTL" daemon-reload || dbk_add_check "警告: systemctl daemon-reload 失败"
      if "$SYSTEMCTL" start systemd-zram-setup@zram0.service 2>/dev/null; then dbk_add_action "已启动 systemd-zram-setup@zram0.service"
      else dbk_add_check "警告: 启动 systemd-zram-setup@zram0.service 失败(可能需重启后生效)"; fi
    fi
    if ! zram_present; then
      EXTRA_MANUAL+=("zram0 仍未出现:分层安装需重启后才生效,重启后重跑本脚本核对 zram0")
      REBOOT_NEEDED=1
    fi
  fi
  return 0
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
if [ "$REBOOT_NEEDED" -ne 1 ]; then judge; fi
if [ "$DBK_MODE" = apply ]; then finish "交换空间落地已执行(--apply;复读判据)"; else finish "交换空间核对完成(--check 零写)"; fi
