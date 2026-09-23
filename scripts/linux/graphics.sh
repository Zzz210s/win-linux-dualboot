#!/usr/bin/env bash
# 对应卡:05-3
# 破坏性:1
# L4:显卡栈收敛(Kubuntu 26.04 LTS / apt 语义;设计依据:docs/design/04-kubuntu-variant-design.md 第 2 节 D3
#   与第 1 节"省心"对照表:NVIDIA 走 Ubuntu 官方**预签名**包(ubuntu-drivers 安装),不需要 ublue rebase、
#   不需要 MOK 注册、不需要自签密钥)。
# 用途:--check 只读判定驱动来源/签名者/会话类型/PRIME offload;--apply(需 root 且需 --yes)执行
#   `ubuntu-drivers install`(装推荐驱动),装完复读判据。
# 判据(--check,零写):① `ubuntu-drivers devices` 可读并给出推荐驱动行(取不到 → 需人工);
#   ② `modinfo -F signer nvidia` 非空(官方包自带签名者;未装/未加载 → 需人工,不是失败);
#   ③ `nvidia-smi` 可执行(未装或未重启 → 需人工);④ `XDG_SESSION_TYPE=wayland`(取不到 → 需人工,其它 → 失败);
#   ⑤ PRIME offload:`xrandr --listproviders` 有 ≥2 个 provider(取不到 → 需人工)。
# 边界:本步不关 Secure Boot、不自签密钥、不注册 MOK;签名细查见 scripts/linux/check-signature.sh。
# 兜底(设计 04 第 7 节):nouveau 是天然回退点 —— 桌面起不来时用 07-2 从 GRUB 提示符回 Windows,或按 07-5 处置;
#   驱动不认时的顺序是"换更新内核 -> 换驱动版本(rollback-pkg.sh 降级 + hold) -> 才考虑发行版问题";
#   绝不长按电源(用 REISUB/SysRq)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: graphics.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step 05-3] [-h]
# 注入(夹具用):DBK_UBUNTU_DRIVERS / DBK_NVIDIA_SMI / DBK_MODINFO / DBK_LSMOD / DBK_LSPCI / DBK_XRANDR。
# 待核实(以官方文档为准):ubuntu-drivers devices/install 的输出格式与子命令名、xrandr --listproviders 的
#   provider 计数文本、modinfo 签名者在 Ubuntu 官方包下的实际取值,均未在真机验证。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "graphics"

UD_STR="${DBK_UBUNTU_DRIVERS:-ubuntu-drivers}"   # 待核实(以官方文档为准)
SMI_STR="${DBK_NVIDIA_SMI:-nvidia-smi}"
MO_STR="${DBK_MODINFO:-modinfo}"; LS_STR="${DBK_LSMOD:-lsmod}"
LSPCI_STR="${DBK_LSPCI:-lspci}"; XR_STR="${DBK_XRANDR:-xrandr}"
UD=(); SMI=(); MO=(); LS=(); LSPCI=(); XR=()
read -r -a UD <<<"$UD_STR"; read -r -a SMI <<<"$SMI_STR"; read -r -a MO <<<"$MO_STR"
read -r -a LS <<<"$LS_STR"; read -r -a LSPCI <<<"$LSPCI_STR"; read -r -a XR <<<"$XR_STR"
# 包装函数一律「名字不与外部命令同名 + 体内 command」双保险:函数查找优先于 PATH,同名(lspci)会无限递归。
ud() { command "${UD[@]}" "$@"; }
smi() { command "${SMI[@]}" "$@"; }
mo() { command "${MO[@]}" "$@"; }
lsm() { command "${LS[@]}" "$@"; }
lspci_() { command "${LSPCI[@]}" "$@"; }
xr() { command "${XR[@]}" "$@"; }

ISSUES=(); MANUAL=(); APPLY_FAILS=(); PROBE_OUT=""; PROBE_RC=0
probe() {   # 统一探针:stdout+stderr 收进 PROBE_OUT(不吞输出);PROBE_RC 分辨 127(缺命令)与执行失败
  local out
  if out="$("$@" 2>&1)"; then PROBE_RC=0; else PROBE_RC=$?; fi
  PROBE_OUT="$out"
  return 0
}

