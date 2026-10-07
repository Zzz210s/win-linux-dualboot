#!/usr/bin/env bash
# 对应卡:05-7,05-10,07-7
# 破坏性:1
# 引导器状态与更新后复读断言(卡 05-7 / 05-10 / 07-7;批次 M1,落点见设计 03 第 6 节)。
# 为什么有这张卡:上游 Silverblue #595 真实出现过 `bootupctl update` 后 `/boot/loader/grub.cfg` 丢失 ->
#   掉进 grub 命令行;对"固件只认 Windows 条目"的双系统机器,这是能进不去系统的组合。本脚本把
#   "重启前先复读引导器"做成可执行判据(判据真源:docs/07-rescue.md 的 07-7、docs/05-first-boot.md 的 05-7/05-10)。
# 判据(--check,零写):
#   ① `bootupctl status` 原样输出;含 `updates available` -> 需人工(2)并提示先更新;
#   ② /boot/loader/grub.cfg 存在且非空(缺失或空 -> 硬判据 FAIL);
#   ③ /boot/loader/entries/*.conf 条目数 ≥ 部署数且 ≥ 2(条目为 0 -> 硬判据 FAIL);
#   ④ 找不到 bootupctl -> 需人工(2):缺少 bootupd 时只能手工比对 ESP(老镜像不判 FAIL)。
# --apply --update --yes 才跑 `bootupctl update`(缺 --yes 由库层退 64 且零写);更新后**立刻复读 ②③**,
#   复读失败 -> 1 并输出"不要重启,先按 07-2 / 07-6 处置"。
# --apply 不带 --update:无写动作,只做只读判定(调用方是 07-7 周期巡检与 05-7/05-10 的重启前手工复核;
#   总控 verify-all.sh **不**调本行,所以不得假设有调用方替它加 --yes)。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-bootloader.sh [--check|--apply] [--update] [--dry-run] [--json] [--log <路径>] [--yes] [--step NN-K] [-h]
# 注入(夹具用):DBK_BOOT_DIR / DBK_EFI_DIR / DBK_DEPLOYMENTS / DBK_BOOTUPCTL;部署数缺省经 dbk-rollback.sh 读
#   (DBK_RPM_OSTREE 透传)。
# 待核实(以官方文档为准):bootupctl status 的 "updates available" 文案、update 子命令形态、BLS 目录路径。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-rollback.sh disable=SC1091
. "$HERE/dbk-rollback.sh"

UPDATE_REQ=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) UPDATE_REQ=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
dbk_assert_step
dbk_log_default "check-bootloader"
dbk_enable_errtrap

BOOT_DIR="${DBK_BOOT_DIR:-/boot}"; EFI_DIR="${DBK_EFI_DIR:-/boot/efi}"
BOOTUPCTL="${DBK_BOOTUPCTL:-bootupctl}"
GRUB_CFG="$BOOT_DIR/loader/grub.cfg"; ENTRIES_DIR="$BOOT_DIR/loader/entries"
GUIDE="处置指引:不要重启,先按 07-2(从 grub 提示符回去)或 07-6(基线回滚)处置。"

