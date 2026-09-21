#!/usr/bin/env bash
# 对应卡:05-7
# L4:更新策略收紧(设计 3.18 与 4 节 R8「保守更新策略」)——`rpm-ostreed-automatic` 只做
#   check/download,**不自动应用、不自动重启**:应用=产生新部署,仍需一次重启才生效。
# 用途:--check 只读判定下面三项判据;--apply 安装 templates/rpm-ostreed.snippet 到目标配置并启用定时器。
# 判据(--check,零写):① 目标文件含 `AutomaticUpdatePolicy=check|download`;
#   ② `systemctl is-enabled rpm-ostreed-automatic.timer` 输出为 enabled;③ 回读配置行并打印。
#   取不到 systemctl → 该项需人工(2)。未在真机验证的单元名/段名见下面的 `# 待核实` 注:若与官方文档不符,
#   本项判据应按「需人工」呈现而不是当作 FAIL。
# 关键纪律(设计 3.18 / 4 节):模板与目标里**一律不得**出现 `AutomaticUpdatePolicy=stage`
#   (stage = 自动应用 + 自动重启);一旦发现 → FAIL 且 --apply **不写任何文件**。
# 人工边界:本步不声明破坏性(不写 `# 破坏性:1`):只写 /etc 下一个配置文件并启用定时器,可逆。
# 回滚:还原 /etc/rpm-ostreed.conf.dbk.bak(或删掉本文件)后重启 rpm-ostreed。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: set-updates.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
# 夹具注入(真机不需要设置):DBK_RPM_OSTREED_CONF / DBK_RPM_OSTREED_TPL / DBK_SYSTEMCTL。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-updates"

CONF="${DBK_RPM_OSTREED_CONF:-/etc/rpm-ostreed.conf}"                  # 待核实(以官方文档为准)
TPL="${DBK_RPM_OSTREED_TPL:-$ROOT/templates/rpm-ostreed.snippet}"
TIMER="rpm-ostreed-automatic.timer"                                    # 待核实(以官方文档为准)
SC_STR="${DBK_SYSTEMCTL:-systemctl}"
SC=()
read -r -a SC <<<"$SC_STR"
sc() { "${SC[@]}" "$@"; }
ISSUES=(); MANUAL=(); APPLY_FAILS=()
PROBE_RC=0

# 统一探针:把命令的 stdout+stderr 收进调用方变量(不吞输出),返回命令自身退出码;
# PROBE_RC 留给调用方分辨 127(命令不存在 → 该项需人工)与真正的执行失败(→ FAIL)。
probe() {
  local __var="$1" __out
  shift
  if __out="$("$@" 2>&1)"; then
    PROBE_RC=0
    printf -v "$__var" '%s' "$__out"
    return 0
  else
    PROBE_RC=$?
    printf -v "$__var" '%s' "$__out"
    return 1
  fi
}

# 回读策略行;文件不存在时 grep 的报错留在 stderr(不吞),返回值由调用方先判存在性。
policy_line() {
  [ -n "${1:-}" ] || return 0
  grep -m1 -E '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=' "$1" || true
}

# 纪律闸门:模板或目标里出现 stage → FAIL 并立刻收口(此时还没做任何写动作)。
assert_no_stage() {
  local f found=""
  for f in "$TPL" "$CONF"; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=[[:space:]]*stage' "$f"; then found="$f"; break; fi
  done
  [ -n "$found" ] || return 0
  dbk_add_check "失败项: $found 含 AutomaticUpdatePolicy=stage"
  dbk_exit FAIL "发现 AutomaticUpdatePolicy=stage($found):自动应用与自动重启被设计明确禁止(设计 3.18 / 4 节);--apply 不会写入任何文件,请先手工把它改成 check 或 download 再重跑"
}

check_tpl() {
  if [ ! -r "$TPL" ]; then ISSUES+=("模板不存在或不可读:$TPL"); return 0; fi
  if grep -qE '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=[[:space:]]*(check|download)' "$TPL"; then
    dbk_add_check "模板策略行: $(policy_line "$TPL")"
  else
    ISSUES+=("模板缺少 AutomaticUpdatePolicy=check|download(实为 '$(policy_line "$TPL")')")
  fi
  return 0
}

check_conf() {
  local line
  if [ ! -f "$CONF" ]; then ISSUES+=("目标配置不存在:$CONF"); return 0; fi
  line="$(policy_line "$CONF")"
  if [ -z "$line" ]; then
    ISSUES+=("目标配置缺少 AutomaticUpdatePolicy 行:$CONF")
  elif grep -qE '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=[[:space:]]*(check|download)' "$CONF"; then
    dbk_add_check "回读配置行: $line"
  else
    ISSUES+=("目标配置的策略行不是 check|download(回读:'$line')")
  fi
  return 0
}

check_timer() {
  local out
  if probe out sc is-enabled "$TIMER" && [ "$out" = enabled ]; then
    dbk_add_check "$TIMER 已 enabled"
    return 0
  fi
  if [ "$PROBE_RC" -eq 127 ] || [ -z "$out" ]; then
    MANUAL+=("取不到 systemctl($SC_STR): $(printf '%s' "$out" | tr '\n' ' ');请人工确认 $TIMER 是否 enabled")
  else
    ISSUES+=("$TIMER 未启用(is-enabled 输出 '$out')")
  fi
  return 0
}

check_all() {
  ISSUES=(); MANUAL=()
  check_tpl
  check_conf
  check_timer
  return 0
}

# 安装片段(与 journald 同一套备份策略:存在且不同才备份,备份只在不存在时创建)。
# 只在 --apply 分支被调用,--check 路径零写。
apply_conf() {
  local dir
  dir="$(dirname "$CONF")"
  if [ -f "$CONF" ] && cmp -s "$TPL" "$CONF"; then
    dbk_add_check "配置已是模板内容,未改动:$CONF"
    return 0
  fi
  if [ -f "$CONF" ] && [ ! -e "$CONF.dbk.bak" ]; then
    if cp -a "$CONF" "$CONF.dbk.bak"; then
      dbk_add_action "备份 $CONF -> $CONF.dbk.bak"
    else
      APPLY_FAILS+=("备份失败:$CONF -> $CONF.dbk.bak")
      return 0
    fi
  fi
  if ! mkdir -p "$dir"; then
    APPLY_FAILS+=("目录创建失败:$dir")
    return 0
  fi
  if cp -a "$TPL" "$CONF"; then
    dbk_add_action "安装 $TPL -> $CONF"
    dbk_add_check "配置已安装:$CONF"
    dbk_mark_changed
  else
    APPLY_FAILS+=("安装失败:$TPL -> $CONF")
  fi
  return 0
}

apply_timer() {
  local out
  if probe out sc enable --now "$TIMER"; then
    dbk_add_action "systemctl enable --now $TIMER"
    dbk_mark_changed
  else
    APPLY_FAILS+=("systemctl enable --now $TIMER 失败: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${APPLY_FAILS[@]+"${APPLY_FAILS[@]}"}; do ISSUES+=("$m"); done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:三项判据全部达成(策略为 check/download、定时器 enabled)"
}

assert_no_stage
if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  apply_conf
  apply_timer
  assert_no_stage
  check_all
  finish "更新策略已执行(--apply;复读判据后判定)"
fi

check_all
finish "更新策略判据核对完成(--check 零写)"
