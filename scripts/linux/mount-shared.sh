#!/usr/bin/env bash
# 对应卡:05-1
# 破坏性:1
# L4 卡 05-1:把共享数据盘(D: 整块 NTFS)以 ntfs3 挂到 /mnt/shared,挂载成功后调用 xdg-redirect.sh 做家目录重定向。
# 判据(--check,零写):① blkid 能解析 UUID 且文件系统是 ntfs;② /etc/fstab 有 /mnt/shared 的目标 ntfs3 行;
#   ③ 该分区当前挂在 /mnt/shared 且挂载选项含 rw。只读判定**不做写测试**(写测试是写动作,只在 --apply 成功路径做)。
# --apply(需要 root,且必须 --yes):备份 fstab(.dbk.bak,仅首次)-> 补写缺失行 -> 建挂载点 -> daemon-reload
#   -> mount -a -> 写测试(.dbk-write-test)-> bash xdg-redirect.sh --apply --yes -> 复读判据。幂等:重跑只补缺失。
# 注:快照分区与 btrfs 快照体系已作废(设计 02 第 8 节),本脚本只挂共享盘。
# 设计依据:设计 3.16 / 4.5 / 5.3(共享盘与四条前提)、02 设计 5 节(D: ≈635GiB NTFS)。夹具级验证,真机未跑。
# 用法:mount-shared.sh [--uuid <SHARED_UUID>(或 DBK_SHARED_UUID)] [--user <name>] [--template <fstab 片段>]
#   [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"

FSTAB="${DBK_FSTAB:-/etc/fstab}"; FSTAB_BAK="$FSTAB.dbk.bak"
SHARED_MNT="${DBK_SHARED_MNT:-/mnt/shared}"; WRITE_TEST="$SHARED_MNT/.dbk-write-test"
NTFS_OPTS_DEFAULT='rw,uid=1000,gid=1000,umask=022,windows_names,nofail,noatime'
XDG_SCRIPT="$HERE/xdg-redirect.sh"
UUID="${DBK_SHARED_UUID:-}"; TARGET_USER="${SUDO_USER:-${USER:-}}"
FSTAB_TPL="${DBK_FSTAB_SNIPPET:-$ROOT/templates/fstab.snippet}"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uuid) dbk_cli_val "--uuid" "${2:-}"; UUID="$2"; shift 2 ;;
    --uuid=*) UUID="${1#*=}"; shift ;;
    --user) dbk_cli_val "--user" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --template) dbk_cli_val "--template" "${2:-}"; FSTAB_TPL="$2"; shift 2 ;;
    --template=*) FSTAB_TPL="${1#*=}"; shift ;;
    --dry-run) shift ;;
    --*) ARGS+=("$1"); shift ;;
    -*) ARGS+=("$1"); shift ;;
    *) if [ -z "$UUID" ]; then UUID="$1"; shift; else ARGS+=("$1"); shift; fi ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "mount-shared"
dbk_enable_errtrap

fstab_cur() { awk -v m="$SHARED_MNT" '!/^[[:space:]]*#/ && $2==m' "$FSTAB" 2>/dev/null || true; }
mnt_target() { findmnt -rn -o TARGET "$SHARED_MNT" 2>/dev/null | head -n 1 || true; }
mnt_src() { findmnt -rn -o SOURCE,FSTYPE,OPTIONS -T "$SHARED_MNT" 2>/dev/null | head -n 1 || true; }

resolve_dev() {   # 只读:UUID -> 设备与文件系统类型
  DEV=""; FSTYPE=""
  [ -n "$UUID" ] || return 0
  if DEV="$(blkid -U "$UUID" 2>/dev/null)" && [ -n "$DEV" ]; then
    FSTYPE="$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)"
  else DEV=""; fi
  return 0
}

want_line() {     # 打印目标 fstab 行;模板不合格或没有 UUID 时返回非零
  local opts="$NTFS_OPTS_DEFAULT" line topts need
  if [ -r "$FSTAB_TPL" ]; then
    line="$(grep -F ntfs3 "$FSTAB_TPL" | grep -v '^[[:space:]]*#' | head -n 1 || true)"
    [ -n "$line" ] || return 1
    topts="$(printf '%s\n' "$line" | awk '{print $4}')"
    for need in windows_names uid= gid= umask= nofail; do
      case "$topts" in *"$need"*) ;; *) return 1 ;; esac
    done
    opts="$topts"
  fi
  [ -n "$UUID" ] || return 1
  printf 'UUID=%s  %s  ntfs3  %s  0 0' "$UUID" "$SHARED_MNT" "$opts"
}

