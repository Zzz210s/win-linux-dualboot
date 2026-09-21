#!/usr/bin/env bash
# L4:健壮性配置落地(设计 4.7 的 R1-R9;Fedora 44 Silverblue 原子版)。六项逐项执行,单项失败不中断,末尾汇总。
#
# 用法:bash scripts/linux/hardening.sh [--check|--dry-run] [--apply] [--log <path>]
#   缺省(或 --check/--dry-run)是 dry-run:只打印六项的动作与判据,不改动系统;--apply(需要 root)才真正改系统。
#   --yes 是全仓契约的统一选项,由 first-boot.sh 在 apply 模式下透传;本脚本以 --apply 为唯一执行门槛。
#   六项:R5 journald 持久化、R8 保守更新策略(rpm-ostreed-automatic)、R9 磁盘健康(SMART)、R7 SSH 救援、
#     R1 变更前固定当前部署、R2 部署级回滚可用性(R1/R2 只读核对,不写系统;用户数据不随部署回滚)。详见 dry-run 输出。
# 环境开关:DBK_SKIP_OSTREE=1 只跳过 rpm-ostree install(文件与 systemd 动作照做),用于无网络/无 rpm-ostree 的静态校验。
# 注入(离线校验):DBK_RPM_OSTREE / DBK_JOURNALD_CONF / DBK_RPM_OSTREED_CONF / DBK_LOG。
# 日志追加到 /var/log/dbk/hardening.log;每项结果打成 DBK-RESULT 行(供 first-boot.sh 摘要提取)。
# 退出码:0=无失败项(跳过不影响),1=有失败项。本脚本是逐项汇总型,不得 set -e。夹具级验证,真机未跑。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
[ -r "$HERE/dbk-ostree.sh" ] || { echo "错误: 缺少 $HERE/dbk-ostree.sh" >&2; exit 1; }
LOG="${DBK_LOG:-/var/log/dbk/hardening.log}"
source "$HERE/dbk-log.sh"
source "$HERE/dbk-ostree.sh"

TPL="$ROOT/templates"
JOURNALD_CONF="${DBK_JOURNALD_CONF:-/etc/systemd/journald.conf.d/99-dbk-persistent.conf}"
OSTREED_CONF="${DBK_RPM_OSTREED_CONF:-/etc/rpm-ostreed.conf}"
RB_STR="${DBK_RPM_OSTREE:-rpm-ostree}"; [ -n "$RB_STR" ] || RB_STR=rpm-ostree
RB=(); read -r -a RB <<<"$RB_STR"
SKIP_OSTREE="${DBK_SKIP_OSTREE:-0}"
APPLY=0
NAMES=(); STATES=(); KEYS=()
DEPRE='^[[:space:]]*(●|○|\*)?[[:space:]]*[A-Za-z0-9._+-]+:[^[:space:]]*(//|fedora)'

usage() { sed -n '2,12p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --check|--dry-run) APPLY=0; shift ;;
    --yes) shift ;;                       # 契约统一选项:first-boot.sh 在 apply 模式透传;执行门槛仍是 --apply
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done
case "$SKIP_OSTREE" in 1|0) ;; *) die "DBK_SKIP_OSTREE 只接受 0/1: $SKIP_OSTREE" ;; esac

[ -r "$TPL/journald-persistent.snippet" ] && [ -r "$TPL/rpm-ostreed.snippet" ] || die "缺少模板:$TPL 下的 journald-persistent.snippet 或 rpm-ostreed.snippet"
grep -qE 'Storage[[:space:]]*=[[:space:]]*persistent' "$TPL/journald-persistent.snippet" || die "模板 journald-persistent.snippet 缺少 Storage=persistent(措施 R5)"
grep -qE 'AutomaticUpdatePolicy[[:space:]]*=[[:space:]]*(check|download)[[:space:]]*$' "$TPL/rpm-ostreed.snippet" || die "模板 rpm-ostreed.snippet 的 AutomaticUpdatePolicy 只能是 check 或 download(决策 3.18 禁止 stage)"

