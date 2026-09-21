#!/usr/bin/env bash
# 总控入口(Fedora 侧,非步骤脚本):读步骤索引 scripts/linux/steps.tsv,分发到步骤脚本并汇总结果。
# 契约真源:docs/design/03-step-automation-design.md 第 5 节(总控入口)与第 2 节(CLI/退出码/2.1 可观测性)。
# 只做分发与汇总,不含业务逻辑:校验步骤号与索引脚本存在 → 透传 --check/--apply/--yes/--json/--log → 汇总。
# 破坏性步骤(索引第 3 列 = 1)在 --apply 且未给 --yes 时**不调用子脚本**,按用法错误退 64;汇总规则:
#   任一子步骤 1 → 1;无 1 但有 2 → 2;其余(0/9)→ 0;未知步骤或索引脚本缺失 → 64。
# 一张卡可以对应多个脚本(设计 03 第 5 节):同一步骤号在索引里允许出现多行,总控**按行顺序逐行执行**
#   并把它们的退出码一起聚合(行顺序 = 索引行顺序);破坏性门槛也逐行判定(任一行是破坏性就需 --yes)。
# 可观测性(设计 2.1 O1/O2):每个子步骤的 步骤号/退出码/状态/失败原因都要打印;有失败时把完整汇总写
#   --log(缺省沿用 dbk_log_default 的 /var/log/dbk/dbk.log),失败行同时进 stderr,JSON 汇总含 message。
# 汇总 JSON:{"steps":[{"step":…,"status":pass|fail|manual|skip,"rc":N,"message":…}],"summary":{pass,fail,manual,skip}}
# 本文件是 C9d 白名单里的库/总控脚本(不写「# 对应卡:」,也不登记进 steps.tsv)。测试钩子:DBK_INDEX 覆盖索引。
set -uo pipefail
DBK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBK_ROOT="$(cd "$DBK_DIR/../.." && pwd)"
DBK_INDEX="${DBK_INDEX:-$DBK_DIR/steps.tsv}"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$DBK_DIR/dbk-cli.sh"
DBK_MASTER_MODE=check; DBK_MASTER_JSON=0; DBK_MASTER_YES=0; DBK_MASTER_LOG=""
S_IDS=(); S_KEYS=(); S_RCS=(); S_MSGS=()
P_STEPS=(); P_PATHS=()

