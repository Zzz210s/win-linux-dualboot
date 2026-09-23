#!/usr/bin/env bash
# 对应卡:05-7
# L4:更新策略收紧(Kubuntu / apt 语义;设计依据:docs/design/04-kubuntu-variant-design.md 第 2 节 D2"LTS 期间只收
#   安全更新"与第 7 节 R8"保守更新策略";原原子版的 rpm-ostreed-automatic 语义已废弃)。
# 用途:--check 只读判定四项;--apply 安装 unattended-upgrades、生成配置片段并启用服务。
# 判据(--check,零写):① 包 unattended-upgrades 已装(dpkg-query);
#   ② 片段存在且含 `Automatic-Reboot "false"`(**不自动重启**);
#   ③ 片段里 Allowed-Origins 只列 `-security`(只装安全更新,不含 updates/backports/proposed/esm);
#   ④ `systemctl is-enabled unattended-upgrades` = enabled(取不到 → 需人工)。
# 片段内容**内嵌在脚本里生成**(不落 templates/;批次 K2 再决定是否抽出模板)。片段路径可注入,便于离线夹具。
# 关键纪律:任何配置里出现 `Automatic-Reboot "true"` → FAIL 且 --apply **不写任何文件**(与"不自动重启"直接冲突)。
# 人工边界:本步不声明破坏性(只写 /etc/apt/apt.conf.d 下一个片段并启用服务,可逆:删片段 + disable 即回到原状)。
# 回滚:还原 <片段>.dbk.bak(或删掉片段)后 `sudo systemctl disable --now unattended-upgrades`。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: set-updates.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用):DBK_UNATTENDED_CONF / DBK_SYSTEMCTL / DBK_DPKG_QUERY / DBK_APT_GET / DBK_SKIP_PKG。
# 待核实(以官方文档为准):unattended-upgrades 单元名、Allowed-Origins 的重置语义与 Automatic-Reboot 的键名
#   均未在真机验证;若与官方文档不符,该项应按「需人工」呈现而不是当作 FAIL。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)
log() { dbk_obs "$*"; }
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-updates"

CONF="${DBK_UNATTENDED_CONF:-/etc/apt/apt.conf.d/52-dbk-unattended.conf}"   # 待核实(以官方文档为准)
UNIT="unattended-upgrades"                                                  # 待核实(以官方文档为准)
SC_STR="${DBK_SYSTEMCTL:-systemctl}"; DQ_STR="${DBK_DPKG_QUERY:-dpkg-query}"
SC=(); DQ=(); read -r -a SC <<<"$SC_STR"; read -r -a DQ <<<"$DQ_STR"
sc() { command "${SC[@]}" "$@"; }
dq() { command "${DQ[@]}" "$@"; }
ISSUES=(); MANUAL=(); APPLY_FAILS=(); PROBE_OUT=""; PROBE_RC=0
probe() { local out; if out="$("$@" 2>&1)"; then PROBE_RC=0; else PROBE_RC=$?; fi; PROBE_OUT="$out"; return 0; }

