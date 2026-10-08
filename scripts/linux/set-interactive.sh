#!/usr/bin/env bash
# 对应卡:05-14
# 破坏性:1(--apply 会写 /etc/shells 并 chsh 改登录 shell;必须显式 --yes)
# L4 交互层:交互 shell 用 fish(走 ublue 自带的 Homebrew 通道,不做系统级 layering 分层),
#   同时显式保持脚本解释器仍是 bash(shebang 与 /bin/sh 一律不动)。
# 判据(--check,零写)五项:① brew 可用(否 → 需人工;它由镜像自带,缺失先按 05-14 手工装,本脚本不自动装);
#   ② fish 在位(command -v fish,或 --fish/DBK_FISH 给定);③ 该用户登录 shell 已是 fish
#   (读 DBK_PASSWD,缺省 /etc/passwd 第 7 字段;取不到该用户行 → 2);④ DBK_SHELLS(缺省 /etc/shells)
#   含 fish 路径(缺 → 1;文件不可读 → 2);⑤ DBK_SH_LINK(缺省 /bin/sh)的 readlink -f 末尾不是 fish(是 → 1)。
# --apply(需 root,必须 --yes):① 备份 /etc/shells -> .dbk.bak(仅首次);② 追加 fish 路径(幂等,已有不追加);
#   ③ DBK_CHSH(缺省 chsh)-s <fish> <user>;④ --install-fish 时经 dbk-brew.sh 安装 fish
#   (返回 2 记需人工 / 9 记跳过 / 1 记失败);⑤ 复读五项。缺 --yes → 64 零写(由库层在解析参数时拦截)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: set-interactive.sh [--check|--apply --yes] [--user <名字>] [--fish <绝对路径>] [--install-fish]
#   [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用,真机不需要设置):DBK_BREW / DBK_FISH / DBK_PASSWD / DBK_SHELLS / DBK_SH_LINK / DBK_CHSH。
# 夹具级验证,真机未跑。待核实(以 ublue 官方文档为准):镜像自带 fish 的路径(缺省 /home/linuxbrew/.linuxbrew/bin/fish)
#   与 chsh 在原子版镜像上的行为;由 sudo 执行时的目标用户图形会话上下文(见 05-14 坑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # 与其它步骤脚本统一脚本头(HERE/ROOT);本脚本不读仓库文件
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-brew.sh disable=SC1091
. "$HERE/dbk-brew.sh"

TARGET_USER="${SUDO_USER:-${USER:-}}"; FISH_OPT="${DBK_FISH:-}"; INSTALL_FISH=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) dbk_cli_val "--user" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --user=*) TARGET_USER="${1#*=}"; shift ;;
    --fish) dbk_cli_val "--fish" "${2:-}"; FISH_OPT="$2"; shift 2 ;;
    --fish=*) FISH_OPT="${1#*=}"; shift ;;
    --install-fish) INSTALL_FISH=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_enable_errtrap
dbk_log_default "set-interactive"

CHSH_STR="${DBK_CHSH:-chsh}"; CHSH=()
read -r -a CHSH <<<"$CHSH_STR"
chsh_run() { command "${CHSH[@]}" "$@"; }

FISH=""; LS_ERR=""
ISSUES=(); MANUAL=(); EXTRA_ISSUES=(); EXTRA_MANUAL=()

# 解析鱼路径:--fish/DBK_FISH 优先,否则 command -v fish;给定但不可执行则回退到按名字查;取不到 → 空。
resolve_fish() {
  local p="${FISH_OPT:-}"
  if [ -z "$p" ]; then
    if ! p="$(command -v fish 2>/dev/null)"; then p=""; fi
  elif [ ! -x "$p" ]; then
    if ! p="$(command -v "$p" 2>/dev/null)"; then p=""; fi
  fi
  printf '%s' "$p"
}

# 读该用户登录 shell(第 7 字段);打印 shell 并返回 0;读不到文件或无该用户 → 返回 2,原因写进 LS_ERR。
login_shell_of() {
  local u="${1:-}" f="${DBK_PASSWD:-/etc/passwd}" s=""
  if [ ! -r "$f" ]; then LS_ERR="读不到 $f"; return 2; fi
  s="$(awk -F: -v u="$u" '$1==u {print $7; exit}' "$f")"
  if [ -z "$s" ]; then LS_ERR="$f 里没有用户 '$u'"; return 2; fi
  printf '%s' "$s"
  return 0
}

check_brew() {
  local rc=0
  brew_avail || rc=$?
  if [ "$rc" -eq 0 ]; then dbk_add_check "① brew 可用(${DBK_BREW:-brew})"
  else MANUAL+=("① brew 不可用:它由 ublue 镜像自带,缺失就先按 05-14 手工装(本脚本不自动装 brew)"); fi
}

check_fish() {
  FISH="$(resolve_fish)"
  if [ -n "$FISH" ]; then dbk_add_check "② fish 在位:$FISH"
  else MANUAL+=("② 未找到 fish:--apply --install-fish --yes 可经 brew 通道装,或用 --fish <绝对路径> 指定(缺省 /home/linuxbrew/.linuxbrew/bin/fish)"); fi
}

