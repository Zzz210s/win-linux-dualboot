#!/usr/bin/env bash
# 对应卡:05-14
# 破坏性:1
# 用途:snap 规避(S1 最小安装 + S2 清除残留 + S3 apt pin 压制 + S6 常用功能替代)。设计依据:
#   docs/design/04-kubuntu-variant-design.md 第 3 节(六条措施与四条判据)与第 1.1 节的事实清单
#   (归档里的 firefox/chromium-browser 是过渡包,apt install firefox 实际装的是 snap;do-release-upgrade 会重新引入 snap)。
# 判据(--check,缺省,零写)四条:① `snap list` 为空或 snap 命令不存在;② `dpkg -l snapd` 无输出(未安装);
#   ③ `apt-cache policy snapd` 无候选或被 pin 到 -1;④ `apt-get install -s firefox` 的模拟输出不含 snapd。
# --apply(需 --yes;脚本头已声明破坏性,缺 --yes 由库层直接拒 64 且零写):
#   ① 存在 snap 应用则逐个 `snap remove --purge <名>`,再 `apt-get purge -y snapd`;
#   ② 清理 /var/snap 与 /snap 残留(先 umount 再 rm -rf);
#   ③ 写 /etc/apt/preferences.d/no-snap(Package: snapd / Pin: release * / Pin-Priority: -1);
#   ④ 配置 Mozilla 官方 APT 仓库(keyring 落 /etc/apt/keyrings/,源文件带 signed-by,并给该源 Pin-Priority: 1000
#      以压过 Ubuntu 归档的过渡包),随后 apt-get update;
#   ⑤ 复跑 --check 的四条判据并给出结论。
# 边界(设计 04 第 3 节):不追求"系统里一个 snap 相关文件都没有";验收取"snap list 为空 + dpkg -l snapd 无输出 + 浏览器来源非 snap"三条可观测事实。
# 用法: step-snap-free.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 注入(夹具用):DBK_SNAP / DBK_DPKG / DBK_APT_CACHE / DBK_APT_GET / DBK_CURL / DBK_SNAP_PIN_FILE / DBK_SNAP_MNT / DBK_SNAP_VAR / DBK_MOZ_KEYRING / DBK_MOZ_SOURCES / DBK_MOZ_PREF。
# 待核实(以官方文档为准):Mozilla 仓库的 URL/keyring 名/优先级写法、`snap remove --purge` 的批量写法、apt-cache policy 在 pin -1 下的输出格式,均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "step-snap-free"

SNAP_STR="${DBK_SNAP:-snap}"; DPKG_STR="${DBK_DPKG:-dpkg}"; AC_STR="${DBK_APT_CACHE:-apt-cache}"
AG_STR="${DBK_APT_GET:-apt-get}"; CURL_STR="${DBK_CURL:-curl}"
PIN_FILE="${DBK_SNAP_PIN_FILE:-/etc/apt/preferences.d/no-snap}"
SNAP_MNT="${DBK_SNAP_MNT:-/snap}"; SNAP_VAR="${DBK_SNAP_VAR:-/var/snap}"
MOZ_KEYRING="${DBK_MOZ_KEYRING:-/etc/apt/keyrings/packages.mozilla.org.asc}"     # 待核实(以官方文档为准)
MOZ_SOURCES="${DBK_MOZ_SOURCES:-/etc/apt/sources.list.d/mozilla.list}"           # 待核实(以官方文档为准)
MOZ_PREF="${DBK_MOZ_PREF:-/etc/apt/preferences.d/mozilla}"                       # 待核实(以官方文档为准)
MOZ_URL="https://packages.mozilla.org/apt"                                       # 待核实(以官方文档为准)
MOZ_KEY_URL="https://packages.mozilla.org/apt/repo-signing-key.gpg"              # 待核实(以官方文档为准)
SNAP=(); DPKG=(); AC=(); AG=()
read -r -a SNAP <<<"$SNAP_STR"; read -r -a DPKG <<<"$DPKG_STR"
read -r -a AC <<<"$AC_STR"; read -r -a AG <<<"$AG_STR"
snap_() { command "${SNAP[@]}" "$@"; }   # 名字不与命令同名 + 体内 command 双保险:函数查找优先于 PATH,同名会无限递归
dpkg_() { command "${DPKG[@]}" "$@"; }
ac() { command "${AC[@]}" "$@"; }
ag() { command "${AG[@]}" "$@"; }
ISSUES=(); MANUAL=(); APPLY_FAILS=()