if [ "$APPLY" -ne 1 ]; then
  log "=== dry-run:以下六项不会被执行 ==="
  log "R5 journald 持久化:$TPL/journald-persistent.snippet -> $JOURNALD_CONF;systemctl restart systemd-journald;判据 /var/log/journal 存在"
  log "R8 保守更新策略:$TPL/rpm-ostreed.snippet -> $OSTREED_CONF;enable --now rpm-ostreed-automatic.timer;判据回读 AutomaticUpdatePolicy=check|download(stage 即 fail)"
  log "R9 磁盘健康:分层安装 smartmontools(rpm-ostree install,需重启);enable --now smartd;判据 smartctl -H 摘要"
  log "R7 SSH 救援:enable --now sshd(不装包);判据 ss -tlnp | grep :22"
  log "R1 变更前固定部署:只读核对 $RB_STR status 的 Pinned 状态;口径:分层安装/rebase/发行版升级前先 $RB_STR pin(可用 scripts/linux/dbk-rollback.sh --pin)"
  log "R2 部署级回滚:只读核对部署数 >= 2;回滚入口 scripts/linux/dbk-rollback.sh --rollback 或开机菜单选旧部署;用户数据不随部署回滚(/var、/var/home 不在部署内)"
  log "dry-run 结束:未修改任何文件。确认无误后加 --apply 重跑:sudo bash scripts/linux/hardening.sh --apply"
  exit 0
fi
[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo bash $0 --apply"

# 记一项结果(同时落 DBK-RESULT 行,first-boot.sh 摘要据此提取)
record() { NAMES+=("$1"); STATES+=("$2"); KEYS+=("$3"); log "DBK-RESULT ${2} ${1} | ${3}"; }

# 安装片段:与模板一致则跳过;存在但不同则先备份为 <目标>.dbk.bak(不覆盖既有备份)再覆盖
install_snippet() {
  local tpl="$1" dst="$2"
  [ -r "$tpl" ] || { log "错误: 缺少模板 $tpl"; return 1; }
  if [ -f "$dst" ] && cmp -s "$tpl" "$dst"; then log "目标 $dst 已是模板内容,跳过"; return 0; fi
  if [ -f "$dst" ] && [ ! -e "$dst.dbk.bak" ]; then
    cp -a "$dst" "$dst.dbk.bak" || return 1
    log "已备份 $dst -> $dst.dbk.bak"
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  cp -a "$tpl" "$dst" || return 1
  log "已安装 $tpl -> $dst"
}

# rpm-ostree status 文本:只读,只取一次(可用 DBK_RPM_OSTREE 注入替代命令,便于离线校验)
OSTREE_TXT=""; OSTREE_OK=0; OSTREE_LOADED=0
ostree_status() {
  if [ "$OSTREE_LOADED" -eq 0 ]; then
    OSTREE_LOADED=1
    if command -v "${RB[0]}" >/dev/null 2>&1 && OSTREE_TXT="$("${RB[@]}" status 2>&1)"; then OSTREE_OK=1; fi
  fi
  [ "$OSTREE_OK" -eq 1 ]
}
ostree_count() { printf '%s\n' "$OSTREE_TXT" | grep -cE "$1" || true; }
ostree_skip() { record "$1" skip "取不到 rpm-ostree status($RB_STR 不可用或非原子版):$2"; }

item_r5() {
  local name="R5 journald 持久化(崩溃可观测)"
  install_snippet "$TPL/journald-persistent.snippet" "$JOURNALD_CONF" || { record "$name" fail "$JOURNALD_CONF 安装失败"; return; }
  if ! systemctl restart systemd-journald >/dev/null 2>&1; then
    record "$name" fail "片段已就位但 systemctl restart systemd-journald 失败"
    return
  fi
  if [ -d /var/log/journal ]; then
    record "$name" ok "片段已就位且 journald 已重启;/var/log/journal 存在(/var 不属于部署,日志不随回滚丢失)"
  else
    record "$name" fail "片段已就位且 journald 已重启,但 /var/log/journal 不存在(journalctl -b -1 仍不可用)"
  fi
}

item_r8() {
  local name="R8 保守更新策略(只 check/download,不自动应用/重启)" key pol
  install_snippet "$TPL/rpm-ostreed.snippet" "$OSTREED_CONF" || { record "$name" fail "$OSTREED_CONF 安装失败"; return; }
  pol="$(grep -m1 -E '^[[:space:]]*AutomaticUpdatePolicy[[:space:]]*=' "$OSTREED_CONF" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]' || true)"
  case "$pol" in
    check|download) ;;
    stage) record "$name" fail "回读 AutomaticUpdatePolicy=stage:自动应用/自动重启被打开(决策 3.18 与 R8 禁止)"; return ;;
    "") record "$name" fail "$OSTREED_CONF 里没有 AutomaticUpdatePolicy 行(回读为空)"; return ;;
    *) record "$name" fail "AutomaticUpdatePolicy 取值非法:$pol(只允许 check/download)"; return ;;
  esac
  key="$OSTREED_CONF 已就位;AutomaticUpdatePolicy=$pol"
  if systemctl enable --now rpm-ostreed-automatic.timer >/dev/null 2>&1; then
    record "$name" ok "$key;定时器已 enable --now(应用与重启仍交给人工)"
  else
    record "$name" fail "$key;systemctl enable --now rpm-ostreed-automatic.timer 失败"
  fi
}

