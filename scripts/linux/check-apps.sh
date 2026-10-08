#!/usr/bin/env bash
# 对应卡:05-17
# 破坏性:0
# L4 卡 05-17:按 templates/apps.tsv(唯一真源)断言必需应用在位;只读脚本,不装任何东西(VFIO 为被否项)。
# 通道:flatpak -> $DBK_FLATPAK(缺省 flatpak) `info <id>`;brew -> dbk-brew.sh 的 brew_formula_installed;
#   native -> `command -v <命令>`;web/win -> 只打一行「跳过(浏览器/回 Windows)」,既不算缺失也不作判据。
# 判据:必需(1) 且缺 -> 1 FAIL;必需(0) 且缺 -> 记录项(dbk_add_check「记录项: …」,不影响退出码);
#   通道工具取不到(flatpak 命令缺 / brew 接口缺)-> 2 需人工(环境问题,不是应用缺失)。优先级 FAIL(1) > 需人工(2)。
# 只读保证:--apply 与 --check 完全相同(只有 flatpak info / command -v / brew_formula_installed 三类读动作)。
# 不接 --yes(破坏性 0):给了 -> 64。
# 注入(夹具用,真机不需要):DBK_APPS_TSV / DBK_FLATPAK / DBK_BREW_LIB。夹具级验证,真机未跑。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-apps.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

APPS_TSV="${DBK_APPS_TSV:-$ROOT/templates/apps.tsv}"
FLATPAK="${DBK_FLATPAK:-flatpak}"
BREW_LIB="${DBK_BREW_LIB:-$HERE/dbk-brew.sh}"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) dbk_usage; dbk_note "用法错误: check-apps.sh 是只读脚本(# 破坏性:0),不接受 --yes"; exit "$DBK_USAGE" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "check-apps"
dbk_enable_errtrap

ISSUES=(); MANUAL=(); NROWS=0
HAVE_FLATPAK=0; HAVE_BREW=0
if command -v "$FLATPAK" >/dev/null 2>&1; then HAVE_FLATPAK=1; fi
if [ -r "$BREW_LIB" ]; then
  # shellcheck source=scripts/linux/dbk-brew.sh disable=SC1091
  . "$BREW_LIB"
  if command -v brew_formula_installed >/dev/null 2>&1; then HAVE_BREW=1; fi
fi
read_rows() { awk -F'\t' 'NF>=4 && $1 !~ /^[[:space:]]*#/ && $1 != "" {print}' "$APPS_TSV" 2>/dev/null || true; }

check_row() {
  local name="$1" ch="$2" ident="$3" req="$4" rc=0 inst=0
  case "$ch" in
    flatpak)
      if [ "$HAVE_FLATPAK" -ne 1 ]; then MANUAL+=("$name($ch $ident):$FLATPAK 命令取不到,无法判定(环境问题)"); return 0; fi
      if "$FLATPAK" info "$ident" >/dev/null 2>&1; then inst=1; fi ;;
    brew)
      if [ "$HAVE_BREW" -ne 1 ]; then MANUAL+=("$name($ch $ident):brew 薄接口取不到($BREW_LIB),无法判定(环境问题)"); return 0; fi
      if brew_formula_installed "$ident"; then inst=1
      else
        rc=$?
        if [ "$rc" -ne 1 ]; then MANUAL+=("$name($ch $ident):brew_formula_installed 返回 $rc(需人工)"); return 0; fi
      fi ;;
    native)
      # native 通道按「同名命令在位」判,而不是看 .desktop:所以 apps.tsv 的 native 项必须写可执行的命令名。
      if command -v "$ident" >/dev/null 2>&1; then inst=1; fi ;;
    web|win)
      dbk_add_check "跳过($ch):$name —— 浏览器/回 Windows"; return 0 ;;
    *)
      MANUAL+=("$name:未知通道 '$ch'(apps.tsv 只认 flatpak|brew|native|web|win)"); return 0 ;;
  esac
  if [ "$inst" -eq 1 ]; then dbk_add_check "$name($ch $ident)在位"; return 0; fi
  if [ "$req" = 1 ]; then ISSUES+=("必需应用缺失:$name($ch $ident)")
  else dbk_add_check "记录项:$name($ch $ident) 未安装(可选,不影响判定)"; fi
  return 0
}

judge() {
  ISSUES=(); MANUAL=(); NROWS=0
  local name ch ident req
  if [ ! -r "$APPS_TSV" ]; then ISSUES+=("找不到应用清单 $APPS_TSV"); return 0; fi
  while IFS=$'\t' read -r name ch ident req _ <&3; do
    if [ -z "$name" ]; then continue; fi
    NROWS=$((NROWS + 1))
    case "$req" in 0|1) ;; *) MANUAL+=("$name:必需列 '$req' 不是 0/1"); continue ;; esac
    check_row "$name" "$ch" "$ident" "$req"
  done 3< <(read_rows)
  if [ "$NROWS" -eq 0 ]; then ISSUES+=("清单 $APPS_TSV 没有可用数据行"); fi
  return 0
}

judge
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本只读(破坏性 0);--apply 与 --check 输出相同,不装任何应用。"; fi
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "应用清单核对发现 ${#ISSUES[@]} 项必需应用缺失;逐条见 checks"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "应用清单有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks"
fi
dbk_exit PASS "应用清单核对通过:$NROWS 行(web/win 只登记;缺可选应用见 checks 的记录项)"
