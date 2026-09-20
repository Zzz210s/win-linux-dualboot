#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:步骤脚本契约的**可观测性层**(Linux 侧):人读/机器读输出、JSON 汇总、--log 落盘、失败可见(ERR trap)。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节(可观测性)与第 7 节(夹具要求)。
# 装配方式:dbk-cli.sh 定义常量与状态变量后 source 本文件;本文件只定义函数,不设置 shell 选项、不主动执行动作。
# 可观测性三条(设计第 2 节):
#   1) 失败不得只给退出码:FAIL/需人工 必须给原因文本,库把说明同时写进 message 与 checks[](判据为空时补一条);
#   2) 三处可见:失败要能在 stderr、--log 日志、--json 的 checks[] 里同时看到;
#   3) 不吞 stderr:日志写不进去时把失败打到 stderr,不许用 2>/dev/null 蒙掉。
# errtrap 是 opt-in:只有用 set -e 的步骤脚本才调 dbk_enable_errtrap;"失败不中断"的脚本(hardening.sh /
#   first-boot.sh 这类逐项汇总、整体仍返回 0)不得启用,否则会把逐项失败升级成中断。
# 夹具级验证,真机未跑。

# 人读信息一律走 stderr(保证 --json 模式下 stdout 只有一行 JSON)。只写 stderr,不落盘。
dbk_note() { printf '%s\n' "$*" >&2; }

# dbk_log_write <文本>:追加到 DBK_LOG 指定的日志文件(未给 --log 时直接返回,库层不落盘)。
# 写不进去必须说出来(不吞 stderr),但仍返回 0:日志失败不该改变步骤脚本的结论。
dbk_log_write() {
  local line="${1:-}" dir
  [ -n "${DBK_LOG:-}" ] || return 0
  dir="$(dirname "$DBK_LOG")"
  if ! mkdir -p "$dir"; then
    printf 'dbk: 日志目录创建失败,日志不可用: %s\n' "$dir" >&2
    return 0
  fi
  if ! printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$line" >>"$DBK_LOG"; then
    printf 'dbk: 日志写入失败: %s\n' "$DBK_LOG" >&2
  fi
  return 0
}

# dbk_obs <文本>:失败信息的统一出口——stderr + (给了 --log 时的)日志文件。第二处由 dbk_log_write 负责。
dbk_obs() {
  printf '%s\n' "$*" >&2
  dbk_log_write "$*"
}

# dbk_log_default <脚本名>:步骤脚本显式调用,把缺省日志路径 /var/log/dbk/<脚本名>.log 写进 DBK_LOG/LOG。
# 库自身不调它(保证"不给 --log 就不落盘");调用后失败路径(dbk_obs)才会写这个文件。
dbk_log_default() {
  [ -n "${DBK_LOG:-}" ] && return 0
  DBK_LOG="/var/log/dbk/${1:-dbk}.log"; LOG="$DBK_LOG"
  return 0
}

# 判据/动作登记:普通判据是字符串;库层失败项(如 errtrap)用原始 JSON 对象登记,与字符串项一起进 checks[]。
dbk_add_check() { DBK_CHECKS+=("${1:-}"); }
dbk_add_action() { DBK_ACTIONS+=("${1:-}"); }
dbk_add_check_raw() { DBK_CHECKS_JSON+=("${1:-}"); }
dbk_mark_changed() { DBK_CHANGED=1; }

# dbk_json_array <元素...>:拼成 JSON 字符串数组(空 → 空),元素经 dbk_json_escape 转义。
dbk_json_array() {
  local sep="" x out=""
  for x in "$@"; do out="$out$sep\"$(dbk_json_escape "$x")\""; sep=,; done
  printf '%s' "$out"
}

# 拼 checks[]:先普通判据(字符串),再库层失败项(原始 JSON 对象,如 {"id":"errtrap","ok":false,"detail":"…"})。
dbk_checks_json() {
  local sep="" x out=""
  for x in ${DBK_CHECKS[@]+"${DBK_CHECKS[@]}"}; do out="$out$sep\"$(dbk_json_escape "$x")\""; sep=,; done
  for x in ${DBK_CHECKS_JSON[@]+"${DBK_CHECKS_JSON[@]}"}; do out="$out$sep$x"; sep=,; done
  printf '%s' "$out"
}

