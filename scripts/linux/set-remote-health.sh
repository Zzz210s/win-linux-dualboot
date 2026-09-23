#!/usr/bin/env bash
# 对应卡:05-8
# L4:远程与磁盘健康(Kubuntu / apt 语义;设计依据:docs/design/04-kubuntu-variant-design.md 第 7 节 R7「常开 SSH
#   救援通道」与 R9「磁盘健康监控」)—— sshd 常开(桌面挂死时从另一台机器登录排障)+ smartd 监控磁盘健康。
# 用途:--check 只读判定;--apply 用 apt 安装 smartmontools(走 dbk-pkg.sh)并 `systemctl enable --now sshd smartd`。
# 判据(--check,零写):① `systemctl is-active sshd` = active;
#   ② 逐盘 `smartctl -H /dev/<disk>` 输出含 `SMART overall-health self-assessment test result: PASSED`
#      或 `SMART Health Status: OK`(盘列表来自 `lsblk -dn -o NAME,TYPE` 的 disk 行);未安装 smartctl → 需人工(2);
#   ③ 附加证据(不作为失败项):`ss -tlnp | grep :22` 能看到 22 端口监听。
# 安装语义:apt 装包**立即生效**(与旧原子版的 rpm-ostree 分层安装不同,不需要重启);DBK_SKIP_PKG=1
#   (兼容 DBK_SKIP_APT)只跳过 apt 动作(判据按现状判定)。
# 人工边界:本步不声明破坏性(不写 `# 破坏性:1`):装包可用 apt-get purge 撤销,不动分区/引导。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: set-remote-health.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
# 夹具注入(真机不需要设置):DBK_SYSTEMCTL / DBK_SMARTCTL / DBK_LSBLK / DBK_SS / DBK_APT_GET / DBK_DPKG_QUERY / DBK_SKIP_PKG。
# 待核实(以官方文档为准):smartctl 的健康行文本与退出码位掩码语义、smartd 单元名均未在真机验证。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-remote-health"
# 包管理助手(库文件:非步骤脚本):pkg_installed / pkg_ensure(apt 装包立即生效,无需重启)。
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)
log() { dbk_obs "$*"; }

SC_STR="${DBK_SYSTEMCTL:-systemctl}"
SM_STR="${DBK_SMARTCTL:-smartctl}"
LS_STR="${DBK_LSBLK:-lsblk}"
SS_STR="${DBK_SS:-ss}"
SC=(); SM=(); LS=(); SS=()
read -r -a SC <<<"$SC_STR"
read -r -a SM <<<"$SM_STR"
read -r -a LS <<<"$LS_STR"
read -r -a SS <<<"$SS_STR"
sc() { "${SC[@]}" "$@"; }
sm() { "${SM[@]}" "$@"; }
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

# 盘列表:lsblk -dn -o NAME,TYPE 里 TYPE=disk 的 NAME;失败时把命令输出打到 stderr 并返回空。
lsblk_disks() {
  local out
  if ! out="$("${LS[@]}" -dn -o NAME,TYPE 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 0
  fi
  printf '%s\n' "$out" | awk '$2=="disk"{print $1}'
  return 0
}

check_sshd() {
  local out
  if probe out sc is-active sshd && [ "$out" = active ]; then
    dbk_add_check "sshd 处于 active"
    return 0
  fi
  if [ "$PROBE_RC" -eq 127 ] || [ -z "$out" ]; then
    MANUAL+=("取不到 systemctl($SC_STR): $(printf '%s' "$out" | tr '\n' ' ');请人工确认 sshd 是否 active")
  else
    ISSUES+=("sshd 不是 active(实为 '$out'):桌面挂死时没有救援通道")
  fi
  return 0
}

# 逐盘健康:只看 smartctl 输出里的健康行(smartctl 的退出码是位掩码,不能当判据)。
check_smart() {
  local disks d out line
  if ! command -v "${SM[0]}" >/dev/null 2>&1; then
    MANUAL+=("未安装 smartctl($SM_STR):先 apt-get install -y smartmontools(设计 R9)后重跑,或人工逐盘 smartctl -H")
    return 0
  fi
  disks="$(lsblk_disks)"
  if [ -z "$disks" ]; then
    MANUAL+=("取不到磁盘列表($LS_STR -dn -o NAME,TYPE 为空或失败);请人工逐盘执行 smartctl -H /dev/<盘>")
    return 0
  fi
  for d in $disks; do
    out="$(sm -H "/dev/$d" 2>&1)" || true
    line="$(printf '%s\n' "$out" | grep -m1 -E 'SMART overall-health self-assessment test result:|SMART Health Status:' || true)"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    case "$line" in
      *PASSED*|*"Health Status: OK"*) dbk_add_check "/dev/$d: $line" ;;
      "") MANUAL+=("/dev/$d: smartctl -H 没有给出健康行(需 root 或盘不支持);请人工确认") ;;
      *) ISSUES+=("/dev/$d 健康检查不通过: $line") ;;
    esac
  done
  return 0
}

check_listen() {
  local out line
  if ! out="$("${SS[@]}" -tlnp 2>&1)"; then
    dbk_add_check "附加证据: ss -tlnp 读不到($(printf '%s' "$out" | tr '\n' ' '));不作为失败项"
    return 0
  fi
  line="$(printf '%s\n' "$out" | grep -E ':22([^0-9]|$)' | head -n1 || true)"
  if [ -n "$line" ]; then
    dbk_add_check "附加证据: 22 端口监听 -> $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
  else
    dbk_add_check "附加证据: 未看到 22 端口监听(ss -tlnp | grep :22 为空);不作为失败项,sshd active 才是判据"
  fi
  return 0
}

check_all() {
  ISSUES=(); MANUAL=()
  check_sshd
  check_smart
  check_listen
  return 0
}

# --apply:apt 安装 smartmontools(返回 9=按 DBK_SKIP_PKG 跳过;返回 1=该判据 FAIL,但继续做 systemd 动作)。
apply_pkg() {
  local st=0
  pkg_ensure smartmontools "sudo apt-get install -y smartmontools" >&2 || st=$?
  case "$st" in
    0)
      dbk_add_action "确保 smartmontools 已安装(apt-get install -y)"
      dbk_mark_changed
      ;;
    9)
      dbk_add_check "跳过: DBK_SKIP_PKG=1,未执行 apt-get install smartmontools(判据按现状判定)"
      ;;
    *)
      APPLY_FAILS+=("安装 smartmontools 失败(返回码 $st);按上面库层给出的硬前置命令处理后重跑")
      ;;
  esac
  return 0
}

apply_services() {
  local out
  if probe out sc enable --now sshd smartd; then
    dbk_add_action "systemctl enable --now sshd smartd"
    dbk_mark_changed
  else
    APPLY_FAILS+=("systemctl enable --now sshd smartd 失败: $(printf '%s' "$out" | tr '\n' ' ')")
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
  dbk_exit PASS "$msg:sshd active 且各盘 SMART 健康检查通过"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  apply_pkg
  apply_services
  check_all
  finish "远程与磁盘健康已执行(--apply;复读判据后判定)"
fi

check_all
finish "远程与磁盘健康判据核对完成(--check 零写)"
