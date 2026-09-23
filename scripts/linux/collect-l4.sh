#!/usr/bin/env bash
# 对应卡:05-12
# 用途:落 L4 产物(Kubuntu / apt 语义;设计依据:docs/design/04-kubuntu-variant-design.md 第 8 节验收调整与
#   第 7 节 R1-R9)。
#   --apply 写 <out-dir>/04-first-boot.md 与 <out-dir>/04-robustness.md;--check(缺省)只打印将落盘的节,零写。
#   04-first-boot.md 记:主机/内核/**发行版版本**、会话类型、**显卡驱动来源与版本**、**snap 四条判据**、
#   共享盘写测试、**timedatectl**、**蓝牙结论**、**待升级包数**、挂载与内存压力摘要。
#   04-robustness.md 记 R1-R9 逐项一行(措施 / 现状 / 证据命令与输出摘要 / 回滚点):
#   R1 变更前备份 baseline、R2 包级回退(rollback-pkg.sh)、R3 旧内核保留、R4 救援 U 盘、R5 journald 持久化、
#   R6 OOM/zram、R7 SSH 通道、R8 保守更新(只安全更新、不自动重启)、R9 SMART。取不到的写「未取到(原因)」,不编造。
# 用法: collect-l4.sh [--check|--apply] [--out-dir <目录>] [--json] [--log <路径>] [--step NN-K]
# 判据与纪律:产物落 baseline/(不入库,仅 baseline/README.md 例外;多设备用 baseline/<设备别名>/);
#   --apply 先写 <文件>.new 再 mv 原子替换;共享盘写测试只在 --apply 执行(--check 必须零写,连共享盘上的
#   临时文件也不碰)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。本卡无破坏性动作(不声明「# 破坏性:1」,不需 --yes)。
# 注入(真机不需要设置):DBK_OUT_DIR / DBK_SHARED_MNT / DBK_BOOT_DIR / DBK_SWAPFILE / DBK_JOURNAL_DIR /
#   DBK_OS_RELEASE / DBK_APT_GET / DBK_SNAP_PIN_FILE / DBK_MOZ_SOURCES。
# 待核实(以官方文档为准):apt-get -s dist-upgrade 的 Inst 行、timedatectl 输出字段、bluetoothctl list 的输出、
#   systemd 单元名(systemd-oomd / sshd / smartd / unattended-upgrades)均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
OUTDIR="${DBK_OUT_DIR:-$ROOT/baseline}"; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) dbk_cli_val "--out-dir" "${2:-}"; OUTDIR="$2"; shift 2 ;;
    --out-dir=*) OUTDIR="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "collect-l4"
SHARED="${DBK_SHARED_MNT:-/mnt/shared}"; BOOT_DIR="${DBK_BOOT_DIR:-/boot}"
SWAPFILE="${DBK_SWAPFILE:-/swapfile}"; JRNL="${DBK_JOURNAL_DIR:-/var/log/journal}"
OS_RELEASE="${DBK_OS_RELEASE:-/etc/os-release}"; AG_STR="${DBK_APT_GET:-apt-get}"
PIN_FILE="${DBK_SNAP_PIN_FILE:-/etc/apt/preferences.d/no-snap}"
MOZ_SOURCES="${DBK_MOZ_SOURCES:-/etc/apt/sources.list.d/mozilla.list}"
WT="未取到(原因:--check 零写,不碰共享盘;--apply 时才做写测试)"
AG=(); read -r -a AG <<<"$AG_STR"

have() { command -v "${1:-}" >/dev/null 2>&1; }
cap() { "$@" 2>&1 || true; }
capn() { local n="${1:-1}"; shift; { cap "$@" || true; } | head -n "$n" | tr '\n' ' ' | cut -c1-200 || true; }
one() { if have "${1:-}"; then capn 1 "$@"; else printf '未取到(未安装 %s)' "${1:-}"; fi; }
ev() {   # <命令…>:证据 = 命令行 + 输出摘要(不吞 stderr)
  local out
  if ! have "${1:-}"; then printf '%s -> 未取到(未安装 %s)' "$*" "${1:-}"; return 0; fi
  out="$( { "$@" 2>&1 || true; } | tr '\n' ' ' | cut -c1-200 || true)"
  printf '%s -> %s' "$*" "${out:-（无输出）}"
}
evs() {   # <shell 片段>:同上,但用于管道/重定向类证据
  local out
  out="$( { bash -c "$1" 2>&1 || true; } | tr '\n' ' ' | cut -c1-200 || true)"
  out="${out:-（无输出）}"
  case "$out" in *"command not found"*) out="未取到(原因: $out)" ;; esac
  printf '%s -> %s' "$1" "$out"
}
tcv() { printf '%s' "${1:-}" | sed 's/|/\\|/g'; }
etc() { evs "$1" | sed 's/|/\\|/g'; }
ecc() { ev "$@" | sed 's/|/\\|/g'; }
osv() { grep -m1 -E "^$1=" "$OS_RELEASE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }
session_line() {
  case "${XDG_SESSION_TYPE:-}" in
    wayland) printf 'XDG_SESSION_TYPE=wayland(符合要求)' ;;
    "") printf 'XDG_SESSION_TYPE=未取到(需人工:不在图形会话里?)' ;;
    *) printf 'XDG_SESSION_TYPE=%s(不符合要求,应为 wayland)' "$XDG_SESSION_TYPE" ;;
  esac
}
upgradable() { have "${AG[0]}" && { "${AG[@]}" -s dist-upgrade 2>&1 || true; } | grep -cE '^Inst[[:space:]]' || true; }

