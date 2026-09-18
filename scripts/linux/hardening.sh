#!/usr/bin/env bash
# L4:健壮性配置落地(设计 3.14/4.7 的 R1-R9、决策 3.18/3.19)。六项逐项执行,单项失败不中断,末尾汇总。
#
# 用法:bash scripts/linux/hardening.sh [--apply] [--log <path>]
#   默认 dry-run:打印六项的动作与判据,不改动系统;--apply(需要 root)才真正改系统。
#   六项:R5 journald 持久化片段 -> 重启 systemd-journald -> 验证 /var/log/journal;
#        R8 unattended-upgrades 片段(仅安全更新/不自动重启/linux- 与 nvidia- 黑名单)-> enable --now -> 回读;
#        R9 apt install smartmontools -> enable --now smartd -> 记录 smartctl -H 摘要;
#        R7 apt install openssh-server -> enable --now ssh -> 记录 22 端口监听;
#        R3 grub-defaults.snippet 合并进 /etc/default/grub(先备份)-> update-grub;
#        R1/R2 先查 /snapshots 已挂载(未挂载记 fail 并提示在 mount-shared.sh 之后复跑)-> apt install timeshift -> 说明快照口径(保留 3 份、只在变更前手动创建、不设定时任务)。
# 环境开关:DBK_SKIP_APT=1 只跳过 apt-get install(文件与 systemd 动作照做),用于无网络/无 apt 的静态校验。
# 日志追加到 /var/log/dbk/hardening.log;每项结果打成 DBK-RESULT 行(供 first-boot.sh 摘要提取)。
# 退出码:0=无失败项(跳过不影响),1=有失败项。设计依据:设计 4.7 的 R1-R9、第 7 节故障矩阵。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
[ -r "$HERE/dbk-apt.sh" ] || { echo "错误: 缺少 $HERE/dbk-apt.sh" >&2; exit 1; }
LOG="${DBK_LOG:-/var/log/dbk/hardening.log}"
source "$HERE/dbk-log.sh"
source "$HERE/dbk-apt.sh"

TPL="$ROOT/templates"
JOURNALD_CONF="${DBK_JOURNALD_CONF:-/etc/systemd/journald.conf.d/99-dbk-persistent.conf}"
APT_POLICY="${DBK_APT_POLICY:-/etc/apt/apt.conf.d/52-dbk-policy}"
GRUB_FILE="${DBK_GRUB_FILE:-/etc/default/grub}"
GRUB_BAK="$GRUB_FILE.dbk.bak"
SKIP_APT="${DBK_SKIP_APT:-0}"
APPLY=0
NAMES=(); STATES=(); KEYS=()

usage() { sed -n '2,13p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done
case "$SKIP_APT" in 1|0) ;; *) die "DBK_SKIP_APT 只接受 0/1: $SKIP_APT" ;; esac

for t in journald-persistent.snippet unattended-upgrades.snippet grub-defaults.snippet; do
  [ -r "$TPL/$t" ] || die "缺少模板 $TPL/$t"
done
if ! grep -qF '"linux-"' "$TPL/unattended-upgrades.snippet" || ! grep -qF '"nvidia-"' "$TPL/unattended-upgrades.snippet"; then
  die "模板 unattended-upgrades.snippet 缺少内核/驱动黑名单(决策 3.18)"
fi
grep -qE '^[[:space:]]*GRUB_DEFAULT=saved' "$TPL/grub-defaults.snippet" || die "模板 grub-defaults.snippet 缺少未注释的 GRUB_DEFAULT=saved(措施 R3)"

