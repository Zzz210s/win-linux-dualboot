#!/usr/bin/env bash
# L4:交换空间落地 —— swapfile 4GiB(不建 swap 分区、不做休眠)+ zram(约 8GiB)。
#
# 用法:bash scripts/linux/storage.sh [--apply] [--size 4G] [--swapfile /swapfile] [--log <path>]
#   默认 dry-run:只打印将执行的动作与判据,不改动系统。
#   --apply(需要 root)按序执行:fallocate -l <size> <file> -> chmod 600 -> mkswap -> swapon
#   -> 校验 /etc/fstab 的 swapfile 行,缺则先备份为 /etc/fstab.dbk.bak 再追加
#   -> 确保 systemd-zram-generator 已安装(缺则 apt-get install,DBK_SKIP_APT=1 跳过)-> 安装 templates/zram-generator.conf 到 /etc/systemd/zram-generator.conf(内容不同则先备份)
#   -> systemctl daemon-reload 并启动 systemd-zram-setup@zram0.service
#   -> 打印 swapon --show 与 zramctl 作为实测验证,并顺带报告 systemd-oomd(R6)。
# 重跑幂等:swapfile 已存在则跳过创建、已在交换列表则跳过 swapon;fstab/zram 配置只补不覆盖。
# 日志追加到 /var/log/dbk/storage.log(目录不可写时只输出到终端)。
# 退出码:0 = swapfile 与 zram 都验证通过;1 = 有项未通过(见日志里的 DBK-RESULT 行)。
# 回退:swapoff <swapfile> && rm -f <swapfile>;删掉 fstab 的 swapfile 行与 zram-generator.conf;
#      两者都不动分区表(决策 3.8 的可调整性)。
# 设计依据:决策 3.8(无 swap 分区)、设计 4.7 的 R6(OOM 与内存压力防护)。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
[ -r "$HERE/dbk-apt.sh" ] || { echo "错误: 缺少 $HERE/dbk-apt.sh" >&2; exit 1; }
LOG="${DBK_LOG:-/var/log/dbk/storage.log}"
source "$HERE/dbk-log.sh"
source "$HERE/dbk-apt.sh"

FSTAB="${DBK_FSTAB:-/etc/fstab}"
FSTAB_BAK="$FSTAB.dbk.bak"
SWAPFILE="${DBK_SWAPFILE:-/swapfile}"
SWAP_SIZE="${DBK_SWAP_SIZE:-4G}"
ZRAM_CONF="${DBK_ZRAM_CONF:-/etc/systemd/zram-generator.conf}"
ZRAM_TPL="${DBK_ZRAM_TPL:-$ROOT/templates/zram-generator.conf}"
ZRAM_PKG="${DBK_ZRAM_PKG:-systemd-zram-generator}"
SKIP_APT="${DBK_SKIP_APT:-0}"
APPLY=0
RC=0

usage() { sed -n '2,13p' "$0"; }

# 活动交换设备名列表(兼容不支持 --show=NAME 的旧 util-linux)
swap_names() {
  swapon --show=NAME --noheadings 2>/dev/null || swapon --show 2>/dev/null | awk 'NR>1{print $1}'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --size) need_val "$#" "--size" "<字节数,如 4G>"; SWAP_SIZE="$2"; shift 2 ;;
    --size=*) SWAP_SIZE="${1#*=}"; shift ;;
    --swapfile) need_val "$#" "--swapfile" "<绝对路径,如 /swapfile>"; SWAPFILE="$2"; shift 2 ;;
    --swapfile=*) SWAPFILE="${1#*=}"; shift ;;
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