ISSUES=(); MANUAL=()
bootupctl_avail() { command -v "${BOOTUPCTL%% *}" >/dev/null 2>&1; }
count_entries() { local f n=0; for f in "$ENTRIES_DIR"/*.conf; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }
deploy_num() {   # 0 = 取到(打印整数)/ 2 = 取不到(需人工);DBK_DEPLOYMENTS 为夹具注入点
  case "${DBK_DEPLOYMENTS:-}" in
    '') ;;
    *[!0-9]*) return 2 ;;
    *) printf '%s' "$DBK_DEPLOYMENTS"; return 0 ;;
  esac
  deployments_count
}

judge() {   # 只读判定:① bootupctl status ② grub.cfg ③ BLS 条目
  local n dc rc st out low
  ISSUES=(); MANUAL=()
  if bootupctl_avail; then
    st=0; out="$(command "$BOOTUPCTL" status 2>&1)" || st=$?
    dbk_obs "①$BOOTUPCTL status 原样输出:"; printf '%s\n' "$out" >&2
    if [ "$st" -ne 0 ]; then MANUAL+=("①bootupctl status 执行失败(退出码 $st):$out")
    else
      # 判定必须大小写无关,且不能把否定式("No updates available")当成"有更新"。
      # 2026-10-06 夹具实测过朴素子串匹配的两个反向错:缺省输出 "No updates available" 被判需人工,
      # 而真 `Updates available` 因大小写不同又被放行(两个用例同时变红)。
      low="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
      case "$low" in
        *"updates available"*)
          case "$low" in
            *"no updates available"*) dbk_add_check "①bootupctl status:没有可用更新(原样输出见上)" ;;
            *) MANUAL+=("①bootupctl status 报 updates available:先跑 --apply --update --yes 更新引导器,再复读本脚本") ;;
          esac ;;
        *) dbk_add_check "①bootupctl status:未报 updates available(原样输出见上;上游文案若不同,按上面原样行人工判)" ;;
      esac
    fi
  else
    MANUAL+=("④未找到 $BOOTUPCTL:缺少 bootupd 时只能手工比对 ESP($EFI_DIR 与 \\EFI\\fedora\\),本脚本判不了引导器是否落后")
  fi
  if [ -s "$GRUB_CFG" ]; then dbk_add_check "②$GRUB_CFG 在位且非空"
  else ISSUES+=("②$GRUB_CFG 缺失或为空(上游 #595 的形态:掉进 grub 命令行);$GUIDE"); fi
  n="$(count_entries)"
  if [ "$n" -eq 0 ]; then
    ISSUES+=("③$ENTRIES_DIR 下 BLS 条目为 0:重启会掉进 grub 命令行;$GUIDE")
  else
    rc=0; dc="$(deploy_num)" || rc=$?
    if [ "$rc" -ne 0 ]; then MANUAL+=("③部署数取不到(部署列表不可读):无法核对 BLS 条目数 ≥ 部署数")
    elif [ "$n" -lt "$dc" ]; then ISSUES+=("③BLS 条目 $n 个 < 部署数 $dc:有部署没有引导条目;$GUIDE")
    else dbk_add_check "③BLS 条目 $n 个 ≥ 部署数 $dc"; fi
    if [ "$n" -lt 2 ]; then ISSUES+=("③BLS 条目仅 $n 个(<2):至少要有当前部署与上一部署两条;$GUIDE"); fi
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项硬判据不满足;$GUIDE"; fi
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ "${#MANUAL[@]}" -gt 0 ]; then dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"; fi
  dbk_exit PASS "$msg:引导器未落后、grub.cfg 在位、BLS 条目数达标"
}

if [ "$DBK_MODE" = apply ] && [ "$UPDATE_REQ" -eq 1 ]; then
  if [ "$(id -u)" -ne 0 ]; then dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"; dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --update --yes"; fi
  if ! bootupctl_avail; then dbk_add_check "未找到 $BOOTUPCTL"; dbk_exit 需人工 "未找到 $BOOTUPCTL:无法执行 bootupctl update(缺少 bootupd 时只能手工比对 ESP $EFI_DIR)"; fi
  dbk_need_yes "运行 $BOOTUPCTL update(更新引导器)" "$BOOTUPCTL update"
  UPD_OUT=""
  if ! UPD_OUT="$(command "$BOOTUPCTL" update 2>&1)"; then
    dbk_add_check "bootupctl update 失败: $UPD_OUT"
    dbk_exit FAIL "$BOOTUPCTL update 执行失败;$GUIDE"
  fi
  dbk_add_action "$BOOTUPCTL update 已执行: $UPD_OUT"; dbk_mark_changed
  judge   # 更新后立刻复读 ②③
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "bootupctl update 后复读失败;$GUIDE"
  fi
  finish "bootupctl update 已执行且复读通过"
fi

if [ "$DBK_MODE" = apply ]; then dbk_note "说明: --apply 不带 --update 时本脚本无写动作,只做只读判定。"
elif [ "$UPDATE_REQ" -eq 1 ]; then dbk_note "说明: --check 下 --update 不生效(要真更新请走 --apply --update --yes)。"; fi
judge
if [ "$DBK_MODE" = apply ]; then finish "引导器判据核对完成(--apply 无写动作:未更新引导器)"; else finish "引导器判据核对完成(--check 零写)"; fi
