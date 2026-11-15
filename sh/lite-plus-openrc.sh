#!/bin/sh
# ==============================================================================
# Lite-Plus —— Alpine / OpenRC 一键安装与升级脚本
# ==============================================================================
#
# 为什么需要它：
#   官方 install-lite.sh 只支持 systemd 和 OpenWrt/procd。在 Alpine(OpenRC) 上跑
#   会得到「二进制装好了，但没有服务、没有开机自启」。本脚本补齐这一块。
#
# 项目：https://github.com/nuomiiiii/Lite-Plus（从 Lite 独立出来的节点管理面板）
#
# 适用：Alpine Linux + OpenRC（也适用于其他 OpenRC 发行版）
# 依赖：仅需 POSIX sh + wget/curl + OpenRC，不需要 bash / jq
#
# 用法：
#   sh lite-plus-openrc.sh                           # 不带 action：已安装则升级，未安装则安装
#   sh lite-plus-openrc.sh install                   # 首次安装
#   sh lite-plus-openrc.sh install --port 8080       # 指定端口安装
#   sh lite-plus-openrc.sh upgrade                   # 升级到最新稳定版
#   sh lite-plus-openrc.sh upgrade --version 0.2.0   # 升级到指定版本
#   sh lite-plus-openrc.sh upgrade --channel snapshot# 升级到快照版
#   sh lite-plus-openrc.sh upgrade --dry-run         # 只演练，不动线上
#   sh lite-plus-openrc.sh rollback                  # 回滚到上一版本
#   sh lite-plus-openrc.sh status                    # 查看运行状态
#
# 从旧 Lite 迁移到 Lite-Plus 请使用迁移脚本（不是本脚本）：
#   sh lite-migrate-to-plus.sh
#
# 一键（复制一行即可下载并执行；Alpine 一般自带 wget）：
#   wget -O lite-plus-openrc.sh https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-plus-openrc.sh && sh lite-plus-openrc.sh
#
# 一键（不落地文件，管道执行；动作写在 -- 之后）：
#   wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-plus-openrc.sh | sh -s -- upgrade
#
# 通用参数：
#   --port N        端口（install 时写入服务脚本，默认 28777；upgrade/status/rollback
#                   未显式指定时会自动从 /etc/init.d/lite-plus 反解已有端口）
#   --version X.Y.Z 指定版本（默认取最新；当前上游 tag 形如 0.2.0）
#   --channel NAME  stable（默认）| snapshot（仅 upgrade 生效，install 装稳定版）
#   --force         无条件执行（跳过同版本/版本新旧判断，用于重装 / 降级）
#   --dry-run       演练：upgrade 只下载并校验（不替换、不重启、不写备份）；install 不做任何改动
#   --no-backup     升级时不备份（不推荐）
#   -h, --help      显示帮助（帮助文本内嵌，管道执行时也可用）
#
# 特性：
#   - 升级前自动备份二进制 + 数据 + 服务脚本（rollback 只还原二进制），失败可一键回滚
#   - 新二进制先校验（ELF 头 + 能否执行 version）再上线
#   - 启动后验证服务状态 / HTTP / 版本号，任一不过自动回滚
#   - 按 cgroup 内存上限自动设置 GOMEMLIMIT + GOGC（Go 不感知 cgroup，否则会 OOM）
#   - 备份与下载都在不停服时完成，真实停机只有几秒
#   - 只有二进制、没有 OpenRC 服务脚本时（官方 install-lite.sh 装的）自动补建服务
# ==============================================================================

set -u

REPO="nuomiiiii/Lite-Plus"
SERVICE="lite-plus"
LEGACY_SERVICE="lite"
INSTALL_DIR="/opt/lite"
DATA_DIR="/opt/lite/data"
BINARY="$INSTALL_DIR/Lite"
INIT_SCRIPT="/etc/init.d/lite-plus"
LEGACY_INIT_SCRIPT="/etc/init.d/lite"
LOG_FILE="/var/log/lite-plus.log"
BACKUP_ROOT="/root/lite-backups"
LAST_BINARY_MARK="$BACKUP_ROOT/.last_binary"
LAST_RELEASE_MARK="$BACKUP_ROOT/.last_release"
NEW_VER=""
NEW_TIME=""

PORT="28777"
PORT_CLI=0
CHANNEL="stable"
OPT_VERSION=""
FORCE=0
DRYRUN=0
DO_BACKUP=1
ACTION="upgrade"
ACTION_CLI=0

