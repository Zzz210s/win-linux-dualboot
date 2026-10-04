#!/usr/bin/env bash
# 用例⑦:步骤脚本夹具自检 —— .superpowers/sdd/*/fixtures/**/*.sh 有语法错要报。
#   夹具在 .superpowers/ 下(gitignore,不入库),不在上面 scripts/ 的扫描范围,故单列一节。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

d="$(mk_repo fixture)"
mkdir -p "$d/.superpowers/sdd/demo/fixtures"
printf '#!/usr/bin/env bash\nif true; then\n'  > "$d/.superpowers/sdd/demo/fixtures/bad.sh"   # 未闭合 if
printf '#!/usr/bin/env bash\necho ok\n'        > "$d/.superpowers/sdd/demo/fixtures/good.sh"
run_gate "$d"
want "夹具语法错报 FIXTURE_SYNTAX" "FIXTURE_SYNTAX .superpowers/sdd/demo/fixtures/bad.sh"
dont "夹具合规不报"                "FIXTURE_SYNTAX .superpowers/sdd/demo/fixtures/good.sh"
cnt_is 1 "FIXTURE_SYNTAX" "FIXTURE_SYNTAX 只报一次"
summary
