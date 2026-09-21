#!/usr/bin/env bash
# 对应卡:05-9,07-7
# 破坏性:1
# 用途:部署回滚与 07-7 周期巡检的部署复检(设计依据:docs/design/02-fedora-atomic-variant-design.md 第 4 节
#   D3 部署级回滚、docs/design/00-design.md 4.7 的 R1/R2 与 7.1 第 6 条、7.2 的"部署级"粒度)。
#   --list 只读列出 ostree 部署(部署数 / 下一次启动的部署 / 当前已启动的部署 / 版本 / pin 标记);
#   --check 只读复检三项:① 部署列表与 pin 状态;② nvidia 模块签名(mokutil + lsmod + modinfo);③ 会话类型;
#   --pin / --unpin 固定 / 取消固定当前部署;--rollback(与 --apply 等价)切换下一次启动的部署。
# 判据与语义(以 rpm-ostree 官方手册为准):部署按"下次启动顺序"列出,列表第一项即下次默认启动的部署,
#   `●` 标记当前已启动的部署;`rpm-ostree rollback` 只切换**下一次启动**的部署,需重启后生效;
#   **用户数据不随部署回滚**(/var 与 /var/home 不在部署内,家目录是 /var/home 的符号链接)。
# 用法: dbk-rollback.sh [--list|--pin|--unpin|--rollback|--check] [--json] [--log <路径>] [--yes] [--step NN-K]
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。默认只读:只有 --pin/--unpin/--rollback 会改系统
#   状态,且都必须显式给 --yes(缺 --yes 时打印将执行的命令与影响并退 64,此后不做任何改动)。
# 回滚本步:pin 可 unpin;rollback 可再回滚到另一部署或在开机菜单选;本脚本不清理部署(清理用 rpm-ostree cleanup)。
# 注入(真机不需要设置):DBK_RPM_OSTREE(覆盖 rpm-ostree 命令)、DBK_MOKUTIL / DBK_MODINFO / DBK_LSMOD。
# 待核实(以官方文档为准):所有 rpm-ostree 子命令与 status 文本解析均未在真机验证(夹具级验证,真机未跑)。
# 不启用 errtrap:只读探针失败是本脚本的预期分支(逐项登记 FAIL / 需人工),不得升级成中断。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

# 本脚本特有的动作选项先摘出来,其余参数原样交给契约库(dbk_parse_args 不认 --list/--pin/--unpin/--rollback)。
ACTION=""; WANT_APPLY=0; ARGS=()
set_action() {
  if [ -n "$ACTION" ] && [ "$ACTION" != "$1" ]; then
    dbk_usage; dbk_note "用法错误: 动作选项冲突(--$ACTION 与 --$1);一次只给一个"; exit "$DBK_USAGE"
  fi
  ACTION="$1"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) set_action list; shift ;;
    --pin) set_action pin; shift ;;
    --unpin) set_action unpin; shift ;;
    --rollback) set_action rollback; shift ;;
    --check) set_action check; ARGS+=(--check); shift ;;
    --apply) WANT_APPLY=1; ARGS+=(--apply); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ "$WANT_APPLY" -eq 1 ] && [ -n "$ACTION" ] && [ "$ACTION" != rollback ]; then
  dbk_usage; dbk_note "用法错误: --apply 只与 --rollback 等价(当前动作 --$ACTION 是只读的)"; exit "$DBK_USAGE"
fi
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "dbk-rollback"
if [ -z "$ACTION" ]; then
  if [ "$WANT_APPLY" -eq 1 ]; then ACTION=rollback; else ACTION=list; fi
fi

RB_STR="${DBK_RPM_OSTREE:-rpm-ostree}"; RB=(); read -r -a RB <<<"$RB_STR"
rs() { "${RB[@]}" "$@"; }                       # 待核实(以官方文档为准)
have_rb() { command -v "${RB[0]}" >/dev/null 2>&1; }

# status 文本解析(未在真机验证):部署条目行 = 可选标记(●/○/*) + <镜像引用>(含 ':' 且其后是 '//' 或 'fedora');
# 列表第一项 = 下一次启动的部署;带 ● 的那项 = 当前已启动的部署;`Pinned: yes` 行表示有部署被固定。
DEPRE='^[[:space:]]*(●|○|\*)?[[:space:]]*[A-Za-z0-9._+-]+:[^[:space:]]*(//|fedora)'
status_text() { rs status 2>&1 || true; }        # 待核实(以官方文档为准)
strip_mark() { sed -E 's/^[[:space:]]*(●|○|\*)?[[:space:]]*//'; }
dep_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE "$DEPRE" || true)"; printf '%s' "${n:-0}"; }
next_ref() { printf '%s\n' "${1:-}" | grep -m1 -E "$DEPRE" | strip_mark || true; }
booted_ref() { printf '%s\n' "${1:-}" | grep -m1 -E '^[[:space:]]*●' | strip_mark || true; }
pin_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE '^[[:space:]]*Pinned:[[:space:]]*yes' || true)"; printf '%s' "${n:-0}"; }
booted_ver() {
  printf '%s\n' "${1:-}" | awk '/^[[:space:]]*●/{f=1} f&&/^[[:space:]]*Version:/{sub(/^[[:space:]]*Version:[[:space:]]*/,"");print;exit}' || true
}
tail3() { printf '%s' "${1:-}" | tail -n 3 | tr '\n' ' '; }
print_st() { if [ "${DBK_JSON:-0}" -eq 1 ]; then dbk_note "$1"; else printf '%s\n' "$1"; fi; }

