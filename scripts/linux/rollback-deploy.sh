#!/usr/bin/env bash
# 对应卡:05-9
# 破坏性:1
# L4:部署级回滚(设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D4 与第 3 节 dbk-rollback.sh 行)。
# 用途:--check 只读判定"回滚这一路现在通不通"(列部署 + 是否有回滚候选 + 是否有已排入下次启动的部署改动);
#   --apply --yes 调接口的 rollback_to_previous,把上一部署排为下次启动(重启后生效);
#   --pin <索引> --yes / --unpin <索引> --yes 分别调 rollback_pin / rollback_unpin(变更前固定/事后解除固定)。
# 索引口径:0 = 当前启动、1 = 上一部署(回滚候选);索引会随重启与新部署变化,要「即读即用」
#   (先跑 --check 看行首序号,再把同一批序号喂给 --pin/--unpin)。
# 判据(--check,零写):① 部署列表可读(人读 status 的 Version: 行与 --json 两侧都能解析且部署数一致);
#   ② 存在回滚候选(部署数 ≥ 2,索引 1 = 上一部署);③ 待重启状态可判定。①③ 读不到或两侧不一致 → 需人工(2);
#   ② 不成立 → 失败(1:先完成一次更新或分层安装,再回来复核)。
# 为什么是部署级(不可改):原子版里没有"改单个包再退回"的粒度,回滚单位是整个部署(设计 06 D4)。
# 与本步有关的纪律:回滚只是把上一部署排为下次启动,重启前当前系统照常可用、也未被改动(想反悔重启前再跑一次);
#   回滚前若想保住当前部署不被垃圾回收,先按索引 0 固定它(接口 rollback_pin,索引口径见 dbk-rollback.sh 头部)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误(脚本头声明了破坏性,--apply 缺 --yes 由库层拒且零写)。
# 用法: rollback-deploy.sh [--check|--apply|--pin <索引>|--unpin <索引>] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
#   三种动作互斥:--check(缺省,零写) / --apply --yes(回滚到上一部署) / --pin N --yes 与 --unpin N --yes(固定/解除固定)。
#   pin 属人工执行:总控 verify-all.sh 的 chk_step 只传 --check/--list,不接受 --pin,卡片里的「变更前 pin」靠人手动跑。
# 注入(夹具用):DBK_RPM_OSTREE 由环境透传给 dbk-rollback.sh;本脚本不写发行版命令字面量(规则 S-1)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-rollback.sh disable=SC1091
. "$HERE/dbk-rollback.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)。
log() { dbk_obs "$*"; }
dbk_enable_errtrap
# --pin / --unpin 不在 dbk-cli.sh 的通用参数表里(且是 05-9 的独立动作),先在本脚本摘出来——纯内存,零写;
# 其余参数原样交给 dbk_parse_args。索引合法性不在这里判:交给 rollback_pin/rollback_unpin 的 1(调用方给错)。
PIN_ACT=""; PIN_IDX=""; MODE_GIVEN=0; DBK_ARGV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pin|--unpin)
      if [ -n "$PIN_ACT" ]; then dbk_note "用法错误: --pin 与 --unpin 只能给一个(已给 --$PIN_ACT)"; exit "$DBK_USAGE"; fi
      if [ "$#" -lt 2 ]; then dbk_note "用法错误: $1 后面要给部署索引(0 = 当前启动,1 = 上一部署)"; exit "$DBK_USAGE"; fi
      PIN_ACT="${1#--}"; PIN_IDX="$2"; shift 2 ;;
    --check|--apply) MODE_GIVEN=1; DBK_ARGV+=("$1"); shift ;;
    *) DBK_ARGV+=("$1"); shift ;;
  esac
done
dbk_parse_args ${DBK_ARGV[@]+"${DBK_ARGV[@]}"}
if [ -n "$PIN_ACT" ] && [ "$MODE_GIVEN" -eq 1 ]; then
  dbk_note "用法错误: pin/unpin 是独立动作,不能与 --check/--apply 混用"
  exit "$DBK_USAGE"
fi
dbk_assert_step
dbk_log_default "rollback-deploy"

ISSUES=(); MANUAL=()
LIST=""; REBOOT=""

