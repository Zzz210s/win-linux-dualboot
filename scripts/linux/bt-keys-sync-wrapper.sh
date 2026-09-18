#!/usr/bin/env bash
# L4:蓝牙配对密钥同步包装脚本(上游项目 KeyofBlueS/bt-keys-sync;本仓库**不内置**其代码)。
#
# 方向与顺序(上游建议,见 docs/05-first-boot.md 步骤 5):**以 Windows 侧密钥为权威来源**。
#   1) 先在 Ubuntu 里对目标设备完成一次正常配对;
#   2) 重启进 Windows,对同一设备重新配对一次(让 Windows 侧成为权威来源);
#   3) 回 Ubuntu 运行本脚本(以 --windows-keys 从 Windows 注册表导入密钥);
#   4) 复测:同一设备在两个系统里都能直接连接,不需再次配对。
# **反向写入 Windows 注册表有风险**(系统盘被独占、写坏可能无法启动),本脚本默认不做;上游建议也是这个方向。
#
# 用法:bt-keys-sync-wrapper.sh [--apply] [--win-mnt <挂载点>] [--script <上游脚本路径>]
#                              [--repo-url <仓库地址|raw 文件地址>] [--log <path>] [-- <上游脚本额外参数>]
#   默认 dry-run:只打印计划(不装包、不下载、不运行上游脚本);加 --apply(需 root)才真正执行。
#   上游仓库地址取自设计文档第 11 节记录的 `KeyofBlueS/bt-keys-sync`;**下载文件名与命令行参数以该仓库 README 为准**——
#   本脚本按候选文件名(bt-keys-sync.sh / bt-keys-sync)在 master/main 分支逐个尝试,全部失败时提示你按 README
#   手工下载或用 --script 指定已有副本;读取注册表只需**只读**挂载 Windows 分区(如 sudo mount -o ro <分区> /mnt/win)。
# 日志追加到 /var/log/dbk/bt-keys-sync-wrapper.log。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${DBK_LOG:-/var/log/dbk/bt-keys-sync-wrapper.log}"
APPLY=0
WIN_MNT="${DBK_WIN_MNT:-}"
SCRIPT_PATH="${DBK_BT_SCRIPT:-}"
REPO_URL="${DBK_BT_REPO:-https://github.com/KeyofBlueS/bt-keys-sync}"
DEST="${DBK_BT_DIR:-/opt/bt-keys-sync}"
SKIP_APT="${DBK_SKIP_APT:-0}"
HIVE_REL="Windows/System32/config/SYSTEM"
PASSTHRU=()

# 日志/参数守卫与 apt 工具与其它 L4 脚本共用(见 dbk-log.sh、dbk-apt.sh);缺失时立刻停下
[ -r "$HERE/dbk-log.sh" ] || { echo "错误: 缺少 $HERE/dbk-log.sh" >&2; exit 1; }
source "$HERE/dbk-log.sh"
[ -r "$HERE/dbk-apt.sh" ] || die "缺少 $HERE/dbk-apt.sh,无法安装 chntpw"
source "$HERE/dbk-apt.sh"

usage() { sed -n '2,17p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --win-mnt) need_val "$#" "--win-mnt" "<Windows 分区挂载点,如 /mnt/win>"; WIN_MNT="$2"; shift 2 ;;
    --win-mnt=*) WIN_MNT="${1#*=}"; shift ;;
    --script) need_val "$#" "--script" "<上游 bt-keys-sync 脚本路径>"; SCRIPT_PATH="$2"; shift 2 ;;
    --script=*) SCRIPT_PATH="${1#*=}"; shift ;;
    --repo-url) need_val "$#" "--repo-url" "<上游仓库地址或 raw 文件地址>"; REPO_URL="$2"; shift 2 ;;
    --repo-url=*) REPO_URL="${1#*=}"; shift ;;
    --log) need_val "$#" "--log" "<日志文件路径>"; LOG="$2"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    --) shift; PASSTHRU=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done
