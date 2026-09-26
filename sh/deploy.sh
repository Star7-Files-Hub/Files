#!/usr/bin/env bash
#
# node-deploy: 一键部署 VLESS-Reality + Snell 节点
#
# 特性:
#   - VLESS-Reality 可选 Xray（默认）或 sing-box 核心
#   - Snell 使用官方 snell-server（默认 v4.1.1，可选 v5.0.1），兼容 Surge / Stash / Clash.Meta
#   - 交互式菜单 + 完整 CLI 参数，支持同时部署，复用出口 IP/域名，端口各自独立
#   - 自动生成 UUID / Reality 密钥 / shortId / PSK，自动写入 systemd 服务并启动
#   - 自动放行 ufw / firewalld / iptables 端口（可用 --no-firewall 关闭）
#   - 支持 --dry-run 生成配置到当前目录 dry-run/，不修改系统
#
# 用法:
#   bash deploy.sh                          # 交互式菜单
#   bash deploy.sh --mode both --address 1.2.3.4 \
#        --vless-port 443 --vless-sni www.microsoft.com \
#        --snell-port 8443 --snell-domain www.bing.com
#   bash deploy.sh --info                   # 查看节点信息
#   bash deploy.sh --uninstall              # 卸载
#
# 详细说明见同目录 README.md
#
set -Eeuo pipefail

SCRIPT_NAME="node-deploy"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# 可被环境变量覆盖的路径
# ---------------------------------------------------------------------------
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
SNELL_BIN="${SNELL_BIN:-/usr/local/bin/snell-server}"

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
MODE=""
MODE_CLI="false"
ACTION=""
NODE_ADDRESS=""
CORE=""
VLESS_PORT=""
VLESS_SNI="www.microsoft.com"
VLESS_DEST_PORT="443"
VLESS_UUID=""
VLESS_PRIVATE_KEY=""
VLESS_PUBLIC_KEY=""
VLESS_SHORT_ID=""
VLESS_FLOW="xtls-rprx-vision"

SNELL_PORT=""
SNELL_DOMAIN="www.bing.com"
SNELL_PSK=""
SNELL_OBFS="tls"
SNELL_VERSION="4.1.1"
SNELL_IPV6="false"

SINGBOX_VERSION=""
SINGBOX_VERSION_FALLBACK="1.14.2"

ENABLE_BBR="false"
FORCE="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
NO_FIREWALL="false"
DEPS_INSTALLED="false"

OS_ID=""
OS_LIKE=""
PKG_MGR=""
ARCH=""
ARCH_RAW=""
XRAY_ASSET=""
SNELL_ARCH=""
SINGBOX_ARCH=""

# 路径在 init_paths 中初始化
CONFIG_DIR=""
CONFIG_FILE=""
XRAY_CONFIG=""
SINGBOX_CONFIG=""
SNELL_CONFIG=""
XRAY_SERVICE=""
SINGBOX_SERVICE=""
SNELL_SERVICE=""
DRY_RUN_DIR=""

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${CYAN}$*${NC}"; }

trap 'err "命令失败：行 $LINENO，退出码 $?"' ERR

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行：sudo bash $0 ..."
  fi
}

# 预扫描 --dry-run，便于在解析参数前确定路径
pre_scan_dry_run() {
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN="true" ;;
    esac
  done
}

init_paths() {
  if [[ "$DRY_RUN" == "true" ]]; then
    DRY_RUN_DIR="${PWD}/dry-run"
    CONFIG_DIR="${DRY_RUN_DIR}/etc/node-deploy"
    CONFIG_FILE="${CONFIG_DIR}/config.env"
    XRAY_CONFIG="${DRY_RUN_DIR}/usr/local/etc/xray/config.json"
    SINGBOX_CONFIG="${DRY_RUN_DIR}/etc/sing-box/config.json"
    SNELL_CONFIG="${DRY_RUN_DIR}/etc/snell/snell-server.conf"
    XRAY_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/xray.service"
    SINGBOX_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/sing-box.service"
    SNELL_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/snell.service"
  else
    CONFIG_DIR="/etc/node-deploy"
    CONFIG_FILE="${CONFIG_DIR}/config.env"
    XRAY_CONFIG="/usr/local/etc/xray/config.json"
    SINGBOX_CONFIG="/etc/sing-box/config.json"
    SNELL_CONFIG="/etc/snell/snell-server.conf"
    XRAY_SERVICE="/etc/systemd/system/xray.service"
    SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
    SNELL_SERVICE="/etc/systemd/system/snell.service"
  fi
}

# ---------------------------------------------------------------------------
# 系统识别
# ---------------------------------------------------------------------------
detect_os() {
  OS_ID=""
  OS_LIKE=""
  PKG_MGR=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="centos"
  fi

  case "$OS_ID" in
    ubuntu|debian|linuxmint|raspbian|kali) PKG_MGR="apt" ;;
    centos|rhel|rocky|almalinux|fedora|ol|amzn)
      if command_exists dnf; then PKG_MGR="dnf"
      elif command_exists yum; then PKG_MGR="yum"
      fi
      ;;
    alpine) PKG_MGR="apk" ;;
    arch|manjaro|endeavouros) PKG_MGR="pacman" ;;
  esac

  if [[ -z "$PKG_MGR" ]]; then
    if command_exists apt-get; then PKG_MGR="apt"
    elif command_exists dnf; then PKG_MGR="dnf"
    elif command_exists yum; then PKG_MGR="yum"
    elif command_exists apk; then PKG_MGR="apk"
    elif command_exists pacman; then PKG_MGR="pacman"
    fi
  fi

  if [[ -z "$PKG_MGR" ]]; then
    die "无法识别的发行版，请手动安装 curl wget unzip tar openssl ca-certificates 后重试"
  fi
}

