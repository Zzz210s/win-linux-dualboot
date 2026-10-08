#!/usr/bin/env bash
# 对应卡:05-15
# 破坏性:1
# L4 卡 05-15:按 templates/mimeapps.tsv(唯一真源)把默认应用绑定到 xdg-mime。
# 判据(--check,零写):逐行 ① 期望的 .desktop 在 $DBK_APPS_DIR(缺省 /usr/share/applications)或该用户
#   的 ~/.local/share/applications 里;不在 = 应用未装 = 2 需人工(先按 05-17);② `xdg-mime query default
#   <mime>` = 期望 desktop;不等 = 1 FAIL;命令缺失或查询报错 = 2 需人工。优先级 FAIL(1) > 需人工(2)。
# --apply(需 root,且必须 --yes):备份该用户 ~/.config/mimeapps.list -> .dbk.bak(仅首次;无改动不备份)
#   -> 逐行 `xdg-mime default <desktop> <mime>`(幂等:已是该值就跳过)-> 复读判据。
# --user <名字> 指定目标用户:所有 xdg-mime 以该用户身份执行(runuser -> sudo -u;夹具用 DBK_RUNUSER 注入)。
# 注入(夹具用,真机不需要):DBK_MIMEAPPS_TPL / DBK_APPS_DIR / DBK_APPS_USER_DIR / DBK_HOME /
#   DBK_XDG_MIME / DBK_MIMEAPPS / DBK_RUNUSER。夹具级验证,真机未跑。
# 回滚:还原 <DBK_MIMEAPPS>.dbk.bak(或删掉 --apply 写入的行)后重登桌面。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: set-default-apps.sh [--user <name>] [--check|--apply --yes] [--json] [--log <路径>] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

MIMEAPPS_TPL="${DBK_MIMEAPPS_TPL:-$ROOT/templates/mimeapps.tsv}"
APPS_DIR="${DBK_APPS_DIR:-/usr/share/applications}"
XDG_MIME="${DBK_XDG_MIME:-xdg-mime}"
RUNUSER_CMD="${DBK_RUNUSER:-}"
TARGET_USER="${DBK_USER:-${SUDO_USER:-${USER:-}}}"
HOMEDIR="${DBK_HOME:-}"
USER_APPS_DIR="${DBK_APPS_USER_DIR:-}"
MIMEAPPS=""
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) dbk_cli_val "--user" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "set-default-apps"
dbk_enable_errtrap

ISSUES=(); MANUAL=(); NROWS=0

resolve_home() {
  if [ -z "$HOMEDIR" ] && [ -n "$TARGET_USER" ]; then
    HOMEDIR="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
  fi
  return 0
}
set_dirs() {
  resolve_home
  if [ -z "$USER_APPS_DIR" ]; then USER_APPS_DIR="${HOMEDIR:-$HOME}/.local/share/applications"; fi
  MIMEAPPS="${DBK_MIMEAPPS:-${HOMEDIR:-$HOME}/.config/mimeapps.list}"
  return 0
}
read_rows() { awk -F'\t' 'NF>=2 && $1 !~ /^[[:space:]]*#/ && $1 != "" {print}' "$MIMEAPPS_TPL" 2>/dev/null || true; }
desktop_found() {
  local id="$1"
  if [ -n "$APPS_DIR" ] && [ -e "$APPS_DIR/$id" ]; then return 0; fi
  if [ -n "$USER_APPS_DIR" ] && [ -e "$USER_APPS_DIR/$id" ]; then return 0; fi
  return 1
}
mime_query() {
  local out rc=0
  out="$(run_as_user "$XDG_MIME" query default "$1" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then printf '@@ERR@@%s' "$(printf '%s' "$out" | tr '\n' ' ')"; return 0; fi
  printf '%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
}
# 目标用户上下文:夹具用 DBK_RUNUSER 注入;真机优先 runuser,其次 sudo -u;都不是就直接执行。
run_as_user() {
  if [ -n "$RUNUSER_CMD" ]; then "$RUNUSER_CMD" -u "$TARGET_USER" -- "$@"; return $?; fi
  if [ "$(id -u)" -eq 0 ] && [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ]; then
    if command -v runuser >/dev/null 2>&1; then runuser -u "$TARGET_USER" -- "$@"; return $?
    elif command -v sudo >/dev/null 2>&1; then sudo -u "$TARGET_USER" -- "$@"; return $?
    fi
  fi
  "$@"
}

