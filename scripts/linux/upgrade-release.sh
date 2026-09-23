#!/usr/bin/env bash
# 对应卡:05-10
# 破坏性:1
# 用途:发行版升级(Kubuntu 26.04 LTS -> 下一 LTS 的 `do-release-upgrade` 流程)。设计依据:
#   docs/design/04-kubuntu-variant-design.md 第 2 节 D2(LTS 3 年,大版本升级写成正式卡)、第 3 节 S5
#   (do-release-upgrade 会重新引入 snap,升级后必须复核)与第 7 节 R1(变更前备份 baseline/)。
# 判据(--check,零写):① /etc/os-release 的版本可读;② `apt-get -s dist-upgrade` 无异常(模拟升级不报 E:);
#   ③ 升级前要留档的两份配置存在(apt pin 文件 /etc/apt/preferences.d/no-snap 与 Mozilla 源文件);
#   ④ `do-release-upgrade` 命令可用。缺一项 → FAIL(不是失败也得先补齐,升级中途出问题代价更高)。
# --apply(需 --yes,库层按脚本头「# 破坏性:1」拦):
#   前置:备份 baseline/ 到 <backup-dir>/<时间戳>-baseline/、把 pin 与 Mozilla 源文件内容写进日志留档、
#     复跑 `apt-get -s dist-upgrade` 确认无异常(有异常则**不执行**升级);
#   执行:`do-release-upgrade -f DistUpgradeViewNonInteractive`;
#   后置复核:系统版本、XDG_SESSION_TYPE=wayland、显卡驱动(nvidia-smi / 签名者)、**按 S5 复跑 snap 四条判据**
#     (调 step-snap-free.sh --check;不通过则提示按 05-14 重写 pin 与 Mozilla 源)。
# 关键纪律(设计 04 第 9 节风险表):升级前必须留档 pin 与 Mozilla 源;升级后 snap 复核不通过不得算通过。
# 用法: upgrade-release.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。默认只读(--check)。
# 注入(真机不需要设置):DBK_DO_RELEASE_UPGRADE / DBK_APT_GET / DBK_OS_RELEASE / DBK_BASELINE_DIR /
#   DBK_BACKUP_DIR / DBK_SNAP_PIN_FILE / DBK_MOZ_SOURCES / DBK_NVIDIA_SMI / DBK_SNAP_FREE(step-snap-free.sh 路径)。
# 待核实(以官方文档为准):do-release-upgrade 的 -f DistUpgradeViewNonInteractive 参数、apt-get -s dist-upgrade
#   的报错文本、/etc/os-release 的 VERSION_ID 取值均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "upgrade-release"

