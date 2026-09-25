#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:部署级回滚接口(Fedora 44 Silverblue / 原子版语义):列部署、pin/unpin、退回上一部署。
# 契约真源:docs/design/06-atomic-restore-design.md 第 2 节 D4(回滚 = 部署级)与第 3 节(dbk-rollback.sh 行);
#   docs/design/03-step-automation-design.md 第 6 节库文件行(四个发行版薄接口之一)。接口名不带发行版痕迹,
#   只换内部实现;Kubuntu 时代的包级回退(apt install <包>=<版本> + apt-mark hold)已随 2026-09-25 回切废弃。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-obs.sh 的 dbk_obs —— dbk-cli.sh 只是替调用方 source 它),
#   然后使用:
#   deployments_list      打印部署列表(每行「索引 版本 标记…」);0 = 可读 / 2 = 取不到或解析不了(需人工)。
#     版本取人读 status 的 Version: 行(JSON 字段名更易漂移),标记取 --json 的 pinned/booted/staged;
#     两个来源的部署数必须一致,不一致 → 2 需人工(不猜哪个对);整段 JSON 里一个 "pinned": 键都没有 → 2
#     需人工(pinned 标记不可信,不能当「没有固定部署」照旧返 0)。
#   deployments_count     打印部署数量(整数,≥1);0 = 可读 / 2 = 取不到或解析不了(需人工)
#   rollback_pin <索引>   0 = 已固定 / 1 = 失败(索引非法也走 1;原因已落日志)
#   rollback_unpin <索引> 0 = 已解除固定 / 1 = 失败
#   rollback_to_previous  0 = 已把上一部署排为下次启动(重启后生效)/ 1 = 失败
#   rollback_needs_reboot 0 = 有已排入下次启动的部署改动(staged,需重启)/ 1 = 无 / 2 = 读不到状态(需人工)
#     护栏:JSON 读到了但整段没有 "staged": 键(字段名漂移)→ 2 需人工;键在且为 false → 1。
# 索引口径:与 ostree 的部署索引一致 —— 0 = 当前启动,1 = 上一部署(回滚候选),依次递增;就是 deployments_list
#   每行行首打印的序号(官方文档口径:ostree admin pin 的 INDEX,0 = booted、1 = rollback)。索引会随重启与
#   新部署变化,调用方要「即读即用」(先 deployments_list,再把同一批序号喂给 rollback_pin/rollback_unpin)。
# 返回值纪律(读调用方代码前必看):读类判定(deployments_list / deployments_count / rollback_needs_reboot)
#   在任何取不到、解析不了的情况下**一律返回 2(需人工)**,绝不 fail-open 成「0 个部署」或「无待重启」——
#   这是"回滚这条路是否可用"的唯一自动判据。调用方必须显式处理 2(case 里给 2 单独一支),丢进 *) 当失败
#   处理会把「需人工」误记成 FAIL。
# 本文件只定义函数与常量:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE 覆盖 rpm-ostree 命令(可含路径)。
# 待核实(以官方文档为准):rpm-ostree status --json 的 deployments[].version / .pinned / .booted / .staged
#   字段名;人读 status 的 Version: 行顺序与 --json 的 deployments[] 顺序一致(本库靠它把两个来源对上);
#   deployments[] 数组顺序与 ostree 部署索引的对应;rpm-ostree pin <索引> / pin --unpin <索引> / rollback 的
#   参数形态与返回码 —— 均未在真机验证。字段名若与官方输出不符(缺 pinned / staged 键),deployments_list
#   与 rollback_needs_reboot 会走 2(需人工),而不是静默给结论(这就是两处键存在性护栏的意义)。

ROLLBACK_CMD="${DBK_RPM_OSTREE:-rpm-ostree}"   # 夹具注入用

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
deployments_count() {
  local n
  n="$(deployments_list | grep -c . || true)"
  case "${n:-0}" in ''|0) return 2 ;; esac
  printf '%s\n' "$n"
  return 0
}

# 执行一个改动部署状态的子命令:0 = 成功 / 1 = 失败(原因已落日志)。体内一律 command(见 dbk-cli.sh 头部约定)。
_rb_run() {
  local desc="${1:-}"; shift
  local out st
  command -v "${ROLLBACK_CMD%% *}" >/dev/null 2>&1 || {
    _rb_note "错误: 未找到 ${ROLLBACK_CMD%% *},无法执行:$desc"; return 1; }
  out="$(command "$ROLLBACK_CMD" "$@" 2>&1)" && st=0 || st=$?
  if [ "$st" -eq 0 ]; then
    _rb_note "$ROLLBACK_CMD $*: $desc"
    return 0
  fi
  _rb_note "错误: $ROLLBACK_CMD $* 失败(退出码 $st): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# 固定某个部署(不被垃圾回收)。索引口径见文件头。
rollback_pin() {
  local idx="${1:-}"
  case "$idx" in
    ''|*[!0-9]*) _rb_note "错误: rollback_pin 需要非负整数索引(deployments_list 行首序号),得到 '$idx'"; return 1 ;;
  esac
  _rb_run "已固定部署 $idx(不会被垃圾回收)" pin "$idx"
}

# 解除某个部署的固定。
rollback_unpin() {
  local idx="${1:-}"
  case "$idx" in
    ''|*[!0-9]*) _rb_note "错误: rollback_unpin 需要非负整数索引(deployments_list 行首序号),得到 '$idx'"; return 1 ;;
  esac
  _rb_run "已解除部署 $idx 的固定,它可被垃圾回收" pin --unpin "$idx"
}

# 退回上一部署:把上一部署排为下次启动(重启后生效;重启前当前系统未变)。
rollback_to_previous() {
  _rb_run "已把上一部署排为下次启动(重启后生效)" rollback
}

# 0 = 有已排入下次启动的部署改动(staged;需重启)/ 1 = 无 / 2 = 读不到状态(需人工)。
# 失效方向必须是 2:它是"回滚排上了但没重启"这条风险的唯一安全网,读不到就当"无待重启"会把风险静默吞掉。
rollback_needs_reboot() {
  local json flat
  json="$(_rb_status_json)" || return 2
  # 去掉空白再匹配 "staged":true(JSON 可能写成 "staged": true,glob 里表达不了"零或多个空白")。
  flat="${json//[[:space:]]/}"
  case "$flat" in
    *'"staged":true'*) return 0 ;;
    *'"staged":'*) return 1 ;;
  esac
  # 键存在性护栏:没有 "staged": 键 = 字段名漂移,不能当「无待重启」→ 2(它是这条风险的唯一安全网)。
  _rb_note "错误: $ROLLBACK_CMD status --json 里没有 staged 键(字段名可能与官方输出不一致),无法判断是否有待重启部署(需人工)"
  return 2
}
