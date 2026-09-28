#!/usr/bin/env bash
# 库文件:非步骤脚本。用途:步骤脚本**脚本头契约**的读取实现(卡号头与破坏性声明)。
# 契约真源:docs/design/03-step-automation-design.md 第 2 节与第 7 节(C9b 的脚本头要求)。
# 依赖:DBK_BOM 常量与 dbk_cli_val 由 dbk-cli.sh 提供(本文件由 dbk-cli.sh 在其之后 source,不单独使用)。

# dbk_header_field <文件> <字段名> <值正则>:读脚本头「# <字段>:<值>」的第一个匹配,打印「:」后的值(取不到打印空)。
# 卡号头与破坏性声明共用这一个实现;行首允许 UTF-8 BOM。
dbk_header_field() {
  local f="${1:-}" field="${2:-}" vre="${3:-}" line=""
  if [ -n "$f" ] && [ -r "$f" ]; then
    line="$(grep -m1 -oE "^(${DBK_BOM})?#[[:space:]]*${field}:[[:space:]]*(${vre})" "$f" || true)"
    if [ -n "$line" ]; then printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//'; fi
  fi
  return 0
}

# dbk_header_cards <文件>:读「# 对应卡:NN-K[,NN-K…]」,打印空格分隔的卡号列表(支持一脚本服务多张卡)。
dbk_header_cards() {
  local line cards
  line="$(dbk_header_field "${1:-}" '(对应卡|Card)' '[0-9][0-9]-[0-9]+([,，][[:space:]]*[0-9][0-9]-[0-9]+)*')"
  cards="$(printf '%s' "$line" | grep -oE '[0-9][0-9]-[0-9]+' | tr '\n' ' ' || true)"
  printf '%s' "${cards% }"
}

# dbk_declared_destructive <文件>:脚本头声明「# 破坏性:1」→ 0(其余情况返回非零)。
dbk_declared_destructive() {
  local v
  v="$(dbk_header_field "${1:-}" '破坏性' '1')"
  if [ "$v" = 1 ]; then return 0; fi
  return 1
}
