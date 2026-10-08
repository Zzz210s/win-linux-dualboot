#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:Homebrew 通道薄接口(Silverblue / ublue 镜像自带 Homebrew,不 layering):判定、查询、安装公式与 bundle 快照。
# 契约真源:docs/design/06-atomic-restore-design.md 第 3 节(发行版薄接口层);卡 05-14(交互层走 brew 通道,不 rpm-ostree 分层)。
# 与 dbk-pkg.sh 同规:包管理与公式通道命令只允许出现在本文件(仓库自检 S-1 已把本文件列入豁免)。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-cli.sh / dbk-obs.sh),然后使用:
#   brew_avail                     0 = brew 可用(Linuxbrew 路径);2 = 不可用(未安装或非 Linuxbrew 路径,需人工)
#   brew_formula_installed <公式>   0 = 已装;1 = 未装;2 = 查不了(brew 不可用或命令失败)
#   brew_install <公式...>          0 = 已装或已装成功;1 = 失败(原因已落日志);2 = 需人工;9 = 按 DBK_SKIP_PKG 跳过
#   brew_list_formulas             stdout 每行一个已装公式;0 = 可读;2 = 读不到
#   brew_bundle_dump <目标文件>     0 = 已写;1 = 失败;2 = 需人工;9 = 跳过(bundle dump --file=… --force)
#   brew_bundle_install <清单文件>  0 = 已应用;1 = 失败;2 = 需人工;9 = 跳过(bundle install --file=…)
# 返回值纪律(读调用方代码前必看):2 一律是「需人工」不是失败,9 是跳过(DBK_SKIP_PKG=1);只有 1 才是失败。
#   brew_avail 返回 2 时调用方必须显式处理:brew 缺失按 05-14 手工装,本库不自动装 brew。
# 注入(夹具用,真机不需要设置):DBK_BREW 覆盖 brew 命令(可含参数,按空白切词);DBK_SKIP_PKG=1 只跳写动作,判定照做。
# 只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail);末尾不留条件语句
#   —— 被 source 时返回非 0 会带崩调用方的 set -e(此坑已踩过一次)。
# 夹具级验证,真机未跑。待核实(以 ublue 官方文档为准):自带 brew 的缺省前缀 /home/linuxbrew/.linuxbrew,
#   以及 brew list --formula / bundle dump 的输出形态。

# 把 DBK_BREW 按空白切成命令数组(可含参数),避免它被当成单个命令名。
_brew_argv() { BREW=(); read -r -a BREW <<<"${DBK_BREW:-brew}"; return 0; }

# 跳过开关:DBK_SKIP_PKG=1(兼容 dbk-pkg.sh 用的 SKIP_PKG)只跳过写动作,判定照做。
_brew_skip() { [ "${SKIP_PKG:-${DBK_SKIP_PKG:-0}}" = 1 ]; }

# 库层日志:优先 dbk_obs(同时落 stderr 与 --log),否则 dbk_note,再否则 dbk-log.sh 的 log,最后 stderr(不吞输出)。
_brew_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v dbk_note >/dev/null 2>&1; then dbk_note "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 0 = brew 可用;2 = 需人工(未安装,或不在 Linuxbrew 路径 —— 非 ublue 自带通道)。
brew_avail() {
  local p
  _brew_argv
  if ! p="$(command -v "${BREW[0]}" 2>/dev/null)"; then
    _brew_note "错误: 未找到 ${BREW[0]}:brew 是 ublue 镜像自带组件,缺失需人工(见 05-14,本库不自动装 brew)"
    return 2
  fi
  case "$p" in
    *linuxbrew*) return 0 ;;
  esac
  _brew_note "错误: ${BREW[0]} 解析为 $p,不在 Linuxbrew 路径:非 ublue 自带通道,需人工(见 05-14)"
  return 2
}

# 0 = 已装;1 = 未装;2 = 查不了(brew 不可用 / list 失败)。
brew_formula_installed() {
  local want="${1:-}" out st=0
  if [ -z "$want" ]; then _brew_note "错误: brew_formula_installed 缺少公式名"; return 2; fi
  brew_avail || return 2
  out="$(command "${BREW[@]}" list --formula 2>&1)" || st=$?
  if [ "$st" -ne 0 ]; then
    _brew_note "错误: ${BREW[0]} list --formula 失败: $(printf '%s' "$out" | tr '\n' ' ')"
    return 2
  fi
  case $'\n'"$out"$'\n' in
    *$'\n'"$want"$'\n'*) return 0 ;;
  esac
  return 1
}

# 0 = 已装或已装成功;1 = 失败;2 = 需人工;9 = 跳过。已装则直接 0(重跑幂等)。
brew_install() {
  local out st=0 f all=1
  if [ "$#" -lt 1 ]; then _brew_note "错误: brew_install 缺少公式名"; return 1; fi
  if _brew_skip; then _brew_note "DBK_SKIP_PKG=1:跳过公式安装 $*"; return 9; fi
  brew_avail || return 2
  for f in "$@"; do
    st=0; brew_formula_installed "$f" || st=$?
    case "$st" in
      0) ;;
      1) all=0; break ;;
      *) return 2 ;;
    esac
  done
  if [ "$all" -eq 1 ]; then _brew_note "$* 已安装,跳过公式安装"; return 0; fi
  st=0
  out="$(command "${BREW[@]}" install "$@" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then _brew_note "${BREW[0]} 安装 $*: 已完成"; return 0; fi
  _brew_note "错误: ${BREW[0]} 安装 $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# stdout 每行一个已装公式;0 = 可读;2 = 读不到(brew 不可用或 list 失败)。
brew_list_formulas() {
  local out st=0
  brew_avail || return 2
  out="$(command "${BREW[@]}" list --formula 2>&1)" || st=$?
  if [ "$st" -ne 0 ]; then
    _brew_note "错误: ${BREW[0]} list --formula 失败: $(printf '%s' "$out" | tr '\n' ' ')"
    return 2
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# 0 = 已写;1 = 失败;2 = 需人工;9 = 跳过。
brew_bundle_dump() {
  local f="${1:-}" out st=0
  if [ -z "$f" ]; then _brew_note "错误: brew_bundle_dump 缺少目标文件"; return 1; fi
  if _brew_skip; then _brew_note "DBK_SKIP_PKG=1:跳过 bundle 快照 $f"; return 9; fi
  brew_avail || return 2
  if ! mkdir -p "$(dirname "$f")"; then _brew_note "错误: 无法创建目录 $(dirname "$f")"; return 1; fi
  out="$(command "${BREW[@]}" bundle dump --file="$f" --force 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then _brew_note "${BREW[0]} bundle dump --file=$f: 已写出"; return 0; fi
  _brew_note "错误: ${BREW[0]} bundle dump --file=$f 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# 0 = 已应用;1 = 失败;2 = 需人工;9 = 跳过。
brew_bundle_install() {
  local f="${1:-}" out st=0
  if [ -z "$f" ]; then _brew_note "错误: brew_bundle_install 缺少清单文件"; return 1; fi
  if _brew_skip; then _brew_note "DBK_SKIP_PKG=1:跳过 bundle 回灌 $f"; return 9; fi
  brew_avail || return 2
  if [ ! -r "$f" ]; then _brew_note "错误: 清单文件不存在或不可读:$f"; return 1; fi
  out="$(command "${BREW[@]}" bundle install --file="$f" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then _brew_note "${BREW[0]} bundle install --file=$f: 已应用"; return 0; fi
  _brew_note "错误: ${BREW[0]} bundle install --file=$f 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}
