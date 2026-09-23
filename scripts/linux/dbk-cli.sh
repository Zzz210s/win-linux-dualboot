#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:步骤脚本的统一 CLI 契约(Linux/Kubuntu 侧):参数解析、卡号断言、破坏性门槛、退出码常量。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(CLI、退出码、可观测性)与第 7 节(夹具要求)。
# 用法(步骤脚本自己 set -euo pipefail 后 source 本文件,再依次调用):
#   dbk_parse_args "$@" → DBK_MODE/DBK_JSON/DBK_YES/DBK_LOG/DBK_STEP;dbk_assert_step → 与脚本头卡号集合比对(不一致 → 64)
#   判据与动作:dbk_add_check "…";仅 --apply 分支里:dbk_need_yes "动作" "命令" → 执行 → dbk_add_action/dbk_mark_changed
#   dbk_exit PASS|FAIL|需人工|跳过 "说明"   →  打印报告并以 0/1/2/9 结束
# 脚本头声明:「# 对应卡:NN-K[,NN-K…]」(一脚本服务多张卡用逗号列表);破坏性脚本另写「# 破坏性:1」——
#   声明后 --apply 缺 --yes 由库层直接拒(64),不靠作者记得调 dbk_need_yes。dbk_assert_step 必须由步骤脚本
#   **顶层直接调用**:它靠 BASH_SOURCE[1] 定位调用方文件头。
# 输出与 JSON 由 dbk-obs.sh 提供(本文件 source 它);--json 时 stdout 只有 dbk_exit/dbk_on_err 的一行 JSON。
# 只读保证:本文件只定义函数与常量;参数错误一律打印用法到 stderr 并 exit 64,不落盘、不经 dbk-log.sh 的 die()
#   (那是 L4 脚本的退 1 语义);只有显式 --log(或调过 dbk_log_default)才记路径,且只在失败路径追加日志。
# 本文件不设置 shell 选项:失败必须中断的步骤脚本自己 set -e;失败不中断的脚本(hardening.sh/first-boot.sh)不得 set -e。
# 夹具级验证,真机未跑。依赖 dbk-log.sh(die/need_val/dbk_json_escape)与 dbk-obs.sh(报告/JSON/errtrap)。

DBK_PASS=0
DBK_FAIL=1
DBK_MANUAL=2
DBK_SKIP=9
DBK_USAGE=64

# 解析结果与状态在这里预置默认值,避免调用方漏调 dbk_parse_args 时踩 set -u。
DBK_MODE=check
DBK_JSON=0
DBK_YES=0
DBK_LOG=""
DBK_STEP=""
DBK_LAST_STATUS=""
DBK_CHANGED=0
DBK_CHECKS=()
DBK_CHECKS_JSON=()
DBK_ACTIONS=()
DBK_ERRTRAP=0

# 脚本头里的「#」前可能有 UTF-8 BOM(.ps1 必须带;.sh 允许)。本常量与 scripts/repo/check-docs-lib.sh 的
# BOM/CARDRE 必须保持一致,否则库与仓库自检(C9b)对同一个脚本头会得出不同结论。
DBK_BOM="$(printf '\xef\xbb\xbf')"

DBK_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-log.sh disable=SC1091
. "$DBK_CLI_DIR/dbk-log.sh"
# shellcheck source=scripts/linux/dbk-obs.sh disable=SC1091
. "$DBK_CLI_DIR/dbk-obs.sh"

