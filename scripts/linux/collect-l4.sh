#!/usr/bin/env bash
# 对应卡:05-12
# 用途:落 L4 产物(设计依据:docs/design/00-design.md 4.5 的首启收敛清单与 4.7 的 R1-R9 健壮性九项)。
#   --apply 写 <out-dir>/04-first-boot.md 与 <out-dir>/04-robustness.md;--check(缺省)只打印将落盘的节,零写。
#   04-first-boot.md 记:主机/内核/模式/时间、会话类型、rpm-ostree status 摘要(部署/版本/来源/pin)、GPU 模块
#   (lsmod 的 nvidia 摘要)、Secure Boot 与 MOK(mokutil 摘要)、zram 与 swap、findmnt 的共享盘与 swapfile、
#   共享盘写测试结果。
#   04-robustness.md 记 R1-R9 逐项一行(措施 / 现状 / 证据命令与输出摘要 / 回滚点);取不到的写「未取到(原因)」,
#   不编造。R5 journald 持久化、R6 zram+swapfile、R7 sshd、R8 rpm-ostreed-automatic、R9 smartd 必有证据行。
# 用法: collect-l4.sh [--check|--apply] [--out-dir <目录>] [--json] [--log <路径>] [--step NN-K]
# 判据与纪律:产物落 baseline/(不入库,仅 baseline/README.md 例外;多设备用 baseline/<设备别名>/);
#   --apply 先写 <文件>.new 再 mv 原子替换;共享盘写测试只在 --apply 执行(--check 必须零写,连共享盘上的
#   临时文件也不碰)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。本卡无破坏性动作(不声明「# 破坏性:1」,不需 --yes)。
# 注入(真机不需要设置):DBK_OUT_DIR(输出目录)、DBK_SHARED_MNT(共享盘挂载点)、DBK_BOOT_DIR(/boot)、
#   DBK_SWAPFILE(/swapfile)、DBK_JOURNAL_DIR(journald 持久化目录)。
# 待核实(以官方文档为准):rpm-ostree status 文本解析、systemd 单元名(rpm-ostreed-automatic.timer / sshd /
#   smartd)与 journald 持久化目录未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
OUTDIR="${DBK_OUT_DIR:-$ROOT/baseline}"; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --out-dir 缺取值(输出目录)"; exit "$DBK_USAGE"; }; OUTDIR="$2"; shift 2 ;;
    --out-dir=*) OUTDIR="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "collect-l4"
SHARED="${DBK_SHARED_MNT:-/mnt/shared}"; BOOT_DIR="${DBK_BOOT_DIR:-/boot}"
SWAPFILE="${DBK_SWAPFILE:-/swapfile}"; JRNL="${DBK_JOURNAL_DIR:-/var/log/journal}"
OSTREED_CONF="${DBK_RPM_OSTREED_CONF:-/etc/rpm-ostreed.conf}"
WT="未取到(原因:--check 零写,不碰共享盘;--apply 时才做写测试)"

have() { command -v "${1:-}" >/dev/null 2>&1; }
cap() { "$@" 2>&1 || true; }
capn() { local n="${1:-1}"; shift; { cap "$@" || true; } | head -n "$n" | tr '\n' ' ' | cut -c1-200 || true; }
one() { if have "${1:-}"; then capn 1 "$@"; else printf '未取到(未安装 %s)' "${1:-}"; fi; }
nlines() { local n; n="$(printf '%s\n' "${1:-}" | grep -c . || true)"; printf '%s' "${n:-0}"; }
ev() {
  local out
  if ! have "${1:-}"; then printf '%s -> 未取到(未安装 %s)' "$*" "${1:-}"; return 0; fi
  out="$( { "$@" 2>&1 || true; } | tr '\n' ' ' | cut -c1-200 || true)"
  printf '%s -> %s' "$*" "${out:-（无输出）}"
}
evs() {
  local out
  out="$( { bash -c "$1" 2>&1 || true; } | tr '\n' ' ' | cut -c1-200 || true)"
  out="${out:-（无输出）}"
  case "$out" in *"command not found"*) out="未取到(原因: $out)" ;; esac
  printf '%s -> %s' "$1" "$out"
}
# 表格单元格里的证据/现状：把 '|' 转义成 '\|'，否则会撑破 04-robustness.md 的 markdown 表。
tcv() { printf '%s' "${1:-}" | sed 's/|/\\|/g'; }
etc() { evs "$1" | sed 's/|/\\|/g'; }
ecc() { ev "$@" | sed 's/|/\\|/g'; }

