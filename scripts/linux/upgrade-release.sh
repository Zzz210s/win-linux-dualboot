#!/usr/bin/env bash
# 对应卡:05-10
# 破坏性:1
# 用途:发行版升级(Fedora 原子版:`rpm-ostree rebase` 到目标分支/镜像引用)。设计依据:
#   docs/design/02-fedora-atomic-variant-design.md 第 4 节(发行版升级 = 先 pin 当前部署 → rebase → 重启 → 复检,
#   不满意回滚到被固定的部署)与 docs/design/00-design.md 4.7 的 R1(变更前固定当前部署)、7.2(部署级回滚)。
# 判据(--check,零写):当前部署版本、rpm-ostree status 的镜像来源(下一次启动的部署)、当前分支是否已指向目标分支。
# --apply(需 --yes,库层按脚本头「# 破坏性:1」拦):
#   ① rpm-ostree pin 固定当前部署并复读确认(无法确认则**不执行 rebase**);② rpm-ostree rebase <branch>;
#   ③ 打印"需重启"与回滚路径(dbk-rollback.sh --rollback 或开机菜单选旧部署);
#   ④ 后置复检(版本 / XDG_SESSION_TYPE=wayland / lsmod 有 nvidia):rebase 只作用于**下一部署**,未重启时以
#      「需人工」+ 明确说明呈现,不假报 PASS。
# 关键纪律(设计 4 节):改部署之前必须先 pin;失败必须给失败项与原因,并保留被固定的部署作为回滚点。
# 用法: upgrade-release.sh [--check|--apply] [--branch <目标分支/镜像引用>] [--json] [--log <路径>] [--yes] [--step NN-K]
#   目标分支缺省读 DBK_TARGET_BRANCH;两者都没有时用占位符并在输出里标 # 待核实(占位符不得用于 --apply)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。默认只读(--check)。
# 注入(真机不需要设置):DBK_TARGET_BRANCH(目标分支)、DBK_RPM_OSTREE(覆盖 rpm-ostree 命令)。
# 待核实(以官方文档为准):rebase 的子命令与分支/镜像命名、pin 与 status 的复读解析均未在真机验证(夹具级验证)。
# 不启用 errtrap:只读探针失败是本脚本的预期分支(逐项登记 FAIL / 需人工),不得升级成中断。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

BRANCH="${DBK_TARGET_BRANCH:-}"; GIVEN=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --branch 缺取值(目标分支/镜像引用)"; exit "$DBK_USAGE"; }; BRANCH="$2"; shift 2 ;;
    --branch=*) BRANCH="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ -n "$BRANCH" ] && GIVEN=1
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "upgrade-release"
if [ "$GIVEN" -eq 0 ]; then
  BRANCH='ostree-image-signed:docker://ghcr.io/ublue-os/bluefin-nvidia:<新分支,待核实>'   # 待核实(以官方文档为准)
fi
if [ "$DBK_MODE" = apply ] && [ "$GIVEN" -eq 0 ]; then
  dbk_usage
  dbk_note "用法错误: --apply 必须用 --branch 指定真实的目标分支/镜像引用(缺省值是占位符,不可执行)"
  dbk_note "例: --branch fedora:fedora/45/x86_64/silverblue 或 ublue 变体的对应分支/镜像引用(值待核实)"
  exit "$DBK_USAGE"
fi

RB_STR="${DBK_RPM_OSTREE:-rpm-ostree}"; RB=(); read -r -a RB <<<"$RB_STR"
rs() { "${RB[@]}" "$@"; }                        # 待核实(以官方文档为准)
have_rb() { command -v "${RB[0]}" >/dev/null 2>&1; }
DEPRE='^[[:space:]]*(●|○|\*)?[[:space:]]*[A-Za-z0-9._+-]+:[^[:space:]]*(//|fedora)'
status_text() { rs status 2>&1 || true; }         # 待核实(以官方文档为准)
strip_mark() { sed -E 's/^[[:space:]]*(●|○|\*)?[[:space:]]*//'; }
dep_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE "$DEPRE" || true)"; printf '%s' "${n:-0}"; }
next_ref() { printf '%s\n' "${1:-}" | grep -m1 -E "$DEPRE" | strip_mark || true; }
booted_ref() { printf '%s\n' "${1:-}" | grep -m1 -E '^[[:space:]]*●' | strip_mark || true; }
pin_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE '^[[:space:]]*Pinned:[[:space:]]*yes' || true)"; printf '%s' "${n:-0}"; }
booted_ver() {
  printf '%s\n' "${1:-}" | awk '/^[[:space:]]*●/{f=1} f&&/^[[:space:]]*Version:/{sub(/^[[:space:]]*Version:[[:space:]]*/,"");print;exit}' || true
}
tail3() { printf '%s' "${1:-}" | tail -n 3 | tr '\n' ' '; }

