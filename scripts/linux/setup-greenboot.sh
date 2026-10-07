#!/usr/bin/env bash
# 对应卡:05-9
# 破坏性:1
# greenboot(启动失败自动回滚)的健康检查安装与核对(卡 05-9;设计 02 第 4 节 F10、设计 06 第 2 节 D4)。
# --check(零写):
#   ① `rpm -q greenboot` 是否预装(缺 -> 需人工 2,并给两条路:分层安装 / 用 systemd 单元 + ostree 回滚钩子);
#   ② /etc/greenboot/check/required.d/60-dbk-health.sh 是否在位且与"注入后的模板"逐字一致(不一致 -> 2 并报差异行)。
# --apply --yes:写/覆盖该健康检查(内容来自 templates/greenboot-health.snippet,单一真源;@DBK_LINUX_DIR@ 注入为
#   脚本所在目录);**不自动装 greenboot**,除非显式 --install-greenboot(那时才经 dbk-pkg.sh 分层安装,仍需 --yes)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: setup-greenboot.sh [--check|--apply] [--install-greenboot] [--dry-run] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 注入(夹具用):DBK_GREENBOOT_DIR / DBK_GREENBOOT_TPL / DBK_RPM / DBK_LINUX_DIR;DBK_RPM_OSTREE 透传给 dbk-pkg.sh。
# 待核实(以官方文档为准):greenboot 的 required.d 目录与 rpm 包名、检查脚本的退出语义(非零 -> 回滚)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"

INSTALL_REQ=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-greenboot) INSTALL_REQ=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "setup-greenboot"
dbk_enable_errtrap

GB_DIR="${DBK_GREENBOOT_DIR:-/etc/greenboot}"
TARGET="$GB_DIR/check/required.d/60-dbk-health.sh"
TPL="${DBK_GREENBOOT_TPL:-$ROOT/templates/greenboot-health.snippet}"
RPM_CMD="${DBK_RPM:-rpm}"
LINUX_DIR="${DBK_LINUX_DIR:-$HERE}"
GUIDE="两条路:① 分层安装(经 dbk-pkg.sh 的 pkg_ensure greenboot,重启后生效);② 不装 greenboot,改用 systemd 单元 + ostree 回滚钩子自建启动失败计数。"

# 渲染并确保 LF:模板若被 CRLF 化(Windows 检出),装到 /etc 后 shebang 会变成 bad interpreter。
render_tpl() { sed -e "s|@DBK_LINUX_DIR@|$LINUX_DIR|g" -e 's/\r$//' "$TPL"; }
rpm_installed() { command "$RPM_CMD" -q greenboot >/dev/null 2>&1; }

ISSUES=(); MANUAL=(); EXTRA_MANUAL=()   # EXTRA_MANUAL:--apply 路径产生的"需人工"项(judge 会重置 MANUAL,不清空它)
judge() {
  local d
  ISSUES=(); MANUAL=()
  if [ ! -r "$TPL" ]; then ISSUES+=("模板 $TPL 不存在或不可读:无法核对健康检查(单一真源缺失)"); return 0; fi
  if rpm_installed; then dbk_add_check "①greenboot 已预装($RPM_CMD -q greenboot)"
  else MANUAL+=("①greenboot 未预装:$GUIDE"); fi
  if [ ! -e "$TARGET" ]; then MANUAL+=("②$TARGET 不在位:--apply --yes 会按模板写入")
  else
    d="$(diff -u <(render_tpl) "$TARGET" 2>&1 || true)"
    if [ -z "$d" ]; then dbk_add_check "②$TARGET 在位且与注入后的模板逐字一致"
    else MANUAL+=("②$TARGET 与模板不一致(差异片段): $(printf '%s' "$d" | head -n 6 | tr '\n' ' ')"); fi
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项硬判据不满足;逐条见 checks"; fi
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  for m in ${EXTRA_MANUAL[@]+"${EXTRA_MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ $(( ${#MANUAL[@]} + ${#EXTRA_MANUAL[@]} )) -gt 0 ]; then dbk_exit 需人工 "$msg:有 $(( ${#MANUAL[@]} + ${#EXTRA_MANUAL[@]} )) 项脚本判不了;逐条见 checks,请人工确认"; fi
  dbk_exit PASS "$msg:greenboot 已预装且健康检查与模板逐字一致"
}

if [ "$DBK_MODE" = apply ]; then
  [ "$(id -u)" -eq 0 ] || { dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes"; }
  [ -r "$TPL" ] || { dbk_add_check "模板 $TPL 不存在或不可读"; dbk_exit FAIL "模板缺失(--template 不可读),没有可写入的健康检查内容"; }
  dbk_need_yes "写 greenboot 健康检查 $TARGET" "按 $TPL 渲染后写入 $TARGET"
  mkdir -p "$(dirname "$TARGET")"
  render_tpl >"$TARGET"
  dbk_add_action "已写入 $TARGET(来自 $TPL;注入 DBK_LINUX_DIR=$LINUX_DIR)"; dbk_mark_changed
  if [ "$INSTALL_REQ" -eq 1 ]; then
    dbk_need_yes "分层安装 greenboot(经 dbk-pkg.sh,重启后生效)" "pkg_ensure greenboot"
    st=0; pkg_ensure greenboot || st=$?
    case "$st" in
      0) dbk_add_action "greenboot 已提交分层安装(重启后生效)"; dbk_mark_changed ;;
      2) EXTRA_MANUAL+=("greenboot 分层安装需人工(pkg_ensure 返回 2;--now 语义不支持):$GUIDE") ;;
      9) dbk_add_check "记录项:greenboot 分层安装被 DBK_SKIP_PKG 跳过(--install-greenboot 未生效;与其它脚本的 9 = 跳过同口径)" ;;
      *) dbk_exit FAIL "greenboot 分层安装失败(见上面库层输出);健康检查已写入,装好 greenboot 后重跑 --check" ;;
    esac
  fi
  judge
  finish "greenboot 健康检查已落地(--apply 已执行)"
fi

if [ "$INSTALL_REQ" -eq 1 ]; then dbk_note "说明: --install-greenboot 只在 --apply 路径生效;本次是 --check,不装包。"; fi
judge
finish "greenboot 判据核对完成(--check 零写)"
