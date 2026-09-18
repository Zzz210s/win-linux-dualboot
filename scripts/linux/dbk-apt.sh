#!/usr/bin/env bash
# 共享 apt 工具:由 scripts/linux/hardening.sh 与 scripts/linux/storage.sh source。
# 拆出来的原因:两个脚本都要装包(硬编码两份必然漂移),且每份代码文件不得超过 200 行。
# 调用约定:调用方先 source dbk-log.sh(提供 log)并在调用前设置 SKIP_APT(0/1;通常取自 DBK_SKIP_APT),然后使用:
#   apt_installed <包>        包已装好(dpkg 状态 install ok installed)返回 0
#   apt_install <包...>       0 = 装好;9 = 按 SKIP_APT 跳过;1 = 失败(失败原因已落日志)
#   apt_ensure <包> [补救命令]  已装则直接 0;否则 apt_install;失败再补一行"硬前置"提示
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail)。
SKIP_APT="${SKIP_APT:-0}"

apt_installed() {
  [ "$#" -ge 1 ] || return 1
  command -v dpkg-query >/dev/null 2>&1 || return 1
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_install() {
  local out
  if [ "$SKIP_APT" = 1 ]; then log "DBK_SKIP_APT=1:跳过 apt-get install $*"; return 9; fi
  command -v apt-get >/dev/null 2>&1 || { log "错误: 无 apt-get,无法安装 $*"; return 1; }
  if out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" 2>&1)"; then log "apt-get install $*: 成功"; return 0; fi
  log "错误: apt-get install $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; return 1
}

# 先查后装:已装直接返回 0(重跑不重复下载);失败时给出可直接照做的硬前置命令
apt_ensure() {
  local pkg="$1" hint="${2:-}" st
  if apt_installed "$pkg"; then log "$pkg 已安装,跳过 apt-get install"; return 0; fi
  apt_install "$pkg"; st=$?
  if [ "$st" -eq 1 ]; then log "硬前置: 必须先执行 ${hint:-apt-get install -y $pkg} 再重跑本脚本"; fi
  return "$st"
}