case "$SWAPFILE" in /*) ;; *) die "--swapfile 需要绝对路径: $SWAPFILE" ;; esac
case "$SWAP_SIZE" in *[!0-9GgMmKk]*|"") die "--size 只允许数字与单位 G/M/K: $SWAP_SIZE" ;; esac
case "$SKIP_APT" in 1|0) ;; *) die "DBK_SKIP_APT 只接受 0/1: $SKIP_APT" ;; esac
[ -r "$ZRAM_TPL" ] || die "缺少 zram 模板 $ZRAM_TPL"
for key in 'zram-size' 'compression-algorithm' 'swap-priority'; do
  grep -qE "^[[:space:]]*$key[[:space:]]*=" "$ZRAM_TPL" || die "模板 $ZRAM_TPL 缺少 $key(决策 3.8)"
done
grep -qF 'min(ram / 2, 8192)' "$ZRAM_TPL" || log "警告: 模板 zram-size 不是 min(ram / 2, 8192),按模板原样安装"

log "=== 交换空间计划(决策 3.8:不做休眠、不建 swap 分区)==="
log "1) $SWAPFILE($SWAP_SIZE):fallocate -l -> chmod 600 -> mkswap -> swapon"
log "2) $FSTAB:缺 swapfile 行时先备份为 $FSTAB_BAK 再追加 '$SWAPFILE none swap sw,nofail 0 0'"
log "3) 确保 $ZRAM_PKG 已安装(缺则 apt-get install -y;DBK_SKIP_APT=1 跳过),再安装 $ZRAM_TPL -> $ZRAM_CONF(内容不同时先备份为 $ZRAM_CONF.dbk.bak)"
log "4) systemctl daemon-reload && systemctl start systemd-zram-setup@zram0.service(zram 约 8GiB)"
log "5) 验证:swapon --show 列出 $SWAPFILE、zramctl 列出 zram0;并报告 systemd-oomd 状态"
log "6) 回退:swapoff $SWAPFILE && rm -f $SWAPFILE;删该 fstab 行与 $ZRAM_CONF(都不动分区表)"

if [ "$APPLY" -ne 1 ]; then
  log "dry-run 结束:未修改任何文件。确认无误后加 --apply 重跑:sudo bash scripts/linux/storage.sh --apply"
  exit 0
fi
[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:sudo bash $0 --apply"

# 0) zram 依赖包:zram 单元由该包提供;缺包则 systemd-zram-setup@zram0.service 起不来(R6 半项失效)
#    先查后装(重跑不重复下载);DBK_SKIP_APT=1 时只跳过安装,便于无 apt 环境做静态校验
pkg_st=0; apt_ensure "$ZRAM_PKG" "sudo apt install -y $ZRAM_PKG" || pkg_st=$?
if [ "$pkg_st" -eq 1 ]; then RC=1; fi
if [ "$pkg_st" -eq 9 ]; then log "DBK_SKIP_APT=1:未安装 $ZRAM_PKG,按静态校验继续(下面 zram 判据会因缺包记 fail)"; fi

# 1) swapfile:不存在则创建;存在则跳过创建(重跑幂等),未启用时补 swapon
if [ ! -e "$SWAPFILE" ]; then
  if fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
    log "已创建 $SWAPFILE($SWAP_SIZE)"
    chmod 600 "$SWAPFILE" || log "警告: chmod 600 $SWAPFILE 失败"
    out="$(mkswap "$SWAPFILE" 2>&1)"; st=$?
    if [ "$st" -eq 0 ]; then
      log "mkswap: $(printf '%s' "$out" | tail -n 1)"
    else
      log "错误: mkswap $SWAPFILE 失败: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; RC=1
    fi
  else
    log "错误: fallocate -l $SWAP_SIZE $SWAPFILE 失败(root 分区空间不足?决策 3.6 给 root 100GiB)"; RC=1
  fi
else
  log "$SWAPFILE 已存在,跳过创建(fallocate 不覆盖已有文件)"
  chmod 600 "$SWAPFILE" 2>/dev/null || log "警告: chmod 600 $SWAPFILE 失败"
fi
if [ -e "$SWAPFILE" ]; then
  if swap_names | grep -qxF "$SWAPFILE"; then
    log "$SWAPFILE 已是活动交换空间(重跑跳过 swapon)"
  elif swapon "$SWAPFILE" 2>/dev/null; then
    log "已启用 $SWAPFILE"
  else
    log "错误: swapon $SWAPFILE 失败(mkswap 未成功或内核拒绝该文件)"; RC=1
  fi
fi

# 2) fstab:已有该路径的条目则跳过;否则备份后追加(备份只在不存在时创建)
SWAP_LINE="$SWAPFILE  none  swap  sw,nofail  0 0"
# 按首个字段精确匹配(不用 grep -F:否则 /swapfile2、/swapfile.bak 会被误判为已有条目而静默不落盘)
cur="$(awk -v p="$SWAPFILE" '!/^[[:space:]]*#/ && $1==p' "$FSTAB" 2>/dev/null || true)"
if [ -n "$cur" ]; then
  log "fstab 已有 $SWAPFILE 条目,跳过写入: $(printf '%s' "$cur" | head -n 1)"
  case "$cur" in *swap*) ;; *) log "警告: 该条目未见 swap 关键字,请手工核对 $FSTAB" ;; esac
  case "$cur" in *nofail*) ;; *) log "警告: 该条目缺 nofail(设计第 8 节 F 组判据:非 root 条目均带 nofail),请手工核对 $FSTAB" ;; esac
else
  if [ ! -e "$FSTAB_BAK" ]; then
    cp -a "$FSTAB" "$FSTAB_BAK" && log "已备份 $FSTAB -> $FSTAB_BAK(重跑不覆盖首次备份)" || { log "错误: 备份 $FSTAB 失败"; RC=1; }
  else
    log "备份已存在,保留不覆盖: $FSTAB_BAK"
  fi
  if printf '\n# L4 交换空间(决策 3.8):zram + swapfile,不做休眠\n%s\n' "$SWAP_LINE" >>"$FSTAB"; then
    log "已追加 fstab 行: $SWAP_LINE"
  else
    log "错误: 写入 $FSTAB 失败"; RC=1
  fi
fi

# 3) zram 配置:与模板一致则跳过;有差异先备份再覆盖
if [ -f "$ZRAM_CONF" ] && cmp -s "$ZRAM_TPL" "$ZRAM_CONF"; then
  log "$ZRAM_CONF 已是模板内容,跳过"
else
  if [ -f "$ZRAM_CONF" ] && [ ! -e "$ZRAM_CONF.dbk.bak" ]; then
    cp -a "$ZRAM_CONF" "$ZRAM_CONF.dbk.bak" && log "已备份 $ZRAM_CONF -> $ZRAM_CONF.dbk.bak"
  fi
  mkdir -p "$(dirname "$ZRAM_CONF")" 2>/dev/null
  if cp -a "$ZRAM_TPL" "$ZRAM_CONF"; then
    log "已安装 $ZRAM_TPL -> $ZRAM_CONF"
  else
    log "错误: 写入 $ZRAM_CONF 失败"; RC=1
  fi
fi

# 4) 让 systemd 接手:重载单元并启动 zram 设备
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || { log "警告: systemctl daemon-reload 失败"; RC=1; }
  if systemctl start systemd-zram-setup@zram0.service 2>/dev/null; then
    log "已启动 systemd-zram-setup@zram0.service"
  else
    log "错误: 启动 systemd-zram-setup@zram0.service 失败(确认已装 systemd-zram-generator 包)"; RC=1
  fi
else
  log "警告: 无 systemctl(非 systemd 环境),跳过 zram 启动"; RC=1
fi

# 5) 验证:以实测输出为准
log "=== 验证(实测输出)==="
if command -v swapon >/dev/null 2>&1; then
  log "swapon --show:
$(swapon --show 2>&1 | sed 's/^/  /')"
  if swap_names | grep -qxF "$SWAPFILE"; then
    log "DBK-RESULT ok swapfile $SWAPFILE 处于活动状态"
  else
    log "DBK-RESULT fail swapfile $SWAPFILE 不在 swapon --show 列表里"; RC=1
  fi
else
  log "DBK-RESULT fail swapfile 无 swapon 命令,无法验证"; RC=1
fi
if command -v zramctl >/dev/null 2>&1; then
  zr_out="$(zramctl 2>&1)"; st=$?
  log "zramctl:
$(printf '%s\n' "$zr_out" | sed 's/^/  /')"
  if [ "$st" -eq 0 ] && printf '%s\n' "$zr_out" | grep -q '^zram0'; then
    log "DBK-RESULT ok zram0 已建立(swap-priority=100,优先于 swapfile)"
  else
    log "DBK-RESULT fail zramctl 未列出 zram0(硬前置: 必须先执行 sudo apt install -y $ZRAM_PKG 再重跑本脚本)"; RC=1
  fi
else
  log "DBK-RESULT fail zram 无 zramctl 命令,无法验证(可看 /dev/zram0 与 lsblk)"; RC=1
fi
if command -v systemctl >/dev/null 2>&1; then
  log "systemd-oomd(R6): is-enabled=$(systemctl is-enabled systemd-oomd 2>&1 || true) is-active=$(systemctl is-active systemd-oomd 2>&1 || true)"
fi

if [ "$RC" -eq 0 ]; then
  log "完成:swapfile 与 zram 均验证通过"
else
  log "结束:有未通过项,见上面的 DBK-RESULT 行;修好后可重跑本脚本(幂等)"
fi
exit "$RC"
