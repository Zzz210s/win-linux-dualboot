#!/usr/bin/env bash
# 对应卡:05-13
# 破坏性:1(会写 fstab/user-dirs.dirs、装包、起服务:--apply 必须显式 --yes)
# L4:健壮性配置落地(R1-R9;Fedora 44 Silverblue / 原子版语义)。九项逐项执行,单项失败不中断,末尾汇总。
#
# 用法:bash scripts/linux/hardening.sh [--check|--dry-run] [--apply --yes] [--json] [--log <path>]
#   缺省(或 --check/--dry-run)是 dry-run:只打印九项的动作与判据,不改动系统;--apply(需要 root)才真正改系统,
#   且必须同时给 --yes(全仓契约:声明「# 破坏性:1」的脚本,--apply 缺 --yes 一律 64 且零写)。
#   九项:R1 变更前备份 baseline/、R2 部署级回滚(rollback-deploy.sh)、R3 旧内核保留、R4 救援 U 盘(人工)、
#     R5 journald 持久化、R6 OOM/zram(storage.sh)、R7 SSH 通道、R8 保守更新(set-updates.sh)、R9 SMART。
#   设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D4 与第 4 节(hardening.sh 行)。
# 环境开关:DBK_SKIP_PKG=1(兼容 DBK_SKIP_APT)只跳过分层安装动作(文件与 systemd 动作照做)。
# 注入(离线校验):DBK_BASELINE_DIR / DBK_BACKUP_DIR / DBK_JOURNALD_CONF / DBK_BOOT_DIR / DBK_LOG。
# 日志追加到 /var/log/dbk/hardening.log;每项结果打成 DBK-RESULT 行(供 first-boot.sh 摘要提取)。
# 退出码:0=无失败项(跳过不影响),1=有失败项。本脚本是逐项汇总型,不得 set -e。夹具级验证,真机未跑。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
[ -r "$HERE/dbk-pkg.sh" ] || { echo "错误: 缺少 $HERE/dbk-pkg.sh" >&2; exit 1; }
# shellcheck disable=SC2034  # LOG 由 source 进来的 dbk-log.sh 的 log() 消费(跨文件)
LOG="${DBK_LOG:-/var/log/dbk/hardening.log}"
source "$HERE/dbk-log.sh"
source "$HERE/dbk-pkg.sh"

TPL="$ROOT/templates"
JOURNALD_CONF="${DBK_JOURNALD_CONF:-/etc/systemd/journald.conf.d/99-dbk-persistent.conf}"
BASEDIR="${DBK_BASELINE_DIR:-$ROOT/baseline}"; BAKDIR="${DBK_BACKUP_DIR:-/var/backups/dbk}"
BOOT_DIR="${DBK_BOOT_DIR:-/boot}"
APPLY=0; YES=0; JSON=0; NAMES=(); STATES=(); KEYS=(); SEEN_CHECK=0; SEEN_APPLY=0

usage() { sed -n '2,13p' "$0" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; SEEN_APPLY=1; shift ;;
    --check|--dry-run) APPLY=0; SEEN_CHECK=1; shift ;;
    --json) JSON=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --log)
      need_val "$#" "--log" "<日志文件路径>"
      # shellcheck disable=SC2034  # LOG 由 source 进来的 dbk-log.sh 的 log() 消费(跨文件)
      LOG="$2"
      shift 2 ;;
    --log=*)
      # shellcheck disable=SC2034  # LOG 由 dbk-log.sh 的 log() 消费(跨文件)
      LOG="${1#*=}"
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; printf '用法错误: 未知参数 %s\n' "$1" >&2; exit 64 ;;
  esac
done

# --check/--dry-run 与 --apply 互斥(与库层 dbk_parse_args 同口径):互斥时 64 且零写。
{ [ "$SEEN_CHECK" -eq 1 ] && [ "$SEEN_APPLY" -eq 1 ]; } && { usage; echo "用法错误: --check/--dry-run 与 --apply 互斥,只能给一个" >&2; exit 64; }
# --json 时人读信息走 stderr(dbk-log.sh 的 log() 消费 DBK_LOG_TO_STDERR),stdout 只留一行 JSON。
# shellcheck disable=SC2034  # DBK_LOG_TO_STDERR 由 dbk-log.sh 的 log() 消费(跨文件)
if [ "$JSON" -eq 1 ]; then DBK_LOG_TO_STDERR=1; fi

