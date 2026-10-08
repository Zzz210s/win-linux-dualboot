#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:部署状态读取层(Fedora 44 Silverblue / 原子版语义):把 dbk-rollback.sh 的**读类接口**拆成单职责库(原文件已到 200 行
#   上限);实现与判定口径一字未改,动作类接口(pin/unpin/退回上一部署/清理)仍在 dbk-rollback.sh。本层是「回滚这条路是否可用」的
#   唯一自动判据来源,调用方经 dbk-rollback.sh 使用它(那一层会替调用方 source 本库)。
# 契约真源:docs/design/06-atomic-restore-design.md 第 2 节 D4(回滚 = 部署级)与第 3 节;docs/design/03-step-automation-design.md 第 6 节。
# 调用约定:调用方先 source dbk-rollback.sh(它定义 ROLLBACK_CMD 并 source 本库),然后:
#   deployments_list      打印部署列表(每行「索引 版本 标记…」);0 = 可读 / 2 = 取不到或解析不了(需人工)。
#     版本取人读 status 的 Version: 行(JSON 字段名更易漂移),标记取 --json 的 pinned/booted/staged;
#     两个来源的部署数必须一致,不一致 → 2 需人工(不猜哪个对);整段 JSON 里一个 "pinned": 键都没有 → 2
#     需人工(pinned 标记不可信,不能当「没有固定部署」照旧返 0)。
#   deployments_count     打印部署数量(整数,≥1);0 = 可读 / 2 = 取不到或解析不了(需人工)。
#     实现口径:先取 deployments_list 的退出码,再数行 —— 不得用 `deployments_list | grep -c` 吞掉子函数退出码
#     (list 因缺 pinned 键或两来源计数不一致而返回 2 时,管道版会反手打印一个数 = fail-open)。
# 索引口径:0 = 当前启动,1 = 上一部署(回滚候选);就是 deployments_list 每行行首打印的序号。索引会随重启与新部署变化,
#   调用方要「即读即用」(先 deployments_list,再把同一批序号喂给 pin/unpin)。
# 返回值纪律(读调用方代码前必看):读类判定(deployments_list / deployments_count / rollback_needs_reboot)
#   在任何取不到、解析不了的情况下**一律返回 2(需人工)**,绝不 fail-open 成「0 个部署」或「无待重启」——
#   这是"回滚这条路是否可用"的唯一自动判据。调用方必须显式处理 2(case 里给 2 单独一支),丢进 *) 当失败
#   处理会把「需人工」误记成 FAIL。
# 依赖:本库不定义任何部署命令字面量(规则 S-1)——ROLLBACK_CMD 由调用方提供(真源在 dbk-rollback.sh)。
# 本文件只定义函数:不设置 shell 选项、不执行动作(调用方自己 set -euo pipefail 或逐项汇总)。
#   **末尾禁止追加任何条件语句**:被 source 时它返回 1,而调用方普遍带 set -e,会让整个脚本静默退 1 且零输出
#   (2026-10-06 实测:11 个调用方全挂、k1 50 条断言变红)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE 覆盖部署状态命令(可含路径)。
# 待核实(以官方文档为准):status --json 的 deployments[].version / .pinned / .booted / .staged 字段名;人读 status 的
#   Version: 行顺序与 --json 的 deployments[] 顺序一致(本库靠它把两个来源对上);deployments[] 数组顺序与部署索引的对应;
#   pin <索引> / pin --unpin <索引> / rollback 的(以及清理用的)pending|rollback 参数形态与返回码 —— 均未在真机验证。
#   字段名若与官方输出不符(缺 pinned / staged 键),deployments_list 与 rollback_needs_reboot 会走 2(需人工),而不是静默给结论。

# 库层日志:优先用可观测层的 dbk_obs(同时落 stderr 与 --log),否则退回 dbk-log.sh 的 log,再退回 stderr。
# 不吞 stderr:调用方既没装 dbk-obs 也没装 dbk-log 时,失败信息仍要打到 stderr。
_rb_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 读 status --json:成功时把 JSON 打到 stdout 并返回 0;取不到或不像 status 输出 → 2(需人工,原因已打 stderr)。
_rb_status_json() {
  local out st
  command -v "${ROLLBACK_CMD%% *}" >/dev/null 2>&1 || {
    _rb_note "错误: 未找到 ${ROLLBACK_CMD%% *},读不到部署列表(需人工)"; return 2; }
  out="$(command "$ROLLBACK_CMD" status --json 2>/dev/null)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _rb_note "错误: $ROLLBACK_CMD status --json 退出码 $st,读不到部署列表(需人工)"; return 2
  fi
  if [ -z "$out" ]; then
    _rb_note "错误: $ROLLBACK_CMD status --json 无输出,读不到部署列表(需人工)"; return 2
  fi
  case "$out" in
    *'"deployments"'*) ;;
    *) _rb_note "错误: $ROLLBACK_CMD status --json 输出不含 deployments,读不到部署列表(需人工)"; return 2 ;;
  esac
  printf '%s' "$out"
  return 0
}

