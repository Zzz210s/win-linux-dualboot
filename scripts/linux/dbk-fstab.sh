#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:fstab 结构判据与 NTFS 脏卷探测——mount-shared.sh 的**只读判定层**(从该脚本拆出;判定口径不变)。
# 调用约定:调用方先 source 本库(mount-shared.sh 在 source dbk-cli.sh 之后 source 它),然后:
#   fstab_lines <fstab> <挂载点>                     打印该挂载点的非注释行(可多行;读不到 → 无输出,返回 0)
#   fstab_match <fstab行> <挂载点> <UUID> <必含选项…> 0 = UUID/挂载点/ntfs3/必含选项都成立(选项顺序无关)/ 1 = 不成立;
#     必含选项按「逗号边界前缀」比对(如 uid= 命中 uid=1000),由调用方逐项传入。
#   fstab_want <模板> <挂载点> <UUID> <默认选项>     打印应写入的 fstab 行;模板无 ntfs3 行 / 选项不全 / UUID 为空 → 返回 1
#   mnt_target <挂载点>                             打印挂载点当前 TARGET(未挂载或取不到 → 空)
#   mnt_src <挂载点>                                打印 "SOURCE FSTYPE OPTIONS"(取不到 → 空)
#   ntfs_probe <设备>                               零依赖脏卷探测:0 = 卷干净(不带 force 的 rw 临时挂载成功,已立刻卸载且删点)
#     / 1 = 输出含 dirty(脏卷,调用方记需人工、提示回 Windows 跑 chkdsk)/ 2 = 其它失败 / 3 = 权限不足(需 root 才能探测)
# 只读:除 ntfs_probe 的临时挂载(成功即卸载)外不写任何东西;探测失败一律给非 0,绝不 fail-open 成「卷干净」。
# 本文件只定义函数:不设置 shell 选项、不执行动作。**末尾不加任何条件语句**(被 source 时返回非 0 会让带 set -e 的调用方静默退 1)。
# Environment: 无(命令一律走 PATH,如 findmnt / mount / umount / mktemp,便于夹具注入假件)。
# 夹具级验证,真机未跑。

# 目标挂载点的当前 fstab 条目(只读,只挑非注释行)。
fstab_lines() { awk -v m="${2:-}" '!/^[[:space:]]*#/ && $2==m' "${1:-}" 2>/dev/null || true; }

# fstab 行结构判据:UUID + 挂载点 + fstype 相等,且选项里含调用方给的必含集合(顺序无关,不看整行字符串)。
fstab_match() {
  local line="${1:-}" mnt="${2:-}" uuid="${3:-}" f1 f2 f3 opts need
  shift 3
  read -r f1 f2 f3 opts _ <<<"$line"
  [ "$f1" = "UUID=$uuid" ] && [ "$f2" = "$mnt" ] && [ "$f3" = ntfs3 ] || return 1
  for need in "$@"; do
    case ",$opts," in *",$need"*) ;; *) return 1 ;; esac
  done
  return 0
}

# 应写入的目标 fstab 行:模板里取第一条非注释 ntfs3 行,校验必含选项;没有模板就用默认选项。
fstab_want() {
  local tpl="${1:-}" mnt="${2:-}" uuid="${3:-}" opts="${4:-}" line topts need
  if [ -r "$tpl" ]; then
    line="$(grep -F ntfs3 "$tpl" | grep -v '^[[:space:]]*#' | head -n 1 || true)"
    [ -n "$line" ] || return 1
    topts="$(printf '%s\n' "$line" | awk '{print $4}')"
    for need in windows_names uid= gid= umask= nofail; do
      case "$topts" in *"$need"*) ;; *) return 1 ;; esac
    done
    opts="$topts"
  fi
  [ -n "$uuid" ] || return 1
  printf 'UUID=%s  %s  ntfs3  %s  0 0' "$uuid" "$mnt" "$opts"
}

mnt_target() { findmnt -rn -o TARGET "${1:-}" 2>/dev/null | head -n 1 || true; }
mnt_src() { findmnt -rn -o SOURCE,FSTYPE,OPTIONS -T "${1:-}" 2>/dev/null | head -n 1 || true; }

# NTFS 脏卷探测(零依赖):不带 force 的 rw 挂载成功 = 干净(立刻卸载);失败且输出含 dirty = 脏卷;其余 = 判不了。
ntfs_probe() {
  local dev="${1:-}" tm out
  tm="$(mktemp -d)" || return 2
  if out="$(mount -t ntfs3 -o rw "$dev" "$tm" 2>&1)"; then
    if ! umount "$tm" 2>/dev/null; then
      if command -v dbk_add_check >/dev/null 2>&1; then
        dbk_add_check "警告: 探测用的临时挂载点 $tm 未能卸载(探测结论仍为卷干净),重启前请人工 umount 后复核"
      fi
    fi
    rmdir "$tm" 2>/dev/null || true
    return 0
  fi
  rmdir "$tm" 2>/dev/null || true
  case "$out" in *[Dd][Ii][Rr][Tt][Yy]*) return 1 ;; esac
  case "$out" in *"permission denied"*|*"must be superuser"*|*"only root"*|*"Operation not permitted"*) return 3 ;; esac
  return 2
}
