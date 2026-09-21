#!/usr/bin/env bash
# 对应卡:05-5
# 破坏性:1
# L4 卡 05-5:蓝牙配对密钥同步包装(上游 KeyofBlueS/bt-keys-sync;本仓库不内置其代码)。
# 方向(上游建议,以 Windows 侧密钥为权威):1) Ubuntu 配对目标设备 -> 2) 回 Windows 对同一设备再配对
#   -> 3) 回 Ubuntu 用 --windows-keys 导入 -> 4) 复测两系统都能直连。**反向写 Windows 注册表有风险,本脚本不做**。
# 判据(--check,零写):① chntpw 已分层安装(rpm-ostree status 查询;DBK_SKIP_OSTREE=1 时记需人工);
#   ② Windows 注册表 hive 可读(<win-mnt>/Windows/System32/config/SYSTEM,只读挂载即可);
#   ③ 上游脚本已就位(--script 指定,或已下载到 DEST)。三项齐 → PASS(上游运行与两系统直连复测属卡内人工步骤)。
# --apply(需要 root,且必须 --yes):pkg_ensure chntpw 走 rpm-ostree 分层安装(chntpw 不在 Fedora 基础仓库,通常来自 RPM Fusion
#   free 源:分层安装前需先启用该源,rpm-ostree install 的具体源参数 # 待核实(以官方文档为准):
#   刚装完需重启,故本脚本在"本次才装上"时停下并要求重启后重跑)-> 下载上游脚本到 DEST(文件名/参数以仓库 README 为准)
#   -> bash <脚本> --windows-keys --path <hive> [-- 透传]。
# 环境开关:DBK_SKIP_OSTREE=1 跳过分层安装。注入:DBK_WIN_MNT / DBK_BT_SCRIPT / DBK_BT_DIR / DBK_BT_REPO。
# 夹具级验证,真机未跑。用法:bt-keys-sync-wrapper.sh [--win-mnt <挂载点>] [--script <上游脚本>] [--repo-url <地址>]
#   [--check|--apply] [--json] [--log <路径>] [--yes] [--step NN-K] [-- <上游额外参数>] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-ostree.sh disable=SC1091
. "$HERE/dbk-ostree.sh"
log() { dbk_obs "$*"; }   # dbk-log.sh 的 log() 打 stdout(会破坏 --json 单行输出),统一改走 stderr + 日志

WIN_MNT="${DBK_WIN_MNT:-}"; SCRIPT_PATH="${DBK_BT_SCRIPT:-}"
REPO_URL="${DBK_BT_REPO:-https://github.com/KeyofBlueS/bt-keys-sync}"
DEST="${DBK_BT_DIR:-/opt/bt-keys-sync}"
HIVE_REL="Windows/System32/config/SYSTEM"
PASSTHRU=(); ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --win-mnt) dbk_cli_val "--win-mnt" "${2:-}"; WIN_MNT="$2"; shift 2 ;;
    --win-mnt=*) WIN_MNT="${1#*=}"; shift ;;
    --script) dbk_cli_val "--script" "${2:-}"; SCRIPT_PATH="$2"; shift 2 ;;
    --script=*) SCRIPT_PATH="${1#*=}"; shift ;;
    --repo-url) dbk_cli_val "--repo-url" "${2:-}"; REPO_URL="$2"; shift 2 ;;
    --repo-url=*) REPO_URL="${1#*=}"; shift ;;
    --dry-run) shift ;;
    --) shift; PASSTHRU=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "bt-keys-sync-wrapper"
dbk_enable_errtrap
SKIP="${DBK_SKIP_OSTREE:-0}"
case "$SKIP" in 0|1) ;; *) dbk_usage; dbk_note "用法错误: DBK_SKIP_OSTREE 只接受 0/1: $SKIP"; exit "$DBK_USAGE" ;; esac

find_win_mnt() {
  local t
  while IFS= read -r t; do
    if [ -r "$t/$HIVE_REL" ]; then printf '%s\n' "$t"; return 0; fi
  done < <(findmnt -rn -o TARGET -t ntfs,ntfs3 2>/dev/null || true)
  return 1
}
resolve_win_mnt() {
  [ -n "$WIN_MNT" ] || WIN_MNT="$(find_win_mnt || true)"
  if [ -n "$WIN_MNT" ] && [ -r "$WIN_MNT/$HIVE_REL" ]; then HIVE_OK=1; else HIVE_OK=0; fi
  return 0
}
resolve_script() {
  local c
  [ -n "$SCRIPT_PATH" ] && return 0
  for c in bt-keys-sync.sh bt-keys-sync; do
    if [ -s "$DEST/$c" ]; then SCRIPT_PATH="$DEST/$c"; return 0; fi
  done
  return 0
}
fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 1; fi
}
download_upstream() {
  local repo="$1" dest="$2" base cand br url tmp
  case "$repo" in
    *.sh|*raw.githubusercontent.com*) tmp="$dest/$(basename "$repo")"
      if fetch "$repo" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then printf '%s\n' "$tmp"; return 0; fi
      rm -f "$tmp"; return 1 ;;
  esac
  base="${repo%/}"; base="${base%.git}"; base="${base#https://github.com/}"
  for cand in bt-keys-sync.sh bt-keys-sync; do
    for br in master main; do
      url="https://raw.githubusercontent.com/$base/$br/$cand"; tmp="$dest/$cand"
      if fetch "$url" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then printf '%s\n' "$tmp"; return 0; fi
      rm -f "$tmp"
    done
  done
  return 1
}

ISSUES=(); MANUAL=(); EXTRA_MANUAL=(); REBOOT_NEEDED=0

