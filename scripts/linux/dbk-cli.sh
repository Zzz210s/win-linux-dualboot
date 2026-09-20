#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:步骤脚本的统一 CLI 契约(Linux/Fedora 侧):参数解析、退出码常量、报告与 JSON 汇总。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(CLI 与退出码)、第 7 节(夹具要求)。
# 用法(步骤脚本自己 set -euo pipefail 后 source 本文件,再依次调用):
#   dbk_parse_args "$@"  →  DBK_MODE(check|apply)/DBK_JSON/DBK_YES/DBK_LOG/DBK_STEP
#   dbk_assert_step      →  与脚本头「# 对应卡:NN-K」比对,不一致 → 64
#   判据与动作:dbk_add_check "…";仅 --apply 分支里:dbk_need_yes "动作" "命令" → 执行 → dbk_add_action/dbk_mark_changed
#   dbk_exit PASS|FAIL|需人工|跳过 "说明"   →  打印报告并以 0/1/2/9 结束
# 输出:文本模式行首 `[PASS]`/`[FAIL]`/`[需人工]`/`[跳过]`;`--json` 时只有 dbk_exit 写 stdout(单行 JSON),
#   其余人读信息一律走 dbk_note(写 stderr)。dbk_need_yes 只在 --apply 分支调用:--check 不写系统状态。
# 只读保证:本文件只定义函数与常量,不写任何路径(只有显式 --log 才把路径记进 DBK_LOG 与 LOG)。
# 夹具级验证,真机未跑。依赖 dbk-log.sh(need_val/log/dbk_json_escape),由本文件自行 source。
set -euo pipefail

DBK_PASS=0
DBK_FAIL=1
DBK_MANUAL=2
DBK_SKIP=9
DBK_USAGE=64

# 解析结果在这里预置默认值,避免调用方漏调 dbk_parse_args 时踩 set -u。
DBK_MODE=check
DBK_JSON=0
DBK_YES=0
DBK_LOG=""
DBK_STEP=""
DBK_LAST_STATUS=""
DBK_CHANGED=0
DBK_CHECKS=()
DBK_ACTIONS=()

DBK_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-log.sh disable=SC1091
. "$DBK_CLI_DIR/dbk-log.sh"

# 人读信息一律走 stderr(保证 --json 模式下 stdout 只有 dbk_exit 的单行 JSON)。
dbk_note() { printf '%s\n' "$*" >&2; }

dbk_usage() {
  cat >&2 <<'EOF'
用法: <脚本> [--check] [--apply] [--json] [--log <路径>] [--yes] [--step <NN-K>]
  --check  只读判定本步是否达成(缺省;不写任何系统状态)
  --apply  执行本步(幂等;破坏性动作需要 --yes)
  --json   机器可读输出;--log <路径> 日志路径(缺省不落盘,由脚本自己决定何时写)
  --yes    破坏性动作必需;缺省时打印将执行的命令与影响并以 64 退出
  --step <NN-K> 显式声明卡号;与脚本头「# 对应卡:」不一致 → 64;-h|--help 打印本用法
退出码: 0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误
EOF
}

# 解析命令行:--check 与 --apply 互斥;未知参数、缺参、空取值都是用法错误(64)。
dbk_parse_args() {
  local seen_check=0 seen_apply=0
  DBK_CHECKS=(); DBK_ACTIONS=(); DBK_CHANGED=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) seen_check=1; shift ;;
      --apply) seen_apply=1; shift ;;
      --json) DBK_JSON=1; shift ;;
      --yes|-y) DBK_YES=1; shift ;;
      --log)
        need_val "$#" "--log" "<日志路径,如 /var/log/dbk/x.log>" "${2:-}"
        DBK_LOG="$2"; LOG="$DBK_LOG"; shift 2 ;;
      --step)
        need_val "$#" "--step" "<卡号,如 05-1>" "${2:-}"
        DBK_STEP="$2"; shift 2 ;;
      -h|--help) dbk_usage; exit "$DBK_PASS" ;;
      *) dbk_usage; dbk_note "用法错误: 未知参数 $1"; exit "$DBK_USAGE" ;;
    esac
  done
  if [ "$seen_check" -eq 1 ] && [ "$seen_apply" -eq 1 ]; then
    dbk_usage; dbk_note "用法错误: --check 与 --apply 互斥,只能给一个"; exit "$DBK_USAGE"
  fi
  if [ "$seen_apply" -eq 1 ]; then DBK_MODE=apply; else DBK_MODE=check; fi
  return 0
}