detect_arch() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64)
      ARCH="amd64"
      XRAY_ASSET="Xray-linux-64.zip"
      SNELL_ARCH="amd64"
      SINGBOX_ARCH="amd64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      XRAY_ASSET="Xray-linux-arm64-v8a.zip"
      SNELL_ARCH="aarch64"
      SINGBOX_ARCH="arm64"
      ;;
    armv7l|armv7)
      ARCH="armv7"
      XRAY_ASSET="Xray-linux-arm32-v7a.zip"
      SNELL_ARCH="armv7l"
      SINGBOX_ARCH="armv7"
      ;;
    i386|i686)
      ARCH="386"
      XRAY_ASSET="Xray-linux-32.zip"
      SNELL_ARCH=""
      SINGBOX_ARCH="386"
      ;;
    *)
      die "不支持的 CPU 架构：$ARCH_RAW"
      ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 安装依赖：${pkgs[*]}"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf) dnf install -y "${pkgs[@]}" ;;
    yum) yum install -y "${pkgs[@]}" ;;
    apk) apk add --no-cache "${pkgs[@]}" ;;
    pacman) pacman -Sy --noconfirm "${pkgs[@]}" ;;
    *) die "未知包管理器：$PKG_MGR" ;;
  esac
}

install_deps() {
  log "安装基础依赖..."
  pkg_install curl wget unzip tar openssl ca-certificates
  # qrencode 是可选的，失败不影响主流程
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || true ;;
    dnf) dnf install -y qrencode >/dev/null 2>&1 || true ;;
    yum) yum install -y qrencode >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache qrencode >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm qrencode >/dev/null 2>&1 || true ;;
  esac
}

ensure_env() {
  if [[ -z "$OS_ID" ]]; then detect_os; fi
  if [[ -z "$ARCH" ]]; then detect_arch; fi
  if [[ "$DEPS_INSTALLED" != "true" && "$DRY_RUN" != "true" ]]; then
    install_deps
    DEPS_INSTALLED="true"
  fi
}

# ---------------------------------------------------------------------------
# 下载 / 解压
# ---------------------------------------------------------------------------
download() {
  local url="$1"
  local out="$2"
  local -a urls=()

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 下载 $url -> $out"
    return 0
  fi

  if [[ "$url" == *github.com* ]]; then
    urls=(
      "$url"
      "https://gh-proxy.com/${url}"
      "https://ghfast.top/${url}"
      "https://ghproxy.net/${url}"
    )
  else
    urls=("$url")
  fi

  local u
  for u in "${urls[@]}"; do
    log "下载：$u"
    if command_exists curl; then
      if curl -fL --connect-timeout 10 --max-time 300 -o "$out" "$u"; then
        [[ -s "$out" ]] && return 0
      fi
    fi
    if command_exists wget; then
      if wget -q --timeout=300 -O "$out" "$u"; then
        [[ -s "$out" ]] && return 0
      fi
    fi
  done
  die "下载失败：$url"
}

extract_zip() {
  local zip="$1"
  local dest="$2"
  mkdir -p "$dest"
  if command_exists unzip; then
    unzip -oq "$zip" -d "$dest"
  elif command_exists python3; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest"
  else
    die "缺少 unzip 或 python3，无法解压 $zip"
  fi
}

# ---------------------------------------------------------------------------
# 校验 / 生成
# ---------------------------------------------------------------------------
validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

is_domain() {
  local d="$1"
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

is_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets
  read -r -a octets <<< "$ip" || return 1
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    (( o <= 255 )) || return 1
  done
  return 0
}

is_ipv6() {
  [[ "$1" == *:* ]]
}

validate_host() {
  local h="$1"
  is_domain "$h" || is_ipv4 "$h" || is_ipv6 "$h"
}

validate_sni() {
  is_domain "$1"
}

url_encode() {
  local s="$1"
  if command_exists python3; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$s"
  else
    printf '%s' "$s" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/&/%26/g' -e 's/?/%3F/g'
  fi
}

format_host_for_url() {
  local h="$1"
  if is_ipv6 "$h"; then
    printf '[%s]\n' "$h"
  else
    printf '%s\n' "$h"
  fi
}

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command_exists xray; then
    "$XRAY_BIN" uuid 2>/dev/null || true
  elif command_exists sing-box; then
    "$SINGBOX_BIN" generate uuid 2>/dev/null || true
  elif command_exists python3; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    die "无法生成 UUID"
  fi
}

gen_psk() {
  if command_exists openssl; then
    openssl rand -base64 32 | tr -d '\n/+=' | cut -c1-32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32
  fi
}

