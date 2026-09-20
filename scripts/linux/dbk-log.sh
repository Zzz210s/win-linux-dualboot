#!/usr/bin/env bash
# 共享日志与参数工具:由 scripts/linux/ 下的 L4 脚本(storage/hardening/mount-shared/xdg-redirect/graphics/first-boot)source。
# 拆出来的原因与家目录重定向相同——每份代码文件不超过 200 行,且多个脚本的日志实现原本逐字重复。
# 调用约定:调用方先设置 LOG(日志文件路径,可用 DBK_LOG 覆盖),再使用 log()/die()/need_val()/dbk_json_escape()。
# dbk_json_escape 是 JSON 字符串转义的唯一实现(scripts/linux/dbk-cli.sh 也复用它,不重复定义)。
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
# 取值选项的参数守卫:
#   need_val "$#" "--size" "<字节数,如 4G>"        只守"缺参数"(既有调用写法)
#   need_val "$#" "--size" "<字节数>" "$2"         第 4 参给取值,额外守"取值为空串"
# 缺失或取值为空时给中文提示并 exit 1;否则 $2 就是合法取值(调用方随后 X="$2"; shift 2)。
# 不加守卫的话:set -e 的脚本会静默 exit 1(shift 2 失败),无 set -e 的脚本会 shift 失败后原地死循环。
need_val() {
  [ "$1" -ge 2 ] || die "$2 缺少参数:$3"
  if [ "$#" -ge 4 ]; then [ -n "$4" ] || die "$2 的取值为空:$3"; fi
}

# 把一段文本转义成可安全放进 JSON 双引号字符串的形式(不引入 jq/python):
# 先转义反斜杠,再转义双引号,最后把制表符/回车/换行写成转义序列。
dbk_json_escape() {
  local s="${*:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