# --list:只读列出部署与固定状态(第一项=下次默认启动;● =当前已启动)。
do_list() {
  have_rb || { dbk_add_check "失败项: 未找到 ${RB[0]}(无法列出部署)"; dbk_exit FAIL "rpm-ostree 不可用:本机不是原子版或命令未安装,无法列出部署"; }
  local st; st="$(status_text)"
  print_st "$st"
  dbk_add_check "部署数=$(dep_count "$st");下一次启动=$(next_ref "$st");当前启动=$(booted_ref "$st");当前部署版本=$(booted_ver "$st");已固定部署数=$(pin_count "$st")"
  dbk_exit PASS "部署清单如上(列表第一项=下次默认启动,● =当前已启动);pin/回滚见 --pin / --unpin / --rollback"
}

# --check:07-7 复检三项(部署列表与 pin / nvidia 模块签名 / 会话类型)。只读。
do_check() {
  local st n next booted ver pins issues=0 manual=0 mk mo ls enrolled signer loaded
  have_rb || { dbk_add_check "失败项: 未找到 ${RB[0]}(无法读取部署列表)"; dbk_exit FAIL "rpm-ostree 不可用:本机不是原子版或命令未安装;请按发行版实际情况处理"; }
  st="$(status_text)"; n="$(dep_count "$st")"; next="$(next_ref "$st")"; booted="$(booted_ref "$st")"
  ver="$(booted_ver "$st")"; pins="$(pin_count "$st")"
  if [ "$n" -ge 1 ]; then
    dbk_add_check "部署列表: 共 $n 个部署;下一次启动=${next:-未取到};当前启动=${booted:-未取到};当前部署版本=${ver:-未取到};已固定部署数=$pins"
  else
    dbk_add_check "失败项: 部署列表读不到(rpm-ostree status 输出里没有部署条目)"; issues=$((issues + 1))
  fi
  ls="${DBK_LSMOD:-lsmod}"
  if command -v "$ls" >/dev/null 2>&1; then
    loaded="$("$ls" 2>&1 | grep -E '^nvidia' || true)"
    if [ -n "$loaded" ]; then dbk_add_check "lsmod: nvidia 模块已加载($(printf '%s\n' "$loaded" | head -n 1))"
    else dbk_add_check "需人工: lsmod 无 nvidia 模块(无独显或模块未加载),签名判定以 modinfo 为准"; manual=$((manual + 1)); fi
  else
    dbk_add_check "需人工: 未找到 $ls(无法核对 nvidia 模块是否加载)"; manual=$((manual + 1))
  fi
  mk="${DBK_MOKUTIL:-mokutil}"
  if command -v "$mk" >/dev/null 2>&1; then
    enrolled="$("$mk" --list-enrolled 2>&1 || true)"
    if [ -n "$(printf '%s\n' "$enrolled" | grep -v '^[[:space:]]*$' || true)" ]; then
      dbk_add_check "MOK: mokutil --list-enrolled 非空($(printf '%s\n' "$enrolled" | head -n 2 | tr '\n' ' '))"
    else
      dbk_add_check "失败项: mokutil --list-enrolled 为空(无已登记密钥;Secure Boot 下 nvidia 模块会被拒)"; issues=$((issues + 1))
    fi
  else
    dbk_add_check "需人工: 未找到 $mk(无法核对 MOK 已登记密钥)"; manual=$((manual + 1))
  fi
  mo="${DBK_MODINFO:-modinfo}"
  if command -v "$mo" >/dev/null 2>&1; then
    signer="$("$mo" -F signer nvidia 2>&1 || true)"
    if [ -n "$(printf '%s' "$signer" | tr -d '[:space:]')" ]; then dbk_add_check "nvidia 模块签名: signer=$signer"
    else dbk_add_check "失败项: modinfo -F signer nvidia 无输出(nvidia 模块未加载或未签名)"; issues=$((issues + 1)); fi
  else
    dbk_add_check "需人工: 未找到 $mo(无法核对 nvidia 模块签名)"; manual=$((manual + 1))
  fi
  case "${XDG_SESSION_TYPE:-}" in
    wayland) dbk_add_check "会话类型: wayland" ;;
    "") dbk_add_check "需人工: XDG_SESSION_TYPE 取不到(不在图形会话里?用 loginctl show-session 复核)"; manual=$((manual + 1)) ;;
    *) dbk_add_check "失败项: XDG_SESSION_TYPE=${XDG_SESSION_TYPE}(要求 wayland)"; issues=$((issues + 1)) ;;
  esac
  if [ "$issues" -gt 0 ]; then dbk_exit FAIL "07-7 复检未通过($issues 项):部署列表 / nvidia 模块签名 / 会话类型;逐条见 checks"; fi
  if [ "$manual" -gt 0 ]; then dbk_exit 需人工 "07-7 复检有 $manual 项无法判定(不属于失败,但必须人工确认);逐条见 checks"; fi
  dbk_exit PASS "07-7 复检通过:部署列表与 pin 状态可读、nvidia 模块签名有效、会话为 wayland"
}

