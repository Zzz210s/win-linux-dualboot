#!/usr/bin/env bash
# 验收总控(Fedora 44 Silverblue / 原子版侧;执行器:不进卡映射表、不登记 steps.tsv):按 docs/08-verification.md 的 A-G 七组
#   逐项判定——能自动的调既有步骤脚本的 --check/--list 或读系统状态,不能自动的记「需人工」并给手动核对步骤。
#   **绝不执行任何 --apply**:只允许 --check 与只读子命令,收到 --apply/--rollback/--pin/--unpin → 64 且一个子脚本
#   都不调。汇总只在 --apply 时落盘 <out-dir>/08-verification.md(每台设备副本,含「已知例外」表与结论行);
#   --check 零写。退出码:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项(加 --confirm-manual
#   表示人工项已按清单逐条核对完成,不再计入退出码)/ 64 用法错误。
# 条目表真源:**scripts/verification-items.tsv**(48 条;列 = 编号/组/卡/侧/判定脚本/参数/标签)。本执行器只读它并按行分派:
#   侧 = W 的条目在本侧记「需人工」;判定脚本 = 仓库相对路径 → 只读调用该步骤脚本;= builtin → 调 dbk-verify-probes.sh 的
#   probe_<编号>;= - → 直接记「需人工」(原因取标签列)。增删条目只改那张表(与 docs/08-verification.md 同步)。
# 用法: verify-all.sh [--check|--apply] [--out-dir <目录>] [--confirm-manual] [--json] [--log <路径>]
# 夹具注入(真机不需要):DBK_ITEMS_TSV(换一张条目表)/DBK_EFIBOOTMGR/DBK_FINDMNT/DBK_MOKUTIL/DBK_TIMEDATECTL/DBK_FWUPDMGR/
#   DBK_SYSTEMCTL/DBK_ZRAMCTL/DBK_SMARTCTL/DBK_JOURNALCTL/DBK_XDG_USER_DIR、DBK_SESSION_TYPE、DBK_STEP_ROOT/DBK_GIT_ROOT/
#   DBK_BASELINE_DIR/DBK_FSTAB/DBK_JOURNAL_DIR/DBK_SHARED_MNT/DBK_DISK;白名单依据=设计 03 第 6 节「验收七组」。
# 跨文件注入:STEP_ROOT / GIT_ROOT / BASEDIR / FSTAB / JRNL / SHARED / DISK / HOOK_RC 由 source 进来的
#   dbk-verify-probes.sh 的 probe_* 消费(bash 动态作用域),本文件里"看起来未使用"是预期的;
#   豁免 SC2034 以免掩盖别处真正的未用变量。
# shellcheck disable=SC2034
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$SRC/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$SRC/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-verify-probes.sh disable=SC1091
. "$SRC/dbk-verify-probes.sh"
# 缺省落点 = <baseline>/auto/(与 Windows 侧同口径):baseline/08-verification.md 是**人填写版**,缺省写那里会把它盖掉。
OUTDIR="$ROOT/baseline/auto"; CONFIRM=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --out-dir 缺取值(输出目录)"; exit "$DBK_USAGE"; }; OUTDIR="$2"; shift 2 ;;
    --out-dir=*) OUTDIR="${1#*=}"; shift ;;
    --confirm-manual) CONFIRM=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
# --step(执行器专用,与 Windows 侧 verify-all.ps1 同口径,真源 docs/design/03 第 5 节):`08-A-G` = 七组全判(缺省);
#   `08-A`…`08-G` = 只判该组(过滤条目表的**组**列);其它值 = 验收条目关联的卡号(NN-K,过滤**卡**列)。非法值 → 64 且不落产物。
#   未选中的条目记「跳过」、不计入退出码(本执行器不绑卡、无「# 对应卡:」头)。
STEP_SEL="${DBK_STEP:-}"; case "$STEP_SEL" in 08-A-G) STEP_SEL="" ;; esac; DBK_STEP="${STEP_SEL:-08-A-G}"
if [ "$DBK_MODE" = apply ]; then dbk_log_default "verify-all"; fi
STEP_ROOT="${DBK_STEP_ROOT:-$ROOT}"; GIT_ROOT="${DBK_GIT_ROOT:-$ROOT}"; BASEDIR="${DBK_BASELINE_DIR:-$ROOT/baseline}"
FSTAB="${DBK_FSTAB:-/etc/fstab}"; JRNL="${DBK_JOURNAL_DIR:-/var/log/journal}"
SHARED="${DBK_SHARED_MNT:-/mnt/shared}"; DISK="${DBK_DISK:-/dev/nvme0n1}"
SUMMARY="$OUTDIR/08-verification.md"; HOST="${DBK_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
G=""; R=(); n_pass=0; n_fail=0; n_manual=0; n_skip=0; HOOK_OUT=""; HOOK_RC=0; STEP_OUT=""; STEP_RC=0
tag_of() { case "$1" in pass) printf PASS ;; fail) printf FAIL ;; manual) if [ "$CONFIRM" -eq 1 ]; then printf '需人工(已确认)'; else printf 需人工; fi ;; *) printf 跳过 ;; esac; }
item() {   # <编号> <结论> <原因> <关联卡>;G=当前组(原因内的 | 换全角,避免拆列歧义);打印/计数/--step 过滤统一在汇总段
  R+=("$1|$G|$2|${3//|/／}|$4"); }