DRU_STR="${DBK_DO_RELEASE_UPGRADE:-do-release-upgrade}"   # 待核实(以官方文档为准)
AG_STR="${DBK_APT_GET:-apt-get}"; OS_RELEASE="${DBK_OS_RELEASE:-/etc/os-release}"
BASEDIR="${DBK_BASELINE_DIR:-$ROOT/baseline}"; BAKDIR="${DBK_BACKUP_DIR:-/var/backups/dbk}"
PIN_FILE="${DBK_SNAP_PIN_FILE:-/etc/apt/preferences.d/no-snap}"
MOZ_SOURCES="${DBK_MOZ_SOURCES:-/etc/apt/sources.list.d/mozilla.list}"
SMI_STR="${DBK_NVIDIA_SMI:-nvidia-smi}"; SNAP_FREE="${DBK_SNAP_FREE:-$HERE/step-snap-free.sh}"
DRU=(); AG=(); SMI=(); read -r -a DRU <<<"$DRU_STR"; read -r -a AG <<<"$AG_STR"; read -r -a SMI <<<"$SMI_STR"
dru() { command "${DRU[@]}" "$@"; }
ag() { command "${AG[@]}" "$@"; }
smi() { command "${SMI[@]}" "$@"; }
ISSUES=(); MANUAL=(); PROBE_OUT=""; PROBE_RC=0
probe() { local out; if out="$("$@" 2>&1)"; then PROBE_RC=0; else PROBE_RC=$?; fi; PROBE_OUT="$out"; return 0; }
tail3() { printf '%s' "${1:-}" | tail -n 3 | tr '\n' ' '; }
os_ver() { grep -m1 -E '^VERSION_ID=' "$OS_RELEASE" 2>/dev/null | cut -d= -f2- || true; }
os_name() { grep -m1 -E '^PRETTY_NAME=' "$OS_RELEASE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }
dist_upgrade_ok() {   # 模拟升级无异常 → 0;有 E:/错误 → 1;跑不起来 → 2
  command -v "${AG[0]}" >/dev/null 2>&1 || return 2
  probe ag -s dist-upgrade
  if [ "$PROBE_RC" -ne 0 ] && [ -z "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then return 2; fi
  case "$PROBE_OUT" in
    *"E:"*|*"错误"*|*"broken"*|*"held broken"*) return 1 ;;
  esac
  return 0
}

check_all() {
  local ver rc=0
  ISSUES=(); MANUAL=()
  ver="$(os_ver)"
  if [ -n "$ver" ]; then dbk_add_check "①当前系统:${ver}($(os_name))"
  else MANUAL+=("①读不到 $OS_RELEASE 的 VERSION_ID;请人工确认当前发行版版本"); fi
  rc=0; dist_upgrade_ok || rc=$?
  case "$rc" in
    0) dbk_add_check "②apt-get -s dist-upgrade 模拟无异常" ;;
    1) ISSUES+=("②apt-get -s dist-upgrade 报异常:$(printf '%s\n' "$PROBE_OUT" | grep -E 'E:|错误|broken' | head -n 2 | tr '\n' ' ' || true)") ;;
    2) MANUAL+=("②apt-get -s 跑不起来或 ${AG[0]} 缺失;请人工跑 apt-get -s dist-upgrade 核对") ;;
  esac
  if [ -r "$PIN_FILE" ]; then dbk_add_check "③snap pin 留档可读:$PIN_FILE -> $(tr '\n' ';' <"$PIN_FILE")"
  else ISSUES+=("③缺 $PIN_FILE:先跑 05-14 的 step-snap-free.sh --apply 建立 snap 压制,再升级(否则升级会把 snap 拉回来)"); fi
  if [ -r "$MOZ_SOURCES" ]; then dbk_add_check "③Mozilla 源留档可读:$MOZ_SOURCES -> $(tr '\n' ';' <"$MOZ_SOURCES")"
  else ISSUES+=("③缺 $MOZ_SOURCES:浏览器来源会在升级后回到 snap 过渡包;先按 05-14 配置 Mozilla 官方源"); fi
  if command -v "${DRU[0]}" >/dev/null 2>&1; then dbk_add_check "④$DRU_STR 可用"
  else ISSUES+=("④未找到 ${DRU[0]}:装 update-manager-core(sudo apt-get install -y update-manager-core)后重跑"); fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项前置未就绪;逐条见 checks,补齐后再考虑 --apply"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:版本可读、模拟升级无异常、pin 与 Mozilla 源留档齐全、do-release-upgrade 可用"
}

check_all
if [ "$DBK_MODE" != apply ]; then
  finish "发行版升级前置核对完成(--check 零写)"
fi

# ---- 以下只在 --apply 路径执行 ----
if [ "$(id -u)" -ne 0 ]; then
  dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
  dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"
fi
check_all
if [ "${#ISSUES[@]}" -gt 0 ]; then finish "升级前置未通过,按纪律不执行升级"; fi
V1="$(os_ver)"
TS="$(date '+%Y%m%d-%H%M%S')"; BAK="$BAKDIR/$TS-baseline"
mkdir -p "$BAKDIR" || { dbk_add_check "失败项: 无法创建备份目录 $BAKDIR"; dbk_exit FAIL "备份目录创建失败:$BAKDIR(核对路径与权限)"; }
if [ -d "$BASEDIR" ]; then
  if cp -a "$BASEDIR" "$BAK"; then dbk_add_action "备份 baseline/ -> $BAK"; dbk_mark_changed
  else dbk_add_check "失败项: cp -a $BASEDIR $BAK 失败"; dbk_exit FAIL "baseline/ 备份失败:按纪律不执行升级(升级前必须留一份现场记录)"; fi
