#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:显卡与 Secure Boot 的**只读判据层**(从 dbk-driver.sh 拆出:原文件已到 200 行上限;实现与判定口径一字未改):
#   ① 签名者、② MOK 注册、③ 模块加载状态三条只读接口 + 聚合判定 driver_check。动作类接口(rebase、版本前置断言、nouveau 兜底)
#   与命令常量仍在 dbk-driver.sh(它 source 本库,接口名不变)。
# 契约真源:docs/design/02-fedora-atomic-variant-design.md 第 3 节 D2 的「看到:」四项;docs/design/06-atomic-restore-design.md 第 2 节 D3 与第 3 节。
# 调用约定:调用方先 source dbk-driver.sh(它会替调用方 source 本库),然后:
#   driver_signer           0 = 签名者非空(打印签名者)/ 2 = 读不到(需人工);1 不用:模块不在位也是「判不了」
#   mok_check               0 = ublue 密钥已注册 / 1 = 未注册 / 2 = 读不到(需人工)
#   driver_module_state     0 = lsmod 有 nvidia(打印命中行)/ 1 = 没有(可能是 nouveau 兜底)/ 2 = 读不到(需人工)
#   driver_check            0 = 已就绪(签名者非空 + ublue 密钥已注册 + nvidia 已加载)/ 1 = 未完成 / 2 = 需人工
# 判据口径(设计 02 第 3 节 D2):① `modinfo -F signer nvidia` 非空;② `mokutil --list-enrolled` 含 ublue 密钥(MOK_KEY_MATCH);
#   ③ `lsmod` 有 nvidia。三条全绿 = 本地这三条读得到且成立;driver_check 的 0 只证明这三件事,不外推镜像来源/版本/
#   Secure Boot 链整体有效(那两点由 07-7 周期巡检承担,见 dbk-driver.sh 的判据作用域段)。
# 返回值纪律:读类判定在命令缺失、退出非 0、输出为空或字段缺失时一律返回 2(需人工),绝不 fail-open 成「没问题」;
#   1 是「读到了,而且明确没完成」。调用方必须显式处理 2(case 里给 2 单独一支),丢进 *) 会把「需人工」误记成 FAIL。
# 本文件只定义函数与常量:不设置 shell 选项、不执行任何动作。**末尾禁止追加任何条件语句**(被 source 时返回 1,调用方普遍带 set -e)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_MODINFO / DBK_MOKUTIL / DBK_LSMOD。
MOK_KEY_MATCH="ublue"   # 设计 06 第 3 节:mokutil --list-enrolled 含 ublue 密钥

# 库层日志:优先用可观测层的 dbk_obs(同时落 stderr 与 --log),否则退回 dbk-log.sh 的 log,再退回 stderr(不吞 stderr)。
_drv_note() {
  if command -v dbk_obs >/dev/null 2>&1; then dbk_obs "$*"
  elif command -v log >/dev/null 2>&1; then log "$*"
  else printf '%s\n' "$*" >&2
  fi
}