run_hook() {   # <命令或回放文件> [参数…]:输出进 HOOK_OUT(不吞 stderr),HOOK_RC = 命令退出码
  local spec="$1" p=(); shift || true; HOOK_OUT=""; HOOK_RC=0
  if [ -e "$spec" ]; then HOOK_OUT="$(cat -- "$spec" 2>&1)" || HOOK_RC=$?; return 0; fi
  read -r -a p <<<"$spec"
  if ! command -v "${p[0]:-$spec}" >/dev/null 2>&1; then HOOK_RC=127; return 0; fi   # 命令不存在 → HOOK_OUT 空(调用方按需人工)
  HOOK_OUT="$("${p[@]}" "$@" 2>&1)" || HOOK_RC=$?
  return 0
}
avail() { [ -e "${1:-}" ] || command -v "${1%% *}" >/dev/null 2>&1; }
first() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-140 || true; }
chk_cmd_all() {   # <编号> <卡> <标签> <命令> <分号分隔正则;全中才 PASS> [参数…]
  local id="$1" card="$2" lab="$3" spec="$4" res="$5" re miss="" RES=(); shift 5
  run_hook "$spec" "$@"
  # 逐项按整条正则匹配(不按空白切词):否则 'RTC in local TZ: no' 会被拆成 6 个必须同时命中的词,双语言判据(中英各写一条)也没法表达。
  mapfile -t RES <<<"${res//;/$'\n'}"
  for re in ${RES[@]+"${RES[@]}"}; do [ -n "$re" ] || continue; printf '%s' "$HOOK_OUT" | grep -qE "$re" || miss="$miss $re"; done
  if ! avail "$spec"; then item "$id" manual "$lab:未找到命令 $spec;手动核对:按 $card 与 08 清单手工执行" "$card"
  elif [ -z "$miss" ]; then item "$id" pass "$lab:$(first "$HOOK_OUT")" "$card"
  else item "$id" fail "$lab:输出缺$miss;实际:$(first "$HOOK_OUT")" "$card"; fi
}
run_step() { STEP_OUT="$(cd "$STEP_ROOT" && bash "$@" 2>&1)" && STEP_RC=0 || STEP_RC=$?; return 0; }
chk_step() {   # <编号> <卡> <标签> <步骤脚本相对路径> [只读参数…];状态改动参数 → 64(一个子脚本都不调)
  local id="$1" card="$2" lab="$3" rel="$4" msg; shift 4
  case " $* " in *" --apply "*|*" --rollback "*|*" --pin "*|*" --unpin "*)
    dbk_note "用法错误: 验收总控只允许只读调用,收到状态改动参数:$*"; exit "$DBK_USAGE" ;; esac
  run_step "$rel" "$@"; msg="$(printf '%s\n' "$STEP_OUT" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-160 || true)"
  case "$STEP_RC" in 0) item "$id" pass "$lab:$msg" "$card" ;; 2) item "$id" manual "$lab(脚本判为需人工):$msg" "$card" ;;
    9) item "$id" skip "$lab(脚本跳过):$msg" "$card" ;; *) item "$id" fail "$lab(脚本退出码 $STEP_RC):$msg" "$card" ;; esac
}
# ===== 读条目表(唯一真源;制表符分隔、LF、# 开头为注释)=====
ITEMS_TSV="${DBK_ITEMS_TSV:-$ROOT/scripts/verification-items.tsv}"
[ -r "$ITEMS_TSV" ] || { dbk_usage; dbk_note "用法错误: 读不到验收条目表 $ITEMS_TSV(它随仓库分发,不要手工生成)"; exit "$DBK_USAGE"; }
ITEMS=()
while IFS=$'\t' read -r id grp card side scr args label; do
  case "$id" in ''|'#'*) continue ;; esac
  ITEMS+=("$id|$grp|$card|$side|$scr|$args|${label//|/／}")
done <"$ITEMS_TSV"
[ "${#ITEMS[@]}" -gt 0 ] || { dbk_usage; dbk_note "用法错误: 验收条目表 $ITEMS_TSV 里没有条目行"; exit "$DBK_USAGE"; }
# ===== 逐条判定(按侧与判定脚本列分派;探测实现见 dbk-verify-probes.sh)—— A 引导安全 / B 系统功能 / C 切换 / D 可撤除 / E 记录 / F 健壮 / G 体验
for row in "${ITEMS[@]}"; do
  IFS='|' read -r id grp card side scr args label <<<"$row"
  G="$grp"
  if [ "$side" = W ]; then item "$id" manual "$label" "$card"; continue; fi
  case "$scr" in
    -) item "$id" manual "$label" "$card" ;;
    builtin) if declare -F "probe_$id" >/dev/null 2>&1; then "probe_$id" "$label" "$card"
             else item "$id" manual "$label(本侧没有 $id 的内置探测,需人工)" "$card"; fi ;;
    *) ARGS_A=(); [ "$args" = "-" ] || read -r -a ARGS_A <<<"$args"
       chk_step "$id" "$card" "$label" "$scr" ${ARGS_A[@]+"${ARGS_A[@]}"} ;;
  esac