# 破坏性门槛(与 dbk-cli.sh 同口径):带 --apply 必须显式 --yes,否则 64 且零写。
if [ "$APPLY" -eq 1 ] && [ "$YES" -ne 1 ]; then
  usage
  echo "用法错误: 脚本头声明了「# 破坏性:1」,--apply 必须显式给 --yes(本脚本会写 fstab/user-dirs.dirs、装包、起服务)" >&2
  exit 64
fi

# 记一项结果(同时落 DBK-RESULT 行,first-boot.sh 摘要据此提取)
record() { NAMES+=("$1"); STATES+=("$2"); KEYS+=("$3"); log "DBK-RESULT ${2} ${1} | ${3}"; }
last_line() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-160; }
# 跑一个同级步骤脚本:apply 模式给 --apply(--yes 由各脚本自己声明破坏性时使用),否则只给 --check
run_step() {   # <脚本文件名> [--apply 附加参数…];输出写调用方变量 STEP_OUT/STEP_RC
  STEP_OUT=""; STEP_RC=0
  if [ "$APPLY" -eq 1 ]; then STEP_OUT="$(bash "$HERE/$1" --apply "${@:2}" 2>&1)" || STEP_RC=$?
  else STEP_OUT="$(bash "$HERE/$1" --check 2>&1)" || STEP_RC=$?; fi
  return 0
}

# --json:stdout 只留一行契约 JSON(人读信息由 DBK_LOG_TO_STDERR=1 送到 stderr)
emit_json() { printf '{"step":"05-13","status":"%s","message":"%s","checks":[],"actions":[],"changed":false}\n' "$1" "$(dbk_json_escape "$2")"; }

if [ "$APPLY" -ne 1 ]; then
  log "=== dry-run:以下九项不会被执行 ==="
  log "R1 变更前备份 baseline/:$BASEDIR -> $BAKDIR/<时间戳>-baseline/;判据备份目录可读"
  log "R2 部署级回滚:只读核对 scripts/linux/rollback-deploy.sh 与接口 dbk-rollback.sh;回滚命令见该脚本 --check/--apply"
  log "R3 旧内核保留:只读核对 $BOOT_DIR 下的 vmlinuz-* 数量(>=2 才算保留了旧内核)"
  log "R4 永久救援介质:人工(确认 U 盘在位并标记已验证可用),本脚本只登记需人工"
  log "R5 journald 持久化:调 scripts/linux/set-journald.sh(片段 $TPL/journald-persistent.snippet -> $JOURNALD_CONF);restart systemd-journald;判据 /var/log/journal 存在"
  log "R6 OOM/zram:调 scripts/linux/storage.sh(swapfile + zram0);systemd-oomd 由该脚本一并核对"
  log "R7 SSH 救援:enable --now sshd(不装包);判据 ss -tlnp | grep :22"
  log "R8 保守更新:调 scripts/linux/set-updates.sh(只检查/下载,不自动应用与不自动重启;需 --yes)"
  log "R9 磁盘健康:分层安装 smartmontools(原子版:重启后生效);enable --now smartd;判据 smartctl -H 摘要"
  log "dry-run 结束:未修改任何文件。确认无误后加 --apply 重跑:sudo bash scripts/linux/hardening.sh --apply"
  [ "$JSON" -eq 1 ] && emit_json pass "dry-run 完成:九项未执行、未修改任何文件(缺省/--check/--dry-run 都是 dry-run);确认无误后加 --apply --yes 重跑"
  exit 0