# 提示语里引用自身；管道执行（wget | sh -s --）时 $0 是 sh/ash，不能直接拿来拼命令
case "${0##*/}" in
	sh|dash|ash|bash|ksh|zsh|busybox|"") SELF="lite-plus-openrc.sh" ;;
	*) SELF="$0" ;;
esac

# ------------------------------------------------------------------------------
# 输出
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
	C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'
	C_BLU='\033[0;34m'; C_RST='\033[0m'
else
	C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi

info() { printf '%b\n' "$1"; }
ok()   { printf '%b\n' "${C_GRN}[ OK ]${C_RST} $1"; }
warn() { printf '%b\n' "${C_YEL}[WARN]${C_RST} $1"; }
die()  { printf '%b\n' "${C_RED}[FAIL]${C_RST} $1"; exit 1; }
step() { printf '%b\n' "${C_BLU}==>${C_RST} $1"; }

usage() {
	cat <<'USAGE'
Lite-Plus —— Alpine / OpenRC 一键安装与升级脚本

用法：
  sh lite-plus-openrc.sh                             # 不带 action：已安装则升级，未安装则安装
  sh lite-plus-openrc.sh install                     # 首次安装（默认端口 28777）
  sh lite-plus-openrc.sh install --port 8080         # 指定端口安装
  sh lite-plus-openrc.sh upgrade                     # 升级到最新稳定版
  sh lite-plus-openrc.sh upgrade --version 0.2.0     # 升级到指定版本
  sh lite-plus-openrc.sh upgrade --channel snapshot  # 升级到快照版
  sh lite-plus-openrc.sh upgrade --dry-run           # 只演练，不动线上
  sh lite-plus-openrc.sh rollback                    # 回滚到上一版本（仅还原二进制）
  sh lite-plus-openrc.sh status                      # 查看运行状态（不需要 root）

从旧 Lite 迁移到 Lite-Plus 请使用迁移脚本（不是本脚本）：
  sh lite-migrate-to-plus.sh

一键（复制一行即可下载并执行；Alpine 一般自带 wget）：
  wget -O lite-plus-openrc.sh https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-plus-openrc.sh && sh lite-plus-openrc.sh

一键（不落地文件，管道执行；动作写在 -- 之后）：
  wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-plus-openrc.sh | sh -s -- upgrade

参数：
  --port N        端口（install 时写入服务脚本，默认 28777；upgrade/status/rollback
                  未显式指定时会自动从 /etc/init.d/lite-plus 反解已有端口）
  --version X.Y.Z 指定版本（默认取最新；当前上游 tag 形如 0.2.0）
  --channel NAME  stable（默认）| snapshot（仅 upgrade 生效，install 装稳定版）
  --force         无条件执行（跳过同版本/版本新旧判断，用于重装 / 降级）
  --dry-run       演练：upgrade 只下载并校验（不替换、不重启、不写备份）；install 不做任何改动
  --no-backup     升级时不备份（不推荐，之后无法 rollback）
  -h, --help      显示本帮助

说明：
  - 安装 / 升级 / 回滚需要 root，status 不需要
  - 只用 POSIX sh，不需要 bash / jq（busybox 的 sh + wget 即可）
  - 只有二进制、没有 OpenRC 服务脚本时（官方 install-lite.sh 装的）会自动补建服务
  - 同版本号但有更新的发布（按 GitHub 最近更新时间 updated_at 比较）时，upgrade 会自动更新；--force 无条件执行
  - 若检测到旧 Lite 的服务脚本 /etc/init.d/lite，本脚本会拒绝操作，请改用迁移脚本
USAGE
	exit 0
}

# ------------------------------------------------------------------------------
# 环境检查
# ------------------------------------------------------------------------------
need_root() {
	[ "$(id -u)" = "0" ] || die "需要 root 权限运行（当前 uid=$(id -u)）"
}

check_openrc() {
	command -v rc-service >/dev/null 2>&1 || die "未找到 rc-service：本脚本只支持 OpenRC 主机"
	command -v rc-update  >/dev/null 2>&1 || die "未找到 rc-update"
	if ! command -v supervise-daemon >/dev/null 2>&1; then
		warn "未找到 supervise-daemon，将退化为简单的后台进程方式（无自动重启）"
	fi
}

detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64)        echo "amd64" ;;
		aarch64|arm64)       echo "arm64" ;;
		i386|i686)           echo "386" ;;
		riscv64)             echo "riscv64" ;;
		loongarch64|loong64) echo "loong64" ;;
		*) die "不支持的架构: $(uname -m)（官方提供 amd64/arm64/386/riscv64/loong64）" ;;
	esac
}

