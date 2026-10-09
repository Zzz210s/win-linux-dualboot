#!/usr/bin/env bash
# 对应卡:05-19
# 破坏性:1(--apply 会经薄接口安装 flatpak/brew 应用;必须显式 --yes)
# L4 卡 05-19:按 templates/apps.tsv(唯一真源)核对必需应用并按通道安装。通道优先级(2026-10-06 定):
#   GUI 应用走 Flatpak(经 dbk-flatpak.sh)-> CLI 工具走 Homebrew(经 dbk-brew.sh)-> 只有需要内核模块/驱动的
#   系统级组件才允许分层,且必须逐项记账。**本脚本对 native 缺失只打印需人工命令(经 dbk-pkg.sh 的
#   pkg_layered_hint),绝不自动分层**;web/win 只登记不判定。
# 判据(--check,零写):逐行报「在位/缺/需人工(通道工具不可用)/跳过(--channel 或 web/win)」;
#   必需(1) 缺失(flatpak/brew)= 1 FAIL;native 必需缺失 = 2 需人工;通道工具取不到 = 2 需人工;可选缺失 = 记录项。
#   优先级 FAIL(1) > 需人工(2)。
# --apply(必须 --yes;缺 → 64 零写):只装**必需 = 1 且缺**的 flatpak/brew 项(幂等:已装不调接口);
#   不碰 native/web/win;不自动分层。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: install-apps.sh [--channel flatpak|brew|all(缺省 all)] [--check|--apply] [--yes] [--json]
#   [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要):DBK_APPS_TSV / DBK_FLATPAK / DBK_FLATPAK_REMOTE / DBK_BREW / DBK_BREW_LIB /
#   DBK_RPM_OSTREE / DBK_SKIP_PKG。
# 夹具级验证,真机未跑。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"
# shellcheck source=scripts/linux/dbk-brew.sh disable=SC1091
. "$HERE/dbk-brew.sh"
# shellcheck source=scripts/linux/dbk-flatpak.sh disable=SC1091
. "$HERE/dbk-flatpak.sh"

APPS_TSV="${DBK_APPS_TSV:-$ROOT/templates/apps.tsv}"
CHANNEL=all; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel) dbk_cli_val "--channel" "${2:-}"; CHANNEL="$2"; shift 2 ;;
    --channel=*) CHANNEL="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "install-apps"
dbk_enable_errtrap
case "$CHANNEL" in flatpak|brew|all) ;; *) dbk_usage; dbk_note "用法错误: --channel 只接受 flatpak|brew|all:$CHANNEL"; exit "$DBK_USAGE" ;; esac

ISSUES=(); MANUAL=(); NROWS=0; HAVE_FLATPAK=0; HAVE_BREW=0
if flatpak_avail >/dev/null 2>&1; then HAVE_FLATPAK=1; fi
if brew_avail >/dev/null 2>&1; then HAVE_BREW=1; fi
read_rows() { awk -F'\t' 'NF>=4 && $1 !~ /^[[:space:]]*#/ && $1 != "" {print}' "$APPS_TSV" 2>/dev/null || true; }

do_flatpak() {
  local name="$1" id="$2" req="$3" st=0
  if [ "$HAVE_FLATPAK" -ne 1 ]; then MANUAL+=("$name(flatpak $id):flatpak 命令取不到,无法判定(环境问题)"); return 0; fi
  if flatpak_installed "$id"; then dbk_add_check "$name(flatpak $id)在位"; return 0; fi
  if [ "$req" != 1 ]; then dbk_add_check "记录项:$name(flatpak $id) 未安装(可选)"; return 0; fi
  if [ "$DBK_MODE" != apply ]; then ISSUES+=("必需应用缺失:$name(flatpak $id)"); return 0; fi
  flatpak_install "$id" || st=$?
  case "$st" in
    0) dbk_add_action "安装 flatpak $id($name)"; dbk_mark_changed ;;
    9) dbk_add_check "记录项: DBK_SKIP_PKG=1,跳过 $id 安装" ;;
    2) MANUAL+=("$name(flatpak $id):安装需人工(原因见日志)") ;;
    *) ISSUES+=("$name(flatpak $id):安装失败(原因见日志)") ;;
  esac
  return 0
}

