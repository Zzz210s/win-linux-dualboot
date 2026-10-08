#!/usr/bin/env bash
# 对应卡:05-18
# 破坏性:1(--apply 会回灌 dconf / 安装 Flatpak;缺 --yes → 64 且零写)
# 用途/判据:重装或换机后按 export-config.sh 的五份快照复原(回灌 dconf / 补装 Flatpak / 装 Homebrew 清单;分层包只打印命令)。
#   --check(零写):五份快照是否在位(缺 → 2 并列出缺哪份),在位则打印"将执行"清单并退 0;本模式不写任何东西。
#   --apply --yes(需 root):① 先备现状到 $CFG/pre-import-<时间戳>/;② **回灌前必须过 $CFG/manifest.txt 的 sha256 校验**(不过则一个写动作都不做);
#   ③ dconf 回灌(load / < dconf.txt);④ Flatpak 逐行 info 判已装则跳过,否则安装;⑤ Homebrew 清单经 dbk-brew.sh 的 brew_bundle_install;
#   ⑥ 分层包不自动装,打印命令并记需人工;⑦ 末尾自检:重新 dump 与快照比对,不等 → 1 FAIL(分层包不一致按需人工)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: import-config.sh [--check|--apply --yes] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入点(夹具用):DBK_CONFIG_DIR / DBK_DCONF / DBK_OSTREE / DBK_FLATPAK / DBK_RPM_OSTREE / DBK_BREW_LIB;接口契约见 dbk-brew.sh 与 dbk-pkg.sh。
# 待核实(以官方文档为准):Flatpak info/install 的退出码与 -y 位置、dconf load / 的输入格式、Homebrew 清单安装器参数——均未真机验证。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"
BREW_LIB="${DBK_BREW_LIB:-$HERE/dbk-brew.sh}"
if [ -r "$BREW_LIB" ]; then
  # shellcheck source=/dev/null disable=SC1090
  . "$BREW_LIB"
fi
# 快照表/比对口径/采集分派/manifest 校验拆到单职责库 dbk-config-snapshot.sh(原文件逼近 200 行上限;口径不变)。
# shellcheck source=scripts/linux/dbk-config-snapshot.sh disable=SC1091
. "$HERE/dbk-config-snapshot.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "import-config"

CFG="${DBK_CONFIG_DIR:-$ROOT/baseline/config}"
mapfile -t FILES < <(snap_files)
DC=(); FP=()   # 回灌用的命令(dconf 回灌 / flatpak 补装);快照采集的命令在 dbk-config-snapshot.sh 里自读 DBK_*
read -r -a DC <<<"${DBK_DCONF:-dconf}"
read -r -a FP <<<"${DBK_FLATPAK:-flatpak}"

MANUAL=(); FAILS=(); TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; return 0; }
trap cleanup EXIT
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbk-import.XXXXXX")"

have() { [ -x "${1:-}" ] || command -v "${1:-}" >/dev/null 2>&1; }
norm() { snap_norm "${1:-}"; }
lines() { snap_norm "${1:-}"; }   # 语义别名:读清单时用 lines,比对时用 norm
# gen_file <文件名> <输出路径>:现状采集(供 pre-import 备份与末尾自检);分层包清单在 import 侧只读、不采集。
#   五份快照的清单表、命令来源与采集口径见 dbk-config-snapshot.sh 的 snap_files / snap_gen。
gen_file() {
  case "$1" in
    layered-pkgs.txt) return 1 ;;
    *) snap_gen "$1" "$2" 0 ;;
  esac
}


check_present() {
  local n miss=0
  for n in "${FILES[@]}"; do
    if [ ! -r "$CFG/$n" ]; then MANUAL+=("快照缺失:$CFG/$n"); miss=1; fi
  done
  [ "$miss" -eq 1 ] && return 1
  return 0
}

do_backup() {
  local n
  if ! mkdir -p "$1"; then FAILS+=("无法创建备份目录:$1"); return 0; fi
  for n in "${FILES[@]}"; do gen_file "$n" "$1/$n" || true; done
  dbk_add_action "现状已另存 -> $1"
}

do_dconf_load() {
  have "${DC[0]}" || { MANUAL+=("dconf 命令缺失,无法回灌 dconf.txt(需人工)"); return 0; }
  if "${DC[@]}" load / <"$CFG/dconf.txt" >>"$TMP/dconf-load.log" 2>&1; then
    dbk_add_action "dconf 回灌:$CFG/dconf.txt"
    dbk_mark_changed
  else
    FAILS+=("dconf 回灌失败(dconf load 非零);dconf.txt 可能被改坏")
  fi
}

