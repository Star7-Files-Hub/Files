#!/bin/sh
# ==============================================================================
# Lite → Lite-Plus（OpenRC）迁移脚本
# ==============================================================================
#
# 把 nuomiiiii/Lite（原项目）迁移到 nuomiiiii/Lite-Plus（新项目）。
#
# 适用：Alpine / OpenRC 上、由 lite-openrc.sh 或官方脚本安装的 Lite。
#       二进制 /opt/lite/Lite，数据目录 /opt/lite/data。
#
# 迁移要点（对齐官方「从 Lite 升级」）：
#   - 迁移前完整备份：二进制 + data 目录 + OpenRC 服务脚本
#   - 监听端口（HTTP -l / LITE_LISTEN）按原值保留，不会改成 Lite-Plus 默认 28777
#   - 换成 Lite-Plus 二进制，沿用原 data 目录；首次启动会做数据库迁移（请勿中断）
#   - 服务名从 lite 迁移为 lite-plus（与官方一致）
#   - 失败自动回滚：还原二进制 + data + 旧服务
#
# 用法：
#   sh lite-migrate-to-plus.sh                     # 迁移（默认最新稳定版）
#   sh lite-migrate-to-plus.sh --version 0.2.0     # 迁移到指定 Lite-Plus 版本
#   sh lite-migrate-to-plus.sh --port 27777        # 显式指定要保留的监听端口
#   sh lite-migrate-to-plus.sh --dry-run           # 只演练，不做任何改动
#   sh lite-migrate-to-plus.sh --force             # 已存在 lite-plus 服务时仍强制执行
#   sh lite-migrate-to-plus.sh rollback            # 回滚到迁移前的 Lite
#   sh lite-migrate-to-plus.sh --help
#
# 说明：
#   - 迁移 / 回滚需要 root
#   - 只用 POSIX sh，不需要 bash / jq
#   - 迁移后日常升级请使用 lite-plus-openrc.sh，而不是本脚本
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
MIGRATE_MARK="$BACKUP_ROOT/.last_migrate"
LAST_RELEASE_MARK="$BACKUP_ROOT/.last_release"
NEW_VER=""
NEW_TIME=""

PORT="27777"
PORT_CLI=0
CHANNEL="stable"
OPT_VERSION=""
FORCE=0
DRYRUN=0
ACTION="migrate"

case "${0##*/}" in
	sh|dash|ash|bash|ksh|zsh|busybox|"") SELF="lite-migrate-to-plus.sh" ;;
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
Lite → Lite-Plus（OpenRC）迁移脚本

用法：
  sh lite-migrate-to-plus.sh                     # 迁移（默认最新稳定版）
  sh lite-migrate-to-plus.sh --version 0.2.0     # 迁移到指定 Lite-Plus 版本
  sh lite-migrate-to-plus.sh --port 27777        # 显式指定要保留的监听端口
  sh lite-migrate-to-plus.sh --channel snapshot  # 迁移到快照版（不推荐用于迁移）
  sh lite-migrate-to-plus.sh --dry-run           # 只演练，不做任何改动
  sh lite-migrate-to-plus.sh --force             # 已存在 lite-plus 服务时仍强制执行
  sh lite-migrate-to-plus.sh rollback            # 回滚到迁移前的 Lite
  sh lite-migrate-to-plus.sh --help

说明：
  - 迁移前会完整备份二进制、data 目录和旧服务脚本（保存在 /root/lite-backups）
  - 监听端口按原值保留（未检测到时默认 27777，可用 --port 覆盖）
  - 首次启动会做数据库迁移，脚本会等待健康检查通过，期间请勿中断
  - 迁移后日常升级请使用 lite-plus-openrc.sh
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

check_space() {
	need_kb=150000
	cs_dir="$INSTALL_DIR"
	while [ -n "$cs_dir" ] && [ "$cs_dir" != "/" ] && [ ! -d "$cs_dir" ]; do
		cs_dir=$(dirname "$cs_dir")
	done
	avail=$(df -Pk "$cs_dir" 2>/dev/null | awk 'NR==2{print $4}')
	[ -n "$avail" ] || return 0
	if [ "$avail" -lt "$need_kb" ]; then
		die "磁盘空间不足：迁移需要约 150MB（不含 data 备份，data 越大需要越多）。当前可用 $((avail / 1024))MB"
	fi
	ok "磁盘可用 $((avail / 1024))MB"
}