# 索引里的全部步骤号(用法信息用)。
dbk_index_ids() {
  local id path dest desc
  [ -r "$DBK_INDEX" ] || return 0
  while IFS=$'\t' read -r id path dest desc || [ -n "${id:-}" ]; do
    case "$id" in [0-9][0-9]-[0-9]*) printf '%s ' "$id" ;; esac
  done <"$DBK_INDEX"
}
dbk_usage_master() {
  cat >&2 <<EOF
用法: scripts/linux/dbk.sh <步骤号> [<步骤号>…] [--check] [--apply] [--yes] [--json] [--log <路径>]
  读步骤索引分发到对应步骤脚本,汇总每个子步骤的退出码与结论(总控不含业务逻辑)。
  --check 缺省(只读);--apply 执行(破坏性步骤必须同时给 --yes);--json 输出单行汇总 JSON。
  索引: $DBK_INDEX
  可用步骤号: $(dbk_index_ids)
退出码: 0 全部通过 / 1 有失败 / 2 有需人工 / 64 用法错误(未知步骤、索引脚本缺失、破坏性步骤缺 --yes)
EOF
}
dbk_parse_master_args() {
  local seen_check=0 seen_apply=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) seen_check=1; shift ;;
      --apply) seen_apply=1; shift ;;
      --json) DBK_MASTER_JSON=1; shift ;;
      --yes|-y) DBK_MASTER_YES=1; shift ;;
      --log) dbk_cli_val "--log" "${2:-}"; DBK_MASTER_LOG="$2"; DBK_LOG="$2"; shift 2 ;;
      -h|--help) dbk_usage_master; exit "$DBK_PASS" ;;
      --*) dbk_usage_master; dbk_note "用法错误: 未知参数 $1"; exit "$DBK_USAGE" ;;
      *) S_IDS+=("$1"); shift ;;
    esac
  done
  if [ "$seen_check" -eq 1 ] && [ "$seen_apply" -eq 1 ]; then
    dbk_usage_master; dbk_note "用法错误: --check 与 --apply 互斥,只能给一个"; exit "$DBK_USAGE"
  fi
  if [ "$seen_apply" -eq 1 ]; then DBK_MASTER_MODE=apply; fi
  if [ "${#S_IDS[@]}" -eq 0 ]; then dbk_usage_master; dbk_note "用法错误: 未给步骤号"; exit "$DBK_USAGE"; fi
}
# dbk_index_rows <步骤号>:打印该步骤号在索引里的**全部**「<脚本路径>|<破坏性>」行(按文件顺序,一行一对)。
# 一张卡可以对应多个脚本,故同一步骤号允许多行;一行也没取到时返回非零。
dbk_index_rows() {
  local want="$1" id path dest desc found=1
  while IFS=$'\t' read -r id path dest desc || [ -n "${id:-}" ]; do
    case "$id" in
      [0-9][0-9]-[0-9]*) if [ "$id" = "$want" ]; then printf '%s|%s\n' "$path" "$dest"; found=0; fi ;;
    esac
  done <"$DBK_INDEX"
  return "$found"
}
# dbk_prepare:先把全部步骤的全部索引行校验完再跑,任何一条不合格 → 64 且零调用。
dbk_prepare() {
  local i step path dest abs n
  for i in "${!S_IDS[@]}"; do
    step="${S_IDS[$i]}"; n=0
    while IFS='|' read -r path dest; do
      [ -n "${path:-}" ] || continue
      n=$((n + 1))
      case "$path" in /*) abs="$path" ;; *) abs="$DBK_ROOT/$path" ;; esac
      if [ ! -f "$abs" ]; then
        dbk_note "用法错误: 索引里声明的脚本不存在: $path(步骤 $step,解析为 $abs)"; exit "$DBK_USAGE"
      fi
      if [ "$dest" = 1 ] && [ "$DBK_MASTER_MODE" = apply ] && [ "$DBK_MASTER_YES" -ne 1 ]; then
        dbk_note "用法错误: 破坏性步骤 $step 的 --apply 必须显式给 --yes;未调用任何子脚本"
        dbk_note "影响:该步骤会改动系统状态;确认无误后加 --yes 重跑。"; exit "$DBK_USAGE"
      fi
      P_STEPS+=("$step"); P_PATHS+=("$abs")
    done < <(dbk_index_rows "$step")
    if [ "$n" -eq 0 ]; then
      dbk_usage_master; dbk_note "用法错误: 未知步骤 $step(索引 $DBK_INDEX 里没有这一行)"; exit "$DBK_USAGE"
    fi
  done
}
dbk_step_key() { case "${1:-}" in 0) printf pass ;; 1) printf fail ;; 2) printf manual ;; 9) printf skip ;; *) printf fail ;; esac; }
# JSON 反转义(与 dbk-log.sh 的 dbk_json_escape 互逆):从子脚本的 --json 里取 message。
dbk_json_unescape() {
  local s="${1:-}"
  s="${s//\\n/$'\n'}"; s="${s//\\t/$'\t'}"; s="${s//\\r/$'\r'}"; s="${s//\\\"/\"}"; s="${s//\\\\/\\}"
  printf '%s' "$s"
}
# dbk_child_message <子脚本 stdout> <是否 JSON 模式>:取结论/失败原因文本(不依赖 jq/python)。
#   契约输出的 JSON 里取 message(可能是空串,交给上层合成);不是契约输出时退回 stdout 的最后一行。
dbk_child_message() {
  local s="${1:-}" v=""
  if [ "${2:-0}" -eq 1 ]; then
    case "$s" in
      *'"message":"'*)
        v="${s#*\"message\":\"}"
        case "$v" in *'","checks":['*) v="${v%%\",\"checks\":[*}" ;; *) v="" ;; esac
        dbk_json_unescape "$v"; return 0 ;;
    esac
  fi
  v="$(printf '%s\n' "$s" | grep -v '^[[:space:]]*$' | tail -n1 || true)"
  case "$v" in \[*\]\ *) v="${v#*] }" ;; esac
  printf '%s' "$v"
}
# dbk_step_line <步骤号> <状态键> <退出码> <原因>:汇总的每一行(打印与落盘共用同一格式)。
dbk_step_line() {
  if [ -n "${4:-}" ]; then printf '[%s] %s rc=%s %s' "$(dbk_status_tag "$2")" "$1" "$3" "$4"
  else printf '[%s] %s rc=%s' "$(dbk_status_tag "$2")" "$1" "$3"; fi
}
dbk_run_one() {
  local i="$1" step="${P_STEPS[$1]}" abs="${P_PATHS[$1]}" rc=0 key msg out args=()
  if [ "$DBK_MASTER_MODE" = apply ]; then args+=(--apply); else args+=(--check); fi
  [ "$DBK_MASTER_YES" -eq 1 ] && args+=(--yes)
  [ "$DBK_MASTER_JSON" -eq 1 ] && args+=(--json)
  [ -n "$DBK_MASTER_LOG" ] && args+=(--log "$DBK_MASTER_LOG")
  # 只捕获 stdout(JSON 模式要保干净);stderr 继承到本进程,失败信息照旧可见(不吞 stderr)。
  out="$(bash "$abs" ${args[@]+"${args[@]}"})" || rc=$?
  key="$(dbk_step_key "$rc")"
  msg="$(dbk_child_message "$out" "$DBK_MASTER_JSON")"
  case "$rc" in
    0|1|2|9) ;;
    *) key=fail
       if [ -n "$msg" ]; then msg="$msg; 子步骤退出码 $rc 不在 0/1/2/9 契约内"; else msg="子步骤退出码 $rc 不在 0/1/2/9 契约内"; fi ;;
  esac
  if [ -z "$msg" ] && { [ "$key" = fail ] || [ "$key" = manual ]; }; then msg="子步骤未给出原因文本(退出码 $rc)"; fi
  S_KEYS[$i]="$key"; S_RCS[$i]="$rc"; S_MSGS[$i]="$msg"
  if [ "$DBK_MASTER_JSON" -ne 1 ]; then
    [ -n "$out" ] && printf '%s\n' "$out"
    dbk_step_line "$step" "$key" "$rc" "$msg"; printf '\n'
  fi
  if [ "$key" = fail ] || [ "$key" = manual ]; then dbk_note "$(dbk_step_line "$step" "$key" "$rc" "$msg")"; fi
}
# dbk_count <状态键>:按已收集结果统计数量(汇总与退出码判定共用)。
dbk_count() {
  local k n=0
  for k in ${S_KEYS[@]+"${S_KEYS[@]}"}; do [ "$k" = "$1" ] && n=$((n + 1)); done
  printf '%s' "$n"
}
# 有失败/需人工时把完整汇总(每个子步骤一行 + 总计)写进日志;全绿不落盘。
dbk_log_summary() {
  local i
  dbk_log_write "汇总: pass=$(dbk_count pass) fail=$(dbk_count fail) manual=$(dbk_count manual) skip=$(dbk_count skip)"
  for i in "${!P_STEPS[@]}"; do
    dbk_log_write "$(dbk_step_line "${P_STEPS[$i]}" "${S_KEYS[$i]}" "${S_RCS[$i]}" "${S_MSGS[$i]}")"
  done
}
dbk_emit_summary_json() {
  local i sep=""
  printf '{"steps":['
  for i in "${!P_STEPS[@]}"; do
    printf '%s{"step":"%s","status":"%s","rc":%s,"message":"%s"}' "$sep" \
      "$(dbk_json_escape "${P_STEPS[$i]}")" "${S_KEYS[$i]}" "${S_RCS[$i]}" "$(dbk_json_escape "${S_MSGS[$i]}")"
    sep=,
  done
  printf '],"summary":{"pass":%s,"fail":%s,"manual":%s,"skip":%s}}\n' \
    "$(dbk_count pass)" "$(dbk_count fail)" "$(dbk_count manual)" "$(dbk_count skip)"
}

dbk_parse_master_args "$@"
if [ ! -r "$DBK_INDEX" ]; then dbk_note "用法错误: 步骤索引不可读: $DBK_INDEX"; exit "$DBK_USAGE"; fi
dbk_prepare
dbk_log_default dbk   # 缺省日志路径(显式给 --log 时不动);只有失败路径才真的落盘
i=0
while [ "$i" -lt "${#P_STEPS[@]}" ]; do dbk_run_one "$i"; i=$((i + 1)); done
N_FAIL="$(dbk_count fail)"; N_MANUAL="$(dbk_count manual)"
if [ "$N_FAIL" -gt 0 ] || [ "$N_MANUAL" -gt 0 ]; then dbk_log_summary; fi
if [ "$DBK_MASTER_JSON" -eq 1 ]; then
  dbk_emit_summary_json
elif [ "$N_FAIL" -gt 0 ] || [ "$N_MANUAL" -gt 0 ]; then
  printf '[汇总] pass=%s fail=%s manual=%s skip=%s\n' "$(dbk_count pass)" "$N_FAIL" "$N_MANUAL" "$(dbk_count skip)"
fi
if [ "$N_FAIL" -gt 0 ]; then exit "$DBK_FAIL"; fi
if [ "$N_MANUAL" -gt 0 ]; then exit "$DBK_MANUAL"; fi
exit "$DBK_PASS"
