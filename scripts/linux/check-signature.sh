#!/usr/bin/env bash
# 对应卡:07-7
# 卡 07-7「周期巡检」的模块签名部分:判定 NVIDIA 模块签名与 MOK 注册状态(只读 —— 不注册密钥、不改 Secure Boot)。
# 判据:modinfo -F signer nvidia(模块未加载/未安装不算失败,分别给结论)+ mokutil --list-enrolled;lsmod 只用来区分
#   「未加载」与「未安装」,缺 lsmod 只记需人工,不影响结论。卡 07-7 的部署列表与 pin 部分由 dbk-rollback.sh --check 承担。
# 只读保证:本脚本没有任何写动作,--apply 与 --check 输出完全相同。
# 退出码:0 = 已签名且已注册(打印签名者与已注册密钥条数);1 = 命令存在但输出异常(逐条失败项);
#   2 = 需人工(未签名 / 未加载 / 未安装 / MOK 未注册),附补救指引:按 L4 卡 05-3 -> ujust enroll-secure-boot-key +
#       重启后在 MOK 管理界面注册,**不要关闭 Secure Boot**;9 = 非 Linux 或命令缺失。
# 注入钩子(真机留空;夹具用。取值 = 命令名/可带参数的命令行(由夹具注入假命令),或一个存在的文件路径(回放该文件)):
#   DBK_MODINFO / DBK_MOKUTIL / DBK_LSMOD / DBK_UNAME
# 待核实(以官方文档为准):modinfo -F signer 与 mokutil --list-enrolled 的输出格式(密钥条数行、未签名时的报错文本)
#   均未在真机验证;本脚本对"未签名"与"未安装"的区分依赖 modinfo 的报错文本。
# 夹具级验证,真机未跑。用法: check-signature.sh [--check|--apply] [--json] [--log <路径>] [--step NN-K]
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
count_of() { printf '%s\n' "${1:-}" | grep -cE "${2:-}" || true; }
GUIDE="补救指引:按 L4 卡 05-3(显卡驱动与 MOK)先确认已 rebase 到 ublue NVIDIA 变体,执行 ujust enroll-secure-boot-key,重启后在 MOK 管理界面完成注册;不要关闭 Secure Boot。"

# 0) 环境与命令可用性(非 Linux 或命令缺失 → 9)
run_hook "${DBK_UNAME:-uname -s}"; UNAME_OUT="$(first_line "$HOOK_OUT")"
case "$UNAME_OUT" in
  Linux*) ;;
  *) dbk_add_check "环境: 当前不是 Linux(uname 输出 '$UNAME_OUT')"
     dbk_exit 跳过 "跳过:本脚本只在 Linux(Silverblue)上可用(uname 输出 '$UNAME_OUT');Windows 侧巡检见 07-7 的 verify-baseline.ps1" ;;
esac
MISSING=""
hook_avail "$MO_HOOK" || MISSING="$MISSING modinfo"
hook_avail "$MK_HOOK" || MISSING="$MISSING mokutil"
if [ -n "$MISSING" ]; then
  dbk_add_check "环境: 命令缺失:$MISSING"
  dbk_exit 跳过 "跳过:缺少命令$MISSING,无法判定签名与 MOK 注册(mokutil 走 sudo rpm-ostree install mokutil? 按发行版实际包名安装后重跑)"
fi

# 1) 模块签名:modinfo -F signer nvidia(未加载/未安装分别给结论,不算失败但需人工确认)
run_hook "$MO_HOOK" -F signer nvidia; SIG_OUT="$HOOK_OUT"; SIG_RC="$HOOK_RC"
SIG_LINE="$(printf '%s\n' "$SIG_OUT" | grep -vE '^[[:space:]]*(modinfo|ERROR|警告)' | grep -v '^[[:space:]]*$' | head -n1 || true)"
run_hook "$LS_HOOK"; LSMOD_OUT="$HOOK_OUT"
if printf '%s\n' "$LSMOD_OUT" | grep -qE '^nvidia'; then LOADED=1; else LOADED=0; fi
if ! hook_avail "$LS_HOOK"; then dbk_add_check "需人工: 未找到 $LS_HOOK(无法区分模块未加载与未安装;结论以 modinfo 为准)"; fi

# 2) MOK 注册:mokutil --list-enrolled
run_hook "$MK_HOOK" --list-enrolled; MOK_OUT="$HOOK_OUT"; MOK_RC="$HOOK_RC"
MOK_N="$(count_of "$MOK_OUT" '^\[key [0-9]+\]')"
if [ "$MOK_N" -eq 0 ]; then MOK_N="$(count_of "$MOK_OUT" '^SHA1 Fingerprint:')"; fi
MOK_LINES="$(count_of "$MOK_OUT" '[^[:space:]]')"

# 3) 判定
if [ -z "$SIG_LINE" ]; then
  if printf '%s' "$SIG_OUT" | grep -qiE 'not found|找不到'; then
    dbk_add_check "签名: nvidia 模块未安装(modinfo 退出码 $SIG_RC: $(first_line "$SIG_OUT"))"
    dbk_exit 需人工 "nvidia 模块未安装:若本机应使用 NVIDIA 显卡,说明未 rebase 到 ublue NVIDIA 变体或模块未随内核构建;$GUIDE"
  elif printf '%s' "$SIG_OUT" | grep -qiE 'signer field|does not have|没有.*签'; then
    dbk_add_check "签名: 模块在位但没有签名者字段未签名(modinfo 退出码 $SIG_RC: $(first_line "$SIG_OUT"))"
    dbk_exit 需人工 "NVIDIA 模块没有签名者字段(未签名,Secure Boot 下会被拒);$GUIDE"
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
if [ "$MOK_RC" -ne 0 ]; then
  dbk_add_check "失败项: mokutil --list-enrolled 失败(退出码 $MOK_RC: $(first_line "$MOK_OUT"))"
  dbk_exit FAIL "mokutil --list-enrolled 执行失败:无法核对 MOK 已注册密钥;$GUIDE"
fi
if [ "$MOK_LINES" -eq 0 ]; then
  dbk_add_check "MOK: mokutil --list-enrolled 为空(没有任何已登记密钥)"
  dbk_exit 需人工 "MOK 未注册任何密钥:Secure Boot 下签名的 nvidia 模块也会被拒;$GUIDE"
fi
if [ "$MOK_N" -gt 0 ]; then dbk_add_check "MOK: 已注册密钥 $MOK_N 条(mokutil --list-enrolled)"; else dbk_add_check "MOK: mokutil --list-enrolled 非空但解析不到条数标记,按已注册处理($MOK_LINES 行)"; fi
dbk_exit PASS "签名与 MOK 通过:签名者=$SIG_LINE;已注册密钥 ${MOK_N:-?} 条(07-7 的部署列表与 pin 见 dbk-rollback.sh --check)"