gen_short_id() {
  if command_exists openssl; then
    openssl rand -hex 8
  else
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

gen_xray_keypair() {
  local out priv pub
  out="$("$XRAY_BIN" x25519 2>/dev/null || true)"
  priv="$(printf '%s\n' "$out" | grep -iE 'private' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
  pub="$(printf '%s\n' "$out" | grep -iE 'public|password' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"

  if [[ -z "$priv" ]]; then
    die "无法生成 Xray Reality 私钥"
  fi
  if [[ -z "$pub" ]]; then
    out="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null || true)"
    pub="$(printf '%s\n' "$out" | grep -iE 'public|password' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
  fi
  if [[ -z "$pub" ]]; then
    die "无法生成 Xray Reality 公钥"
  fi
  printf '%s|%s\n' "$priv" "$pub"
}

gen_singbox_keypair() {
  local out priv pub
  out="$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || true)"
  priv="$(printf '%s\n' "$out" | grep -iE 'private' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
  pub="$(printf '%s\n' "$out" | grep -iE 'public' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
  if [[ -z "$priv" || -z "$pub" ]]; then
    die "无法生成 sing-box Reality 密钥"
  fi
  printf '%s|%s\n' "$priv" "$pub"
}

# ---------------------------------------------------------------------------
# 端口 / 防火墙
# ---------------------------------------------------------------------------
port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  if command_exists netstat; then
    netstat -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  if command_exists lsof; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

ensure_port_available() {
  local port="$1"
  local label="$2"
  validate_port "$port" || die "${label}端口无效：$port"

  # dry-run 只生成配置，不检查真实端口占用
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  if port_in_use "$port"; then
    if [[ "$FORCE" == "true" ]]; then
      warn "${label}端口 $port 已被占用，但 --force 已指定，继续。"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "${label}端口 $port 已被占用。"
    else
      warn "${label}端口 $port 已被占用。"
      local ans
      read -r -p "是否仍要继续？[y/N]: " ans || true
      [[ "$ans" =~ ^[Yy]$ ]] || die "已取消。"
    fi
  fi
}

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"

  if [[ "$NO_FIREWALL" == "true" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 放行端口 ${port}/${proto}"
    return 0
  fi

  if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command_exists iptables; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || true
  fi
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

systemd_reload() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  if ! command_exists systemctl; then
    die "未检测到 systemd，当前脚本仅支持 systemd 系统"
  fi
  systemctl daemon-reload
}

service_enable_start() {
  local svc="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: systemctl enable --now ${svc}"
    return 0
  fi
  systemd_reload
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
  sleep 1
  if ! systemctl is-active --quiet "$svc"; then
    systemctl status "$svc" --no-pager -l || true
    die "$svc 启动失败"
  fi
  log "$svc 已启动"
}

service_stop_disable() {
  local svc="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 配置持久化
# ---------------------------------------------------------------------------
save_config() {
  mkdir -p "$CONFIG_DIR"
  {
    echo "# node-deploy configuration"
    echo "# generated at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'MODE=%q\n' "$MODE"
    printf 'NODE_ADDRESS=%q\n' "$NODE_ADDRESS"
    printf 'CORE=%q\n' "$CORE"
    printf 'VLESS_PORT=%q\n' "$VLESS_PORT"
    printf 'VLESS_SNI=%q\n' "$VLESS_SNI"
    printf 'VLESS_DEST_PORT=%q\n' "$VLESS_DEST_PORT"
    printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
    printf 'VLESS_PRIVATE_KEY=%q\n' "$VLESS_PRIVATE_KEY"
    printf 'VLESS_PUBLIC_KEY=%q\n' "$VLESS_PUBLIC_KEY"
    printf 'VLESS_SHORT_ID=%q\n' "$VLESS_SHORT_ID"
    printf 'VLESS_FLOW=%q\n' "$VLESS_FLOW"
    printf 'SNELL_PORT=%q\n' "$SNELL_PORT"
    printf 'SNELL_DOMAIN=%q\n' "$SNELL_DOMAIN"
    printf 'SNELL_PSK=%q\n' "$SNELL_PSK"
    printf 'SNELL_OBFS=%q\n' "$SNELL_OBFS"
    printf 'SNELL_VERSION=%q\n' "$SNELL_VERSION"
    printf 'SNELL_IPV6=%q\n' "$SNELL_IPV6"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Xray
# ---------------------------------------------------------------------------
install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    log "已存在 Xray：$XRAY_BIN"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 跳过下载 Xray"
    return 0
  fi

  log "安装 Xray-core..."
  local tmp url
  tmp="$(mktemp -d)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
  download "$url" "${tmp}/xray.zip"
  extract_zip "${tmp}/xray.zip" "${tmp}"
  local bin
  bin="$(find "$tmp" -type f -name xray -print -quit)"
  [[ -n "$bin" ]] || die "Xray 解压失败"
  install -m 0755 "$bin" "$XRAY_BIN"
  rm -rf "$tmp"
  log "Xray 版本：$("$XRAY_BIN" version 2>/dev/null | head -1 || true)"
}

configure_xray() {
  log "生成 Xray 配置..."
  write_file "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "${VLESS_FLOW}",
            "email": "node-deploy"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${VLESS_SNI}:${VLESS_DEST_PORT}",
          "xver": 0,
          "serverNames": [
            "${VLESS_SNI}"
          ],
          "privateKey": "${VLESS_PRIVATE_KEY}",
          "shortIds": [
            "${VLESS_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

  if [[ -x "$XRAY_BIN" ]]; then
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
      "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Xray 配置校验失败"
    fi
    log "Xray 配置校验通过"
  else
    warn "未找到 Xray 可执行文件，跳过配置校验"
  fi
}

write_xray_service() {
  write_file "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# sing-box
# ---------------------------------------------------------------------------
get_latest_singbox_version() {
  local tag=""
  if command_exists curl; then
    tag="$(curl -fsSL --connect-timeout 10 --max-time 20 \
      'https://api.github.com/repos/SagerNet/sing-box/releases/latest' 2>/dev/null \
      | grep -m1 '"tag_name"' \
      | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
  fi
  if [[ -z "$tag" ]] && command_exists curl; then
    tag="$(curl -fsSL --connect-timeout 10 --max-time 20 \
      'https://gh-proxy.com/https://api.github.com/repos/SagerNet/sing-box/releases/latest' 2>/dev/null \
      | grep -m1 '"tag_name"' \
      | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
  fi
  tag="${tag#v}"
  if [[ -z "$tag" ]]; then
    tag="$SINGBOX_VERSION_FALLBACK"
  fi
  printf '%s\n' "$tag"
}

install_singbox() {
  if [[ -x "$SINGBOX_BIN" ]]; then
    log "已存在 sing-box：$SINGBOX_BIN"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 跳过下载 sing-box"
    return 0
  fi

  log "安装 sing-box..."
  local version tmp url
  version="${SINGBOX_VERSION:-}"
  if [[ -z "$version" || "$version" == "latest" ]]; then
    version="$(get_latest_singbox_version)"
  fi
  version="${version#v}"

  tmp="$(mktemp -d)"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${SINGBOX_ARCH}.tar.gz"
  download "$url" "${tmp}/sing-box.tar.gz"
  tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name sing-box -print -quit)"
  [[ -n "$bin" ]] || die "sing-box 解压失败"
  install -m 0755 "$bin" "$SINGBOX_BIN"
  rm -rf "$tmp"
  log "sing-box 版本：$("$SINGBOX_BIN" version 2>/dev/null | head -1 || true)"
}

configure_singbox() {
  log "生成 sing-box 配置..."
  write_file "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "name": "node-deploy",
          "uuid": "${VLESS_UUID}",
          "flow": "${VLESS_FLOW}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${VLESS_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${VLESS_SNI}",
            "server_port": ${VLESS_DEST_PORT}
          },
          "private_key": "${VLESS_PRIVATE_KEY}",
          "short_id": [
            "${VLESS_SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  if [[ -x "$SINGBOX_BIN" ]]; then
    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
      "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" || die "sing-box 配置校验失败"
    fi
    log "sing-box 配置校验通过"
  else
    warn "未找到 sing-box 可执行文件，跳过配置校验"
  fi
}

write_singbox_service() {
  write_file "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Snell
# ---------------------------------------------------------------------------
install_snell() {
  if [[ -x "$SNELL_BIN" ]]; then
    log "已存在 snell-server：$SNELL_BIN"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 跳过下载 snell-server"
    return 0
  fi
  if [[ -z "$SNELL_ARCH" ]]; then
    die "Snell 官方服务端不支持当前架构：$ARCH_RAW"
  fi
  if [[ "$OS_ID" == "alpine" ]]; then
    warn "Alpine 使用 musl libc，Snell 官方二进制可能无法运行，建议使用 Debian/Ubuntu"
  fi

  log "安装 snell-server v${SNELL_VERSION}..."
  local tmp url
  tmp="$(mktemp -d)"
  url="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
  download "$url" "${tmp}/snell.zip"
  extract_zip "${tmp}/snell.zip" "${tmp}"
  local bin
  bin="$(find "$tmp" -type f -name 'snell-server*' -print -quit)"
  [[ -n "$bin" ]] || die "Snell 解压失败"
  install -m 0755 "$bin" "$SNELL_BIN"
  rm -rf "$tmp"
  log "Snell 版本：$("$SNELL_BIN" -v 2>&1 | head -1 || true)"
}

configure_snell() {
  log "生成 Snell 配置..."
  mkdir -p "$(dirname "$SNELL_CONFIG")"
  {
    echo "[snell-server]"
    echo "listen = 0.0.0.0:${SNELL_PORT}"
    echo "psk = ${SNELL_PSK}"
    echo "ipv6 = ${SNELL_IPV6}"
    case "$SNELL_OBFS" in
      tls)
        echo "obfs = tls"
        [[ -n "$SNELL_DOMAIN" ]] && echo "obfs-host = ${SNELL_DOMAIN}"
        ;;
      http)
        echo "obfs = http"
        [[ -n "$SNELL_DOMAIN" ]] && echo "obfs-host = ${SNELL_DOMAIN}"
        ;;
      none|"")
        : # 不写 obfs，即不混淆
        ;;
      *)
        die "不支持的 Snell obfs：${SNELL_OBFS}（可选 tls/http/none）"
        ;;
    esac
  } > "$SNELL_CONFIG"
  chmod 600 "$SNELL_CONFIG" 2>/dev/null || true

  if [[ -x "$SNELL_BIN" ]]; then
    local logfile
    logfile="$(mktemp)"
    timeout 2 "$SNELL_BIN" -c "$SNELL_CONFIG" >"$logfile" 2>&1 || true
    if ! grep -q "Start snell server" "$logfile"; then
      cat "$logfile" >&2
      rm -f "$logfile"
      die "Snell 配置校验失败"
    fi
    rm -f "$logfile"
    log "Snell 配置校验通过"
  else
    warn "未找到 snell-server 可执行文件，跳过配置校验"
  fi
}

write_snell_service() {
  write_file "$SNELL_SERVICE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${SNELL_BIN} -c ${SNELL_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# 交互输入
# ---------------------------------------------------------------------------
prompt_value() {
  local prompt="$1"
  local default="$2"
  local var=""
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  read -r -p "${prompt} [${default}]: " var || true
  printf '%s\n' "${var:-$default}"
}

prompt_port() {
  local prompt="$1"
  local default="$2"
  local p
  while true; do
    p="$(prompt_value "$prompt" "$default")"
    if validate_port "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
    warn "端口无效：$p"
    [[ "$NON_INTERACTIVE" == "true" ]] && die "非交互模式下端口无效：$p"
  done
}

prompt_host() {
  local prompt="$1"
  local default="$2"
  local h
  while true; do
    h="$(prompt_value "$prompt" "$default")"
    if validate_host "$h"; then
      printf '%s\n' "$h"
      return 0
    fi
    warn "域名/IP 无效：$h"
    [[ "$NON_INTERACTIVE" == "true" ]] && die "非交互模式下域名/IP 无效：$h"
  done
}

prompt_sni() {
  local prompt="$1"
  local default="$2"
  local d
  while true; do
    d="$(prompt_value "$prompt" "$default")"
    if validate_sni "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
    warn "SNI 必须是域名：$d"
    [[ "$NON_INTERACTIVE" == "true" ]] && die "非交互模式下 SNI 无效：$d"
  done
}

detect_public_ip() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '203.0.113.10\n'
    return 0
  fi
  local ip url
  for url in \
    "https://api.ipify.org" \
    "https://ip.sb" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://ipinfo.io/ip"; do
    ip="$(curl -fsSL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$ip" ]] && validate_host "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
  printf '%s\n' "${ip:-127.0.0.1}"
}

