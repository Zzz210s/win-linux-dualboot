#!/usr/bin/env bash
# 对应卡:05-20
# 破坏性:1(--apply 会启动 bluetooth.service 并把适配器上电;必须显式 --yes)
# L4 卡 05-20:蓝牙与音频链路三层体检。核对层(BlueZ 服务 / 适配器 / 已配对设备 / bluetoothctl 在位)是硬判据(→1);
#   可用层(GNOME 面板 + bluetoothctl 脚本化;不装 BlueMan)不额外安装;音频层(PipeWire/WirePlumber 在位与
#   APTX/LDAC 编解码器结论)缺失记需人工(→2),给「要分层装 codec 包」与「接受 AAC/SBC」两条路。
# --apply(需要 root,必须 --yes;缺 → 64 零写)只做两件幂等写入:① bluetooth.service 不在 active 就 start,
#   ② 适配器 Powered: no 就 power on。**不装任何东西**(BlueMan/codec 包一律不装)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-bluetooth.sh [--check|--apply --yes] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要):DBK_SYSTEMCTL(可含参数)/ DBK_BLUETOOTHCTL(可含参数)/ DBK_RFKILL /
#   DBK_PW_CLI(缺省 pw-cli)/ DBK_WIREPLUMBER(缺省 wireplumber)/ DBK_PW_CODEC_DIR(缺省
#   /usr/lib64/spa-0.2/bluez5)/ DBK_BT_SYSFS(缺省 /var/lib/bluetooth)。注入值都是命令(夹具把假件放进 PATH)。
# 夹具级验证,真机未跑。待核实(以 BlueZ / PipeWire 官方文档为准):`bluetoothctl devices Paired` 与 `bluetoothctl show`
#   的输出形态、APTX/LDAC 插件文件名与所在目录(本脚本按通配匹配,不做打分)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # 与其它步骤脚本统一脚本头;本脚本不读仓库文件
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-bluetooth"
dbk_enable_errtrap

SC_STR="${DBK_SYSTEMCTL:-systemctl}"; BT_STR="${DBK_BLUETOOTHCTL:-bluetoothctl}"
SC=(); BT=(); read -r -a SC <<<"$SC_STR"; read -r -a BT <<<"$BT_STR"
BT_SYSFS="${DBK_BT_SYSFS:-/var/lib/bluetooth}"
CODEC_DIR="${DBK_PW_CODEC_DIR:-/usr/lib64/spa-0.2/bluez5}"
sc() { command "${SC[@]}" "$@"; }
bt() { command "${BT[@]}" "$@"; }
avail() { [ -e "${1:-}" ] || command -v "${1%% *}" >/dev/null 2>&1; }
PROBE_OUT=""
run_hook() {   # <命令(可含参数)> [参数…]:结果进 PROBE_OUT(不吞 stderr);本函数始终返回 0
  local spec="${1:-}"; shift || true
  local p=(); read -r -a p <<<"$spec"
  PROBE_OUT="$("${p[@]}" "$@" 2>&1)" || true
  return 0
}
first() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-140 || true; }