case "$SKIP_APT" in 1|0) ;; *) die "DBK_SKIP_APT 只接受 0/1: $SKIP_APT" ;; esac

if [ "$APPLY" -eq 1 ]; then log "模式: apply(将装包、下载上游脚本并运行)"; else log "模式: dry-run(只打印计划,不装包、不下载、不运行)"; fi
log "上游项目: KeyofBlueS/bt-keys-sync(设计文档第 11 节记录;仓库 $REPO_URL;下载文件名与参数以该仓库 README 为准)"
log "推荐顺序(顺序错了就得重来): 1) 先在 Ubuntu 配对目标设备 -> 2) 回 Windows 对同一设备重新配对 -> 3) 回 Ubuntu 用 --windows-keys 导入 Windows 侧密钥 -> 4) 复测两系统都能直连"
log "方向: 以 Windows 侧密钥为准(上游建议);反向写入 Windows 注册表有风险(系统盘独占、写坏可能无法启动),本脚本默认不做。"

# 找 Windows 分区:显式 --win-mnt 优先,否则扫描 ntfs/ntfs3 挂载点里含注册表 hive 的那个
find_win_mnt() {
  local t
  while IFS= read -r t; do
    if [ -r "$t/$HIVE_REL" ]; then printf '%s\n' "$t"; return 0; fi
  done < <(findmnt -rn -o TARGET -t ntfs,ntfs3 2>/dev/null || true)
  return 1
}
if [ -z "$WIN_MNT" ] && command -v findmnt >/dev/null 2>&1; then
  WIN_MNT="$(find_win_mnt || true)"
fi
HIVE_OK=0
if [ -n "$WIN_MNT" ] && [ -r "$WIN_MNT/$HIVE_REL" ]; then HIVE_OK=1; fi
if [ "$HIVE_OK" -eq 1 ]; then
  log "Windows 分区挂载点: $WIN_MNT(注册表 hive 可读:$HIVE_REL)"
elif [ -n "$WIN_MNT" ]; then
  log "警告: $WIN_MNT/$HIVE_REL 读不到;请确认该挂载点就是 Windows 系统分区(只读挂载即可)"
  log "做法: sudo mount -o ro <Windows 系统分区,如 /dev/nvme0n1p2> $WIN_MNT 后再带 --win-mnt $WIN_MNT 重跑"
else
  log "提示: 未找到已挂载的 Windows 分区(自动扫描 ntfs/ntfs3 挂载点没找到含注册表 hive 的那个)"
  log "做法(只读挂载即可,不要用可写方式挂载系统分区): sudo mkdir -p /mnt/win && sudo mount -o ro <Windows 系统分区> /mnt/win,再带 --win-mnt /mnt/win 重跑"
fi

if apt_installed chntpw; then log "依赖 chntpw: 已安装"; else log "依赖 chntpw: 未安装,计划用 apt-get install -y chntpw(DBK_SKIP_APT=1 时跳过)"; fi

# 上游 README(KeyofBlueS/bt-keys-sync,"Windows registry hive file"一节)的选项为 `-p, --path <system_hive_path>`:
# hive 已定位时显式传入,这样 --win-mnt 挂在 /media、/mnt 以外(或已挂载但不被上游搜索到的)路径时上游也能找到
DRY_ARGS=" --windows-keys"
if [ "$HIVE_OK" -eq 1 ]; then DRY_ARGS="$DRY_ARGS --path $WIN_MNT/$HIVE_REL"; fi
if [ "${#PASSTHRU[@]}" -gt 0 ]; then DRY_ARGS="$DRY_ARGS ${PASSTHRU[*]}"; fi

if [ "$APPLY" -ne 1 ]; then
  log "计划执行: 1) apt_ensure chntpw  2) 把上游脚本下载到 $DEST/  3) bash <上游脚本>$DRY_ARGS"
  log "计划结束: 提示你不做反向写入(不改 Windows 注册表),并按上面四步复测。"
  log "dry-run 结束:未装包、未下载、未运行上游脚本;真正执行请用 sudo bash scripts/linux/bt-keys-sync-wrapper.sh --apply${WIN_MNT:+ --win-mnt $WIN_MNT}"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "--apply 需要 root:请用 sudo 重跑"
