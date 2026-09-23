#!/usr/bin/env bash
# 对应卡:07-7
# 卡 07-7「周期巡检」的模块签名部分:判定 NVIDIA 模块签名者与 Secure Boot 状态(只读 —— 不注册密钥、不改固件)。
# Kubuntu 语义(设计依据:docs/design/04-kubuntu-variant-design.md 第 2 节 D3):驱动走 Ubuntu 官方**预签名**包,
#   签名链现成 —— **不需要自签、不需要 MOK 注册**(原原子版的 `ujust enroll-secure-boot-key` 与
#   `mokutil --list-enrolled` 注册判据已随之删除)。未签名 / 未安装时一律指向卡 05-3 重新装官方驱动包。
# 判据:① `modinfo -F signer nvidia` 的签名者非空(取不到 → 需人工,分别说明"未安装"与"未签名");
#   ② `mokutil --sb-state` 显示 Secure Boot enabled(显示 disabled → 需人工:设计 D3 要求保持开启);
#   ③ lsmod 只用来区分「未加载」与「未安装」,缺 lsmod 只记需人工,不影响结论。
# 只读保证:本脚本没有任何写动作,--apply 与 --check 输出完全相同。
# 退出码:0 = 签名者非空且 Secure Boot 开启;1 = 命令存在但输出异常(逐条失败项);
#   2 = 需人工(未签名 / 未加载 / 未安装 / Secure Boot 关闭),补救指引见卡 05-3;9 = 非 Linux 或命令缺失。
# 注入钩子(真机留空;夹具用。取值 = 命令名/可带参数的命令行(由夹具注入假命令),或一个存在的文件路径(回放该文件)):
#   DBK_MODINFO / DBK_MOKUTIL / DBK_LSMOD / DBK_UNAME
# 待核实(以官方文档为准):modinfo -F signer 与 mokutil --sb-state 的输出格式(未签名时的报错文本、
#   Secure Boot 状态串的大小写)均未在真机验证。夹具级验证,真机未跑。
# 用法: check-signature.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K] [-h]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-signature"
dbk_enable_errtrap

MO_HOOK="${DBK_MODINFO:-modinfo}"; MK_HOOK="${DBK_MOKUTIL:-mokutil}"; LS_HOOK="${DBK_LSMOD:-lsmod}"
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
GUIDE="补救指引:按卡 05-3 用 Ubuntu 官方预签名包重装驱动(sudo ubuntu-drivers install 或 apt-get install -y nvidia-driver-<版本>);官方包的模块自带签名者,不需要自签密钥,也不需要在 MOK 界面注册。"

# 0) 环境与命令可用性(非 Linux 或命令缺失 → 9)
run_hook "${DBK_UNAME:-uname -s}"; UNAME_OUT="$(first_line "$HOOK_OUT")"
case "$UNAME_OUT" in
  Linux*) ;;
  *) dbk_add_check "环境: 当前不是 Linux(uname 输出 '$UNAME_OUT')"
     dbk_exit 跳过 "跳过:本脚本只在 Linux(Kubuntu)上可用(uname 输出 '$UNAME_OUT');Windows 侧巡检见 07-7 的 verify-baseline.ps1" ;;
esac
MISSING=""
hook_avail "$MO_HOOK" || MISSING="$MISSING modinfo"
hook_avail "$MK_HOOK" || MISSING="$MISSING mokutil"
if [ -n "$MISSING" ]; then
  dbk_add_check "环境: 命令缺失:$MISSING"
  dbk_exit 跳过 "跳过:缺少命令$MISSING,无法判定签名与 Secure Boot 状态(按发行版实际包名安装 mokutil 后重跑)"
fi

# 1) 模块签名:modinfo -F signer nvidia(未加载/未安装分别给结论,不算失败但需人工确认)
run_hook "$MO_HOOK" -F signer nvidia; SIG_OUT="$HOOK_OUT"; SIG_RC="$HOOK_RC"
SIG_LINE="$(printf '%s\n' "$SIG_OUT" | grep -vE '^[[:space:]]*(modinfo|ERROR|警告)' | grep -v '^[[:space:]]*$' | head -n1 || true)"
run_hook "$LS_HOOK"; LSMOD_OUT="$HOOK_OUT"
if printf '%s\n' "$LSMOD_OUT" | grep -qE '^nvidia'; then LOADED=1; else LOADED=0; fi
if ! hook_avail "$LS_HOOK"; then dbk_add_check "需人工: 未找到 $LS_HOOK(无法区分模块未加载与未安装;结论以 modinfo 为准)"; fi

