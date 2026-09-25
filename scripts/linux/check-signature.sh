#!/usr/bin/env bash
# 对应卡:07-7
# 卡 07-7「周期巡检」的 Secure Boot 与密钥部分:判定 Secure Boot 开关与 ublue 密钥是否已注册(只读)。
# 原子版语义(设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D3):驱动走 ublue 镜像内**已预签名**的模块,
#   签名链现成 —— **不需要自签、不需要 MOK 注册脚本**(原 Kubuntu 时代的"Ubuntu 官方预签名包"口径
#   已随 2026-09-25 回切废弃,本脚本不再匹配 Ubuntu/Canonical 签名者)。密钥注册必须人工在 MOK 界面完成。
# 判据:① `mokutil --sb-state` 显示 Secure Boot enabled(disabled → 需人工:设计 D3 要求保持开启);
#   ② 经 dbk-driver.sh 的 mok_check:`mokutil --list-enrolled` 含 ublue 密钥(未注册 → 需人工;已注册 → 通过)。
#   模块签名者(签名是否来自 ublue 镜像)由 dbk-driver.sh 的 driver_signer 与 graphics.sh 的 driver_check 承担,
#   本脚本不重复判(卡 07-7 的其余巡检见 check-health.sh)。
# 只读保证:本脚本没有任何写动作,--apply 与 --check 输出完全相同(不注册密钥、不改固件)。
# 退出码:0 = Secure Boot enabled 且 ublue 密钥已注册;1 = mokutil --sb-state 执行失败(输出异常);
#   2 = 需人工(Secure Boot 关闭 / 密钥未注册 / 读不到);9 = 非 Linux 或缺少 mokutil。
# 注入钩子(真机留空;夹具用。取值 = 命令名/可带参数的命令行,或一个存在的文件路径(回放该文件)):
#   DBK_UNAME / DBK_MOKUTIL(dbk-driver.sh 的 mok_check 同源读取同一个注入值)。
# 本脚本不写发行版命令字面量(规则 S-1):密钥注册判定一律走 dbk-driver.sh 的接口。
# 待核实(以官方文档为准):mokutil --sb-state 与 --list-enrolled 的输出格式(状态串大小写、未注册时的文本)、
#   MOK 注册任务名 enroll-secure-boot-key 与 MOK 密码 universalblue —— 均未在真机验证。夹具级验证,真机未跑。
# 用法: check-signature.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-driver.sh disable=SC1091
. "$HERE/dbk-driver.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-signature"
dbk_enable_errtrap

MK_HOOK="${DBK_MOKUTIL:-mokutil}"
HOOK_OUT=""; HOOK_RC=0
hook_avail() { local spec="${1:-}" p=(); [ -e "$spec" ] && return 0; read -r -a p <<<"$spec"; command -v "${p[0]}" >/dev/null 2>&1; }
run_hook() {   # 执行钩子;结果放 HOOK_OUT/HOOK_RC(stderr 并入输出,不吞错);本函数始终返回 0
  local spec="${1:-}"; shift || true
  HOOK_OUT=""; HOOK_RC=0
  if [ -e "$spec" ]; then HOOK_OUT="$(cat -- "$spec" 2>&1)" || HOOK_RC=$?; return 0; fi
  local p=(); read -r -a p <<<"$spec"
  HOOK_OUT="$("${p[@]}" "$@" 2>&1)" || HOOK_RC=$?
  return 0
}
first_line() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 || true; }
GUIDE="补救指引:按 05-3 rebase 到 ublue 的 NVIDIA 变体后重启,进 MOK 界面执行一次 enroll-secure-boot-key(MOK 密码 universalblue,均待核实);接口不代跑。"

# 0) 环境与命令可用性(非 Linux 或命令缺失 → 9)
run_hook "${DBK_UNAME:-uname -s}"; UNAME_OUT="$(first_line "$HOOK_OUT")"
case "$UNAME_OUT" in
  Linux*) ;;
  *) dbk_add_check "环境: 当前不是 Linux(uname 输出 '$UNAME_OUT')"
     dbk_exit 跳过 "跳过:本脚本只在 Linux 侧可用(uname 输出 '$UNAME_OUT');Windows 侧巡检见 07-7 的 verify-baseline.ps1" ;;
esac
if ! hook_avail "$MK_HOOK"; then
  dbk_add_check "环境: 缺少命令 $MK_HOOK"
  dbk_exit 跳过 "跳过:缺少 $MK_HOOK,无法判定 Secure Boot 开关与密钥注册状态(按发行版实际包名安装后重跑)"
fi

MANUAL=()
# 1) Secure Boot 开关:mokutil --sb-state
run_hook "$MK_HOOK" --sb-state; SB_OUT="$HOOK_OUT"; SB_RC="$HOOK_RC"
SB_LINE="$(first_line "$SB_OUT")"
if [ "$SB_RC" -ne 0 ]; then
  dbk_add_check "失败项: mokutil --sb-state 失败(退出码 $SB_RC: $SB_LINE)"
  dbk_exit FAIL "mokutil --sb-state 执行失败:无法核对 Secure Boot 状态(需要 root?)"
fi
case "$SB_OUT" in
  *"SecureBoot enabled"*) dbk_add_check "①Secure Boot: enabled(设计 D3 要求保持开启)" ;;
  *"SecureBoot disabled"*) MANUAL+=("①Secure Boot: disabled —— 设计 D3 要求保持开启;请在固件设置里重新打开后重跑") ;;
  *) MANUAL+=("①mokutil --sb-state 输出无法识别($SB_LINE);请人工确认固件里的 Secure Boot 开关") ;;
esac

# 2) ublue 密钥注册(经 dbk-driver.sh 的 mok_check;读不到 → 2 需人工,绝不 fail-open 成"没问题")
MOK_RC=0
if mok_check; then MOK_RC=0; else MOK_RC=$?; fi
case "$MOK_RC" in
  0) dbk_add_check "②Secure Boot 密钥:ublue 已注册(经 dbk-driver.sh 的 mok_check)" ;;
  1) MANUAL+=("②Secure Boot 密钥:ublue 未注册;$GUIDE") ;;
  *) MANUAL+=("②Secure Boot 密钥:读不到已注册密钥(需人工;原因见上面 dbk-driver 的报错)") ;;
esac

if [ "${#MANUAL[@]}" -gt 0 ]; then
  for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
  dbk_exit 需人工 "Secure Boot 与密钥有 ${#MANUAL[@]} 项需要人工确认(不属于失败);逐条见 checks"
fi
dbk_exit PASS "Secure Boot 与密钥通过:Secure Boot enabled;ublue 密钥已注册(卡 07-7 的其余巡检见 check-health.sh)"
