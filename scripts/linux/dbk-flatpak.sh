#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:Flatpak 通道薄接口(GUI 应用优先 Flatpak/Flathub;不做系统级分层)。
# 契约真源:docs/design/06-atomic-restore-design.md 第 3 节(发行版薄接口层);卡 05-19。
# 与 dbk-brew.sh 同规:包管理通道命令只允许出现在本文件(仓库自检 S-1 的豁免名单由 check-scripts.sh 维护)。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-cli.sh / dbk-obs.sh),然后使用:
#   flatpak_avail                      0 = 命令可用;2 = 不可用(未安装,需人工;本库不自动装)
#   flatpak_installed <application-id> 0 = 已装;1 = 未装;2 = 查不了(命令不可用)
#   flatpak_install <id...>            0 = 已装或已装成功;1 = 失败(原因已落日志);2 = 需人工;9 = 按 DBK_SKIP_PKG 跳过
#   flatpak_list                       stdout 每行一个已装 application id;0 = 可读;2 = 读不到
# 返回值纪律(读调用方代码前必看):2 一律是「需人工」不是失败,9 是跳过(DBK_SKIP_PKG=1);只有 1 才是失败。
#   flatpak_avail 返回 2 时调用方必须显式处理:Flatpak 是 ublue 镜像自带组件,本库不自动装。
# 注入(夹具用,真机不需要设置):DBK_FLATPAK 覆盖命令(可含参数,按空白切词);DBK_FLATPAK_REMOTE 覆盖 remote 名
#   (缺省 flathub);DBK_SKIP_PKG=1 只跳写动作,判定照做。
# 只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail);末尾不留条件语句
#   —— 被 source 时返回非 0 会带崩调用方的 set -e。
# 夹具级验证,真机未跑。待核实(以 Flatpak/Flathub 官方文档为准):`flatpak info` 对未装应用的非零退出码、
#   `flatpak list --app --columns=application` 的输出形态,以及 remote 名 flathub 是否为缺省。

# 把 DBK_FLATPAK 按空白切成命令数组(可含参数),避免它被当成单个命令名。
_flatpak_argv() { FP=(); read -r -a FP <<<"${DBK_FLATPAK:-flatpak}"; return 0; }

# 跳过开关:DBK_SKIP_PKG=1(兼容 dbk-pkg.sh 用的 SKIP_PKG)只跳过写动作,判定照做。
_flatpak_skip() { [ "${SKIP_PKG:-${DBK_SKIP_PKG:-0}}" = 1 ]; }

# 库层日志:优先 dbk_obs(同时落 stderr 与 --log),否则 dbk_note,再否则 stderr(不吞输出)。
_flatpak_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v dbk_note >/dev/null 2>&1; then dbk_note "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 0 = 命令可用;2 = 需人工(未安装)。
flatpak_avail() {
  _flatpak_argv
  if ! command -v "${FP[0]}" >/dev/null 2>&1; then
    _flatpak_note "错误: 未找到 ${FP[0]}:Flatpak 是 ublue 镜像自带组件,缺失需人工(见 05-19,本库不自动装)"
    return 2
  fi
  return 0
}

# 0 = 已装;1 = 未装;2 = 查不了(命令不可用)。
flatpak_installed() {
  local want="${1:-}" out st=0
  if [ -z "$want" ]; then _flatpak_note "错误: flatpak_installed 缺少 application id"; return 2; fi
  flatpak_avail || return 2
  out="$(command "${FP[@]}" info "$want" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then return 0; fi
  return 1
}

# 0 = 已装或已装成功;1 = 失败;2 = 需人工;9 = 跳过。已装则直接 0(重跑幂等)。
flatpak_install() {
  local out st=0 id all=1 remote="${DBK_FLATPAK_REMOTE:-flathub}"
  if [ "$#" -lt 1 ]; then _flatpak_note "错误: flatpak_install 缺少 application id"; return 1; fi
  if _flatpak_skip; then _flatpak_note "DBK_SKIP_PKG=1:跳过 Flatpak 安装 $*"; return 9; fi
  flatpak_avail || return 2
  for id in "$@"; do
    st=0; flatpak_installed "$id" || st=$?
    case "$st" in
      0) ;;
      1) all=0; break ;;
      *) return 2 ;;
    esac
  done
  if [ "$all" -eq 1 ]; then _flatpak_note "$* 已安装,跳过 Flatpak 安装"; return 0; fi
  st=0
  out="$(command "${FP[@]}" install --noninteractive -y "$remote" "$@" 2>&1)" || st=$?
  if [ "$st" -eq 0 ]; then _flatpak_note "${FP[0]} 安装 $*: 已完成"; return 0; fi
  _flatpak_note "错误: ${FP[0]} 安装 $* 失败: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  return 1
}

# stdout 每行一个已装 application id;0 = 可读;2 = 读不到。
flatpak_list() {
  local out st=0
  flatpak_avail || return 2
  out="$(command "${FP[@]}" list --app --columns=application 2>&1)" || st=$?
  if [ "$st" -ne 0 ]; then
    _flatpak_note "错误: ${FP[0]} list 失败: $(printf '%s' "$out" | tr '\n' ' ')"
    return 2
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}
