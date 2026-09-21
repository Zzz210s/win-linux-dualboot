#!/usr/bin/env bash
# 对应卡:05-3
# L4:Secure Boot 下的一次性 MOK 注册与签名复检(变体设计 3 节:MOK 注册行与判据行)。
# 用途:--check 只读判定 `mokutil --list-enrolled` 是否已有上游密钥、`modinfo -F signer nvidia` 是否有签名者、
#   `lsmod` 是否加载 nvidia;--apply(需 root)执行一次 `ujust enroll-secure-boot-key`,然后**重启进 MOK 界面**确认。
# 判据(--check,零写):① `mokutil --list-enrolled` 有已注册密钥(空 = 还没注册 → 需人工 2);
#   ② `modinfo -F signer nvidia` 非空(取不到 → 需人工);③ `lsmod` 有 `nvidia`(未加载 → 需人工,重启后复跑)。
# 未注册的处置(脚本判不了固件界面里的按键,按卡口径给「需人工」而不是「失败」):
#   在 TTY 或桌面上执行 `sudo ujust enroll-secure-boot-key` -> 重启 -> MOK 界面选 Enroll MOK -> Continue ->
#   输入上游文档给的 MOK 密码 -> Reboot;随后重跑本脚本复核。
# 边界:本步不改分区表、不改引导顺序(I1–I4),只往固件 MOK 库注册上游厂商密钥;不关 Secure Boot、不自签密钥。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: graphics-mok.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step 05-3]
# 环境注入(夹具用):DBK_MOKUTIL / DBK_MODINFO / DBK_LSMOD / DBK_UJUST 覆盖命令;DBK_UJUST_TASK 覆盖任务名。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "graphics-mok"

MOKUTIL="${DBK_MOKUTIL:-mokutil}"
MODINFO="${DBK_MODINFO:-modinfo}"
LSMOD="${DBK_LSMOD:-lsmod}"
# ujust 任务名上游会改(变体设计 3 节「实施时须核实」):默认用设计文档写的名字,真机前必须按官方文档核对。
UJUST_TASK="${DBK_UJUST_TASK:-enroll-secure-boot-key}"  # 待核实(以官方文档为准)
UJUST="${DBK_UJUST:-ujust}"

ENROLLED=""; SIGNER=""; ISSUES=(); MANUAL=()

probe() { # 读一个可选判据:命令跑不了或不给输出都不算失败,由调用方决定归入需人工
  local out; out="$("$@" 2>&1)" || true; printf '%s' "$out"
}

judge() {
  ISSUES=(); MANUAL=()
  if command -v "$MOKUTIL" >/dev/null 2>&1; then
    ENROLLED="$(probe "$MOKUTIL" --list-enrolled)"
    if [ -z "$ENROLLED" ]; then
      MANUAL+=("mokutil --list-enrolled 为空:MOK 未注册任何密钥;执行 sudo ujust $UJUST_TASK 后重启进 MOK 界面确认")
    else
      dbk_add_check "已注册 MOK 密钥(${MOKUTIL} --list-enrolled 非空,共 $(printf '%s\n' "$ENROLLED" | grep -c . ) 行)"
      case "$ENROLLED" in
        *ublue*|*Universal*|*NVIDIA*|*nvidia*) dbk_add_check "已注册密钥含上游厂家标识(ublue/NVIDIA)" ;;
        *) MANUAL+=("已注册密钥里未见上游厂家标识;请人工核对是否就是 ublue 的 NVIDIA 变体密钥") ;;
      esac
    fi
  else
    MANUAL+=("无 $MOKUTIL 命令;请人工跑 mokutil --list-enrolled 核对")
  fi
  if command -v "$MODINFO" >/dev/null 2>&1; then
    SIGNER="$(probe "$MODINFO" -F signer nvidia)"
    if [ -n "$SIGNER" ]; then
      dbk_add_check "nvidia 模块签名者(modinfo -F signer nvidia): $(printf '%s' "$SIGNER" | tr '\n' ' ')"
    else
      MANUAL+=("modinfo -F signer nvidia 为空:模块未装、未加载或读不到;rebase+重启后再复核")
    fi
  else
    MANUAL+=("无 $MODINFO 命令;请人工跑 modinfo -F signer nvidia 核对")
  fi
  if command -v "$LSMOD" >/dev/null 2>&1; then
    if "$LSMOD" 2>/dev/null | grep -qE '^nvidia([[:space:]]|_)'; then
      dbk_add_check "nvidia 模块已加载(lsmod)"
    else
      MANUAL+=("lsmod 未见 nvidia:rebase 后未重启时属正常现象;重启后重跑本脚本")
    fi
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项需要人工(多为重启进 MOK 界面才能完成);逐条见 checks"
  fi
  dbk_exit PASS "$msg:MOK 已注册上游密钥、nvidia 签名者非空且模块已加载"
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply(只想看结论就只跑 --check)"
  fi
  if ! command -v "$UJUST" >/dev/null 2>&1; then
    dbk_add_check "失败项: 无 $UJUST 命令(原子桌面应自带 ujust)"
    dbk_exit FAIL "无 $UJUST:无法执行 $UJUST_TASK;请人工按官方文档注册 MOK(任务名待核实)"
  fi
  if out="$("$UJUST" "$UJUST_TASK" 2>&1)"; then
    dbk_add_action "$UJUST $UJUST_TASK(一次性 MOK 注册)"
    dbk_mark_changed
    dbk_add_check "ujust 输出摘要: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  else
    dbk_add_check "失败项: $UJUST $UJUST_TASK 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    dbk_exit FAIL "$UJUST $UJUST_TASK 失败(任务名标 # 待核实,先按官方文档核对):见 checks"
  fi
  dbk_exit 需人工 "MOK 注册已提交但**必须重启后人工确认**:重启 -> MOK 界面选 Enroll MOK -> Continue -> 输入上游文档给的 MOK 密码 -> Reboot;回来重跑本脚本 --check(任务名与密码均标 # 待核实)"
fi

judge
finish "MOK 与 nvidia 签名核对完成(--check 零写)"