# dbk_assert_step [脚本头声明的卡号]
#   不给参数时从调用本函数的脚本文件头读「# 对应卡:NN-K」(BASH_SOURCE[1]);
#   --step 给过且与声明不一致 → 64;两处都取不到卡号 → 64(步骤脚本必须有卡头)。
dbk_assert_step() {
  local declared="${1:-}" caller
  if [ -z "$declared" ]; then
    caller="${BASH_SOURCE[1]:-}"
    if [ -n "$caller" ] && [ -r "$caller" ]; then
      declared="$(grep -m1 -oE '^#[[:space:]]*(对应卡|Card):[[:space:]]*[0-9][0-9]-[0-9]+' "$caller" \
        | grep -oE '[0-9][0-9]-[0-9]+' || true)"
    fi
  fi
  if [ -z "$declared" ]; then
    dbk_note "用法错误: 取不到「# 对应卡:NN-K」,无法确认本脚本服务的卡"
    exit "$DBK_USAGE"
  fi
  if [ -n "$DBK_STEP" ] && [ "$DBK_STEP" != "$declared" ]; then
    dbk_note "用法错误: --step $DBK_STEP 与脚本头声明的卡号 $declared 不一致"
    exit "$DBK_USAGE"
  fi
  DBK_STEP="$declared"
  return 0
}

# dbk_need_yes <动作描述> [将执行的命令...]
#   未给 --yes → 打印动作、将执行的命令与影响并退出 64(调用点之前不做任何改动 → 零写)。
dbk_need_yes() {
  local desc="${1:-}" cmd
  shift || true
  [ "$DBK_YES" -eq 1 ] && return 0
  dbk_note "破坏性动作:$desc"
  if [ "$#" -gt 0 ]; then
    dbk_note "将执行的命令:"
    for cmd in "$@"; do dbk_note "  $cmd"; done
  fi
  dbk_note "影响:该动作会改动系统状态;确认无误后加 --yes 重跑(缺 --yes 时脚本不做任何改动)。"
  exit "$DBK_USAGE"
}

dbk_add_check() { DBK_CHECKS+=("${1:-}"); }
dbk_add_action() { DBK_ACTIONS+=("${1:-}"); }
dbk_mark_changed() { DBK_CHANGED=1; }

# 状态归一:PASS/FAIL/需人工/跳过(英文 pass/fail/manual/skip 也认);未知状态返回非零。
dbk_status_key() {
  case "${1:-}" in
    PASS|pass|通过) printf 'pass' ;;
    FAIL|fail|不通过) printf 'fail' ;;
    需人工|人工|manual) printf 'manual' ;;
    跳过|skip) printf 'skip' ;;
    *) return 1 ;;
  esac
}

dbk_status_code() {
  case "${1:-}" in
    pass) printf '%s' "$DBK_PASS" ;;
    fail) printf '%s' "$DBK_FAIL" ;;
    manual) printf '%s' "$DBK_MANUAL" ;;
    skip) printf '%s' "$DBK_SKIP" ;;
    *) printf '%s' "$DBK_USAGE" ;;
  esac
}

# dbk_json_array <元素...>:拼成 JSON 字符串数组(空 → 空),元素经 dbk_json_escape 转义。
dbk_json_array() {
  local sep="" x out=""
  for x in "$@"; do out="$out$sep\"$(dbk_json_escape "$x")\""; sep=,; done
  printf '%s' "$out"
}

# JSON 汇总(单行):{"step":…,"status":…,"checks":[…],"actions":[…],"changed":true|false}
dbk_emit_json() {
  printf '{"step":"%s","status":"%s","checks":[%s],"actions":[%s],"changed":%s}\n' \
    "$(dbk_json_escape "${1:-}")" "${2:-}" \
    "$(dbk_json_array ${DBK_CHECKS[@]+"${DBK_CHECKS[@]}"})" \
    "$(dbk_json_array ${DBK_ACTIONS[@]+"${DBK_ACTIONS[@]}"})" \
    "$([ "$DBK_CHANGED" -eq 1 ] && printf true || printf false)"
}

# dbk_report <PASS|FAIL|需人工|跳过> <说明>
#   文本模式打印 `[PASS] 说明` 及判据/动作清单;JSON 模式打印单行 JSON。只打印,不改退出码。
dbk_report() {
  local status="${1:-}" msg="${2:-}" key tag x
  key="$(dbk_status_key "$status")" || {
    dbk_note "用法错误: 未知状态 $status(只认 PASS/FAIL/需人工/跳过 或 pass/fail/manual/skip)"
    exit "$DBK_USAGE"
  }
  DBK_LAST_STATUS="$key"
  if [ "$DBK_JSON" -eq 1 ]; then
    dbk_emit_json "$DBK_STEP" "$key"
    return 0
  fi
  case "$key" in
    pass) tag=PASS ;;
    fail) tag=FAIL ;;
    manual) tag=需人工 ;;
    skip) tag=跳过 ;;
  esac
  printf '[%s] %s\n' "$tag" "$msg"
  for x in "${DBK_CHECKS[@]}"; do printf '  - %s\n' "$x"; done
  for x in "${DBK_ACTIONS[@]}"; do printf '  > %s\n' "$x"; done
  return 0
}

# dbk_exit <状态> <说明>:报告后以对应退出码结束(0 PASS / 1 FAIL / 2 需人工 / 9 跳过)。
dbk_exit() {
  dbk_report "${1:-}" "${2:-}"
  exit "$(dbk_status_code "$DBK_LAST_STATUS")"
}
