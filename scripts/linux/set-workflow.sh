#!/usr/bin/env bash
# 对应卡:05-16
# 破坏性:1(--apply 会写 GNOME 的 gsettings/dconf 配置并落 dconf 备份;必须显式 --yes)
# L4 体验层:按 templates/workflow.tsv(唯一真源)固定虚拟桌面工作流(工作区数量、关掉动态工作区、
#   前两个工作区直达快捷键);不换合成器(niri / KDE 为非目标)。
# 判据(--check,零写):逐行 `gsettings get <schema> <key>` 与清单期望值逐字比对(去首尾空白):
#   不等 → FAIL;DBK_GSETTINGS 缺失 → 需人工;报错含 No such schema / No such key → 需人工(消息带原始报错首行);
#   其它报错 → 需人工(脚本判不了)。清单不可读 → FAIL。
# --apply(需 root,必须 --yes):① DBK_DCONF(缺省 dconf)dump /org/gnome/ 备份到 DBK_DCONF_BAK
#   (缺省 ~/.config/dbk/workflow.dbk.bak,仅首次,目录不存在就建);备份失败则不写设置;
#   ② 逐行 `gsettings set`(幂等:已是该值就不写;schema/key 不存在的行记需人工并跳过);③ 复读判据。
#   复读不过 → FAIL。缺 --yes → 64 零写(由库层在解析参数时拦截)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: set-workflow.sh [--check|--apply --yes] [--user <名字>] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要设置):DBK_GSETTINGS / DBK_DCONF / DBK_DCONF_BAK。
# 夹具级验证,真机未跑。待核实(以 GNOME 官方文档为准):各 schema/key 名与 `gsettings get` 的输出写法;
#   真机由 sudo 执行时须在目标用户图形会话里跑(见 05-16 坑,root 改的是 root 自己的配置)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

WF_TSV="$ROOT/templates/workflow.tsv"
TARGET_USER="${SUDO_USER:-${USER:-}}"; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) dbk_cli_val "--user" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_enable_errtrap
dbk_log_default "set-workflow"

GS_STR="${DBK_GSETTINGS:-gsettings}"; GS=()
DC_STR="${DBK_DCONF:-dconf}"; DC=()
read -r -a GS <<<"$GS_STR"
read -r -a DC <<<"$DC_STR"
gs_run() { command "${GS[@]}" "$@"; }
dc_run() { command "${DC[@]}" "$@"; }

# 备份路径缺省:~ 取目标用户的家目录(--user 指定;取不到就退回当前 $HOME)。
home_of() {
  local u="${1:-}" h=""
  if [ -n "$u" ] && command -v getent >/dev/null 2>&1; then h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"; fi
  if [ -z "$h" ]; then h="${HOME:-}"; fi
  printf '%s' "$h"
}
BAK="${DBK_DCONF_BAK:-}"
if [ -z "$BAK" ]; then BAK="$(home_of "$TARGET_USER")/.config/dbk/workflow.dbk.bak"; fi

ISSUES=(); MANUAL=(); EXTRA_ISSUES=(); EXTRA_MANUAL=()

trim() { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

check_all() {
  local schema="" key="" want="" got="" rc=0 first="" n=0
  ISSUES=(); MANUAL=()
  if [ ! -r "$WF_TSV" ]; then ISSUES+=("找不到清单 $WF_TSV(仓库内应为 templates/workflow.tsv;它是唯一真源)"); return 0; fi
  if ! command -v "${GS[0]}" >/dev/null 2>&1; then MANUAL+=("未找到 ${GS[0]}:无法读取 GNOME 工作区设置(脚本判不了)"); return 0; fi
  while IFS=$'\t' read -r schema key want || [ -n "${schema:-}" ]; do
    case "$schema" in ''|'#'*) continue ;; esac
    if [ -z "$key" ] || [ -z "$want" ]; then ISSUES+=("清单行非法(需 schema<TAB>key<TAB>期望三列):$schema"); continue; fi
    n=$((n + 1)); rc=0
    got="$(gs_run get "$schema" "$key" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      first="$(printf '%s\n' "$got" | head -n1)"
      case "$got" in
        *"No such schema"*) MANUAL+=("$schema $key:schema 不存在(原始报错:$first);按 05-16 改清单去掉该行,不要硬塞") ;;
        *"No such key"*) MANUAL+=("$schema $key:key 不存在(原始报错:$first)") ;;
        *) MANUAL+=("$schema $key:gsettings get 失败(原始报错:$first)") ;;
      esac
      continue
    fi
    if [ "$(trim "$got")" = "$(trim "$want")" ]; then dbk_add_check "$schema $key = $(trim "$got")(与清单一致)"
    else ISSUES+=("$schema $key 当前 $(trim "$got"),清单期望 $(trim "$want")(--apply 会写入)"); fi
  done <"$WF_TSV"
  if [ "$n" -eq 0 ]; then ISSUES+=("清单 $WF_TSV 无有效行(应为 schema<TAB>key<TAB>期望三列)"); fi
  return 0
}

