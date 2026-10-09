#!/usr/bin/env bash
# 对应卡:05-22
# 破坏性:1(--apply 会执行一次 restic 备份与保留策略;必须显式 --yes)
# L4 卡 05-22:备份与同步(restic + rclone)。备份对象 = 家目录文档 + /etc 漂移快照 + Flatpak/brew 清单;
#   目标 = 本机 baseline/ 快照(已有)+ 服务器 62.234.211.51(经 rclone);外置盘只留接口。
#   **仓库地址与密码只从环境变量或本地 600 文件读**:脚本绝不写凭据、不把密码打进日志、不新建凭据文件。
# 判据(--check,零写):① restic 在位(缺 → 1 FAIL);② rclone 在位(缺 → 2 需人工:本机 baseline/ 快照不需要它);
#   ③ RESTIC_REPOSITORY 已配置(缺 → 1 FAIL);④ 密码来源可读(RESTIC_PASSWORD 环境变量,或 RESTIC_PASSWORD_FILE
#   文件可读;都缺 → 1 FAIL);⑤ 最近一次快照在 DBK_BACKUP_DAYS 期内(读不到/没有快照/已过期 → 1 FAIL)。
# --apply(需要 root,必须 --yes):生成 Flatpak/brew 清单与 /etc 漂移快照,跑一次
#   `restic backup`(文档目录 + /etc + 清单),再执行保留策略 `restic forget --keep-last N --prune`(幂等)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: backup-home.sh [--check|--apply --yes] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要):DBK_RESTIC / DBK_RCLONE / RESTIC_REPOSITORY / RESTIC_PASSWORD_FILE / RESTIC_PASSWORD /
#   DBK_BACKUP_DAYS / DBK_BACKUP_KEEP / DBK_BACKUP_DOCS / DBK_BACKUP_ETC / DBK_BACKUP_MFDIR / DBK_NOW / DBK_OSTREE /
#   DBK_FLATPAK / DBK_BREW。DBK_NOW 覆盖「当前时间」(epoch 秒),让「快照是否在期内」可离线复现。
# 夹具级验证,真机未跑。待核实(以 restic 官方文档为准):`restic snapshots --latest 1 --json` 的 time 字段格式、
#   `restic forget --keep-last` 的语义与 --prune 的代价。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # 与其它步骤脚本统一脚本头;本脚本不读仓库文件
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-flatpak.sh disable=SC1091
. "$HERE/dbk-flatpak.sh"
# shellcheck source=scripts/linux/dbk-brew.sh disable=SC1091
. "$HERE/dbk-brew.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "backup-home"
dbk_enable_errtrap

RESTIC_STR="${DBK_RESTIC:-restic}"; RCLONE_STR="${DBK_RCLONE:-rclone}"; OSTREE_STR="${DBK_OSTREE:-ostree}"
RESTIC=(); read -r -a RESTIC <<<"$RESTIC_STR"
REPO="${RESTIC_REPOSITORY:-}"; PWFILE="${RESTIC_PASSWORD_FILE:-}"
DAYS="${DBK_BACKUP_DAYS:-7}"; KEEP="${DBK_BACKUP_KEEP:-7}"
DOCS="${DBK_BACKUP_DOCS:-$HOME/Documents}"; ETC="${DBK_BACKUP_ETC:-/etc}"
MFDIR="${DBK_BACKUP_MFDIR:-$HOME/.local/state/dbk/backup-manifests}"
now() { printf '%s' "${DBK_NOW:-$(date +%s)}"; }
first() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-140 || true; }
avail() { [ -e "${1:-}" ] || command -v "${1%% *}" >/dev/null 2>&1; }

pw_source() {   # 返回密码来源描述;没有可读来源 → 打印空
  if [ -n "${RESTIC_PASSWORD:-}" ]; then printf 'RESTIC_PASSWORD 环境变量'
  elif [ -n "$PWFILE" ] && [ -r "$PWFILE" ]; then printf 'RESTIC_PASSWORD_FILE 文件(%s)' "$PWFILE"
  else printf ''; fi
}

