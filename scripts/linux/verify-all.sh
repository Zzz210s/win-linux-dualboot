#!/usr/bin/env bash
# 验收总控(Kubuntu 侧;执行器:不进卡映射表、不登记 steps.tsv):按 docs/08-verification.md 的 A-F 六组
#   逐项判定——能自动的调既有步骤脚本的 --check/--list 或读系统状态,不能自动的记「需人工」并给手动核对步骤。
#   **绝不执行任何 --apply**:只允许 --check 与只读子命令,收到 --apply/--rollback/--pin/--unpin → 64 且一个子脚本
#   都不调。汇总只在 --apply 时落盘 <out-dir>/08-verification.md(每台设备副本,含「已知例外」表与结论行);
#   --check 零写。退出码:0 无自动失败且无待确认人工项 / 1 有自动失败 / 2 有需人工项(加 --confirm-manual
#   表示人工项已按清单逐条核对完成,不再计入退出码)/ 64 用法错误。
# 用法: verify-all.sh [--check|--apply] [--out-dir <目录>] [--confirm-manual] [--json] [--log <路径>]
# 夹具注入(真机不需要):DBK_EFIBOOTMGR/DBK_FINDMNT/DBK_MOKUTIL/DBK_TIMEDATECTL/DBK_FWUPDMGR/DBK_SYSTEMCTL/DBK_ZRAMCTL/
#   DBK_SMARTCTL/DBK_JOURNALCTL/DBK_XDG_USER_DIR、DBK_SESSION_TYPE、DBK_STEP_ROOT/DBK_GIT_ROOT/DBK_BASELINE_DIR/
#   DBK_FSTAB/DBK_JOURNAL_DIR/DBK_SHARED_MNT/DBK_DISK;白名单依据=设计 03 第 6 节「验收六组」。待核实(以官方文档为准):
#   mokutil/timedatectl/fwupdmgr/smartctl/dpkg-query 输出文本未在真机验证,取不到时按「需人工」而非 FAIL。
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$SRC/../.." && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$SRC/dbk-cli.sh"
OUTDIR="$ROOT/baseline"; CONFIRM=0; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) [ -n "${2:-}" ] || { dbk_usage; dbk_note "用法错误: --out-dir 缺取值(输出目录)"; exit "$DBK_USAGE"; }; OUTDIR="$2"; shift 2 ;;
    --out-dir=*) OUTDIR="${1#*=}"; shift ;;
    --confirm-manual) CONFIRM=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
