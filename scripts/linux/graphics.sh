#!/usr/bin/env bash
# 对应卡:05-3
# 破坏性:1
# L4:显卡栈收敛(设计 4.5「显卡驱动」行、变体设计 3 节:rebase 到 ublue 的 NVIDIA 变体)。
# 用途:--check 只读判定当前部署是不是 ublue 的 NVIDIA 变体、nvidia 模块是否加载、会话是否 Wayland;
#   --apply(需 root 且需 --yes)执行一次 `rpm-ostree rebase <UBLUE_IMAGE>`,rebase 只写下一个部署,**需重启才生效**。
# 判据(--check,零写):① `rpm-ostree status` 可读(读不到 → 需人工);
#   ② 当前启动部署的镜像来源是 ublue NVIDIA 变体(含 `nvidia` 标记);
#   ③ `lsmod` 有 `nvidia`(rebase 后未重启时为「需人工」,不是失败);④ `XDG_SESSION_TYPE=wayland`(取不到 → 需人工)。
# MOK 注册不在本脚本内:rebase 后跑 `scripts/linux/graphics-mok.sh`(卡 05-3 的第二个脚本)。
# 为什么不能用 akmods:原子版 `rpm-ostree install` 时 akmods 不签名模块(上游 issue-tracker#499),且会卡内核升级
#   (#632);镜像内模块已预签名才是与「Secure Boot 全程开启、不自签密钥」一致的路(设计 3 节被否路径表)。
# 兜底:nouveau 是天然回滚点 —— 桌面起不来时在开机菜单选上一个部署,或 `scripts/linux/dbk-rollback.sh --rollback`;
#   绝不长按电源,用 REISUB(SysRq);驱动不认时顺序是「换更新内核 -> 换驱动版本 -> 才考虑发行版问题」。
# 退出码:0 PASS / 1 FAIL / 2 需人工 / 9 跳过 / 64 用法错误。夹具级验证,真机未跑。
# 用法: graphics.sh [--check|--apply] [--json] [--log <路径>] [--yes] [--step 05-3]
# 环境注入(夹具用):DBK_RPM_OSTREE / DBK_LSMOD / DBK_LSPCI / DBK_UBLUE_IMAGE 覆盖命令与镜像引用。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux/dbk-cli.sh disable=SC1091
. "$HERE/dbk-cli.sh"
dbk_enable_errtrap
dbk_parse_args "$@"
dbk_assert_step
dbk_log_default "graphics"

# 目标镜像:ublue 的 GNOME NVIDIA 变体。上游会改品牌名/通道名(变体设计 3 节「实施时须核实」),
# 故此处是可覆盖的占位符,真机执行前必须按官方文档核对。
UBLUE_IMAGE="${DBK_UBLUE_IMAGE:-ostree-image-signed:docker://ghcr.io/ublue-os/bluefin-nvidia:latest}"  # 待核实(以官方文档为准)
RPM_OSTREE="${DBK_RPM_OSTREE:-rpm-ostree}"       # 夹具注入用
LSMOD="${DBK_LSMOD:-lsmod}"
LSPCI="${DBK_LSPCI:-lspci}"

RUN_CMD=(); read -r -a RUN_CMD <<<"$RPM_OSTREE"
run_ostree() { "${RUN_CMD[@]}" "$@"; }

STATUS=""; ISSUES=(); MANUAL=()

# 读一次 rpm-ostree status:stdout+stderr 都收进变量(不吞输出);读不到就是「需人工」(脚本判不了)。
read_status() {
  if ! STATUS="$(run_ostree status 2>&1)"; then
    dbk_add_check "rpm-ostree status 读取失败($RPM_OSTREE): $(printf '%s' "$STATUS" | tr '\n' ' ')"
    dbk_exit 需人工 "取不到 rpm-ostree status($RPM_OSTREE);请人工执行 rpm-ostree status 核对当前部署来源"
  fi
  [ -n "$STATUS" ] || dbk_exit 需人工 "rpm-ostree status 无输出;请人工确认当前部署与镜像来源"
  return 0
}

# 当前启动部署的镜像引用行:rpm-ostree status 里带镜像来源的那一行(stock 形如 fedora:fedora/44/x86_64/silverblue,
# ublue 形如 ostree-image-signed:docker://ghcr.io/...);只做文本匹配,取不到不猜。
# 文本口径未在真机验证。
image_line() { printf '%s\n' "$STATUS" | grep -m1 -E 'docker://|ostree-image|fedora:' || true; }