ISSUES=(); MANUAL=()
check_tools() {
  if avail "$RESTIC_STR"; then dbk_add_check "①restic 在位($RESTIC_STR)"
  else ISSUES+=("①缺少 restic:备份链路跑不通(按 05-22 经 brew 通道装,或先跑 install-apps.sh --apply --yes)"); fi
  if avail "$RCLONE_STR"; then dbk_add_check "②rclone 在位($RCLONE_STR)"
  else MANUAL+=("②缺少 rclone:本机 baseline/ 快照不需要它,只有同步到服务器 62.234.211.51 时才要(按 05-22 装)"); fi
}
check_config() {
  if [ -n "$REPO" ]; then dbk_add_check "③RESTIC_REPOSITORY 已配置"
  else ISSUES+=("③RESTIC_REPOSITORY 未配置:不知道备份仓库在哪(按 05-22 配环境变量或本地凭据文件;凭据不进仓库)"); fi
  local src; src="$(pw_source)"
  if [ -n "$src" ]; then dbk_add_check "④密码来源可读:$src"
  else ISSUES+=("④没有可读的密码来源:设 RESTIC_PASSWORD 或把密码放进 600 的 RESTIC_PASSWORD_FILE(脚本绝不代写凭据)"); fi
}
check_recent() {
  local out st=0 t te age
  if [ "${#ISSUES[@]}" -gt 0 ]; then MANUAL+=("⑤仓库/凭据未就绪,跳过「最近快照」判定"); return 0; fi
  out="$(command "${RESTIC[@]}" snapshots --latest 1 --json 2>&1)" || st=$?
  if [ "$st" -ne 0 ]; then ISSUES+=("⑤读不到快照(restic snapshots 退出码 $st):$(first "$out")"); return 0; fi
  t="$(printf '%s' "$out" | grep -o '"time":"[^"]*"' | head -n1 | cut -d'"' -f4)"
  if [ -z "$t" ]; then ISSUES+=("⑤仓库里没有任何快照:备份链路还没跑通过一次(--apply 会跑)"); return 0; fi
  te="$(date -d "$t" +%s 2>/dev/null || true)"
  if [ -z "$te" ]; then MANUAL+=("⑤无法解析快照时间 '$t';请人工确认快照新鲜度"); return 0; fi
  age=$(( $(now) - te ))
  if [ "$age" -gt $((DAYS * 86400)) ]; then ISSUES+=("⑤最近一次快照已过期(早于 ${DAYS} 天:$t):按 05-22 重跑备份")
  else dbk_add_check "⑤最近一次快照在期内($t;期限 ${DAYS} 天)"; fi
}
check_all() { ISSUES=(); MANUAL=(); check_tools; check_config; check_recent; return 0; }

EXTRA_ISSUES=(); EXTRA_MANUAL=()
write_manifests() {
  mkdir -p "$MFDIR" || { EXTRA_ISSUES+=("无法创建清单目录 $MFDIR"); return 0; }
  if flatpak_list >"$MFDIR/flatpak-apps.txt" 2>/dev/null; then dbk_add_action "写出 Flatpak 清单:$MFDIR/flatpak-apps.txt"
  else EXTRA_MANUAL+=("未取到 Flatpak 清单(见 05-19/05-21),本次备份不含它"); fi
  local st=0; brew_bundle_dump "$MFDIR/brew-bundle.txt" || st=$?
  case "$st" in
    0) dbk_add_action "写出 Homebrew 清单:$MFDIR/brew-bundle.txt" ;;
    9) dbk_add_action "DBK_SKIP_PKG=1:跳过 Homebrew 清单" ;;
    2) EXTRA_MANUAL+=("Homebrew 清单需人工(brew 不可用;见 05-21)") ;;
    *) EXTRA_ISSUES+=("Homebrew 清单写出失败(原因见日志)") ;;
  esac
  if command "$OSTREE_STR" admin config-diff >"$MFDIR/etc-config-diff.txt" 2>/dev/null; then dbk_add_action "写出 /etc 漂移快照:$MFDIR/etc-config-diff.txt"
  else EXTRA_MANUAL+=("/etc 漂移快照取不到(ostree admin config-diff 不可用);本次备份只含文档目录与清单"); fi
}
restic_backup() {
  local st=0 out paths=()
  if [ -d "$DOCS" ]; then paths+=("$DOCS"); fi
  if [ -d "$ETC" ]; then paths+=("$ETC"); fi
  paths+=("$MFDIR")
  out="$(command "${RESTIC[@]}" backup --tag dbk "${paths[@]}" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then dbk_add_action "restic backup --tag dbk(对象:${paths[*]})"; dbk_mark_changed
  else EXTRA_ISSUES+=("restic backup 失败(退出码 $st):$(first "$out")"); fi
  st=0
  out="$(command "${RESTIC[@]}" forget --keep-last "$KEEP" --prune 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then dbk_add_action "保留策略:restic forget --keep-last $KEEP --prune"; dbk_mark_changed
  else EXTRA_ISSUES+=("restic forget 失败(退出码 $st):$(first "$out")"); fi
}
apply_run() {
  if [ "$(id -u)" -ne 0 ]; then dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; fi
  if ! avail "$RESTIC_STR"; then EXTRA_ISSUES+=("restic 不在位,--apply 无法执行(先按 05-22 装)"); return 0; fi
  if [ -z "$REPO" ] || [ -z "$(pw_source)" ]; then EXTRA_MANUAL+=("仓库或凭据未配置,--apply 未执行(脚本绝不代写凭据)"); return 0; fi
  write_manifests
  restic_backup
  return 0
}

finish() {
  local msg="${1:-}" m
  ISSUES+=(${EXTRA_ISSUES[@]+"${EXTRA_ISSUES[@]}"})
  MANUAL+=(${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"})
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks,修好后重跑本脚本"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:备份链路可跑通(restic/rclone 在位、仓库与凭据可读、最近快照在期内)"
}
if [ "$DBK_MODE" = apply ]; then
  apply_run
  check_all
  finish "--apply 已执行(生成清单 + restic backup + 保留策略;复读判据后判定)"
fi
check_all
if [ -n "$(pw_source)" ]; then dbk_add_check "记录项: 密码来源已读取,脚本不打印任何密码内容"; fi
finish "--check 零写判定完成"
