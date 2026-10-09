#!/usr/bin/env bash
# 对应卡:07-7
# 卡 07-7「周期巡检」的安全与固件部分(只读,破坏性 0):firewalld / fwupd / lynis 三处结论。
# 判据:① `firewall-cmd --state` = running(not running → 1 FAIL;命令缺失 → 2 需人工);默认区只作记录项;
#   ② fwupd:只读跑 `fwupdmgr get-updates` —— 无可用更新 = PASS,有可用固件更新 = **需人工**(脚本不装固件、
#   不改配置),读不到(权限/网络)= 需人工;③ lynis:在装则只读跑 `lynis audit system --quick` 并记录摘要
#   (**只报告,不打分、不改配置**),未装只记记录项。本脚本不做任何写动作,--apply 与 --check 输出完全相同。
# 不接 --yes(--破坏性 0):给了 → 64。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-security.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要):DBK_FIREWALL_CMD / DBK_FWUPDMGR / DBK_LYNIS。注入值都是命令(夹具把假件放进 PATH)。
# 夹具级验证,真机未跑。待核实(以 firewalld / fwupd / lynis 官方文档为准):fwupdmgr get-updates 的
#   无更新文案、lynis audit system --quick 的摘要行形态与它自身写 /var/log/lynis*.log 的行为。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # 与其它步骤脚本统一脚本头;本脚本不读仓库文件
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) dbk_usage; dbk_note "用法错误: check-security.sh 是只读脚本(# 破坏性:0),不接受 --yes"; exit "$DBK_USAGE" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "check-security"
dbk_enable_errtrap

FW="${DBK_FIREWALL_CMD:-firewall-cmd}"; FWUPD="${DBK_FWUPDMGR:-fwupdmgr}"; LYNIS="${DBK_LYNIS:-lynis}"
avail() { [ -e "${1:-}" ] || command -v "${1%% *}" >/dev/null 2>&1; }
PROBE_OUT=""; PROBE_RC=0
run_hook() {   # <命令(可含参数)> [参数…]:结果进 PROBE_OUT/PROBE_RC(不吞 stderr);本函数始终返回 0
  local spec="${1:-}"; shift || true
  local p=(); read -r -a p <<<"$spec"
  PROBE_OUT="$("${p[@]}" "$@" 2>&1)" || PROBE_RC=$?
  return 0
}
first() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-140 || true; }

ISSUES=(); MANUAL=()
check_firewalld() {
  local st
  if ! avail "$FW"; then MANUAL+=("①未找到 ${FW%% *},无法读 firewalld 状态(按 07-7 核对防火墙是否该装) "); return 0; fi
  run_hook "$FW" --state
  st="$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')"
  case "$st" in
    running) dbk_add_check "①firewalld 正在运行(firewall-cmd --state)" ;;
    notrunning) ISSUES+=("①firewalld 未运行:防火墙没在工作(按 07-7 启用;Docker/容器场景注意 DOCKER-USER 链)") ;;
    *) MANUAL+=("①firewall-cmd --state 输出无法识别($(first "$PROBE_OUT"));请人工确认") ;;
  esac
  run_hook "$FW" --get-default-zone
  if [ -n "$(first "$PROBE_OUT")" ]; then dbk_add_check "记录项: firewalld 默认区 = $(first "$PROBE_OUT")"; fi
}
check_fwupd() {
  if ! avail "$FWUPD"; then MANUAL+=("②未找到 ${FWUPD%% *},无法核对固件更新(按 07-7 核对 fwupd 是否该装)"); return 0; fi
  run_hook "$FWUPD" get-updates
  if [ "$PROBE_RC" -ne 0 ]; then MANUAL+=("②fwupdmgr get-updates 读不到(退出码 $PROBE_RC:$(first "$PROBE_OUT")):可能是权限/网络;只报告,不装固件"); return 0; fi
  if printf '%s' "$PROBE_OUT" | grep -qiE 'no (updates|available)'; then
    dbk_add_check "②固件无可用更新($(first "$PROBE_OUT"))"
  elif printf '%s' "$PROBE_OUT" | grep -qiE 'updates? available'; then
    MANUAL+=("②有可用固件更新:脚本不装固件、不改配置;人工核对后按 07-7 决定($(first "$PROBE_OUT"))")
  else
    MANUAL+=("②fwupdmgr get-updates 输出无法识别($(first "$PROBE_OUT"));请人工确认固件状态")
  fi
}
check_lynis() {
  local out sum
  if ! avail "$LYNIS"; then dbk_add_check "记录项: 未安装 lynis,跳过安全体检(可选;按 07-7 经 brew 通道装)"; return 0; fi
  run_hook "$LYNIS" audit system --quick --no-colors
  sum="$(printf '%s\n' "$PROBE_OUT" | grep -iE 'hardening index|suggestion|warning' | tail -n 2 | tr '\n' ';' | cut -c1-180)"
  out="${sum:-$(printf '%s\n' "$PROBE_OUT" | grep -v '^[[:space:]]*$' | tail -n1)}"
  dbk_add_check "记录项: lynis audit system --quick 摘要:$out(只报告,不打分、不改配置)"
  if [ "$PROBE_RC" -ne 0 ]; then MANUAL+=("③lynis audit 退出码 $PROBE_RC:请人工复核(只报告,不影响本脚本判定)"); fi
}

check_all() { ISSUES=(); MANUAL=(); check_firewalld; check_fwupd; check_lynis; return 0; }
check_all
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本只读(破坏性 0);--apply 与 --check 输出相同,不改任何配置。"; fi
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "安全与固件体检发现 ${#ISSUES[@]} 项硬判据不满足;逐条见 checks"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "安全与固件体检有 ${#MANUAL[@]} 项需要人工确认(不属于失败);逐条见 checks"
fi
dbk_exit PASS "安全与固件体检通过:firewalld 运行中、固件无可用更新、lynis 只报告(其余为记录项,见 checks)"
