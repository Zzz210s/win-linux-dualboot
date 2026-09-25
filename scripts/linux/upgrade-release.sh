#!/usr/bin/env bash
# 对应卡:05-10
# 破坏性:1
# L4:发行版升级(Fedora 44 Silverblue 原子版;节奏约 13 个月一次 —— 每 6 个月一发、支持窗口约 13 个月)。
# 设计依据:docs/design/06-atomic-restore-design.md 第 2 节 D1/D4 与第 3 节(upgrade-release.sh 行)、
#   docs/design/02-fedora-atomic-variant-design.md 第 4 节(先固定当前部署 → rebase 到下一发行版分支 →
#   重启 → 复检;不满意就回滚到已固定的部署)、docs/design/03-step-automation-design.md 第 6 节映射表(卡 05-10)。
# 用途:--check 只读判定升级前置是否齐备;--apply(需 --yes,库层按脚本头「# 破坏性:1」拦)执行
#   「固定当前部署 → 备份 baseline/ → 复核前置 → 提交 rebase → 提示重启 → 后置复检」。
# 判据(--check,零写;逐项分流 —— 读到了且不成立 → 1 FAIL,判不了/取值缺失 → 2 需人工):
#   ① 部署列表可读(走接口 dbk-rollback.sh 的 deployments_list);
#   ② 当前启动部署已被固定(pin):升级不满意或进不了桌面时,它是唯一的退回目标;
#   ③ baseline/ 存在,有得备份(设计 00 R1:变更前留一份现场记录);
#   ④ 更新策略复核(走接口 dbk-update.sh 的 update_policy_check):仍是「只检查/下载,不自动应用与自动重启」;
#   ⑤ 已指定升级目标分支(DBK_RELEASE_REF):分支号随发行版推进,必须人工给。
# --apply 顺序:前置 1 固定当前部署(接口 rollback_pin,索引即读即用)→ 前置 2 复核上面五条
#   (任一未达成即不执行)→ 前置 3 备份 baseline/ 到 <backup-dir>/<时间戳>-baseline/ → 提交 rebase 到目标分支
#   → 提示重启、后置复检(当前系统版本 / 部署数 / MOK 注册 / 会话类型)。
# 与 Kubuntu 口径的差别(不可改):升级不再由发行版包管理器做,也没有「清残留」复核(原子版没有那套体系);
#   升级 = rebase 到下一个发行版分支,重启后生效;回退用开机菜单选旧部署,或按 05-9 回滚到已固定的部署。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误(声明了破坏性,--apply 缺 --yes 由库层拒且零写)。
# 用法: upgrade-release.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step 05-10] [-h]
# 注入(夹具用):DBK_RELEASE_REF(升级目标分支);DBK_RPM_OSTREE / DBK_RPM_OSTREED_CONF / DBK_SYSTEMCTL /
#   DBK_MOKUTIL / DBK_OS_RELEASE / DBK_BASELINE_DIR / DBK_BACKUP_DIR 全部透传给对应接口;
#   本脚本不写发行版命令字面量(规则 S-1:命令与分支名都由接口或注入给)。
# 待核实(以官方文档为准):rebase 的分支写法与返回码;目标分支号每 6 个月推进一次(实施时按 Fedora 官方公告取值);
#   /etc/os-release 的 VERSION_ID 取值 —— 均未在真机验证(夹具级验证,真机未跑)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
# shellcheck source=scripts/linux/dbk-pkg.sh disable=SC1091
. "$HERE/dbk-pkg.sh"       # PKG_CMD:rebase 走哪条命令
# shellcheck source=scripts/linux/dbk-rollback.sh disable=SC1091
. "$HERE/dbk-rollback.sh"  # deployments_list / deployments_count / rollback_pin(0/1,无 2)
# shellcheck source=scripts/linux/dbk-update.sh disable=SC1091
. "$HERE/dbk-update.sh"    # update_policy_check:复核更新策略
# shellcheck source=scripts/linux/dbk-driver.sh disable=SC1091
. "$HERE/dbk-driver.sh"    # mok_check:后置复核 Secure Boot 密钥注册
# dbk-log.sh 的 log() 打 stdout(会破坏 --json 的单行输出);这里统一改走 dbk_obs(stderr + --log 日志)。
log() { dbk_obs "$*"; }
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "upgrade-release"

REF_STR="${DBK_RELEASE_REF:-}"   # 升级目标分支(人工给;分支号每 6 个月推进一次,待核实)
OS_RELEASE="${DBK_OS_RELEASE:-/etc/os-release}"
BASEDIR="${DBK_BASELINE_DIR:-$ROOT/baseline}"; BAKDIR="${DBK_BACKUP_DIR:-/var/backups/dbk}"
# MOK 口径同 05-3(待核实:MOK 界面里的密码 universalblue 取自 ublue 上游文档)。
MOK_HOWTO="重启进 MOK 界面完成一次性注册(会话内先执行 ujust enroll-secure-boot-key,MOK 密码 universalblue,待核实)"

