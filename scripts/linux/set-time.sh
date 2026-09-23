#!/usr/bin/env bash
# 对应卡:05-4
# L4:时间收敛(设计 4.5 的「时间」行)——RTC 走 UTC(`RTC in local TZ: no`)+ NTP 已启用。
# 用途:--check 只读判定下面两项判据;--apply 把 RTC 基准改成 UTC(仅当当前是本地时间)并打开 NTP,再复读判据。
# 判据(--check,零写):① `timedatectl` 输出含 `RTC in local TZ: no`(RTC 走 UTC);
#   ② NTP 已启用(`System clock synchronized: yes` 或 `NTP service: active`)。
#   取不到 timedatectl 输出 → 需人工(2):脚本判不了,必须人看(硬规则 5:未在真机验证的读法按需人工呈现)。
# 为什么:RTC 与 Windows 共用同一块硬件时钟;Linux 若按本地时间写 RTC,Windows 侧时间会漂移(反之亦然),
#   统一 UTC 是双系统时间一致的前提(Windows 侧可配合 RealTimeIsUniversal=1,见 05-4 回滚段)。
# 人工边界:本步不声明破坏性(不写 `# 破坏性:1`):只改 RTC 基准与 NTP 开关,可逆,不动分区表、不动引导。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: set-time.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
# 夹具注入(真机不需要设置):DBK_TIMEDATECTL 覆盖 timedatectl 命令(允许写成"命令 + 参数",按空白切分)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-time"

TD_STR="${DBK_TIMEDATECTL:-timedatectl}"
TD=()
read -r -a TD <<<"$TD_STR"
td_run() { command "${TD[@]}" "$@"; }

RTC_LOCAL=""; SYNC=""; NTP=""; ISSUES=(); MANUAL=()

# 读一次 timedatectl:stdout 与 stderr 都收进变量(不吞输出);取不到 → 需人工(脚本判不了)。
read_td() {
  local out
  if ! out="$(td_run 2>&1)"; then
    dbk_add_check "timedatectl 读取失败($TD_STR): $(printf '%s' "$out" | tr '\n' ' ')"
    dbk_exit 需人工 "取不到 timedatectl 输出($TD_STR): $(printf '%s' "$out" | tr '\n' ' ');请人工执行 timedatectl 确认 RTC 基准与 NTP 状态"
  fi
  [ -n "$out" ] || { dbk_add_check "timedatectl 无输出"; dbk_exit 需人工 "timedatectl 无输出($TD_STR);请人工确认系统时间服务"; }
  RTC_LOCAL="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*RTC in local TZ:[[:space:]]*//p' | head -n1)"
  SYNC="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*System clock synchronized:[[:space:]]*//p' | head -n1)"
  NTP="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*NTP service:[[:space:]]*//p' | head -n1)"
  return 0
}

# 判据归一:通过的判据登记进 checks;失败项进 ISSUES;判不了的进 MANUAL。
verdict() {
  ISSUES=(); MANUAL=()
  case "$RTC_LOCAL" in
    no|NO|No) dbk_add_check "RTC 用 UTC(RTC in local TZ: no)" ;;
    yes|YES|Yes) ISSUES+=("RTC 用的是本地时间(RTC in local TZ: yes):与 Windows 共存会时间漂移") ;;
    *) MANUAL+=("读不到「RTC in local TZ」行(实为 '${RTC_LOCAL:-空}');请人工核对 timedatectl 输出格式") ;;
  esac
  if [ "$SYNC" = yes ] || [ "$NTP" = active ]; then
    dbk_add_check "NTP 已启用(System clock synchronized: ${SYNC:-未读到} / NTP service: ${NTP:-未读到})"
  else
    ISSUES+=("NTP 未启用(System clock synchronized: ${SYNC:-未读到} / NTP service: ${NTP:-未读到});系统时间会持续漂移")
  fi
  return 0
}

# 判据 → 退出码:有失败项 → FAIL;否则有判不了的 → 需人工;否则 PASS。
finish() {
  local msg="${1:-}" m
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks,修好后重跑本脚本"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:两项判据全部达成(RTC 走 UTC 且 NTP 已启用)"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  read_td; verdict
  if [ "$RTC_LOCAL" = yes ]; then
    if out="$(td_run set-local-rtc 0 2>&1)"; then
      dbk_add_action "timedatectl set-local-rtc 0(RTC 基准改 UTC)"
      dbk_mark_changed
    else
      dbk_add_check "失败项: timedatectl set-local-rtc 0 失败: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
    read_td
  fi
  if [ "$SYNC" != yes ] && [ "$NTP" != active ]; then
    if out="$(td_run set-ntp true 2>&1)"; then
      dbk_add_action "timedatectl set-ntp true(启用 NTP)"
      dbk_mark_changed
    else
      dbk_add_check "失败项: timedatectl set-ntp true 失败: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
    read_td
  fi
  verdict
  finish "时间收敛已执行(--apply;复读 timedatectl 后判定)"
fi

read_td
verdict
finish "时间判据核对完成(--check 零写)"