done
# ===== --step 过滤与计数(执行器语义:见脚本头;非法值 64,不落任何产物)=====
KNOWN="$(printf '%s\n' "${R[@]}" | cut -d'|' -f5 | sort -u | tr '\n' ' ')"
GRP_LIST="$(printf '%s\n' "${R[@]}" | cut -d'|' -f2 | sort -u | tr '\n' ' ')"
SEL_GROUP=""
if [ -n "$STEP_SEL" ]; then
  case "$STEP_SEL" in
    08-[A-G]) SEL_GROUP="${STEP_SEL#08-}"
      printf ' %s ' "$GRP_LIST" | grep -q " $SEL_GROUP " || { dbk_usage; dbk_note "用法错误: --step $STEP_SEL 不在本执行器的组集合里;可用组:08-A 08-B 08-C 08-D 08-E 08-F 08-G;08-A-G = 七组全判(缺省)"; exit "$DBK_USAGE"; } ;;
    *) printf ' %s ' "$KNOWN" | grep -q " $STEP_SEL " || { dbk_usage; dbk_note "用法错误: --step $STEP_SEL 不在本执行器(验收总控)的验收条目集合里;可用值:$KNOWN;08-A-G = 七组全判(缺省)"; exit "$DBK_USAGE"; } ;;
  esac
fi
for idx in "${!R[@]}"; do IFS='|' read -r i g s m c <<<"${R[$idx]}"
  if [ -n "$SEL_GROUP" ]; then
    if [ "$g" != "$SEL_GROUP" ]; then s=skip; m="未选中(--step $STEP_SEL 只判组 $SEL_GROUP):$m"; fi
  elif [ -n "$STEP_SEL" ] && [ "$c" != "$STEP_SEL" ]; then s=skip; m="未选中(--step $STEP_SEL 只判卡 $STEP_SEL):$m"; fi
  R[$idx]="$i|$g|$s|$m|$c"; case "$s" in fail) n_fail=$((n_fail + 1)) ;; manual) n_manual=$((n_manual + 1)) ;; pass) n_pass=$((n_pass + 1)) ;; *) n_skip=$((n_skip + 1)) ;; esac
  if [ "${DBK_JSON:-0}" -ne 1 ]; then printf '[%s] %s %s\n' "$(tag_of "$s")" "$i" "$m"; fi
done
# ===== 汇总与落盘 =====
if [ "$n_fail" -gt 0 ]; then OVER=fail; CONCL="不通过(自动判定失败 $n_fail 项;逐条见下表)"
elif [ "$n_manual" -gt 0 ] && [ "$CONFIRM" -eq 0 ]; then OVER=manual; CONCL="待人工(无自动失败,但有 $n_manual 项需人工核对;逐条见下表)"
elif [ "$n_manual" -gt 0 ]; then OVER=pass; CONCL="通过(人工项 $n_manual 项已由执行人按清单逐条确认)"
else OVER=pass; CONCL="通过(全部 $n_pass 项自动判定通过)"; fi
if [ "${DBK_JSON:-0}" -eq 1 ]; then
  for r in "${R[@]}"; do IFS='|' read -r i g s m c <<<"$r"; dbk_add_check "$i($g) $(tag_of "$s"):$m [关联卡 $c]"; done
  dbk_emit_json "$DBK_STEP" "$OVER" "$CONCL"
else
  printf '汇总: PASS=%s FAIL=%s 需人工=%s 跳过=%s;每个条目都带编号与关联卡\n结论: %s\n' "$n_pass" "$n_fail" "$n_manual" "$n_skip" "$CONCL"
fi
if [ "$DBK_MODE" = apply ]; then
  mkdir -p "$OUTDIR"
  printf '%s\n' "${R[@]}" | dbk_write_accept_summary "$SUMMARY" "$HOST" 'Linux(Fedora 原子版)' \
    '`scripts/linux/verify-all.sh`(执行器,不进卡映射表)' '`docs/08-verification.md`(唯一判据)' "$CONCL" "$CONFIRM"
  printf '汇总已写:%s\n' "$SUMMARY" >&2
  if [ -n "${DBK_LOG:-}" ]; then dbk_log_write "验收汇总已写:$SUMMARY;结论:$CONCL"; fi
fi
case "$OVER" in fail) exit "$DBK_FAIL" ;; manual) exit "$DBK_MANUAL" ;; *) exit "$DBK_PASS" ;; esac