prompt_vless() {
  if [[ -z "$NODE_ADDRESS" ]]; then
    local detected
    detected="$(detect_public_ip)"
    NODE_ADDRESS="$(prompt_host "节点地址（客户端连接用，域名或 IP）" "$detected")"
  fi
  validate_host "$NODE_ADDRESS" || die "节点地址无效：$NODE_ADDRESS"
  if [[ "$NODE_ADDRESS" == "127.0.0.1" ]]; then
    warn "未能自动检测公网 IP，当前使用 127.0.0.1；建议用 --address 指定域名或公网 IP"
  fi

  if [[ -z "$CORE" ]]; then
    CORE="$(prompt_value "VLESS-Reality 核心 (xray/sing-box)" "xray")"
  fi
  case "$CORE" in
    xray|sing-box) ;;
    *) die "核心必须是 xray 或 sing-box，当前：$CORE" ;;
  esac

  VLESS_PORT="$(prompt_port "VLESS-Reality 监听端口" "${VLESS_PORT:-443}")"
  VLESS_SNI="$(prompt_sni "VLESS-Reality 伪装域名/SNI" "${VLESS_SNI:-www.microsoft.com}")"
  VLESS_DEST_PORT="$(prompt_port "伪装目标端口（通常 443）" "${VLESS_DEST_PORT:-443}")"
  [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(gen_uuid)"
  [[ -n "$VLESS_SHORT_ID" ]] || VLESS_SHORT_ID="$(gen_short_id)"
  [[ -n "$VLESS_FLOW" ]] || VLESS_FLOW="xtls-rprx-vision"
}