judge() {
  ISSUES=(); MANUAL=(); NROWS=0
  local have_xdg=0 mime desktop cur
  set_dirs
  if [ ! -r "$MIMEAPPS_TPL" ]; then ISSUES+=("找不到 mimeapps 模板 $MIMEAPPS_TPL"); return 0; fi
  if command -v "$XDG_MIME" >/dev/null 2>&1; then have_xdg=1
  else MANUAL+=("找不到命令 $XDG_MIME:读不到当前绑定(default 也写不了)"); fi
  while IFS=$'\t' read -r mime desktop _ <&3; do
    NROWS=$((NROWS + 1))
    if ! desktop_found "$desktop"; then
      MANUAL+=("$mime:期望的 $desktop 不在 $APPS_DIR 或 $USER_APPS_DIR(应用未装,先按 05-17)")
      continue
    fi
    if [ "$have_xdg" -ne 1 ]; then continue; fi
    cur="$(mime_query "$mime")"
    case "$cur" in
      '@@ERR@@'*) MANUAL+=("$mime:xdg-mime query default 失败(${cur#@@ERR@@});请人工确认") ;;
      "$desktop") dbk_add_check "$mime -> $desktop" ;;
      *) ISSUES+=("$mime 当前绑定 '$cur' != 期望 '$desktop'") ;;
    esac
  done 3< <(read_rows)
  if [ "$NROWS" -eq 0 ]; then ISSUES+=("模板 $MIMEAPPS_TPL 没有可用数据行(mime <TAB> desktop)"); fi
  return 0
}

apply_run() {
  local mime desktop cur item
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --user <name> --apply --yes"
  fi
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    dbk_usage; dbk_note "用法错误: --apply 必须用 --user <name> 指定目标用户(不要改 root 的 mimeapps.list)"; exit "$DBK_USAGE"
  fi
  set_dirs
  if [ -z "$HOMEDIR" ] || [ ! -d "$HOMEDIR" ]; then
    dbk_usage; dbk_note "用法错误: 用户 $TARGET_USER 的家目录不存在或无法解析(可用 DBK_HOME 注入)"; exit "$DBK_USAGE"
  fi
  if [ ! -r "$MIMEAPPS_TPL" ]; then dbk_add_check "找不到模板:$MIMEAPPS_TPL"; dbk_exit FAIL "找不到 mimeapps 模板 $MIMEAPPS_TPL"; fi
  if ! command -v "$XDG_MIME" >/dev/null 2>&1; then
    dbk_add_check "找不到命令:$XDG_MIME"; dbk_exit 需人工 "找不到 $XDG_MIME:写不了绑定(先装 xdg-utils)"
  fi
  NEED=()
  while IFS=$'\t' read -r mime desktop _ <&3; do
    if ! desktop_found "$desktop"; then continue; fi
    cur="$(mime_query "$mime")"
    case "$cur" in
      '@@ERR@@'*) continue ;;
      "$desktop") dbk_add_check "$mime 已是 $desktop,未改动" ;;
      *) NEED+=("$mime|$desktop") ;;
    esac
  done 3< <(read_rows)
  if [ "${#NEED[@]}" -gt 0 ]; then
    if [ -e "$MIMEAPPS.dbk.bak" ]; then dbk_add_action "备份已存在,保留不覆盖:$MIMEAPPS.dbk.bak"
    elif [ -e "$MIMEAPPS" ]; then
      if cp -a "$MIMEAPPS" "$MIMEAPPS.dbk.bak"; then dbk_add_action "备份 $MIMEAPPS -> $MIMEAPPS.dbk.bak(仅首次)"; fi
    fi
    if ! mkdir -p "$(dirname "$MIMEAPPS")"; then dbk_add_check "警告: 无法创建 $(dirname "$MIMEAPPS")"; fi
    for item in "${NEED[@]}"; do
      mime="${item%%|*}"; desktop="${item#*|}"
      if run_as_user "$XDG_MIME" default "$desktop" "$mime"; then
        dbk_add_action "xdg-mime default $desktop $mime"; dbk_mark_changed
      else
        dbk_add_check "警告: xdg-mime default $desktop $mime 返回非零(复读时会判 FAIL)"
      fi
    done
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项绑定与 mimeapps.tsv 不符;逐条见 checks(缺应用的先按 05-17)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks"
  fi
  dbk_exit PASS "$msg:$NROWS 行绑定全部与 mimeapps.tsv 一致"
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
judge
if [ "$DBK_MODE" = apply ]; then finish "默认应用绑定已执行(--apply;复读判据)"
else finish "默认应用绑定判据核对完成(--check 零写)"; fi
