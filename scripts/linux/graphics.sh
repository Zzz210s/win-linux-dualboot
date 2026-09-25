#!/usr/bin/env bash
# 对应卡:05-3
# 破坏性:1
# L4:显卡与 Secure Boot(原子版;设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D3 与第 3 节 dbk-driver.sh 行;
#   判据取自 docs/design/02-fedora-atomic-variant-design.md 第 3 节 D2 的「看到:」四项)。
# 用途:--check 只读判定驱动栈是否已就绪(① nvidia 模块签名者非空 ② MOK 已注册 ublue 密钥 ③ nvidia 模块已加载 ④ 会话为 wayland);
#   --apply(需 root 且需 --yes)调接口 driver_rebase,把系统 rebase 到 ublue 的 NVIDIA 变体(镜像内模块已预签名),重启后生效。
# 判据(--check,零写):① `modinfo -F signer nvidia` 非空;② `mokutil --list-enrolled` 含 ublue 密钥;③ `lsmod` 有 nvidia;
#   ④ `XDG_SESSION_TYPE=wayland`。①②③ 由 dbk-driver.sh 的 driver_check 一次聚合判定(0 就绪 / 1 未完成 / 2 读不到),
#   逐条证据另用同源只读函数 driver_signer / mok_check / driver_module_state 亮出来给人看(只读,不参与判定)。
#   口径(与 set-updates.sh 一致):② 未注册 → 失败(1);①②③ 任一条读不到 → 需人工(2),绝不当作没问题;④ 取不到 → 需人工,非 wayland → 失败。
# 与旧(Kubuntu)口径的差别(不可改):驱动走 ublue 镜像内**已预签名**的模块(Ubuntu 官方的 ubuntu-drivers 预签名包路径已废弃);
#   本步不关 Secure Boot、不自签密钥(自签反而会破坏上游的预签名路径)。签名细查见 07-7 的 check-signature.sh。
# MOK 注册必须人工完成(接口不代跑):--apply 只提交 rebase;重启进 MOK 界面完成一次性注册(密码见下),会话内执行
#   `ujust enroll-secure-boot-key`,再次重启后重跑本脚本复核。
# nouveau 兜底(设计 02 第 7 节):桌面起不来时不要长按电源 —— 用 07-2 从 GRUB 提示符回 Windows,或按 05-9 回滚到 stock 部署
#   (回滚后由 nouveau 起桌面);接口 driver_fallback_nouveau 打印同一套步骤。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误(脚本头声明了破坏性,--apply 缺 --yes 由库层拒且零写)。
# 用法: graphics.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step 05-3] [-h]
# 注入(夹具用):DBK_MOKUTIL / DBK_MODINFO / DBK_LSMOD / DBK_RPM_OSTREE / DBK_UBLUE_IMAGE 与 XDG_SESSION_TYPE,
#   全部透传给 dbk-driver.sh;本脚本不写发行版命令字面量(规则 S-1)。
# 待核实(以官方文档为准):ublue 实际镜像名与分支;MOK 注册任务名 enroll-secure-boot-key 与 MOK 密码 universalblue;
#   modinfo -F signer / mokutil --list-enrolled 的输出格式。夹具级验证,真机未跑。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-driver.sh disable=SC1091
. "$HERE/dbk-driver.sh"
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)。
log() { dbk_obs "$*"; }
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "graphics"

ISSUES=(); MANUAL=()
# 待核实(以官方文档为准):MOK 注册任务名 enroll-secure-boot-key 与 MOK 密码 universalblue(设计 02 第 3 节 D2)。
MOK_HOWTO="重启进 MOK 界面完成一次性密钥注册(会话内先执行 ujust enroll-secure-boot-key,MOK 密码 universalblue,待核实)"