prompt_snell() {
  if [[ -z "$NODE_ADDRESS" ]]; then
    local detected
    detected="$(detect_public_ip)"
    NODE_ADDRESS="$(prompt_host "节点地址（客户端连接用，域名或 IP）" "$detected")"
  fi
  validate_host "$NODE_ADDRESS" || die "节点地址无效：$NODE_ADDRESS"
  if [[ "$NODE_ADDRESS" == "127.0.0.1" ]]; then
    warn "未能自动检测公网 IP，当前使用 127.0.0.1；建议用 --address 指定域名或公网 IP"
  fi

  SNELL_PORT="$(prompt_port "Snell 监听端口" "${SNELL_PORT:-8443}")"
  SNELL_OBFS="$(prompt_value "Snell 混淆 (tls/http/none)" "${SNELL_OBFS:-tls}")"
  case "$SNELL_OBFS" in
    tls|http|none) ;;
    *) die "Snell 混淆必须是 tls/http/none，当前：$SNELL_OBFS" ;;
  esac
  if [[ "$SNELL_OBFS" != "none" ]]; then
    SNELL_DOMAIN="$(prompt_host "Snell 伪装域名/obfs-host" "${SNELL_DOMAIN:-www.bing.com}")"
  else
    SNELL_DOMAIN=""
  fi
  [[ -n "$SNELL_PSK" ]] || SNELL_PSK="$(gen_psk)"
  SNELL_VERSION="$(prompt_value "Snell 服务端版本" "${SNELL_VERSION:-4.1.1}")"
  SNELL_VERSION="${SNELL_VERSION#v}"
  SNELL_IPV6="$(prompt_value "Snell 是否启用 IPv6 (true/false)" "${SNELL_IPV6:-false}")"
  case "$SNELL_IPV6" in
    true|false) ;;
    *) die "Snell IPv6 必须是 true 或 false，当前：$SNELL_IPV6" ;;
  esac
}

