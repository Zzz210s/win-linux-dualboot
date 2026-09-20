#!/usr/bin/env bash
# 共享日志与参数工具:由 scripts/linux/ 下的 L4 脚本(storage/hardening/mount-shared/xdg-redirect/graphics/first-boot)source。
# 拆出来的原因与家目录重定向相同——每份代码文件不超过 200 行,且多个脚本的日志实现原本逐字重复。
# 调用约定:调用方先设置 LOG(日志文件路径,可用 DBK_LOG 覆盖),再使用 log()/die()/need_val()/dbk_json_escape()。
# dbk_json_escape 是 JSON 字符串转义的唯一实现(scripts/linux/dbk-cli.sh 也复用它,不重复定义)。
# 本文件只定义函数:不设置 shell 选项、不执行任何动作(调用方自己 set -euo pipefail)。
# 可观测性纪律(设计第 2 节):本库不得吞 stderr——日志目录/文件写不进去时必须把失败打到 stderr,不许 2>/dev/null 蒙掉。
LOG="${LOG:-/var/log/dbk/dbk.log}"

log() {
  local line dir
  line="$(date '+%Y-%m-%d %H:%M:%S%z') $*"
  printf '%s\n' "$line"
  dir="$(dirname "$LOG")"
  if ! mkdir -p "$dir" || [ ! -w "$dir" ]; then
    printf 'dbk: 日志目录不可写,本条只留在 stderr: %s\n' "$dir" >&2
    return 0
  fi
  if ! printf '%s\n' "$line" >>"$LOG"; then
    printf 'dbk: 日志写入失败,本条只留在 stderr: %s\n' "$LOG" >&2
  fi
  return 0
}

die() { log "错误: $*"; exit 1; }
# 取值选项的参数守卫:
#   need_val "$#" "--size" "<字节数,如 4G>"        只守"缺参数"(既有调用写法)
#   need_val "$#" "--size" "<字节数>" "$2"         第 4 参给取值,额外守"取值为空串"
# 缺失或取值为空时给中文提示并 exit 1;否则 $2 就是合法取值(调用方随后 X="$2"; shift 2)。
# 不加守卫的话:set -e 的脚本会静默 exit 1(shift 2 失败),无 set -e 的脚本会 shift 失败后原地死循环。
# 注意:dbk-cli.sh 的 --log/--step 不用本函数——那里缺参要用法错误 64,不能退 1、更不能落盘(见 dbk_cli_val)。
need_val() {
  [ "$1" -ge 2 ] || die "$2 缺少参数:$3"
  if [ "$#" -ge 4 ]; then [ -n "$4" ] || die "$2 的取值为空:$3"; fi
}

# 把一段文本转义成可安全放进 JSON 双引号字符串的形式(不引入 jq/python):
# 1) 反斜杠、双引号;2) 制表符/回车/换行写成短转义;3) 其余 U+0001–U+001F 控制字符写成 \u00XX
# (NUL 无法进入 bash 变量,故不在覆盖范围内;JSON 里也不允许裸控制字符)。
dbk_json_escape() {
  local s="${*:-}" i c hex
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    c="$(printf "\\$(printf '%03o' "$i")")"
    printf -v hex '\\u00%02x' "$i"
    s="${s//$c/$hex}"
  done
  printf '%s' "$s"
}