if [ "$APPLY" -ne 1 ]; then
  log "=== dry-run:以下六项不会被执行 ==="
  log "R5 journald 持久化:$TPL/journald-persistent.snippet -> $JOURNALD_CONF;systemctl restart systemd-journald;判据 [ -d /var/log/journal ]"
  log "R8 更新策略:$TPL/unattended-upgrades.snippet -> $APT_POLICY;enable --now unattended-upgrades;判据黑名单含 linux- 与 nvidia-"
  log "R9 磁盘健康:apt-get install -y smartmontools;enable --now smartd;判据 smartctl -H 摘要与 smartd active"
  log "R7 SSH 救援:apt-get install -y openssh-server;enable --now ssh;判据 ss -tlnp | grep :22"
  log "R3 引导:$TPL/grub-defaults.snippet 合并进 $GRUB_FILE(备份 $GRUB_BAK)-> update-grub"
  log "R1/R2 快照:先查 /snapshots 已挂载(未挂载即 fail,需在 mount-shared.sh --snapshot-uuid 之后复跑);apt-get install -y timeshift;保留 3 份、只在变更前手动创建"
  log "环境开关:DBK_SKIP_APT=1 只跳过 apt-get install,文件与 systemd 动作照做"
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

# apt 安装:apt_install() 由 dbk-apt.sh 提供(0=成功 9=按 DBK_SKIP_APT 跳过 1=失败),本脚本不再重复实现

run_update_grub() {
  if command -v update-grub >/dev/null 2>&1; then update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg
  else return 127; fi
}

item_r5() {
  local name="R5 journald 持久化(崩溃可观测)" key
  install_snippet "$TPL/journald-persistent.snippet" "$JOURNALD_CONF" || { record "$name" fail "$JOURNALD_CONF 安装失败"; return; }
  if systemctl restart systemd-journald 2>/dev/null; then key="片段已就位;journald 已重启"; else record "$name" fail "片段已就位但重启 systemd-journald 失败"; return; fi
  systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  if [ -d /var/log/journal ]; then record "$name" ok "$key;/var/log/journal 存在"; else record "$name" fail "$key;但 /var/log/journal 不存在"; fi
}

item_r8() {
  local name="R8 更新策略(仅安全更新/不自动重启/黑名单)" key st
  install_snippet "$TPL/unattended-upgrades.snippet" "$APT_POLICY" || { record "$name" fail "$APT_POLICY 安装失败"; return; }
  key="$APT_POLICY 已就位"
  if grep -qF '"linux-"' "$APT_POLICY" && grep -qF '"nvidia-"' "$APT_POLICY"; then key="$key;黑名单含 linux- 与 nvidia-"; else key="$key;警告: 黑名单不完整"; fi
  if grep -qF 'Automatic-Reboot "false"' "$APT_POLICY"; then key="$key;不自动重启"; else key="$key;警告: 未声明 Automatic-Reboot false"; fi
  apt_install unattended-upgrades; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_APT=1;片段已就位:$key"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "安装 unattended-upgrades 失败"; return; fi
  if systemctl enable --now unattended-upgrades >/dev/null 2>&1; then record "$name" ok "$key;服务已 enable --now"; else record "$name" fail "systemctl enable --now unattended-upgrades 失败"; fi
}

item_r9() {
  local name="R9 磁盘健康监控(SMART)" dev line summary st
  apt_install smartmontools; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_APT=1:跳过安装与 smartd"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "安装 smartmontools 失败"; return; fi
  if systemctl enable --now smartd >/dev/null 2>&1; then summary="smartd 已 enable --now"; else record "$name" fail "systemctl enable --now smartd 失败"; return; fi
  while read -r dev; do
    line="$(smartctl -H "/dev/$dev" 2>&1 | grep -m1 -E 'SMART overall-health|SMART Health Status' || true)"
    [ -n "$line" ] && summary="$summary;/dev/$dev: $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
  done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
  case "$summary" in *"/dev/"*) ;; *) summary="$summary;未取到健康行(需 root 或盘不支持,可手工 smartctl -H /dev/nvme0)" ;; esac
  record "$name" ok "$summary"
}

item_r7() {
  local name="R7 SSH 救援通道" listen st
  apt_install openssh-server; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_APT=1:跳过安装与 ssh 启用"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "安装 openssh-server 失败"; return; fi
  if systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1; then
    listen="$(ss -tlnp 2>/dev/null | grep -E ':22\b' | head -n 1 || true)"
    if [ -n "$listen" ]; then record "$name" ok "监听: $(printf '%s' "$listen" | sed 's/^[[:space:]]*//')"; else record "$name" fail "ssh 已启用但 22 端口未监听(ss -tlnp | grep :22 为空)"; fi
  else record "$name" fail "systemctl enable --now ssh 失败"; fi
}