ISSUES=(); MANUAL=(); LIST=""; CUR_IDX=0
os_ver() { grep -m1 -E '^VERSION_ID=' "$OS_RELEASE" 2>/dev/null | cut -d= -f2- || true; }
# 当前启动部署那一行(「索引 版本 标记…」):优先找 [当前启动] 标记,缺失时退回首行(索引口径见 dbk-rollback.sh 头部)。
cur_line() {
  local line
  line="$(printf '%s\n' "$LIST" | grep -F -m1 '[当前启动]' || true)"
  [ -n "$line" ] || line="$(printf '%s\n' "$LIST" | sed -n '1p')"
  printf '%s\n' "$line"
}

check_all() {
  local rc line skip_pin="${1:-}"
  ISSUES=(); MANUAL=(); LIST=""; CUR_IDX=0
  # ① 部署列表可读
  if LIST="$(deployments_list)"; then rc=0; else rc=$?; LIST=""; fi
  case "$rc" in
    0)
      line="$(cur_line)"; CUR_IDX="$(printf '%s' "$line" | awk '{print $1}')"
      dbk_add_check "①部署列表可读:$line(索引 0 = 当前启动,1 = 上一部署)"
      if [ "$skip_pin" = nopin ]; then
        dbk_add_check "②当前部署(索引 $CUR_IDX)已由 --apply 的前置步骤固定"
      else
        case "$line" in
          *'[pinned]'*) dbk_add_check "②当前部署(索引 $CUR_IDX)已固定:升级不满意时可回滚到它" ;;
          *) ISSUES+=("②当前部署(索引 $CUR_IDX)未固定:先 pin 当前部署(sudo bash scripts/linux/rollback-deploy.sh --pin $CUR_IDX --yes,即卡 05-9)再升级;升级失败时它是唯一的退回目标") ;;
        esac
      fi ;;
    2) MANUAL+=("①读不到部署列表:接口返回 2(命令缺失 / 输出解析不了 / 两个来源部署数不一致);判不了当前部署是否已固定") ;;
    *) ISSUES+=("①部署列表判定返回未知状态码 $rc") ;;
  esac
  # ③ baseline/ 有得备份
  if [ -d "$BASEDIR" ]; then dbk_add_check "③baseline/ 存在,可备份到 $BAKDIR/<时间戳>-baseline/"
  else MANUAL+=("③没有 $BASEDIR 可备份(先跑 03-9 / 05-12 落产物,或确认本机不需要留档)"); fi
  # ④ 更新策略复核(接口 update_policy_check:0 已配 / 1 不符 / 2 读不到)
  if update_policy_check; then rc=0; else rc=$?; fi
  case "$rc" in
    0) dbk_add_check "④更新策略仍是「只检查/下载,不自动应用与自动重启」($UPDATE_CONF)" ;;
    1) ISSUES+=("④更新策略未配为「只检查/下载」($UPDATE_CONF);先跑 05-7 收敛 —— 否则升级后的自动应用会把「能否进桌面」交给无人值守任务") ;;
    2) MANUAL+=("④读不到更新策略配置或定时器状态($UPDATE_CONF);请人工确认配置内容与定时器是否已启用") ;;
    *) ISSUES+=("④更新策略判定返回未知状态码 $rc") ;;
  esac
  # ⑤ 升级目标分支已指定
  if [ -n "$REF_STR" ]; then dbk_add_check "⑤升级目标分支:$REF_STR"
  else MANUAL+=("⑤未指定升级目标分支:用 DBK_RELEASE_REF 给(形如「远程:分支」);分支号每 6 个月推进一次,按 Fedora 官方公告取值"); fi
  return 0
}

# 汇总:$1 = 场景说明,$2 = PASS 行的补充;已判定的失败优先(1),其次判不了的(2)。
finish() {
  local msg="${1:-}" pass_tail="${2:-}" m
  for m in ${ISSUES[@]+"${ISSUES[@]}"}; do dbk_add_check "失败项: $m"; done
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项未达成;逐条见 checks,修好后重跑本脚本(幂等)"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in ${MANUAL[@]+"${MANUAL[@]}"}; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了;逐条见 checks,请人工确认"
  fi
  dbk_exit PASS "$msg:$pass_tail"
}

