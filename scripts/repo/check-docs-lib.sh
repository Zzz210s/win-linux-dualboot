#!/usr/bin/env bash
# 库文件:非步骤脚本
# check-docs 公共解析库:被 scripts/repo/check-docs.sh(C1-C9a)与 scripts/repo/check-docs-repo.sh(C9b/C9c/C9d)source。
# 规则与白名单真源:docs/design/03-step-automation-design.md 第 4 节(改这里的 WL 必须同步改设计文档)。
# 调用方需先定义 ROOT(仓库根)。
set -uo pipefail

# emoji 字节模式:F0 9F = U+1F000 及以上;E2 98/99/9A/9B = U+2600~U+26FF;E2 9C/9D/9E = U+2700~U+27BF;EF B8 8F = 变体选择符。
# 本机 grep -P 不支持多字节码点范围,故用 LC_ALL=C 下的字节级匹配。
# 与 check-docs.sh 共用的命名常量:本文件只定义,由 check-docs.sh source 后使用(故此处看似未使用)。
# shellcheck disable=SC2034
EMOJI="$(printf '\xf0\x9f|\xe2\x98|\xe2\x99|\xe2\x9a|\xe2\x9b|\xe2\x9c|\xe2\x9d|\xe2\x9e|\xef\xb8\x8f')"

# C9 白名单:库文件(dbk-pkg.sh 是 hardening/storage/set-updates 等 source 的 apt/dpkg 包助手;它取代了已废弃的 dbk-ostree.sh / dbk-apt.sh;
# verify-all.sh / verify-all.ps1 是验收总控执行器,按 08 的 A-F 只读判定并汇总,不绑卡、不进步骤索引,故与库文件同列,
# 与 docs/design/03-step-automation-design.md 的 C9d 名单逐行一致,夹具 F7 断言两处相等)与仓库自检脚本。
WL=" scripts/linux/dbk-log.sh scripts/linux/dbk-cli.sh scripts/linux/dbk-obs.sh scripts/linux/dbk-pkg.sh scripts/linux/dbk.sh scripts/linux/verify-all.sh scripts/repo/check-docs.sh scripts/repo/check-docs-lib.sh scripts/repo/check-docs-repo.sh scripts/repo/check-scripts.sh scripts/windows/dbk-cli.ps1 scripts/windows/dbk-obs.ps1 scripts/windows/dbk-win-probe.ps1 scripts/windows/dbk.ps1 scripts/windows/verify-all.ps1 "
is_wl() { case "$WL" in *" $1 "*) return 0;; *) return 1;; esac; }

# 脚本头「# 对应卡:NN-K[,NN-K…]」:# 前允许 UTF-8 BOM(.ps1 必须带;.sh 允许),支持一脚本服务多张卡的逗号列表。
# 本正则与 scripts/linux/dbk-cli.sh 的 DBK_BOM/dbk_header_field、scripts/windows/dbk-cli.ps1 的
# Get-DbkHeaderField 必须保持一致,否则库与仓库自检(C9b/C9d)对同一脚本头会得出不同结论。
BOM="$(printf '\xef\xbb\xbf')"
CARDRE="^(${BOM})?#[[:space:]]*(对应卡|Card):[[:space:]]*[0-9][0-9]-[0-9]+([,，][[:space:]]*[0-9][0-9]-[0-9]+)*"
# 读脚本头声明的全部卡号(空格分隔;取不到则空)。

# 卡内脚本路径:正斜杠与反斜杠都接受(Windows 侧卡会写 scripts\windows\x.ps1);判存在/比对前先用 norm_path 归一成 /
# shellcheck disable=SC2034  # 与 check-docs.sh 共用(由它 source 后使用)
PATHRE='scripts[\\/][A-Za-z0-9_./\\-]+\.(sh|ps1)'
norm_path() { LC_ALL=C tr '\\' '/'; }

rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}";; *) printf '%s' "$1";; esac; }
# 文件末行之后的行号:无尾换行时 wc -l 会少 1,故用 awk 计数
file_end() { awk 'END {print NR + 1}' "$1"; }
# 卡体结束:下一个一级~三级标题的行号;没有则文件末行 + 1
card_end() {
  local e; e="$(awk -v s="$2" 'NR > s && (/^#[^#]/ || /^##[^#]/ || /^###[^#]/) {print NR; exit}' "$1")"
  printf '%s' "${e:-$(file_end "$1")}"
}
# 卡体行(不含卡标题):sed 切片(输出内相对行号用于回推绝对行号)
card_lines() { sed -n "$(($2 + 1)),$(($3 - 1))p" "$1"; }
# 标题/锚点归一(GitHub 风格):去标记、小写、空白转 -、去其它标点,但保留 - 与 _(这在上游是合法锚点字符);
# 中文等多字节字符逐字节保留(LC_ALL=C 下 [:punct:] 不含高位字节),- 与 _ 先换成控制字节再换回,避免被当标点删掉。
slugify() {
  sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//; s/[[:space:]]/-/g' \
    | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -- '-_' '\001\002' \
    | LC_ALL=C tr -d '[:punct:]' | LC_ALL=C tr -- '\001\002' '-_'
}
# 同文件锚点集合:归一后的标题;重复标题按 GitHub 规则追加 -1、-2…
file_anchors() {
  grep -E '^#{1,6} ' "$1" | slugify \
    | awk 'length($0) { n[$0]++; if (n[$0] == 1) print $0; else print $0 "-" (n[$0] - 1) }'
}
# 文档体裁:FLOW(01-07 卡文档)/ DOC08 / SPEED(09-10 速查卡)/ PLAIN(不写卡)
scope_of() {
  case "$(rel "$1")" in docs/design/*|checklists/*|baseline/README.md) echo PLAIN; return;; esac
  case "$(basename "$1")" in
    00-overview.md|README.md|README.zh-CN.md) echo PLAIN;;
    0[1-7]-*.md) echo FLOW;; 08-*.md) echo DOC08;; 09-*.md|10-*.md) echo SPEED;; *) echo PLAIN;;
  esac
}
# NN -> 文档路径:被检查文件自身命名匹配时用自身(夹具场景),否则取 docs/NN-*.md
doc_of() { case "$(basename "$2")" in "$1"-*.md) printf '%s' "$2";; *) ls "$ROOT/docs/$1"-*.md 2>/dev/null | head -1;; esac; }
card_exists() {
  local ref="$1" d
  d="$(doc_of "${ref%%-*}" "$2")"
  [ -n "$d" ] && grep -qE "^### $ref([[:space:]]|\$)" "$d" && return 0
  # 回退:引用方自身不是该编号的手册(例如 docs/design/NN-*.md 的编号是设计文档序号,不是手册号)时,
  # 按编号到 docs/ 里找承载该卡的手册;保持单文件模式与仓库模式结论一致。
  grep -lqE "^### $ref([[:space:]]|\$)" "$ROOT"/docs/"${ref%%-*}"-*.md 2>/dev/null
}
card_header_cards() {
  local line cards
  line="$(grep -m1 -oE "$CARDRE" "$1" || true)"
  cards="$(printf '%s' "$line" | grep -oE '[0-9][0-9]-[0-9]+' | tr '\n' ' ')"
  printf '%s' "${cards% }"
}
# 卡标题行:FLOW 只认 ### NN-K 形态(C2 定义的卡);08/09/10 的卡只需 ### 标题
card_heads() {
  case "$(scope_of "$1")" in FLOW) grep -nE '^### [0-9][0-9]-[0-9]+([[:space:]]|$)' "$1";; *) grep -nE '^### ' "$1";; esac
}
# 缺省文档集合:docs/*.md(仅深度 1)+ checklists/*.md + 仓库根 README.md / README.zh-CN.md
default_docs() {
  { find "$ROOT/docs" -maxdepth 1 -name '*.md'
    find "$ROOT/checklists" -maxdepth 1 -name '*.md' 2>/dev/null
    ls "$ROOT/README.md" "$ROOT/README.zh-CN.md" 2>/dev/null; } | sort
}
