#!/usr/bin/env bash
# 用例④:S-2 仓库卫生。未跟踪且未被忽略的散落文件(含带空格名)要报;gitignore 的不算违规;
#   追踪的根散落仍按旧行为报;白名单根文件不报。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

d="$(mk_git_repo s2)"
mkdir -p "$d/scripts/linux"
printf '.superpowers/\n*.log\n' > "$d/.gitignore"          # .gitignore 本身在白名单里
printf 'junk\n' > "$d/junk.txt"                            # 未跟踪、未被忽略 -> S2_STRAY_ROOT
printf 'tracked\n' > "$d/oldstray.txt"; git -C "$d" add oldstray.txt   # 已追踪根散落 -> 仍要报
printf 'log\n' > "$d/notes.log"                            # 被 .gitignore 忽略 -> 不算违规
printf '# dbk\n' > "$d/README.md"                          # 白名单 -> 不报
printf '#!/usr/bin/env bash\necho ok\n' > "$d/scripts/linux/has space.sh"  # 未跟踪带空格 -> S2_SPACE_NAME

run_gate "$d"
want "未跟踪且未忽略的根散落报 S2_STRAY_ROOT" "S2_STRAY_ROOT junk.txt"
want "已追踪的根散落仍报 S2_STRAY_ROOT"       "S2_STRAY_ROOT oldstray.txt"
dont "gitignore 忽略的 .log 不算违规"         "S2_STRAY_ROOT notes.log"
dont "白名单 README.md 不报"                  "S2_STRAY_ROOT README.md"
want "带空格文件名报 S2_SPACE_NAME"           "S2_SPACE_NAME"
want "空格名列表含该文件"                     "has space.sh"
summary
