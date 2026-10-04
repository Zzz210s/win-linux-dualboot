#!/usr/bin/env bash
# 用例②③:S-1 发行版薄接口。覆盖:snapshot 注释不误报、yum/zypper/pacman/apk/flatpak install/snap 要报、
#   指引文字里的 flatpak 不报、apt 词内形态不报(词首守卫)。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

d="$(mk_repo s1)"
mkf() { local p="$d/$1"; mkdir -p "$(dirname "$p")"; cat > "$p"; }

mkf scripts/linux/pkg-yum.sh    <<'EOF'
#!/usr/bin/env bash
yum install -y htop
EOF
mkf scripts/linux/pkg-zypper.sh <<'EOF'
#!/usr/bin/env bash
zypper install htop
EOF
mkf scripts/linux/pkg-pacman.sh <<'EOF'
#!/usr/bin/env bash
pacman -S htop
EOF
mkf scripts/linux/pkg-apk.sh    <<'EOF'
#!/usr/bin/env bash
apk add htop
EOF
mkf scripts/linux/pkg-snap.sh   <<'EOF'
#!/usr/bin/env bash
snap install core
EOF
mkf scripts/linux/pkg-flat.sh   <<'EOF'
#!/usr/bin/env bash
flatpak install flathub org.mozilla.firefox
EOF
mkf scripts/linux/doc-snapshot.sh <<'EOF'
#!/usr/bin/env bash
# 本仓不引入 snapshot 体系。
echo ok
EOF
mkf scripts/linux/guide-flatpak.sh <<'EOF'
#!/usr/bin/env bash
# GUI 应用优先 flatpak,再考虑系统包。
echo ok
EOF
mkf scripts/linux/word-apt.sh <<'EOF'
#!/usr/bin/env bash
# 英文单词 adaptation 里嵌入的字母序列不是包管理器。
echo ok
EOF

run_gate "$d"
want "yum install 报 S1"        "S1_PKG_LEAK scripts/linux/pkg-yum.sh"
want "zypper install 报 S1"     "S1_PKG_LEAK scripts/linux/pkg-zypper.sh"
want "pacman 报 S1"             "S1_PKG_LEAK scripts/linux/pkg-pacman.sh"
want "apk add 报 S1"            "S1_PKG_LEAK scripts/linux/pkg-apk.sh"
want "snap install 报 S1"       "S1_PKG_LEAK scripts/linux/pkg-snap.sh"
want "flatpak install 报 S1"    "S1_PKG_LEAK scripts/linux/pkg-flat.sh"
dont "snapshot 注释不报(词边界)"  "S1_PKG_LEAK scripts/linux/doc-snapshot.sh"
dont "flatpak 指引文字不报"        "S1_PKG_LEAK scripts/linux/guide-flatpak.sh"
dont "apt 词内形态不报"            "S1_PKG_LEAK scripts/linux/word-apt.sh"
cnt_is 6 "S1_PKG_LEAK" "S1 命中恰好 6 个包管理器文件"
summary
