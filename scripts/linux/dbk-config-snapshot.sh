#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:配置快照的五份清单——export-config.sh(采集侧)与 import-config.sh(复原侧)共用的**清单表、比对口径、采集分派与
#   manifest.txt 的 sha256 校验**。从两个步骤脚本里拆出(原文件逼近 200 行上限);口径、消息文本与占位行写法一字未改。
# 调用约定:调用方先 source dbk-cli.sh(取 dbk_add_check)与 dbk-pkg.sh / dbk-brew.sh(取 pkg_layered_list /
#   brew_bundle_dump 两个只读接口),再 source 本库,然后:
#   snap_files                            打印五份快照文件名(一行一个,顺序固定)
#   snap_norm <文件>                      打印去掉空行与纯注释行后的内容(比对口径;文件不存在 → 无输出,返回 0)
#   snap_gen <文件名> <输出路径> <取不到时写占位行 0|1>   按文件名分派采集(export 侧传 1,import 侧传 0);
#     0 = 采到 / 1 = 文件名不认识 / 2 = 取不到数据(原因已进 SNAP_MANUAL)
#   snap_verify_manifest <快照目录>       校验 <目录>/manifest.txt 与五份快照的 sha256;0 = 通过 / 1 = 不过(原因进 SNAP_MANUAL)
#   SNAP_MANUAL                           数组:采集/校验中判为「需人工」的原因(调用方读它并入自己的 MANUAL)
# 依赖调用方变量:BREW_LIB(dbk-brew.sh 的路径,只用于提示文本;缺省 dbk-brew.sh)。
# 命令来源:DBK_DCONF / DBK_OSTREE / DBK_FLATPAK(空格分隔的命令与固定参数);brew 与分层包走上面两个接口。
# 只读:不写系统状态;采集输出只写调用方给的 <输出路径>。本文件只定义函数与数组,不设置 shell 选项、不执行动作;
#   **末尾不加任何条件语句**(被 source 时返回非 0 会让带 set -e 的调用方静默退 1)。

SNAP_MANUAL=()

snap_files() { printf '%s\n' dconf.txt etc-config-diff.txt flatpak-apps.txt brew-bundle.txt layered-pkgs.txt; }

snap_norm() { grep -vE '^[[:space:]]*(#.*)?$' "${1:-}" 2>/dev/null || true; }

# snap_gen <文件名> <输出路径> <占位:0|1>:命令型三份按 DBK_* 指定的命令采集;brew 与分层包走接口。
snap_gen() {
  local n="${1:-}" out="${2:-}" ph="${3:-0}" label="" st=0
  local -a cmd=()
  case "$n" in
    dconf.txt) label="dconf 清单"; read -r -a cmd <<<"${DBK_DCONF:-dconf}"; set -- "${cmd[@]}" dump / ;;
    etc-config-diff.txt) label="/etc 漂移"; read -r -a cmd <<<"${DBK_OSTREE:-ostree}"; set -- "${cmd[@]}" admin config-diff ;;
    flatpak-apps.txt) label="Flatpak 清单"; read -r -a cmd <<<"${DBK_FLATPAK:-flatpak}"; set -- "${cmd[@]}" list --app --columns=application,origin ;;
    brew-bundle.txt)
      if command -v brew_bundle_dump >/dev/null 2>&1; then brew_bundle_dump "$out" >/dev/null 2>&1 || st=$?; else st=2; fi
      if [ "$st" -eq 0 ]; then return 0; fi
      SNAP_MANUAL+=("brew 清单:dbk-brew.sh 未就位或 brew 不可用(rc=$st,需人工;库 ${BREW_LIB:-dbk-brew.sh})")
      if [ "$ph" = 1 ]; then printf '# 取不到数据:brew 接口不可用(rc=%s)\n' "$st" >"$out"; fi
      return 2 ;;
    layered-pkgs.txt)
      if command -v pkg_layered_list >/dev/null 2>&1 && pkg_layered_list >"$out" 2>/dev/null; then return 0; fi
      SNAP_MANUAL+=("分层包清单:读不到分层状态(需人工)")
      if [ "$ph" = 1 ]; then printf '# 取不到数据:分层状态读不到\n' >"$out"; fi
      return 2 ;;
    *) return 1 ;;
  esac
  # 命令型三份:命令不在或跑失败 → 记需人工;占位行只在 export 侧写(import 侧靠自检跳过比对)。
  if ! { [ -x "${1:-}" ] || command -v "${1:-}" >/dev/null 2>&1; }; then
    SNAP_MANUAL+=("$label:未找到命令 ${1:-}(需人工)")
    if [ "$ph" = 1 ]; then printf '# 取不到数据:命令缺失(%s)\n' "${1:-}" >"$out"; fi
    return 2
  fi
  if "$@" >"$out" 2>"$out.err"; then rm -f "$out.err"; return 0; fi
  SNAP_MANUAL+=("$label:命令失败($*)")
  rm -f "$out.err"
  if [ "$ph" = 1 ]; then printf '# 取不到数据:命令失败(%s)\n' "$1" >"$out"; fi
  return 2
}

# 回灌前必须过 manifest 校验:export-config.sh 写的 manifest.txt 是五份快照的 sha256 台账。不校验就会把被改坏/
# 截断的快照原样回灌(2026-10-06 审查指出)。取不到 sha256sum 或台账缺行 → 记需人工,不 fail-open。
snap_verify_manifest() {
  local cfg="${1:-}" n want got bad=0
  if ! command -v sha256sum >/dev/null 2>&1; then SNAP_MANUAL+=("未找到 sha256sum:无法校验快照完整性(需人工)"); return 1; fi
  if [ ! -r "$cfg/manifest.txt" ]; then SNAP_MANUAL+=("缺 $cfg/manifest.txt:先跑 export-config.sh --apply --yes 重新生成"); return 1; fi
  while IFS= read -r n; do
    want="$(awk -v f="$n" '$2 == f { print $1; exit }' "$cfg/manifest.txt" 2>/dev/null || true)"
    got="$(sha256sum "$cfg/$n" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      dbk_add_check "校验失败: $n 与 manifest.txt 的 sha256 不符或缺台账行"
      SNAP_MANUAL+=("$n 快照与 manifest 不符;**不执行回灌**,核后重跑 export-config.sh --apply --yes"); bad=1
    fi
  done < <(snap_files)
  if [ "$bad" -eq 1 ]; then return 1; fi
  return 0
}