else
  dbk_add_check "需人工: 没有 $BASEDIR 可备份(先跑 03-9/05-12 落产物,或确认本机不需要留档)"
fi
dbk_note "留档: snap pin($PIN_FILE)内容 -> $(tr '\n' ';' <"$PIN_FILE" 2>/dev/null || printf '未取到')"
dbk_note "留档: Mozilla 源($MOZ_SOURCES)内容 -> $(tr '\n' ';' <"$MOZ_SOURCES" 2>/dev/null || printf '未取到')"
dbk_add_action "把 pin 与 Mozilla 源内容写进日志留档(升级后按 S5 复核)"
OUT=""; RC=0
OUT="$(dru -f DistUpgradeViewNonInteractive 2>&1)" || RC=$?
if [ "$RC" -ne 0 ]; then
  dbk_add_check "失败项: $DRU_STR 退出码 $RC"
  dbk_exit FAIL "发行版升级失败: $(tail3 "$OUT");按上面的输出排障;系统仍可继续用旧版本,数据在 D: 不受影响"
fi
dbk_add_action "$DRU_STR -f DistUpgradeViewNonInteractive"; dbk_mark_changed
# 后置复核(重启后重跑本脚本可得更完整的结论;此处先按当前状态判定)
ISSUES=(); MANUAL=()
V2="$(os_ver)"
if [ -z "$V2" ]; then MANUAL+=("后置: 读不到升级后的版本($OS_RELEASE)")
else dbk_add_check "后置: 升级前版本=${V1:-未取到} -> 升级后版本=$V2($(os_name))"; fi
case "${XDG_SESSION_TYPE:-}" in
  wayland) dbk_add_check "后置: 会话类型 wayland" ;;
  "") MANUAL+=("后置: XDG_SESSION_TYPE 取不到(不在图形会话里?)") ;;
  *) ISSUES+=("后置: XDG_SESSION_TYPE=${XDG_SESSION_TYPE}(要求 wayland)") ;;
esac
if command -v "${SMI[0]}" >/dev/null 2>&1; then
  probe smi
  if [ "$PROBE_RC" -eq 0 ]; then dbk_add_check "后置: nvidia-smi 可用(显卡驱动来源为 Ubuntu 官方包)"
  else MANUAL+=("后置: nvidia-smi 执行失败(退出码 $PROBE_RC);重启后重跑,仍失败则按 05-3 处置"); fi
else
  MANUAL+=("后置: 未找到 ${SMI[0]};按 05-3 核对显卡驱动")
fi
# S5:升级会重新引入 snap —— 复跑四条判据
if [ -x "$SNAP_FREE" ] || [ -r "$SNAP_FREE" ]; then
  SNAP_OUT=""; SNAP_RC=0
  SNAP_OUT="$(bash "$SNAP_FREE" --check 2>&1)" || SNAP_RC=$?
  if [ "$SNAP_RC" -eq 0 ]; then dbk_add_check "后置 S5: step-snap-free.sh --check 四条判据仍全绿"
  else
    ISSUES+=("后置 S5: step-snap-free.sh --check 退出码 $SNAP_RC:$(printf '%s\n' "$SNAP_OUT" | tail -n 2 | tr '\n' ' ');按 05-14 重写 $PIN_FILE 与 Mozilla 源后重跑")
  fi
else
  MANUAL+=("后置 S5: 找不到 $SNAP_FREE,无法复跑 snap 四条判据;请人工核对 snap list / dpkg -l snapd")
fi
finish "发行版升级已执行(--apply;后置复核与 S5 复核见 checks)"
