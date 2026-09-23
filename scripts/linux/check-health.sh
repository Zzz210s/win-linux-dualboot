#!/usr/bin/env bash
# 对应卡:07-7
# 用途:周期巡检(Linux / Kubuntu 侧):只读采集体检结论,替代原 dbk-rollback.sh --check 的巡检角色。
#   (原原子版的"部署列表与固定状态 + 回滚可用性"随 dbk-rollback.sh 删除;包级回退的可用性由
#    rollback-pkg.sh --check 回答,nvidia 模块签名的细查由 check-signature.sh 承担。)
# 硬判据(不满足 → 1):
#   ① 会话类型 = wayland(设计 04 第 1.1 节:Kubuntu 26.04 是 Wayland-only)
#   ② snap 零残留(snap 命令不存在或 `snap list` 为空 + `dpkg -l snapd` 无 ii 行)
#   ③ `systemctl is-system-running` = running(degraded → 失败;starting/maintenance/stopping → 需人工)
#   ④ 根分区余量 ≥10%(df -P /)
# 记录项(取不到 → 2;不影响通过与否):显卡驱动来源与版本(ubuntu-drivers devices 的推荐行 + nvidia 模块签名者)、
#   待升级包数(apt-get -s dist-upgrade 的 Inst 行数)、journald 是否持久化。
# 只读保证:本脚本只有读动作;--apply 与 --check 输出相同(不改任何文件、不装包、不重启服务)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-health.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要设置):DBK_SNAP / DBK_DPKG / DBK_SYSTEMCTL / DBK_DF / DBK_MODINFO /
#   DBK_UBUNTU_DRIVERS / DBK_APT_GET / DBK_DPKG_QUERY / DBK_JOURNAL_DIR / DBK_SESSION_TYPE。
# 待核实(以官方文档为准):systemctl is-system-running 的取值集合、ubuntu-drivers devices 的输出格式、
#   apt-get -s dist-upgrade 的 Inst 行格式均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-health"

SNAP_STR="${DBK_SNAP:-snap}"; DPKG_STR="${DBK_DPKG:-dpkg}"; SC_STR="${DBK_SYSTEMCTL:-systemctl}"
DF_STR="${DBK_DF:-df}"; MO_STR="${DBK_MODINFO:-modinfo}"; UD_STR="${DBK_UBUNTU_DRIVERS:-ubuntu-drivers}"
AG_STR="${DBK_APT_GET:-apt-get}"; DQ_STR="${DBK_DPKG_QUERY:-dpkg-query}"
JRNL_DIR="${DBK_JOURNAL_DIR:-/var/log/journal}"
SNAP=(); DPKG=(); SC=(); DF=(); MO=(); UD=(); AG=(); DQ=()
read -r -a SNAP <<<"$SNAP_STR"; read -r -a DPKG <<<"$DPKG_STR"; read -r -a SC <<<"$SC_STR"
read -r -a DF <<<"$DF_STR"; read -r -a MO <<<"$MO_STR"; read -r -a UD <<<"$UD_STR"
read -r -a AG <<<"$AG_STR"; read -r -a DQ <<<"$DQ_STR"
# 包装函数一律「名字不与外部命令同名 + 体内 command」双保险:函数查找优先于 PATH,同名(snap/dpkg)会无限递归。
snap_() { command "${SNAP[@]}" "$@"; }
dpkg_() { command "${DPKG[@]}" "$@"; }
sc() { command "${SC[@]}" "$@"; }
dfc() { command "${DF[@]}" "$@"; }
mo() { command "${MO[@]}" "$@"; }
ud() { command "${UD[@]}" "$@"; }
ag() { command "${AG[@]}" "$@"; }
dq() { command "${DQ[@]}" "$@"; }

ISSUES=(); MANUAL=(); PROBE_OUT=""; PROBE_RC=0
# 统一探针:stdout+stderr 收进 PROBE_OUT(不吞输出),返回命令自身退出码;PROBE_RC 留给调用方分辨
# 127(命令不存在 → 该项需人工)与真正的执行失败(→ FAIL)。
probe() {
  local out
  if out="$("$@" 2>&1)"; then PROBE_RC=0; else PROBE_RC=$?; fi
  PROBE_OUT="$out"
  return 0
}