dbk_parse_args ${ARGS[@]+"${ARGS[@]}"}
DBK_STEP="08-A-F"
if [ "$DBK_MODE" = apply ]; then dbk_log_default "verify-all"; fi
STEP_ROOT="${DBK_STEP_ROOT:-$ROOT}"; GIT_ROOT="${DBK_GIT_ROOT:-$ROOT}"; BASEDIR="${DBK_BASELINE_DIR:-$ROOT/baseline}"
FSTAB="${DBK_FSTAB:-/etc/fstab}"; JRNL="${DBK_JOURNAL_DIR:-/var/log/journal}"
SHARED="${DBK_SHARED_MNT:-/mnt/shared}"; DISK="${DBK_DISK:-/dev/nvme0n1}"
SUMMARY="$OUTDIR/08-verification.md"; HOST="${DBK_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
G=""; R=(); n_pass=0; n_fail=0; n_manual=0; n_skip=0; HOOK_OUT=""; HOOK_RC=0; STEP_OUT=""; STEP_RC=0
tag_of() { case "$1" in pass) printf PASS ;; fail) printf FAIL ;; manual) if [ "$CONFIRM" -eq 1 ]; then printf '需人工(已确认)'; else printf 需人工; fi ;; *) printf 跳过 ;; esac; }
item() {   # <编号> <结论> <原因> <关联卡>;G = 当前组(记录里把原因内的 | 换成全角,避免拆列歧义)
  R+=("$1|$G|$2|${3//|/／}|$4")
  case "$2" in fail) n_fail=$((n_fail + 1)) ;; manual) n_manual=$((n_manual + 1)) ;; pass) n_pass=$((n_pass + 1)) ;; *) n_skip=$((n_skip + 1)) ;; esac
  if [ "${DBK_JSON:-0}" -ne 1 ]; then printf '[%s] %s %s\n' "$(tag_of "$2")" "$1" "$3"; fi; }
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
  local id="$1" card="$2" lab="$3" spec="$4" res="$5" re miss=""; shift 5
  run_hook "$spec" "$@"
  for re in ${res//;/ }; do printf '%s' "$HOOK_OUT" | grep -qE "$re" || miss="$miss $re"; done
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
G=A   # ===== A 引导安全组 =====
run_hook "${DBK_EFIBOOTMGR:-efibootmgr}" -v
if [ -z "$HOOK_OUT" ]; then
  item A1 manual "读不到 efibootmgr -v(需要 root);手动核对:sudo efibootmgr -v 的 BootOrder 首位" "07-7"
  item A5 manual "读不到 efibootmgr -v;手动核对:ubuntu 条目是否在 BootOrder 末位" "04-3"
else
  BO="$(printf '%s\n' "$HOOK_OUT" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
  H1="$(printf '%s\n' "$HOOK_OUT" | grep -E "^Boot${BO%%,*}\*?" | head -n1 || true)"; H2="$(printf '%s\n' "$HOOK_OUT" | grep -E "^Boot${BO##*,}\*?" | head -n1 || true)"
  case "$H1" in *Windows*Boot*Manager*|*Windows*启动管理器*) item A1 pass "BootOrder 首位仍是 Windows Boot Manager($H1)" "07-7" ;;
    *) item A1 fail "BootOrder 首位不是 Windows Boot Manager(实际 ${H1:-空});处置见 07-9" "07-9" ;; esac
  case "$H2" in *ubuntu*|*Ubuntu*) item A5 pass "ubuntu 条目位于 BootOrder 末位($H2)" "04-3" ;;
    *) item A5 fail "BootOrder 末位不是 ubuntu 条目(实际 ${H2:-空});处置见 04-3" "04-3" ;; esac