backup_dconf() {
  local out="" st=0
  if [ -e "$BAK" ]; then dbk_add_action "备份已存在,保留不覆盖:$BAK"; return 0; fi
  if ! command -v "${DC[0]}" >/dev/null 2>&1; then EXTRA_MANUAL+=("未找到 ${DC[0]}:未备份 dconf(改坏后用 dconf load 回灌)"); return 0; fi
  if ! mkdir -p "$(dirname "$BAK")"; then EXTRA_ISSUES+=("备份目录创建失败:$(dirname "$BAK")"); return 0; fi
  out="$(dc_run dump /org/gnome/ 2>&1)" || st=$?
  if [ "$st" -ne 0 ]; then EXTRA_ISSUES+=("${DC[0]} dump /org/gnome/ 失败:$(printf '%s' "$out" | head -n1);未备份前不写设置"); return 0; fi
  if printf '%s\n' "$out" >"$BAK"; then dbk_add_action "备份 dconf /org/gnome/ -> $BAK(仅首次)"; dbk_mark_changed
  else EXTRA_ISSUES+=("备份写入失败:$BAK"); fi
}

apply_rows() {
  local schema="" key="" want="" got="" out="" rc=0
  while IFS=$'\t' read -r schema key want || [ -n "${schema:-}" ]; do
    case "$schema" in ''|'#'*) continue ;; esac
    if [ -z "$key" ] || [ -z "$want" ]; then continue; fi
    rc=0
    got="$(gs_run get "$schema" "$key" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      case "$got" in
        *"No such schema"*|*"No such key"*) EXTRA_MANUAL+=("$schema $key 不存在,跳过(按 05-16 改清单):$(printf '%s' "$got" | head -n1)") ;;
        *) EXTRA_ISSUES+=("$schema $key:gsettings get 失败,未写:$(printf '%s' "$got" | head -n1)") ;;
      esac
      continue
    fi
    if [ "$(trim "$got")" = "$(trim "$want")" ]; then dbk_add_action "$schema $key 已是期望值,未写(幂等)"; continue; fi
    rc=0
    out="$(gs_run set "$schema" "$key" "$want" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then dbk_add_action "gsettings set $schema $key $want"; dbk_mark_changed
    else EXTRA_ISSUES+=("gsettings set $schema $key $want 失败:$(printf '%s' "$out" | head -n1)"); fi
  done <"$WF_TSV"
}

apply_run() {
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(在目标用户图形会话里执行,见 05-16 坑)"
  fi
  if [ ! -r "$WF_TSV" ]; then dbk_add_check "找不到清单 $WF_TSV"; dbk_exit FAIL "清单缺失:无法应用(见 checks)"; fi
  if ! command -v "${GS[0]}" >/dev/null 2>&1; then dbk_add_check "未找到 ${GS[0]}"; dbk_exit 需人工 "未找到 ${GS[0]}:无法写入 GNOME 设置"; fi
  backup_dconf
  if [ "${#EXTRA_ISSUES[@]}" -gt 0 ]; then return 0; fi
  apply_rows
  return 0
}

finish() {
  local msg="${1:-}" m
  ISSUES+=(${EXTRA_ISSUES[@]+"${EXTRA_ISSUES[@]}"})
  MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"})
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks(清单是唯一真源,改清单后重跑)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:清单逐行一致(工作区数量、动态工作区、Super+1/Super+2 直达快捷键)"
}

if [ "$DBK_MODE" = apply ]; then
  apply_run
  check_all
  finish "虚拟桌面工作流已执行(--apply;复读清单后判定)"
fi
check_all
finish "虚拟桌面工作流判据核对完成(--check 零写)"
