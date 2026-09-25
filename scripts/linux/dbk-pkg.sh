#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:包管理助手(Fedora 44 Silverblue / rpm-ostree 分层语义):判断、分层安装系统级包。
# 契约真源:docs/design/06-atomic-restore-design.md 第 3 节(发行版薄接口层,四个接口之一);
#   docs/design/03-step-automation-design.md 第 6 节库文件行。文件名保持 dbk-pkg.sh(接口名不带发行版痕迹),
#   只换内部实现;Kubuntu 时代的 apt/dpkg 语义已随 2026-09-25 回切废弃。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-log.sh 的 log 或 dbk-cli.sh 的 dbk_obs),然后使用:
#   pkg_installed <包>      该包已装(基础镜像或分层,含已提交未重启的)→ 0;未装 → 1
#   pkg_update              原子版 no-op:返回 0,打印"原子版无 apt update 等价动作"(rpm-ostree 自动同步元数据)
#   pkg_install <包...>     0 = 分层安装已提交(重启后生效);9 = 按 SKIP_PKG 跳过;1 = 失败(原因已落日志)
#   pkg_ensure <包...>      已装 → 0;否则 pkg_install;失败再补一行"硬前置"提示;含 --now → 2(需人工)
#   pkg_needs_reboot        0 = 存在未生效的 staged 分层改动(步骤脚本据此提示重启);1 = 无
# 关键语义(原子版,与 Kubuntu 相反):rpm-ostree 分层安装**写进下一部署、重启后才生效**,装完当前系统仍看不到;
#   因此 pkg_installed 先查 rpm-ostree status --json 的 deployments[].packages(含已提交分层),再退回 rpm -q。
# DBK_SKIP_PKG/DBK_SKIP_APT=1 只跳过分层动作,判定(pkg_installed)照做,用于无网络/无 ostree 的静态校验。
# 注意:SKIP_PKG 不在这里固化默认值(源文件时赋值会先于调用方赋值,顺序难以保证),而在函数内实时读取。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE 覆盖 rpm-ostree 命令。
# 待核实(以官方文档为准):rpm-ostree status --json 的 deployments[].packages 数组与 staged 布尔字段名。

PKG_CMD="${DBK_RPM_OSTREE:-rpm-ostree}"   # 夹具注入用

# 库层日志:优先用可观测层的 dbk_obs(同时落 stderr 与 --log),否则退回 dbk-log.sh 的 log,再退回 stderr。
# 不吞 stderr:调用方既没装 dbk-obs 也没装 dbk-log 时,失败信息仍要打到 stderr。
_pkg_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# <包名>:rpm-ostree status --json 的 deployments[].packages 命中 → 0;否则 rpm -q 命中 → 0;都不中 → 1。
pkg_installed() {
  local want="${1:-}" out
  [ -n "$want" ] || return 1
  if out="$(command "$PKG_CMD" status --json 2>/dev/null)" \
    && printf '%s' "$out" | grep -qF "\"$want\""; then
    return 0
  fi
  command rpm -q "$want" >/dev/null 2>&1 && return 0
  return 1
}

# 原子版 no-op:rpm-ostree 无 apt-get update 的等价动作(元数据随 status/install 自动同步)。
pkg_update() {
  _pkg_note "原子版无 apt update 等价动作(rpm-ostree 自动同步元数据)"
  return 0
}

# 分层安装:提交后写进下一部署,重启后才生效。
pkg_install() {
  local skip out st
  [ "$#" -ge 1 ] || { _pkg_note "错误: pkg_install 缺少包名"; return 1; }
  skip="${SKIP_PKG:-${DBK_SKIP_PKG:-${DBK_SKIP_APT:-0}}}"
  if [ "$skip" = 1 ]; then _pkg_note "DBK_SKIP_PKG=1:跳过分层安装 $*"; return 9; fi
  command -v "${PKG_CMD%% *}" >/dev/null 2>&1 || { _pkg_note "错误: 无 $PKG_CMD,无法分层安装 $*"; return 1; }
  out="$(command "$PKG_CMD" install "$@" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then _pkg_note "rpm-ostree install $*: 分层安装已提交,重启后生效"; return 0; fi
  _pkg_note "错误: rpm-ostree install $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# 先查后装:已装则直接 0(重跑幂等);失败时给出可直接照做的硬前置命令。
# 原子版没有"立即生效"的安装,--now 无法兑现 → 返回 2(需人工),由调用方提示重启。
pkg_ensure() {
  local p st
  for p in "$@"; do
    if [ "$p" = --now ]; then
      _pkg_note "原子版:分层安装无法立即生效,--now 不可用;请重启后复核(pkg_needs_reboot)"
      return 2
    fi
  done
  [ "$#" -ge 1 ] || { _pkg_note "错误: pkg_ensure 缺少包名"; return 1; }
  for p in "$@"; do
    if pkg_installed "$p"; then _pkg_note "$p 已安装,跳过分层安装"; continue; fi
    pkg_install "$p"; st=$?
    if [ "$st" -eq 1 ]; then _pkg_note "硬前置: 必须先执行 sudo rpm-ostree install $p 再重跑本脚本"; fi
    [ "$st" -eq 0 ] || return "$st"
  done
  return 0
}

# 0 = 有未生效的 staged 分层改动(下一次重启才应用);1 = 无。供步骤脚本提示"重启后生效"。
pkg_needs_reboot() {
  command "$PKG_CMD" status --json 2>/dev/null | grep -q '"staged"[[:space:]]*:[[:space:]]*true'
}
