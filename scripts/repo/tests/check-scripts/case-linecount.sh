#!/usr/bin/env bash
# 用例①:行数上限按物理行计。旧实现 `wc -l` 只数换行符——末行无转行符时 201 物理行被算成 200,漏报上限。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 生成 n 物理行;末行是否带转行符由 trail 决定(首行放 shebang 免得 shellcheck 报 SC2148 噪声)
gen() { local f="$1" n="$2" trail="$3" i; : > "$f"
  for ((i = 1; i <= n; i++)); do
    if [ "$i" -eq 1 ]; then printf '#!/usr/bin/env bash'; else printf '# 填充行 %s' "$i"; fi >> "$f"
    if [ "$i" -lt "$n" ] || [ "$trail" = 1 ]; then printf '\n' >> "$f"; fi
  done; }

d="$(mk_repo linecount)"
mkdir -p "$d/scripts/linux"
gen "$d/scripts/linux/over.sh" 201 0   # 物理 201 行、末行无转行符 -> wc -l=200(旧逻辑漏报)
gen "$d/scripts/linux/edge.sh" 200 0   # 物理 200 行、末行无转行符 -> wc -l=199(必须不报)
run_gate "$d"
want "201 物理行(末行无转行符)报 TOO_LONG" "over.sh (201 行)"
dont "200 物理行(末行无转行符)不报" "edge.sh ("
cnt_is 1 "TOO_LONG" "TOO_LONG 只报一次"
printf '      [变异证据] over.sh 的 wc -l=%s、awk 物理行=%s\n' "$(wc -l < "$d/scripts/linux/over.sh")" "$(awk 'END{print NR}' "$d/scripts/linux/over.sh")"
summary