# --apply 分支。注意:声明了「# 破坏性:1」,--apply 缺 --yes 由 dbk_parse_args 在解析阶段拦(64,零写)。
if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  # 前置 1:固定当前部署(索引即读即用;读不到列表 → 需人工,不猜索引)
  check_all
  if [ -z "$LIST" ]; then finish "升级前置未通过,按纪律不执行升级"; fi
  if printf '%s\n' "$(cur_line)" | grep -qF '[pinned]'; then
    dbk_add_check "前置: 当前部署(索引 $CUR_IDX)已固定,跳过固定动作"
  elif rollback_pin "$CUR_IDX"; then
    dbk_add_action "rollback_pin $CUR_IDX(固定当前部署;升级不满意时可回滚到它)"; dbk_mark_changed
  else
    dbk_add_check "失败项: rollback_pin $CUR_IDX 失败(原因见上面接口输出)"
    dbk_exit FAIL "固定当前部署失败:按上面原因处理后重跑(幂等);未固定前不执行升级(升级后就没有退回目标)"
  fi
  # 前置 2:复核其余前置(② 已在上一步满足)
  check_all nopin
  if [ "${#ISSUES[@]}" -gt 0 ] || [ "${#MANUAL[@]}" -gt 0 ]; then
    finish "升级前置未通过,按纪律不执行升级"
  fi
  # 前置 3:备份 baseline/
  TS="$(date '+%Y%m%d-%H%M%S')"; BAK="$BAKDIR/$TS-baseline"
  mkdir -p "$BAKDIR" || { dbk_add_check "失败项: 无法创建备份目录 $BAKDIR"; dbk_exit FAIL "备份目录创建失败:$BAKDIR(核对路径与权限)"; }
  if cp -a "$BASEDIR" "$BAK"; then dbk_add_action "备份 baseline/ -> $BAK"; dbk_mark_changed
  else dbk_add_check "失败项: cp -a $BASEDIR $BAK 失败"; dbk_exit FAIL "baseline/ 备份失败:按纪律不执行升级(变更前必须留一份现场记录)"; fi
  dbk_note "留档: 更新策略 $UPDATE_CONF -> $(grep -E '^[[:space:]]*AutomaticUpdatePolicy=' "$UPDATE_CONF" 2>/dev/null | head -n1 || printf '未取到')"
  # 前置 4:提交 rebase(重启后生效;当前部署已固定、baseline/ 已备份)
  dbk_need_yes "rebase 到升级目标分支 $REF_STR(重启后才切换系统)" "$PKG_CMD rebase $REF_STR"
  OUT=""; RC=0
  OUT="$(command "$PKG_CMD" rebase "$REF_STR" 2>&1)" || RC=$?
  if [ "$RC" -ne 0 ]; then
    dbk_add_check "失败项: rebase 退出码 $RC"
    dbk_exit FAIL "发行版升级未提交:$(printf '%s' "$OUT" | tail -n 3 | tr '\n' ' ');系统仍跑当前部署,数据在 D: 不受影响"
  fi
  dbk_add_action "rebase 到 $REF_STR(已提交,重启后生效)"; dbk_mark_changed
  # 后置复检(重启前后各跑一次更完整;此处按当前状态如实记录)
  ISSUES=(); MANUAL=()
  V1="$(os_ver)"
  if [ -n "$V1" ]; then dbk_add_check "后置:当前系统版本 $V1(rebase 已提交,重启后才切到新部署)"
  else MANUAL+=("后置: 读不到 $OS_RELEASE 的 VERSION_ID"); fi
  if n2="$(deployments_count)"; then dbk_add_check "后置:部署数 $n2(新部署排在下次启动)"
  else MANUAL+=("后置: 读不到部署数(接口返回 2)"); fi
  if mok_check; then rc=0; else rc=$?; fi
  case "$rc" in
    0) dbk_add_check "后置:MOK 已注册 ublue 密钥(新部署里的模块签名链可用)" ;;
    1) ISSUES+=("后置: MOK 未注册 ublue 密钥($MOK_HOWTO);重启进新部署后显卡模块会加载失败") ;;
    2) MANUAL+=("后置: 读不到 MOK 注册状态;请人工核对 mokutil --list-enrolled 是否含 ublue 密钥") ;;
    *) ISSUES+=("后置: MOK 判定返回未知状态码 $rc") ;;
  esac
  case "${XDG_SESSION_TYPE:-}" in
    wayland) dbk_add_check "后置:会话类型 wayland" ;;
    "") MANUAL+=("后置: 取不到 XDG_SESSION_TYPE(不在图形会话里?)") ;;
    *) ISSUES+=("后置: XDG_SESSION_TYPE=${XDG_SESSION_TYPE}(要求 wayland)") ;;
  esac
  finish "发行版升级已提交(需重启进新部署复核)" "重启进新部署后复核:会话仍 wayland、显卡模块仍加载、桌面可用;不满意就在开机菜单选旧部署,或按 05-9 回滚到已固定的部署"
fi

check_all
finish "发行版升级前置核对完成(--check 零写,未改动任何系统状态)" "部署列表可读、当前部署已固定、baseline/ 有得备份、更新策略合规、目标分支已指定"
