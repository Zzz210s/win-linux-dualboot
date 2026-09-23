#!/usr/bin/env bash
# 对应卡:05-9
# 破坏性:1
# 用途:包级回退与变更前备份(设计依据:docs/design/04-kubuntu-variant-design.md 第 2 节 D4 与第 7 节
#   "单包回退 = apt install <pkg>=<旧版本> + apt-mark hold";失去部署级原子回滚后的替代手段)。
#   --list <包名>   只读列出该包在仓库里的可用版本(apt-cache madison)
#   --check         只读巡检:已 apt-mark hold 的包清单 + apt 最近历史摘要(默认动作)
#   --apply --pkg <名> --version <版本>  降级安装到指定版本并 apt-mark hold(需 --yes;幂等重跑安全)
#   --unhold --pkg <名>                   解除固定(需 --yes),让该包重新跟随仓库升级
# 判据(--check,零写):① `apt-mark showhold` 可读(列出已固定包,空即"无固定包");② apt 历史可读
#   (/var/log/apt/history.log 的最近记录,给出 Start-Date / Commandline 摘要)。两项都取不到 → 需人工。
# 为什么用 hold 而不只是装旧版本:装旧版本后下一次 `apt upgrade` 会把它升回去,hold 才是"停在这个版本"。
# 与 snap 的 no-snap pin 的区别(设计 04 第 3 节 S3):pin -1 是"该包永不作为候选"(拦安装),hold 是"冻结
#   已装版本的升级"(拦升级);两者用途不同,不要互相替代。
# 回退本步:再 --apply 到更新的版本,或 --unhold 后 `sudo apt-get install --reinstall <包>`。
# 用法: rollback-pkg.sh [--list <包名>|--check|--apply --pkg <名> --version <版本>|--unhold --pkg <名>]
#   [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误(缺 --yes 时由库层直接拒,且零写)。
# 注入(真机不需要设置):DBK_APT_GET / DBK_APT_CACHE / DBK_APT_MARK / DBK_APT_HISTORY。
# 待核实(以官方文档为准):apt-cache madison / apt-mark showhold / apt-get install pkg=ver 的文本与返回码、
#   以及 --allow-downgrades 的必要性均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

ACTION=""; LIST_PKG=""; PKG=""; VER=""; WANT_APPLY=0; ARGS=()
set_action() {
  if [ -n "$ACTION" ] && [ "$ACTION" != "$1" ]; then
    dbk_usage; dbk_note "用法错误: 动作选项冲突(--$ACTION 与 --$1);一次只给一个"; exit "$DBK_USAGE"
  fi
  ACTION="$1"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) set_action list; dbk_cli_val "--list" "${2:-}"; LIST_PKG="$2"; shift 2 ;;
    --check) set_action check; ARGS+=(--check); shift ;;
    --apply) WANT_APPLY=1; ARGS+=(--apply); shift ;;
    --unhold) set_action unhold; shift ;;
    --pkg) dbk_cli_val "--pkg" "${2:-}"; PKG="$2"; shift 2 ;;
    --pkg=*) PKG="${1#*=}"; shift ;;
    --version) dbk_cli_val "--version" "${2:-}"; VER="$2"; shift 2 ;;
    --version=*) VER="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "rollback-pkg"
if [ "$WANT_APPLY" -eq 1 ]; then
  if [ -n "$ACTION" ] && [ "$ACTION" != check ]; then
    dbk_usage; dbk_note "用法错误: --apply 只与本脚本的降级动作搭配(当前动作 --$ACTION 是只读的)"; exit "$DBK_USAGE"
  fi
  set_action apply
fi
if [ -z "$ACTION" ]; then if [ "$WANT_APPLY" -eq 1 ]; then ACTION=apply; else ACTION=check; fi; fi
case "$ACTION" in
  apply) [ -n "$PKG" ] || { dbk_usage; dbk_note "用法错误: --apply 需要 --pkg <包名>"; exit "$DBK_USAGE"; }
         [ -n "$VER" ] || { dbk_usage; dbk_note "用法错误: --apply 需要 --version <版本>"; exit "$DBK_USAGE"; } ;;
  unhold) [ -n "$PKG" ] || { dbk_usage; dbk_note "用法错误: --unhold 需要 --pkg <包名>"; exit "$DBK_USAGE"; } ;;
esac

AG_STR="${DBK_APT_GET:-apt-get}"; AC_STR="${DBK_APT_CACHE:-apt-cache}"; AM_STR="${DBK_APT_MARK:-apt-mark}"
HIST="${DBK_APT_HISTORY:-/var/log/apt/history.log}"
AG=(); AC=(); AM=(); read -r -a AG <<<"$AG_STR"; read -r -a AC <<<"$AC_STR"; read -r -a AM <<<"$AM_STR"
ag() { command "${AG[@]}" "$@"; }        # 待核实(以官方文档为准)
ac() { command "${AC[@]}" "$@"; }        # 待核实(以官方文档为准)
am() { command "${AM[@]}" "$@"; }        # 待核实(以官方文档为准)
tail3() { printf '%s' "${1:-}" | tail -n 3 | tr '\n' ' '; }
showhold() { am showhold 2>&1 || true; }