# JSON 汇总(单行):{"step":…,"status":…,"message":…,"checks":[…],"actions":[…],"changed":true|false}
# message 是失败/结论的原因文本(M-1:不得因为走 JSON 就把说明丢掉)。
dbk_emit_json() {
  printf '{"step":"%s","status":"%s","message":"%s","checks":[%s],"actions":[%s],"changed":%s}\n' \
    "$(dbk_json_escape "${1:-}")" "${2:-}" "$(dbk_json_escape "${3:-}")" \
    "$(dbk_checks_json)" \
    "$(dbk_json_array ${DBK_ACTIONS[@]+"${DBK_ACTIONS[@]}"})" \
    "$([ "$DBK_CHANGED" -eq 1 ] && printf true || printf false)"
}

# 状态显示名:文本报告与失败行用;未知键原样返回。
dbk_status_tag() {
  case "${1:-}" in
    pass) printf 'PASS' ;;
    fail) printf 'FAIL' ;;
    manual) printf '需人工' ;;
    skip) printf '跳过' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# dbk_report <PASS|FAIL|需人工|跳过> <说明>
#   FAIL/需人工:说明不得为空(不得只给退出码);说明同时进 stderr+日志、JSON 的 message 与 checks[](判据为空时补一条)。
#   文本模式打印 `[状态] 说明` 与判据/动作清单;JSON 模式打印单行 JSON。只打印,不改退出码。
dbk_report() {
  local status="${1:-}" msg="${2:-}" key tag x
  key="$(dbk_status_key "$status")" || {
    dbk_note "用法错误: 未知状态 $status(只认 PASS/FAIL/需人工/跳过 或 pass/fail/manual/skip)"
    exit "$DBK_USAGE"
  }
  DBK_LAST_STATUS="$key"
  tag="$(dbk_status_tag "$key")"
  case "$key" in
    fail|manual)
      if [ -z "$msg" ]; then
        dbk_note "用法错误: $tag 必须给出原因文本(失败不得只给退出码)"
        exit "$DBK_USAGE"
      fi
      if [ "${#DBK_CHECKS[@]}" -eq 0 ] && [ "${#DBK_CHECKS_JSON[@]}" -eq 0 ]; then
        dbk_add_check "失败项: $msg"
      fi
      dbk_obs "[$tag] $msg" ;;
  esac
  if [ "${DBK_JSON:-0}" -eq 1 ]; then
    dbk_emit_json "$DBK_STEP" "$key" "$msg"
    return 0
  fi
  printf '[%s] %s\n' "$tag" "$msg"
  for x in ${DBK_CHECKS[@]+"${DBK_CHECKS[@]}"}; do printf '  - %s\n' "$x"; done
  for x in ${DBK_ACTIONS[@]+"${DBK_ACTIONS[@]}"}; do printf '  > %s\n' "$x"; done
  return 0
}

# dbk_enable_errtrap:opt-in 的失败可见机制(只给用 set -e 的步骤脚本;失败不中断的脚本不得启用)。
# 启用后任何命令非零都会走 dbk_on_err,把失败写到 stderr、--log 日志、--json 的 checks[],并立刻输出一行报告。
dbk_enable_errtrap() {
  DBK_ERRTRAP=1
  trap 'dbk_on_err $? $LINENO "$BASH_COMMAND"' ERR
  return 0
}

# dbk_on_err <rc> <行号> <失败命令> —— 由 ERR trap 调用(也可手工调用,夹具用它验证三处可见)。
dbk_on_err() {
  local rc="${1:-0}" ln="${2:-0}" cmd="${3:-}" detail
  [ "${DBK_ERRTRAP:-0}" -eq 1 ] || return 0
  DBK_ERRTRAP=0                      # 防递归:本函数内部再失败不再进 trap
  detail="line $ln rc=$rc: $cmd"
  dbk_obs "errtrap: $detail"
  dbk_add_check_raw "{\"id\":\"errtrap\",\"ok\":false,\"detail\":\"$(dbk_json_escape "$detail")\"}"
  DBK_LAST_STATUS=fail
  if [ "${DBK_JSON:-0}" -eq 1 ]; then
    dbk_emit_json "$DBK_STEP" fail "errtrap: $detail"
  else
    printf '[FAIL] errtrap: %s\n' "$detail"
  fi
  DBK_ERRTRAP=1
  return 0
}
