#!/usr/bin/env bash
# 共享日志工具:由 scripts/linux/mount-shared.sh 与 scripts/linux/xdg-redirect.sh source。
# 拆出来的原因与家目录重定向相同——每份代码文件不超过 200 行,且两个脚本的日志实现原本逐字重复。
# 调用约定:调用方先设置 LOG(日志文件路径,可用 DBK_LOG 覆盖),再使用 log()/die()。
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
