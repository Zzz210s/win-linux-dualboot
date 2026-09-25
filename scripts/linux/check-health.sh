#!/usr/bin/env bash
# 对应卡:07-7
# 用途:周期巡检(Linux / 原子版侧):只读采集体检结论(卡 07-7)。
#   部署列表与回滚可用性由 dbk-rollback.sh 回答;更新策略由 dbk-update.sh 回答;Secure Boot 密钥由 dbk-driver.sh 回答。
# 硬判据(不满足 → 1):
#   ① 会话类型 = wayland(设计口径:Wayland 会话);
#   ② 部署数 ≥2 或存在 pinned 部署(部署级回滚路径可用);
#   ③ 自动更新定时器已启用(只检查/下载,**不自动应用也不自动重启**);
#   ④ systemctl is-system-running = running(degraded → 失败;过渡态 → 需人工);
#   ⑤ 根分区余量 ≥10%(df -P /)。
# 记录项(取不到 → 2;不影响通过与否):Secure Boot 密钥注册(mok_check)、模块加载来源(nvidia / nouveau)、
#   待更新(有已下载并排入下次启动的改动 → 需重启才生效)、journald 是否持久化。
# 只读保证:本脚本只有读动作;--apply 与 --check 输出相同(不改任何文件、不装包、不重启服务)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-health.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要设置):DBK_SYSTEMCTL / DBK_DF / DBK_JOURNAL_DIR / DBK_SESSION_TYPE;
#   读类命令的注入由接口层读取:DBK_RPM_OSTREE / DBK_MOKUTIL / DBK_LSMOD。
# 本脚本不写发行版命令字面量(规则 S-1):定时器单元名等一律取自接口(dbk-update.sh 的 $UPDATE_TIMER)。
# 待核实(以官方文档为准):systemctl is-system-running 的取值集合、$UPDATE_TIMER 的单元名与 is-enabled
#   的退出码约定、staged 部署字段名 —— 均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-rollback.sh disable=SC1091
. "$HERE/dbk-rollback.sh"
# shellcheck source=scripts/linux/dbk-driver.sh disable=SC1091
. "$HERE/dbk-driver.sh"
# shellcheck source=scripts/linux/dbk-update.sh disable=SC1091
. "$HERE/dbk-update.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-health"

SC_STR="${DBK_SYSTEMCTL:-systemctl}"; DF_STR="${DBK_DF:-df}"
JRNL_DIR="${DBK_JOURNAL_DIR:-/var/log/journal}"
SC=(); DF=()
read -r -a SC <<<"$SC_STR"; read -r -a DF <<<"$DF_STR"
# 包装函数一律「名字不与外部命令同名 + 体内 command」双保险:函数查找优先于 PATH,同名会无限递归(见 dbk-cli.sh 头部约定)。
sc() { command "${SC[@]}" "$@"; }
dfc() { command "${DF[@]}" "$@"; }

ISSUES=(); MANUAL=(); PROBE_OUT=""
# 统一探针:stdout+stderr 收进 PROBE_OUT(不吞输出);命令失败不影响调用方继续判定。
probe() { local out; if out="$("$@" 2>&1)"; then :; fi; PROBE_OUT="$out"; return 0; }

