#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:验收总控(scripts/linux/verify-all.sh)的**内置探测层**——条目表 scripts/verification-items.tsv 里「判定脚本」列写 builtin
#   的条目,按「编号」分派到本库的 probe_<编号>(该列是人读词表,不是文件路径;探测实现就在这一处)。
# 调用约定:总控先 source dbk-cli.sh,再 source 本库,并保证调用时下列**总控侧**的助手与变量已在作用域里
#   (bash 函数按动态作用域读调用方的变量,本库不自己定义它们):
#   助手:item <编号> <状态> <原因> <关联卡>   登记一行判定;
#         run_hook <命令或回放文件> [参数…]  把输出写进 HOOK_OUT、退出码写进 HOOK_RC(命令不存在 → 127、输出为空);
#         chk_cmd_all <编号> <卡> <标签> <命令> <分号分隔正则;全中才 PASS> [参数…];
#         avail <命令或路径>。
#   变量:SHARED(共享盘挂载点)、JRNL(journald 持久目录)、BASEDIR(baseline 目录)、GIT_ROOT(git 工作区)、DISK(受检磁盘)。
#   每个 probe_<编号> 接 <标签> <关联卡> 两个参数(标签来自条目表;卡用于登记,个别分支按状态改用处置卡)。
#   探测口径与库层返回值纪律同源:读不到系统状态一律登记「需人工」,绝不 fail-open 成 PASS。
# 本文件只定义函数:不设置 shell 选项、不执行动作;**末尾不加任何条件语句**(被 source 时返回非 0 会让带 set -e 的调用方静默退 1)。
# 夹具级验证,真机未跑(待核实文本:mokutil / timedatectl / fwupdmgr / smartctl / journalctl 的输出格式,取不到按需人工而非 FAIL)。

# A1:默认启动项仍是 Windows Boot Manager(efibootmgr -v 的 BootOrder 首位)。读不到 → 需人工。
probe_A1() {
  local bo h1
  run_hook "${DBK_EFIBOOTMGR:-efibootmgr}" -v
  if [ -z "$HOOK_OUT" ]; then
    item A1 manual "读不到 efibootmgr -v(需要 root);手动核对:sudo efibootmgr -v 的 BootOrder 首位" "$2"; return 0
  fi
  bo="$(printf '%s\n' "$HOOK_OUT" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
  h1="$(printf '%s\n' "$HOOK_OUT" | grep -E "^Boot${bo%%,*}\*?" | head -n1 || true)"
  case "$h1" in
    *Windows*Boot*Manager*|*Windows*启动管理器*) item A1 pass "BootOrder 首位仍是 Windows Boot Manager($h1)" "$2" ;;
    *) item A1 fail "BootOrder 首位不是 Windows Boot Manager(实际 ${h1:-空});处置见 07-9" "07-9" ;;
  esac
  return 0
}

# A5:fedora 条目位于 BootOrder 末位。读不到 → 需人工。
probe_A5() {
  local bo h2
  run_hook "${DBK_EFIBOOTMGR:-efibootmgr}" -v
  if [ -z "$HOOK_OUT" ]; then
    item A5 manual "读不到 efibootmgr -v;手动核对:Linux(Fedora)引导条目是否在 BootOrder 末位" "$2"; return 0
  fi
  bo="$(printf '%s\n' "$HOOK_OUT" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1)"
  h2="$(printf '%s\n' "$HOOK_OUT" | grep -E "^Boot${bo##*,}\*?" | head -n1 || true)"
  case "$h2" in
    *fedora*|*Fedora*|*ubuntu*|*Ubuntu*) item A5 pass "BootOrder 末位是 Linux 引导条目($h2)" "$2" ;;
    *) item A5 fail "BootOrder 末位不是 Linux 引导条目(实际 ${h2:-空});处置见 04-3" "$2" ;;
  esac
  return 0
}

# B1:会话类型为 wayland(取 XDG_SESSION_TYPE;取不到 → 需人工)。
probe_B1() {
  local st="${DBK_SESSION_TYPE:-${XDG_SESSION_TYPE:-}}"
  if [ -z "$st" ]; then item B1 manual "XDG_SESSION_TYPE 取不到;手动核对:echo \$XDG_SESSION_TYPE 应为 wayland" "$2"
  elif [ "$st" = wayland ]; then item B1 pass "会话类型 wayland" "$2"
  else item B1 fail "会话类型 $st(要求 wayland)" "$2"; fi
}