fi
item A2 manual "连续重启 3 次(不按键、不选菜单),每次都自动进 Windows" "03-8"
item A3 manual "Windows 侧跑 verify-baseline.ps1 -BaselineDir baseline 看 ② 行是否为「通过」(\\EFI\\Microsoft\\ 逐文件比对)" "07-7"
chk_step A7 "07-7" "两个 ESP 互不干扰(两块 ESP 内容完整 + BootOrder 首位;逐文件比对见 A3)" scripts/linux/verify-l3.sh --check
item A4 manual "Windows 管理员会话 bcdedit /enum {bootmgr} 的 path 与基线逐字一致" "07-7"
item A6 manual "复核全部执行记录:没有任何一次 efibootmgr -o / displayorder 调整永久顺序" "07-7"
item A8 manual "可撤除性演练:另存 \\EFI\\ubuntu\\ 后删除该子树,连续重启 3 次应自动进 Windows,再还原复测" "07-8"
G=B   # ===== B 系统功能组 =====
ST="${DBK_SESSION_TYPE:-${XDG_SESSION_TYPE:-}}"
if [ -z "$ST" ]; then item B1 manual "XDG_SESSION_TYPE 取不到;手动核对:echo \$XDG_SESSION_TYPE 应为 wayland" "05-12"
elif [ "$ST" = wayland ]; then item B1 pass "会话类型 wayland" "05-12"
else item B1 fail "会话类型 $ST(要求 wayland)" "05-12"; fi
chk_step B2 "05-3" "GPU 驱动与 nvidia 模块签名" scripts/linux/check-signature.sh --check
chk_cmd_all B3 "07-7" "Secure Boot 保持开启" "${DBK_MOKUTIL:-mokutil}" 'SecureBoot enabled' --sb-state
chk_cmd_all B4 "05-1" "共享盘以 ntfs3 读写挂载且带 nofail" "${DBK_FINDMNT:-findmnt}" 'ntfs3;rw;nofail' -no SOURCE,FSTYPE,OPTIONS "$SHARED"
run_hook "${DBK_DPKG_QUERY:-dpkg-query}" -l 'nvidia-driver-*'
if ! avail "${DBK_DPKG_QUERY:-dpkg-query}"; then item B5 manual "未找到 dpkg-query;手动核对:dpkg -l 'nvidia-driver-*' 有已安装的官方驱动包" "05-3"
elif printf '%s' "$HOOK_OUT" | grep -qE '^ii[[:space:]]+nvidia-driver'; then item B5 pass "显卡驱动来源为 Ubuntu 官方包:$(printf '%s\n' "$HOOK_OUT" | grep -m1 -E '^ii[[:space:]]+nvidia-driver' | cut -c1-100 || true)" "05-3"
else item B5 fail "没有已安装的 nvidia-driver-* 官方包;见 05-3(不用 NVIDIA 显卡的设备可记为已知例外)" "05-3"; fi
chk_step B6 "05-14" "snap 零残留(snap list 空 + dpkg -l snapd 无输出)" scripts/linux/step-snap-free.sh --check
item B7 manual "跨系统双向可见性:Windows 写 D:\\Shared\\dbk-verify-win.txt -> Linux 读到;反向再测一次" "05-1"
XU="${DBK_XDG_USER_DIR:-xdg-user-dir}"; B8BAD=""
if ! avail "$XU"; then item B8 manual "未找到 xdg-user-dir;手动核对:六项 XDG 目录都指向 $SHARED 下" "05-2"
else
  for k in DESKTOP DOCUMENTS DOWNLOAD PICTURES VIDEOS MUSIC; do run_hook "$XU" "$k"
    case "$(printf '%s' "$HOOK_OUT" | tail -n1)" in "$SHARED"/*) ;; *) B8BAD="$B8BAD $k=$(printf '%s' "$HOOK_OUT" | tail -n1)" ;; esac; done
  if [ -n "$B8BAD" ]; then item B8 fail "家目录重定向未生效:$B8BAD;见 05-2" "05-2"; else item B8 pass "六项 XDG 目录都指向 $SHARED 下" "05-2"; fi; fi
chk_cmd_all B9 "05-4" "RTC 走 UTC" "${DBK_TIMEDATECTL:-timedatectl}" 'RTC in local TZ: no'
item B10 manual "切换系统后蓝牙无需重新配对(三趟往返都能直连)" "05-5"
chk_cmd_all B11 "05-12" "fwupd 能识别设备" "${DBK_FWUPDMGR:-fwupdmgr}" 'Device|设备|UEFI|NVMe|SSD|Firmware' get-devices
G=C   # ===== C 双系统切换组(需实机切换) =====
item C1 manual "从 Windows 用 set-bootnext.ps1 或固件菜单键一次性进 Linux" "05-11"
item C2 manual "一次性入口用掉后再重启应自动回 Windows,且 BootOrder 与基线逐字一致" "05-11"
item C3 manual "切换 3 轮后 A1/A3/A4(必要时 A5)复检仍成立" "07-7"
G=D   # ===== D 可撤除性组(需实机演练/真做) =====
item D1 manual "按 L5 五步顺序完整推演(参考设备真做一次);参考设备不做即该设备 D 组不成立" "07-9"
item D2 manual "结束后固件条目与实际状态一致、BootOrder 首位仍是 Windows Boot Manager" "07-12"
item D3 manual "Windows 侧逐项核对:六个已知文件夹与游戏库都在 D:,C: 不含用户数据" "03-3"
item D4 manual "原地重装两法各推演一次(参考设备至少真做一法:只格 C:,或只格 root)" "07-4"
item D5 manual "重装后 A 组四条不变量复检通过(A3 按预期差异口径判读)" "07-4"
item D6 manual "非重装逃生路径:从 02-esp-backup 还原 \\EFI\\Microsoft\\ 并 bcdboot 重建后可正常启动" "07-6"
G=E   # ===== E 记录组 =====
MISS=""; for f in 00-firmware.md 01-partitions.txt 01-activation.md 02-preflight-report.md 02-firmware-entries.txt 02-partitions.txt 02-esp-backup/manifest.sha256 03-efi-layout.txt 04-first-boot.md 04-robustness.md 08-verification.md; do
  [ -e "$BASEDIR/$f" ] || MISS="$MISS $f"; done
if [ -n "$MISS" ]; then item E1 fail "baseline 产物缺失:$MISS(见 baseline/README.md 命名规范)" "03-9"
else item E1 pass "baseline 十一件产物齐全($BASEDIR)" "03-9"; fi
if ! command -v git >/dev/null 2>&1; then item E2 manual "未找到 git;手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md" "03-9"
else
  run_hook git -C "$GIT_ROOT" status --porcelain; GS="$HOOK_OUT"; GRC="$HOOK_RC"
  run_hook git -C "$GIT_ROOT" ls-files baseline/; LT="$(printf '%s\n' "$HOOK_OUT" | grep -v '^[[:space:]]*$' | grep -cv '^baseline/README.md$' || true)"; LRC="$HOOK_RC"
  if [ "$GRC" -ne 0 ] || [ "$LRC" -ne 0 ]; then item E2 manual "git 读不到工作区($GIT_ROOT);手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md" "03-9"
  elif printf '%s' "$GS" | grep -q 'baseline/'; then item E2 fail "baseline/ 内容混进了工作区:$(printf '%s' "$GS" | grep 'baseline/' | head -n3 | tr '\n' ' ' || true)" "03-9"
  elif [ "$LT" -gt 0 ]; then item E2 fail "baseline/ 已被 git 追踪(只允许 baseline/README.md)" "03-9"
  else item E2 pass "baseline/ 未入库(仅 README.md 被追踪)" "03-9"; fi
fi
item E3 manual "本次与设备参数表的偏差已回写 baseline/ 或 00-overview.md 的偏离项处置表" "07-7"
item E4 manual "所有未勾选项都整理成已知例外(条目/原因/影响面/是否阻塞/后续动作)" "08"
item E5 manual "至少一台设备 A-F 全绿(或例外都不阻塞),方可称参考实现" "08"
G=F   # ===== F 健壮性组 =====
item F1 manual "包级回退演练(真做一次):rollback-pkg.sh --list <包> -> --apply --pkg <包> --version <旧版本> --yes -> 复测 -> --unhold;并确认 D: 数据不受影响" "05-9"
item F3 manual "原地重装演练(参考设备至少真做一法:只格 C: 或只格 root):装完复检 A 组四条不变量,数据在 D: 不受影响" "07-4"
chk_step F2 "05-9" "包级回退可用(apt-mark hold 清单 + apt 历史可读)" scripts/linux/rollback-pkg.sh --check
run_hook "${DBK_JOURNALCTL:-journalctl}" --list-boots
NB="$(printf '%s\n' "$HOOK_OUT" | grep -cE '^[[:space:]]*-?[0-9]+[[:space:]]' || true)"
if [ ! -d "$JRNL" ]; then item F4 fail "journald 未持久化($JRNL 不存在);见 05-7" "05-7"
elif [ "${NB:-0}" -ge 2 ]; then item F4 pass "journalctl --list-boots 列出 $NB 次启动(可回看上一次启动)" "05-7"
else item F4 manual "journalctl --list-boots 只 ${NB:-0} 条;重启一次后复核(--check 时可能只有本次启动)" "05-7"; fi
chk_step F5 "05-7" "更新策略只 check/download,不自动应用与重启" scripts/linux/set-updates.sh --check
run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active sshd
case "$HOOK_OUT" in active) item F6 pass "sshd 为 active(无需桌面会话即可 SSH)" "05-8" ;;
  "") item F6 manual "读不到 systemctl;手动核对:systemctl is-active sshd + 从另一台机器 ssh 登录" "05-8" ;;
  *) item F6 fail "sshd 不是 active(实际:$HOOK_OUT);见 05-8" "05-8" ;; esac
run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active systemd-oomd; OOMD="$HOOK_OUT"; run_hook "${DBK_ZRAMCTL:-zramctl}"; ZR="$HOOK_OUT"
if [ -z "$OOMD" ] || [ -z "$ZR" ]; then item F7 manual "读不到 systemctl/zramctl;手动核对:systemd-oomd 为 active 且 zramctl 有 /dev/zram0" "05-6"
elif [ "$OOMD" != active ]; then item F7 fail "systemd-oomd 不是 active(实际:${OOMD:-空});见 05-6" "05-6"
elif printf '%s' "$ZR" | grep -q zram; then item F7 pass "systemd-oomd active 且 zram 生效" "05-6"
else item F7 fail "zramctl 未见 /dev/zram0;见 05-6" "05-6"; fi
run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active smartd; SMD="$HOOK_OUT"; run_hook "${DBK_SMARTCTL:-smartctl}" -H "$DISK"
if [ -z "$SMD" ]; then item F8 manual "读不到 systemctl;手动核对:systemctl is-active smartd + smartctl -H $DISK 应报 PASSED" "05-8"
elif [ "$SMD" != active ]; then item F8 fail "smartd 不是 active(实际:${SMD:-空});见 05-8" "05-8"
elif printf '%s' "$HOOK_OUT" | grep -q PASSED; then item F8 pass "smartd active 且 smartctl -H $DISK 报 PASSED" "05-8"
else item F8 fail "smartctl -H $DISK 未报 PASSED:$(printf '%s' "$HOOK_OUT" | grep -iE 'health|result' | head -n1 || true);按硬件问题处理" "05-8"; fi
BADF="$(awk '!/^[[:space:]]*#/ && NF>=4 { if ($2=="/") next; if ($2=="/boot/efi") { if ($4 ~ /nofail/) print "ESP 行不应带 nofail" } else if ($4 !~ /nofail/) print "缺 nofail: " $2 }' "$FSTAB" 2>/dev/null || true)"
if [ ! -r "$FSTAB" ]; then item F9 manual "读不到 $FSTAB;手动核对:非 root 条目都带 nofail,/boot/efi 不带" "05-1"
elif [ -n "$BADF" ]; then item F9 fail "fstab 挂载选项不合判据:$(printf '%s' "$BADF" | tr '\n' ' ')" "05-1"
else item F9 pass "fstab 非 root 条目均带 nofail,/boot/efi 未加 nofail" "05-1"; fi
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
  { printf '# 验收汇总:A-F 六组逐项判定\n\n- 设备:%s\n- 判定侧:Linux(Kubuntu)\n- 生成时间:%s\n- 判定脚本:%s\n- 依据:%s\n\n' \
      "$HOST" "$(date '+%F %T%z')" '`scripts/linux/verify-all.sh`(执行器,不进卡映射表)' '`docs/08-verification.md`(唯一判据)'
    printf '## 逐项结果\n\n| 项 | 组 | 结论 | 原因 | 关联卡 |\n|---|---|---|---|---|\n'
    for r in "${R[@]}"; do IFS='|' read -r i g s m c <<<"$r"; printf '| %s | %s | %s | %s | %s |\n' "$i" "$g" "$(tag_of "$s")" "$(printf '%s' "$m" | sed 's/|/\\|/g')" "$c"; done
    printf '\n## 失败项\n\n'
    for r in "${R[@]}"; do IFS='|' read -r i g s m c <<<"$r"; if [ "$s" = fail ]; then printf -- '- %s %s(关联卡 %s)\n' "$i" "$m" "$c"; fi; done
    if [ "$n_fail" -eq 0 ]; then printf '（无）\n'; fi
    printf '\n## 已知例外\n\n未通过项的唯一合法归宿;逐条填写条目/原因/影响面/是否阻塞/后续动作,无例外时保留(无)。\n\n'
    printf '| 条目 | 原因 | 影响面 | 是否阻塞 | 后续动作 |\n|---|---|---|---|---|\n| （无） |  |  |  |  |\n\n## 结论\n\n结论: %s\n' "$CONCL"
  } >"$SUMMARY.new" && mv "$SUMMARY.new" "$SUMMARY"
  printf '汇总已写:%s\n' "$SUMMARY" >&2
  if [ -n "${DBK_LOG:-}" ]; then dbk_log_write "验收汇总已写:$SUMMARY;结论:$CONCL"; fi
fi
case "$OVER" in fail) exit "$DBK_FAIL" ;; manual) exit "$DBK_MANUAL" ;; *) exit "$DBK_PASS" ;; esac