# rpm-ostree status 文本解析(未在真机验证):部署条目 = 可选标记(●/○/*) + <镜像引用>;列表第一项=下次默认
# 启动的部署,带 ● 的 =当前已启动的部署;`Pinned: yes` 行 =有部署被固定。
DEPRE='^[[:space:]]*(●|○|\*)?[[:space:]]*[A-Za-z0-9._+-]+:[^[:space:]]*(//|fedora)'
dep_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE "$DEPRE" || true)"; printf '%s' "${n:-0}"; }
next_ref() { printf '%s\n' "${1:-}" | grep -m1 -E "$DEPRE" | sed -E 's/^[[:space:]]*(●|○|\*)?[[:space:]]*//' || true; }
booted_ref() { printf '%s\n' "${1:-}" | grep -m1 -E '^[[:space:]]*●' | sed -E 's/^[[:space:]]*(●|○|\*)?[[:space:]]*//' || true; }
pin_count() { local n; n="$(printf '%s\n' "${1:-}" | grep -cE '^[[:space:]]*Pinned:[[:space:]]*yes' || true)"; printf '%s' "${n:-0}"; }
booted_ver() {
  printf '%s\n' "${1:-}" | awk '/^[[:space:]]*●/{f=1} f&&/^[[:space:]]*Version:/{sub(/^[[:space:]]*Version:[[:space:]]*/,"");print;exit}' || true
}
session_line() {
  case "${XDG_SESSION_TYPE:-}" in
    wayland) printf 'XDG_SESSION_TYPE=wayland(符合要求)' ;;
    "") printf 'XDG_SESSION_TYPE=未取到(需人工:不在图形会话里?)' ;;
    *) printf 'XDG_SESSION_TYPE=%s(不符合要求,应为 wayland)' "$XDG_SESSION_TYPE" ;;
  esac
}

first_boot_body() {
  local st note; st="$(cap rpm-ostree status)"     # 待核实(以官方文档为准)
  case "$st" in *"command not found"*) note="未取到(原因: rpm-ostree 不可用)" ;; *) note="ok" ;; esac
  cat <<EOF
# baseline/04-first-boot.md (L4 产物;卡 05-12,设计 4.5)

## 主机 / 内核 / 模式 / 时间
host=$(capn 1 hostname)
kernel=$(capn 1 uname -r)
mode=XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-未取到}
cmdline=$(capn 1 cat /proc/cmdline)
date=$(date '+%Y-%m-%d %H:%M:%S%z')

## 会话类型(XDG_SESSION_TYPE)
$(session_line)
loginctl=$(one loginctl list-sessions)

## rpm-ostree status 摘要(部署 / 版本 / 来源 / pin)
rpm-ostree=$note
部署数=$(dep_count "$st");下一次启动=$(next_ref "$st");当前启动=$(booted_ref "$st");当前部署版本=$(booted_ver "$st");已固定部署数=$(pin_count "$st")
--- status 原文(前 40 行)---
$(printf '%s' "$st" | head -n 40 || true)

## GPU 模块(lsmod 摘要)
$(evs "lsmod | grep -E '^(nvidia|nouveau)'")

## Secure Boot 与 MOK(mokutil 摘要)
$(ev mokutil --sb-state)
$(evs "mokutil --list-enrolled | head -n 6")