# B3:Secure Boot 保持开启(mokutil --sb-state)。
probe_B3() { chk_cmd_all B3 "$2" "Secure Boot 保持开启" "${DBK_MOKUTIL:-mokutil}" 'SecureBoot enabled' --sb-state; }

# B4:共享盘以 ntfs3 读写挂载且带 nofail(findmnt)。
probe_B4() { chk_cmd_all B4 "$2" "共享盘以 ntfs3 读写挂载且带 nofail" "${DBK_FINDMNT:-findmnt}" 'ntfs3;rw;nofail' -no SOURCE,FSTYPE,OPTIONS "$SHARED"; }

# B6:Secure Boot 密钥已注册(ublue 一次性 MOK 注册;mokutil --list-enrolled)。
probe_B6() { chk_cmd_all B6 "$2" "Secure Boot 密钥已注册(ublue 一次性 MOK 注册)" "${DBK_MOKUTIL:-mokutil}" 'ublue' --list-enrolled; }

# B8:六项 XDG 目录都指向共享盘下(逐项 xdg-user-dir)。命令缺失 → 需人工。
probe_B8() {
  local xu bad="" k
  xu="${DBK_XDG_USER_DIR:-xdg-user-dir}"
  if ! avail "$xu"; then item B8 manual "未找到 xdg-user-dir;手动核对:六项 XDG 目录都指向 $SHARED 下" "$2"; return 0; fi
  for k in DESKTOP DOCUMENTS DOWNLOAD PICTURES VIDEOS MUSIC; do
    run_hook "$xu" "$k"
    case "$(printf '%s' "$HOOK_OUT" | tail -n1)" in "$SHARED"/*) ;; *) bad="$bad $k=$(printf '%s' "$HOOK_OUT" | tail -n1)" ;; esac
  done
  if [ -n "$bad" ]; then item B8 fail "家目录重定向未生效:$bad;见 05-2" "$2"; else item B8 pass "六项 XDG 目录都指向 $SHARED 下" "$2"; fi
}

# B9:RTC 走 UTC。判据前强制 LC_ALL=C(timedatectl 会按 locale 输出本地化文本);中文口径正则作为回放件/异体输出的傍路。
probe_B9() { LC_ALL=C chk_cmd_all B9 "$2" "RTC 走 UTC" "${DBK_TIMEDATECTL:-timedatectl}" 'RTC in local TZ: no|RTC 在本地时区: *否'; }

# B11:fwupd 能识别设备(至少列出一项)。
probe_B11() { chk_cmd_all B11 "$2" "fwupd 能识别设备" "${DBK_FWUPDMGR:-fwupdmgr}" 'Device|设备|UEFI|NVMe|SSD|Firmware' get-devices; }

# E1:baseline 十一件产物齐全。
probe_E1() {
  local f miss=""
  for f in 00-firmware.md 01-partitions.txt 01-activation.md 02-preflight-report.md 02-firmware-entries.txt \
           02-partitions.txt 02-esp-backup/manifest.sha256 03-efi-layout.txt 04-first-boot.md 04-robustness.md 08-verification.md; do
    [ -e "$BASEDIR/$f" ] || miss="$miss $f"; done
  if [ -n "$miss" ]; then item E1 fail "baseline 产物缺失:$miss(见 baseline/README.md 命名规范)" "$2"
  else item E1 pass "baseline 十一件产物齐全($BASEDIR)" "$2"; fi
}

# E2:baseline/ 未入库(只允许 baseline/README.md 被追踪)。git 不可用或读不到工作区 → 需人工。
probe_E2() {
  local gs grc lt lrc
  if ! command -v git >/dev/null 2>&1; then
    item E2 manual "未找到 git;手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md" "$2"; return 0
  fi
  run_hook git -C "$GIT_ROOT" status --porcelain; gs="$HOOK_OUT"; grc="$HOOK_RC"
  run_hook git -C "$GIT_ROOT" ls-files baseline/
  lt="$(printf '%s\n' "$HOOK_OUT" | grep -v '^[[:space:]]*$' | grep -cv '^baseline/README.md$' || true)"; lrc="$HOOK_RC"
  if [ "$grc" -ne 0 ] || [ "$lrc" -ne 0 ]; then
    item E2 manual "git 读不到工作区($GIT_ROOT);手动核对:git status 不含 baseline/ 条目、git ls-files baseline/ 只列 README.md" "$2"
  elif printf '%s' "$gs" | grep -q 'baseline/'; then
    item E2 fail "baseline/ 内容混进了工作区:$(printf '%s' "$gs" | grep 'baseline/' | head -n3 | tr '\n' ' ' || true)" "$2"
  elif [ "$lt" -gt 0 ]; then item E2 fail "baseline/ 已被 git 追踪(只允许 baseline/README.md)" "$2"
  else item E2 pass "baseline/ 未入库(仅 README.md 被追踪)" "$2"; fi
}

# F4:journald 持久化(--list-boots 至少两次启动可回看)。目录不在 → FAIL(硬判据)。
probe_F4() {
  local nb
  run_hook "${DBK_JOURNALCTL:-journalctl}" --list-boots
  nb="$(printf '%s\n' "$HOOK_OUT" | grep -cE '^[[:space:]]*-?[0-9]+[[:space:]]' || true)"
  if [ ! -d "$JRNL" ]; then item F4 fail "journald 未持久化($JRNL 不存在);见 05-7" "$2"
  elif [ "${nb:-0}" -ge 2 ]; then item F4 pass "journalctl --list-boots 列出 $nb 次启动(可回看上一次启动)" "$2"
  else item F4 manual "journalctl --list-boots 只 ${nb:-0} 条;重启一次后复核(--check 时可能只有本次启动)" "$2"; fi
}

# F6:sshd 为 active(无需桌面会话即可 SSH)。
probe_F6() {
  run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active sshd
  case "$HOOK_OUT" in
    active) item F6 pass "sshd 为 active(无需桌面会话即可 SSH)" "$2" ;;
    "") item F6 manual "读不到 systemctl;手动核对:systemctl is-active sshd + 从另一台机器 ssh 登录" "$2" ;;
    *) item F6 fail "sshd 不是 active(实际:$HOOK_OUT);见 05-8" "$2" ;;
  esac
}

# F7:systemd-oomd active 且 zram 生效。
probe_F7() {
  local oomd zr
  run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active systemd-oomd; oomd="$HOOK_OUT"
  run_hook "${DBK_ZRAMCTL:-zramctl}"; zr="$HOOK_OUT"
  if [ -z "$oomd" ] || [ -z "$zr" ]; then item F7 manual "读不到 systemctl/zramctl;手动核对:systemd-oomd 为 active 且 zramctl 有 /dev/zram0" "$2"
  elif [ "$oomd" != active ]; then item F7 fail "systemd-oomd 不是 active(实际:${oomd:-空});见 05-6" "$2"
  elif printf '%s' "$zr" | grep -q zram; then item F7 pass "systemd-oomd active 且 zram 生效" "$2"
  else item F7 fail "zramctl 未见 /dev/zram0;见 05-6" "$2"; fi
}

# F8:smartd active 且 smartctl -H 报 PASSED。
probe_F8() {
  local smd
  run_hook "${DBK_SYSTEMCTL:-systemctl}" is-active smartd; smd="$HOOK_OUT"
  run_hook "${DBK_SMARTCTL:-smartctl}" -H "$DISK"
  if [ -z "$smd" ]; then item F8 manual "读不到 systemctl;手动核对:systemctl is-active smartd + smartctl -H $DISK 应报 PASSED" "$2"
  elif [ "$smd" != active ]; then item F8 fail "smartd 不是 active(实际:${smd:-空});见 05-8" "$2"
  elif printf '%s' "$HOOK_OUT" | grep -q PASSED; then item F8 pass "smartd active 且 smartctl -H $DISK 报 PASSED" "$2"
  else item F8 fail "smartctl -H $DISK 未报 PASSED:$(printf '%s' "$HOOK_OUT" | grep -iE 'health|result' | head -n1 || true);按硬件问题处理" "$2"; fi
}

# F9:fstab 非 root 条目都带 nofail,/boot/efi 不带。读不到 → 需人工。
probe_F9() {
  local badf
  badf="$(awk '!/^[[:space:]]*#/ && NF>=4 { if ($2=="/") next; if ($2=="/boot/efi") { if ($4 ~ /nofail/) print "ESP 行不应带 nofail" } else if ($4 !~ /nofail/) print "缺 nofail: " $2 }' "$FSTAB" 2>/dev/null || true)"
  if [ ! -r "$FSTAB" ]; then item F9 manual "读不到 $FSTAB;手动核对:非 root 条目都带 nofail,/boot/efi 不带" "$2"
  elif [ -n "$badf" ]; then item F9 fail "fstab 挂载选项不合判据:$(printf '%s' "$badf" | tr '\n' ' ')" "$2"
  else item F9 pass "fstab 非 root 条目均带 nofail,/boot/efi 未加 nofail" "$2"; fi
}