ISSUES=(); MANUAL=(); EXTRA_MANUAL=()   # EXTRA_MANUAL:--apply 路径产生的"需人工"项(judge 会重置 MANUAL,不清空它)

judge() {         # 只读判定:判据 -> checks/ISSUES/MANUAL
  ISSUES=(); MANUAL=()
  want="$(want_line || true)"
  if [ -z "$want" ]; then
    if [ -z "$UUID" ]; then MANUAL+=("未给 --uuid(或 DBK_SHARED_UUID),无法核对 fstab 行的 UUID 字段")
    else ISSUES+=("模板 ${FSTAB_TPL} 的 ntfs3 行缺失或选项不全(windows_names/uid=/gid=/umask=/nofail)"); fi
  else
    resolve_dev
    if [ -z "$DEV" ]; then
      MANUAL+=("blkid 解析不到 UUID=$UUID 对应的分区(非 root 或盘未接入),文件系统类型无法核对")
    elif [ "$FSTYPE" != ntfs ]; then
      ISSUES+=("共享分区 $DEV 的文件系统为 '$FSTYPE',应为 ntfs(整块 D: 为 NTFS 共享盘)")
    else
      dbk_add_check "共享分区可解析:$DEV($FSTYPE)"
    fi
    cur="$(fstab_cur)"
    if [ "$cur" = "$want" ]; then dbk_add_check "fstab 已含 $SHARED_MNT 的目标行"
    elif [ -n "$cur" ]; then ISSUES+=("fstab 已有 $SHARED_MNT 的其他条目,需人工处理: $cur")
    else ISSUES+=("fstab 缺少 $SHARED_MNT 的 ntfs3 行(--apply 会补上)"); fi
  fi
  if [ "$(mnt_target)" = "$SHARED_MNT" ]; then
    src="$(mnt_src)"
    dbk_add_check "$SHARED_MNT 已挂载: $src"
    case "$src" in *"rw"*) dbk_add_check "挂载选项含 rw(可写)" ;; *) ISSUES+=("$SHARED_MNT 挂载选项不含 rw(当前只读)") ;; esac
  else
    ISSUES+=("$SHARED_MNT 未挂载(或挂的是本机目录,不是共享分区)")
  fi
  if [ -n "$TARGET_USER" ] && id -u "$TARGET_USER" >/dev/null 2>&1; then
    if [ "$(id -u "$TARGET_USER")" != 1000 ]; then
      MANUAL+=("用户 $TARGET_USER 的 uid≠1000,而挂载选项固定 uid=1000:共享盘属主会与预期不一致")
    fi
  elif [ -n "$TARGET_USER" ]; then
    MANUAL+=("无法解析目标用户 '$TARGET_USER'(桌面用户名需人工确认)")
  fi
  return 0
}

finish() {        # 判据 -> 退出码:有失败项 FAIL;否则有判不了的 需人工;否则 PASS
  local msg="${1:-}" m
  if [ "${#EXTRA_MANUAL[@]}" -gt 0 ]; then MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"}); fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks。修好后重跑本脚本(或加 --apply --yes 自动补行挂载)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:共享盘已挂在 $SHARED_MNT,fstab 行与判据一致"
}