# --check 的三条判据。LIST 由 deployments_list 落一次,后面展示与判据复用,避免重复读状态。
check_all() {
  local rc n cand
  ISSUES=(); MANUAL=(); LIST=""; REBOOT=""
  if LIST="$(deployments_list)"; then rc=0; else rc=$?; LIST=""; fi
  case "$rc" in
    0)
      n="$(printf '%s\n' "$LIST" | grep -c . || true)"
      dbk_add_check "①部署列表可读:共 $n 个部署(索引 0 = 当前启动,1 = 上一部署)"
      if [ "${n:-0}" -ge 2 ]; then
        cand="$(printf '%s\n' "$LIST" | sed -n '2p')"
        dbk_add_check "②存在回滚候选:索引 1 = $cand"
      else
        ISSUES+=("②只有 ${n:-0} 个部署,没有可回滚的上一部署(先完成一次更新或分层安装,再回来复核)")
      fi ;;
    2) MANUAL+=("①读不到部署列表:人读 status 或 --json 取不到/解析不了,或两侧部署数不一致;无法判定回滚是否可用") ;;
    *) ISSUES+=("①部署列表判定返回未知状态码 $rc") ;;
  esac
  if rollback_needs_reboot; then rc=0; else rc=$?; fi
  REBOOT="$rc"
  case "$rc" in
    0) dbk_add_check "③已有排入下次启动的部署改动(staged;重启后生效)" ;;
    1) dbk_add_check "③当前没有排入下次启动的部署改动" ;;
    *) MANUAL+=("③读不到待重启状态:status 的 JSON 取不到或解析不了") ;;
  esac
  return 0
}

# 把部署列表亮到 stderr(不污染 --json 的 stdout),让"索引 + 版本 + 标记"一眼可见。
show_list() {
  local line
  log "部署列表(索引 版本 标记;索引 0 = 当前启动,1 = 上一部署):"
  while IFS= read -r line; do log "  $line"; done <<<"$LIST"
}

finish() {
  local msg="${1:-}" m hint=""
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  if [ "$REBOOT" = 0 ]; then hint=";已有排入下次启动的部署改动,请重启使其生效"; fi
  dbk_exit PASS "$msg:部署级回滚这一路可用$hint"
}

if [ -n "$PIN_ACT" ]; then
  if [ "$PIN_ACT" = pin ]; then
    what="固定部署 $PIN_IDX(不被垃圾回收)"; want="$ROLLBACK_CMD pin $PIN_IDX"
    done_msg="部署 $PIN_IDX 已固定(变更前 pin 完成;要解除用 --unpin $PIN_IDX --yes)"
  else
    what="解除部署 $PIN_IDX 的固定(它可被垃圾回收)"; want="$ROLLBACK_CMD pin --unpin $PIN_IDX"
    done_msg="部署 $PIN_IDX 的固定已解除"
  fi
  dbk_need_yes "$what" "$want"
  if "rollback_$PIN_ACT" "$PIN_IDX"; then prc=0; else prc=$?; fi
  case "$prc" in   # 接口返回值直传:1 = 失败,2 = 需人工(不把「需人工」记成 FAIL)
    0) dbk_add_action "rollback_$PIN_ACT $PIN_IDX"; dbk_mark_changed; dbk_exit PASS "$done_msg" ;;
    2) dbk_exit 需人工 "rollback_$PIN_ACT $PIN_IDX 判不了(接口返回 2 需人工);原因见上面库层输出" ;;
    *) dbk_exit FAIL "rollback_$PIN_ACT $PIN_IDX 失败(接口返回 $prc);按上面原因处理后重跑(幂等)" ;;
  esac
fi

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  dbk_need_yes "把上一部署排为下次启动(重启后生效)" "$ROLLBACK_CMD rollback"
  if rollback_to_previous; then
    dbk_add_action "rollback_to_previous(上一部署已排为下次启动)"
    dbk_mark_changed
  else
    dbk_add_check "失败项: rollback_to_previous 失败(原因见上面库层输出)"
    dbk_exit FAIL "部署回滚未执行成功:接口返回失败;按上面原因处理后重跑(幂等)"
  fi
  check_all; show_list
  finish "已把上一部署排为下次启动(--apply 已执行)"
fi

check_all; show_list
finish "回滚判据核对完成(--check 零写,未改动任何系统状态)"