## 内存压力防护(zram 与 swap)
$(evs "zramctl; swapon --show; systemctl is-enabled systemd-oomd")

## 挂载(共享盘与 swapfile)
$(ev findmnt "$SHARED")
$(ev findmnt "$SWAPFILE")
$(evs "grep -n nofail /etc/fstab")

## 共享盘写测试
$WT
EOF
}

robustness_body() {
  local st pins jd zr sw oomd sshd smart pol tm vc
  st="$(cap rpm-ostree status)"     # 待核实(以官方文档为准)
  pins="$(pin_count "$st")"
  if [ -d "$JRNL" ]; then jd="存在"; else jd="不存在"; fi
  if have zramctl; then zr="行数=$(nlines "$(cap zramctl)")"; else zr="未取到(未安装 zramctl)"; fi
  if have swapon; then sw="行数=$(nlines "$(cap swapon --show)")"; else sw="未取到(未安装 swapon)"; fi
  oomd="$(one systemctl is-enabled systemd-oomd)"; sshd="$(one systemctl is-active sshd)"
  smart="$(one systemctl is-active smartd)"; tm="$(one systemctl is-enabled rpm-ostreed-automatic.timer)"
  pol="$(one grep -h AutomaticUpdatePolicy "$OSTREED_CONF")"
  vc="$( { cap ls "$BOOT_DIR/loader/entries" || true; } | grep -c ostree || true)"
  cat <<EOF
# baseline/04-robustness.md (L4 产物;卡 05-12,设计 4.7 的 R1-R9)

| # | 措施 | 现状 | 证据命令与输出摘要 | 回滚点 |
|---|---|---|---|---|
| R1 | 变更前固定当前部署(平时不额外固定) | 已固定部署数=$pins | $(etc "rpm-ostree status | grep Pinned") | 选回被固定的部署 |
| R2 | 部署级回滚(开机菜单选旧部署 / rpm-ostree rollback) | 部署数=$(dep_count "$st");下一次启动=$(next_ref "$st");当前启动=$(booted_ref "$st") | $(etc "rpm-ostree status | head -n 3") | 部署列表里的任一新旧部署 |
| R3 | 多部署保留 + 一次性启动 | $BOOT_DIR/loader/entries 的 ostree 条目数=$vc | $(ecc ls "$BOOT_DIR/loader/entries") | 选旧部署 / 固件 BootNext |
| R4 | 永久救援介质(安装 U 盘兼 live) | 未取到(需人工:确认介质在位并标记"已验证可用") | $(etc "lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT") | 从 U 盘进入 live 环境修复 |
| R5 | 崩溃可观测(journald 持久化) | $(tcv "$JRNL=$jd") | $(etc "ls -d $JRNL; journalctl --disk-usage") | 无(仅提升可诊断性) |
| R6 | OOM 与内存压力防护(zram + swapfile) | zram $(tcv "$zr");swap $(tcv "$sw");systemd-oomd=$(tcv "$oomd") | $(etc "zramctl; swapon --show; systemctl is-enabled systemd-oomd") | 调整 zram / swapfile 大小 |
| R7 | 常开 SSH 救援通道 | sshd=$(tcv "$sshd") | $(etc "systemctl is-active sshd; ss -tln") | 关闭服务 |
| R8 | 保守更新策略(rpm-ostreed-automatic 只 check/download) | AutomaticUpdatePolicy=$(tcv "$pol");timer=$(tcv "$tm") | $(etc "grep -h AutomaticUpdatePolicy $OSTREED_CONF; systemctl is-enabled rpm-ostreed-automatic.timer") | 选回被固定的部署 |
| R9 | 磁盘健康监控(smartd) | smartd=$(tcv "$smart") | $(etc "systemctl is-active smartd; smartctl -H") | 无(提前发现硬件故障) |
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
