#!/usr/bin/env bash
# 对应卡:05-2
# 破坏性:1
# L4 卡 05-2:把"文档类"家目录(桌面/文档/下载/图片/视频/音乐)重定向到共享盘,对齐 Windows 侧已知文件夹重定向。
# 判据(--check,零写):① 模板合格(六条 XDG_*_DIR 且都指向 $SHARED_MNT,不含 .config/.ssh/.gnupg);
#   ②(缺省)共享盘已挂载;③ ~/.config/user-dirs.dirs 已按模板写入六条且都指向 $SHARED_MNT;④ 六条目标目录都存在(缺失记需人工,由 --apply 创建)。
# 家目录在原子版里是 /var/home/<user>(/home 是其符号链接);~/.config、~/.ssh、~/.gnupg 与代码仓库留在本地 root
# (NTFS 无 POSIX 权限语义;设计 3.6 / 3.16 / 4.5 / 5.3)。
# --apply(需要 root,且必须 --yes):备份 user-dirs.dirs -> .dbk.bak(仅首次)-> 写入六行 -> 以该用户身份跑
#   xdg-user-dirs-update --force -> 建目标目录 -> 复读判据。通常由 mount-shared.sh --apply 在挂载成功后调用。
# 注入(离线校验):DBK_SHARED_MNT / DBK_XDG_SNIPPET / DBK_HOME。夹具级验证,真机未跑。
# 用法:xdg-redirect.sh [--user <name>] [--template <片段路径>] [--skip-mount-check]
#   [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

SHARED_MNT="${DBK_SHARED_MNT:-/mnt/shared}"
KEYS='XDG_DESKTOP_DIR XDG_DOCUMENTS_DIR XDG_DOWNLOAD_DIR XDG_PICTURES_DIR XDG_VIDEOS_DIR XDG_MUSIC_DIR'
TARGET_USER="${SUDO_USER:-${USER:-}}"; SKIP_MOUNT_CHECK=0
XDG_TPL="${DBK_XDG_SNIPPET:-$ROOT/templates/user-dirs.dirs.snippet}"
HOMEDIR="${DBK_HOME:-}"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) dbk_cli_val "--user" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --template) dbk_cli_val "--template" "${2:-}"; XDG_TPL="$2"; shift 2 ;;
    --template=*) XDG_TPL="${1#*=}"; shift ;;
    --skip-mount-check) SKIP_MOUNT_CHECK=1; shift ;;
    --dry-run) shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "xdg-redirect"
dbk_enable_errtrap

resolve_home() {
  [ -n "$HOMEDIR" ] && return 0
  [ -n "$TARGET_USER" ] || return 0
  HOMEDIR="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
  return 0
}
shared_mounted() { [ "$(findmnt -rn -o TARGET "$SHARED_MNT" 2>/dev/null | head -n 1 || true)" = "$SHARED_MNT" ]; }
tpl_body() { grep -E '^XDG_[A-Z]+_DIR=' "$XDG_TPL" 2>/dev/null || true; }
tpl_ok() {   # 模板校验:六条齐全、全部指向共享盘、不含 .config/.ssh/.gnupg
  local body="${1:-}" k line n
  [ -n "$body" ] || return 1
  for k in $KEYS; do
    line="$(printf '%s\n' "$body" | grep -E "^$k=" | head -n 1 || true)"
    case "$line" in *"\"$SHARED_MNT/"*) ;; *) return 1 ;; esac
  done
  if printf '%s\n' "$body" | grep -qE '"(/home|~|\$HOME)/\.(config|ssh|gnupg)'; then return 1; fi
  n="$(printf '%s\n' "$body" | grep -c "\"$SHARED_MNT/" || true)"
  [ "$n" -eq 6 ] || return 1
  return 0
}
run_as_user() {
  if command -v runuser >/dev/null 2>&1; then runuser -u "$TARGET_USER" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo -u "$TARGET_USER" -- "$@"
  else su -s /bin/bash "$TARGET_USER" -c "$(printf '%q ' "$@")"; fi
}

ISSUES=(); MANUAL=(); EXTRA_MANUAL=()