# 磁盘余量检查：二进制 ~46MB，需留 备份+下载 的余量
check_space() {
	need_kb=140000
	# 安装目录可能还不存在（首次安装时 check_space 先于 mkdir），往上找最近的已存在目录
	cs_dir="$INSTALL_DIR"
	while [ -n "$cs_dir" ] && [ "$cs_dir" != "/" ] && [ ! -d "$cs_dir" ]; do
		cs_dir=$(dirname "$cs_dir")
	done
	avail=$(df -Pk "$cs_dir" 2>/dev/null | awk 'NR==2{print $4}')
	[ -n "$avail" ] || return 0
	if [ "$avail" -lt "$need_kb" ]; then
		die "磁盘空间不足：需要约 140MB，当前可用 $((avail / 1024))MB。请先清理 $BACKUP_ROOT 里的旧备份"
	fi
	ok "磁盘可用 $((avail / 1024))MB"
}

# 旧 Lite 服务存在而新服务不存在时，说明是从 Lite 直接升级，需要走迁移脚本
guard_legacy_service() {
	if [ -f "$LEGACY_INIT_SCRIPT" ] && [ ! -f "$INIT_SCRIPT" ]; then
		die "检测到旧 Lite 服务脚本 $LEGACY_INIT_SCRIPT。从 Lite 迁移到 Lite-Plus 请使用迁移脚本：sh lite-migrate-to-plus.sh"
	fi
}