judge() {
  ISSUES=(); MANUAL=()
  resolve_win_mnt; resolve_script
  if [ "$SKIP" = 1 ]; then MANUAL+=("DBK_SKIP_OSTREE=1:跳过分层安装,chntpw 是否已装需人工确认")
  elif pkg_installed chntpw; then dbk_add_check "依赖 chntpw:已分层安装"
  else ISSUES+=("依赖 chntpw 未安装(--apply 会用 rpm-ostree install 分层安装,装完需重启)"); fi
  if [ "$HIVE_OK" = 1 ]; then dbk_add_check "Windows hive 可读:$WIN_MNT/$HIVE_REL"
  elif [ -n "$WIN_MNT" ]; then ISSUES+=("$WIN_MNT/$HIVE_REL 读不到:确认该挂载点就是 Windows 系统分区,并以**只读**方式挂载")
  else ISSUES+=("未找到已挂载的 Windows 分区:先 sudo mkdir -p /mnt/win && sudo mount -o ro <Windows 系统分区> /mnt/win,再带 --win-mnt /mnt/win 重跑"); fi
  if [ -n "$SCRIPT_PATH" ] && [ -s "$SCRIPT_PATH" ]; then dbk_add_check "上游脚本已就位:$SCRIPT_PATH"
  else ISSUES+=("上游脚本未就位(--script 指定,或 --apply 下载到 $DEST;文件名/参数以 $REPO_URL 的 README 为准,# 待核实)"); fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#EXTRA_MANUAL[@]}" -gt 0 ]; then MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"}); fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项前置未就绪;逐条见 checks,修好后重跑本脚本"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了或需重启后复核;逐条见 checks"
  fi
  dbk_exit PASS "$msg:前置三项就绪(chntpw 已装 + Windows hive 可读 + 上游脚本已就位);上游运行与两系统直连复测见卡 05-5"
}

apply_run() {
  local pkg_st=0 was=1 sha
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; }
  resolve_win_mnt
  if [ "$HIVE_OK" != 1 ]; then
    ISSUES+=("读不到 Windows 注册表 hive($WIN_MNT/$HIVE_REL)")
    dbk_exit FAIL "读不到 Windows 注册表 hive:先只读挂载 Windows 系统分区并带 --win-mnt <挂载点> 重跑"
  fi
  if ! pkg_installed chntpw; then was=0; fi
  pkg_ensure chntpw "sudo rpm-ostree install chntpw && sudo systemctl reboot" || pkg_st=$?
  if [ "$pkg_st" -eq 9 ]; then
    ISSUES+=("DBK_SKIP_OSTREE=1:无法安装 chntpw")
    dbk_exit FAIL "DBK_SKIP_OSTREE=1:跳过分层安装,但 --apply 需要 chntpw 读取 hive;去掉该开关后重跑"
  elif [ "$pkg_st" -eq 1 ]; then
    ISSUES+=("chntpw 分层安装失败")
    dbk_exit FAIL "chntpw 分层安装失败(见上面日志);硬前置:sudo rpm-ostree install chntpw && sudo systemctl reboot 后重跑"
  fi
  dbk_add_action "chntpw 已就位"
  if [ "$was" = 0 ]; then
    pkg_reboot_hint
    EXTRA_MANUAL+=("chntpw 本次才分层安装:必须重启后重跑本脚本,才能运行上游脚本(--windows-keys)")
    REBOOT_NEEDED=1
    return 0
  fi
  mkdir -p "$DEST" || { ISSUES+=("无法创建 $DEST"); dbk_exit FAIL "无法创建 $DEST"; }
  if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(download_upstream "$REPO_URL" "$DEST" || true)"
    if [ -z "$SCRIPT_PATH" ]; then
      ISSUES+=("下载上游脚本失败($REPO_URL)")
      dbk_exit FAIL "下载失败:候选 bt-keys-sync.sh / bt-keys-sync 的 master/main 都没取到;请按 $REPO_URL 的 README 手工下载到 $DEST 或用 --script 指定"
    fi
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    dbk_add_action "已下载上游脚本:$SCRIPT_PATH(分支尖端快照:无签名、无版本校验)"
    sha="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || true)"
    dbk_obs "上游脚本 SHA256: ${sha:-无法计算(缺 sha256sum)};建议先人工过目(less $SCRIPT_PATH)并记入 baseline/04-first-boot.md"
  else
    dbk_add_action "使用 --script 指定的副本:$SCRIPT_PATH(来源由你保证,本脚本不做下载校验)"
  fi
  UP_ARGS=(--windows-keys --path "$WIN_MNT/$HIVE_REL")
  if [ "${#PASSTHRU[@]}" -gt 0 ]; then UP_ARGS+=("${PASSTHRU[@]}"); fi
  dbk_add_action "运行: bash $SCRIPT_PATH ${UP_ARGS[*]}"; dbk_mark_changed
  if bash "$SCRIPT_PATH" "${UP_ARGS[@]}"; then
    dbk_add_action "上游脚本已按 --windows-keys 导入;未反向写 Windows 注册表"
  else
    dbk_exit FAIL "上游脚本以非 0 退出:把它的输出与 docs/05-first-boot.md 的 05-5 卡对照排障"
  fi
  return 0
}

if [ "$DBK_MODE" = apply ]; then apply_run; fi
if [ "$REBOOT_NEEDED" -ne 1 ]; then judge; fi
if [ "$DBK_MODE" = apply ]; then finish "蓝牙密钥同步已执行(--apply;复读前置判据)"; else finish "蓝牙密钥同步前置核对完成(--check 零写)"; fi
