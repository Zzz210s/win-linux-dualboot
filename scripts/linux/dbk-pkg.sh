#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:包管理助手(Fedora 44 Silverblue / rpm-ostree 分层语义):判断、分层安装系统级包。
# 契约真源:docs/design/06-atomic-restore-design.md 第 3 节(发行版薄接口层,四个接口之一);
#   docs/design/03-step-automation-design.md 第 6 节库文件行。文件名保持 dbk-pkg.sh(接口名不带发行版痕迹),
#   只换内部实现;Kubuntu 时代的 apt/dpkg 语义已随 2026-09-25 回切废弃。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-obs.sh 的 dbk_obs —— dbk_obs 的真源是 dbk-obs.sh,
#   dbk-cli.sh 只是替调用方 source 它;不引 dbk-cli 时也可直接 source dbk-log.sh 的 log),然后使用:
#   pkg_installed <包>      该包已装(基础镜像或分层,**含已提交未重启的**)→ 0;未装 → 1
#   pkg_update              原子版 no-op:返回 0,打印"原子版无 apt update 等价动作"(rpm-ostree 自动同步元数据)
#   pkg_install <包...>     0 = 分层安装已提交(重启后生效);9 = 按 SKIP_PKG 跳过;1 = 失败(原因已落日志)
#   pkg_ensure <包...>      0 = 已装或已提交 / 1 = 失败 / 2 = 需人工(--now);已装则跳过,否则逐个 pkg_install
#   pkg_needs_reboot        0 = 存在未生效的 staged 分层改动(步骤脚本据此提示重启);1 = 无;2 = 读不到状态(需人工)
# 返回值纪律(读调用方代码前必看):
#   pkg_installed 判 0 的含义是"已装或已提交分层安装",**不代表本轮的包已经可用**:
#     调用方若要在同一轮使用该包,必须先 pkg_needs_reboot 分流;它返回 2 当"需人工"处理。
#   pkg_ensure 可能返回 2(需人工):调用方必须显式处理 2(case 里给 2 单独一支),
#     丢进 *) 当失败处理会把"需人工"误记成 FAIL。
# 关键语义(原子版,与 Kubuntu 相反):rpm-ostree 分层安装**写进下一部署、重启后才生效**,装完当前系统仍看不到;
#   因此 pkg_installed 先查 rpm-ostree status --json 的 deployments[].packages(含已提交分层):先切出各部署的
#   "packages":[…] 段,再按整词匹配,避免整文档 grep 命中 JSON 键名或别的字段;仍不中才退回 rpm -q
#   (它只查当前启动的 rpmdb,分层包要重启后才在里面)。
# DBK_SKIP_PKG/DBK_SKIP_APT=1 只跳过分层动作,判定(pkg_installed)照做,用于无网络/无 ostree 的静态校验。
# 注意:SKIP_PKG 不在这里固化默认值(源文件时赋值会先于调用方赋值,顺序难以保证),而在函数内实时读取。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE 覆盖 rpm-ostree 命令。
# 待核实(以官方文档为准):rpm-ostree status --json 的 deployments[].packages 数组与 deployments[].staged
#   布尔字段名;pkg_needs_reboot 的读法(在 status --json 全文里找 "staged": true,不区分是哪个部署);
#   以及 pkg_installed 的 rpm -q 兜底口径(只看当前启动的 rpmdb)。

PKG_CMD="${DBK_RPM_OSTREE:-rpm-ostree}"   # 夹具注入用

# 库层日志:优先用可观测层的 dbk_obs(同时落 stderr 与 --log),否则退回 dbk-log.sh 的 log,再退回 stderr。
# 不吞 stderr:调用方既没装 dbk-obs 也没装 dbk-log 时,失败信息仍要打到 stderr。
_pkg_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 从 status --json(stdin)里取出各部署 "packages":[…] 段的元素,一行一个(带引号)。
# 先切段再匹配:整文档 grep 会命中 JSON 键名,也依赖"包名不与键名同形"这个偶然前提。
_pkg_names() {
  awk '
    { src = src " " $0 }
    END {
      while (match(src, /"packages"[[:space:]]*:[[:space:]]*\[[^]]*\]/)) {
        seg = substr(src, RSTART, RLENGTH)
        src = substr(src, RSTART + RLENGTH)
        sub(/^"packages"[[:space:]]*:[[:space:]]*\[/, "", seg)
        sub(/\]$/, "", seg)
        n = split(seg, a, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
          if (a[i] ~ /^"[^"]*"$/) print a[i]
        }
      }
    }
  '
}

# <包名>:rpm-ostree status --json 的 deployments[].packages 命中 → 0;否则 rpm -q 命中 → 0;都不中 → 1。
pkg_installed() {
  local want="${1:-}" out names
  [ -n "$want" ] || return 1
  out="$(command "$PKG_CMD" status --json 2>/dev/null)" || out=""
  names="$(printf '%s\n' "$out" | _pkg_names)"
  case $'\n'"$names"$'\n' in
    *$'\n'"\"$want\""$'\n'*) return 0 ;;
  esac
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
# 调用方必须显式处理 2(见文件头「返回值纪律」),不要把 2 当普通失败。
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
    if pkg_installed "$p"; then _pkg_note "$p 已安装(或已提交分层),跳过分层安装"; continue; fi
    pkg_install "$p"; st=$?
    if [ "$st" -eq 1 ]; then _pkg_note "硬前置: 必须先执行 sudo rpm-ostree install $p 再重跑本脚本"; fi
    [ "$st" -eq 0 ] || return "$st"
  done
  return 0
}

# 0 = 有未生效的 staged 分层改动(下一次重启才应用);1 = 无;2 = 读不到状态(需人工)。
# 失效方向必须是 2:它是"分层安装装了没生效"这条头号风险的唯一安全网,读不到就当"无待重启"会把风险静默吞掉。
pkg_needs_reboot() {
  local out st flat
  command -v "${PKG_CMD%% *}" >/dev/null 2>&1 || {
    _pkg_note "错误: 无 $PKG_CMD,无法判断是否有未生效分层改动(需人工)"; return 2; }
  out="$(command "$PKG_CMD" status --json 2>/dev/null)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _pkg_note "错误: $PKG_CMD status --json 退出码 $st,无法判断是否有未生效分层改动(需人工)"; return 2
  fi
  if [ -z "$out" ]; then
    _pkg_note "错误: $PKG_CMD status --json 无输出,无法判断是否有未生效分层改动(需人工)"; return 2
  fi
  case "$out" in
    *'"deployments"'*) ;;
    *) _pkg_note "错误: $PKG_CMD status --json 输出不含 deployments,无法判断是否有未生效分层改动(需人工)"; return 2 ;;
  esac
  # 去掉空白再匹配 "staged":true(JSON 可能写成 "staged": true,glob 里表达不了"零或多个空白")。
  flat="${out//[[:space:]]/}"
  case "$flat" in
    *'"staged":true'*) return 0 ;;
  esac
  return 1
}