# 判据 ①:snap list 为空或 snap 命令不存在。返回 0=干净;1=有 snap 应用(应用名打到 stdout);2=读不到。
snap_apps() {
  local out
  if ! command -v "${SNAP[0]}" >/dev/null 2>&1; then return 0; fi
  out="$(snap_ list 2>&1)" || true
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then return 2; fi
  case "$out" in *"No snaps are installed"*|*"no snaps installed"*) return 0 ;; esac
  printf '%s\n' "$out" | awk 'NR>1 && $1 !~ /^Name$/ && NF>0 {print $1}'
  return 1
}
# 判据 ②:dpkg -l snapd 无输出(未安装)。返回 0=未装;1=已装;2=dpkg 不可用。
snapd_installed() {
  local out
  command -v "${DPKG[0]}" >/dev/null 2>&1 || return 2
  out="$(dpkg_ -l snapd 2>&1)" || true
  if printf '%s\n' "$out" | grep -qE '^ii[[:space:]]+snapd'; then return 1; fi
  return 0
}
# 判据 ③:apt-cache policy snapd 无候选或被 pin 到 -1。返回 0=已压制;1=有候选且未压制;2=读不到。
snapd_pinned() {
  local out cand
  if ! command -v "${AC[0]}" >/dev/null 2>&1; then return 2; fi
  out="$(ac policy snapd 2>&1)" || true
  cand="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)"
  case "$cand" in ""|"(none)"|none|无) return 0 ;; esac
  if [ -r "$PIN_FILE" ] && grep -qE '^[[:space:]]*Pin-Priority:[[:space:]]*-1[[:space:]]*$' "$PIN_FILE"; then return 0; fi
  return 1
}
# 判据 ④:apt-get install -s firefox 的模拟输出不含 snapd。返回 0=不含;1=含 snapd;2=模拟跑不起来。
sim_firefox_dep() {
  local out
  command -v "${AG[0]}" >/dev/null 2>&1 || return 2
  out="$(ag install -s firefox 2>&1)" || true
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then return 2; fi
  case "$out" in *"no packages found"*|*"无法定位"*|*"Unable to locate"*) return 2 ;; esac
  if printf '%s\n' "$out" | grep -qE '(^|[[:space:]])snapd([[:space:]]|$)'; then return 1; fi
  return 0
}

judge() {
  local apps rc=0
  ISSUES=(); MANUAL=()
  apps="$(snap_apps)" || rc=$?
  case "$rc" in
    0) dbk_add_check "S1/S2 ①:snap list 为空或 snap 命令不存在" ;;
    1) ISSUES+=("S2 ①:仍有 snap 应用:$(printf '%s' "$apps" | tr '\n' ' ')(--apply 会逐个 snap remove --purge)") ;;
    2) MANUAL+=("①:snap list 无输出也读不到结论(命令异常);请人工跑 snap list") ;;
  esac
  rc=0; snapd_installed || rc=$?
  case "$rc" in
    0) dbk_add_check "S2 ②:dpkg -l snapd 无输出(未安装)" ;;
    1) ISSUES+=("S2 ②:snapd 已安装(dpkg -l 有 ii 行);--apply 会 apt-get purge -y snapd") ;;
    2) MANUAL+=("②:未找到 ${DPKG[0]},无法核对 snapd 是否安装") ;;
  esac
  rc=0; snapd_pinned || rc=$?
  case "$rc" in
    0) dbk_add_check "S3 ③:apt-cache policy snapd 无候选或被 pin 到 -1($PIN_FILE)" ;;
    1) ISSUES+=("S3 ③:snapd 仍有候选且未被压制;--apply 会写 $PIN_FILE 的 Pin-Priority: -1") ;;
    2) MANUAL+=("③:未找到 ${AC[0]},无法核对 snapd 候选") ;;
  esac
  rc=0; sim_firefox_dep || rc=$?
  case "$rc" in
    0) dbk_add_check "S4 ④:apt-get install -s firefox 的模拟输出不含 snapd" ;;
    1) ISSUES+=("S4 ④:模拟安装 firefox 会把 snapd 拉进来(归档里的 firefox 是过渡包);--apply 会配 Mozilla 官方源并给 Pin-Priority: 1000") ;;
    2) MANUAL+=("④:apt-get -s 跑不起来或 firefox 不在已配置仓库里;请人工核对浏览器来源") ;;
  esac
  # S6 附加证据(不作为失败项)
  dbk_add_check "S6 附加证据(不作为失败项):plasma-discover=$(command -v plasma-discover >/dev/null 2>&1 && plasma-discover --version 2>&1 | head -n1 || printf '未取到');fwupd=$(command -v fwupdmgr >/dev/null 2>&1 && fwupdmgr --version 2>&1 | head -n1 || printf '未取到')"
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${APPLY_FAILS[@]+"${APPLY_FAILS[@]}"}; do ISSUES+=("$m"); done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:snap 四条判据全部达成(snap list 为空 / snapd 未装 / 候选已被 pin -1 / 模拟装 firefox 不拉 snapd)"
}

