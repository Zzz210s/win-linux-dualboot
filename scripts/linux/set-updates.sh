#!/usr/bin/env bash
# 对应卡:05-7
# L4:更新策略收紧(Fedora 44 Silverblue / 原子版语义;设计依据:docs/design/06-atomic-restore-design.md
#   第 2 节 D5「只检查/下载,绝不自动应用与自动重启」与第 3 节 dbk-update.sh 行)。
# 用途:--check 只读判定更新策略是否已配为「只检查/下载、不自动应用与自动重启」;--apply 经 dbk-update.sh 写
#   更新策略配置并启用自动更新定时器(配置文件路径、节名、键名与单元名都由接口封装,本脚本不写发行版字面量)。
# 语义说明(不可改):原子版没有「只装安全更新」这个粒度 → 语义如实替换为「只检查/下载」。
# 判据(--check,零写):① 配置已配为「只检查/下载」;② 配置里没有「自动应用/自动重启」的取值;③ 定时器已启用。
#   三项一并由 dbk-update.sh 的 update_policy_check 判定(0 已配 / 1 未配或不符 / 2 读不到 -> 需人工)。
# 人工边界:本步不声明破坏性(只写一个配置文件并启用一个定时器,可逆:删配置 + disable 定时器后复跑 --check)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: set-updates.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 注入(夹具用):DBK_RPM_OSTREED_CONF / DBK_SYSTEMCTL(两个注入点都直接透传给 dbk-update.sh)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-update.sh disable=SC1091
. "$HERE/dbk-update.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)。
log() { dbk_obs "$*"; }
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "set-updates"

ISSUES=(); MANUAL=()

# --check 时把将写入的内容亮出来(走 stderr,不污染 --json 的 stdout),让"未配成什么样"一眼可见。
show_target() {
  log "目标配置: $UPDATE_CONF"
  update_policy_text | while IFS= read -r line; do log "$line"; done
}

check_all() {
  local rc
  ISSUES=(); MANUAL=()
  if update_policy_check; then rc=0; else rc=$?; fi
  case "$rc" in
    0) dbk_add_check "①更新策略已是「只检查/下载,不自动应用与自动重启」($UPDATE_CONF)" ;;
    1) ISSUES+=("①未配为「只检查/下载」:$UPDATE_CONF 缺 AutomaticUpdatePolicy=check/download,或含 apply/stage") ;;
    2) MANUAL+=("①读不到更新策略配置或定时器状态:$UPDATE_CONF;请人工确认配置内容与定时器是否已启用") ;;
    *) ISSUES+=("①更新策略判定返回了未知状态码 $rc") ;;
  esac
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:更新策略已是「只检查/下载,不自动应用与自动重启」"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  if update_policy_apply; then
    dbk_add_action "写入 $UPDATE_CONF 并启用自动更新定时器"
    dbk_mark_changed
  else
    dbk_add_check "失败项: 写入配置或启用定时器失败(原因见上面库层输出)"
    dbk_exit FAIL "更新策略未执行成功:写配置或启用定时器失败;按上面原因处理后重跑"
  fi
  check_all
  finish "更新策略已执行(--apply;复读判据后判定)"
fi

show_target
check_all
finish "更新策略判据核对完成(--check 零写)"