# ---------------------------------------------------------------------------
# 部署流程
# ---------------------------------------------------------------------------
deploy_vless() {
  ensure_env
  prompt_vless
  ensure_port_available "$VLESS_PORT" "VLESS-Reality"

  # 切换核心时停掉另一个核心，避免端口冲突
  if [[ "$DRY_RUN" != "true" ]]; then
    if [[ "$CORE" == "xray" ]]; then
      service_stop_disable sing-box
    else
      service_stop_disable xray
    fi
  fi

  if [[ "$CORE" == "xray" ]]; then
    install_xray
    if [[ -n "$VLESS_PRIVATE_KEY" && -n "$VLESS_PUBLIC_KEY" ]]; then
      log "使用已有 Reality 密钥"
    elif [[ -n "$VLESS_PRIVATE_KEY" || -n "$VLESS_PUBLIC_KEY" ]]; then
      die "请同时提供 --vless-private-key 和 --vless-public-key，或都不提供"
    elif [[ "$DRY_RUN" == "true" && ! -x "$XRAY_BIN" ]]; then
      VLESS_PRIVATE_KEY="dummy_private_key"
      VLESS_PUBLIC_KEY="dummy_public_key"
      warn "DRY-RUN: 未找到 Xray，使用占位 Reality 密钥"
    else
      local kp
      kp="$(gen_xray_keypair)"
      VLESS_PRIVATE_KEY="${kp%%|*}"
      VLESS_PUBLIC_KEY="${kp##*|}"
    fi
    configure_xray
    write_xray_service
    service_enable_start xray
  else
    install_singbox
    if [[ -n "$VLESS_PRIVATE_KEY" && -n "$VLESS_PUBLIC_KEY" ]]; then
      log "使用已有 Reality 密钥"
    elif [[ -n "$VLESS_PRIVATE_KEY" || -n "$VLESS_PUBLIC_KEY" ]]; then
      die "请同时提供 --vless-private-key 和 --vless-public-key，或都不提供"
    elif [[ "$DRY_RUN" == "true" && ! -x "$SINGBOX_BIN" ]]; then
      VLESS_PRIVATE_KEY="dummy_private_key"
      VLESS_PUBLIC_KEY="dummy_public_key"
      warn "DRY-RUN: 未找到 sing-box，使用占位 Reality 密钥"
    else
      local kp
      kp="$(gen_singbox_keypair)"
      VLESS_PRIVATE_KEY="${kp%%|*}"
      VLESS_PUBLIC_KEY="${kp##*|}"
    fi
    configure_singbox
    write_singbox_service
    service_enable_start sing-box
  fi

  open_firewall_port "$VLESS_PORT" tcp
}

deploy_snell() {
  ensure_env
  prompt_snell
  ensure_port_available "$SNELL_PORT" "Snell"

  install_snell
  configure_snell
  write_snell_service
  service_enable_start snell

  open_firewall_port "$SNELL_PORT" tcp
  # Snell v5 会额外监听 QUIC（UDP）
  if [[ "$SNELL_VERSION" == 5* ]]; then
    open_firewall_port "$SNELL_PORT" udp
  fi
}

# ---------------------------------------------------------------------------
# 信息输出
# ---------------------------------------------------------------------------
generate_vless_link() {
  local name="VLESS-Reality"
  local encoded_name
  local host
  encoded_name="$(url_encode "$name")"
  host="$(format_host_for_url "$NODE_ADDRESS")"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$VLESS_UUID" \
    "$host" \
    "$VLESS_PORT" \
    "$VLESS_FLOW" \
    "$VLESS_SNI" \
    "$VLESS_PUBLIC_KEY" \
    "$VLESS_SHORT_ID" \
    "$encoded_name"
}

generate_snell_surge() {
  local host
  host="$(format_host_for_url "$NODE_ADDRESS")"
  local line="Snell = snell, ${host}, ${SNELL_PORT}, psk=${SNELL_PSK}"
  case "$SNELL_OBFS" in
    tls) line+=", obfs=tls"; [[ -n "$SNELL_DOMAIN" ]] && line+=", obfs-host=${SNELL_DOMAIN}" ;;
    http) line+=", obfs=http"; [[ -n "$SNELL_DOMAIN" ]] && line+=", obfs-host=${SNELL_DOMAIN}" ;;
  esac
  if [[ "$SNELL_VERSION" == 5* ]]; then
    line+=", version=5"
  else
    line+=", version=4"
  fi
  printf '%s\n' "$line"
}

generate_snell_clash() {
  local version=4
  local server="$NODE_ADDRESS"
  [[ "$SNELL_VERSION" == 5* ]] && version=5
  if is_ipv6 "$NODE_ADDRESS"; then
    server="\"${NODE_ADDRESS}\""
  fi
  cat <<EOF
- name: Snell
  type: snell
  server: ${server}
  port: ${SNELL_PORT}
  psk: ${SNELL_PSK}
  version: ${version}
EOF
  if [[ "$SNELL_OBFS" == "tls" || "$SNELL_OBFS" == "http" ]]; then
    cat <<EOF
  obfs-opts:
    mode: ${SNELL_OBFS}
    host: ${SNELL_DOMAIN}
EOF
  fi
}

show_qr() {
  local link="$1"
  if command_exists qrencode; then
    qrencode -t ANSIUTF8 "$link" || true
  else
    warn "未安装 qrencode，跳过二维码"
  fi
}