# 部署块:stdin 读 status --json,一行一个部署(展平 JSON 并去掉外层花括号);解析不出则无输出。
# 先定位 "deployments":[ 再按 "},{" 切分:不依赖 JSON 的换行缩进,也不依赖对象内键的顺序。
_rb_blocks() {
  awk '
    { s = s $0 }
    END {
      if (match(s, /"deployments"[[:space:]]*:[[:space:]]*\[/)) {
        s = substr(s, RSTART + RLENGTH)
        sub(/\][^]]*$/, "", s)
        gsub(/[[:space:]]/, "", s)
        sub(/^[{]/, "", s); sub(/[}]$/, "", s)
        if (length(s) > 0) { gsub(/[}],[{]/, "\n", s); print s }
      }
    }'
}

# 文本 status(不带 --json)的 Deployments 段:一行一个 Version: 值。0 = 取到 / 2 = 取不到或没有 Deployments 段(需人工)。
# 版本以人读输出为准;部署数由 deployments_list 与 --json 的 deployments[] 交叉核对。
_rb_text_versions() {
  local out st
  out="$(command "$ROLLBACK_CMD" status 2>/dev/null)" && st=0 || st=$?
  if [ "$st" -ne 0 ] || [ -z "$out" ]; then
    _rb_note "错误: $ROLLBACK_CMD status 取不到输出(退出码 $st;需人工)"; return 2
  fi
  case "$out" in
    *Deployments:*) ;;
    *) _rb_note "错误: $ROLLBACK_CMD status 输出里没有 Deployments 段(需人工)"; return 2 ;;
  esac
  printf '%s\n' "$out" | awk '
    /^[[:space:]]*Version:/ { sub(/^[[:space:]]*Version:[[:space:]]*/, ""); print }'
  return 0
}

# 部署列表:一行一个「索引 版本 标记…」(标记有 当前启动 / pinned / staged:待重启)。0 = 可读 / 2 = 需人工。
deployments_list() {
  local json vers ntext i=0 blk ver line pk=0
  json="$(_rb_status_json)" || return 2
  vers="$(_rb_text_versions)" || return 2
  ntext="$(printf '%s\n' "$vers" | grep -c . || true)"
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    ver="$(printf '%s\n' "$vers" | sed -n "$((i + 1))p")"
    line="$i ${ver:-未知版本}"
    case "$blk" in *'"booted":true'*) line="$line [当前启动]" ;; esac
    case "$blk" in *'"pinned":'*) pk=1 ;; esac
    case "$blk" in *'"pinned":true'*) line="$line [pinned]" ;; esac
    case "$blk" in *'"staged":true'*) line="$line [staged:待重启]" ;; esac
    printf '%s\n' "$line"
    i=$((i + 1))
  done <<<"$(printf '%s\n' "$json" | _rb_blocks)"
  if [ "$i" -eq 0 ]; then
    _rb_note "错误: $ROLLBACK_CMD 的 status 输出里解析不出任何部署(需人工)"; return 2
  fi
  if [ "$i" -ne "${ntext:-0}" ]; then
    _rb_note "错误: 两个来源的部署数不一致(文本 status 有 $ntext 行 Version:,JSON 有 $i 个部署),拒绝猜(需人工)"
    return 2
  fi
  # 键存在性护栏:整段 JSON 一个 "pinned": 键都没有 = 字段名漂移,标记不可信 → 2(不能照旧返 0 说「没有固定部署」)。
  if [ "$pk" -ne 1 ]; then
    _rb_note "错误: $ROLLBACK_CMD status --json 里没有任何 pinned 键(字段名可能与官方输出不一致),固定标记不可信(需人工)"
    return 2
  fi
  return 0
}

# 部署数量:0 = 可读(打印整数,≥1)/ 2 = 取不到或解析不了(需人工)。
# 必须先看 deployments_list 的退出码再数行:管道里的 grep -c 会吞掉子函数退出码(旧实现即 fail-open)。
deployments_count() {
  local list n
  list="$(deployments_list)" || return 2
  n="$(printf '%s\n' "$list" | grep -c . || true)"
  case "${n:-0}" in ''|0) return 2 ;; esac
  printf '%s\n' "$n"
}