# --pin / --unpin:先 dbk_need_yes(缺 --yes 时零写退 64),执行后复读固定状态。
do_pinstate() {
  local act="$1" desc out rc=0 st pins
  case "$act" in
    pin) desc="固定当前部署(防止被自动清理,作为变更前的回滚点)" ;;
    *) desc="取消固定当前部署(取消后可被 rpm-ostree cleanup 清理)" ;;
  esac
  dbk_need_yes "$desc" "${RB[*]} $act"       # 待核实(以官方文档为准)
  out="$(rs "$act" 2>&1)" || rc=$?       # 待核实(以官方文档为准)
  if [ "$rc" -ne 0 ]; then
    dbk_add_check "失败项: rpm-ostree $act 退出码 $rc"
    dbk_exit FAIL "rpm-ostree $act 失败: $(tail3 "$out");固定状态未改变"
  fi
  dbk_add_action "rpm-ostree $act"; dbk_mark_changed
  st="$(status_text)"; pins="$(pin_count "$st")"
  if [ "$act" = pin ] && [ "$pins" -gt 0 ]; then dbk_add_check "复读确认: 已有 $pins 个部署处于固定状态(Pinned: yes)"
  elif [ "$act" = unpin ] && [ "$pins" -eq 0 ]; then dbk_add_check "复读确认: 已无固定部署(Pinned: yes 计数 0)"
  else
    dbk_exit 需人工 "rpm-ostree $act 返回成功,但复读的固定状态与预期不符(固定数=$pins);status 文本解析未在真机验证,请人工确认"
  fi
  dbk_exit PASS "rpm-ostree $act 完成并复读确认(pin 只影响部署保留,不需要重启)"
}

# --rollback / --apply:切换下一次启动的部署。先 dbk_need_yes(缺 --yes 时零写退 64),执行后复读确认已切换。
do_rollback() {
  local st first_before booted_before first_after out rc=0
  dbk_need_yes "切换下一次启动的部署(rpm-ostree rollback;需重启后生效)" "${RB[*]} rollback"   # 待核实(以官方文档为准)
  st="$(status_text)"; first_before="$(next_ref "$st")"; booted_before="$(booted_ref "$st")"
  dbk_add_check "回滚前: 部署数=$(dep_count "$st");下一次启动=${first_before:-未取到};当前启动=${booted_before:-未取到}"
  out="$(rs rollback 2>&1)" || rc=$?       # 待核实(以官方文档为准)
  if [ "$rc" -ne 0 ]; then
    dbk_add_check "失败项: rpm-ostree rollback 退出码 $rc"
    dbk_exit FAIL "rpm-ostree rollback 失败: $(tail3 "$out");下一次启动的部署未改变"
  fi
  dbk_add_action "rpm-ostree rollback"; dbk_mark_changed
  st="$(status_text)"; first_after="$(next_ref "$st")"
  dbk_add_check "回滚后: 下一次启动=${first_after:-未取到};当前启动=$(booted_ref "$st")"
  if [ -n "$first_after" ] && [ "$first_after" != "$first_before" ]; then
    dbk_add_check "已切换: 下次默认启动的部署由 '$first_before' 变为 '$first_after'"
  else
    dbk_exit 需人工 "rpm-ostree rollback 返回成功,但 status 里下次默认启动的部署未变(${first_after:-未取到});先确认是否还有旧部署可回滚,再人工判断"
  fi
  dbk_note "需重启后生效:执行 systemctl reboot(或开机菜单选旧部署)。"
  dbk_note "注意:**用户数据不随部署回滚** —— /var 与 /var/home 不在部署内,回滚系统不会丢家目录数据。"
  dbk_exit PASS "已切换下一次启动的部署($first_before -> $first_after);需重启后生效;用户数据不随回滚"
}

case "$ACTION" in
  list) do_list ;;
  check) do_check ;;
  pin | unpin) do_pinstate "$ACTION" ;;
  rollback) do_rollback ;;
esac