dbk_usage() {
  cat >&2 <<'EOF'
用法: <脚本> [--check] [--apply] [--json] [--log <路径>] [--yes] [--step <NN-K>]
  --check  只读判定本步是否达成(缺省;不写任何系统状态)
  --apply  执行本步(幂等;破坏性动作需要 --yes)
  --json   机器可读输出(含 message/checks[]/actions[]/changed)
  --log <路径> 日志路径;不给就不落盘(步骤脚本可用 dbk_log_default 设缺省路径)
  --yes    破坏性动作必需;缺省时打印动作与影响并以 64 退出(声明了「# 破坏性:1」的脚本照样 64)
  --step <NN-K> 显式声明卡号;必须是脚本头卡号集合的成员,否则 → 64;-h|--help 打印本用法
退出码: 0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误
EOF
}

# dbk_cli_val <参数名> <取值>:契约库的取值守卫——缺值/空值一律打印用法并以 64 退出,不落盘、不经 die()。
# 与 dbk-log.sh 的 need_val 的区别:need_val 用于 L4 脚本的普通取值选项,缺参退 1 且经 log()/die() 可能落盘。
dbk_cli_val() {
  if [ -z "${2:-}" ]; then
    dbk_usage
    dbk_note "用法错误: $1 缺取值"
    exit "$DBK_USAGE"
  fi
  return 0
}

# dbk_header_field <文件> <字段名> <值正则>:读脚本头「# <字段>:<值>」的第一个匹配,打印「:」后的值(取不到打印空)。
# 卡号头与破坏性声明共用这一个实现;行首允许 UTF-8 BOM。
dbk_header_field() {
  local f="${1:-}" field="${2:-}" vre="${3:-}" line=""
  if [ -n "$f" ] && [ -r "$f" ]; then
    line="$(grep -m1 -oE "^(${DBK_BOM})?#[[:space:]]*${field}:[[:space:]]*(${vre})" "$f" || true)"
    if [ -n "$line" ]; then printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//'; fi
  fi
  return 0
}

# dbk_header_cards <文件>:读「# 对应卡:NN-K[,NN-K…]」,打印空格分隔的卡号列表(支持一脚本服务多张卡)。
dbk_header_cards() {
  local line cards
  line="$(dbk_header_field "${1:-}" '(对应卡|Card)' '[0-9][0-9]-[0-9]+([,，][[:space:]]*[0-9][0-9]-[0-9]+)*')"
  cards="$(printf '%s' "$line" | grep -oE '[0-9][0-9]-[0-9]+' | tr '\n' ' ' || true)"
  printf '%s' "${cards% }"
}

# dbk_declared_destructive <文件>:脚本头声明「# 破坏性:1」→ 0(其余情况返回非零)。
dbk_declared_destructive() {
  local v
  v="$(dbk_header_field "${1:-}" '破坏性' '1')"
  if [ "$v" = 1 ]; then return 0; fi
  return 1
}

# 解析命令行:--check 与 --apply 互斥;未知参数、缺参、空取值都是用法错误(64);声明破坏性时 --apply 需 --yes。
dbk_parse_args() {
  local seen_check=0 seen_apply=0 caller
  DBK_CHECKS=(); DBK_ACTIONS=(); DBK_CHECKS_JSON=(); DBK_CHANGED=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) seen_check=1; shift ;;
      --apply) seen_apply=1; shift ;;
      --json) DBK_JSON=1; shift ;;
      --yes|-y) DBK_YES=1; shift ;;
      --log) dbk_cli_val "--log" "${2:-}"; DBK_LOG="$2"; LOG="$DBK_LOG"; shift 2 ;;
      --step) dbk_cli_val "--step" "${2:-}"; DBK_STEP="$2"; shift 2 ;;
      -h|--help) dbk_usage; exit "$DBK_PASS" ;;
      *) dbk_usage; dbk_note "用法错误: 未知参数 $1"; exit "$DBK_USAGE" ;;
    esac
  done
  if [ "$seen_check" -eq 1 ] && [ "$seen_apply" -eq 1 ]; then
    dbk_usage; dbk_note "用法错误: --check 与 --apply 互斥,只能给一个"; exit "$DBK_USAGE"
  fi
  if [ "$seen_apply" -eq 1 ]; then DBK_MODE=apply; else DBK_MODE=check; fi
  caller="${BASH_SOURCE[1]:-}"
  if [ "$DBK_MODE" = apply ] && [ "$DBK_YES" -ne 1 ] && dbk_declared_destructive "$caller"; then
    dbk_usage
    dbk_note "用法错误: 脚本头声明了「# 破坏性:1」,--apply 必须显式给 --yes"
    dbk_note "影响:该动作会改动系统状态;缺 --yes 时脚本不做任何改动。确认无误后加 --yes 重跑。"
    exit "$DBK_USAGE"
  fi
  return 0
}

# dbk_assert_step [脚本头声明的卡号或列表]
#   不给参数时从调用本函数的步骤脚本文件头读「# 对应卡:NN-K[,NN-K…]」(BASH_SOURCE[1]);
#   --step 是集合成员判断:给了 --step 时它必须落在脚本头声明的卡号集合里,否则 64;两处都取不到卡号 → 64。
dbk_assert_step() {
  local declared="${1:-}" caller cards first
  if [ -n "$declared" ]; then
    cards="$(printf '%s' "$declared" | grep -oE '[0-9][0-9]-[0-9]+' | tr '\n' ' ' || true)"
    cards="${cards% }"
  else
    caller="${BASH_SOURCE[1]:-}"
    cards="$(dbk_header_cards "$caller")"
  fi
  if [ -z "$cards" ]; then
    dbk_note "用法错误: 取不到「# 对应卡:NN-K」,无法确认本脚本服务的卡"
    exit "$DBK_USAGE"
  fi
  if [ -n "$DBK_STEP" ]; then
    case " $cards " in
      *" $DBK_STEP "*) ;;
      *) dbk_note "用法错误: --step $DBK_STEP 不在脚本头声明的卡号集合($cards)里"; exit "$DBK_USAGE" ;;
    esac
  fi
  first="${cards%% *}"
  DBK_STEP="${DBK_STEP:-$first}"
  return 0
}

# dbk_need_yes <动作描述> [将执行的命令...]
#   未给 --yes → 打印动作、将执行的命令与影响并退出 64(调用点之前不做任何改动 → 零写)。
#   声明了「# 破坏性:1」的脚本在 dbk_parse_args 就会先拦(64);本函数用于条件性破坏动作(声明不适用)
#   与 --yes 执行路径上的命令记录。
dbk_need_yes() {
  local desc="${1:-}" cmd
  shift || true
  if [ "$DBK_YES" -eq 1 ]; then return 0; fi
  dbk_note "破坏性动作:$desc"
  if [ "$#" -gt 0 ]; then
    dbk_note "将执行的命令:"
    for cmd in "$@"; do dbk_note "  $cmd"; done
  fi
  dbk_note "影响:该动作会改动系统状态;确认无误后加 --yes 重跑(缺 --yes 时脚本不做任何改动)。"
  exit "$DBK_USAGE"
}

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

# dbk_exit <状态> <说明>:报告后以对应退出码结束(0 PASS / 1 FAIL / 2 需人工 / 9 跳过)。
dbk_exit() {
  dbk_report "${1:-}" "${2:-}"
  exit "$(dbk_status_code "$DBK_LAST_STATUS")"
}