# ------------------------------------------------------------------------------
# 端口：upgrade / status / rollback 未显式给 --port 时，从已有服务脚本里反解
# ------------------------------------------------------------------------------
port_from_file() { # port_from_file <file>
	[ -f "$1" ] || return 1
	# 先看未注释的 command_args 行（生成的服务脚本里它就是启动参数），避免取到注释掉的旧端口
	p=$(sed -n '/^[[:space:]]*#/d; s/^[[:space:]]*command_args=.*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1)
	# 退一步：任意未注释行的 0.0.0.0:PORT（兼容手工改写过的服务脚本）
	if [ -z "$p" ]; then
		p=$(sed -n '/^[[:space:]]*#/d; s/.*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1)
	fi
	[ -n "$p" ] || return 1
	printf '%s\n' "$p"
}

detect_port() {
	dp=$(port_from_file "$INIT_SCRIPT") || return 1
	printf '%s\n' "$dp"
}

resolve_port() {
	[ "$PORT_CLI" = "1" ] && return 0
	dp=$(detect_port) || {
		[ -f "$INIT_SCRIPT" ] && warn "无法从 $INIT_SCRIPT 反解端口，将按 $PORT 探测（可显式传 --port 指定）"
		return 0
	}
	[ -n "$dp" ] || return 0
	if [ "$dp" != "$PORT" ]; then
		PORT="$dp"
		info "从 $INIT_SCRIPT 读取到监听端口：$PORT（需要改端口请显式传 --port）"
	fi
	return 0
}

# 补建缺失的 OpenRC 服务脚本（官方 install-lite.sh 在 Alpine 上只装二进制、不建服务）
ensure_init_script() {
	[ -f "$INIT_SCRIPT" ] && return 0
	warn "未找到 $INIT_SCRIPT，正在补建 OpenRC 服务（端口 $PORT）"
	write_init || return 1
	rc-update add "$SERVICE" default >/dev/null 2>&1 \
		&& ok "已加入开机自启（default runlevel）" \
		|| warn "加入开机自启失败，可手动执行：rc-update add $SERVICE default"
	return 0
}

# ------------------------------------------------------------------------------
# 下载（兼容 busybox，容器里通常只有 wget）
# ------------------------------------------------------------------------------
dl() { # dl <url> <dest>
	if command -v curl >/dev/null 2>&1; then curl -fL --retry 2 -o "$2" "$1"; return $?; fi
	if command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"; return $?; fi
	if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -O "$2" "$1"; return $?; fi
	die "没有可用的下载工具（curl / wget / uclient-fetch 都没有）"
}

dl_stdout() { # dl_stdout <url>
	if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; return $?; fi
	if command -v wget >/dev/null 2>&1; then wget -qO- "$1"; return $?; fi
	if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -O- "$1"; return $?; fi
	return 1
}

# ------------------------------------------------------------------------------
# 版本
# ------------------------------------------------------------------------------
current_version() {
	[ -x "$BINARY" ] && [ -f "$BINARY" ] || return 1
	cv=$("$BINARY" version 2>/dev/null | tail -n 1 | awk '{print $1}')
	[ -n "$cv" ] || return 1
	printf '%s\n' "$cv"
}

# 从 GitHub release JSON 里取「最近更新时间」：优先 updated_at（同 tag 重新上传产物时会变），
# 其次 published_at（首次发布时间；重新发布时才会变）。两者都是 ISO8601 UTC。
json_time() { # json_time <json>
	t=$(printf '%s\n' "$1" | grep '"updated_at"' | head -n 1 \
		| sed -e 's/.*"updated_at" *: *"//' -e 's/".*//')
	if [ -z "$t" ]; then
		t=$(printf '%s\n' "$1" | grep '"published_at"' | head -n 1 \
			| sed -e 's/.*"published_at" *: *"//' -e 's/".*//')
	fi
	printf '%s\n' "$t"
}

# 取某个 tag 的最近更新时间
release_time_for_tag() { # release_time_for_tag <tag>
	json_time "$(dl_stdout "https://api.github.com/repos/${REPO}/releases/tags/$1")"
}

# 解析目标版本与最近更新时间，写入全局 NEW_VER / NEW_TIME
resolve_target() {
	if [ -n "$OPT_VERSION" ]; then
		NEW_VER="$OPT_VERSION"
		NEW_TIME=$(release_time_for_tag "$NEW_VER")
		return 0
	fi
	if [ "$CHANNEL" = "snapshot" ]; then
		NEW_VER=$(dl_stdout "https://api.github.com/repos/${REPO}/releases" \
			| grep '"tag_name"' | grep 'Snapshot-' | head -n 1 \
			| sed -e 's/.*"tag_name" *: *"//' -e 's/".*//')
		[ -n "$NEW_VER" ] || die "获取最新 snapshot 版本号失败（GitHub API 可能限流，可稍后重试或用 --version 指定）"
		NEW_TIME=$(release_time_for_tag "$NEW_VER")
		return 0
	fi
	json=$(dl_stdout "https://api.github.com/repos/${REPO}/releases/latest")
	NEW_VER=$(printf '%s\n' "$json" | grep '"tag_name"' | head -n 1 \
		| sed -e 's/.*"tag_name" *: *"//' -e 's/".*//')
	NEW_TIME=$(json_time "$json")
	# 保险：拿不到就退回 GitHub 的 latest 重定向
	if [ -z "$NEW_VER" ]; then
		NEW_VER=$(dl_stdout "https://github.com/${REPO}/releases/latest" \
			| grep -o "releases/tag/[0-9][^\"']*" | head -n 1 | sed 's|releases/tag/||')
	fi
	if [ -n "$NEW_VER" ] && [ -z "$NEW_TIME" ]; then
		NEW_TIME=$(release_time_for_tag "$NEW_VER")
	fi
	[ -n "$NEW_VER" ] || die "获取最新版本号失败（GitHub API 可能限流，可稍后重试或用 --version 指定）"
}

# ISO8601(UTC) → epoch 秒；busybox 没有 date -d，用 awk 手算
iso_to_epoch() {
	printf '%s\n' "$1" | awk -F'[-T:Z]' '{
		Y=$1; M=$2; D=$3; h=$4; mi=$5; s=$6
		if (M <= 2) { Y--; M += 12 }
		A = int(Y / 100); B = 2 - A + int(A / 4)
		days = int(365.25 * (Y + 4716)) + int(30.6001 * (M + 1)) + D + B - 1524 - 2440588
		print days * 86400 + h * 3600 + mi * 60 + s
	}'
}

# 字符串按字典序比较 a < b（ISO8601 UTC 时间可直接比）
is_lex_less() { # is_lex_less <a> <b>
	[ "$1" != "$2" ] || return 1
	printf '%s\n%s\n' "$1" "$2" | sort -c >/dev/null 2>&1
}

# 同版本更新判断：release 最近更新时间是否比「上次安装的 release 时间」新
# 无标记时退回比较本机二进制 mtime 与发布/更新时间的 epoch 秒
release_newer_than_last() {
	[ -n "$NEW_TIME" ] || return 1
	last_time=$(sed -n 's/^[^|]*|//p' "$LAST_RELEASE_MARK" 2>/dev/null | head -n 1)
	if [ -n "$last_time" ]; then
		is_lex_less "$last_time" "$NEW_TIME"
		return $?
	fi
	mt=$(stat -c %Y "$BINARY" 2>/dev/null) || return 1
	rt=$(iso_to_epoch "$NEW_TIME") || return 1
	[ -n "$mt" ] && [ -n "$rt" ] && [ "$rt" -gt "$mt" ]
}

# 记录本次成功安装 / 升级的 release 最近更新时间
write_last_release_mark() {
	[ -n "${NEW_TIME:-}" ] || return 0
	mkdir -p "$BACKUP_ROOT"
	printf '%s|%s\n' "${NEW_VER:-}" "$NEW_TIME" > "$LAST_RELEASE_MARK"
}

download_url() { # download_url <arch> <version>
	echo "https://github.com/${REPO}/releases/download/$2/Lite-linux-$1"
}

# 校验二进制：大小 >10MB + ELF 头 + 能执行 version
verify_binary() { # verify_binary <file> <期望版本>
	f="$1"; want="$2"
	[ -f "$f" ] || return 1
	sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
	[ -n "$sz" ] && [ "$sz" -gt 10000000 ] || { warn "文件大小异常: ${sz} 字节"; return 1; }
	magic=$(head -c 4 "$f" | od -An -c | tr -d ' \n')
	case "$magic" in *E*L*F*) ;; *) warn "不是有效的 ELF 文件（魔数: $magic）"; return 1;; esac
	chmod +x "$f"
	got=$("$f" version 2>/dev/null | tail -n 1 | awk '{print $1}')
	[ -n "$got" ] || { warn "二进制无法执行 version"; return 1; }
	if [ -n "$want" ]; then
		[ "$got" = "$want" ] || { warn "版本不符：期望 $want，实际 $got"; return 1; }
	fi
	ok "校验通过：版本 $got，大小 $((sz / 1024 / 1024))MB"
	return 0
}

