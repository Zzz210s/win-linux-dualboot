#!/usr/bin/env bash
# 对应卡:05-13
# 破坏性:1(会逐模块写 fstab/user-dirs.dirs、装包、起服务、装驱动:--apply 必须显式 --yes)
# L4 首启编排器:依次调用 storage.sh、hardening.sh、mount-shared.sh、graphics.sh,
# 每模块单独落日志,末尾生成 /var/log/dbk/first-boot-summary.txt(模块 / 状态 / 关键输出)。
#
# 用法:bash scripts/linux/first-boot.sh [--check|--apply --yes] [--uuid <SHARED_PART_UUID>] [--user <name>] [--log-dir <dir>]
#   缺省(或 --check)是 dry-run:各模块以 --check 调用,只判定不改动系统;--apply(需要 root)才真正改系统,
#   且必须同时给 --yes(全仓契约:声明「# 破坏性:1」的脚本,--apply 缺 --yes 一律 64 且零写),并给模块统一透传 --yes。
#   模块顺序:storage(交换空间与 zram)-> hardening(健壮性 R1-R9)-> mount-shared(共享盘挂载 + 家目录重定向;
#   缺 --uuid 时记 skipped)-> graphics(NVIDIA 驱动与 Wayland/PRIME 核对);脚本文件缺失的模块打印提示级消息并记 skipped。
#   整机目标:能进桌面 + 记录失败项 —— 单模块失败不改变本脚本退出码(始终 0),失败/跳过项在摘要末尾显式列出。
#   注意:R1/R2(备份 baseline 与包级回退)在 hardening 里只读核对;mount-shared 失败不阻塞登录。
# 日志:/var/log/dbk/first-boot.log(编排)、/var/log/dbk/<模块>.log(本脚本重定向的模块输出)、first-boot-summary.txt;
#   日志目录不可写时(非 root,或该目录曾由 sudo 创建)回落 <TMPDIR>/dbk-<uid>/ 并打印警告。
# 设计依据:docs/design/04-kubuntu-variant-design.md 第 2 节(D4 回滚降级为包级回退 + 原地重装、D5 分区表 8 项)
#   与第 7 节(R1-R9 的替代方案);docs/design/00-design.md 4.7 的 R1-R9。
# 本脚本是逐项汇总型,不得 set -e。夹具级验证,真机未跑。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${DBK_LOG:-/var/log/dbk/first-boot.log}"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
source "$HERE/dbk-log.sh"

LOG_DIR="${DBK_LOG_DIR:-/var/log/dbk}"
APPLY=0; YES=0
UUID="${DBK_SHARED_UUID:-}"
TARGET_USER="${DBK_USER:-${SUDO_USER:-${USER:-}}}"
MOD_NAMES=(); MOD_STATES=(); MOD_KEYS=()
F_N=0; S_N=0

usage() { sed -n '2,15p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --check|--dry-run) APPLY=0; shift ;;
    --yes|-y) YES=1; shift ;;
    --uuid) need_val "$#" "--uuid" "<SHARED_PART_UUID>"; UUID="$2"; shift 2 ;;
    --uuid=*) UUID="${1#*=}"; shift ;;
    --user) need_val "$#" "--user" "<用户名>"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --log-dir) need_val "$#" "--log-dir" "<日志目录>"; LOG_DIR="$2"; shift 2 ;;
    --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

# 破坏性门槛(与 dbk-cli.sh 同口径):带 --apply 必须显式 --yes,否则 64 且零写。
if [ "$APPLY" -eq 1 ] && [ "$YES" -ne 1 ]; then
  usage
  echo "用法错误: 脚本头声明了「# 破坏性:1」,--apply 必须显式给 --yes(本脚本会逐模块写 fstab/user-dirs.dirs、装包、起服务)" >&2
  exit 64
fi

# 日志目录:默认 /var/log/dbk;不可写时(通常是非 root,或目录曾被 sudo 创建)回落到临时目录,便于离线演练。
# mkdir -p 在目录已存在时返回 0(即使不可写),所以必须再显式判一次 -w,否则摘要根本写不出去。
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