do_list() {
  if ! command -v "${AC[0]}" >/dev/null 2>&1; then
    dbk_add_check "失败项: 未找到 ${AC[0]}(无法列出可用版本)"
    dbk_exit FAIL "apt-cache 不可用:无法列出 $LIST_PKG 的可用版本;请在 Ubuntu 上运行"
  fi
  OUT="$(ac madison "$LIST_PKG" 2>&1)" || true
  if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
    dbk_add_check "失败项: apt-cache madison $LIST_PKG 无输出(包名错误或不在已配置仓库里)"
    dbk_exit FAIL "取不到 $LIST_PKG 的可用版本:先核对包名,再确认仓库已 apt-get update"
  fi
  dbk_note "$OUT"
  dbk_add_check "可用版本数=$(printf '%s\n' "$OUT" | grep -c . || true)(来源已配置仓库)"
  dbk_exit PASS "已列出 $LIST_PKG 的可用版本:按 '包=版本' 的写法喂给 --apply --pkg $LIST_PKG --version <版本>"
}

# --check:07-7 之外的日常巡检角色(原 dbk-rollback.sh --check 的巡检位置改由 check-health.sh 承担,
# 本子命令只回答"包级回退这条路现在通不通")。只读。
do_check() {
  local held hist issues=0 manual=0
  if ! command -v "${AM[0]}" >/dev/null 2>&1; then
    dbk_add_check "需人工: 未找到 ${AM[0]}(无法读出已固定的包)"; manual=$((manual + 1))
  else
    held="$(showhold)"
    if [ -n "$(printf '%s' "$held" | tr -d '[:space:]')" ]; then
      dbk_add_check "已固定(apt-mark hold)的包:$(printf '%s' "$held" | tr '\n' ' ')"
    else
      dbk_add_check "当前没有 apt-mark hold 的包(变更前按需固定:$AM_STR hold <包>)"
    fi
  fi
  if [ -r "$HIST" ]; then
    hist="$(grep -E '^(Start-Date|Commandline):' "$HIST" 2>/dev/null | tail -n 6 | tr '\n' ';' || true)"
    dbk_add_check "apt 历史($HIST,最近记录):${hist:-（无 Start-Date/Commandline 行）}"
  else
    dbk_add_check "需人工: 读不到 apt 历史 $HIST(缺文件或权限不足);无法核对最近一次变更"; manual=$((manual + 1))
  fi
  if [ "$issues" -gt 0 ]; then dbk_exit FAIL "包级回退巡检未通过($issues 项);逐条见 checks"; fi
  if [ "$manual" -gt 0 ]; then dbk_exit 需人工 "包级回退巡检有 $manual 项无法判定;逐条见 checks"; fi
  dbk_exit PASS "包级回退可用:apt-mark 可读、apt 历史可查;回退命令见 --list / --apply --pkg --version"
}

# --apply:降级到指定版本并固定。先 dbk_need_yes(缺 --yes 时库层已拦;这里记录将执行的命令)。
do_apply() {
  local out rc=0 held
  dbk_need_yes "把 $PKG 降级到 $VER 并 apt-mark hold(停在该版本)" "${AG[*]} install -y --allow-downgrades $PKG=$VER" "${AM[*]} hold $PKG"
  out="$(ag install -y --allow-downgrades "$PKG=$VER" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    dbk_add_check "失败项: $AG_STR install $PKG=$VER 退出码 $rc"
    dbk_exit FAIL "降级安装失败: $(tail3 "$out");先核对版本号来自 --list 的输出,并确认仓库索引已是 --list 用过的状态"
  fi
  dbk_add_action "apt-get install -y --allow-downgrades $PKG=$VER"; dbk_mark_changed
  rc=0; out="$(am hold "$PKG" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    dbk_add_check "失败项: $AM_STR hold $PKG 退出码 $rc"
    dbk_exit FAIL "固定失败: $(tail3 "$out");包已降级但未固定,下一次 apt upgrade 会把它升回去,请手工重试 $AM_STR hold $PKG"
  fi
  dbk_add_action "apt-mark hold $PKG"; dbk_mark_changed
  held="$(showhold)"
  if printf '%s\n' "$held" | grep -qx -- "$PKG"; then
    dbk_add_check "复读确认: $PKG 已在 hold 清单里"
  else
    dbk_exit 需人工 "$AM_STR hold 返回成功,但复读的 hold 清单里没有 $PKG(实为:$(printf '%s' "$held" | tr '\n' ' '));请人工核对 $AM_STR showhold"
  fi
  dbk_exit PASS "已把 $PKG 固定在 $VER(降级 + hold);复测通过后用 --unhold --pkg $PKG --yes 放开"
}

do_unhold() {
  local out rc=0 held
  dbk_need_yes "解除 $PKG 的版本固定(放开后该包随仓库升级)" "${AM[*]} unhold $PKG"
  out="$(am unhold "$PKG" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    dbk_add_check "失败项: $AM_STR unhold $PKG 退出码 $rc"
    dbk_exit FAIL "解除固定失败: $(tail3 "$out");固定状态未改变(可用 $AM_STR showhold 复核)"
  fi
  dbk_add_action "apt-mark unhold $PKG"; dbk_mark_changed
  held="$(showhold)"
  if printf '%s\n' "$held" | grep -qx -- "$PKG"; then
    dbk_exit 需人工 "$AM_STR unhold 返回成功,但 $PKG 仍在 hold 清单里;请人工核对 $AM_STR showhold 后再决定是否手工放开"
  fi
  dbk_add_check "复读确认: $PKG 已不在 hold 清单里"
  dbk_exit PASS "已解除 $PKG 的版本固定;它会在下一次 apt upgrade 时随仓库升级"
}

case "$ACTION" in
  list) do_list ;;
  check) do_check ;;
  apply) do_apply ;;
  unhold) do_unhold ;;
esac
