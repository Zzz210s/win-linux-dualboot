#!/usr/bin/env bash
# L4:挂载共享数据盘(D:,ntfs3)与快照分区(/snapshots),并调用 xdg-redirect.sh 做家目录重定向。
#
# 用法:mount-shared.sh --uuid <SHARED_PART_UUID> [--apply] [--snapshot-uuid <UUID>]
#                      [--user <name>] [--template <path>] [--log <path>]
#   默认 dry-run:只打印将追加到 /etc/fstab 的两行,不改动系统。
#   加 --apply 才真正改系统(需要 root),顺序为:备份 fstab(.dbk.bak)-> mkdir -p /mnt/shared
#   -> 追加 fstab 行 -> systemctl daemon-reload -> mount -a -> 校验挂载 + 写测试(.dbk-write-test)
#   -> 调 xdg-redirect.sh --apply 完成文档类家目录重定向(家目录部分独立成脚本,可单独运行)。
# 日志追加到 /var/log/dbk/mount-shared.log(该目录不可写时只输出到终端)。
# 设计依据:设计文档 3.16 / 4.5 / 5.3(共享盘与四条前提)、第 7 节 L4 fstab 行。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FSTAB=/etc/fstab
FSTAB_BAK=/etc/fstab.dbk.bak
SHARED_MNT=/mnt/shared
SNAP_MNT=/snapshots
WRITE_TEST="$SHARED_MNT/.dbk-write-test"
NTFS_OPTS_DEFAULT='rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime'
SNAP_OPTS='defaults,nofail,noatime'
XDG_SCRIPT="$HERE/xdg-redirect.sh"

UUID=""
SNAPSHOT_UUID=""
APPLY=0
TARGET_USER="${SUDO_USER:-${USER:-}}"
FSTAB_TPL="${DBK_FSTAB_SNIPPET:-$ROOT/templates/fstab.snippet}"
LOG="${DBK_LOG:-/var/log/dbk/mount-shared.log}"

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

usage() { sed -n '2,11p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uuid) UUID="${2:-}"; shift 2 ;;
    --uuid=*) UUID="${1#*=}"; shift ;;
    --snapshot-uuid) SNAPSHOT_UUID="${2:-}"; shift 2 ;;
    --snapshot-uuid=*) SNAPSHOT_UUID="${1#*=}"; shift ;;
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --template) FSTAB_TPL="${2:-}"; shift 2 ;;
    --template=*) FSTAB_TPL="${1#*=}"; shift ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) if [ -z "$UUID" ]; then UUID="$1"; shift; else usage; die "未知参数: $1"; fi ;;
  esac
done

[ -n "$UUID" ] || { usage; die "缺少 --uuid <SHARED_PART_UUID>(用 blkid -s UUID -o value <设备> 获取)"; }
case "$UUID" in *[!0-9A-Fa-f-]*) die "--uuid 只允许十六进制与连字符: $UUID" ;; esac
[ "${#UUID}" -ge 8 ] || die "--uuid 长度异常: $UUID"
if [ -n "$SNAPSHOT_UUID" ]; then
  case "$SNAPSHOT_UUID" in *[!0-9A-Fa-f-]*) die "--snapshot-uuid 只允许十六进制与连字符: $SNAPSHOT_UUID" ;; esac
  [ "${#SNAPSHOT_UUID}" -ge 8 ] || die "--snapshot-uuid 长度异常: $SNAPSHOT_UUID"
fi

DEV=""
FSTYPE=""
if DEV="$(blkid -U "$UUID" 2>/dev/null)" && [ -n "$DEV" ]; then
  log "共享分区: UUID=$UUID -> $DEV"
  FSTYPE="$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)"
  [ "$FSTYPE" = "ntfs" ] || die "共享分区文件系统为 '$FSTYPE',应为 ntfs(设计文档 3.16:整块 D: 为 NTFS 共享盘)"
else
  [ "$APPLY" -eq 0 ] || die "blkid 找不到 UUID=$UUID 对应的分区(确认盘已接入、UUID 抄自 blkid)"
  log "警告: blkid 未能解析 UUID=$UUID(通常因为非 root 或分区尚未接入),dry-run 继续"
fi
if [ -n "$SNAPSHOT_UUID" ]; then
  if SNAP_DEV="$(blkid -U "$SNAPSHOT_UUID" 2>/dev/null)" && [ -n "$SNAP_DEV" ]; then
    log "快照分区: UUID=$SNAPSHOT_UUID -> $SNAP_DEV"
  else
    log "警告: blkid 未能解析快照分区 UUID=$SNAPSHOT_UUID(快照行仍会写入,带 nofail 不阻断启动)"
  fi
fi
MNTPT="$(findmnt -rn -S "UUID=$UUID" -o TARGET 2>/dev/null | head -n 1 || true)"
if [ -n "$MNTPT" ] && [ "$MNTPT" != "$SHARED_MNT" ]; then
  log "警告: 该分区当前挂载在 $MNTPT(与本脚本目标 $SHARED_MNT 不一致)"
fi