item_r3() {
  local name="R3 GRUB(saved)与多内核保留" tpl="$TPL/grub-defaults.snippet" keys k line merged=0 key
  [ -r "$tpl" ] || { record "$name" fail "缺少 $tpl"; return; }
  [ -f "$GRUB_FILE" ] || { record "$name" fail "找不到 $GRUB_FILE"; return; }
  keys="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$tpl" | tr -d '=')"
  [ -n "$keys" ] || { record "$name" fail "模板没有可合并的未注释 KEY=VALUE"; return; }
  if [ ! -e "$GRUB_BAK" ]; then cp -a "$GRUB_FILE" "$GRUB_BAK" || { record "$name" fail "备份 $GRUB_FILE 失败"; return; }; log "已备份 $GRUB_FILE -> $GRUB_BAK"; fi
  [ -z "$(tail -c 1 "$GRUB_FILE")" ] || printf '\n' >>"$GRUB_FILE"
  # 每个键先删旧行再统一追加(结果唯一);注释形式的 GRUB_TERMINAL 条件项不参与合并
  for k in $keys; do
    line="$(grep -m1 -E "^[[:space:]]*$k=" "$tpl" || true)"
    [ -n "$line" ] || continue
    sed -i -E "/^[[:space:]]*$k=/d" "$GRUB_FILE" && printf '%s\n' "$line" >>"$GRUB_FILE" && merged=$((merged+1))
  done
  key="合并 $merged/$(printf '%s' "$keys" | wc -w) 项;回读: $(grep -hE '^[[:space:]]*(GRUB_DEFAULT|GRUB_SAVEDEFAULT|GRUB_TIMEOUT|GRUB_DISABLE_OS_PROBER)=' "$GRUB_FILE" | tr '\n' ' ')"
  if run_update_grub >/dev/null 2>&1; then record "$name" ok "$key;update-grub 已执行"; else record "$name" fail "$key;update-grub 失败(grub.cfg 未更新)"; fi
  log "  条件项:引导菜单阶段黑屏(键盘仍可用)时,去掉 $tpl 里 GRUB_TERMINAL=console 的行首 # 后重跑本项(决策 3.19)"
}

item_r1() {
  local name="R1/R2 变更前快照(timeshift)" st snap
  if findmnt -rn /snapshots >/dev/null 2>&1; then
    snap="$(findmnt -rn -o SOURCE,FSTYPE,SIZE /snapshots | head -n 1)"
  else
    # first-boot 的顺序是 hardening 在 mount-shared 之前,首次 --apply 时 /snapshots 必然未挂载;
    # 此时 R2 判据(设计 4.7)未达成,不能记 ok,否则用户会误以为快照已就绪
    record "$name" fail "/snapshots 未挂载:R2 判据未达成;本项需在 mount-shared.sh --snapshot-uuid 完成后再复跑 bash scripts/linux/hardening.sh --apply"
    return
  fi
  apt_install timeshift; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_APT=1:跳过安装;/snapshots=$snap;口径:保留 3 份、只在变更前手动创建"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "安装 timeshift 失败;/snapshots=$snap"; return; fi
  log "  timeshift 口径:快照目标 /snapshots、保留 3 份(可调)、只在装驱动/换内核等变更前手动创建;本脚本不写定时任务。"
  log "  首次打开 timeshift 按上述口径设置(RSYNC、目标 /snapshots、保留 3);命令行示例:timeshift --create --comments '变更前快照'"
  record "$name" ok "/snapshots=$snap;保留 3 份(可调);只在变更前手动创建(不设定时任务)"
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

log "=== 健壮性配置开始(apply=1;DBK_SKIP_APT=$SKIP_APT)==="
item_r5; item_r8; item_r9; item_r7; item_r3; item_r1
print_summary
fails=$?
if [ "$fails" -gt 0 ]; then
  log "结束:有 $fails 个失败项;每项独立判定,按各项判据修好后可整脚本重跑(幂等)"
  exit 1
fi
log "结束:六项无失败项(跳过项按 DBK_SKIP_APT 口径处理)"
exit 0