judge() {
  ISSUES=(); MANUAL=()
  local img
  img="$(image_line)"
  if [ -n "$img" ]; then
    case "$img" in
      *nvidia*|*NVIDIA*) dbk_add_check "当前部署镜像来源已是 NVIDIA 变体: $(printf '%s' "$img" | sed 's/^[[:space:]]*//')" ;;
      *) ISSUES+=("当前部署镜像来源不是 NVIDIA 变体(实为: $(printf '%s' "$img" | sed 's/^[[:space:]]*//')):需 rebase 到 ublue 的 NVIDIA 变体") ;;
    esac
  else
    MANUAL+=("rpm-ostree status 未给出可识别的镜像来源行;请人工核对(目标镜像引用为占位符,须按官方文档核实)")
  fi
  if command -v "$LSMOD" >/dev/null 2>&1; then
    if "$LSMOD" 2>/dev/null | grep -qE '^nvidia([[:space:]]|_)'; then
      dbk_add_check "nvidia 模块已加载(lsmod)"
    else
      MANUAL+=("lsmod 未见 nvidia 模块:rebase/更新后未重启时为正常现象 —— 重启后重跑本脚本复核")
    fi
  fi
  local st="${XDG_SESSION_TYPE:-}"
  if [ "$st" = wayland ]; then
    dbk_add_check "XDG_SESSION_TYPE=wayland"
  elif [ -z "$st" ]; then
    MANUAL+=("取不到 XDG_SESSION_TYPE(登录桌面后在会话内重跑;期望 wayland)")
  else
    ISSUES+=("XDG_SESSION_TYPE=$st:期望 wayland;先查驱动加载与残留 nomodeset,再考虑重建会话")
  fi
  return 0
}

# 判据 → 退出码:有失败项 → FAIL;否则有判不了的 → 需人工;否则 PASS。
finish() {
  local msg="${1:-}" m
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    for m in "${ISSUES[@]}"; do dbk_add_check "失败项: $m"; done
    dbk_exit FAIL "$msg:有 ${#ISSUES[@]} 项判据未达成;逐条见 checks"
  fi
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    for m in "${MANUAL[@]}"; do dbk_add_check "需人工: $m"; done
    dbk_exit 需人工 "$msg:有 ${#MANUAL[@]} 项脚本判不了(多为 reboot 后才可判定);逐条见 checks"
  fi
  dbk_exit PASS "$msg:当前部署是 ublue NVIDIA 变体、nvidia 已加载且会话为 Wayland"
}

# 采集:显卡硬件与 nouveau 兜底说明(只读,失败不阻塞判定)
collect() {
  if command -v "$LSPCI" >/dev/null 2>&1; then
    local gpu; gpu="$("$LSPCI" -nn 2>/dev/null | grep -E 'VGA|3D' || true)"
    if [ -n "$gpu" ]; then dbk_add_check "显卡(lspci -nn): $(printf '%s' "$gpu" | tr '\n' ';' | sed 's/;*$//')"
    else dbk_add_check "lspci 未列出 VGA/3D 设备(受限环境或纯远程会话)"; fi
  fi
  dbk_add_check "nouveau 兜底: 桌面起不来时在开机菜单选上一个部署或 dbk-rollback.sh --rollback;不要长按电源(用 REISUB)"
  return 0
}

if [ "$DBK_MODE" = apply ]; then
  if [ "$(id -u)" -ne 0 ]; then
    dbk_add_check "--apply 需要 root(当前 uid=$(id -u))"
    dbk_exit FAIL "--apply 需要 root:sudo bash $0 --apply --yes(只想看结论就只跑 --check)"
  fi
  read_status; collect
  if out="$(run_ostree rebase "$UBLUE_IMAGE" 2>&1)"; then
    dbk_add_action "rpm-ostree rebase $UBLUE_IMAGE"
    dbk_mark_changed
    dbk_add_check "rebase 已提交: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"
  else
    dbk_add_check "失败项: rpm-ostree rebase $UBLUE_IMAGE 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    dbk_exit FAIL "rebase 失败:见 checks;镜像引用为占位符($UBLUE_IMAGE),先按官方文档核实镜像名与分支后再重跑"
  fi
  dbk_exit 需人工 "rebase 已提交但**需重启**才生效:重启后跑 scripts/linux/graphics-mok.sh --check 注册 MOK,再重跑本脚本复核(目标镜像引用 $UBLUE_IMAGE 标 # 待核实,须按官方文档核实)"
fi

read_status; collect; judge
finish "显卡栈核对完成(--check 零写)"
