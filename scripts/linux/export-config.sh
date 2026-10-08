#!/usr/bin/env bash
# 对应卡:05-18
# 破坏性:1(--apply 会写快照目录;缺 --yes → 64 且零写)
# 用途:把可快照带走的配置落成五份文本快照(重装/换机后由 import-config.sh 复原)。
#   --check 只读:现场重新生成五份快照,与 $CFG 下同名文件逐文件比对(忽略纯注释行与空行,忽略 manifest.txt)。
# 判据(--check,零写):快照目录或某份缺失 → 2 需人工(提示先 --apply --yes);有实质差异 → 2 需人工并打印差异前 5 行;
#   无差异 → 0;取不到数据(命令缺失/接口不可用)→ 2 需人工。本脚本 --check 不产生 FAIL。
# 五份快照:$CFG/{dconf.txt,etc-config-diff.txt,flatpak-apps.txt,brew-bundle.txt,layered-pkgs.txt}
#   缺省 $CFG = <repo>/baseline/config(DBK_CONFIG_DIR 可覆盖);另写 manifest.txt(时间戳 + 五份文件 sha256)。
# --apply --yes:需 root;目录不存在就建;已有旧快照先备份到 $CFG/pre-export-<时间戳>/;写出五份 + manifest 后复读判定。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 夹具级验证,真机未跑。用法: export-config.sh [--check|--apply --yes] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入点(夹具用,真机不需要):DBK_CONFIG_DIR / DBK_DCONF / DBK_OSTREE / DBK_FLATPAK / DBK_RPM_OSTREE / DBK_BREW_LIB;
#   brew 清单经 dbk-brew.sh 的 brew_bundle_dump <目标文件> 落盘(库路径可用 DBK_BREW_LIB 覆盖);
#   分层包经 dbk-pkg.sh 的 pkg_layered_list(见该库头部的返回值约定)。
# 待核实(以官方文档为准):flatpak list --columns 的字段名与输出格式、dconf dump / 的文本是否逐次稳定、
#   ostree admin config-diff 的行前缀与排序;上述均未在真机验证(夹具级验证,真机未跑)。
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
dbk_log_default "export-config"

CFG="${DBK_CONFIG_DIR:-$ROOT/baseline/config}"
mapfile -t FILES < <(snap_files)

MANUAL=(); DIFFS=(); FAILS=(); TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; return 0; }
trap cleanup EXIT
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbk-export.XXXXXX")"

# 比对口径(去空行与纯注释行)与五份快照的清单表/采集分派都在 dbk-config-snapshot.sh(snap_norm / snap_files / snap_gen)。
norm() { snap_norm "${1:-}"; }
gen_file() { snap_gen "$1" "$2" 1; }


# cmp_file <文件名> <check|apply>:生成现场快照并与 $CFG 下同名文件比对;差异按模式进 DIFFS 或 FAILS。
cmp_file() {
  local n="$1" mode="$2" cur="$TMP/$1" d
  gen_file "$n" "$cur" || return 0
  if [ ! -r "$CFG/$n" ]; then MANUAL+=("快照缺失:$CFG/$n(先 --apply --yes)"); return 0; fi
  if diff -u <(norm "$CFG/$n") <(norm "$cur") >"$TMP/$n.diff" 2>&1; then return 0; fi
  d="$(head -n 5 "$TMP/$n.diff" | tr '\n' ' ')"
  if [ "$mode" = apply ]; then FAILS+=("$n 复读与刚写入的快照不一致:$d"); else DIFFS+=("$n:$d"); fi
}

run_compare() {
  local mode="$1" n
  if [ ! -d "$CFG" ]; then MANUAL+=("快照目录不存在:$CFG(先 --apply --yes)"); return 0; fi
  for n in "${FILES[@]}"; do cmp_file "$n" "$mode"; done
  return 0
}

write_manifest() {
  local n
  {
    printf '# 时间戳: %s\n' "$(date '+%F %T%z')"
    for n in "${FILES[@]}"; do
      if [ -r "$CFG/$n" ]; then printf '%s  %s\n' "$(sha256sum "$CFG/$n" | awk '{print $1}')" "$n"
      else printf 'MISSING  %s\n' "$n"; fi
    done
  } >"$CFG/manifest.txt.tmp" && mv -f "$CFG/manifest.txt.tmp" "$CFG/manifest.txt"
}

apply_all() {
  local n ts bak
  if ! mkdir -p "$CFG"; then FAILS+=("无法创建 $CFG"); return 0; fi
  if [ -e "$CFG/manifest.txt" ] || [ -e "$CFG/${FILES[0]}" ]; then
    ts="$(date '+%Y%m%d-%H%M%S')"; bak="$CFG/pre-export-$ts"
    if mkdir -p "$bak" && cp -a "$CFG"/*.txt "$bak/" 2>/dev/null; then
      dbk_add_action "备份旧快照 -> $bak"
    else
      FAILS+=("备份旧快照失败:$bak")
    fi
  fi
  for n in "${FILES[@]}"; do
    gen_file "$n" "$TMP/$n" || true
    if [ -r "$TMP/$n" ] && cp -a "$TMP/$n" "$CFG/$n"; then dbk_add_action "写入 $CFG/$n"
    else FAILS+=("写入失败:$CFG/$n"); fi
  done
  write_manifest
  dbk_mark_changed
}

finish() {
  local m
  for m in ${FAILS[@]+"${FAILS[@]}"}; do dbk_add_check "失败项: $m"; done
  for m in ${DIFFS[@]+"${DIFFS[@]}"}; do dbk_add_check "漂移: $m"; done
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ "${#FAILS[@]}" -gt 0 ]; then dbk_exit FAIL "$1:有 ${#FAILS[@]} 项失败;逐条见 checks"; fi
  if [ "${#DIFFS[@]}" -gt 0 ]; then dbk_exit 需人工 "$1:有 ${#DIFFS[@]} 份快照与现状有实质漂移;逐条见 checks(前 5 行差异)"; fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then dbk_exit 需人工 "$1:有 ${#MANUAL[@]} 项需人工(缺失/取不到数据);逐条见 checks"; fi
  dbk_exit PASS "$1:五份快照与现状一致"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"
  fi
  apply_all
  run_compare apply
  finish "配置快照已落盘(--apply;复读判定)"
fi

run_compare check
finish "配置快照核对完成(--check 零写)"