# ------------------------------------------------------------------------------
# 下载
# ------------------------------------------------------------------------------
dl() {
	if command -v curl >/dev/null 2>&1; then curl -fL --retry 2 -o "$2" "$1"; return $?; fi
	if command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"; return $?; fi
	if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -O "$2" "$1"; return $?; fi
	die "没有可用的下载工具（curl / wget / uclient-fetch 都没有）"
}

dl_stdout() {
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

latest_version() {
	if [ "$CHANNEL" = "snapshot" ]; then
		v=$(dl_stdout "https://api.github.com/repos/${REPO}/releases" \
			| grep '"tag_name"' | grep 'Snapshot-' | head -n 1 \
			| sed -e 's/.*"tag_name" *: *"//' -e 's/".*//')
	else
		v=$(dl_stdout "https://api.github.com/repos/${REPO}/releases/latest" \
			| grep '"tag_name"' | head -n 1 \
			| sed -e 's/.*"tag_name" *: *"//' -e 's/".*//')
	fi
	if [ -z "$v" ]; then
		v=$(dl_stdout "https://github.com/${REPO}/releases/latest" \
			| grep -o "releases/tag/[0-9][^\"']*" | head -n 1 | sed 's|releases/tag/||')
	fi
	[ -n "$v" ] || die "获取最新版本号失败（GitHub API 可能限流，可稍后重试或用 --version 指定）"
	echo "$v"
}

# 取某个 tag 的最近更新时间：优先 updated_at，其次 published_at（ISO8601 UTC）
release_time_for_tag() { # release_time_for_tag <tag>
	json=$(dl_stdout "https://api.github.com/repos/${REPO}/releases/tags/$1")
	t=$(printf '%s\n' "$json" | grep '"updated_at"' | head -n 1 \
		| sed -e 's/.*"updated_at" *: *"//' -e 's/".*//')
	if [ -z "$t" ]; then
		t=$(printf '%s\n' "$json" | grep '"published_at"' | head -n 1 \
			| sed -e 's/.*"published_at" *: *"//' -e 's/".*//')
	fi
	printf '%s\n' "$t"
}

download_url() { # download_url <arch> <version>
	echo "https://github.com/${REPO}/releases/download/$2/Lite-linux-$1"
}

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
# 内存保护（与 lite-plus-openrc.sh 保持一致）
# ------------------------------------------------------------------------------
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
# OpenRC 服务脚本（新服务 lite-plus）
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
# 端口
# ------------------------------------------------------------------------------
port_from_file() { # port_from_file <file>
	[ -f "$1" ] || return 1
	p=$(sed -n '/^[[:space:]]*#/d; s/^[[:space:]]*command_args=.*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1)
	if [ -z "$p" ]; then
		p=$(sed -n '/^[[:space:]]*#/d; s/.*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1)
	fi
	[ -n "$p" ] || return 1
	printf '%s\n' "$p"
}

resolve_port() {
	[ "$PORT_CLI" = "1" ] && return 0
	if dp=$(port_from_file "$LEGACY_INIT_SCRIPT"); then
		PORT="$dp"
	elif dp=$(port_from_file "$INIT_SCRIPT"); then
		PORT="$dp"
	fi
}

# ------------------------------------------------------------------------------
# 健康检查
# ------------------------------------------------------------------------------
service_up() { # service_up [name]
	rc-service "${1:-$SERVICE}" status 2>/dev/null | grep -q "started"
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

health_ok() { # health_ok [name]
	service_up "${1:-$SERVICE}" || return 1
	http_ok || return 1
	[ -n "$(current_version)" ] || return 1
	return 0
}

# 等待迁移完成：首次启动会做数据库迁移，可能较慢。最多约 3 分钟。
wait_healthy() { # wait_healthy [name]
	n=1
	while [ "$n" -le 60 ]; do
		if health_ok "${1:-$SERVICE}"; then
			return 0
		fi
		if [ $((n % 10)) -eq 0 ]; then
			info "  仍在等待服务就绪（${n}/60）… 迁移期间请勿中断"
		fi
		sleep 3
		n=$((n + 1))
	done
	return 1
}

# ------------------------------------------------------------------------------
# 备份
# ------------------------------------------------------------------------------
do_backup() { # do_backup <cur_ver>
	cv="$1"
	TS=$(date +%Y%m%d_%H%M%S)
	mkdir -p "$BACKUP_ROOT"
	bin_backup="$BACKUP_ROOT/migrate-Lite.$cv.$TS"
	data_backup="-"
	init_backup="-"

	cp -a "$BINARY" "$bin_backup" || die "备份二进制失败"

	if [ -d "$DATA_DIR" ]; then
		data_backup="$BACKUP_ROOT/migrate-data.$TS.tar.gz"
		tar czf "$data_backup" -C "$INSTALL_DIR" data 2>/dev/null \
			&& ok "数据已备份: $data_backup" \
			|| { rm -f "$bin_backup"; die "数据备份失败，迁移已中止（请检查磁盘空间）"; }
	fi

	if [ -f "$LEGACY_INIT_SCRIPT" ]; then
		init_backup="$BACKUP_ROOT/migrate-initd-lite.$TS"
		cp -a "$LEGACY_INIT_SCRIPT" "$init_backup" || { rm -f "$bin_backup"; die "备份旧服务脚本失败"; }
	fi

	printf '%s\n%s\n%s\n%s\n%s\n' \
		"$bin_backup" "$data_backup" "$init_backup" "$LEGACY_PRESENT" "$PORT" \
		> "$MIGRATE_MARK"
	ok "迁移前备份完成（时间戳 $TS），回滚命令：sh $SELF rollback"
}

# ------------------------------------------------------------------------------
# 回滚
# ------------------------------------------------------------------------------
do_rollback() {
	need_root; check_openrc
	[ -f "$MIGRATE_MARK" ] || die "没有迁移回滚记录（找过 $MIGRATE_MARK）"
	bin_backup=$(sed -n '1p' "$MIGRATE_MARK")
	data_backup=$(sed -n '2p' "$MIGRATE_MARK")
	init_backup=$(sed -n '3p' "$MIGRATE_MARK")
	legacy_flag=$(sed -n '4p' "$MIGRATE_MARK")
	old_port=$(sed -n '5p' "$MIGRATE_MARK")
	[ -n "$bin_backup" ] && [ -f "$bin_backup" ] || die "二进制备份不存在: ${bin_backup:-<空>}"

	step "回滚到迁移前的 Lite"
	rc-service "$SERVICE" stop >/dev/null 2>&1
	rc-service "$LEGACY_SERVICE" stop >/dev/null 2>&1
	sleep 2

	# 还原二进制
	cp -a "$bin_backup" "$BINARY" || die "还原二进制失败"
	chmod +x "$BINARY"

	# 还原 data（Lite-Plus 首次启动会改写数据库，必须连数据一起还原）
	if [ "$data_backup" != "-" ] && [ -f "$data_backup" ]; then
		if [ -d "$DATA_DIR" ]; then
			mv "$DATA_DIR" "${DATA_DIR}.plus-migrated.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
		fi
		mkdir -p "$DATA_DIR"
		tar xzf "$data_backup" -C "$INSTALL_DIR" || die "还原数据失败"
		ok "数据已从 $data_backup 还原"
	fi

	# 还原服务状态：移除 lite-plus，恢复迁移前的 lite（如果存在）
	rc-update del "$SERVICE" >/dev/null 2>&1 || true
	rm -f "$INIT_SCRIPT" "/run/${SERVICE}.pid"

	if [ "$legacy_flag" = "1" ] && [ "$init_backup" != "-" ] && [ -f "$init_backup" ]; then
		cp -a "$init_backup" "$LEGACY_INIT_SCRIPT" || die "还原旧服务脚本失败"
		chmod +x "$LEGACY_INIT_SCRIPT" 2>/dev/null
		rc-update add "$LEGACY_SERVICE" default >/dev/null 2>&1 || true
		rc-service "$LEGACY_SERVICE" start >/dev/null 2>&1
		PORT="$old_port"
		if wait_healthy "$LEGACY_SERVICE"; then
			ok "回滚成功：Lite $(current_version)，服务 $LEGACY_SERVICE（端口 $PORT）"
		else
			die "回滚后服务仍异常，请检查日志"
		fi
	else
		ok "已还原 Lite 二进制与数据。迁移前没有 OpenRC 服务脚本，未自动启动服务。"
		info "手动启动：$BINARY server -l 0.0.0.0:${old_port:-27777}"
	fi
}

# ------------------------------------------------------------------------------
# 迁移
# ------------------------------------------------------------------------------
do_migrate() {
	need_root; check_openrc

	if [ ! -x "$BINARY" ] || [ ! -f "$BINARY" ]; then
		die "未找到可执行的 $BINARY。本脚本只用于从已安装的 Lite 迁移；全新安装请用 sh lite-plus-openrc.sh install"
	fi
	[ -d "$DATA_DIR" ] || warn "未找到数据目录 $DATA_DIR（可能是全新/异常安装，继续迁移）"

	if [ -f "$INIT_SCRIPT" ] && [ "$FORCE" != "1" ]; then
		die "已存在 $INIT_SCRIPT（看起来已经是 Lite-Plus）。如需强制重跑请加 --force；日常升级请用 sh lite-plus-openrc.sh upgrade"
	fi

	CUR_VER=$(current_version) || die "无法读取当前二进制版本号"
	LEGACY_PRESENT=0
	[ -f "$LEGACY_INIT_SCRIPT" ] && LEGACY_PRESENT=1

	resolve_port
	info "迁移将保留监听端口：$PORT"

	arch=$(detect_arch)
	NEW_VER=${OPT_VERSION:-$(latest_version)}
	NEW_TIME=$(release_time_for_tag "$NEW_VER")
	url=$(download_url "$arch" "$NEW_VER")

	step "准备从 Lite $CUR_VER 迁移到 Lite-Plus $NEW_VER (${arch})"
	if [ "$DRYRUN" = "1" ]; then
		info "演练（--dry-run）：不做任何改动。真实执行会："
		info "  1) 备份二进制 / data / 旧服务脚本到 $BACKUP_ROOT"
		info "  2) 下载并校验 Lite-Plus $NEW_VER"
		info "  3) 停机替换二进制，服务名 $LEGACY_SERVICE → $SERVICE（端口保留 $PORT）"
		info "  4) 启动并等待首次数据库迁移完成；失败自动回滚"
		exit 0
	fi

	check_space
	do_backup "$CUR_VER"

	step "下载 $url"
	dl "$url" "$BINARY.dl" || die "下载失败，线上服务未受影响"
	verify_binary "$BINARY.dl" "$NEW_VER" || { rm -f "$BINARY.dl"; die "新二进制校验失败，已中止。线上仍是 Lite $CUR_VER"; }

	step "切换版本（停机中，首次启动会做数据库迁移）"
	rc-service "$SERVICE" stop >/dev/null 2>&1
	rc-service "$LEGACY_SERVICE" stop >/dev/null 2>&1
	sleep 2
	mv -f "$BINARY.dl" "$BINARY" || die "替换二进制失败"
	chmod +x "$BINARY"

	write_init || die "写入 $INIT_SCRIPT 失败"
	if [ "$LEGACY_PRESENT" = "1" ]; then
		rc-update del "$LEGACY_SERVICE" >/dev/null 2>&1 || true
		rm -f "$LEGACY_INIT_SCRIPT" "/run/${LEGACY_SERVICE}.pid"
		ok "已移除旧服务 $LEGACY_SERVICE（服务名迁移为 $SERVICE）"
	fi
	rc-update add "$SERVICE" default >/dev/null 2>&1 \
		&& ok "已加入开机自启（default runlevel）" \
		|| warn "加入开机自启失败，可手动执行：rc-update add $SERVICE default"

	step "启动 Lite-Plus 并等待迁移完成（请勿中断）"
	rc-service "$SERVICE" start >/dev/null 2>&1

	if wait_healthy; then
		if [ -n "$NEW_TIME" ]; then
			mkdir -p "$BACKUP_ROOT"
			printf '%s|%s\n' "$NEW_VER" "$NEW_TIME" > "$LAST_RELEASE_MARK"
		fi
		ok "迁移完成：Lite $CUR_VER → Lite-Plus $(current_version)（端口 $PORT）"
		info "请打开管理页面确认节点、历史曲线、账单与远程功能正常；备份保留在 $BACKUP_ROOT"
		info "如需回退：sh $SELF rollback"
	else
		warn "新服务健康检查失败，正在自动回滚到 Lite…"
		do_rollback
		die "已回滚到 Lite $CUR_VER，请查看 $LOG_FILE 排查"
	fi
}

# ------------------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		migrate) ACTION="migrate"; shift ;;
		rollback) ACTION="rollback"; shift ;;
		--port)     [ $# -ge 2 ] || die "--port 缺少参数（端口号）"; PORT="$2"; PORT_CLI=1; shift 2 ;;
		--version)  [ $# -ge 2 ] || die "--version 缺少参数（版本号）"; OPT_VERSION="$2"; shift 2 ;;
		--channel)  [ $# -ge 2 ] || die "--channel 缺少参数（stable|snapshot）"; CHANNEL="$2"; shift 2 ;;
		--force)    FORCE=1; shift ;;
		--dry-run)  DRYRUN=1; shift ;;
		-h|--help)  usage ;;
		*) die "未知参数: $1（用 --help 查看用法）" ;;
	esac
done

case "$ACTION" in
	migrate)  do_migrate ;;
	rollback) do_rollback ;;
esac