show_info() {
  load_config || true
  echo
  echo "==================== 节点信息 ===================="
  echo "节点地址 : ${NODE_ADDRESS:-<未配置>}"
  echo "部署模式 : ${MODE:-<未配置>}"
  echo "配置文件 : ${CONFIG_FILE}"

  if [[ "${MODE}" == "vless" || "${MODE}" == "both" ]]; then
    echo
    info "--- VLESS-Reality ---"
    echo "核心       : ${CORE}"
    echo "端口       : ${VLESS_PORT}"
    echo "UUID       : ${VLESS_UUID}"
    echo "SNI/伪装域名: ${VLESS_SNI}"
    echo "目标端口   : ${VLESS_DEST_PORT}"
    echo "Flow       : ${VLESS_FLOW}"
    echo "PublicKey  : ${VLESS_PUBLIC_KEY}"
    echo "ShortId    : ${VLESS_SHORT_ID}"
    echo
    echo "分享链接："
    local link
    link="$(generate_vless_link)"
    echo "$link"
    echo
    show_qr "$link"
  fi

  if [[ "${MODE}" == "snell" || "${MODE}" == "both" ]]; then
    echo
    info "--- Snell ---"
    echo "版本       : ${SNELL_VERSION}"
    echo "端口       : ${SNELL_PORT}"
    echo "PSK        : ${SNELL_PSK}"
    echo "Obfs       : ${SNELL_OBFS}"
    echo "Obfs Host  : ${SNELL_DOMAIN}"
    echo
    echo "Surge / Stash 配置："
    generate_snell_surge
    echo
    echo "Clash.Meta 配置："
    generate_snell_clash
  fi
  echo "=================================================="
}

# ---------------------------------------------------------------------------
# BBR
# ---------------------------------------------------------------------------
enable_bbr() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 启用 BBR"
    return 0
  fi
  log "启用 BBR..."
  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$cc" == "bbr" ]]; then
    log "BBR 已启用"
  else
    warn "BBR 可能未启用，当前拥塞控制算法：${cc:-unknown}"
  fi
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
uninstall_all() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 卸载（仅清理 ${DRY_RUN_DIR}）"
    rm -rf "$DRY_RUN_DIR"
    return 0
  fi

  load_config || true
  log "停止并卸载 Xray / sing-box / Snell..."
  service_stop_disable xray
  service_stop_disable sing-box
  service_stop_disable snell

  rm -f "$XRAY_SERVICE" "$SINGBOX_SERVICE" "$SNELL_SERVICE"
  rm -f "$XRAY_BIN" "$SINGBOX_BIN" "$SNELL_BIN"
  rm -rf /usr/local/etc/xray /etc/sing-box /etc/snell
  rm -rf "$CONFIG_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  log "卸载完成。防火墙规则未自动删除，如有需要请手动清理。"
}

# ---------------------------------------------------------------------------
# 交互菜单
# ---------------------------------------------------------------------------
interactive_menu() {
  while true; do
    echo
    echo "=================================================="
    echo "        ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "=================================================="
    echo " 1. 部署/重装 VLESS-Reality"
    echo " 2. 部署/重装 Snell"
    echo " 3. 同时部署 VLESS-Reality + Snell"
    echo " 4. 查看节点信息"
    echo " 5. 启用 BBR"
    echo " 6. 卸载所有组件"
    echo " 0. 退出"
    echo "=================================================="
    local choice=""
    read -r -p "请选择 [0-6]: " choice || true
    case "$choice" in
      1)
        MODE="vless"
        deploy_vless
        save_config
        show_info
        ;;
      2)
        MODE="snell"
        deploy_snell
        save_config
        show_info
        ;;
      3)
        MODE="both"
        deploy_vless
        deploy_snell
        save_config
        show_info
        ;;
      4)
        show_info
        ;;
      5)
        enable_bbr
        ;;
      6)
        local ans=""
        read -r -p "确认卸载所有组件？[y/N]: " ans || true
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          uninstall_all
          exit 0
        fi
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择：$choice"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
一键部署 VLESS-Reality + Snell 节点

用法：
  # 一键运行（无需上传）
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)
  sudo bash <(wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)

  # 本地运行
  bash deploy.sh [选项]

模式：
  -m, --mode <vless|snell|both>   部署模式；不指定则进入交互菜单
  -a, --address <域名|IP>         客户端连接地址；同时部署时两者复用
      --core <xray|sing-box>      VLESS-Reality 核心，默认 xray

VLESS-Reality：
      --vless-port <端口>         监听端口，默认 443
      --vless-sni <域名>          伪装域名/SNI，默认 www.microsoft.com
      --vless-dest-port <端口>    伪装目标端口，默认 443
      --vless-uuid <UUID>         自定义 UUID，默认随机生成
      --vless-flow <flow>         默认 xtls-rprx-vision
      --vless-short-id <hex>      自定义 shortId，默认随机生成
      --vless-private-key <key>   自定义 Reality 私钥
      --vless-public-key <key>    自定义 Reality 公钥

Snell：
      --snell-port <端口>         监听端口，默认 8443
      --snell-domain <域名>       obfs-host/伪装域名，默认 www.bing.com
      --snell-psk <密钥>          PSK，默认随机生成
      --snell-obfs <tls|http|none> 混淆方式，默认 tls
      --snell-version <版本>      服务端版本，默认 4.1.1（可选 5.0.1）
      --snell-ipv6 <true|false>   是否启用 IPv6，默认 false

其他：
      --singbox-version <版本>    指定 sing-box 版本；默认自动获取最新
      --bbr                       启用 BBR
      --no-firewall               不自动放行防火墙端口
      --info                      查看当前节点信息
      --uninstall                 卸载所有组件
  -f, --force                     端口占用/重装时不再询问
  -y, --yes                       非交互模式，所有未指定项使用默认值
      --dry-run                   仅生成配置到 ./dry-run，不修改系统
  -h, --help                      显示帮助
      --version                   显示版本