write_pin() {
  local f="$1" body="$2"
  mkdir -p "$(dirname "$f")" || { APPLY_FAILS+=("目录创建失败: $(dirname "$f")"); return 0; }
  if [ -f "$f" ] && [ ! -e "$f.dbk.bak" ]; then
    cp -a "$f" "$f.dbk.bak" || { APPLY_FAILS+=("备份失败: $f"); return 0; }
    dbk_add_action "备份 $f -> $f.dbk.bak"
  fi
  if printf '%s' "$body" >"$f"; then dbk_add_action "写入 $f"; dbk_mark_changed
  else APPLY_FAILS+=("写入失败: $f"); fi
  return 0
}

apply_run() {
  local apps rc=0 sdi=0 name out
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; }
  # ① 逐个移除 snap 应用,再 purge snapd
  apps="$(snap_apps)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    for name in $apps; do
      out="$(snap_ remove --purge "$name" 2>&1)" || { APPLY_FAILS+=("snap remove --purge $name 失败: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"); continue; }
      dbk_add_action "snap remove --purge $name"; dbk_mark_changed
    done
  fi
  snapd_installed || sdi=$?
  if [ "$sdi" -eq 1 ]; then
    if out="$(ag purge -y snapd 2>&1)"; then
      dbk_add_action "apt-get purge -y snapd"; dbk_mark_changed
    else
      APPLY_FAILS+=("apt-get purge -y snapd 失败: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')")
    fi
  fi
  # ② 清理残留挂载点与目录
  for d in "$SNAP_MNT" "$SNAP_VAR"; do
    [ -e "$d" ] || continue
    umount "$d" >/dev/null 2>&1 || true
    if rm -rf "$d" 2>/dev/null; then dbk_add_action "清理残留:$d"; dbk_mark_changed
    else APPLY_FAILS+=("清理失败:$d(可能被占用;先 umount 后手工 rm -rf)"); fi
  done
  # ③ apt pin 压制 snapd
  write_pin "$PIN_FILE" "Package: snapd
Pin: release *
Pin-Priority: -1
"
  # ④ Mozilla 官方 APT 仓库(keyring + 源 + 高优先级 pin),随后 apt-get update
  mkdir -p "$(dirname "$MOZ_KEYRING")" 2>/dev/null || true
  if command -v "${CURL_STR%% *}" >/dev/null 2>&1 && "$CURL_STR" -fsSL "$MOZ_KEY_URL" -o "$MOZ_KEYRING" 2>&1; then
    dbk_add_action "下载 Mozilla 仓库签名密钥 -> $MOZ_KEYRING"; dbk_mark_changed
  else
    APPLY_FAILS+=("下载 $MOZ_KEY_URL 失败(缺 curl 或网络不通);请按官方文档手工安装密钥到 $MOZ_KEYRING")
  fi
  write_pin "$MOZ_SOURCES" "deb [signed-by=$MOZ_KEYRING] $MOZ_URL mozilla main
"
  write_pin "$MOZ_PREF" "Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
"
  if ag update >/dev/null 2>&1; then dbk_add_action "apt-get update(纳入 Mozilla 仓库)"
  else APPLY_FAILS+=("apt-get update 失败(见上面 stderr);先核对 $MOZ_SOURCES 的写法"); fi
  return 0
}

if [ "$DBK_MODE" = apply ]; then
  apply_run
  judge
  finish "snap 规避已执行(--apply;复读四条判据)"
fi
judge
finish "snap 规避判据核对完成(--check 零写)"