# 片段内容(唯一实现处):只装安全更新 + 不自动重启。
snippet_body() {
  cat <<EOF
// 由 dbk 脚本生成(卡 05-7):只装安全更新,不自动重启
// 依据:docs/design/04-kubuntu-variant-design.md 第 2 节 D2 与第 7 节 R8
Unattended-Upgrade::Allowed-Origins {
        "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

policy_line() { [ -r "$1" ] && grep -m1 -E '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot' "$1" || true; }

# 纪律闸门:片段或目标里出现 Automatic-Reboot "true" → FAIL 且立刻收口(--apply 时不写任何文件)。
assert_no_autoreboot() {
  local f found=""
  for f in "$CONF"; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"?true' "$f"; then found="$f"; break; fi
  done
  [ -n "$found" ] || return 0
  dbk_add_check "失败项: $found 含 Automatic-Reboot \"true\""
  dbk_exit FAIL "发现 Automatic-Reboot \"true\"($found):自动重启被设计明确禁止(R8);--apply 不会写入任何文件,请先手工改成 false 再重跑"
}

check_pkg() {
  if ! command -v "${DQ[0]}" >/dev/null 2>&1; then MANUAL+=("①未找到 ${DQ[0]}:无法核对 unattended-upgrades 是否已装"); return 0; fi
  probe dq -W -f='${Status}' unattended-upgrades
  case "$PROBE_OUT" in
    *"install ok installed"*) dbk_add_check "①unattended-upgrades 已安装" ;;
    *) ISSUES+=("①unattended-upgrades 未安装(--apply 会 apt-get install -y unattended-upgrades)") ;;
  esac
}
check_conf() {
  local line
  if [ ! -f "$CONF" ]; then ISSUES+=("②配置片段不存在:$CONF(--apply 会生成)"); return 0; fi
  line="$(policy_line "$CONF")"
  case "$line" in
    *'"false"'*) dbk_add_check "②不自动重启: $line" ;;
    "") ISSUES+=("②配置片段缺少 Automatic-Reboot 行:$CONF") ;;
    *) ISSUES+=("②Automatic-Reboot 不是 false(回读:'$line')") ;;
  esac
  if ! grep -qE '^[[:space:]]*Unattended-Upgrade::Allowed-Origins' "$CONF"; then
    ISSUES+=("③配置片段缺少 Allowed-Origins(无法确认只装安全更新)")
    return 0
  fi
  if grep -qE '\-(updates|backports|proposed|esm|apps-security)' "$CONF"; then
    ISSUES+=("③Allowed-Origins 里含 security 之外的口子(updates/backports/proposed/esm);只允许 -security")
  else
    dbk_add_check "③只装安全更新:Allowed-Origins 只列 -security"
  fi
}
check_unit() {
  if ! command -v "${SC[0]}" >/dev/null 2>&1; then MANUAL+=("④未找到 ${SC[0]}:请人工确认 $UNIT 是否 enabled"); return 0; fi
  probe sc is-enabled "$UNIT"
  if [ "$PROBE_OUT" = enabled ]; then dbk_add_check "④$UNIT 已 enabled"
  elif [ "$PROBE_RC" -eq 127 ] || [ -z "$PROBE_OUT" ]; then
    MANUAL+=("④取不到 $UNIT 的 is-enabled 输出;请人工确认")
  else
    ISSUES+=("④$UNIT 未启用(is-enabled 输出 '$PROBE_OUT';--apply 会 systemctl enable --now $UNIT)")
  fi
}

check_all() { ISSUES=(); MANUAL=(); check_pkg; check_conf; check_unit; return 0; }

apply_conf() {
  local body dir
  body="$(snippet_body)"
  if [ -f "$CONF" ] && [ "$(cat "$CONF")" = "$body" ]; then dbk_add_check "配置已是目标内容,未改动:$CONF"; return 0; fi
  dir="$(dirname "$CONF")"
  mkdir -p "$dir" || { APPLY_FAILS+=("目录创建失败:$dir"); return 0; }
  if [ -f "$CONF" ] && [ ! -e "$CONF.dbk.bak" ]; then
    if cp -a "$CONF" "$CONF.dbk.bak"; then dbk_add_action "备份 $CONF -> $CONF.dbk.bak"
    else APPLY_FAILS+=("备份失败:$CONF -> $CONF.dbk.bak"); return 0; fi
  fi
  if printf '%s\n' "$body" >"$CONF"; then dbk_add_action "生成配置片段:$CONF"; dbk_mark_changed
  else APPLY_FAILS+=("写入失败:$CONF"); fi
  return 0
}

apply_pkg() {
  local st=0
  pkg_ensure unattended-upgrades "sudo apt-get install -y unattended-upgrades" >&2 || st=$?
  case "$st" in
    0) dbk_add_action "确保 unattended-upgrades 已安装"; dbk_mark_changed ;;
    9) dbk_add_check "跳过: DBK_SKIP_PKG=1,未执行 apt-get install unattended-upgrades(判据按现状判定)" ;;
    *) APPLY_FAILS+=("安装 unattended-upgrades 失败(返回码 $st);按上面库层给出的硬前置命令处理后重跑") ;;
  esac
  return 0
}

apply_unit() {
  probe sc enable --now "$UNIT"
  if [ "$PROBE_RC" -eq 0 ]; then dbk_add_action "systemctl enable --now $UNIT"; dbk_mark_changed
  else APPLY_FAILS+=("systemctl enable --now $UNIT 失败: $(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"); fi
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${APPLY_FAILS[@]+"${APPLY_FAILS[@]}"}; do ISSUES+=("$m"); done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:四项判据全部达成(包已装 / 只装安全更新 / 不自动重启 / 服务 enabled)"
}

assert_no_autoreboot
if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  apply_pkg
  apply_conf
  apply_unit
  assert_no_autoreboot
  check_all
  finish "更新策略已执行(--apply;复读判据后判定)"
fi

check_all
finish "更新策略判据核对完成(--check 零写)"