# 2) Secure Boot 状态:mokutil --sb-state
run_hook "$MK_HOOK" --sb-state; SB_OUT="$HOOK_OUT"; SB_RC="$HOOK_RC"
SB_LINE="$(first_line "$SB_OUT")"

# 3) 判定
if [ -z "$SIG_LINE" ]; then
  if printf '%s' "$SIG_OUT" | grep -qiE 'not found|找不到'; then
    dbk_add_check "签名: nvidia 模块未安装(modinfo 退出码 $SIG_RC: $(first_line "$SIG_OUT"))"
    dbk_exit 需人工 "nvidia 模块未安装:若本机应使用 NVIDIA 显卡,说明官方驱动包没装上;$GUIDE"
  elif printf '%s' "$SIG_OUT" | grep -qiE 'signer field|does not have|没有.*签'; then
    dbk_add_check "签名: 模块在位但没有签名者字段(未签名;modinfo 退出码 $SIG_RC: $(first_line "$SIG_OUT"))"
    dbk_exit 需人工 "NVIDIA 模块没有签名者字段(不是 Ubuntu 官方包,Secure Boot 下会被拒);$GUIDE"
  elif [ "$SIG_RC" -ne 0 ]; then
    dbk_add_check "失败项: modinfo -F signer nvidia 输出异常(退出码 $SIG_RC,无签名者也无 not found: $(first_line "$SIG_OUT"))"
    dbk_exit FAIL "modinfo 输出异常:无法判定签名状态;$GUIDE"
  elif [ "$LOADED" -eq 1 ]; then
    dbk_add_check "签名: 未取到签名者(lsmod 显示 nvidia 已加载 -> 模块未签名;modinfo 退出码 $SIG_RC)"
    dbk_exit 需人工 "NVIDIA 模块已加载但没有签名者字段(未签名,Secure Boot 下会被拒/已降级);$GUIDE"
  else
    dbk_add_check "签名: 未取到签名者(lsmod 无 nvidia 且 modinfo 退出码 0 -> 模块未加载)"
    dbk_exit 需人工 "nvidia 模块未加载:无独显或驱动未加载,签名判定以 modinfo 为准;$GUIDE"
  fi
fi
dbk_add_check "签名: 签名者=$SIG_LINE(modinfo 退出码 $SIG_RC)"
case "$SIG_LINE" in
  *Ubuntu*|*ubuntu*|*Canonical*|*canonical*|*NVIDIA*|*nvidia*) dbk_add_check "签名者含 Ubuntu/Canonical/NVIDIA 标识(官方包签名链)" ;;
  *) dbk_add_check "需人工: 签名者 '$SIG_LINE' 不是预期的 Ubuntu/Canonical/NVIDIA 标识;请人工确认驱动来源(卡 05-3)" ;;
esac
if [ "$SB_RC" -ne 0 ]; then
  dbk_add_check "失败项: mokutil --sb-state 失败(退出码 $SB_RC: $(first_line "$SB_OUT"))"
  dbk_exit FAIL "mokutil --sb-state 执行失败:无法核对 Secure Boot 状态(需要 root?)$GUIDE"
fi
case "$SB_OUT" in
  *"SecureBoot enabled"*) dbk_add_check "Secure Boot: enabled(设计 D3 要求保持开启)" ;;
  *"SecureBoot disabled"*) dbk_add_check "Secure Boot: disabled"
    dbk_exit 需人工 "Secure Boot 已关闭:设计 D3 要求保持开启(官方预签名驱动本就无需关它);请在固件设置里重新打开后重跑本脚本" ;;
  *) dbk_add_check "需人工: mokutil --sb-state 输出无法识别($SB_LINE)"
    dbk_exit 需人工 "取不到可识别的 Secure Boot 状态($SB_LINE);请人工确认固件里的 Secure Boot 开关" ;;
esac
dbk_exit PASS "签名与 Secure Boot 通过:签名者=$SIG_LINE;Secure Boot enabled(07-7 的其余巡检见 check-health.sh)"
