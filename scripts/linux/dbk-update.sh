#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:更新策略接口(Fedora 44 Silverblue / 原子版语义):判定与写入「只检查/下载,绝不自动应用与自动重启」。
# 契约真源:docs/design/06-atomic-restore-design.md 第 2 节 D5 与第 3 节(dbk-update.sh 行);
#   docs/design/03-step-automation-design.md 第 6 节库文件行(四个发行版薄接口之一)。接口名不带发行版痕迹,
#   只换内部实现;Kubuntu 时代的 unattended-upgrades 语义(apt 粒度的「只装安全更新」)已随 2026-09-25 回切废弃。
# 关键语义(原子版,不可改):原子版没有「只装安全更新」这个 apt 粒度 → 语义如实替换为
#   「只检查/下载,绝不自动应用与自动重启」;配置写 <update-conv> 的 [Daemon] 段 AutomaticUpdatePolicy。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-obs.sh 的 dbk_obs —— dbk-cli.sh 只是替调用方 source 它),
#   然后使用:
#   update_policy_check  0 = 已配为「只检查/下载」且自动更新定时器已启用 / 1 = 未配或不符 / 2 = 读不到(需人工)
#   update_policy_apply  0 = 写入并启用成功 / 1 = 失败(原因已落日志)
#   update_policy_text   打印将写入的两行(供步骤脚本的 --check 展示)
#   $UPDATE_CONF / $UPDATE_TIMER  解析后的配置路径与定时器单元名(供步骤脚本展示,别在步骤脚本里写发行版字面量)
# 环境注入:DBK_RPM_OSTREED_CONF(缺省 /etc/rpm-ostreed.conf)、DBK_SYSTEMCTL(缺省 systemctl;可含路径)。
# 本文件只定义函数与常量:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。
# 待核实(以官方文档为准):配置文件的节名 [Daemon] 与键名 AutomaticUpdatePolicy;取值 check/download/stage 的语义;
#   systemd 单元名 rpm-ostreed-automatic.timer;systemctl is-enabled 的退出码约定 —— 四处都未在真机验证。

UPDATE_CONF="${DBK_RPM_OSTREED_CONF:-/etc/rpm-ostreed.conf}"   # 待核实(以官方文档为准)
UPDATE_TIMER="rpm-ostreed-automatic.timer"                     # 待核实(以官方文档为准)

# 日志出口:优先用可观测层的 dbk_obs(同时落 stderr 与 --log),否则退回 dbk-log.sh 的 log,再退回 stderr(不吞 stderr)。
_upd_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 将写入的两行(唯一实现处;--check 展示与 --apply 写入共用)。
update_policy_text() { printf '[Daemon]\nAutomaticUpdatePolicy=check\n'; }

# 自动更新定时器是否已启用:0 已启用 / 1 未启用 / 2 读不到(需人工)。
# 注入值可能带路径或参数,故用数组切分;体内一律 command,避免与同名 shell 函数互相递归(dbk-cli.sh 头部约定)。
_update_timer_enabled() {
  local -a sc
  local out st
  read -r -a sc <<<"${DBK_SYSTEMCTL:-systemctl}"
  if ! command -v "${sc[0]}" >/dev/null 2>&1; then
    _upd_note "错误: 未找到 ${sc[0]},无法判断 $UPDATE_TIMER 是否已启用(需人工)"
    return 2
  fi
  out="$(command "${sc[@]}" is-enabled "$UPDATE_TIMER" 2>&1)" && st=0 || st=$?
  if [ "$out" = enabled ]; then return 0; fi
  if [ -z "$out" ] || [ "$st" -eq 127 ]; then
    _upd_note "错误: $UPDATE_TIMER is-enabled 取不到状态(退出码 $st,输出空;需人工)"
    return 2
  fi
  _upd_note "提示: $UPDATE_TIMER 未启用(is-enabled 输出 '$out')"
  return 1
}

# 0 = 已配为「只检查/下载」且定时器已启用;1 = 未配或不符;2 = 读不到(需人工)。
# check 与 download 都算「只检查/下载」(设计 06 第 3 节写 check|download);apply/stage 是「自动应用/自动重启」,一律拒。
# 读不到状态一律走 2(需人工),绝不 fail-open 成 0:更新策略是「不自动重启」这条纪律的唯一自动判据。
update_policy_check() {
  if [ -e "$UPDATE_CONF" ] && [ ! -r "$UPDATE_CONF" ]; then
    _upd_note "错误: $UPDATE_CONF 存在但读不到(权限问题?需人工)"
    return 2
  fi
  if [ ! -r "$UPDATE_CONF" ]; then
    _upd_note "提示: $UPDATE_CONF 不存在或不可读,更新策略尚未配置"
    return 1
  fi
  if ! grep -qE '^[[:space:]]*AutomaticUpdatePolicy=(check|download)([[:space:]]|$)' "$UPDATE_CONF"; then
    _upd_note "提示: $UPDATE_CONF 未设 AutomaticUpdatePolicy=check/download"
    return 1
  fi
  if grep -qE '^[[:space:]]*AutomaticUpdatePolicy=(apply|stage)' "$UPDATE_CONF"; then
    _upd_note "提示: $UPDATE_CONF 含 AutomaticUpdatePolicy=apply/stage(会自动应用或自动重启)"
    return 1
  fi
  if _update_timer_enabled; then
    return 0
  else
    return $?
  fi
}

# 写入配置并启用定时器:0 成功 / 1 失败(原因已落日志)。
# 只写目标内容(不保留旧文件);回退办法写在步骤脚本的回滚说明里(删配置 + disable 定时器)。
update_policy_apply() {
  local -a sc
  local dir out st
  dir="$(dirname "$UPDATE_CONF")"
  command -v install >/dev/null 2>&1 || { _upd_note "错误: 未找到 install,无法创建目录 $dir"; return 1; }
  if ! install -d "$dir"; then
    _upd_note "错误: 目录创建失败:$dir"
    return 1
  fi
  if ! update_policy_text >"$UPDATE_CONF"; then
    _upd_note "错误: 写入失败:$UPDATE_CONF"
    return 1
  fi
  _upd_note "已写入 $UPDATE_CONF"
  read -r -a sc <<<"${DBK_SYSTEMCTL:-systemctl}"
  if ! command -v "${sc[0]}" >/dev/null 2>&1; then
    _upd_note "错误: 未找到 ${sc[0]},无法启用 $UPDATE_TIMER(配置已写入,但定时器未启用)"
    return 1
  fi
  out="$(command "${sc[@]}" enable --now "$UPDATE_TIMER" 2>&1)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _upd_note "错误: ${sc[0]} enable --now $UPDATE_TIMER 失败(退出码 $st): $(printf '%s' "$out" | tr '\n' ' ')"
    return 1
  fi
  _upd_note "已启用 $UPDATE_TIMER"
  return 0
}