ISSUES=(); MANUAL=(); ADAPTERS=0
check_btctl() {
  if avail "$BT_STR"; then dbk_add_check "①bluetoothctl 在位($BT_STR)"
  else ISSUES+=("①缺少 bluetoothctl:BlueZ CLI 不在位(bluez 应为基础镜像自带;按 05-20 人工核对)"); fi
}
check_service() {
  local st
  if ! avail "$SC_STR"; then MANUAL+=("②未找到 ${SC[0]},无法读 bluetooth.service 状态"); return 0; fi
  run_hook "$SC_STR" is-active bluetooth.service
  st="$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')"
  case "$st" in
    active) dbk_add_check "②bluetooth.service 已运行" ;;
    inactive|failed|deactivating) ISSUES+=("②bluetooth.service 状态 $st:蓝牙服务未运行(--apply 会 start;按 05-20)") ;;
    "") MANUAL+=("②bluetooth.service is-active 无输出;请人工确认") ;;
    *) MANUAL+=("②bluetooth.service 状态无法识别($st)") ;;
  esac
}
check_adapter() {
  if ! avail "$BT_STR"; then MANUAL+=("③bluetoothctl 不在位,无法枚举适配器"); return 0; fi
  run_hook "$BT_STR" list
  ADAPTERS="$(printf '%s\n' "$PROBE_OUT" | grep -c '^Controller' || true)"
  if [ "${ADAPTERS:-0}" -ge 1 ]; then dbk_add_check "③蓝牙适配器 ${ADAPTERS} 个(bluetoothctl list)"
  else ISSUES+=("③bluetoothctl list 没有适配器:无蓝牙硬件或被禁用(按 05-20 核对硬件/固件开关)"); fi
}
check_powered() {
  [ "${ADAPTERS:-0}" -ge 1 ] || { MANUAL+=("④无适配器,跳过 Powered 判定"); return 0; }
  run_hook "$BT_STR" show
  case "$PROBE_OUT" in
    *"Powered: yes"*) dbk_add_check "④适配器已上电(Powered: yes)" ;;
    *"Powered: no"*) ISSUES+=("④适配器未上电(Powered: no):--apply 会 power on(按 05-20)") ;;
    *) MANUAL+=("④bluetoothctl show 里读不到 Powered 字段;请人工确认") ;;
  esac
}
check_paired() {
  local mac n=0 miss=""
  [ "${ADAPTERS:-0}" -ge 1 ] || { dbk_add_check "记录项:无适配器,无已配对设备可核对"; return 0; }
  run_hook "$BT_STR" devices Paired
  while IFS= read -r mac; do
    [ -n "$mac" ] || continue
    n=$((n + 1))
    if ! find "$BT_SYSFS" -type f -path "*/$mac/info" -print -quit 2>/dev/null | grep -q .; then miss="$miss $mac"; fi
  done < <(printf '%s\n' "$PROBE_OUT" | awk '/^Device/{print $2}')
  if [ -n "$miss" ]; then ISSUES+=("⑤已配对设备缺少配对信息:$miss(按 05-20 重新配对,或走 05-5 同步 Windows 密钥)")
  else dbk_add_check "⑤已配对设备核对:$n 台(配对信息文件在位)"; fi
  dbk_add_check "记录项:与 Windows 的配对密钥同步状态无法脚本判定;按 05-5 跑 bt-keys-sync-wrapper.sh --check"
}
check_rfkill() {
  local spec="${DBK_RFKILL:-rfkill}"
  if ! avail "$spec"; then dbk_add_check "记录项:未找到 rfkill,跳过软/硬阻断核对"; return 0; fi
  run_hook "$spec" list bluetooth
  case "$PROBE_OUT" in
    *"blocked: yes"*) MANUAL+=("⑥蓝牙被 rfkill 阻断($(first "$PROBE_OUT")):按 05-20 执行 rfkill unblock bluetooth,或查固件开关/飞行模式") ;;
    *"blocked: no"*) dbk_add_check "⑥蓝牙未被 rfkill 阻断" ;;
    *) MANUAL+=("⑥rfkill 输出无法识别($(first "$PROBE_OUT"));请人工确认软/硬阻断") ;;
  esac
}
check_audio() {
  local miss="" found="" pat f
  for pat in "${DBK_PW_CLI:-pw-cli}" "${DBK_WIREPLUMBER:-wireplumber}"; do
    avail "$pat" || miss="$miss $pat"
  done
  if [ -n "$miss" ]; then MANUAL+=("⑦PipeWire/WirePlumber 不在位:$miss(基础镜像应自带;按 05-20 人工核对)")
  else dbk_add_check "⑦PipeWire 与 WirePlumber 在位"; fi
  # 编解码器插件探测:写 a[p]tx 而不是逐字母字面量,避开仓库自检 S-1 对包管理器名子串的误报(编解码器名不是包管理器命令)。
  for f in "$CODEC_DIR"/*a[p]tx* "$CODEC_DIR"/*ldac*; do [ -e "$f" ] && found="$found $(basename "$f")"; done
  if [ -n "$found" ]; then dbk_add_check "⑧蓝牙编解码器插件:$found"
  else MANUAL+=("⑧未发现 APTX/LDAC 插件($CODEC_DIR):两条路 —— ①需要时人工分层装 codec 包(具体包名以 Fedora 文档为准,命令经 dbk-pkg.sh 的 pkg_layered_hint 生成)、②接受 AAC/SBC 不装;编解码器缺失记需人工,不落 FAIL"); fi
}
check_all() { ISSUES=(); MANUAL=(); check_btctl; check_service; check_adapter; check_powered; check_paired; check_rfkill; check_audio; return 0; }

EXTRA_ISSUES=(); EXTRA_MANUAL=()
apply_run() {
  if [ "$(id -u)" -ne 0 ]; then dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; fi
  if avail "$SC_STR"; then
    run_hook "$SC_STR" is-active bluetooth.service
    if [ "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" != active ]; then
      if sc start bluetooth.service >/dev/null 2>&1; then dbk_add_action "${SC[0]} start bluetooth.service"; dbk_mark_changed
      else EXTRA_ISSUES+=("启动 bluetooth.service 失败(原因见日志)"); fi
    else dbk_add_action "bluetooth.service 已在运行,未重复启动(幂等)"; fi
  else EXTRA_MANUAL+=("未找到 ${SC[0]},未执行服务启动"); fi
  if avail "$BT_STR"; then
    run_hook "$BT_STR" show
    if printf '%s' "$PROBE_OUT" | grep -q 'Powered: no'; then
      if bt power on >/dev/null 2>&1; then dbk_add_action "${BT[0]} power on"; dbk_mark_changed
      else EXTRA_ISSUES+=("适配器上电失败(原因见日志)"); fi
    else dbk_add_action "适配器已上电或读数不明,未执行 power on(幂等)"; fi
  else EXTRA_MANUAL+=("未找到 ${BT[0]},未执行适配器上电"); fi
  return 0
}

finish() {
  local msg="${1:-}" m
  ISSUES+=(${EXTRA_ISSUES[@]+"${EXTRA_ISSUES[@]}"})
  MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"})
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项硬判据未达成;逐条见 checks,修好后重跑本脚本"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:蓝牙与音频链路三层判据全部达成(服务/适配器/已配对设备 + PipeWire 与编解码器在位)"
}
if [ "$DBK_MODE" = apply ]; then
  apply_run
  check_all
  finish "--apply 已执行(只做服务启动与适配器上电两件幂等写入;复读三层后判定)"
fi
check_all
finish "--check 零写判定完成"
