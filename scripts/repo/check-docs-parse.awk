# 文档解析器(库文件:非步骤脚本):被 scripts/repo/check-docs.sh(逐文件判定 C1-C9a)与
# scripts/repo/check-docs-repo.sh(C9c 收集卡体内脚本路径)共用,保证「卡体」定义只有一处。
# 用法: awk -v scope=<FLOW|DOC08|SPEED|PLAIN> -v nn=<NN 前缀|空> -v no_ph=<0|1> -v emoji=<字节模式> -f check-docs-parse.awk <文件>
# 输出: KIND<TAB>行号<TAB>载荷;各 KIND 的含义见 check-docs.sh 的 parse_file 注释。
    function body_has(s, e, key,   i) { for (i = s + 1; i < e; i++) if (index(L[i], key)) return 1; return 0 }
    function end_of(line,   i) { for (i = 1; i <= na; i++) if (A[i] > line) return A[i]; return n + 1 }
    BEGIN {
      KEY[1] = "看到:"; KEY[2] = "坑:"; KEY[3] = "出错时:"
      PATHRE = "scripts[\\\\/][A-Za-z0-9_./\\\\-]+\\.(sh|ps1)"
    }
    {
      n++; L[n] = $0
      if ($0 ~ /^### /) H[++nh] = n
      if ($0 ~ /^#[^#]/ || $0 ~ /^##[^#]/ || $0 ~ /^###[^#]/) A[++na] = n
      if ($0 ~ /^## /) in_hist = ($0 ~ /变更历史/)
      if (!in_hist && $0 !~ /^\|[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*\|/) {
        rest = $0
        while (match(rest, /(-> |`)[0-9][0-9]-[0-9]+/)) {
          ref = substr(rest, RSTART, RLENGTH); sub(/^(-> |`)/, "", ref)
          if (!((n ":" ref) in seen)) { seen[n ":" ref] = 1; printf "R\t%d\t%s\n", n, ref }
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
      if (!no_ph && $0 ~ /TBD|TODO|待补|FIXME|占位符/) printf "P\t%d\t\n", n
      if ($0 ~ emoji) printf "E\t%d\t\n", n
      rest = $0
      while (match(rest, /\]\([^)#][^)]*\)/)) {
        link = substr(rest, RSTART + 2, RLENGTH - 3); rest = substr(rest, RSTART + RLENGTH)
        sub(/[[:space:]]+("[^"]*"|'[^']*'|\([^()]*\)?)[[:space:]]*$/, "", link)
        sub(/#.*$/, "", link)
        if (link ~ /^(https?|mailto)/ || link ~ /^\// || link ~ /\{\{/) continue
        printf "L\t%d\t%s\n", n, link
      }
      rest = $0
      while (match(rest, /\]\([^)]*\.md#[^)]*\)/)) { printf "X\t%d\t\n", n; rest = substr(rest, RSTART + RLENGTH) }
      rest = $0
      while (match(rest, /\]\(#[^)]*\)/)) { printf "S\t%d\t%s\n", n, substr(rest, RSTART + 3, RLENGTH - 4); rest = substr(rest, RSTART + RLENGTH) }
      if ($0 ~ /^- \[[ xX]\]/) printf "I\t%d\t%s\n", n, $0
    }
    END {
      for (i = 1; i <= nh; i++) {
        line = H[i]; t = L[line]; e = end_of(line)
        printf "H\t%d\t%s\n", line, t
        if (t ~ /^### [0-9][0-9]-[0-9]+([ \t]|$)/) {
          id = substr(t, 5); sub(/[ \t].*$/, "", id); printf "K\t%d\t%s\n", line, id
        }
        gate = 0
        if (scope == "FLOW" && length(nn) == 2 && substr(t, 1, 7) == "### " nn "-") {
          rem = substr(t, 8); kk = rem; sub(/[^0-9].*$/, "", kk)
          if (kk != "") gate = 1
        }
        if (gate) {
          printf "T\t%d\t%d\n", line, e - line
          for (j = 1; j <= 3; j++) if (!body_has(line, e, KEY[j])) printf "M\t%d\t%s\n", line, KEY[j]
        }
        if (scope == "FLOW" ? (t ~ /^### [0-9][0-9]-[0-9]+([ \t]|$)/) : (scope != "PLAIN")) {
          for (b = line + 1; b < e; b++) {
            rest = L[b]
            while (match(rest, PATHRE)) {
              p = substr(rest, RSTART, RLENGTH); gsub(/\\/, "/", p)
              printf "A\t%d\t%s\n", b, p
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        }
      }
    }