# ------------------------------------------------------------------------------
# 内存保护：Go runtime 不感知 cgroup，必须显式压制，否则小容器会 OOM
# ------------------------------------------------------------------------------
# cgroup 内存上限（MB）；拿不到、或为 max / 无上限时输出空
cgroup_limit_mb() {
	lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
	case "$lim" in ''|max) lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null);; esac
	case "$lim" in ''|max|9223372036854771712) return 0;; esac
	mb=$((lim / 1048576))
	[ "$mb" -gt 0 ] || return 0
	echo "$mb"
}

calc_memlimit() {
	mb=$(cgroup_limit_mb)
	[ -n "$mb" ] || return 0
	half=$((mb / 2))
	[ "$half" -lt 32 ] && half=32
	echo "${half}MiB"
}

# ------------------------------------------------------------------------------
# OpenRC 服务脚本
# ------------------------------------------------------------------------------
write_init() {
	memlimit=$(calc_memlimit)
	if [ -n "$memlimit" ]; then
		mem_mb=$(cgroup_limit_mb)
		mem_block="
# 内存保护：本容器 cgroup 上限 ${mem_mb:-?}MB，Go runtime 默认不感知该限制，
# GOGC=100 会让 heap 翻倍增长直至 OOM，必须显式压制。
export GOMEMLIMIT=\"${memlimit}\"
export GOGC=\"50\""
	else
		mem_block=""
	fi

	cat > "$INIT_SCRIPT" <<EOF
#!/sbin/openrc-run

name="${SERVICE}"
description="Lite-Plus Monitoring Server"

command="${BINARY}"
command_args="server -l 0.0.0.0:${PORT}"
directory="${INSTALL_DIR}"
pidfile="/run/${SERVICE}.pid"

supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0

output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

export LITE_DEPLOYMENT="linux"
export LITE_SERVICE_NAME="${SERVICE}"
export LITE_SERVICE_MANAGER="openrc"
export LITE_LISTEN="0.0.0.0:${PORT}"
export GODEBUG="disablethp=1"
${mem_block}

depend() {
	use net
	after firewall
}
EOF
	chmod +x "$INIT_SCRIPT" 2>/dev/null
	if [ ! -f "$INIT_SCRIPT" ] || [ ! -s "$INIT_SCRIPT" ]; then
		warn "写入 $INIT_SCRIPT 失败（请检查该路径是否为目录、权限与磁盘空间）"
		return 1
	fi
	ok "服务脚本已写入 $INIT_SCRIPT${memlimit:+（内存保护 GOMEMLIMIT=$memlimit）}"
}

# ------------------------------------------------------------------------------
# 备份 / 回滚
# ------------------------------------------------------------------------------
do_backup() {
	[ "$DO_BACKUP" = "1" ] || { warn "已用 --no-backup 跳过备份"; return 0; }
	TS=$(date +%Y%m%d_%H%M%S)
	mkdir -p "$BACKUP_ROOT"
	if [ -f "$BINARY" ]; then
		cp -a "$BINARY" "$BACKUP_ROOT/Lite.$CUR_VER.$TS" || die "备份二进制失败"
		echo "$BACKUP_ROOT/Lite.$CUR_VER.$TS" > "$LAST_BINARY_MARK"
	fi
	if [ -d "$DATA_DIR" ]; then
		tar czf "$BACKUP_ROOT/data.$TS.tar.gz" -C "$INSTALL_DIR" data 2>/dev/null \
			&& ok "数据已备份: $BACKUP_ROOT/data.$TS.tar.gz" \
			|| warn "数据备份失败（继续）"
	fi
	[ -f "$INIT_SCRIPT" ] && cp -a "$INIT_SCRIPT" "$BACKUP_ROOT/initd.$TS" 2>/dev/null
	ok "备份完成（时间戳 $TS），回滚命令：sh $SELF rollback"
}