# ①②③ 的逐条证据(只读;判定已由 driver_check 给出,这里只把值亮出来)——每条都带实际取到的值。
evidence_lines() {
  local out rc=0
  out="$(driver_signer)" || rc=$?
  case "$rc" in
    0) dbk_add_check "①nvidia 模块签名者(modinfo -F signer nvidia):$out" ;;
    2) dbk_add_check "①nvidia 模块签名者(modinfo -F signer nvidia):读不到(需人工;原因见上面接口输出)" ;;
    *) dbk_add_check "①nvidia 模块签名者(modinfo -F signer nvidia):返回未知状态码 $rc" ;;
  esac
  rc=0; mok_check >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) dbk_add_check "②MOK 注册(mokutil --list-enrolled):ublue 密钥已注册" ;;
    1) dbk_add_check "②MOK 注册(mokutil --list-enrolled):未注册 ublue 密钥($MOK_HOWTO)" ;;
    2) dbk_add_check "②MOK 注册(mokutil --list-enrolled):读不到(需人工)" ;;
    *) dbk_add_check "②MOK 注册(mokutil --list-enrolled):返回未知状态码 $rc" ;;
  esac
  rc=0; out="$(driver_module_state)" || rc=$?
  case "$rc" in
    0) dbk_add_check "③nvidia 模块已加载(lsmod):$out" ;;
    1) dbk_add_check "③nvidia 模块未加载(lsmod):$out(未重启 / MOK 未注册 / 已回退到 nouveau;按上面两条与接口输出收敛)" ;;
    2) dbk_add_check "③模块加载状态读不到(lsmod):需人工" ;;
    *) dbk_add_check "③模块加载状态(lsmod):返回未知状态码 $rc" ;;
  esac
}

# ④ 会话类型:wayland 是设计 01/00 的收敛目标;取不到 → 需人工(可在桌面会话内重跑),其它值 → 失败。
check_session() {
  case "${XDG_SESSION_TYPE:-}" in
    wayland) dbk_add_check "④XDG_SESSION_TYPE=wayland" ;;
    "") MANUAL+=("④取不到 XDG_SESSION_TYPE(登录桌面后在会话内重跑;期望 wayland)") ;;
    *) ISSUES+=("④XDG_SESSION_TYPE=$XDG_SESSION_TYPE:期望 wayland;先查驱动加载与内核行是否还有 nomodeset,再考虑重建会话") ;;
  esac
}

check_all() {
  local rc=0
  ISSUES=(); MANUAL=()
  # ①-③ 一次聚合判定(接口 driver_check);逐条原因由接口写 stderr 与 --log。
  driver_check || rc=$?
  evidence_lines
  case "$rc" in
    0) dbk_add_check "①-③显卡栈总判定:modinfo -F signer nvidia 非空 + mokutil --list-enrolled 含 ublue 密钥 + lsmod 有 nvidia" ;;
    1) ISSUES+=("①-③显卡栈未完成:nvidia 模块未加载或 ublue 密钥未注册;按上面逐条原因(未 rebase / 未重启 / 未注册 MOK)收敛后重跑") ;;
    2) MANUAL+=("①-③读不到显卡栈状态:modinfo / mokutil / lsmod 有一个取不到或输出判不了;请人工核对驱动来源与 Secure Boot 状态") ;;
    *) ISSUES+=("①-③显卡栈判定返回未知状态码 $rc") ;;
  esac
  check_session
  dbk_add_check "nouveau 兜底: 桌面起不来时用 07-2 从 GRUB 提示符回 Windows,或按 05-9 回滚到 stock 部署(回滚后由 nouveau 起桌面);绝不长按电源(用 REISUB/SysRq)"
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:驱动栈已就绪(ublue 预签名模块 + MOK 已注册 + nvidia 已加载 + 会话为 wayland)"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  check_all
  if [ "${#ISSUES[@]}" -eq 0 ] && [ "${#MANUAL[@]}" -eq 0 ]; then
    dbk_exit PASS "显卡栈已就绪:无需再 rebase(--apply 幂等);要复核对齐请只跑 --check"
  fi
  dbk_need_yes "rebase 到 ublue 的 NVIDIA 变体(镜像内模块已预签名;重启后生效)" "$REBASE_CMD rebase $UBLUE_IMAGE"
  if driver_rebase; then
    dbk_add_action "driver_rebase(已 rebase 到 $UBLUE_IMAGE)"
    dbk_mark_changed
  else
    dbk_add_check "失败项: driver_rebase 失败(原因见上面接口输出)"
    dbk_exit FAIL "rebase 未执行成功:按上面原因处理后重跑(幂等);要退回 stock 部署按 driver_fallback_nouveau 的步骤走"
  fi
  dbk_add_check "下一步(必须人工): $MOK_HOWTO;再次重启后重跑本脚本复核"
  check_all
  finish "已 rebase 到 ublue 的 NVIDIA 变体(--apply 已提交:重启并完成 MOK 注册后再复核)"
fi

check_all
finish "显卡栈判据核对完成(--check 零写,未改动任何系统状态)"