judge() {
  local k line missing nd d
  ISSUES=(); MANUAL=()
  resolve_home
  CONFIG_DIR="$HOMEDIR/.config"; UDIRS="$CONFIG_DIR/user-dirs.dirs"; UDIRS_BAK="$UDIRS.dbk.bak"
  BODY="$(tpl_body)"
  if [ ! -r "$XDG_TPL" ]; then ISSUES+=("找不到 XDG 模板 $XDG_TPL(仓库内应为 templates/user-dirs.dirs.snippet)")
  elif tpl_ok "$BODY"; then dbk_add_check "模板合格:$XDG_TPL(六条都指向 $SHARED_MNT)"
  else ISSUES+=("模板 $XDG_TPL 不合格:需六条 XDG_*_DIR 都指向 $SHARED_MNT,且不得把 .config/.ssh/.gnupg 放共享盘"); fi
  if [ "$SKIP_MOUNT_CHECK" -eq 1 ]; then
    MANUAL+=("已按 --skip-mount-check 跳过共享盘挂载校验")
  elif shared_mounted; then dbk_add_check "共享盘已挂载:$(findmnt -rn -o SOURCE,FSTYPE -T "$SHARED_MNT" | head -n 1 || true)"
  else ISSUES+=("$SHARED_MNT 未挂载:先跑 scripts/linux/mount-shared.sh --apply --yes,否则重定向目标会落在本地 root 上"); fi
  if [ -z "$HOMEDIR" ]; then
    MANUAL+=("无法解析用户 '$TARGET_USER' 的家目录(用 --user <name> 指定桌面用户)")
  elif [ ! -d "$HOMEDIR" ]; then
    MANUAL+=("家目录 $HOMEDIR 不存在或不可读")
  else
    dbk_add_check "家目录:$HOMEDIR(原子版为 /var/home/<user>;~/.config、~/.ssh、~/.gnupg 留在本地)"
    if [ ! -r "$UDIRS" ]; then
      ISSUES+=("缺少 $UDIRS(--apply 会按模板写入)")
    else
      missing=0
      for k in $KEYS; do
        line="$(grep -E "^$k=" "$UDIRS" 2>/dev/null | head -n 1 || true)"
        case "$line" in *"\"$SHARED_MNT/"*) ;; *) missing=$((missing + 1)) ;; esac
      done
      if [ "$missing" -eq 0 ]; then dbk_add_check "user-dirs.dirs 六条都已指向 $SHARED_MNT"
      else ISSUES+=("user-dirs.dirs 有 $missing 条未指向 $SHARED_MNT(--apply 会按模板重写)"); fi
      nd=0
      while IFS= read -r line; do
        case "$line" in
          XDG_*_DIR=\"*) d="${line#*=}"; d="${d%\"}"; d="${d#\"}"; d="${d/#\$HOME/$HOMEDIR}"
            if [ ! -d "$d" ]; then nd=$((nd + 1)); fi ;;
        esac
      done <<EOF
$BODY
EOF
      if [ "$nd" -eq 0 ]; then dbk_add_check "六条目标目录都已存在"
      else MANUAL+=("有 $nd 条重定向目标目录不存在(--apply 会创建;需共享盘已挂载)"); fi
    fi
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#EXTRA_MANUAL[@]}" -gt 0 ]; then MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"}); fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks。修好后重跑本脚本(或加 --apply --yes 自动重写)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:六条文档类家目录都已指向 $SHARED_MNT"
}

apply_run() {
  local line d
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --user <name> --apply --yes"; }
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    dbk_usage; dbk_note "用法错误: 无法确定桌面用户,请用 --user <name> 指定(不要对 root 重定向家目录)"; exit "$DBK_USAGE"
  fi
  resolve_home
  if [ -z "$HOMEDIR" ] || [ ! -d "$HOMEDIR" ]; then
    dbk_usage; dbk_note "用法错误: 用户 $TARGET_USER 的家目录不存在或无法解析"; exit "$DBK_USAGE"
  fi
  CONFIG_DIR="$HOMEDIR/.config"; UDIRS="$CONFIG_DIR/user-dirs.dirs"; UDIRS_BAK="$UDIRS.dbk.bak"
  if [ "$SKIP_MOUNT_CHECK" -ne 1 ] && ! shared_mounted; then
    dbk_add_check "$SHARED_MNT 未挂载"; dbk_exit FAIL "$SHARED_MNT 未挂载:先跑 scripts/linux/mount-shared.sh --apply --yes,否则重定向目标会落在本地 root 上"
  fi
  BODY="$(tpl_body)"
  if [ ! -r "$XDG_TPL" ] || ! tpl_ok "$BODY"; then
    dbk_add_check "模板不合格:$XDG_TPL"; dbk_exit FAIL "模板校验失败:需要六条 XDG_*_DIR 都指向 $SHARED_MNT(见 checks)"
  fi
  GROUP="$(id -gn "$TARGET_USER")"
  if [ -e "$UDIRS_BAK" ]; then dbk_add_action "备份已存在,保留不覆盖: $UDIRS_BAK"
  elif [ -e "$UDIRS" ]; then cp -a "$UDIRS" "$UDIRS_BAK"; dbk_add_action "备份 $UDIRS -> $UDIRS_BAK(仅首次)"; fi
  mkdir -p "$CONFIG_DIR" || dbk_add_check "警告: 无法创建 $CONFIG_DIR"
  {
    printf '# 由 scripts/linux/xdg-redirect.sh 写入(模板: %s)\n' "$XDG_TPL"
    printf '%s\n' "$BODY"
  } >"$UDIRS"
  chown "$TARGET_USER:$GROUP" "$UDIRS" 2>/dev/null || dbk_add_check "警告: chown $UDIRS 未成功(属主未改,必要时手工 chown)"
  dbk_add_action "已写入 $UDIRS(六条 XDG_*_DIR)"; dbk_mark_changed
  if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    if run_as_user xdg-user-dirs-update --force; then dbk_add_action "已以 $TARGET_USER 身份执行 xdg-user-dirs-update --force"
    else dbk_add_check "警告: xdg-user-dirs-update --force 返回非零(六行已写入,注销重登后再核对)"; fi
  else
    EXTRA_MANUAL+=("未找到 xdg-user-dirs-update(Silverblue 应自带该命令):六行已写入,请注销重登后人工核对")
  fi
  while IFS= read -r line; do
    case "$line" in
      XDG_*_DIR=\"*)
        d="${line#*=}"; d="${d%\"}"; d="${d#\"}"; d="${d/#\$HOME/$HOMEDIR}"
        mkdir -p "$d" || dbk_add_check "警告: 无法创建 $d"
        chown "$TARGET_USER:$GROUP" "$d" 2>/dev/null || true ;;
    esac
  done <<EOF
$BODY
EOF
  dbk_add_action "已建好六条重定向目标目录"
  return 0
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
judge
if [ "$DBK_MODE" = apply ]; then finish "家目录重定向已执行(--apply;复读判据)"; else finish "家目录重定向判据核对完成(--check 零写)"; fi