示例：
  # 交互式
  bash $0

  # 同时部署，复用同一地址，端口独立
  bash $0 --mode both --address node.example.com \\
    --core xray \\
    --vless-port 443 --vless-sni www.microsoft.com \\
    --snell-port 8443 --snell-domain www.bing.com --snell-obfs tls

  # 非交互 + 自动默认值
  bash $0 --mode both --address 1.2.3.4 -y --force

  # 只部署 Snell v5
  bash $0 --mode snell --address 1.2.3.4 --snell-port 8443 \\
    --snell-domain www.bing.com --snell-version 5.0.1

  # 查看信息 / 卸载
  bash $0 --info
  bash $0 --uninstall
EOF
}

need_value() {
  [[ $# -ge 2 ]] || die "参数 $1 需要值"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mode)
        need_value "$@"
        MODE="$2"; MODE_CLI="true"; shift 2 ;;
      -a|--address)
        need_value "$@"
        NODE_ADDRESS="$2"; shift 2 ;;
      --core)
        need_value "$@"
        CORE="$2"; shift 2 ;;
      --vless-port)
        need_value "$@"
        VLESS_PORT="$2"; shift 2 ;;
      --vless-sni)
        need_value "$@"
        VLESS_SNI="$2"; shift 2 ;;
      --vless-dest-port)
        need_value "$@"
        VLESS_DEST_PORT="$2"; shift 2 ;;
      --vless-uuid)
        need_value "$@"
        VLESS_UUID="$2"; shift 2 ;;
      --vless-flow)
        need_value "$@"
        VLESS_FLOW="$2"; shift 2 ;;
      --vless-private-key)
        need_value "$@"
        VLESS_PRIVATE_KEY="$2"; shift 2 ;;
      --vless-public-key)
        need_value "$@"
        VLESS_PUBLIC_KEY="$2"; shift 2 ;;
      --vless-short-id)
        need_value "$@"
        VLESS_SHORT_ID="$2"; shift 2 ;;
      --snell-port)
        need_value "$@"
        SNELL_PORT="$2"; shift 2 ;;
      --snell-domain)
        need_value "$@"
        SNELL_DOMAIN="$2"; shift 2 ;;
      --snell-psk)
        need_value "$@"
        SNELL_PSK="$2"; shift 2 ;;
      --snell-obfs)
        need_value "$@"
        SNELL_OBFS="$2"; shift 2 ;;
      --snell-version)
        need_value "$@"
        SNELL_VERSION="$2"; shift 2 ;;
      --snell-ipv6)
        need_value "$@"
        SNELL_IPV6="$2"; shift 2 ;;
      --singbox-version)
        need_value "$@"
        SINGBOX_VERSION="$2"; shift 2 ;;
      --bbr)
        ENABLE_BBR="true"; shift ;;
      --no-firewall)
        NO_FIREWALL="true"; shift ;;
      --info)
        ACTION="info"; shift ;;
      --uninstall)
        ACTION="uninstall"; shift ;;
      --reinstall)
        FORCE="true"; shift ;;
      -f|--force)
        FORCE="true"; shift ;;
      -y|--yes|--non-interactive)
        NON_INTERACTIVE="true"; shift ;;
      --dry-run)
        DRY_RUN="true"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --version)
        echo "$SCRIPT_VERSION"; exit 0 ;;
      *)
        die "未知参数：$1（使用 --help 查看帮助）" ;;
    esac
  done

  if [[ -n "$MODE" ]]; then
    case "$MODE" in
      vless|snell|both) ;;
      *) die "--mode 必须是 vless、snell 或 both，当前：$MODE" ;;
    esac
  fi

  SNELL_VERSION="${SNELL_VERSION#v}"
  SINGBOX_VERSION="${SINGBOX_VERSION#v}"

  case "$SNELL_IPV6" in
    true|false) ;;
    *) die "--snell-ipv6 必须是 true 或 false，当前：$SNELL_IPV6" ;;
  esac
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
main() {
  # 帮助和版本优先处理
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help) usage; exit 0 ;;
      --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    esac
  done

  local args_count=$#
  pre_scan_dry_run "$@"
  init_paths
  require_root
  load_config || true

  # 无参数时始终进入交互菜单，避免读取到旧配置后直接重装
  if [[ $args_count -eq 0 ]]; then
    detect_os
    detect_arch
    interactive_menu
    exit 0
  fi

  parse_args "$@"

  if [[ "$ACTION" == "info" ]]; then
    show_info
    exit 0
  fi
  if [[ "$ACTION" == "uninstall" ]]; then
    uninstall_all
    exit 0
  fi
  if [[ "$ENABLE_BBR" == "true" ]]; then
    enable_bbr
  fi

  # 只执行 --bbr 且没有显式 --mode 时，启用后退出
  if [[ "$MODE_CLI" != "true" && "$ENABLE_BBR" == "true" && -z "$ACTION" ]]; then
    exit 0
  fi

  if [[ -z "$MODE" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      usage
      die "非交互模式必须指定 --mode"
    fi
    detect_os
    detect_arch
    interactive_menu
    exit 0
  fi

  case "$MODE" in
    vless)
      deploy_vless
      ;;
    snell)
      deploy_snell
      ;;
    both)
      deploy_vless
      deploy_snell
      ;;
  esac

  save_config
  show_info
}

main "$@"
