#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:显卡与 Secure Boot 接口(Fedora 44 Silverblue / 原子版语义):rebase 到 ublue 的 NVIDIA 变体 + MOK 注册判据 + nouveau 兜底。
# 契约真源:docs/design/06-atomic-restore-design.md 第 2 节 D3 与第 3 节(dbk-driver.sh 行);判据取自
#   docs/design/02-fedora-atomic-variant-design.md 第 3 节 D2 的「看到:」四项;docs/design/03-step-automation-design.md
#   第 6 节库文件行(四个发行版薄接口之一)。接口名不带发行版痕迹,只换内部实现;Kubuntu 时代的 ubuntu-drivers
#   预签名包路径(不换镜像分支、不注册 MOK)已随 2026-09-25 回切废弃。
# 调用约定:调用方先 source 本库(如需落日志,先 source dbk-obs.sh 的 dbk_obs —— dbk-cli.sh 只是替调用方 source 它),
#   然后使用:
#   driver_check            0 = 已就绪(签名者非空 + ublue 密钥已注册 + nvidia 已加载)/ 1 = 未完成 / 2 = 需人工
#   mok_check               0 = ublue 密钥已注册 / 1 = 未注册 / 2 = 读不到(需人工)
#   driver_signer           0 = 签名者非空(打印签名者)/ 2 = 读不到(需人工);1 不用:模块不在位也是「判不了」
#   driver_module_state     0 = lsmod 有 nvidia(打印命中行)/ 1 = 没有(可能是 nouveau 兜底)/ 2 = 读不到(需人工)
#   driver_rebase           0 = 已提交 rebase(重启后生效)/ 1 = 失败(原因已落日志)
#   driver_fallback_nouveau 只打印 nouveau 兜底步骤(不改任何系统状态),恒返回 0
# 返回值纪律(读调用方代码前必看):读类判定(driver_check / mok_check / driver_signer / driver_module_state)
#   在命令缺失、退出非 0、输出为空或字段缺失时一律返回 2(需人工),绝不 fail-open 成「没问题」;
#   1 是「读到了,而且明确没完成」。调用方必须显式处理 2(case 里给 2 单独一支),
#   丢进 *) 当普通失败处理会把「需人工」误记成 FAIL。
# 判据口径(设计 02 第 3 节 D2):① `modinfo -F signer nvidia` 非空(模块已签名);② `mokutil --list-enrolled` 含
#   ublue 密钥(签名者非空且已注册 ublue 密钥);③ `lsmod` 有 nvidia(模块已加载)。三条全绿 = 本地这三条读得到且成立。
# 判据作用域(契约,不可外推):driver_check 的 0 只证明「签名者非空 + 已注册密钥里出现 ublue + nvidia 已加载」这三件事,
#   既不证明镜像来源与版本,也不证明 Secure Boot 链整体有效 —— 这两点由 07-7 周期巡检承担
#   (镜像来源与版本由卡 07-7 判定;签名与 Secure Boot 状态部分见 check-signature.sh)。本步不判也不降级,只如实标注「不由本步判定」。
#   「是否已 rebase」同理不单独判:本步判结果,不读 status 的镜像 ref。
# 本文件只定义函数与常量:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail 或逐项汇总)。
# 夹具级验证,真机未跑。环境注入(夹具用):DBK_RPM_OSTREE / DBK_MOKUTIL / DBK_MODINFO / DBK_LSMOD / DBK_UBLUE_IMAGE。
# 待核实(以官方文档为准):本步不判镜像来源与版本(由 07-7 周期巡检承担,见上面作用域段);目标镜像名与分支(上游会改
#   品牌名/通道名);MOK 注册任务名 enroll-secure-boot-key 与密码 universalblue;modinfo -F signer 与 mokutil --list-enrolled
#   的输出格式;rebase 到 ostree-image-signed:docker://… 的参数形态与返回码 —— 均未在真机验证。

REBASE_CMD="${DBK_RPM_OSTREE:-rpm-ostree}"   # 夹具注入用
# 待核实(以官方文档为准):ublue 在 2026-09 的实际镜像名与分支(设计 02 第 3 节 D2 自标「实施时须核实」)。
UBLUE_IMAGE="${DBK_UBLUE_IMAGE:-ostree-image-signed:docker://ghcr.io/ublue-os/bluefin-nvidia:latest}"
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

# rebase 到 ublue 的 NVIDIA 变体(镜像内模块已预签名):0 = 已提交(重启后生效)/ 1 = 失败(原因已落日志)。
driver_rebase() {
  local -a rb
  local out st
  read -r -a rb <<<"$REBASE_CMD"
  command -v "${rb[0]}" >/dev/null 2>&1 || { _drv_note "错误: 未找到 ${rb[0]},无法 rebase 到 ublue NVIDIA 变体"; return 1; }
  out="$(command "${rb[@]}" rebase "$UBLUE_IMAGE" 2>&1)" && st=0 || st=$?
  if [ "$st" -ne 0 ]; then
    _drv_note "错误: ${rb[0]} rebase $UBLUE_IMAGE 失败(退出码 $st): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  _drv_note "${rb[0]} rebase $UBLUE_IMAGE: 已提交,重启后生效"
  return 0
}

# nouveau 兜底(设计 02 第 7 节 / 设计 00 风险表第 7 条):只打印步骤,绝不改系统。
driver_fallback_nouveau() {
  _drv_note "nouveau 兜底步骤(只打印,不改系统):"
  _drv_note "  1) 桌面起不来时别长按电源:用 REISUB/SysRq 安全重启,或按 07-2 从 GRUB 提示符回 Windows"
  _drv_note "  2) 回到能进系统的状态后按 05-9 回滚到 stock 部署(部署级回滚;回滚后由 nouveau 起桌面)"
  _drv_note "  3) 会话内核对:$REBASE_CMD status 看镜像来源与版本;mokutil --sb-state 看 Secure Boot;modinfo -F signer nvidia 看签名者"
  _drv_note "  4) 排查后重试 rebase(接口 driver_rebase):$REBASE_CMD rebase $UBLUE_IMAGE"
  _drv_note "  5) 内核行:cat /proc/cmdline 不含 nomodeset(nomodeset 关 KMS,与 Wayland 会话冲突)"
  return 0
}
