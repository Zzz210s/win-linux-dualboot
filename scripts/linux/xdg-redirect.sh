#!/usr/bin/env bash
# L4:家目录重定向 —— 把"文档类"目录指到共享盘(/mnt/shared),对齐 Windows 侧已知文件夹重定向。
#
# 用法:xdg-redirect.sh [--user <name>] [--apply] [--template <path>] [--log <path>]
#                      [--skip-mount-check]
#   默认 dry-run:只打印将写入 ~/.config/user-dirs.dirs 的内容,不改动任何文件。
#   加 --apply 才真正改系统(需要 root):备份 ~/.config/user-dirs.dirs(user-dirs.dirs.dbk.bak)
#   -> 按模板写入六条 XDG_*_DIR -> 以该用户身份执行 xdg-user-dirs-update --force
#   -> 建好缺失的目标目录 -> 逐条回读并打印核对结果。
#   只重定向文档类目录(桌面/文档/下载/图片/视频/音乐);~/.config、~/.ssh、~/.gnupg 与代码仓库
#   一律留在本地 root —— NTFS 无 POSIX 权限语义(设计文档 3.6 / 3.16 / 4.5 / 5.3)。
# 日志追加到 /var/log/dbk/xdg-redirect.log(该目录不可写时只输出到终端)。
# 通常由 scripts/linux/mount-shared.sh --apply 在挂载成功后调用,也可单独运行。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SHARED_MNT=/mnt/shared
KEYS='XDG_DESKTOP_DIR XDG_DOWNLOAD_DIR XDG_DOCUMENTS_DIR XDG_PICTURES_DIR XDG_MUSIC_DIR XDG_VIDEOS_DIR'
TARGET_USER="${SUDO_USER:-${USER:-}}"
APPLY=0
SKIP_MOUNT_CHECK=0
XDG_TPL="${DBK_XDG_SNIPPET:-$ROOT/templates/user-dirs.dirs.snippet}"
LOG="${DBK_LOG:-/var/log/dbk/xdg-redirect.log}"

log() {
  local line dir
  line="$(date '+%Y-%m-%d %H:%M:%S%z') $*"
  printf '%s\n' "$line"
  dir="$(dirname "$LOG")"
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
  fi
}

die() { log "错误: $*"; exit 1; }

usage() { sed -n '2,14p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --template) XDG_TPL="${2:-}"; shift 2 ;;
    --template=*) XDG_TPL="${1#*=}"; shift ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --skip-mount-check) SKIP_MOUNT_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

[ -r "$XDG_TPL" ] || die "找不到 XDG 模板 $XDG_TPL(仓库内应为 templates/user-dirs.dirs.snippet)"
XDG_BODY="$(grep -E '^XDG_[A-Z]+_DIR=' "$XDG_TPL" || true)"
[ -n "$XDG_BODY" ] || die "模板 $XDG_TPL 里没有未注释的 XDG_*_DIR 行"

for k in $KEYS; do
  case "$XDG_BODY" in
    *"$k="*) ;;
    *) die "XDG 模板 $XDG_TPL 缺少 $k" ;;
  esac
done
n_shared="$(printf '%s\n' "$XDG_BODY" | grep -c "\"$SHARED_MNT/" || true)"
[ "$n_shared" -eq 6 ] || die "模板里指向 $SHARED_MNT 的条目应为 6 条,实际 $n_shared 条"
if printf '%s\n' "$XDG_BODY" | grep -qE '"(/home|~|\$HOME)/\.(config|ssh|gnupg)'; then
  die "模板把配置/凭据目录放到了共享盘:$XDG_TPL"
fi

log "=== dry-run:以下内容将写入 ~/.config/user-dirs.dirs ==="
printf '%s\n' "$XDG_BODY"
log "目标用户: $TARGET_USER;模板: $XDG_TPL"
log "将执行: 备份 ~/.config/user-dirs.dirs -> user-dirs.dirs.dbk.bak -> 写入上述六行"
log "         -> sudo -u $TARGET_USER xdg-user-dirs-update --force -> 建目录 -> 逐条回读核对"

if [ "$APPLY" -ne 1 ]; then
  log "dry-run 结束:未修改任何文件。确认无误后加 --apply 重跑。"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo $0 --user $TARGET_USER --apply"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  die "无法确定桌面用户,请用 --user <name> 指定(不要对 root 重定向家目录)"
fi
HOMEDIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$HOMEDIR" ] && [ -d "$HOMEDIR" ] || die "用户 $TARGET_USER 的家目录不存在或无法解析"
GROUP="$(id -gn "$TARGET_USER")"

if [ "$SKIP_MOUNT_CHECK" -ne 1 ]; then
  if ! findmnt -rn "$SHARED_MNT" >/dev/null 2>&1; then
    die "$SHARED_MNT 未挂载:先完成共享盘挂载(scripts/linux/mount-shared.sh --apply),否则重定向目标会落在本地 root 上"
  fi
  log "共享盘已挂载: $(findmnt -rn -o SOURCE,FSTYPE -T "$SHARED_MNT" | head -n 1)"
else
  log "警告: 已按 --skip-mount-check 跳过挂载校验"
fi

CONFIG_DIR="$HOMEDIR/.config"
UDIRS="$CONFIG_DIR/user-dirs.dirs"
mkdir -p "$CONFIG_DIR"
if [ -e "$UDIRS" ]; then
  cp -a "$UDIRS" "$UDIRS.dbk.bak"
  log "已备份 $UDIRS -> $UDIRS.dbk.bak"
else
  log "原文件不存在($UDIRS),无需备份"
fi
{
  printf '# 由 scripts/linux/xdg-redirect.sh 写入(模板: %s)\n' "$XDG_TPL"
  printf '%s\n' "$XDG_BODY"
} >"$UDIRS"
chown "$TARGET_USER:$GROUP" "$UDIRS"
log "已写入 $UDIRS"

run_as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$TARGET_USER" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$TARGET_USER" -- "$@"
  else
    su -s /bin/bash "$TARGET_USER" -c "$(printf '%q ' "$@")"
  fi
}

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  run_as_user xdg-user-dirs-update --force
  log "已执行(以 $TARGET_USER 身份): xdg-user-dirs-update --force"
else
  log "警告: 未安装 xdg-user-dirs,跳过该步(文件已写入;建议 sudo apt install -y xdg-user-dirs)"
fi

while IFS= read -r line; do
  case "$line" in
    XDG_*_DIR=\"*)
      dir_val="${line#*=}"
      dir_val="${dir_val%\"}"
      dir_val="${dir_val#\"}"
      dir_val="${dir_val/#\$HOME/$HOMEDIR}"
      mkdir -p "$dir_val"
      chown "$TARGET_USER:$GROUP" "$dir_val"
      log "已准备目录 $dir_val"
      ;;
  esac
done <<EOF
$XDG_BODY
EOF

log "=== 核对:回读 $UDIRS ==="
while IFS= read -r line; do log "$line"; done <"$UDIRS"
log "完成:文档类家目录已重定向到 $SHARED_MNT"
log "回退:cp -a $UDIRS.dbk.bak $UDIRS && sudo -u $TARGET_USER xdg-user-dirs-update --force(或删掉该文件后重跑)"