do_rollback() {
	resolve_port
	last=$(cat "$LAST_BINARY_MARK" 2>/dev/null)
	[ -n "$last" ] && [ -f "$last" ] || die "没有可用的回滚备份（找过 $LAST_BINARY_MARK）"
	step "回滚到 $last"
	rc-service "$SERVICE" stop >/dev/null 2>&1
	cp -a "$last" "$BINARY" || die "恢复二进制失败"
	chmod +x "$BINARY"
	rc-service "$SERVICE" start >/dev/null 2>&1
	if wait_healthy_loop; then
		ok "回滚成功，当前版本 $(current_version)"
	else
		die "回滚后服务仍异常，请检查 $LOG_FILE"
	fi
}

# ------------------------------------------------------------------------------
# 健康检查
# ------------------------------------------------------------------------------
service_up() {
	rc-service "$SERVICE" status 2>/dev/null | grep -q "started"
}

http_ok() {
	if command -v wget >/dev/null 2>&1; then
		wget -q -O /dev/null --timeout=8 "http://127.0.0.1:${PORT}/" 2>/dev/null && return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -sf -o /dev/null --max-time 8 "http://127.0.0.1:${PORT}/" 2>/dev/null && return 0
	fi
	return 1
}

health_check() {
	v=$(current_version)
	service_up || { warn "服务未处于 started 状态"; return 1; }
	http_ok     || { warn "HTTP 无响应（127.0.0.1:$PORT）"; return 1; }
	[ -n "$v" ] || { warn "无法读取版本号"; return 1; }
	ok "健康检查通过：版本 $v，服务 started，HTTP 正常"
	return 0
}

# 轮询等待服务就绪：最多约 2 分钟。
# 新版首次启动可能做数据迁移 / 大库压缩，8 秒固定等待往往不够，容易误判回滚。
wait_healthy_loop() {
	n=1
	while [ "$n" -le 40 ]; do
		if service_up && http_ok && [ -n "$(current_version 2>/dev/null)" ]; then
			return 0
		fi
		if [ $((n % 10)) -eq 0 ]; then
			info "  仍在等待服务就绪（${n}/40，约 $((n * 3)) 秒）…"
		fi
		sleep 3
		n=$((n + 1))
	done
	return 1
}

# ------------------------------------------------------------------------------
# 安装
# ------------------------------------------------------------------------------
do_install() {
	need_root; check_openrc
	guard_legacy_service
	# 已有服务脚本时沿用它的端口，避免重装把线上端口悄悄换成默认 28777
	resolve_port
	if [ -e "$BINARY" ] && [ -f "$INIT_SCRIPT" ]; then
		if [ -x "$BINARY" ] && [ -f "$BINARY" ]; then
			die "已安装 Lite-Plus（$(current_version)）。升级请改用: sh $SELF upgrade"
		fi
		die "$BINARY 存在但不是可执行文件（权限或损坏）。修复：chmod +x $BINARY 后执行 sh $SELF upgrade；确认要重装请先 rm -f $BINARY 再执行 sh $SELF install"
	fi
	if [ "$DRYRUN" = "1" ]; then
		info "演练（--dry-run）：install 不做任何改动；真实执行会下载并安装 Lite-Plus、写 $INIT_SCRIPT 并启动服务"
		exit 0
	fi
	if [ -e "$BINARY" ] || [ -f "$INIT_SCRIPT" ] || [ -d "$DATA_DIR" ]; then
		CUR_VER=$(current_version 2>/dev/null || echo unknown)
		if [ -f "$BINARY" ]; then
			warn "$BINARY 已存在但没有服务脚本（例如官方 install-lite.sh 装的），继续安装并补建 OpenRC 服务"
		else
			warn "检测到旧安装痕迹（$INIT_SCRIPT / $DATA_DIR），但 $BINARY 不可用，重新安装并沿用端口 $PORT"
		fi
		do_backup
	fi
	[ "$CHANNEL" = "stable" ] || warn "--channel $CHANNEL 只对 upgrade 生效，install 安装的是稳定版"

	arch=$(detect_arch)
	resolve_target
	ver="$NEW_VER"
	url=$(download_url "$arch" "$ver")

	step "安装 Lite-Plus $ver (${arch}) 到 $INSTALL_DIR"
	mkdir -p "$INSTALL_DIR" "$DATA_DIR" || die "无法创建 $INSTALL_DIR / $DATA_DIR"
	check_space

	step "下载 $url"
	dl "$url" "$BINARY.dl" || die "下载失败"
	verify_binary "$BINARY.dl" "$ver" || { rm -f "$BINARY.dl"; die "新二进制校验失败，已中止"; }
	mv -f "$BINARY.dl" "$BINARY" || die "替换二进制失败"

	write_init || die "写入 $INIT_SCRIPT 失败"
	rc-update add "$SERVICE" default >/dev/null 2>&1 \
		&& ok "已加入开机自启（default runlevel）" \
		|| warn "加入开机自启失败，可手动执行：rc-update add $SERVICE default"
	rc-service "$SERVICE" start >/dev/null 2>&1
	wait_healthy_loop || warn "等待服务就绪超时（约 2 分钟）"

	health_check || die "启动后健康检查失败，请看 $LOG_FILE"
	write_last_release_mark
	ip=$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
	[ -z "$ip" ] && ip="<本机IP>"
	info ""
	info "安装完成。访问 http://${ip}:${PORT}/"
	info "首次访问会跳 /install，请尽快创建管理员账号。"
}