NTFS_OPTS="$NTFS_OPTS_DEFAULT"
if [ -r "$FSTAB_TPL" ]; then
  tpl_line="$(grep -F 'ntfs3' "$FSTAB_TPL" | grep -v '^[[:space:]]*#' | head -n 1 || true)"
  [ -n "$tpl_line" ] || die "模板 $FSTAB_TPL 里找不到未注释的 ntfs3 行"
  tpl_opts="$(printf '%s\n' "$tpl_line" | awk '{print $4}')"
  for need in windows_names uid= gid= umask= nofail; do
    case "$tpl_opts" in
      *"$need"*) ;;
      *) die "模板 $FSTAB_TPL 的 ntfs3 选项缺少 $need: $tpl_opts" ;;
    esac
  done
  NTFS_OPTS="$tpl_opts"
else
  log "警告: 未找到模板 $FSTAB_TPL,使用内置挂载选项: $NTFS_OPTS_DEFAULT"
fi

SHARED_LINE="UUID=$UUID  $SHARED_MNT  ntfs3  $NTFS_OPTS  0 0"
SNAP_LINE=""
if [ -n "$SNAPSHOT_UUID" ]; then
  SNAP_LINE="UUID=$SNAPSHOT_UUID  $SNAP_MNT  ext4  $SNAP_OPTS  0 2"
fi

if [ -n "$TARGET_USER" ] && id -u "$TARGET_USER" >/dev/null 2>&1; then
  uid="$(id -u "$TARGET_USER")"
  if [ "$uid" != "1000" ]; then
    log "警告: 用户 $TARGET_USER 的 uid=$uid,而挂载选项固定 uid=1000;共享盘属主会不一致"
  fi
else
  log "警告: 无法解析目标用户 '$TARGET_USER',按 uid/gid=1000 处理(可用 --user 指定)"
fi
if findmnt -rn "$SHARED_MNT" >/dev/null 2>&1; then
  log "共享盘当前可用空间: $(df -h --output=avail "$SHARED_MNT" | tail -n 1)"
fi

log "=== dry-run:以下动作不会被执行 ==="
log "将追加到 $FSTAB :"
printf '%s\n' "$SHARED_LINE"
if [ -n "$SNAP_LINE" ]; then printf '%s\n' "$SNAP_LINE"; fi
log "将备份 $FSTAB -> $FSTAB_BAK(若备份不存在)"
log "将执行: mkdir -p $SHARED_MNT -> systemctl daemon-reload -> mount -a -> 写测试 $WRITE_TEST"
log "随后调用: $XDG_SCRIPT --user $TARGET_USER --apply(dry-run 阶段只打印该命令)"

if [ "$APPLY" -ne 1 ]; then
  log "dry-run 结束:未修改任何文件。确认无误后加 --apply 重跑。"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo $0 --uuid $UUID --apply"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  die "无法确定桌面用户,请用 --user <name> 指定(不要对 root 重定向家目录)"
fi
getent passwd "$TARGET_USER" >/dev/null || die "用户 $TARGET_USER 不存在"

if [ ! -e "$FSTAB_BAK" ]; then
  cp -a "$FSTAB" "$FSTAB_BAK"
  log "已备份 $FSTAB -> $FSTAB_BAK"
else
  log "备份已存在,保留不覆盖: $FSTAB_BAK"
fi

existing="$(grep -F " $SHARED_MNT " "$FSTAB" | grep -v '^[[:space:]]*#' | head -n 1 || true)"
if [ "$existing" = "$SHARED_LINE" ]; then
  log "fstab 已含目标行,跳过写入"
elif [ -n "$existing" ]; then
  die "fstab 已含 $SHARED_MNT 的其他条目,请先手工处理: $existing"
else
  {
    printf '\n# L4 共享数据盘(D:)与快照分区,由 scripts/linux/mount-shared.sh 写入\n'
    printf '%s\n' "$SHARED_LINE"
    if [ -n "$SNAP_LINE" ]; then printf '%s\n' "$SNAP_LINE"; fi
  } >>"$FSTAB"
  log "已追加 fstab 行"
fi

mkdir -p "$SHARED_MNT"
if [ -n "$SNAPSHOT_UUID" ]; then mkdir -p "$SNAP_MNT"; fi
systemctl daemon-reload
mount -a
if ! findmnt -rn -S "UUID=$UUID" >/dev/null 2>&1; then
  die "分区未挂载,$SHARED_MNT 仍是本地目录;fstab 行已保留(nofail 不阻断启动),修正后重跑本脚本"
fi
if touch "$WRITE_TEST" 2>/dev/null; then
  rm -f "$WRITE_TEST"
  log "写测试通过: $WRITE_TEST 可创建并删除"
else
  die "写测试失败: $SHARED_MNT 不可写(核对 D: 未加密、Windows 已关 Fast Startup 与休眠)"
fi

if [ -x "$XDG_SCRIPT" ]; then
  log "调用 $XDG_SCRIPT --user $TARGET_USER --apply"
  "$XDG_SCRIPT" --user "$TARGET_USER" --apply --log "$(dirname "$LOG")/xdg-redirect.log"
else
  die "找不到可执行脚本 $XDG_SCRIPT;家目录重定向未执行,请手工运行它"
fi

log "完成:共享盘已挂载 + 写测试通过 + 家目录重定向已交由 $XDG_SCRIPT 处理"
log "回退:恢复 $FSTAB_BAK 后 mount -a;家目录回退见 $XDG_SCRIPT 的提示"