# 硬判据 ①:会话类型
check_session() {
  case "${DBK_SESSION_TYPE:-${XDG_SESSION_TYPE:-}}" in
    wayland) dbk_add_check "①会话类型:XDG_SESSION_TYPE=wayland" ;;
    "") MANUAL+=("①取不到 XDG_SESSION_TYPE(不在图形会话里?用 loginctl show-session 复核)") ;;
    *) ISSUES+=("①XDG_SESSION_TYPE=${DBK_SESSION_TYPE:-$XDG_SESSION_TYPE}:要求 wayland") ;;
  esac
}
# 硬判据 ②:部署数 ≥2 或存在 pinned 部署(布置级回滚路径可用;经 dbk-rollback.sh 的 deployments_list)
check_deployments() {
  local list rc n pin desc
  rc=0
  if list="$(deployments_list)"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    MANUAL+=("②部署列表取不到(原因见上面 dbk-rollback 的报错):无法判定部署级回滚是否可用")
    return 0
  fi
  n="$(printf '%s\n' "$list" | grep -c . || true)"; pin=0
  case "$list" in *"[pinned]"*) pin=1 ;; esac
  desc="部署数=${n:-0}"
  if [ "$pin" -eq 1 ]; then desc="$desc(含 pinned 部署)"; fi
  if [ "${n:-0}" -ge 2 ] || [ "$pin" -eq 1 ]; then
    dbk_add_check "②部署级回滚可用:$desc"
  else
    ISSUES+=("②只有一个部署且没有 pinned 部署:部署级回滚不可用(按 05-9 先固定当前部署再改系统)")
  fi
}
# 硬判据 ③:自动更新定时器已启用(只检查/下载)
check_timer() {
  local st
  if ! command -v "${SC[0]}" >/dev/null 2>&1; then MANUAL+=("③未找到 ${SC[0]},无法读自动更新定时器状态"); return 0; fi
  probe sc is-enabled "$UPDATE_TIMER"
  st="$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')"
  case "$st" in
    enabled) dbk_add_check "③自动更新定时器已启用:$UPDATE_TIMER(只检查/下载)" ;;
    "") MANUAL+=("③$UPDATE_TIMER is-enabled 无输出;请人工确认定时器状态") ;;
    disabled|masked) ISSUES+=("③$UPDATE_TIMER 未启用(状态 $st):更新不会自动检查/下载(按 05-7 启用)") ;;
    *) MANUAL+=("③$UPDATE_TIMER is-enabled 输出无法识别($st);请人工确认") ;;
  esac
}
# 硬判据 ④:systemctl is-system-running
check_system_state() {
  local st
  if ! command -v "${SC[0]}" >/dev/null 2>&1; then MANUAL+=("④未找到 ${SC[0]},无法读系统状态"); return 0; fi
  probe sc is-system-running
  st="$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')"
  case "$st" in
    running) dbk_add_check "④systemctl is-system-running=running" ;;
    degraded) ISSUES+=("④systemctl is-system-running=degraded:有单元失败(systemctl --failed 逐条看)") ;;
    "") MANUAL+=("④systemctl is-system-running 无输出;请人工执行看系统状态") ;;
    *) MANUAL+=("④systemctl is-system-running=$st(启动中/维护中等过渡态,请稍后重跑)") ;;
  esac
}
# 硬判据 ⑤:根分区余量
check_root_free() {
  local pct
  if ! command -v "${DF[0]}" >/dev/null 2>&1; then MANUAL+=("⑤未找到 ${DF[0]},无法读根分区余量"); return 0; fi
  probe dfc -P /
  pct="$(printf '%s\n' "$PROBE_OUT" | awk 'NR>1 {gsub(/%/,"",$5); print $5; exit}')"
  case "$pct" in
    ""|*[!0-9]*) MANUAL+=("⑤取不到根分区余量(df -P / 输出异常)"); return 0 ;;
  esac
  if [ "$pct" -ge 10 ]; then dbk_add_check "⑤根分区余量 ${pct}%(≥10%)"
  else ISSUES+=("⑤根分区余量仅 ${pct}%(<10%):按 05-6 核对 zram/swapfile 并清理"); fi
}
# 记录项:Secure Boot 密钥注册、模块加载来源、待更新、journald 持久化(取不到只记需人工)
check_record() {
  local rc mod mrc prc
  rc=0
  if mok_check; then rc=0; else rc=$?; fi
  case "$rc" in
    0) dbk_add_check "显卡:Secure Boot 密钥已注册(经 dbk-driver.sh 的 mok_check)" ;;
    1) MANUAL+=("显卡:Secure Boot 密钥未注册(重启进 MOK 界面注册一次;Secure Boot 状态细查见 check-signature.sh)") ;;
    *) MANUAL+=("显卡:读不到已注册的 Secure Boot 密钥(需人工;原因见上面 dbk-driver 的报错)") ;;
  esac
  mod=""; mrc=0
  if mod="$(driver_module_state)"; then mrc=0; else mrc=$?; fi
  case "$mrc" in
    0) dbk_add_check "显卡模块来源:$mod" ;;
    1) MANUAL+=("显卡模块来源:${mod:-读不到} (nvidia 未加载:开源驱动兜底或未安装;按 05-3 核对)") ;;
    *) MANUAL+=("显卡模块来源:读不到模块加载状态(需人工;原因见上面 dbk-driver 的报错)") ;;
  esac
  prc=0
  if rollback_needs_reboot; then prc=0; else prc=$?; fi
  case "$prc" in
    0) MANUAL+=("待更新:有已下载并排入下次启动的改动(staged);重启后才生效,重启前可在开机菜单直接选旧部署") ;;
    1) dbk_add_check "待更新:没有 staged 部署(已下载待应用的更新为空)" ;;
    *) MANUAL+=("待更新:读不到部署状态,无法判断是否有待重启的改动(需人工)") ;;
  esac
  if [ -d "$JRNL_DIR" ]; then dbk_add_check "journald 持久化:存在 $JRNL_DIR"; else MANUAL+=("journald 未持久化:$JRNL_DIR 不存在(见 05-7)"); fi
}

check_all() {
  ISSUES=(); MANUAL=()
  check_session; check_deployments; check_timer; check_system_state; check_root_free; check_record
  return 0
}

check_all
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本无写动作(只读巡检);--apply 与 --check 输出相同。"; fi
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "周期巡检发现 ${#ISSUES[@]} 项硬判据不满足;逐条见 checks(处置卡号见各条说明)"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "周期巡检有 ${#MANUAL[@]} 项需要人工确认(不属于失败,但必须人工核对);逐条见 checks"
fi
dbk_exit PASS "周期巡检通过:会话 wayland、部署级回滚可用、更新定时器已启用、系统 running、根分区余量充足(其余为记录项,见 checks)"