# ------------------------------------------------------------------------------
# 升级
# ------------------------------------------------------------------------------
do_upgrade() {
	need_root; check_openrc
	guard_legacy_service
	resolve_port
	if [ ! -e "$BINARY" ]; then
		[ -f "$INIT_SCRIPT" ] && warn "发现 $INIT_SCRIPT，但 $BINARY 不存在"
		die "未检测到可用的 Lite-Plus 二进制。重新安装请用: sh $SELF install"
	fi
	[ -x "$BINARY" ] && [ -f "$BINARY" ] \
		|| die "$BINARY 不是可执行文件（权限或损坏）。修复：chmod +x $BINARY；确认要重装：sh $SELF install"
	CUR_VER=$(current_version) || die "无法读取 $BINARY 的版本号（二进制可能损坏）。确认要重装：sh $SELF install"

	arch=$(detect_arch)
	resolve_target
	url=$(download_url "$arch" "$NEW_VER")

	step "升级 Lite-Plus：$CUR_VER → $NEW_VER （通道 $CHANNEL）"
	if [ "$CUR_VER" = "$NEW_VER" ] && [ "$FORCE" != "1" ]; then
		if release_newer_than_last; then
			info "版本号未变（$NEW_VER），但检测到更新的发布（$NEW_TIME），继续同版本更新"
		elif [ -f "$INIT_SCRIPT" ]; then
			ok "当前已是 $CUR_VER，且没有更新的同版本发布，无需升级。（无条件重装/降级加 --force）"
			exit 0
		elif [ "$DRYRUN" = "1" ]; then
			ok "演练：当前已是 $CUR_VER，但缺少 $INIT_SCRIPT；真实执行会补建服务并启动（本次不做任何改动）"
			exit 0
		else
			ok "当前已是 $CUR_VER，但缺少 OpenRC 服务脚本，只补建服务（不重新下载）"
			ensure_init_script || die "补建服务脚本失败"
			rc-service "$SERVICE" start >/dev/null 2>&1
			wait_healthy_loop || warn "等待服务就绪超时（约 2 分钟）"
			health_check || die "启动后健康检查失败，请看 $LOG_FILE"
			write_last_release_mark
			ok "服务已补建并启动（端口 $PORT）"
			exit 0
		fi
	fi

	check_space
	# --dry-run 不写备份（否则会用同版本备份覆盖真正的回滚点）
	[ "$DRYRUN" = "1" ] || do_backup

	step "下载 $url"
	dl "$url" "$BINARY.dl" || die "下载失败，线上服务未受影响"
	verify_binary "$BINARY.dl" "$NEW_VER" || {
		rm -f "$BINARY.dl"
		die "新二进制校验失败，已中止。线上仍是 $CUR_VER，服务未受影响"
	}

	if [ "$DRYRUN" = "1" ]; then
		rm -f "$BINARY.dl"
		ok "演练完成：新版本校验通过，未做任何改动。（去掉 --dry-run 执行真实升级）"
		exit 0
	fi

	step "切换版本（停机中）"
	ensure_init_script
	rc-service "$SERVICE" stop >/dev/null 2>&1
	sleep 2
	mv -f "$BINARY.dl" "$BINARY" || die "替换二进制失败"
	rc-service "$SERVICE" start >/dev/null 2>&1
	info "已启动新版本，等待服务就绪（首次启动可能做数据迁移，最多约 2 分钟）"
	wait_healthy_loop || warn "等待服务就绪超时（约 2 分钟）"

	if health_check; then
		write_last_release_mark
		ok "升级完成：$CUR_VER → $(current_version)"
		info "官方回滚点（面板内可用）: ls $INSTALL_DIR/backup/"
	else
		warn "新版本健康检查失败，正在自动回滚…"
		do_rollback
		die "已回滚到 $CUR_VER，请查看 $LOG_FILE 排查"
	fi
}