do_brew() {
  local name="$1" f="$2" req="$3" st=0 rc=0
  if [ "$HAVE_BREW" -ne 1 ]; then MANUAL+=("$name(brew $f):brew 薄接口取不到,无法判定(环境问题)"); return 0; fi
  if brew_formula_installed "$f"; then dbk_add_check "$name(brew $f)在位"; return 0; else rc=$?; fi
  if [ "$rc" -ne 1 ]; then MANUAL+=("$name(brew $f):brew 判定返回 $rc(需人工)"); return 0; fi
  if [ "$req" != 1 ]; then dbk_add_check "记录项:$name(brew $f) 未安装(可选)"; return 0; fi
  if [ "$DBK_MODE" != apply ]; then ISSUES+=("必需应用缺失:$name(brew $f)"); return 0; fi
  brew_install "$f" || st=$?
  case "$st" in
    0) dbk_add_action "安装 brew 公式 $f($name)"; dbk_mark_changed ;;
    9) dbk_add_check "记录项: DBK_SKIP_PKG=1,跳过 $f 安装" ;;
    2) MANUAL+=("$name(brew $f):安装需人工(原因见日志)") ;;
    *) ISSUES+=("$name(brew $f):安装失败(原因见日志)") ;;
  esac
  return 0
}

do_native() {
  local name="$1" ident="$2" req="$3" hint=""
  if command -v "$ident" >/dev/null 2>&1; then dbk_add_check "$name(native $ident)在位"; return 0; fi
  if [ "$req" != 1 ]; then dbk_add_check "记录项:$name(native $ident) 未安装(可选)"; return 0; fi
  hint="$(pkg_layered_hint "$name" 2>/dev/null || true)"
  MANUAL+=("$name(native $ident)缺失:不自动分层;如确需系统级组件,人工执行 $hint")
  return 0
}

judge() {
  ISSUES=(); MANUAL=(); NROWS=0
  local name ch ident req
  if [ ! -r "$APPS_TSV" ]; then ISSUES+=("找不到应用清单 $APPS_TSV"); return 0; fi
  while IFS=$'\t' read -r name ch ident req _ <&3; do
    [ -n "$name" ] || continue
    NROWS=$((NROWS + 1))
    case "$req" in 0|1) ;; *) MANUAL+=("$name:必需列 '$req' 不是 0/1"); continue ;; esac
    case "$ch" in
      web|win) dbk_add_check "跳过($ch):$name —— 浏览器/回 Windows"; continue ;;
      flatpak|brew|native) ;;
      *) MANUAL+=("$name:未知通道 '$ch'(apps.tsv 只认 flatpak|brew|native|web|win)"); continue ;;
    esac
    if [ "$CHANNEL" != all ] && [ "$CHANNEL" != "$ch" ]; then
      dbk_add_check "跳过(--channel $CHANNEL):$name($ch $ident)"; continue
    fi
    case "$ch" in
      flatpak) do_flatpak "$name" "$ident" "$req" ;;
      brew) do_brew "$name" "$ident" "$req" ;;
      native) do_native "$name" "$ident" "$req" ;;
    esac
  done 3< <(read_rows)
  if [ "$NROWS" -eq 0 ]; then ISSUES+=("清单 $APPS_TSV 没有可用数据行"); fi
  return 0
}

judge
if [ "$DBK_MODE" = apply ]; then dbk_note "说明: --apply 只装必需且缺的 flatpak/brew 项(幂等);native 项只提示、不自动分层。"; fi
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
  dbk_exit FAIL "应用安装层有 ${#ISSUES[@]} 项必需应用缺失或安装失败;逐条见 checks"
fi
if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "应用安装层有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks"
fi
dbk_exit PASS "应用安装层就绪:$NROWS 行已核对(必需项在位;可选缺失见 checks 记录项)"
