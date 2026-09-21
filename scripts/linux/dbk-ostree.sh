#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:分层安装助手(Fedora Silverblue 原子版):用 rpm-ostree 判断/安装系统级包。
# 契约真源:docs/design/03-step-automation-design.md 第 6 节库文件行;docs/design/02-fedora-atomic-variant-design.md 第 8 节
#   (旧分层安装库经两次改名后定名 `dbk-ostree.sh`;改名经过见设计文档的变更历史,不在本文件里复写旧文件名)。
# 调用约定:调用方先 source dbk-log.sh(提供 log),并按需在调用前设置 SKIP_OSTREE(0/1;通常取自 DBK_SKIP_OSTREE,
#   兼容旧名 DBK_SKIP_OSTREE / DBK_SKIP_APT),然后使用:
#   pkg_installed <包>      该包已在当前部署里(分层安装过)→ 0
#   pkg_install <包...>     0 = 已请求分层安装;9 = 按 SKIP_OSTREE 跳过;1 = 失败(原因已落日志)
#   pkg_ensure <包> [补救]   已装 → 0;否则 pkg_install;失败再补一行"硬前置"提示
#   pkg_reboot_hint        打印"分层安装需重启"的统一提示(调用方在成功路径上调用)
# 关键语义(设计 4.5 / 02 设计 4 节):rpm-ostree install 只是把包写进**下一部署**,当前运行的部署不变 ——
#   装完必须重启才生效;重复安装同一包时 rpm-ostree 以非零退出并说明已存在,本库把这种情形归一成 0(重跑幂等)。
# DBK_SKIP_OSTREE=1 只跳过 rpm-ostree install(其余判定与文件动作照做),用于无网络/无 rpm-ostree 的静态校验。
# 注意:SKIP_OSTREE 不在这里固化默认值(源文件时赋值会先于调用方赋值,顺序难以保证),而在函数内实时读取。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail)。
# 夹具级验证,真机未跑。

# 分层安装列表的来源:rpm-ostree status --json 的 deployments[*].requested-packages / packages(字符串数组)。
# 无 jq 依赖:直接在 JSON 文本里做包名的整词匹配(包名出现在带引号的字符串里);JSON 不可用时退回文本输出。
# 未在真机验证(以官方文档与 rpm-ostree 实际输出为准):# 待核实(以官方文档为准)。
pkg_installed() {
  local pkg="${1:-}" json txt
  [ -n "$pkg" ] || return 1
  command -v rpm-ostree >/dev/null 2>&1 || return 1
  json="$(rpm-ostree status --json 2>/dev/null || true)"
  if [ -n "$json" ]; then
    printf '%s' "$json" | grep -qF "\"$pkg\"" && return 0
    return 1
  fi
  txt="$(rpm-ostree status 2>/dev/null || true)"
  [ -n "$txt" ] || return 1
  printf '%s' "$txt" | grep -qE "(^|[^A-Za-z0-9._+-])${pkg}([^A-Za-z0-9._+-]|$)" && return 0
  return 1
}

# 分层安装需重启的统一提示:调用方在 pkg_install/pkg_ensure 成功(0)后调用;跳过(9)时不必调用。
pkg_reboot_hint() {
  log "提示: 分层安装需**重启**才生效(rpm-ostree install 只把包写进下一部署,当前运行的部署不变)"
  return 0
}

pkg_install() {
  local out st skip
  [ "$#" -ge 1 ] || { log "错误: pkg_install 缺少包名"; return 1; }
  skip="${SKIP_OSTREE:-${DBK_SKIP_OSTREE:-${DBK_SKIP_APT:-0}}}"
  if [ "$skip" = 1 ]; then log "DBK_SKIP_OSTREE=1:跳过 rpm-ostree install $*"; return 9; fi
  command -v rpm-ostree >/dev/null 2>&1 || { log "错误: 无 rpm-ostree,无法分层安装 $*"; return 1; }
  out="$(rpm-ostree install "$@" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then
    log "rpm-ostree install $*: 分层安装成功(需重启后生效)"
    return 0
  fi
  # 重复安装:rpm-ostree 对已在部署里的包以非零退出;识别出该情形按幂等成功处理
  case "$out" in
    *"already requested"*|*"already installed"*|*"is already"*)
      log "rpm-ostree install $*: 该包已在部署中(重跑跳过,仍按需重启)"
      return 0 ;;
  esac
  log "错误: rpm-ostree install $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# 先查后装:已分层安装则直接 0(重跑不重复写部署);失败时给出可直接照做的硬前置命令。
pkg_ensure() {
  local pkg="${1:-}" hint="${2:-}" st
  [ -n "$pkg" ] || { log "错误: pkg_ensure 缺少包名"; return 1; }
  if pkg_installed "$pkg"; then log "$pkg 已分层安装,跳过 rpm-ostree install"; return 0; fi
  pkg_install "$pkg"; st=$?
  if [ "$st" -eq 1 ]; then log "硬前置: 必须先执行 ${hint:-sudo rpm-ostree install $pkg && sudo systemctl reboot} 再重跑本脚本"; fi
  return "$st"
}