# ------------------------------------------------------------------------------
# 状态
# ------------------------------------------------------------------------------
do_status() {
	resolve_port
	printf '%b\n' "${C_BLU}=== Lite-Plus 运行状态 ===${C_RST}"
	if [ -x "$BINARY" ]; then
		info "版本      : $(current_version) $("$BINARY" version 2>/dev/null | tail -n1 | awk '{print $2}')"
	else
		warn "未安装（$BINARY 不存在）"
		return 1
	fi
	st=$(rc-service "$SERVICE" status 2>&1 | sed -n 's/.*status: *//p' | tail -n1)
	info "服务状态  : ${st:-未知}"
	rl=$(rc-update show 2>/dev/null | grep -E "^ +$SERVICE " | awk -F'|' '{gsub(/ /,"",$2); print $2}')
	info "开机自启  : ${rl:-未注册}"
	info "监听端口  : $(netstat -tlnp 2>/dev/null | grep "${PORT}" | head -n1 || echo '无')"
	info "HTTP      : $(http_ok && echo "正常 (127.0.0.1:$PORT)" || echo '异常')"
	if [ -f /sys/fs/cgroup/memory.current ]; then
		mem_now=$(( $(cat /sys/fs/cgroup/memory.current) / 1048576 ))
		lim_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
		case "$lim_raw" in
			''|max|9223372036854771712) mem_max="无限制" ;;
			*) mem_max="$((lim_raw / 1048576))MB" ;;
		esac
		info "cgroup占用: ${mem_now}MB / ${mem_max}"
	fi
	info "磁盘剩余  : $(df -Ph "$INSTALL_DIR" | awk 'NR==2{print $4}')"
	if [ -d "$BACKUP_ROOT" ]; then
		info "备份目录  : $BACKUP_ROOT"
		ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -v '^\.' | sed 's/^/            /'
	fi
}

# ------------------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		install|upgrade|rollback|status) ACTION="$1"; ACTION_CLI=1; shift ;;
		--port)     [ $# -ge 2 ] || die "--port 缺少参数（端口号）"; PORT="$2"; PORT_CLI=1; shift 2 ;;
		--version)  [ $# -ge 2 ] || die "--version 缺少参数（版本号）"; OPT_VERSION="$2"; shift 2 ;;
		--channel)  [ $# -ge 2 ] || die "--channel 缺少参数（stable|snapshot）"; CHANNEL="$2"; shift 2 ;;
		--force)    FORCE=1; shift ;;
		--dry-run)  DRYRUN=1; shift ;;
		--no-backup) DO_BACKUP=0; shift ;;
		-h|--help)  usage ;;
		*) die "未知参数: $1（用 --help 查看用法）" ;;
	esac
done

# 没写 action 时自动判断：已装就升级，没装就安装（下载即执行，无需先看文档）
# 注意：只要发现安装痕迹但二进制不可用，就停下来让用户显式选，避免用默认端口重写线上服务脚本
if [ "$ACTION_CLI" = "0" ]; then
	if [ -x "$BINARY" ] && [ -f "$BINARY" ]; then
		ACTION="upgrade"
	elif [ -e "$BINARY" ] || [ -f "$INIT_SCRIPT" ] || [ -d "$DATA_DIR" ]; then
		die "检测到 Lite-Plus 的安装痕迹（$INIT_SCRIPT 或 $DATA_DIR），但 $BINARY 不是可执行文件。请先确认：要用默认端口重装就执行 sh $SELF install；只是想升级就修复二进制后执行 sh $SELF upgrade"
	else
		ACTION="install"
	fi
	info "未指定动作，自动选择：$ACTION（已安装 → upgrade，未安装 → install；可直接写 action 跳过本判断）" >&2
fi

case "$ACTION" in
	install)  do_install ;;
	upgrade)  do_upgrade ;;
	rollback) need_root; do_rollback ;;
	status)   do_status ;;
esac