first_boot_body() {
  local ver pretty up
  ver="$(osv VERSION_ID)"; pretty="$(osv PRETTY_NAME)"; up="$(upgradable)"
  cat <<EOF
# baseline/04-first-boot.md (L4 产物;卡 05-12,设计 04 第 8 节)

## 主机 / 内核 / 发行版 / 时间
host=$(capn 1 hostname)
kernel=$(capn 1 uname -r)
distro=${pretty:-未取到}(VERSION_ID=${ver:-未取到})
cmdline=$(capn 1 cat /proc/cmdline)
date=$(date '+%Y-%m-%d %H:%M:%S%z')

## 会话类型(XDG_SESSION_TYPE)
$(session_line)
loginctl=$(one loginctl list-sessions)

## 显卡驱动来源与版本
$(evs "dpkg-query -W -f='\${Package} \${Version}\n' 'nvidia-driver-*'")
$(ev ubuntu-drivers devices)
$(ev modinfo -F signer nvidia)
$(ev nvidia-smi)
$(evs "lsmod | grep -E '^(nvidia|nouveau)'")

## snap 四条判据(S1/S2/S3/S4;设计 04 第 3 节)
$(evs "snap list")
$(evs "dpkg -l snapd")
$(evs "apt-cache policy snapd")
$(evs "apt-get install -s firefox | grep -c snapd")
pin=$(evs "cat $PIN_FILE")
mozilla=$(evs "cat $MOZ_SOURCES")

## 共享盘写测试
$WT

## 时间同步(timedatectl)
$(ev timedatectl)

## 蓝牙结论
$(evs "systemctl is-active bluetooth")
$(evs "bluetoothctl list")
结论=配对与密钥同步属人工步骤(卡 05-5);本行只记现状,不判通过。

## 待升级包数(apt-get -s dist-upgrade 的 Inst 行)
待升级包数=${up:-0}

## 挂载与内存压力(zram / swap / oomd)
$(evs "zramctl; swapon --show; systemctl is-enabled systemd-oomd")
$(ev findmnt "$SHARED")
$(ev findmnt "$SWAPFILE")
$(evs "grep -n nofail /etc/fstab")
EOF
}