fi
[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo bash $0 --apply"

item_r1() {   # 变更前备份 baseline/(取代原子版的"变更前固定部署")
  local name="R1 变更前备份 baseline/" ts bak
  if [ ! -d "$BASEDIR" ]; then record "$name" skip "没有 $BASEDIR 可备份(先落 03-9/05-12 产物)"; return; fi
  ts="$(date '+%Y%m%d-%H%M%S')"; bak="$BAKDIR/$ts-baseline"
  if mkdir -p "$BAKDIR" && cp -a "$BASEDIR" "$bak"; then record "$name" ok "已备份 $BASEDIR -> $bak(升级/重装前先跑本项)"
  else record "$name" fail "备份失败:cp -a $BASEDIR $bak(核对 $BAKDIR 的权限与空间)"; fi
}
item_r2() {   # 部署级回滚可用性(只读核对;接口 dbk-rollback.sh)
  local name="R2 部署级回滚(列部署 + 回滚前 pin + 回到上一部署)"
  if [ ! -r "$HERE/rollback-deploy.sh" ]; then record "$name" fail "缺 $HERE/rollback-deploy.sh,部署级回滚无脚本可依"; return; fi
  if [ ! -r "$HERE/dbk-rollback.sh" ]; then record "$name" fail "缺 $HERE/dbk-rollback.sh(发行版薄接口),回滚判据无接口可依"; return; fi
  record "$name" ok "回退入口:bash scripts/linux/rollback-deploy.sh --check / --pin <索引> --yes / --apply --yes(重启后生效);接口:dbk-rollback.sh 的 deployments_list / rollback_to_previous"
}
item_r3() {   # 旧内核保留(只读核对 /boot 下的内核数)
  local name="R3 旧内核保留" n
  n="$(ls -1 "$BOOT_DIR"/vmlinuz-* 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ge 2 ]; then record "$name" ok "$BOOT_DIR 下有 $n 个内核(旧内核保留,升级后可从 GRUB 高级选项回退)"
  elif [ "${n:-0}" -eq 1 ]; then record "$name" skip "$BOOT_DIR 下只有 1 个内核:首次安装属正常;内核升级一次后自然 >=2,届时复跑本项"
  else record "$name" fail "$BOOT_DIR 下找不到 vmlinuz-*(核对 $BOOT_DIR 是否为独立 ext4 分区)"; fi
}
item_r4() { record "R4 永久救援介质(安装 U 盘兼 live)" skip "需人工:确认介质在位并标记\"已验证可用\",本脚本无法自动判定"; }
item_r5() {   # journald 持久化:唯一写者 set-journald.sh(消费同一模板 templates/journald-persistent.snippet)
  local name="R5 journald 持久化(崩溃可观测)"
  if [ ! -r "$HERE/set-journald.sh" ]; then record "$name" skip "缺 $HERE/set-journald.sh;请人工把 $TPL/journald-persistent.snippet 装到 $JOURNALD_CONF 并重启 systemd-journald"; return; fi
  run_step set-journald.sh --yes
  case "$STEP_RC" in
    0) record "$name" ok "$(last_line "$STEP_OUT")" ;;
    2) record "$name" skip "set-journald.sh 判为需人工:$(last_line "$STEP_OUT")" ;;
    *) record "$name" fail "set-journald.sh 退出码 $STEP_RC:$(last_line "$STEP_OUT")" ;;
  esac
}
item_r6() {   # OOM 与内存压力防护(zram + swapfile):委托 storage.sh
  local name="R6 OOM 与内存压力防护(zram + swapfile)"
  if [ ! -r "$HERE/storage.sh" ]; then record "$name" skip "缺 $HERE/storage.sh;请人工核对 zramctl 与 swapon --show"; return; fi
  run_step storage.sh --yes
  case "$STEP_RC" in
    0) record "$name" ok "$(last_line "$STEP_OUT")" ;;
    2) record "$name" skip "storage.sh 判为需人工:$(last_line "$STEP_OUT")" ;;
    *) record "$name" fail "storage.sh 退出码 $STEP_RC:$(last_line "$STEP_OUT")" ;;
  esac
}
item_r7() {
  local name="R7 SSH 救援通道" listen
  if ! systemctl enable --now sshd >/dev/null 2>&1; then record "$name" fail "systemctl enable --now sshd 失败(基础镜像自带 sshd,不需要安装)"; return; fi
  listen="$(ss -tlnp 2>/dev/null | grep -E ':22\b' | head -n 1 || true)"
  if [ -n "$listen" ]; then record "$name" ok "sshd 已 enable --now;监听: $(printf '%s' "$listen" | sed 's/^[[:space:]]*//')"
  else record "$name" fail "sshd 已启用但 22 端口未监听(ss -tlnp | grep :22 为空)"; fi
}
item_r8() {   # 保守更新策略:委托 set-updates.sh(只检查/下载,不自动应用与不自动重启;原子版语义,同 05-7)
  local name="R8 保守更新(只检查/下载,不自动应用与不自动重启)"
  if [ ! -r "$HERE/set-updates.sh" ]; then record "$name" skip "缺 $HERE/set-updates.sh;请人工核对更新策略配置(节名与键名见 scripts/linux/dbk-update.sh 接口)"; return; fi
  run_step set-updates.sh --yes
  case "$STEP_RC" in
    0) record "$name" ok "$(last_line "$STEP_OUT")" ;;
    2) record "$name" skip "set-updates.sh 判为需人工:$(last_line "$STEP_OUT")" ;;
    *) record "$name" fail "set-updates.sh 退出码 $STEP_RC:$(last_line "$STEP_OUT")" ;;
  esac
}
item_r9() {
  local name="R9 磁盘健康监控(SMART)" dev line summary="smartd 已 enable --now" st rc=0
  pkg_ensure smartmontools; st=$?
  if [ "$st" = 9 ]; then record "$name" skip "DBK_SKIP_PKG=1:跳过分层安装与 smartd 启用"; return; fi
  if [ "$st" = 2 ]; then record "$name" skip "需人工:分层安装无法立即生效(--now 不可用);请重启后重跑本项复核"; return; fi
  if [ "$st" != 0 ]; then record "$name" fail "分层安装 smartmontools 失败(硬前置命令见上面库层提示)"; return; fi
  pkg_needs_reboot || rc=$?
  case "$rc" in
    0) record "$name" skip "需人工:smartmontools 已提交分层安装但尚未重启生效;重启后重跑本项复核"; return ;;
    2) record "$name" skip "需人工:读不到分层安装状态,无法判断是否已生效;重启后重跑本项复核"; return ;;
    *) if [ "$rc" -ne 1 ]; then record "$name" skip "需人工:pkg_needs_reboot 返回未知状态 $rc(库层约定只可能是 0/1/2);重启后重跑本项复核"; return; fi ;;
  esac
  if ! systemctl enable --now smartd >/dev/null 2>&1; then record "$name" fail "systemctl enable --now smartd 失败"; return; fi
  while read -r dev; do
    [ -n "$dev" ] || continue
    line="$(smartctl -H "/dev/$dev" 2>&1 | grep -m1 -E 'SMART overall-health|SMART Health Status' || true)"
    [ -n "$line" ] && summary="$summary;/dev/$dev: $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
  done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
  case "$summary" in *"/dev/"*) ;; *) summary="$summary;未取到健康行(需 root 或盘不支持,可手工 smartctl -H /dev/nvme0)" ;; esac
  record "$name" ok "$summary"
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

log "=== 健壮性配置开始(apply=$APPLY;DBK_SKIP_PKG=${DBK_SKIP_PKG:-${DBK_SKIP_APT:-0}})==="
item_r1; item_r2; item_r3; item_r4; item_r5; item_r6; item_r7; item_r8; item_r9
print_summary
fails=$?
if [ "$fails" -gt 0 ]; then
  log "结束:有 $fails 个失败项;每项独立判定,按各项判据修好后可整脚本重跑(幂等)"
  [ "$JSON" -eq 1 ] && emit_json fail "健壮性 R1-R9 有 $fails 个失败项(失败不中断,其余项已执行完毕);逐项见日志 $LOG"
  exit 1
fi
log "结束:九项无失败项(记为 skip 的项见上面的 DBK-RESULT 行)"
[ "$JSON" -eq 1 ] && emit_json pass "健壮性 R1-R9 完成:九项无失败项(记为 skip 的项见日志 $LOG)"
exit 0