item_r9() {
  local name="R9 磁盘健康监控(SMART)" dev line summary="smartd 已 enable --now" st
  pkg_ensure smartmontools "sudo rpm-ostree install smartmontools && sudo systemctl reboot"; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_OSTREE=1:跳过分层安装与 smartd 启用"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "分层安装 smartmontools 失败(补救命令见上面库层的硬前置提示)"; return; fi
  if ! pkg_installed smartmontools; then
    pkg_reboot_hint
    record "$name" ok "已提交分层安装 smartmontools(需重启生效);重启后复跑 sudo bash scripts/linux/hardening.sh --apply 启用 smartd 并采集 smartctl -H"
    return
  fi
  if ! systemctl enable --now smartd >/dev/null 2>&1; then record "$name" fail "systemctl enable --now smartd 失败"; return; fi
  while read -r dev; do
    [ -n "$dev" ] || continue
    line="$(smartctl -H "/dev/$dev" 2>&1 | grep -m1 -E 'SMART overall-health|SMART Health Status' || true)"
    [ -n "$line" ] && summary="$summary;/dev/$dev: $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
  done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
  case "$summary" in *"/dev/"*) ;; *) summary="$summary;未取到健康行(需 root 或盘不支持,可手工 smartctl -H /dev/nvme0)" ;; esac
  record "$name" ok "$summary"
}

item_r7() {
  local name="R7 SSH 救援通道" listen
  if ! systemctl enable --now sshd >/dev/null 2>&1; then
    record "$name" fail "systemctl enable --now sshd 失败(基础镜像自带 sshd,不需要安装)"
    return
  fi
  listen="$(ss -tlnp 2>/dev/null | grep -E ':22\b' | head -n 1 || true)"
  if [ -n "$listen" ]; then
    record "$name" ok "sshd 已 enable --now;监听: $(printf '%s' "$listen" | sed 's/^[[:space:]]*//')"
  else
    record "$name" fail "sshd 已启用但 22 端口未监听(ss -tlnp | grep :22 为空)"
  fi
}

item_r1() {
  local name="R1 变更前固定当前部署" pins
  if ! ostree_status; then ostree_skip "$name" "只读核对跳过;变更前仍应手工执行 $RB_STR pin"; return; fi
  pins="$(ostree_count '^[[:space:]]*Pinned:[[:space:]]*yes')"
  record "$name" ok "已固定部署数=$pins;口径:分层安装/rebase/发行版升级前先固定当前部署($RB_STR pin,可用 scripts/linux/dbk-rollback.sh --pin),平时不额外固定"
}

item_r2() {
  local name="R2 部署级回滚可用性" n
  if ! ostree_status; then ostree_skip "$name" "无法核对部署数;回滚入口仍是 scripts/linux/dbk-rollback.sh --rollback 与开机菜单选旧部署"; return; fi
  n="$(ostree_count "$DEPRE")"
  if [ "$n" -ge 2 ]; then
    record "$name" ok "部署数=$n(>=2 可回退);回滚入口:scripts/linux/dbk-rollback.sh --rollback 或开机菜单选旧部署;用户数据不随部署回滚(/var、/var/home 不在部署内)"
  else
    record "$name" fail "部署数=$n(<2):还没有可回退的部署;完成一次更新或分层安装产生新部署后重跑本项"
  fi
}

print_summary() {
  local i fails=0
  log "=== 汇总(共 ${#NAMES[@]} 项;失败不中断,其余项已执行完毕)==="
  for i in "${!NAMES[@]}"; do
    log "DBK-RESULT ${STATES[$i]} ${NAMES[$i]} | ${KEYS[$i]}"
    if [ "${STATES[$i]}" = fail ]; then fails=$((fails+1)); fi
  done
  log "失败项: $fails 项(ok 与 skip 见上)"
  return "$fails"
}

log "=== 健壮性配置开始(apply=$APPLY;DBK_SKIP_OSTREE=$SKIP_OSTREE)==="
item_r5; item_r8; item_r9; item_r7; item_r1; item_r2
print_summary
fails=$?
if [ "$fails" -gt 0 ]; then
  log "结束:有 $fails 个失败项;每项独立判定,按各项判据修好后可整脚本重跑(幂等)"
  exit 1
fi
log "结束:六项无失败项(记为 skip 的项见上面的 DBK-RESULT 行;分层安装需重启生效)"
exit 0
