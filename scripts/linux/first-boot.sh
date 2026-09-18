#!/usr/bin/env bash
# L4 首启编排器:依次调用 storage.sh、hardening.sh、mount-shared.sh、graphics.sh,
# 每模块单独落日志,末尾生成 /var/log/dbk/first-boot-summary.txt(模块 / 状态 / 关键输出)。
#
# 用法:bash scripts/linux/first-boot.sh [--apply] [--uuid <SHARED_PART_UUID>]
#        [--snapshot-uuid <UUID>] [--user <name>] [--log-dir <dir>]
#   默认 dry-run:各模块以 --dry-run 调用,只打印计划,不改动系统;--apply(需要 root)才真正改系统。
#   模块顺序:storage(交换空间 swapfile + zram)-> hardening(健壮性 R1-R9)
#   -> mount-shared(共享盘挂载 + 家目录重定向,缺 --uuid 时记 skipped)
#   -> graphics(NVIDIA 驱动与 PRIME,任务 9 交付;脚本不存在时打印提示级消息并记 skipped)。
#   整机目标:能进桌面 + 记录失败项 —— 单模块失败不改变本脚本退出码(始终 0),
#   失败/跳过项在摘要与末尾提示里显式列出。
# 日志:/var/log/dbk/first-boot.log(编排)、/var/log/dbk/<模块>.log(模块自身)、first-boot-summary.txt;
#      日志目录不可写时(非 root,或该目录曾由 sudo 创建)回落到 <TMPDIR>/dbk-<uid>/ 并打印警告;
# 设计依据:docs/05-first-boot.md 步骤 3-6 与设计 4.7 的 R1-R9。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${DBK_LOG:-/var/log/dbk/first-boot.log}"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
source "$HERE/dbk-log.sh"

LOG_DIR="${DBK_LOG_DIR:-/var/log/dbk}"
APPLY=0
UUID="${DBK_SHARED_UUID:-}"
SNAPSHOT_UUID="${DBK_SNAPSHOT_UUID:-}"
TARGET_USER="${DBK_USER:-${SUDO_USER:-${USER:-}}}"
MOD_NAMES=(); MOD_STATES=(); MOD_KEYS=()
F_N=0; S_N=0

usage() { sed -n '2,15p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --uuid) UUID="${2:-}"; shift 2 ;;
    --uuid=*) UUID="${1#*=}"; shift ;;
    --snapshot-uuid) SNAPSHOT_UUID="${2:-}"; shift 2 ;;
    --snapshot-uuid=*) SNAPSHOT_UUID="${1#*=}"; shift ;;
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

# 日志目录:默认 /var/log/dbk;不可写时(通常是非 root,或目录曾被 sudo 创建)回落到临时目录,便于离线演练
# mkdir -p 在目录已存在时返回 0(即使不可写),所以必须再显式判一次 -w,否则摘要根本写不出去
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG_DIR="${TMPDIR:-/tmp}/dbk-$(id -u)"
  mkdir -p "$LOG_DIR" 2>/dev/null
  if [ ! -w "$LOG_DIR" ]; then echo "错误: 无法创建可写日志目录 $LOG_DIR" >&2; exit 1; fi
  echo "警告: 原日志目录不可写(通常因为非 root,或该目录曾由 sudo 创建),日志改落 $LOG_DIR" >&2
fi
LOG="$LOG_DIR/first-boot.log"
SUMMARY="$LOG_DIR/first-boot-summary.txt"
if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then die "--apply 需要 root:sudo bash $0 --apply"; fi

# 记一个模块结果(同时落 DBK-MODULE 行,摘要据此生成)
record_mod() { MOD_NAMES+=("$1"); MOD_STATES+=("$2"); MOD_KEYS+=("$3"); log "DBK-MODULE ${2} ${1} | ${3}"; }

# 跑一个模块:$1=脚本文件名 $2=显示名,其余参数原样传给模块。失败不中断编排(仅记状态)
run_module() {
  local file="$1" name="$2" path mlog state key="" rc=0
  path="$HERE/$file"; shift 2
  if [ ! -f "$path" ]; then record_mod "$name" skipped "脚本不存在:$path"; return; fi
  mlog="$LOG_DIR/${file%.sh}.log"
  log "--- 调用 $name:bash $path $* ---"
  bash "$path" "$@" >>"$mlog" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then state=ok; else state=fail; fi
  # 关键输出:失败模块优先取 DBK-RESULT fail 行(必须在摘要里一眼看到失败原因),否则取模块的结果行,最多两行
  key="$(grep -hE 'DBK-RESULT fail|校验未通过' "$mlog" 2>/dev/null | tail -n 2 \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}[+-][0-9]{4} //' | tr '\n' ';' | sed 's/;$//')"
  [ -n "$key" ] || key="$(grep -hE 'DBK-RESULT|DBK-MODULE|校验通过|校验未通过|完成:|错误|失败' "$mlog" 2>/dev/null | tail -n 2 \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}[+-][0-9]{4} //' | tr '\n' ';' | sed 's/;$//')"
  [ -n "$key" ] || key="$(tail -n 1 "$mlog" 2>/dev/null | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}[+-][0-9]{4} //' || true)"
  record_mod "$name" "$state" "rc=$rc;${key}"
}

