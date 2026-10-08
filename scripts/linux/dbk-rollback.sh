#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:部署级回滚接口(Fedora 44 Silverblue / 原子版语义):pin/unpin、退回上一部署、清理 pending/rollback 部署。
#   部署列表与数量的**读类接口**在 dbk-deploy.sh(本库 source 它)——读类与动作类分两层,便于各自守 200 行上限;动作类接口如下:
#   然后使用:
#   rollback_pin <索引>   0 = 已固定 / 1 = 失败(索引非法也走 1;原因已落日志)
#   rollback_unpin <索引> 0 = 已解除固定 / 1 = 失败
#   rollback_to_previous  0 = 已把上一部署排为下次启动(重启后生效)/ 1 = 失败
#   rollback_needs_reboot 0 = 有已排入下次启动的部署改动(staged,需重启)/ 1 = 无 / 2 = 读不到状态(需人工)
#     护栏:JSON 读到了但整段没有 "staged": 键(字段名漂移)→ 2 需人工;键在且为 false → 1。
#   rollback_cleanup <pending|rollback>  0 = 已清理 / 1 = 失败(参数非法也走 1;pin 的部署由 rpm-ostree 自身保护)。CLI 入口(--prune)见 rollback-deploy.sh
# 索引口径:与 ostree 的部署索引一致 —— 0 = 当前启动,1 = 上一部署(回滚候选),依次递增;就是 deployments_list
#   每行行首打印的序号(官方文档口径:ostree admin pin 的 INDEX,0 = booted、1 = rollback)。索引会随重启与
#   新部署变化,调用方要「即读即用」(先 deployments_list,再把同一批序号喂给 rollback_pin/rollback_unpin)。
# 返回值纪律(读调用方代码前必看):读类判定(deployments_list / deployments_count / rollback_needs_reboot)
#   在任何取不到、解析不了的情况下**一律返回 2(需人工)**,绝不 fail-open 成「0 个部署」或「无待重启」——
#   这是"回滚这条路是否可用"的唯一自动判据。调用方必须显式处理 2(case 里给 2 单独一支),丢进 *) 当失败
#   处理会把「需人工」误记成 FAIL。
# 本文件只定义函数与常量:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总);CLI 入口在 rollback-deploy.sh。
#   **末尾禁止追加任何条件语句**:被 source 时它返回 1,而调用方普遍带 `set -e`,会让整个脚本静默退 1 且零输出(2026-10-06 实测:11 个调用方全挂、k1 50 条断言变红)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE 覆盖 rpm-ostree 命令(可含路径)。
# 待核实(以官方文档为准):rpm-ostree status --json 的 deployments[].version / .pinned / .booted / .staged
#   字段名;人读 status 的 Version: 行顺序与 --json 的 deployments[] 顺序一致(本库靠它把两个来源对上);
#   deployments[] 数组顺序与 ostree 部署索引的对应;rpm-ostree pin <索引> / pin --unpin <索引> / rollback 的
#   参数形态与返回码 —— 均未在真机验证。字段名若与官方输出不符(缺 pinned / staged 键),deployments_list
#   与 rollback_needs_reboot 会走 2(需人工),而不是静默给结论(这就是两处键存在性护栏的意义)。

ROLLBACK_CMD="${DBK_RPM_OSTREE:-rpm-ostree}"   # 夹具注入用
# 部署状态读取层拆到单职责库 dbk-deploy.sh(deployments_list / deployments_count);source 它,读类调用点不变。
# shellcheck source=scripts/linux/dbk-deploy.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dbk-deploy.sh"
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

rollback_cleanup() {   # 清理部署:pending|rollback -> 0 = 已清理 / 1 = 失败(pin 的部署由 rpm-ostree 自身保护)
  case "${1:-}" in pending) _rb_run "已清理 pending 部署" cleanup --pending ;; rollback) _rb_run "已清理 rollback 部署" cleanup --rollback ;; *) _rb_note "错误: rollback_cleanup 只认 pending|rollback,得到 '${1:-}'"; return 1 ;; esac
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