if [ "$DBK_MODE" != apply ]; then
  have_rb || { dbk_add_check "失败项: 未找到 ${RB[0]}(无法读取部署与镜像来源)"; dbk_exit FAIL "rpm-ostree 不可用:本机不是原子版或命令未安装"; }
  ST="$(status_text)"; SRC="$(next_ref "$ST")"; VER="$(booted_ver "$ST")"
  dbk_add_check "升级前/现状: 部署数=$(dep_count "$ST");下一次启动=${SRC:-未取到};当前部署版本=${VER:-未取到};目标分支=$BRANCH$([ "$GIVEN" -eq 1 ] && printf '' || printf '(占位符,# 待核实)')"
  MATCH=0
  if [ "$GIVEN" -eq 1 ] && [ -n "$SRC" ] && printf '%s' "$SRC" | grep -qF -- "$BRANCH"; then MATCH=1; fi
  if [ "$GIVEN" -eq 0 ]; then
    dbk_exit 需人工 "无法判定升级是否达成:未给 --branch/DBK_TARGET_BRANCH(当前来源=${SRC:-未取到});加 --branch <目标分支/镜像引用> 后重跑"
  fi
  if [ "$MATCH" -eq 1 ]; then
    dbk_exit PASS "已达成:下一次启动的部署来源已指向目标分支($SRC);重启后按 --check 复检版本与模块"
  fi
  dbk_exit FAIL "下一次启动的部署来源与目标分支不符(来源='${SRC:-未取到}';目标='$BRANCH');先核对分支名,再决定 --apply"
fi

# --apply:先 pin(硬前置),再 rebase,最后后置复检。
ST1="$(status_text)"
dbk_add_check "升级前: 部署数=$(dep_count "$ST1");下一次启动=$(next_ref "$ST1");当前部署版本=$(booted_ver "$ST1")"
OUT=""; RC=0
OUT="$(rs pin 2>&1)" || RC=$?                    # 待核实(以官方文档为准)
if [ "$RC" -ne 0 ]; then
  dbk_add_check "失败项: rpm-ostree pin 退出码 $RC"
  dbk_exit FAIL "前置固定失败(rpm-ostree pin): $(tail3 "$OUT");按纪律未执行 rebase(先 pin 再 rebase)"
fi
dbk_add_action "rpm-ostree pin"; dbk_mark_changed
PINS="$(pin_count "$(status_text)")"
if [ "$PINS" -eq 0 ]; then
  dbk_add_check "需人工: rpm-ostree pin 返回成功但复读未见 Pinned: yes"
  dbk_exit 需人工 "无法确认当前部署已固定 → 按纪律不执行 rebase;请人工确认 rpm-ostree status 的固定状态后重跑"
fi
dbk_add_check "前置固定已确认: 已固定部署数=$PINS(作为回滚点)"
RC=0
OUT="$(rs rebase "$BRANCH" 2>&1)" || RC=$?       # 待核实(以官方文档为准)
if [ "$RC" -ne 0 ]; then
  dbk_add_check "失败项: rpm-ostree rebase $BRANCH 退出码 $RC"
  dbk_exit FAIL "rebase 失败: $(tail3 "$OUT");当前部署仍处于固定状态(可用 dbk-rollback.sh --rollback 或开机菜单回退)"
fi
dbk_add_action "rpm-ostree rebase $BRANCH"; dbk_mark_changed
dbk_note "需重启后生效:新部署在下次启动生效,执行 systemctl reboot。"
dbk_note "回滚路径:bash scripts/linux/dbk-rollback.sh --rollback(切换下一次启动的部署)或开机菜单选被固定的旧部署。"
ST2="$(status_text)"; BREF="$(booted_ref "$ST2")"; ISSUES=0; MANUAL=0
if [ -n "$BREF" ] && printf '%s' "$BREF" | grep -qF -- "$BRANCH"; then
  dbk_add_check "后置: 已运行在目标分支上($BREF)"
  V2="$(booted_ver "$ST2")"
  if [ -n "$V2" ]; then dbk_add_check "版本: $V2"; else dbk_add_check "失败项: 重启后的部署版本取不到"; ISSUES=$((ISSUES + 1)); fi
  case "${XDG_SESSION_TYPE:-}" in
    wayland) dbk_add_check "会话类型: wayland" ;;
    "") dbk_add_check "需人工: XDG_SESSION_TYPE 取不到(不在图形会话里?)"; MANUAL=$((MANUAL + 1)) ;;
    *) dbk_add_check "失败项: XDG_SESSION_TYPE=${XDG_SESSION_TYPE}(要求 wayland)"; ISSUES=$((ISSUES + 1)) ;;
  esac
  LM="$(lsmod 2>/dev/null || true)"
  if printf '%s\n' "$LM" | grep -qE '^nvidia'; then dbk_add_check "nvidia 模块已加载"
  else dbk_add_check "需人工: lsmod 未见 nvidia(无独显或模块未加载;按 05-3 处置)"; MANUAL=$((MANUAL + 1)); fi
  if [ "$ISSUES" -gt 0 ]; then dbk_exit FAIL "升级后复检未通过($ISSUES 项);逐条见 checks;可用 dbk-rollback.sh --rollback 回退"; fi
  if [ "$MANUAL" -gt 0 ]; then dbk_exit 需人工 "rebase 与重启已完成,但有 $MANUAL 项无法判定;逐条见 checks"; fi
  dbk_exit PASS "升级完成:已运行在 $BRANCH(版本 $V2)、会话 wayland、nvidia 已加载"
fi
dbk_add_check "后置: 下一次启动=$(next_ref "$ST2");当前启动=${BREF:-未取到}"
dbk_exit 需人工 "rebase 已写入下一部署,但当前运行的部署仍是 '${BREF:-未取到}' → 需重启后再复检(版本/wayland/nvidia);本步不算通过也不算失败"
