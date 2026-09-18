#!/usr/bin/env bash
# 共享日志与参数工具:由 scripts/linux/ 下的 L4 脚本(storage/hardening/mount-shared/xdg-redirect/graphics/first-boot)source。
# 拆出来的原因与家目录重定向相同——每份代码文件不超过 200 行,且多个脚本的日志实现原本逐字重复。
# 调用约定:调用方先设置 LOG(日志文件路径,可用 DBK_LOG 覆盖),再使用 log()/die()/need_val()。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail)。
LOG="${LOG:-/var/log/dbk/dbk.log}"

log() {
  local line dir
  line="$(date '+%Y-%m-%d %H:%M:%S%z') $*"
  printf '%s\n' "$line"
  dir="$(dirname "$LOG")"
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
  fi
}

die() { log "错误: $*"; exit 1; }
# 取值选项的参数守卫:need_val "$#" "--size" "<字节数,如 4G>"。
# 缺失时给中文提示并 exit 1;否则 $2 就是合法取值(调用方随后 X="$2"; shift 2)。
# 不加守卫的话:set -e 的脚本会静默 exit 1(shift 2 失败),无 set -e 的脚本会 shift 失败后原地死循环。
need_val() { [ "$1" -ge 2 ] || die "$2 缺少参数:$3"; }