if [ "$APPLY" -eq 1 ]; then MODE=(--apply); MODE_NAME=apply; else MODE=(--dry-run); MODE_NAME=dry-run; fi
log "=== 首启编排开始(mode=$MODE_NAME;日志目录 $LOG_DIR)==="
run_module storage.sh storage "${MODE[@]}"
run_module hardening.sh hardening "${MODE[@]}"
if [ -n "$UUID" ]; then
  shared_args=("${MODE[@]}" --uuid "$UUID")
  [ -z "$TARGET_USER" ] || shared_args+=(--user "$TARGET_USER")
  [ -z "$SNAPSHOT_UUID" ] || shared_args+=(--snapshot-uuid "$SNAPSHOT_UUID")
  run_module mount-shared.sh mount-shared "${shared_args[@]}"
else
  record_mod mount-shared skipped "缺少 --uuid/DBK_SHARED_UUID:共享盘与 D: 文档目录暂不可用(见 docs/05-first-boot.md 步骤 3)"
fi
# R1/R2 的前置是 /snapshots 已挂载,而 hardening 在 mount-shared 之前跑 —— 提示级提醒,不改进程退出码
if [ "$APPLY" -eq 1 ]; then
  log "提示: hardening 先于 mount-shared 运行,首次 --apply 时 /snapshots 通常未挂载(R1/R2 记 fail 属预期);mount-shared 记 ok 后请复跑:sudo bash scripts/linux/hardening.sh --apply"
fi
if [ -f "$HERE/graphics.sh" ]; then
  run_module graphics.sh graphics "${MODE[@]}"
else
  record_mod graphics skipped "graphics.sh 未交付(任务 9):NVIDIA 驱动与 PRIME 未配置;装驱动前先做 R1 快照"
fi

# 统计失败/跳过项:与摘要写出解耦 —— 摘要写不出去时也要给出正确的失败项数量
count_states() {
  local i; F_N=0; S_N=0
  for i in "${!MOD_STATES[@]}"; do
    if [ "${MOD_STATES[$i]}" = fail ]; then F_N=$((F_N+1)); fi
    if [ "${MOD_STATES[$i]}" = skipped ]; then S_N=$((S_N+1)); fi
  done
}

# 写摘要:先写 <SUMMARY>.new 再原子替换;失败时明确报错并且不读旧摘要充数(返回非 0)
write_summary() {
  local i mode=dry-run
  [ "$APPLY" -eq 1 ] && mode=apply
  if ! {
    printf '# L4 首启摘要(模块 / 状态 / 关键输出)\n'
    printf '时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')"
    printf '主机: %s  内核: %s  模式: %s  日志目录: %s\n' "$(uname -n)" "$(uname -r)" "$mode" "$LOG_DIR"
    printf '\n%s | %s | %s\n' '模块' '状态' '关键输出'
    for i in "${!MOD_NAMES[@]}"; do
      printf '%s | %s | %s\n' "${MOD_NAMES[$i]}" "${MOD_STATES[$i]}" "${MOD_KEYS[$i]}"
    done
    printf '\n失败项: %s;跳过项: %s;模块总数: %s\n' "$F_N" "$S_N" "${#MOD_NAMES[@]}"
    printf '失败模块: '
    for i in "${!MOD_NAMES[@]}"; do
      if [ "${MOD_STATES[$i]}" = fail ]; then printf '%s ' "${MOD_NAMES[$i]}"; fi
    done
    printf '\n结论: 单模块失败不改变整体退出码(本脚本退出码固定 0);失败项见上表,按各模块日志修正后可单独重跑。\n'
  } >"$SUMMARY.new" 2>/dev/null; then
    log "错误: 摘要未写出(无法创建 $SUMMARY.new,检查 $LOG_DIR 是否可写)"
    return 1
  fi
  if ! mv -f "$SUMMARY.new" "$SUMMARY" 2>/dev/null; then
    log "错误: 摘要未写出(无法用 $SUMMARY.new 替换 $SUMMARY)"
    return 1
  fi
  log "摘要 $SUMMARY:"
  while IFS= read -r line; do log "  $line"; done <"$SUMMARY"
  return 0
}

count_states
SUMMARY_OK=1
write_summary || SUMMARY_OK=0
if [ "$SUMMARY_OK" -ne 1 ]; then
  log "=== 首启结束:失败 $F_N 项、跳过 $S_N 项;摘要未写出(见上面错误行),请直接看各模块日志 $LOG_DIR/<模块>.log ==="
elif [ "$F_N" -gt 0 ]; then
  log "=== 首启结束:失败 $F_N 项、跳过 $S_N 项(详见 $SUMMARY);失败项不阻塞登录,进桌面后按各模块日志逐个处理 ==="
else
  log "=== 首启结束:无失败项、跳过 $S_N 项(详见 $SUMMARY)==="
fi
if [ "$APPLY" -ne 1 ]; then
  log "提示: 本次是 dry-run,未改动系统;确认无误后加 --apply(sudo)重跑:sudo bash scripts/linux/first-boot.sh --apply --uuid <SHARED_PART_UUID>"
fi
exit 0