# 剥掉 dbk-log.sh 的日期前缀,摘要里只留人读文本
strip_ts() { sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}[+-][0-9]{4} //'; }

# 跑一个模块:$1=脚本文件名 $2=显示名 $3=脚本缺失时的提示;其余参数原样传给模块。失败不中断编排(仅记状态)
run_module() {
  local file="$1" name="$2" hint="$3" path mlog state key="" rc=0 before=0 slice
  path="$HERE/$file"; shift 3
  if [ ! -f "$path" ]; then record_mod "$name" skipped "脚本不存在:$path;$hint"; return; fi
  mlog="$LOG_DIR/${file%.sh}.log"
  [ -f "$mlog" ] && before="$(wc -l <"$mlog")"
  log "--- 调用 $name:bash $path $* ---"
  bash "$path" "$@" >>"$mlog" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then state=ok; else state=fail; fi
  # 关键输出:只在"本次新增的输出区间"里取。日志是 >> 追加写入,直接 grep 会把上一次运行的陈旧失败行也抓进来。
  slice="$(tail -n "+$((before + 1))" "$mlog" 2>/dev/null || true)"
  key="$(printf '%s\n' "$slice" | grep -hE '^\[FAIL\]|^\[需人工\]' | tail -n 2 | strip_ts | tr '\n' ';' | sed 's/;$//')"
  [ -n "$key" ] || key="$(printf '%s\n' "$slice" | grep -hE 'DBK-RESULT fail' | tail -n 2 | strip_ts | tr '\n' ';' | sed 's/;$//')"
  [ -n "$key" ] || key="$(printf '%s\n' "$slice" | grep -hE 'DBK-RESULT|\[PASS\]|完成:|错误|失败' | tail -n 2 | strip_ts | tr '\n' ';' | sed 's/;$//')"
  [ -n "$key" ] || key="$(printf '%s\n' "$slice" | tail -n 1 | strip_ts || true)"
  record_mod "$name" "$state" "rc=$rc;${key}"
}

# 模块调用参数:dry-run 给 --check;apply 给 --apply --yes(契约要求破坏性动作显式确认,由编排器统一透传)
if [ "$APPLY" -eq 1 ]; then MODE=(--apply --yes); MODE_NAME=apply; else MODE=(--check); MODE_NAME="check(dry-run)"; fi
log "=== 首启编排开始(mode=$MODE_NAME;日志目录 $LOG_DIR)==="
run_module storage.sh storage "仓库文件缺失;交换空间与 zram 未核对" "${MODE[@]}"
run_module hardening.sh hardening "仓库文件缺失;健壮性 R1-R9 未落地" "${MODE[@]}"
if [ -n "$UUID" ]; then
  shared_args=("${MODE[@]}" --uuid "$UUID")
  [ -z "$TARGET_USER" ] || shared_args+=(--user "$TARGET_USER")
  run_module mount-shared.sh mount-shared "仓库文件缺失" "${shared_args[@]}"
else
  record_mod mount-shared skipped "缺少 --uuid/DBK_SHARED_UUID:共享盘与 D: 文档目录暂不可用(见 docs/05-first-boot.md 步骤 1)"
fi
run_module graphics.sh graphics "仓库文件缺失;NVIDIA 驱动与 Wayland/PRIME 未核对,需按手册手工收敛" "${MODE[@]}"

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
  local i mode=check
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
    printf '\n结论: 单模块失败不改变整体退出码(本脚本退出码固定 0);R1/R2(备份与包级回退)由 hardening 只读核对;'
    printf '失败项见上表,按各模块日志修正后可单独重跑。\n'
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
  log "提示: 本次是 check(dry-run),未改动系统;确认无误后加 --apply(sudo)重跑:sudo bash scripts/linux/first-boot.sh --apply --uuid <SHARED_PART_UUID>"
fi
exit 0