do_flatpak() {
  local id
  have "${FP[0]}" || { MANUAL+=("flatpak 命令缺失,清单需人工补装:$CFG/flatpak-apps.txt"); return 0; }
  while IFS= read -r id; do
    id="${id%%[[:space:]]*}"
    case "$id" in ''|'#'*) continue ;; esac
    if "${FP[@]}" info "$id" >/dev/null 2>&1; then dbk_add_action "Flatpak 已装,跳过:$id"
    elif "${FP[@]}" install -y "$id" >>"$TMP/flatpak.log" 2>&1; then dbk_add_action "Flatpak 补装:$id"; dbk_mark_changed
    else FAILS+=("Flatpak 补装失败:$id"); fi
  done < <(lines "$CFG/flatpak-apps.txt")
}

do_brew() {
  local st=0
  if command -v brew_bundle_install >/dev/null 2>&1; then
    brew_bundle_install "$CFG/brew-bundle.txt" >>"$TMP/brew.log" 2>&1 || st=$?
  else
    st=2
  fi
  case "$st" in
    0) dbk_add_action "Homebrew 清单安装:$CFG/brew-bundle.txt"; dbk_mark_changed ;;
    9) MANUAL+=("Homebrew 清单被跳过(DBK_SKIP_PKG=1),需人工确认清单已对齐") ;;
    *) MANUAL+=("Homebrew 清单安装失败/需人工(rc=$st):逐条装后重跑 --check") ;;
  esac
}

do_layered() {
  local pkgs
  pkgs="$(lines "$CFG/layered-pkgs.txt" | tr '\n' ' ')"
  pkgs="${pkgs% }"
  [ -n "$pkgs" ] || return 0
  dbk_add_check "需人工:分层包不自动装;请手工执行: $PKG_CMD install $pkgs"
  MANUAL+=("分层包需人工:$pkgs")
}

self_check() {
  local n cur
  for n in dconf.txt etc-config-diff.txt flatpak-apps.txt brew-bundle.txt; do
    cur="$TMP/$n"
    gen_file "$n" "$cur" || continue
    if ! diff -u <(norm "$CFG/$n") <(norm "$cur") >"$TMP/$n.diff" 2>&1; then
      FAILS+=("$n 自检不一致:$(head -n 5 "$TMP/$n.diff" | tr '\n' ' ')")
    fi
  done
  if command -v pkg_layered_list >/dev/null 2>&1 && pkg_layered_list >"$TMP/layered-live.txt" 2>/dev/null; then
    if ! diff -u <(norm "$CFG/layered-pkgs.txt") <(norm "$TMP/layered-live.txt") >/dev/null 2>&1; then
      MANUAL+=("分层包与快照不一致(不自动装,需人工按上面的命令执行)")
    fi
  fi
}

finish() {
  local m
  for m in ${FAILS[@]+"${FAILS[@]}"}; do dbk_add_check "失败项: $m"; done
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ "${#FAILS[@]}" -gt 0 ]; then dbk_exit FAIL "$1:有 ${#FAILS[@]} 项失败;逐条见 checks"; fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then dbk_exit 需人工 "$1:有 ${#MANUAL[@]} 项需人工;逐条见 checks"; fi
  dbk_exit PASS "$1:五份快照已复原且自检一致"
}

if [ "$DBK_MODE" = apply ]; then
  if ! check_present; then
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "--apply 前五份快照必须齐全;缺件见 checks(先跑 export-config.sh --apply --yes)"
  fi
  if ! snap_verify_manifest "$CFG"; then
    MANUAL+=(${SNAP_MANUAL[@]+"${SNAP_MANUAL[@]}"})
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "--apply 前快照未通过 manifest 校验;**未回灌任何配置**,逐条见 checks"
  fi
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))" ; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes" ; }
  do_backup "$CFG/pre-import-$(date '+%Y%m%d-%H%M%S')"
  do_dconf_load
  do_flatpak
  do_brew
  do_layered
  self_check
  finish "配置复原已执行(--apply;自检判定)"
fi

if check_present; then
  dbk_add_check "将执行:dconf 回灌 / Flatpak 按清单补装 / Homebrew 清单安装;分层包只打印命令(见 $CFG)"
  dbk_exit PASS "五份快照在位;待执行清单见 checks(--check 零写)"
fi
for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
dbk_exit 需人工 "缺快照;逐条见 checks(先跑 export-config.sh --apply --yes)"
