#!/usr/bin/env bash
# 对应卡:07-7
# root 文件系统完整性巡检(卡 07-7;批次 M1):root 是 btrfs,`btrfs device stats` 的非零错误计数 = 硬失败。
# 判据(--check,零写):
#   ① 读 root 文件系统类型(findmnt -T /);非 btrfs -> 需人工(2):本项只对 btrfs root 适用;
#   ② root 是 btrfs 时,`btrfs device stats <root 挂载点>` 各项错误计数全为 0(任一非零 -> FAIL);
#      命令缺失或读不到 -> 需人工(2),绝不 fail-open 成通过。
# 只报告项:`btrfs scrub status` 的最近结论(取不到只记一行需人工,不影响退出码)。
# 与 check-health.sh 的分工:后者管会话/部署/更新策略/余量等"运行态";本脚本只管磁盘与文件系统完整性。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。
# 用法: check-integrity.sh [--check|--apply] [--dry-run] [--json] [--log <路径>] [--step NN-K] [-h]
# 注入(夹具用):DBK_BTRFS / DBK_ROOT_MNT / DBK_ROOT_FSTYPE / DBK_FINDMNT。
# 待核实(以官方文档为准):btrfs device stats 的输出格式与错误计数列名、scrub status 的结论行。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "check-integrity"
dbk_enable_errtrap

ROOT_MNT="${DBK_ROOT_MNT:-/}"
BTRFS="${DBK_BTRFS:-btrfs}"
FINDMNT="${DBK_FINDMNT:-findmnt}"
ROOT_FS="${DBK_ROOT_FSTYPE:-}"
if [ -z "$ROOT_FS" ]; then ROOT_FS="$(command "$FINDMNT" -rn -o FSTYPE -T "$ROOT_MNT" 2>/dev/null | head -n 1 || true)"; fi
btrfs_avail() { command -v "${BTRFS%% *}" >/dev/null 2>&1; }

ISSUES=(); MANUAL=()
judge() {
  local out st line cnt bad sstat
  ISSUES=(); MANUAL=()
  if [ -z "$ROOT_FS" ]; then MANUAL+=("取不到 root 文件系统类型(findmnt -T $ROOT_MNT 不可读):无法判定是否 btrfs")
  elif [ "$ROOT_FS" != btrfs ]; then MANUAL+=("root 文件系统为 '$ROOT_FS'(非 btrfs):本项只对 btrfs root 适用,跳过 btrfs 巡检")
  elif ! btrfs_avail; then MANUAL+=("未找到 $BTRFS:无法读 btrfs 设备错误计数")
  else
    st=0; out="$(command "$BTRFS" device stats "$ROOT_MNT" 2>&1)" || st=$?
    if [ "$st" -ne 0 ]; then MANUAL+=("btrfs device stats 执行失败(退出码 $st):$out")
    else
      bad=0
      while IFS= read -r line; do
        cnt="$(printf '%s\n' "$line" | awk '{print $NF}')"
        case "$cnt" in ''|*[!0-9]*) continue ;; esac
        [ "$cnt" -eq 0 ] || { bad=1; dbk_add_check "失败项: $line"; }
      done <<<"$out"
      if [ "$bad" -eq 0 ]; then dbk_add_check "①btrfs device stats:各项错误计数全为 0"
      else ISSUES+=("btrfs device stats 有非零错误计数(逐条见 checks):按 07-7 备份数据并安排 scrub 或换盘"); fi
    fi
  fi
  if btrfs_avail; then
    sstat="$(command "$BTRFS" scrub status "$ROOT_MNT" 2>/dev/null | grep -iE 'scrub (started|finished)|no errors|found [0-9]+ errors' | head -n 2 | tr '\n' ' ' || true)"
    if [ -n "$sstat" ]; then dbk_add_check "记录项:btrfs scrub 最近结论: $sstat"
    else dbk_add_check "记录项: 无法读 btrfs scrub 结论(只报告,不影响退出码)"; fi
  fi
  return 0
}

finish() {
  local msg="${1:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项硬判据不满足;逐条见 checks"; fi
  for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
  if [ "${#MANUAL[@]}" -gt 0 ]; then dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"; fi
  dbk_exit PASS "$msg:root 文件系统完整性通过(btrfs device stats 全 0)"
}

if [ "$DBK_MODE" = apply ]; then dbk_note "说明: 本脚本无写动作(只读巡检);--apply 与 --check 输出相同。"; fi
judge
finish "完整性巡检完成(--check 零写)"