# 首个非空行(签名者 / 命中的模块行都用它;空输入 → 空)。`|| true` 防调用方 pipefail 下 head 早退变成失败。
_drv_first_line() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | head -n1 || true; }
# 去掉全部空白后判空(命令输出可能只有换行/空格)。
_drv_blank() { [ -z "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]; }

# ① nvidia 模块签名者:`modinfo -F signer nvidia` 非空 → 0(打印签名者)/ 2 = 读不到(命令缺失、退出非 0、输出为空)。
driver_signer() {
  local -a mo
  local out st line
  read -r -a mo <<<"${DBK_MODINFO:-modinfo}"
  command -v "${mo[0]}" >/dev/null 2>&1 || { _drv_note "错误: 未找到 ${mo[0]},读不到 nvidia 模块签名者(需人工)"; return 2; }
  out="$(command "${mo[@]}" -F signer nvidia 2>&1)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _drv_note "错误: ${mo[0]} -F signer nvidia 退出码 $st($(_drv_first_line "$out"));读不到签名者(需人工)"
    return 2
  fi
  if _drv_blank "$out"; then
    _drv_note "错误: ${mo[0]} -F signer nvidia 输出为空(nvidia 模块未装或没有签名者字段;需人工)"
    return 2
  fi
  line="$(_drv_first_line "$out")"
  _drv_note "①nvidia 模块签名者(modinfo -F signer nvidia):$line"
  printf '%s\n' "$line"
  return 0
}

# ② MOK:`mokutil --list-enrolled` 含 ublue 密钥 → 0 / 不含 → 1(未注册)/ 2 读不到(命令缺失、退出非 0、输出为空)。
mok_check() {
  local -a mk
  local out st hit
  read -r -a mk <<<"${DBK_MOKUTIL:-mokutil}"
  command -v "${mk[0]}" >/dev/null 2>&1 || { _drv_note "错误: 未找到 ${mk[0]},读不到已注册的 MOK 密钥(需人工)"; return 2; }
  out="$(command "${mk[@]}" --list-enrolled 2>&1)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _drv_note "错误: ${mk[0]} --list-enrolled 退出码 $st($(_drv_first_line "$out"));读不到已注册密钥(需人工)"
    return 2
  fi
  if _drv_blank "$out"; then
    _drv_note "错误: ${mk[0]} --list-enrolled 输出为空,读不到已注册密钥(需人工)"
    return 2
  fi
  hit="$(printf '%s\n' "$out" | grep -i -m1 "$MOK_KEY_MATCH" || true)"
  if [ -n "$hit" ]; then
    _drv_note "②MOK 已注册 ublue 密钥(mokutil --list-enrolled):$(_drv_first_line "$hit")"
    return 0
  fi
  _drv_note "②MOK 未注册 ublue 密钥(mokutil --list-enrolled):只看到别的密钥(重启进 MOK 界面做一次注册)"
  return 1
}

# ③ nvidia 模块是否已加载:`lsmod` 有 nvidia → 0(打印命中行)/ 1 = 没有(可能是 nouveau 兜底)/ 2 = 读不到(需人工)。
driver_module_state() {
  local -a ls
  local out st hit nb
  read -r -a ls <<<"${DBK_LSMOD:-lsmod}"
  command -v "${ls[0]}" >/dev/null 2>&1 || { _drv_note "错误: 未找到 ${ls[0]},读不到模块加载状态(需人工)"; return 2; }
  out="$(command "${ls[@]}" 2>&1)" && st=0 || st=$?
  if [ "$st" -ne 0 ] || _drv_blank "$out"; then
    _drv_note "错误: ${ls[0]} 退出码 $st 或输出为空,读不到模块加载状态(需人工)"
    return 2
  fi
  hit="$(printf '%s\n' "$out" | grep -E '^nvidia[[:space:]]' | head -n1 || true)"
  if [ -n "$hit" ]; then
    _drv_note "③nvidia 模块已加载(lsmod):$hit"
    printf '%s\n' "$hit"
    return 0
  fi
  nb="$(printf '%s\n' "$out" | grep -E '^nouveau[[:space:]]' | head -n1 || true)"
  if [ -n "$nb" ]; then
    _drv_note "③nvidia 模块未加载(lsmod):nouveau 在加载,当前走开源驱动兜底"
    printf '%s\n' "nouveau"
  else
    _drv_note "③nvidia 模块未加载(lsmod):未见 nvidia,也未见 nouveau"
    printf '%s\n' "未见 nvidia/nouveau"
  fi
  return 1
}

# 聚合判定:0 = 已就绪 / 1 = 未完成 / 2 = 需人工(任一条读不到就不给结论)。三条判据的细行由上面三个只读函数各自落日志。
driver_check() {
  local s=0 m=0 n=0 signer=""
  signer="$(driver_signer)" || s=$?
  mok_check || m=$?
  driver_module_state >/dev/null || n=$?
  if [ "$s" -eq 2 ] || [ "$m" -eq 2 ] || [ "$n" -eq 2 ]; then
    _drv_note "驱动栈判定:需人工(签名者 rc=$s / MOK rc=$m / 模块 rc=$n);有读不到的状态,不当作没问题"
    return 2
  fi
  if [ "$s" -ne 0 ] || [ "$m" -ne 0 ] || [ "$n" -ne 0 ]; then
    _drv_note "驱动栈判定:未完成(签名者 rc=$s / MOK rc=$m / 模块 rc=$n);按上面逐条原因收敛后重跑"
    return 1
  fi
  _drv_note "驱动栈判定:已就绪(签名者 ${signer:-非空};ublue 密钥已注册;nvidia 模块已加载)"
  return 0
}