check_login() {
  local got="" rc=0
  if [ -z "$FISH" ]; then MANUAL+=("③ fish 不在位,无法判定登录 shell"); return 0; fi
  got="$(login_shell_of "$TARGET_USER")" || rc=$?
  if [ "$rc" -ne 0 ]; then MANUAL+=("③ 取不到用户 '$TARGET_USER' 的登录 shell:$LS_ERR"); return 0; fi
  if [ "$got" = "$FISH" ]; then dbk_add_check "③ $TARGET_USER 登录 shell 已是 fish($got)"
  else ISSUES+=("③ $TARGET_USER 登录 shell 是 $got,应为 $FISH:chsh 未执行或未生效(--apply --yes 会改)"); fi
}

check_shells() {
  local f="${DBK_SHELLS:-/etc/shells}"
  if [ -z "$FISH" ]; then MANUAL+=("④ fish 不在位,无法核对 $f"); return 0; fi
  if [ ! -r "$f" ]; then MANUAL+=("④ 读不到 $f:请人工确认其中是否含 $FISH"); return 0; fi
  if grep -qxF -- "$FISH" "$f"; then dbk_add_check "④ $f 含 fish 路径($FISH)"
  else ISSUES+=("④ $f 不含 $FISH:chsh 只认 $f 里的路径,--apply 会追加(幂等)"); fi
}

check_sh() {
  local link="${DBK_SH_LINK:-/bin/sh}" real="" rc=0
  real="$(readlink -f -- "$link" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$real" ]; then
    MANUAL+=("⑤ 无法解析 $link:请人工确认它未指向 fish"); return 0
  fi
  case "${real##*/}" in
    fish*) ISSUES+=("⑤ $link 解析为 $real:脚本解释器被换成了 fish,必须改回 POSIX shell(bash/dash)") ;;
    *) dbk_add_check "⑤ $link 未指向 fish(解析为 $real)" ;;
  esac
}

check_all() {
  ISSUES=(); MANUAL=()
  check_brew; check_fish; check_login; check_shells; check_sh
  return 0
}

backup_shells() {
  local f="${DBK_SHELLS:-/etc/shells}"
  if [ -e "$f.dbk.bak" ]; then dbk_add_action "备份已存在,保留不覆盖:$f.dbk.bak"; return 0; fi
  if [ ! -e "$f" ]; then EXTRA_MANUAL+=("$f 不存在,未做备份(--apply 会新建)"); return 0; fi
  if cp -a "$f" "$f.dbk.bak"; then dbk_add_action "备份 $f -> $f.dbk.bak(仅首次)"; dbk_mark_changed
  else EXTRA_ISSUES+=("备份失败:$f -> $f.dbk.bak"); fi
}

append_shells() {
  local f="${DBK_SHELLS:-/etc/shells}"
  if grep -qxF -- "$FISH" "$f" 2>/dev/null; then dbk_add_action "$f 已含 $FISH,未追加(幂等)"; return 0; fi
  if printf '%s\n' "$FISH" >>"$f"; then dbk_add_action "追加 $FISH 到 $f"; dbk_mark_changed
  else EXTRA_ISSUES+=("追加 $FISH 到 $f 失败"); fi
}

install_fish() {
  local st=0
  brew_install fish || st=$?
  case "$st" in
    0) dbk_add_action "经 dbk-brew.sh 安装 fish(brew 通道)" ;;
    9) dbk_add_check "记录项: DBK_SKIP_PKG=1,跳过 fish 安装" ;;
    2) EXTRA_MANUAL+=("经 brew 通道装 fish 需人工:原因见日志;手工装好 fish 后重跑") ;;
    *) EXTRA_ISSUES+=("经 brew 通道装 fish 失败:原因见日志;手工装好 fish 后重跑") ;;
  esac
}

run_chsh() {
  local out="" st=0
  out="$(chsh_run -s "$FISH" "$TARGET_USER" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then dbk_add_action "${CHSH_STR} -s $FISH $TARGET_USER"; dbk_mark_changed
  else EXTRA_ISSUES+=("${CHSH_STR} -s $FISH $TARGET_USER 失败:$(printf '%s' "$out" | head -n1)"); fi
}

apply_run() {
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  if [ "$INSTALL_FISH" -eq 1 ]; then install_fish; fi
  FISH="$(resolve_fish)"
  if [ -z "$FISH" ]; then EXTRA_MANUAL+=("fish 仍不在位:未追加 /etc/shells、未 chsh;装好 fish 后重跑(见 05-14)"); return 0; fi
  backup_shells
  append_shells
  run_chsh
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
  dbk_exit PASS "$msg:五项判据全部达成(brew 可用、fish 在位、登录 shell 与 /etc/shells 就位、/bin/sh 未指向 fish)"
}

if [ "$DBK_MODE" = apply ]; then
  apply_run
  check_all
  finish "交互层已执行(--apply;复读五项后判定)"
fi
check_all
finish "交互层判据核对完成(--check 零写)"
