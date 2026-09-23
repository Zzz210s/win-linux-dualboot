#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:包管理助手(Kubuntu 26.04 LTS / apt + dpkg 语义):判断、安装系统级包。
# 契约真源:docs/design/03-step-automation-design.md 第 6 节库文件行;docs/design/04-kubuntu-variant-design.md
#   第 6 节(脚本与文档影响面:新增 dbk-pkg.sh,apt/dpkg 语义)。原子版(已废弃)的 dbk-ostree.sh 已删除。
# 调用约定:调用方先 source dbk-log.sh(提供 log),并按需在调用前设置 SKIP_PKG(0/1;通常取自 DBK_SKIP_PKG,
#   兼容旧名 DBK_SKIP_APT),然后使用:
#   pkg_installed <包>      该包已安装(dpkg-query -W 的 Status 含 install ok installed)→ 0
#   pkg_install <包...>     0 = 安装成功;9 = 按 SKIP_PKG 跳过;1 = 失败(原因已落日志)
#   pkg_ensure <包> [补救]   已装 → 0;否则 pkg_install;失败再补一行"硬前置"提示
#   pkg_update              0 = apt-get update 成功;9 = 按 SKIP_PKG 跳过;1 = 失败(调用方按需显式调用)
# 关键语义(与旧分层安装助手的区别):apt 装包**立即生效**,没有"写进下一部署、需重启"这回事;
#   也**不自动 apt update** —— 仓库刚改动(如新增 Mozilla 源)时由调用方显式调 pkg_update。
# DBK_SKIP_PKG/DBK_SKIP_APT=1 只跳过 apt 动作,判定(pkg_installed)照做,用于无网络/无 apt 的静态校验。
# 注意:SKIP_PKG 不在这里固化默认值(源文件时赋值会先于调用方赋值,顺序难以保证),而在函数内实时读取。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_APT_GET / DBK_DPKG_QUERY 覆盖命令。
# 待核实(以官方文档为准):dpkg-query 的 ${Status} 文本与 apt-get install 的幂等返回码未在真机验证。

APT_GET_DEFAULT="${DBK_APT_GET:-apt-get}"       # 夹具注入用
DPKG_QUERY_DEFAULT="${DBK_DPKG_QUERY:-dpkg-query}"

pkg_installed() {
  local pkg="${1:-}" st
  [ -n "$pkg" ] || return 1
  command -v "$DPKG_QUERY_DEFAULT" >/dev/null 2>&1 || return 1
  st="$("$DPKG_QUERY_DEFAULT" -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  case "$st" in *"install ok installed"*) return 0 ;; esac
  return 1
}

pkg_update() {
  local out st skip
  skip="${SKIP_PKG:-${DBK_SKIP_PKG:-${DBK_SKIP_APT:-0}}}"
  if [ "$skip" = 1 ]; then log "DBK_SKIP_PKG=1:跳过 apt-get update"; return 9; fi
  command -v "${APT_GET_DEFAULT%% *}" >/dev/null 2>&1 || { log "错误: 无 $APT_GET_DEFAULT,无法 apt-get update"; return 1; }
  out="$($APT_GET_DEFAULT update 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then log "apt-get update: 仓库索引已更新"; return 0; fi
  log "错误: apt-get update 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

pkg_install() {
  local out st skip
  [ "$#" -ge 1 ] || { log "错误: pkg_install 缺少包名"; return 1; }
  skip="${SKIP_PKG:-${DBK_SKIP_PKG:-${DBK_SKIP_APT:-0}}}"
  if [ "$skip" = 1 ]; then log "DBK_SKIP_PKG=1:跳过 apt-get install $*"; return 9; fi
  command -v "${APT_GET_DEFAULT%% *}" >/dev/null 2>&1 || { log "错误: 无 $APT_GET_DEFAULT,无法安装 $*"; return 1; }
  out="$($APT_GET_DEFAULT install -y --no-install-recommends "$@" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then log "apt-get install $*: 安装成功(立即生效,无需重启)"; return 0; fi
  log "错误: apt-get install $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# 先查后装:已装则直接 0(重跑幂等);失败时给出可直接照做的硬前置命令。
pkg_ensure() {
  local pkg="${1:-}" hint="${2:-}" st
  [ -n "$pkg" ] || { log "错误: pkg_ensure 缺少包名"; return 1; }
  if pkg_installed "$pkg"; then log "$pkg 已安装,跳过 apt-get install"; return 0; fi
  pkg_install "$pkg"; st=$?
  if [ "$st" -eq 1 ]; then log "硬前置: 必须先执行 ${hint:-sudo apt-get install -y $pkg} 再重跑本脚本"; fi
  return "$st"
}