robustness_body() {
  local jd zr sw oomd sshd smart tm pol kern up ver
  ver="$(osv VERSION_ID)"; up="$(upgradable)"
  if [ -d "$JRNL" ]; then jd="存在"; else jd="不存在"; fi
  if have zramctl; then zr="行数=$(cap zramctl | grep -c . || true)"; else zr="未取到(未安装 zramctl)"; fi
  if have swapon; then sw="行数=$(cap swapon --show | grep -c . || true)"; else sw="未取到(未安装 swapon)"; fi
  oomd="$(one systemctl is-active systemd-oomd)"; sshd="$(one systemctl is-active sshd)"
  smart="$(one systemctl is-active smartd)"; tm="$(one systemctl is-enabled unattended-upgrades)"
  pol="$(one grep -h Automatic-Reboot /etc/apt/apt.conf.d/52-dbk-unattended.conf)"
  kern="$(ls -1 "$BOOT_DIR"/vmlinuz-* 2>/dev/null | wc -l | tr -d ' ')"
  cat <<EOF
# baseline/04-robustness.md (L4 产物;卡 05-12,设计 04 第 7 节 R1-R9)

| # | 措施 | 现状 | 证据命令与输出摘要 | 回滚点 |
|---|---|---|---|---|
| R1 | 变更前备份 baseline/ | 现场记录:$(tcv "$( [ -d "$ROOT/baseline" ] && printf '存在' || printf '不存在' )") | $(etc "ls -d $ROOT/baseline") | 从 /var/backups/dbk/<时间戳>-baseline/ 取回 |
| R2 | 包级回退(apt install <pkg>=<版本> + apt-mark hold) | 已固定包:$(tcv "$(cap apt-mark showhold | tr '\n' ' ' || true)") | $(etc "apt-mark showhold; tail -n 4 /var/log/apt/history.log") | rollback-pkg.sh --apply --pkg <包> --version <版本> --yes |
| R3 | 旧内核保留 | $BOOT_DIR 下内核数=${kern:-0} | $(ecc ls "$BOOT_DIR") | GRUB 高级选项里选旧内核 |
| R4 | 永久救援介质(安装 U 盘兼 live) | 未取到(需人工:确认介质在位并标记"已验证可用") | $(etc "lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT") | 从 U 盘进入 live 环境修复 |
| R5 | 崩溃可观测(journald 持久化) | $(tcv "$JRNL=$jd") | $(etc "ls -d $JRNL; journalctl --disk-usage") | 无(仅提升可诊断性) |
| R6 | OOM 与内存压力防护(zram + swapfile) | zram $(tcv "$zr");swap $(tcv "$sw");systemd-oomd=$(tcv "$oomd") | $(etc "zramctl; swapon --show; systemctl is-enabled systemd-oomd") | 调整 zram / swapfile 大小(05-6) |
| R7 | 常开 SSH 救援通道 | sshd=$(tcv "$sshd") | $(etc "systemctl is-active sshd; ss -tln") | 关闭服务 |
| R8 | 保守更新(只安全更新、不自动重启) | Automatic-Reboot=$(tcv "$pol");unit=$(tcv "$tm");待升级=${up:-0} 包 | $(etc "grep -h Automatic-Reboot /etc/apt/apt.conf.d/52-dbk-unattended.conf; systemctl is-enabled unattended-upgrades") | 还原 <片段>.dbk.bak 并 disable 服务(05-7) |
| R9 | 磁盘健康监控(smartd) | smartd=$(tcv "$smart") | $(etc "systemctl is-active smartd; smartctl -H") | 无(提前发现硬件故障) |

说明:发行版版本=${ver:-未取到};本表替代原子版的"部署级回滚"口径 —— 没有一条命令回到上一个可用系统,
系统级恢复靠"原地重装两法 + 数据在 D: 不受影响"(设计 04 第 7 节的已接受取舍)。
EOF
}

put() {
  local f="$1" body="$2"
  if printf '%s\n' "$body" >"$f.new" && mv -f "$f.new" "$f"; then
    dbk_add_action "写入 $f($(printf '%s\n' "$body" | wc -l | tr -d ' ') 行)"
    dbk_add_check "产物已落盘: $f"
    return 0
  fi
  rm -f "$f.new" 2>/dev/null || true
  return 1
}

if [ "$DBK_MODE" = apply ]; then
  if [ -d "$SHARED" ]; then
    if touch "$SHARED/.dbk-write-test" 2>/dev/null && rm -f "$SHARED/.dbk-write-test" 2>/dev/null; then
      WT="通过(在 $SHARED 创建并删除 .dbk-write-test 成功)"
    else
      WT="失败(在 $SHARED 读写失败;按 05-1 核对 ntfs3 挂载与权限)"
    fi
  else
    WT="未取到(原因:$SHARED 未挂载;先跑 05-1 mount-shared.sh)"
  fi
fi
FB="$(first_boot_body)"; RB="$(robustness_body)"
if [ "$DBK_MODE" = apply ]; then
  mkdir -p "$OUTDIR" || dbk_exit FAIL "产物目录创建失败: $OUTDIR(核对路径与权限)"
  put "$OUTDIR/04-first-boot.md" "$FB" || dbk_exit FAIL "产物写入失败: $OUTDIR/04-first-boot.md(核对目录权限与磁盘空间)"
  put "$OUTDIR/04-robustness.md" "$RB" || dbk_exit FAIL "产物写入失败: $OUTDIR/04-robustness.md(核对目录权限与磁盘空间)"
  dbk_mark_changed
  dbk_add_check "共享盘写测试: $WT"
  dbk_exit PASS "L4 产物已落盘:$OUTDIR/04-first-boot.md 与 $OUTDIR/04-robustness.md(baseline/ 不入库)"
fi
if [ "${DBK_JSON:-0}" -eq 1 ]; then dbk_note "$FB"; dbk_note "$RB"; else printf '%s\n' "$FB"; printf '%s\n' "$RB"; fi
dbk_add_check "只打印(--check 零写);加 --apply 落盘到 $OUTDIR/04-first-boot.md 与 $OUTDIR/04-robustness.md"
dbk_exit PASS "L4 产物预览完成(--check 未写任何文件);加 --apply 落盘"