[ "$HIVE_OK" -eq 1 ] || die "读不到 Windows 注册表 hive($WIN_MNT/$HIVE_REL):先只读挂载 Windows 系统分区并带 --win-mnt 重跑"
pkg_st=0; apt_ensure chntpw "sudo apt install -y chntpw" || pkg_st=$?
[ "$pkg_st" -eq 0 ] || die "chntpw 不可用(见上面的失败原因),无法继续"

# 上游脚本获取:fetch 只往 stdout 写,--script 指定的本地副本优先
fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 1; fi
}
download_upstream() {
  local repo="$1" dest="$2" base cand br url tmp
  case "$repo" in
    *.sh|*raw.githubusercontent.com*) tmp="$dest/$(basename "$repo")"
      if fetch "$repo" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then printf '%s\n' "$tmp"; return 0; fi
      rm -f "$tmp"; return 1 ;;
  esac
  base="${repo%/}"; base="${base%.git}"; base="${base#https://github.com/}"
  for cand in bt-keys-sync.sh bt-keys-sync; do
    for br in master main; do
      url="https://raw.githubusercontent.com/$base/$br/$cand"
      tmp="$dest/$cand"
      if fetch "$url" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then printf '%s\n' "$tmp"; return 0; fi
      rm -f "$tmp"
    done
  done
  return 1
}

mkdir -p "$DEST" || die "无法创建 $DEST"
if [ -n "$SCRIPT_PATH" ]; then
  [ -s "$SCRIPT_PATH" ] || die "--script 指定的文件不存在或为空: $SCRIPT_PATH"
  log "使用指定的上游脚本副本: $SCRIPT_PATH(用户自备文件:不改权限位、不做下载校验,由你自行保证来源可信)"
else
  SCRIPT_PATH="$(download_upstream "$REPO_URL" "$DEST" || true)"
  if [ -z "$SCRIPT_PATH" ]; then
    log "下载失败: 无法从 $REPO_URL 取到上游脚本(候选 bt-keys-sync.sh / bt-keys-sync,master/main 都试过)。"
    log "请按 $REPO_URL 的 README 手工下载脚本到 $DEST/(或用 --script <路径> 指定已有副本)后重跑;本仓库不内置上游代码。"
    exit 1
  fi
  chmod +x "$SCRIPT_PATH" 2>/dev/null || true
  log "已下载上游脚本到: $SCRIPT_PATH(取自 master/main 的**分支尖端**快照:无签名、无版本校验,上游随时可能变)"
  sha="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || true)"
  log "该文件 SHA256: ${sha:-无法计算(缺 sha256sum)};建议先人工过目该文件再运行(less $SCRIPT_PATH),并把 SHA256 记入 baseline/04-first-boot.md"
fi

UP_ARGS=("--windows-keys")
if [ "$HIVE_OK" -eq 1 ]; then UP_ARGS+=("--path" "$WIN_MNT/$HIVE_REL"); fi
if [ "${#PASSTHRU[@]}" -gt 0 ]; then UP_ARGS+=("${PASSTHRU[@]}"); fi
log "运行: bash $SCRIPT_PATH ${UP_ARGS[*]}"
bash "$SCRIPT_PATH" "${UP_ARGS[@]}" || die "上游脚本以非 0 退出;把它的输出与 docs/05-first-boot.md 步骤 5 对照排障"
log "完成: 已按 --windows-keys 从 Windows 侧导入密钥;未做反向写入(Windows 注册表未被修改)。"
log "复测: 同一设备在 Ubuntu 与 Windows 里都应能直接连接(不需再次配对);结果按 docs/05-first-boot.md 步骤 5 记入 baseline/04-first-boot.md。"