# 硬判据 ①:会话类型
check_session() {
  case "${DBK_SESSION_TYPE:-${XDG_SESSION_TYPE:-}}" in
    wayland) dbk_add_check "①会话类型:XDG_SESSION_TYPE=wayland" ;;
    "") MANUAL+=("①取不到 XDG_SESSION_TYPE(不在图形会话里?用 loginctl show-session 复核)") ;;
    *) ISSUES+=("①XDG_SESSION_TYPE=${DBK_SESSION_TYPE:-$XDG_SESSION_TYPE}:要求 wayland(Kubuntu 26.04 是 Wayland-only)") ;;
  esac
}
# 硬判据 ②:snap 零残留
check_snap() {
  local apps=""
  if command -v "${SNAP[0]}" >/dev/null 2>&1; then
    probe snap_ list
    apps="$(printf '%s\n' "$PROBE_OUT" | awk 'NR>1 && $1 !~ /^Name$/ && NF>0 {print $1}' | tr '\n' ' ')"
    case "$PROBE_OUT" in
      *"No snaps are installed"*|*"no snaps installed"*) apps="" ;;
    esac
    if [ -n "$apps" ]; then ISSUES+=("②仍有 snap 应用:$apps(见 05-14)"); return 0; fi
    dbk_add_check "②snap list 为空"
  else
    dbk_add_check "②snap 命令不存在(设计 04 第 3 节 S1/S2 的期望态)"
  fi
  probe dpkg_ -l snapd
  if printf '%s\n' "$PROBE_OUT" | grep -qE '^ii[[:space:]]+snapd'; then
    ISSUES+=("②snapd 已安装(dpkg -l 有 ii 行);按 05-14 清除并写 pin")
  elif [ "$PROBE_RC" -eq 127 ]; then
    MANUAL+=("②未找到 ${DPKG[0]},无法核对 snapd 是否安装")
  else
    dbk_add_check "②dpkg -l snapd 无输出(未安装)"
  fi
}
# 硬判据 ③:systemctl is-system-running
check_system_state() {
  if ! command -v "${SC[0]}" >/dev/null 2>&1; then MANUAL+=("③未找到 ${SC[0]},无法读系统状态"); return 0; fi
  probe sc is-system-running
  case "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" in
    running) dbk_add_check "③systemctl is-system-running=running" ;;
    degraded) ISSUES+=("③systemctl is-system-running=degraded:有单元失败(systemctl --failed 逐条看)") ;;
    "") MANUAL+=("③systemctl is-system-running 无输出;请人工执行看系统状态") ;;
    *) MANUAL+=("③systemctl is-system-running=$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')(启动中/维护中等过渡态,请稍后重跑)") ;;
  esac
}
# 硬判据 ④:根分区余量
check_root_free() {
  local pct
  if ! command -v "${DF[0]}" >/dev/null 2>&1; then MANUAL+=("④未找到 ${DF[0]},无法读根分区余量"); return 0; fi
  probe dfc -P /
  pct="$(printf '%s\n' "$PROBE_OUT" | awk 'NR>1 {gsub(/%/,"",$5); print $5; exit}')"
  case "$pct" in
    ""|*[!0-9]*) MANUAL+=("④取不到根分区余量(df -P / 输出异常)"); return 0 ;;
  esac
  if [ "$pct" -ge 10 ]; then dbk_add_check "④根分区余量 ${pct}%(≥10%)"
  else ISSUES+=("④根分区余量仅 ${pct}%(<10%):按 05-6 核对 zram/swapfile 并清理"); fi
}
# 记录项:显卡驱动来源与版本、待升级包数、journald 持久化(取不到只记需人工)
check_record() {
  local src="" UP=0
  if command -v "${UD[0]}" >/dev/null 2>&1; then
    probe ud devices
    src="$(printf '%s\n' "$PROBE_OUT" | grep -iE 'recommended|driver' | head -n 2 | tr '\n' ';' | sed 's/;$//' || true)"
  fi
  if [ -z "$src" ]; then MANUAL+=("显卡驱动来源:取不到 ubuntu-drivers devices 的推荐行($UD_STR)"); fi
  if command -v "${MO[0]}" >/dev/null 2>&1; then
    probe mo -F signer nvidia
    if [ -n "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
      dbk_add_check "显卡模块签名者(modinfo -F signer nvidia):$(printf '%s' "$PROBE_OUT" | head -n1)"
    else
      dbk_add_check "显卡模块:modinfo -F signer nvidia 无输出(未装/未加载;签名细查见 check-signature.sh)"
    fi
  fi
  probe dq -W -f='${Package} ${Version}' 'nvidia-driver-*'
  if [ -n "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    dbk_add_check "显卡驱动来源(Ubuntu 官方包):$(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"
  elif [ -n "$src" ]; then
    dbk_add_check "显卡驱动来源(ubuntu-drivers devices):$src"
  fi
  if command -v "${AG[0]}" >/dev/null 2>&1; then
    probe ag -s dist-upgrade
    UP="$(printf '%s\n' "$PROBE_OUT" | grep -cE '^Inst[[:space:]]' || true)"
    dbk_add_check "待升级包数=${UP:-0}(apt-get -s dist-upgrade 的 Inst 行)"
  else
    MANUAL+=("待升级包数:未找到 ${AG[0]}")
  fi
  if [ -d "$JRNL_DIR" ]; then dbk_add_check "journald 持久化:存在 $JRNL_DIR"; else MANUAL+=("journald 未持久化:$JRNL_DIR 不存在(见 05-7)"); fi
}

check_all() {
  ISSUES=(); MANUAL=()
  check_session; check_snap; check_system_state; check_root_free; check_record
  return 0
}

check_all
UP=""
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本无写动作(只读巡检);--apply 与 --check 输出相同。"; fi
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "周期巡检发现 ${#ISSUES[@]} 项硬判据不满足;逐条见 checks(处置卡号见各条说明)"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "周期巡检有 ${#MANUAL[@]} 项无法判定(不属于失败,但必须人工确认);逐条见 checks"
fi
dbk_exit PASS "周期巡检通过:会话 wayland、snap 零残留、系统 running、根分区余量充足(其余为记录项,见 checks)"
