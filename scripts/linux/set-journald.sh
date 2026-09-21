#!/usr/bin/env bash
# 对应卡:05-7
# L4:journald 持久化(设计 4.7 的 R5「崩溃可观测」)——日志落 /var/log/journal,崩溃或启动失败后
#   仍可用 `journalctl -b -1` 回看上一轮启动;/var 不属于部署,日志不随部署回滚丢失。
# 用途:--check 只读判定下面三项判据;--apply 安装配置片段并重启 systemd-journald,再复读判据。
# 判据(--check,零写):① 配置文件存在且含 `Storage=persistent`;
#   ② `journalctl --disk-usage` 可读且输出非空;③ `systemctl is-active systemd-journald` = active。
#   取不到 systemctl / journalctl(命令不存在或读不到)→ 该项需人工(2):脚本判不了。
# 人工边界:本步不声明破坏性(不写 `# 破坏性:1`):只写 /etc 下一个片段并重启 journald,可逆,不动分区/引导。
# 回滚:删除 $DBK_JOURNALD_CONF(或还原 <目标>.dbk.bak)后 `systemctl restart systemd-journald`。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: set-journald.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
# 夹具注入(真机不需要设置):DBK_JOURNALD_CONF(配置目标)/ DBK_JOURNALCTL / DBK_SYSTEMCTL。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-journald"

CONF="${DBK_JOURNALD_CONF:-/etc/systemd/journald.conf.d/99-dbk-persistent.conf}"
JC_STR="${DBK_JOURNALCTL:-journalctl}"
SC_STR="${DBK_SYSTEMCTL:-systemctl}"
JC=()
SC=()
read -r -a JC <<<"$JC_STR"
read -r -a SC <<<"$SC_STR"
jc() { "${JC[@]}" "$@"; }
sc() { "${SC[@]}" "$@"; }
CONTENT='[Journal]
Storage=persistent'
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

check_conf() {
  if [ ! -f "$CONF" ]; then ISSUES+=("配置文件不存在:$CONF"); return 0; fi
  if grep -qE '^[[:space:]]*Storage=persistent' "$CONF"; then
    dbk_add_check "配置含 Storage=persistent:$CONF"
  else
    ISSUES+=("配置文件缺少 Storage=persistent:$CONF")
  fi
  return 0
}

check_disk() {
  local out
  if probe out jc --disk-usage && [ -n "$out" ]; then
    dbk_add_check "journalctl --disk-usage: $(printf '%s' "$out" | tr '\n' ' ')"
    return 0
  fi
  if [ "$PROBE_RC" -eq 127 ] || [ -z "$out" ]; then
    MANUAL+=("取不到 journalctl --disk-usage($JC_STR): $(printf '%s' "$out" | tr '\n' ' ');请人工确认日志是否落盘 /var/log/journal")
  else
    ISSUES+=("journalctl --disk-usage 失败: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
  return 0
}

check_svc() {
  local out
  if probe out sc is-active systemd-journald && [ "$out" = active ]; then
    dbk_add_check "systemd-journald 处于 active"
    return 0
  fi
  if [ "$PROBE_RC" -eq 127 ] || [ -z "$out" ]; then
    MANUAL+=("取不到 systemctl($SC_STR): $(printf '%s' "$out" | tr '\n' ' ');请人工确认 systemd-journald 是否 active")
  else
    ISSUES+=("systemd-journald 不是 active(实为 '$out')")
  fi
  return 0
}

check_all() {
  ISSUES=(); MANUAL=()
  check_conf
  check_disk
  check_svc
  return 0
}

# 安装片段:已是目标内容则不动;存在但不同则先备份 <目标>.dbk.bak(只在备份不存在时创建)再覆盖。
# 本函数只在 --apply 分支被调用(mkdir/cp/重定向都在这里),--check 路径零写。
apply_conf() {
  local dir
  dir="$(dirname "$CONF")"
  if [ -f "$CONF" ] && printf '%s\n' "$CONTENT" | cmp -s - "$CONF"; then
    dbk_add_check "配置已是目标内容,未改动:$CONF"
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
  if printf '%s\n' "$CONTENT" >"$CONF"; then
    dbk_add_action "写入 $CONF([Journal] + Storage=persistent)"
    dbk_add_check "配置已写入:$CONF"
    dbk_mark_changed
  else
    APPLY_FAILS+=("配置写入失败:$CONF")
  fi
  return 0
}

apply_restart() {
  local out
  if probe out sc restart systemd-journald; then
    dbk_add_action "systemctl restart systemd-journald"
    dbk_mark_changed
  else
    APPLY_FAILS+=("systemctl restart systemd-journald 失败: $(printf '%s' "$out" | tr '\n' ' ')")
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
  dbk_exit PASS "$msg:三项判据全部达成(配置就位、journalctl 可读、journald active)"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  apply_conf
  apply_restart
  check_all
  finish "journald 持久化已执行(--apply;复读判据后判定)"
fi

check_all
finish "journald 持久化判据核对完成(--check 零写)"