# 判据①:驱动来源与推荐驱动行(ubuntu-drivers devices)
check_source() {
  if ! command -v "${UD[0]}" >/dev/null 2>&1; then MANUAL+=("①未找到 ${UD[0]}:请人工跑 ubuntu-drivers devices 核对推荐驱动"); return 0; fi
  probe ud devices
  if [ -z "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    MANUAL+=("①ubuntu-drivers devices 无输出(无独显或受限环境);请人工确认显卡与驱动来源")
    return 0
  fi
  local rec; rec="$(printf '%s\n' "$PROBE_OUT" | grep -iE 'recommended' | head -n 2 | tr '\n' ';' | sed 's/;$//' || true)"
  dbk_add_check "①显卡驱动来源(ubuntu-drivers devices):${rec:-见原始输出,$(printf '%s\n' "$PROBE_OUT" | grep -ciE 'driver' || true) 行}"
}
# 判据②:nvidia 模块签名者(官方包自带签名)
check_signer() {
  if ! command -v "${MO[0]}" >/dev/null 2>&1; then MANUAL+=("②未找到 ${MO[0]}:无法核对 nvidia 模块签名者"); return 0; fi
  probe mo -F signer nvidia
  if [ -z "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    MANUAL+=("②modinfo -F signer nvidia 为空:模块未装或未加载(装完未重启时属正常,重启后重跑);细查见 check-signature.sh")
  else
    dbk_add_check "②nvidia 模块签名者:$(printf '%s' "$PROBE_OUT" | head -n1)"
  fi
}
# 判据③:nvidia-smi 可用(装完并能与驱动通信)
check_smi() {
  if ! command -v "${SMI[0]}" >/dev/null 2>&1; then MANUAL+=("③未找到 ${SMI[0]}:驱动未装(--apply 会 ubuntu-drivers install)"); return 0; fi
  probe smi
  if [ "$PROBE_RC" -eq 0 ] && [ -n "$(printf '%s' "$PROBE_OUT" | tr -d '[:space:]')" ]; then
    dbk_add_check "③nvidia-smi: $(printf '%s\n' "$PROBE_OUT" | grep -m1 -E 'Driver Version|NVIDIA-SMI' | sed 's/^[[:space:]]*//' || printf 'ok')"
  else
    MANUAL+=("③nvidia-smi 执行失败(退出码 $PROBE_RC):装完未重启或驱动未加载;重启后重跑本脚本")
  fi
}
# 判据④:会话类型 Wayland(Kubuntu 26.04 是 Wayland-only)
check_session() {
  case "${XDG_SESSION_TYPE:-}" in
    wayland) dbk_add_check "④XDG_SESSION_TYPE=wayland" ;;
    "") MANUAL+=("④取不到 XDG_SESSION_TYPE(登录桌面后在会话内重跑;期望 wayland)") ;;
    *) ISSUES+=("④XDG_SESSION_TYPE=$XDG_SESSION_TYPE:期望 wayland;先查驱动加载与残留 nomodeset,再考虑重建会话") ;;
  esac
}
# 判据⑤:PRIME offload(核显输出 + 独显渲染的常见双显卡布局)
check_prime() {
  if ! command -v "${XR[0]}" >/dev/null 2>&1; then MANUAL+=("⑤未找到 ${XR[0]}:无法核对 PRIME offload 的 provider 数"); return 0; fi
  probe xr --listproviders
  local n; n="$(printf '%s\n' "$PROBE_OUT" | grep -cE '^Provider [0-9]+' || true)"
  case "$n" in
    ""|0) MANUAL+=("⑤xrandr --listproviders 解析不到 provider 行(远程会话或无 X 时正常);请人工核对 PRIME offload") ;;
    1) MANUAL+=("⑤只有 1 个 provider:单显卡布局属正常;双显卡请人工确认 PRIME offload(prime-run)") ;;
    *) dbk_add_check "⑤PRIME:xrandr --listproviders 有 $n 个 provider(offload 可用)" ;;
  esac
}
# 只读采集:硬件与 nouveau 兜底说明
collect() {
  if command -v "${LSPCI[0]}" >/dev/null 2>&1; then
    probe lspci_ -nn
    local gpu; gpu="$(printf '%s\n' "$PROBE_OUT" | grep -E 'VGA|3D' | tr '\n' ';' | sed 's/;*$//' || true)"
    dbk_add_check "显卡(lspci -nn):${gpu:-未列出 VGA/3D 设备(受限环境或纯远程会话)}"
  fi
  if command -v "${LS[0]}" >/dev/null 2>&1; then
    probe lsm
    if printf '%s\n' "$PROBE_OUT" | grep -qE '^nvidia([[:space:]]|_)'; then dbk_add_check "lsmod: nvidia 模块已加载"
    else dbk_add_check "lsmod: 未见 nvidia(未装或未重启;nouveau 在加载则说明仍在用开源驱动)"; fi
  fi
  dbk_add_check "nouveau 兜底: 桌面起不来时用 07-2 从 GRUB 提示符回 Windows,或按 07-5 只重装 Linux;不要长按电源(用 REISUB)"
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
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了(多为装完未重启才可判定);逐条见 checks"
  fi
  dbk_exit PASS "$msg:驱动来源为 Ubuntu 官方包、nvidia 签名者非空、nvidia-smi 可用、会话为 wayland"
}

judge_all() {
  ISSUES=(); MANUAL=()
  check_source; check_signer; check_smi; check_session; check_prime
  return 0
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  collect
  judge_all
  if [ "${#ISSUES[@]}" -eq 0 ] && [ "${#MANUAL[@]}" -eq 0 ]; then
    dbk_exit PASS "显卡栈已就绪(驱动来源为 Ubuntu 官方包、签名者非空、nvidia-smi 可用、wayland);--apply 无需再装"
  fi
  OUT=""; RC=0
  OUT="$(ud install 2>&1)" || RC=$?
  if [ "$RC" -ne 0 ]; then
    dbk_add_check "失败项: $UD_STR install 退出码 $RC"
    dbk_exit FAIL "安装推荐驱动失败: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' ' ');可改用 apt-get install -y nvidia-driver-<版本>(版本取 --check 的推荐行)"
  fi
  dbk_add_action "ubuntu-drivers install(装推荐驱动,Ubuntu 官方预签名包)"; dbk_mark_changed
  collect; judge_all
  if [ "${#ISSUES[@]}" -eq 0 ] && [ "${#MANUAL[@]}" -eq 0 ]; then
    dbk_exit PASS "推荐驱动已安装并复读通过(--apply;无需 MOK 注册)"
  fi
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "驱动已安装但复读仍有 ${#ISSUES[@]} 项未达成;逐条见 checks"
  fi
  dbk_exit 需人工 "驱动已安装,但仍有 ${#MANUAL[@]} 项要重启后才能判定(模块未加载 / nvidia-smi 未就绪):重启后重跑本脚本复核"
fi

collect; judge_all
finish "显卡栈核对完成(--check 零写)"