apply_run() {     # 唯一的写路径(库层已保证 --apply 必带 --yes)
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --uuid <UUID> --apply --yes"; }
  case "$UUID" in ""|*[!0-9A-Fa-f-]*) dbk_usage; dbk_note "用法错误: --apply 需要合法 --uuid(十六进制与连字符): '$UUID'"; exit "$DBK_USAGE" ;; esac
  [ "${#UUID}" -ge 8 ] || { dbk_usage; dbk_note "用法错误: --uuid 长度异常: $UUID"; exit "$DBK_USAGE"; }
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    dbk_usage; dbk_note "用法错误: 无法确定桌面用户,请用 --user <name> 指定(不要对 root 重定向家目录)"; exit "$DBK_USAGE"
  fi
  resolve_dev
  [ -n "$DEV" ] || { dbk_add_check "blkid 找不到 UUID=$UUID 对应的分区"; dbk_exit FAIL "blkid 找不到 UUID=$UUID:确认盘已接入,UUID 抄自 blkid -s UUID -o value <设备>"; }
  [ "$FSTYPE" = ntfs ] || { dbk_add_check "共享分区 $DEV 不是 ntfs(实为 '$FSTYPE')"; dbk_exit FAIL "共享分区 $DEV 文件系统为 '$FSTYPE',应为 ntfs;停手,不要挂载非 D: 分区"; }
  want="$(want_line || true)"
  if [ -z "$want" ]; then dbk_add_check "模板 ${FSTAB_TPL} 的 ntfs3 行缺失或选项不全"; dbk_exit FAIL "模板校验失败(--template 指定的片段不合格),没有可写入的 fstab 行"; fi
  cur="$(fstab_cur)"
  if [ "$cur" = "$want" ]; then dbk_add_action "fstab 已含目标行,跳过写入"
  elif [ -n "$cur" ]; then dbk_add_check "fstab 已有 $SHARED_MNT 的其他条目: $cur"; dbk_exit FAIL "fstab 已有 $SHARED_MNT 的其他条目(见 checks):手工处理后重跑,本脚本不覆盖既有条目"
  else
    if [ ! -e "$FSTAB_BAK" ]; then cp -a "$FSTAB" "$FSTAB_BAK"; dbk_add_action "备份 $FSTAB -> $FSTAB_BAK(仅首次,重跑不覆盖)"; fi
    printf '\n# L4 共享数据盘(D:),由 scripts/linux/mount-shared.sh 写入\n%s\n' "$want" >>"$FSTAB"
    dbk_add_action "追加 fstab 行: $want"; dbk_mark_changed
  fi
  mkdir -p "$SHARED_MNT" || dbk_add_check "警告: 无法创建挂载点 $SHARED_MNT"
  if [ "$(mnt_target)" != "$SHARED_MNT" ]; then
    systemctl daemon-reload || dbk_add_check "警告: systemctl daemon-reload 失败"
    mount -a || dbk_obs "警告: mount -a 返回非零(带 nofail 的条目失败不致命),继续做挂载校验"
  fi
  resolve_dev
  if [ "$(findmnt -rn -o SOURCE -T "$SHARED_MNT" 2>/dev/null | head -n 1 || true)" != "$DEV" ]; then
    dbk_add_check "分区未挂载到 $SHARED_MNT(fstab 行已写入,带 nofail)"
    dbk_exit FAIL "分区未挂载到 $SHARED_MNT:fstab 行已保留(带 nofail,不阻断启动),修正后重跑本脚本;回退见文档回滚节"
  fi
  dbk_add_action "已挂载 $DEV -> $SHARED_MNT"; dbk_mark_changed
  if touch "$WRITE_TEST" 2>/dev/null && rm -f "$WRITE_TEST"; then
    dbk_add_action "写测试通过:$WRITE_TEST 可创建并删除"
  else
    dbk_add_check "写测试失败:$SHARED_MNT 不可写"
    dbk_exit FAIL "写测试失败:$SHARED_MNT 不可写(核对 D: 未加密、Windows 已关 Fast Startup 与休眠)"
  fi
  if [ -f "$XDG_SCRIPT" ]; then
    dbk_add_action "调用 bash $XDG_SCRIPT --user $TARGET_USER --apply --yes"
    if ! bash "$XDG_SCRIPT" --user "$TARGET_USER" --apply --yes; then
      dbk_add_check "xdg-redirect.sh 失败(家目录重定向未完成)"
      dbk_exit FAIL "家目录重定向失败(共享盘已挂载、写测试已通过);修好后单独重跑 xdg-redirect.sh"
    fi
  else
    EXTRA_MANUAL+=("找不到 $XDG_SCRIPT,家目录重定向未执行(共享盘已就绪)")
  fi
  return 0
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
judge
if [ "$DBK_MODE" = apply ]; then finish "共享盘落地已执行(--apply;复读判据)"; else finish "共享盘判据核对完成(--check 零写)"; fi
