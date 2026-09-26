#!/usr/bin/env bash
#
# node-deploy: 一键部署 VLESS-Reality + Snell 节点
#
# 特性:
#   - VLESS-Reality 可选 sing-box（默认）或 Xray 核心
#   - Snell 使用官方 snell-server（默认 v4.1.1，可选 v5.0.1），兼容 Surge / Stash / Clash.Meta
#   - 交互式菜单 + 完整 CLI 参数，支持同时部署，复用出口 IP/域名，端口各自独立
#   - 自动生成 UUID / Reality 密钥 / shortId / PSK，自动写入 systemd / OpenRC 服务并启动
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

# 明确要求 bash；Alpine 等系统请先安装 bash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "请使用 bash 运行此脚本：bash $0" >&2
  exit 1
fi

set -Eeuo pipefail

# 兼容 Alpine 等系统：确保 /sbin、/usr/sbin 在 PATH 中（rc-service、iptables、sysctl 等）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_NAME="node-deploy"
SCRIPT_VERSION="1.1.0"

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
SNELL_ENGINE=""
SNELL_ENGINE_CLI="false"

ANYTLS_PORT=""
ANYTLS_SNI="www.microsoft.com"
ANYTLS_DEST_PORT="443"
ANYTLS_PASSWORD=""
ANYTLS_USER="node-deploy"
ANYTLS_SECURITY="tls"
ANYTLS_PRIVATE_KEY=""
ANYTLS_PUBLIC_KEY=""
ANYTLS_SHORT_ID=""
ANYTLS_DRY_RUN_DUMMY_CERT="false"

NOWHERE_BIN="${NOWHERE_BIN:-/usr/local/bin/nowhere}"
NOWHERE_PORT=""
NOWHERE_KEY=""
NOWHERE_TLS="1"
NOWHERE_CRT=""
NOWHERE_TLS_KEY=""
NOWHERE_MORPH="0"
NOWHERE_CLIENT="both"
NOWHERE_VERSION="v2.1.1"
NOWHERE_LISTEN_HOST=""
NOWHERE_PUBLIC_HOST=""
NOWHERE_PORTAL=""
NOWHERE_RATE="0"
NOWHERE_ETAR="0"
NOWHERE_LOG="info"

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
INIT_SYSTEM=""
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
SNELL_SINGBOX_CONFIG=""
ANYTLS_CONFIG=""
ANYTLS_CERT=""
ANYTLS_KEY=""
NOWHERE_CONFIG=""
NOWHERE_SERVICE=""
NOWHERE_RUNNER=""
XRAY_SERVICE=""
SINGBOX_SERVICE=""
SNELL_SERVICE=""
SNELL_SINGBOX_SERVICE=""
ANYTLS_SERVICE=""
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

pause_any_key() {
  echo
  echo -n "按任意键返回菜单..."
  local _dummy=""
  read -r -s -n 1 _dummy || true
  # 清掉按 Enter 留下的换行，避免回到菜单后读到空选项
  read -r -t 0.05 -n 1000 -s _dummy || true
  echo
}

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
  detect_init
  if [[ "$DRY_RUN" == "true" ]]; then
    DRY_RUN_DIR="${PWD}/dry-run"
    CONFIG_DIR="${DRY_RUN_DIR}/etc/node-deploy"
    CONFIG_FILE="${CONFIG_DIR}/config.env"
    XRAY_CONFIG="${DRY_RUN_DIR}/usr/local/etc/xray/config.json"
    SINGBOX_CONFIG="${DRY_RUN_DIR}/etc/sing-box/config.json"
    SNELL_CONFIG="${DRY_RUN_DIR}/etc/snell/snell-server.conf"
    SNELL_SINGBOX_CONFIG="${DRY_RUN_DIR}/etc/sing-box/snell.json"
    ANYTLS_CONFIG="${DRY_RUN_DIR}/etc/sing-box/anytls.json"
    ANYTLS_CERT="${DRY_RUN_DIR}/etc/sing-box/anytls.crt"
    ANYTLS_KEY="${DRY_RUN_DIR}/etc/sing-box/anytls.key"
    NOWHERE_CONFIG="${DRY_RUN_DIR}/etc/nowhere/nowhere.env"
    NOWHERE_RUNNER="${DRY_RUN_DIR}/etc/nowhere/run.sh"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      XRAY_SERVICE="${DRY_RUN_DIR}/etc/init.d/xray"
      SINGBOX_SERVICE="${DRY_RUN_DIR}/etc/init.d/sing-box"
      SNELL_SERVICE="${DRY_RUN_DIR}/etc/init.d/snell"
      SNELL_SINGBOX_SERVICE="${DRY_RUN_DIR}/etc/init.d/sing-box-snell"
      ANYTLS_SERVICE="${DRY_RUN_DIR}/etc/init.d/sing-box-anytls"
      NOWHERE_SERVICE="${DRY_RUN_DIR}/etc/init.d/nowhere"
    else
      XRAY_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/xray.service"
      SINGBOX_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/sing-box.service"
      SNELL_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/snell.service"
      SNELL_SINGBOX_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/sing-box-snell.service"
      ANYTLS_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/sing-box-anytls.service"
      NOWHERE_SERVICE="${DRY_RUN_DIR}/etc/systemd/system/nowhere.service"
    fi
  else
    CONFIG_DIR="/etc/node-deploy"
    CONFIG_FILE="${CONFIG_DIR}/config.env"
    XRAY_CONFIG="/usr/local/etc/xray/config.json"
    SINGBOX_CONFIG="/etc/sing-box/config.json"
    SNELL_CONFIG="/etc/snell/snell-server.conf"
    SNELL_SINGBOX_CONFIG="/etc/sing-box/snell.json"
    ANYTLS_CONFIG="/etc/sing-box/anytls.json"
    ANYTLS_CERT="/etc/sing-box/anytls.crt"
    ANYTLS_KEY="/etc/sing-box/anytls.key"
    NOWHERE_CONFIG="/etc/nowhere/nowhere.env"
    NOWHERE_RUNNER="/etc/nowhere/run.sh"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
      XRAY_SERVICE="/etc/init.d/xray"
      SINGBOX_SERVICE="/etc/init.d/sing-box"
      SNELL_SERVICE="/etc/init.d/snell"
      SNELL_SINGBOX_SERVICE="/etc/init.d/sing-box-snell"
      ANYTLS_SERVICE="/etc/init.d/sing-box-anytls"
      NOWHERE_SERVICE="/etc/init.d/nowhere"
    else
      XRAY_SERVICE="/etc/systemd/system/xray.service"
      SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
      SNELL_SERVICE="/etc/systemd/system/snell.service"
      SNELL_SINGBOX_SERVICE="/etc/systemd/system/sing-box-snell.service"
      ANYTLS_SERVICE="/etc/systemd/system/sing-box-anytls.service"
      NOWHERE_SERVICE="/etc/systemd/system/nowhere.service"
    fi
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

detect_init() {
  INIT_SYSTEM=""
  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    INIT_SYSTEM="systemd"
  elif command_exists rc-service && command_exists rc-update; then
    INIT_SYSTEM="openrc"
  else
    INIT_SYSTEM="unknown"
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
  pkg_install bash curl wget unzip tar openssl ca-certificates
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

# 官方 Snell 二进制依赖 glibc 的 /lib64/ld-linux-x86-64.so.2，
# 在 Alpine/musl 上会报 "Not a valid dynamic program"，必须提前拦截。
check_snell_platform() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  if [[ -z "$OS_ID" ]]; then detect_os; fi

  local libc=""
  if command_exists ldd; then
    libc="$(ldd --version 2>&1 | head -1 || true)"
  fi

  if [[ "$OS_ID" == "alpine" || "$libc" == *musl* ]]; then
    err "当前系统是 musl（Alpine 等），官方 Snell 服务端依赖 glibc 的 /lib64/ld-linux-x86-64.so.2，无法运行。"
    return 1
  fi
  return 0
}

default_snell_engine() {
  if [[ -z "$OS_ID" ]]; then detect_os; fi
  local libc=""
  if command_exists ldd; then
    libc="$(ldd --version 2>&1 | head -1 || true)"
  fi
  if [[ "$OS_ID" == "alpine" || "$libc" == *musl* ]]; then
    printf 'singbox\n'
  else
    printf 'official\n'
  fi
}

resolve_snell_engine() {
  if [[ -n "$SNELL_ENGINE" ]]; then
    case "$SNELL_ENGINE" in
      official|singbox) ;;
      *) die "--snell-engine 必须是 official 或 singbox，当前：$SNELL_ENGINE" ;;
    esac
    return 0
  fi
  SNELL_ENGINE="$(default_snell_engine)"
}

validate_anytls_security() {
  case "$ANYTLS_SECURITY" in
    tls|reality) ;;
    *) die "--anytls-security 必须是 tls 或 reality，当前：$ANYTLS_SECURITY" ;;
  esac
}

generate_self_signed_cert() {
  local cert="$1" key="$2" cn="$3"
  mkdir -p "$(dirname "$cert")"
  if [[ -s "$cert" && -s "$key" ]]; then
    log "已存在自签证书：$cert"
    return 0
  fi
  if command_exists openssl; then
    log "生成自签证书（CN=${cn}）..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$key" -out "$cert" -days 3650 \
      -subj "/CN=${cn}" >/dev/null 2>&1 || die "生成自签证书失败"
    chmod 600 "$key" 2>/dev/null || true
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN: 未找到 openssl，写入占位证书（跳过 AnyTLS 配置校验）"
    printf 'dry-run cert\n' > "$cert"
    printf 'dry-run key\n' > "$key"
    ANYTLS_DRY_RUN_DUMMY_CERT="true"
    return 0
  fi
  die "需要 openssl 生成 AnyTLS 自签证书"
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
  elif command_exists od; then
    head -c 32 /dev/urandom | od -An -t x1 | tr -d ' \n' | cut -c1-32
  elif command_exists hexdump; then
    head -c 32 /dev/urandom | hexdump -v -e '/1 "%02x"' | cut -c1-32
  else
    die "无法生成 PSK：缺少 openssl/od/hexdump"
  fi
}

gen_short_id() {
  if command_exists openssl; then
    openssl rand -hex 8
  elif command_exists od; then
    head -c 8 /dev/urandom | od -An -t x1 | tr -d ' \n'
  elif command_exists hexdump; then
    head -c 8 /dev/urandom | hexdump -v -e '/1 "%02x"'
  else
    die "无法生成 shortId：缺少 openssl/od/hexdump"
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

port_in_use_udp() {
  local port="$1"
  if command_exists ss; then
    ss -lun 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  if command_exists netstat; then
    netstat -lun 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  if command_exists lsof; then
    lsof -iUDP:"$port" >/dev/null 2>&1 && return 0
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

ensure_udp_port_available() {
  local port="$1"
  local label="$2"
  validate_port "$port" || die "${label}端口无效：$port"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  if port_in_use_udp "$port"; then
    if [[ "$FORCE" == "true" ]]; then
      warn "${label} UDP 端口 $port 已被占用，但 --force 已指定，继续。"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "${label} UDP 端口 $port 已被占用。"
    else
      warn "${label} UDP 端口 $port 已被占用。"
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
# systemd / OpenRC 服务管理
# ---------------------------------------------------------------------------
write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

init_reload() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  case "$INIT_SYSTEM" in
    systemd)
      if ! command_exists systemctl; then
        die "未检测到 systemctl，无法使用 systemd 管理服务"
      fi
      systemctl daemon-reload
      ;;
    openrc)
      # OpenRC 不需要 daemon-reload
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_enable_start() {
  local svc="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    case "$INIT_SYSTEM" in
      openrc) log "DRY-RUN: rc-update add ${svc} default && rc-service ${svc} restart" ;;
      *)      log "DRY-RUN: systemctl enable --now ${svc}" ;;
    esac
    return 0
  fi

  case "$INIT_SYSTEM" in
    systemd)
      init_reload
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl restart "$svc"
      sleep 1
      if ! systemctl is-active --quiet "$svc"; then
        systemctl status "$svc" --no-pager -l || true
        die "$svc 启动失败"
      fi
      ;;
    openrc)
      rc-update add "$svc" default >/dev/null 2>&1 || true
      rc-service "$svc" restart
      sleep 1
      if ! rc-service "$svc" status >/dev/null 2>&1; then
        rc-service "$svc" status || true
        die "$svc 启动失败"
      fi
      ;;
    *)
      die "未检测到 systemd 或 OpenRC，无法启动 $svc"
      ;;
  esac
  log "$svc 已启动"
}

service_stop_disable() {
  local svc="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service "$svc" stop >/dev/null 2>&1 || true
      rc-update del "$svc" default >/dev/null 2>&1 || true
      ;;
  esac
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
    printf 'SNELL_ENGINE=%q\n' "$SNELL_ENGINE"
    printf 'ANYTLS_PORT=%q\n' "$ANYTLS_PORT"
    printf 'ANYTLS_SNI=%q\n' "$ANYTLS_SNI"
    printf 'ANYTLS_DEST_PORT=%q\n' "$ANYTLS_DEST_PORT"
    printf 'ANYTLS_PASSWORD=%q\n' "$ANYTLS_PASSWORD"
    printf 'ANYTLS_USER=%q\n' "$ANYTLS_USER"
    printf 'ANYTLS_SECURITY=%q\n' "$ANYTLS_SECURITY"
    printf 'ANYTLS_PRIVATE_KEY=%q\n' "$ANYTLS_PRIVATE_KEY"
    printf 'ANYTLS_PUBLIC_KEY=%q\n' "$ANYTLS_PUBLIC_KEY"
    printf 'ANYTLS_SHORT_ID=%q\n' "$ANYTLS_SHORT_ID"
    printf 'NOWHERE_PORT=%q\n' "$NOWHERE_PORT"
    printf 'NOWHERE_KEY=%q\n' "$NOWHERE_KEY"
    printf 'NOWHERE_TLS=%q\n' "$NOWHERE_TLS"
    printf 'NOWHERE_CRT=%q\n' "$NOWHERE_CRT"
    printf 'NOWHERE_TLS_KEY=%q\n' "$NOWHERE_TLS_KEY"
    printf 'NOWHERE_MORPH=%q\n' "$NOWHERE_MORPH"
    printf 'NOWHERE_CLIENT=%q\n' "$NOWHERE_CLIENT"
    printf 'NOWHERE_VERSION=%q\n' "$NOWHERE_VERSION"
    printf 'NOWHERE_LISTEN_HOST=%q\n' "$NOWHERE_LISTEN_HOST"
    printf 'NOWHERE_PUBLIC_HOST=%q\n' "$NOWHERE_PUBLIC_HOST"
    printf 'NOWHERE_PORTAL=%q\n' "$NOWHERE_PORTAL"
    printf 'NOWHERE_RATE=%q\n' "$NOWHERE_RATE"
    printf 'NOWHERE_ETAR=%q\n' "$NOWHERE_ETAR"
    printf 'NOWHERE_LOG=%q\n' "$NOWHERE_LOG"
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
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    write_file "$XRAY_SERVICE" <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG}"
pidfile="/run/xray.pid"
command_background="yes"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
    chmod +x "$XRAY_SERVICE" 2>/dev/null || true
    return 0
  fi

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
  local suffix=""
  if [[ "$OS_ID" == "alpine" ]]; then
    suffix="-musl"
  fi
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${SINGBOX_ARCH}${suffix}.tar.gz"
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
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    write_file "$SINGBOX_SERVICE" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${SINGBOX_BIN}"
command_args="run -c ${SINGBOX_CONFIG}"
pidfile="/run/sing-box.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
    chmod +x "$SINGBOX_SERVICE" 2>/dev/null || true
    return 0
  fi

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

# 通用的 sing-box 辅助服务（Snell / AnyTLS 各跑一个独立进程）
write_singbox_aux_service() {
  local svc_name="$1"
  local svc_config="$2"
  local svc_file="$3"
  local pidfile="/run/${svc_name}.pid"
  local out_log="/var/log/${svc_name}.log"
  local err_log="/var/log/${svc_name}.err"

  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    write_file "$svc_file" <<EOF
#!/sbin/openrc-run
name="${svc_name}"
description="${svc_name} service"
command="${SINGBOX_BIN}"
command_args="run -c ${svc_config}"
pidfile="${pidfile}"
command_background="yes"
output_log="${out_log}"
error_log="${err_log}"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
    chmod +x "$svc_file" 2>/dev/null || true
    return 0
  fi

  write_file "$svc_file" <<EOF
[Unit]
Description=${svc_name} service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${svc_config}
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
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    write_file "$SNELL_SERVICE" <<EOF
#!/sbin/openrc-run
name="snell"
description="Snell Proxy Service"
command="${SNELL_BIN}"
command_args="-c ${SNELL_CONFIG}"
pidfile="/run/snell.pid"
command_background="yes"
output_log="/var/log/snell.log"
error_log="/var/log/snell.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
    chmod +x "$SNELL_SERVICE" 2>/dev/null || true
    return 0
  fi

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
# sing-box Snell / AnyTLS
# ---------------------------------------------------------------------------
configure_snell_singbox() {
  log "生成 sing-box Snell 配置..."
  local listen_host="0.0.0.0"
  [[ "$SNELL_IPV6" == "true" ]] && listen_host="::"

  local version_line mode_line
  if [[ "$SNELL_VERSION" == 6* ]]; then
    version_line='"version": 6'
    mode_line='"mode": "default"'
  else
    version_line='"version": 5'
    case "$SNELL_OBFS" in
      http) mode_line='"obfs_mode": "http"' ;;
      none) mode_line='"obfs_mode": "none"' ;;
      *) die "sing-box Snell 不支持 obfs=${SNELL_OBFS}，请使用 http/none" ;;
    esac
  fi

  write_file "$SNELL_SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-in",
      "listen": "${listen_host}",
      "listen_port": ${SNELL_PORT},
      ${version_line},
      "psk": "${SNELL_PSK}",
      ${mode_line}
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
    if ! "$SINGBOX_BIN" check -c "$SNELL_SINGBOX_CONFIG" >/dev/null 2>&1; then
      "$SINGBOX_BIN" check -c "$SNELL_SINGBOX_CONFIG" || die "sing-box Snell 配置校验失败"
    fi
    log "sing-box Snell 配置校验通过"
  else
    warn "未找到 sing-box 可执行文件，跳过配置校验"
  fi
}

write_snell_singbox_service() {
  write_singbox_aux_service "sing-box-snell" "$SNELL_SINGBOX_CONFIG" "$SNELL_SINGBOX_SERVICE"
}

configure_anytls() {
  log "生成 AnyTLS 配置..."
  validate_anytls_security

  local tls_json
  if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
    tls_json=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${ANYTLS_SNI}",
            "server_port": ${ANYTLS_DEST_PORT}
          },
          "private_key": "${ANYTLS_PRIVATE_KEY}",
          "short_id": [
            "${ANYTLS_SHORT_ID}"
          ]
        }
      }
EOF
)
  else
    generate_self_signed_cert "$ANYTLS_CERT" "$ANYTLS_KEY" "$ANYTLS_SNI"
    tls_json=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_SNI}",
        "certificate_path": "${ANYTLS_CERT}",
        "key_path": "${ANYTLS_KEY}"
      }
EOF
)
  fi

  write_file "$ANYTLS_CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "0.0.0.0",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {
          "name": "${ANYTLS_USER}",
          "password": "${ANYTLS_PASSWORD}"
        }
      ],
      "padding_scheme": [],
${tls_json}
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

  if [[ -x "$SINGBOX_BIN" && "$ANYTLS_DRY_RUN_DUMMY_CERT" != "true" ]]; then
    if ! "$SINGBOX_BIN" check -c "$ANYTLS_CONFIG" >/dev/null 2>&1; then
      "$SINGBOX_BIN" check -c "$ANYTLS_CONFIG" || die "sing-box AnyTLS 配置校验失败"
    fi
    log "sing-box AnyTLS 配置校验通过"
  elif [[ "$ANYTLS_DRY_RUN_DUMMY_CERT" == "true" ]]; then
    warn "DRY-RUN: 跳过 AnyTLS 配置校验（使用占位证书）"
  else
    warn "未找到 sing-box 可执行文件，跳过配置校验"
  fi
}

write_anytls_service() {
  write_singbox_aux_service "sing-box-anytls" "$ANYTLS_CONFIG" "$ANYTLS_SERVICE"
}

# ---------------------------------------------------------------------------
# Nowhere
# ---------------------------------------------------------------------------
detect_nowhere_arch() {
  case "$ARCH_RAW" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "Nowhere 仅支持 x86_64 / aarch64，当前：$ARCH_RAW" ;;
  esac
}

detect_nowhere_libc() {
  if [[ "$OS_ID" == "alpine" ]]; then
    printf 'musl\n'
    return 0
  fi
  if command_exists ldd && ldd --version 2>&1 | grep -qi musl; then
    printf 'musl\n'
  else
    printf 'gnu\n'
  fi
}

install_nowhere() {
  if [[ -x "$NOWHERE_BIN" ]]; then
    log "已存在 Nowhere：$NOWHERE_BIN"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: 跳过下载 Nowhere"
    return 0
  fi

  log "安装 Nowhere..."
  local asset url tmp version
  version="${NOWHERE_VERSION:-v2.1.1}"
  version="v${version#v}"
  asset="nowhere-$(detect_nowhere_arch)-unknown-linux-$(detect_nowhere_libc).tar.gz"
  url="https://github.com/NodePassProject/Nowhere/releases/download/${version}/${asset}"
  tmp="$(mktemp -d)"
  download "$url" "${tmp}/${asset}"
  tar -xzf "${tmp}/${asset}" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name nowhere -perm -u+x -print -quit)"
  [[ -n "$bin" ]] || bin="$(find "$tmp" -type f -name nowhere -print -quit)"
  [[ -n "$bin" ]] || die "Nowhere 解压失败"
  install -m 0755 "$bin" "$NOWHERE_BIN"
  rm -rf "$tmp"
  log "Nowhere 版本：$("$NOWHERE_BIN" --version 2>/dev/null | head -1 || true)"
}

build_nowhere_portal() {
  local key host endpoint query
  key="$(url_encode "$NOWHERE_KEY")"
  host="$NOWHERE_LISTEN_HOST"
  [[ -n "$host" ]] || host="*"
  host="$(format_host_for_url "$host")"
  endpoint="${host}:${NOWHERE_PORT}"
  query="tls=${NOWHERE_TLS}&morph=${NOWHERE_MORPH}"
  if [[ "$NOWHERE_TLS" == "2" ]]; then
    query="${query}&crt=$(url_encode "$NOWHERE_CRT")&key=$(url_encode "$NOWHERE_TLS_KEY")"
  fi
  [[ "$NOWHERE_RATE" == "0" ]] || query="${query}&rate=${NOWHERE_RATE}"
  [[ "$NOWHERE_ETAR" == "0" ]] || query="${query}&etar=${NOWHERE_ETAR}"
  [[ "$NOWHERE_LOG" == "info" ]] || query="${query}&log=${NOWHERE_LOG}"
  NOWHERE_PORTAL="portal://${key}@${endpoint}?${query}"
}

configure_nowhere() {
  build_nowhere_portal
  write_file "$NOWHERE_CONFIG" <<EOF
# Nowhere configuration
NOWHERE_PORTAL=$(printf '%q' "$NOWHERE_PORTAL")
NOWHERE_VERSION=$(printf '%q' "$NOWHERE_VERSION")
NOWHERE_KEY=$(printf '%q' "$NOWHERE_KEY")
NOWHERE_PORT=$(printf '%q' "$NOWHERE_PORT")
NOWHERE_TLS=$(printf '%q' "$NOWHERE_TLS")
NOWHERE_CRT=$(printf '%q' "$NOWHERE_CRT")
NOWHERE_TLS_KEY=$(printf '%q' "$NOWHERE_TLS_KEY")
NOWHERE_MORPH=$(printf '%q' "$NOWHERE_MORPH")
NOWHERE_CLIENT=$(printf '%q' "$NOWHERE_CLIENT")
NOWHERE_PUBLIC_HOST=$(printf '%q' "$NOWHERE_PUBLIC_HOST")
NOWHERE_LISTEN_HOST=$(printf '%q' "$NOWHERE_LISTEN_HOST")
NOWHERE_RATE=$(printf '%q' "$NOWHERE_RATE")
NOWHERE_ETAR=$(printf '%q' "$NOWHERE_ETAR")
NOWHERE_LOG=$(printf '%q' "$NOWHERE_LOG")
EOF
  chmod 600 "$NOWHERE_CONFIG" 2>/dev/null || true
}

write_nowhere_service() {
  write_file "$NOWHERE_RUNNER" <<EOF
#!/bin/sh
exec "${NOWHERE_BIN}" "${NOWHERE_PORTAL}"
EOF
  chmod +x "$NOWHERE_RUNNER" 2>/dev/null || true

  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    write_file "$NOWHERE_SERVICE" <<EOF
#!/sbin/openrc-run
name="nowhere"
description="Nowhere Portal"
command="${NOWHERE_RUNNER}"
pidfile="/run/nowhere.pid"
command_background="yes"
output_log="/var/log/nowhere.log"
error_log="/var/log/nowhere.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
    chmod +x "$NOWHERE_SERVICE" 2>/dev/null || true
    return 0
  fi

  write_file "$NOWHERE_SERVICE" <<EOF
[Unit]
Description=Nowhere Portal
Documentation=https://github.com/NodePassProject/Nowhere
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${NOWHERE_RUNNER}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

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
    CORE="$(prompt_value "VLESS-Reality 核心 (xray/sing-box)" "sing-box")"
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

  # 选择 Snell 服务端：official（官方 snell-server，仅 glibc）或 singbox（sing-box 入站）
  if [[ -z "$SNELL_ENGINE" && "$NON_INTERACTIVE" != "true" ]]; then
    local engine_default
    engine_default="$(default_snell_engine)"
    SNELL_ENGINE="$(prompt_value "Snell 服务端 (official/singbox)" "$engine_default")"
  fi
  resolve_snell_engine

  if [[ "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "当前系统无法运行官方 Snell，请改用 --snell-engine singbox 或 --mode vless。"
    fi
    warn "当前系统无法运行官方 Snell，已自动改用 sing-box Snell"
    SNELL_ENGINE="singbox"
  fi

  SNELL_PORT="$(prompt_port "Snell 监听端口" "${SNELL_PORT:-8443}")"

  if [[ "$SNELL_ENGINE" == "singbox" ]]; then
    # sing-box Snell 仅支持 v5/v6；v5 仅 http/none，v6 使用 mode 无需 obfs
    if [[ -z "$SNELL_VERSION" || "$SNELL_VERSION" == 4* ]]; then
      SNELL_VERSION="5.0.1"
    fi
    SNELL_VERSION="$(prompt_value "Snell 服务端版本 (5/6)" "${SNELL_VERSION:-5.0.1}")"
    SNELL_VERSION="${SNELL_VERSION#v}"
    case "$SNELL_VERSION" in
      5*|6*) ;;
      *) die "sing-box Snell 版本只支持 5 或 6，当前：$SNELL_VERSION" ;;
    esac

    if [[ "$SNELL_VERSION" == 6* ]]; then
      SNELL_OBFS="none"
      SNELL_DOMAIN=""
    else
      if [[ "$SNELL_OBFS" == "tls" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
          die "sing-box Snell 不支持 obfs=tls，请使用 --snell-obfs http 或 none，或改用 --snell-engine official（仅 glibc 系统）。"
        fi
        warn "sing-box Snell 不支持 obfs=tls，已自动改为 http"
        SNELL_OBFS="http"
      fi
      SNELL_OBFS="$(prompt_value "Snell 混淆 (http/none)" "${SNELL_OBFS:-http}")"
      case "$SNELL_OBFS" in
        http|none) ;;
        *) die "sing-box Snell 混淆只支持 http/none，当前：$SNELL_OBFS" ;;
      esac
      if [[ "$SNELL_OBFS" == "http" ]]; then
        SNELL_DOMAIN="$(prompt_host "Snell 伪装域名/obfs-host" "${SNELL_DOMAIN:-www.bing.com}")"
      else
        SNELL_DOMAIN=""
      fi
    fi
  else
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
    SNELL_VERSION="$(prompt_value "Snell 服务端版本" "${SNELL_VERSION:-4.1.1}")"
    SNELL_VERSION="${SNELL_VERSION#v}"
  fi

  [[ -n "$SNELL_PSK" ]] || SNELL_PSK="$(gen_psk)"
  SNELL_IPV6="$(prompt_value "Snell 是否启用 IPv6 (true/false)" "${SNELL_IPV6:-false}")"
  case "$SNELL_IPV6" in
    true|false) ;;
    *) die "Snell IPv6 必须是 true 或 false，当前：$SNELL_IPV6" ;;
  esac
}

prompt_anytls() {
  if [[ -z "$NODE_ADDRESS" ]]; then
    local detected
    detected="$(detect_public_ip)"
    NODE_ADDRESS="$(prompt_host "节点地址（客户端连接用，域名或 IP）" "$detected")"
  fi
  validate_host "$NODE_ADDRESS" || die "节点地址无效：$NODE_ADDRESS"
  if [[ "$NODE_ADDRESS" == "127.0.0.1" ]]; then
    warn "未能自动检测公网 IP，当前使用 127.0.0.1；建议用 --address 指定域名或公网 IP"
  fi

  ANYTLS_PORT="$(prompt_port "AnyTLS 监听端口" "${ANYTLS_PORT:-9443}")"
  ANYTLS_SNI="$(prompt_sni "AnyTLS 伪装域名/SNI" "${ANYTLS_SNI:-www.microsoft.com}")"
  ANYTLS_SECURITY="$(prompt_value "AnyTLS 安全类型 (tls/reality)" "${ANYTLS_SECURITY:-tls}")"
  validate_anytls_security
  if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
    ANYTLS_DEST_PORT="$(prompt_port "AnyTLS Reality 目标端口（通常 443）" "${ANYTLS_DEST_PORT:-443}")"
  fi
  ANYTLS_USER="$(prompt_value "AnyTLS 用户名" "${ANYTLS_USER:-node-deploy}")"
  [[ -n "$ANYTLS_PASSWORD" ]] || ANYTLS_PASSWORD="$(gen_psk)"
}

prompt_nowhere() {
  if [[ -z "$NODE_ADDRESS" ]]; then
    local detected
    detected="$(detect_public_ip)"
    NODE_ADDRESS="$(prompt_host "节点地址（客户端连接用，域名或 IP）" "$detected")"
  fi
  validate_host "$NODE_ADDRESS" || die "节点地址无效：$NODE_ADDRESS"
  if [[ "$NODE_ADDRESS" == "127.0.0.1" ]]; then
    warn "未能自动检测公网 IP，当前使用 127.0.0.1；建议用 --address 指定域名或公网 IP"
  fi
  NOWHERE_PUBLIC_HOST="$NODE_ADDRESS"

  NOWHERE_PORT="$(prompt_port "Nowhere 监听端口（同时监听 TCP+UDP）" "${NOWHERE_PORT:-2077}")"
  [[ -n "$NOWHERE_KEY" ]] || NOWHERE_KEY="$(gen_psk)"
  [[ "${#NOWHERE_KEY}" -le 255 ]] || die "Nowhere 共享密钥必须不超过 255 个字符"
  NOWHERE_TLS="$(prompt_value "Nowhere TLS (1=自签证书, 2=PEM 证书)" "${NOWHERE_TLS:-1}")"
  case "$NOWHERE_TLS" in
    1|2) ;;
    *) die "--nowhere-tls 必须是 1 或 2，当前：$NOWHERE_TLS" ;;
  esac
  if [[ "$NOWHERE_TLS" == "2" ]]; then
    NOWHERE_CRT="$(prompt_value "证书链绝对路径" "${NOWHERE_CRT:-}")"
    NOWHERE_TLS_KEY="$(prompt_value "私钥绝对路径" "${NOWHERE_TLS_KEY:-}")"
    [[ -f "$NOWHERE_CRT" && -f "$NOWHERE_TLS_KEY" ]] || die "TLS=2 需要有效的证书和私钥文件"
  fi
  NOWHERE_MORPH="$(prompt_value "Nowhere Morph (0=关闭, 1=ChaCha20)" "${NOWHERE_MORPH:-0}")"
  case "$NOWHERE_MORPH" in
    0|1) ;;
    *) die "--nowhere-morph 必须是 0 或 1，当前：$NOWHERE_MORPH" ;;
  esac
  NOWHERE_CLIENT="$(prompt_value "Nowhere 客户端 (anywhere/vector/both)" "${NOWHERE_CLIENT:-both}")"
  case "$NOWHERE_CLIENT" in
    anywhere|vector|both) ;;
    *) die "--nowhere-client 必须是 anywhere/vector/both，当前：$NOWHERE_CLIENT" ;;
  esac
  NOWHERE_VERSION="$(prompt_value "Nowhere 版本" "${NOWHERE_VERSION:-v2.1.1}")"
  NOWHERE_VERSION="v${NOWHERE_VERSION#v}"
  NOWHERE_RATE="$(prompt_value "Nowhere 限速 Mbps（0=不限速）" "${NOWHERE_RATE:-0}")"
  NOWHERE_ETAR="$(prompt_value "Nowhere Etar Mbps（0=不限速）" "${NOWHERE_ETAR:-0}")"
  NOWHERE_LOG="$(prompt_value "Nowhere 日志级别" "${NOWHERE_LOG:-info}")"
  NOWHERE_LISTEN_HOST="$(prompt_value "Nowhere 监听地址（留空=全部）" "${NOWHERE_LISTEN_HOST:-}")"

  [[ "$NOWHERE_RATE" =~ ^[0-9]+$ ]] || die "Nowhere 限速必须是非负整数，当前：$NOWHERE_RATE"
  [[ "$NOWHERE_ETAR" =~ ^[0-9]+$ ]] || die "Nowhere Etar 必须是非负整数，当前：$NOWHERE_ETAR"
  case "$NOWHERE_LOG" in
    none|debug|info|warn|error) ;;
    *) die "Nowhere 日志级别必须是 none/debug/info/warn/error，当前：$NOWHERE_LOG" ;;
  esac
  if [[ -n "$NOWHERE_LISTEN_HOST" ]]; then
    validate_host "$NOWHERE_LISTEN_HOST" || die "Nowhere 监听地址无效：$NOWHERE_LISTEN_HOST"
  fi
}

# ---------------------------------------------------------------------------
# 部署流程
# ---------------------------------------------------------------------------
deploy_vless() {
  if [[ "$DRY_RUN" != "true" && "$INIT_SYSTEM" == "unknown" ]]; then
    die "未检测到 systemd 或 OpenRC，当前脚本仅支持 systemd / OpenRC 系统"
  fi
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
  if [[ "$DRY_RUN" != "true" && "$INIT_SYSTEM" == "unknown" ]]; then
    die "未检测到 systemd 或 OpenRC，当前脚本仅支持 systemd / OpenRC 系统"
  fi
  ensure_env
  prompt_snell
  ensure_port_available "$SNELL_PORT" "Snell"

  if [[ "$SNELL_ENGINE" == "official" ]]; then
    if ! check_snell_platform; then
      die "当前系统无法运行官方 Snell，请改用 --snell-engine singbox。"
    fi
    install_snell
    configure_snell
    write_snell_service
    service_enable_start snell
    open_firewall_port "$SNELL_PORT" tcp
    # 官方 Snell v5 会额外监听 QUIC（UDP）
    if [[ "$SNELL_VERSION" == 5* ]]; then
      open_firewall_port "$SNELL_PORT" udp
    fi
  else
    install_singbox
    configure_snell_singbox
    write_snell_singbox_service
    service_enable_start sing-box-snell
    open_firewall_port "$SNELL_PORT" tcp
  fi
}

deploy_anytls() {
  if [[ "$DRY_RUN" != "true" && "$INIT_SYSTEM" == "unknown" ]]; then
    die "未检测到 systemd 或 OpenRC，当前脚本仅支持 systemd / OpenRC 系统"
  fi
  ensure_env
  install_singbox
  prompt_anytls
  ensure_port_available "$ANYTLS_PORT" "AnyTLS"
  validate_anytls_security

  if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
    if [[ -n "$ANYTLS_PRIVATE_KEY" && -n "$ANYTLS_PUBLIC_KEY" ]]; then
      log "使用已有 AnyTLS Reality 密钥"
    elif [[ -n "$ANYTLS_PRIVATE_KEY" || -n "$ANYTLS_PUBLIC_KEY" ]]; then
      die "请同时提供 --anytls-private-key 和 --anytls-public-key，或都不提供"
    elif [[ "$DRY_RUN" == "true" && ! -x "$SINGBOX_BIN" ]]; then
      ANYTLS_PRIVATE_KEY="dummy_private_key"
      ANYTLS_PUBLIC_KEY="dummy_public_key"
      warn "DRY-RUN: 未找到 sing-box，使用占位 AnyTLS Reality 密钥"
    else
      local kp
      kp="$(gen_singbox_keypair)"
      ANYTLS_PRIVATE_KEY="${kp%%|*}"
      ANYTLS_PUBLIC_KEY="${kp##*|}"
    fi
    [[ -n "$ANYTLS_SHORT_ID" ]] || ANYTLS_SHORT_ID="$(gen_short_id)"
  fi

  configure_anytls
  write_anytls_service
  service_enable_start sing-box-anytls
  open_firewall_port "$ANYTLS_PORT" tcp
}

deploy_nowhere() {
  if [[ "$DRY_RUN" != "true" && "$INIT_SYSTEM" == "unknown" ]]; then
    die "未检测到 systemd 或 OpenRC，当前脚本仅支持 systemd / OpenRC 系统"
  fi
  ensure_env
  prompt_nowhere
  ensure_port_available "$NOWHERE_PORT" "Nowhere"
  ensure_udp_port_available "$NOWHERE_PORT" "Nowhere"
  install_nowhere
  configure_nowhere
  write_nowhere_service
  service_enable_start nowhere
  open_firewall_port "$NOWHERE_PORT" tcp
  open_firewall_port "$NOWHERE_PORT" udp
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

snell_surge_version() {
  if [[ "$SNELL_VERSION" == 6* ]]; then
    printf '6\n'
  elif [[ "$SNELL_VERSION" == 5* ]]; then
    printf '5\n'
  else
    printf '4\n'
  fi
}

generate_snell_surge() {
  local host version
  host="$(format_host_for_url "$NODE_ADDRESS")"
  version="$(snell_surge_version)"
  local line="Snell = snell, ${host}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=${version}"
  case "$SNELL_OBFS" in
    tls) line+=", obfs=tls"; [[ -n "$SNELL_DOMAIN" ]] && line+=", obfs-host=${SNELL_DOMAIN}" ;;
    http) line+=", obfs=http"; [[ -n "$SNELL_DOMAIN" ]] && line+=", obfs-host=${SNELL_DOMAIN}" ;;
  esac
  printf '%s\n' "$line"
}

generate_snell_clash() {
  local version server
  version="$(snell_surge_version)"
  server="$NODE_ADDRESS"
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
  if [[ "$version" != "6" && ( "$SNELL_OBFS" == "tls" || "$SNELL_OBFS" == "http" ) ]]; then
    cat <<EOF
  obfs-opts:
    mode: ${SNELL_OBFS}
    host: ${SNELL_DOMAIN}
EOF
  fi
}

generate_snell_singbox() {
  local version=4
  local server="$NODE_ADDRESS"
  local extra=""
  if [[ "$SNELL_VERSION" == 6* ]]; then
    version=6
    extra="\"mode\": \"default\""
  else
    local obfs_mode="none"
    local obfs_host=""
    case "$SNELL_OBFS" in
      http) obfs_mode="http"; obfs_host="$SNELL_DOMAIN" ;;
      none) obfs_mode="none" ;;
      tls) obfs_mode="none"; warn "sing-box 客户端不支持 Snell obfs=tls，已省略 obfs" ;;
    esac
    extra="\"obfs_mode\": \"${obfs_mode}\""
    [[ -n "$obfs_host" ]] && extra+=", \"obfs_host\": \"${obfs_host}\""
  fi
  cat <<EOF
{
  "type": "snell",
  "tag": "snell-out",
  "server": "${server}",
  "server_port": ${SNELL_PORT},
  "version": ${version},
  "psk": "${SNELL_PSK}",
  ${extra}
}
EOF
}

generate_anytls_surge() {
  if [[ "$ANYTLS_SECURITY" != "tls" ]]; then
    printf '# Surge 不支持 AnyTLS Reality，请使用 sing-box 客户端\n'
    return 0
  fi
  local host
  host="$(format_host_for_url "$NODE_ADDRESS")"
  printf 'AnyTLS = anytls, %s, %s, password=%s, sni=%s, skip-cert-verify=true\n' \
    "$host" "$ANYTLS_PORT" "$ANYTLS_PASSWORD" "$ANYTLS_SNI"
}

generate_anytls_singbox() {
  local server="$NODE_ADDRESS"
  if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
    cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${server}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${ANYTLS_SNI}",
    "reality": {
      "enabled": true,
      "public_key": "${ANYTLS_PUBLIC_KEY}",
      "short_id": "${ANYTLS_SHORT_ID}"
    }
  }
}
EOF
  else
    cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${server}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${ANYTLS_SNI}",
    "insecure": true
  }
}
EOF
  fi
}

generate_anytls_uri() {
  local host encoded_password
  host="$(format_host_for_url "$NODE_ADDRESS")"
  encoded_password="$(url_encode "$ANYTLS_PASSWORD")"
  if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
    printf 'anytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#AnyTLS\n' \
      "$encoded_password" "$host" "$ANYTLS_PORT" "$ANYTLS_SNI" "$ANYTLS_PUBLIC_KEY" "$ANYTLS_SHORT_ID"
  else
    printf 'anytls://%s@%s:%s/?security=tls&sni=%s&allowInsecure=1#AnyTLS\n' \
      "$encoded_password" "$host" "$ANYTLS_PORT" "$ANYTLS_SNI"
  fi
}

generate_nowhere_anywhere() {
  local host key name
  host="$(format_host_for_url "$NOWHERE_PUBLIC_HOST")"
  key="$(url_encode "$NOWHERE_KEY")"
  name="$(url_encode "Nowhere")"
  printf 'nowhere://%s@%s:%s?up=tcp&down=tcp&morph=%s&mux=0#%s\n' \
    "$key" "$host" "$NOWHERE_PORT" "$NOWHERE_MORPH" "$name"
}

generate_nowhere_vector() {
  local host key name
  host="$(format_host_for_url "$NOWHERE_PUBLIC_HOST")"
  key="$(url_encode "$NOWHERE_KEY")"
  name="$(url_encode "Nowhere")"
  printf 'vector://%s@%s:%s?up=tcp&down=tcp&mux=0&sni=none&pin=none&morph=%s&socks=127.0.0.1:1080#%s\n' \
    "$key" "$host" "$NOWHERE_PORT" "$NOWHERE_MORPH" "$name"
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

  if [[ "${MODE}" == "vless" || "${MODE}" == "both" || "${MODE}" == "all" ]]; then
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

  if [[ "${MODE}" == "snell" || "${MODE}" == "both" || "${MODE}" == "all" ]]; then
    echo
    info "--- Snell ---"
    echo "服务端     : ${SNELL_ENGINE}"
    echo "版本       : ${SNELL_VERSION}"
    echo "端口       : ${SNELL_PORT}"
    echo "PSK        : ${SNELL_PSK}"
    echo "Obfs       : ${SNELL_OBFS}"
    echo "Obfs Host  : ${SNELL_DOMAIN}"
    if [[ "$SNELL_ENGINE" == "singbox" ]]; then
      echo
      echo "sing-box 客户端配置："
      generate_snell_singbox
    fi
    echo
    echo "Surge / Stash 配置："
    generate_snell_surge
    echo
    echo "Clash.Meta 配置："
    generate_snell_clash
  fi

  if [[ "${MODE}" == "anytls" || "${MODE}" == "all" ]]; then
    echo
    info "--- AnyTLS ---"
    echo "安全类型   : ${ANYTLS_SECURITY}"
    echo "端口       : ${ANYTLS_PORT}"
    echo "用户名     : ${ANYTLS_USER}"
    echo "密码       : ${ANYTLS_PASSWORD}"
    echo "SNI        : ${ANYTLS_SNI}"
    if [[ "$ANYTLS_SECURITY" == "reality" ]]; then
      echo "PublicKey  : ${ANYTLS_PUBLIC_KEY}"
      echo "ShortId    : ${ANYTLS_SHORT_ID}"
    fi
    echo
    echo "Surge 配置："
    generate_anytls_surge
    echo
    echo "sing-box 客户端配置："
    generate_anytls_singbox
    echo
    echo "分享链接："
    generate_anytls_uri
  fi

  if [[ "${MODE}" == "nowhere" || "${MODE}" == "all" ]]; then
    if [[ -n "$NOWHERE_KEY" ]]; then
      build_nowhere_portal
    fi
    echo
    info "--- Nowhere ---"
    echo "版本       : ${NOWHERE_VERSION}"
    echo "端口       : ${NOWHERE_PORT} (TCP+UDP)"
    echo "共享密钥   : ${NOWHERE_KEY}"
    echo "TLS        : ${NOWHERE_TLS}"
    echo "Morph      : ${NOWHERE_MORPH}"
    echo "客户端     : ${NOWHERE_CLIENT}"
    echo "Portal URL : ${NOWHERE_PORTAL}"
    echo
    if [[ "$NOWHERE_CLIENT" == "anywhere" || "$NOWHERE_CLIENT" == "both" ]]; then
      echo "Anywhere 导入链接："
      generate_nowhere_anywhere
      echo
    fi
    if [[ "$NOWHERE_CLIENT" == "vector" || "$NOWHERE_CLIENT" == "both" ]]; then
      echo "Native Vector 链接："
      generate_nowhere_vector
      echo
    fi
    echo "客户端命令："
    echo "  nowhere '$(generate_nowhere_anywhere)'"
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
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
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
  log "停止并卸载 Xray / sing-box / Snell / AnyTLS / Nowhere..."
  service_stop_disable xray
  service_stop_disable sing-box
  service_stop_disable snell
  service_stop_disable sing-box-snell
  service_stop_disable sing-box-anytls
  service_stop_disable nowhere

  rm -f "$XRAY_SERVICE" "$SINGBOX_SERVICE" "$SNELL_SERVICE"
  rm -f "$SNELL_SINGBOX_SERVICE" "$ANYTLS_SERVICE" "$NOWHERE_SERVICE"
  rm -f "$XRAY_BIN" "$SINGBOX_BIN" "$SNELL_BIN" "$NOWHERE_BIN"
  rm -rf /usr/local/etc/xray /etc/sing-box /etc/snell /etc/nowhere
  rm -rf "$CONFIG_DIR"
  init_reload >/dev/null 2>&1 || true
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
    echo " 3. 部署/重装 AnyTLS"
    echo " 4. 部署/重装 Nowhere"
    echo " 5. 同时部署 VLESS-Reality + Snell"
    echo " 6. 全部部署 VLESS + Snell + AnyTLS + Nowhere"
    echo " 7. 查看节点信息"
    echo " 8. 启用 BBR"
    echo " 9. 卸载所有组件"
    echo " 0. 退出"
    echo "=================================================="
    local choice=""
    read -r -p "请选择 [0-9]: " choice || true
    case "$choice" in
      1)
        MODE="vless"
        deploy_vless
        save_config
        show_info
        ;;
      2)
        if [[ "$SNELL_ENGINE_CLI" == "true" && "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
          pause_any_key
          continue
        fi
        MODE="snell"
        deploy_snell
        save_config
        show_info
        ;;
      3)
        MODE="anytls"
        deploy_anytls
        save_config
        show_info
        ;;
      4)
        MODE="nowhere"
        deploy_nowhere
        save_config
        show_info
        ;;
      5)
        if [[ "$SNELL_ENGINE_CLI" == "true" && "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
          pause_any_key
          continue
        fi
        MODE="both"
        deploy_vless
        deploy_snell
        save_config
        show_info
        ;;
      6)
        if [[ "$SNELL_ENGINE_CLI" == "true" && "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
          pause_any_key
          continue
        fi
        MODE="all"
        deploy_vless
        deploy_snell
        deploy_anytls
        deploy_nowhere
        save_config
        show_info
        ;;
      7)
        show_info
        ;;
      8)
        enable_bbr
        ;;
      9)
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
一键部署 VLESS-Reality / Snell / AnyTLS / Nowhere 节点

用法：
  # 一键运行（无需上传）
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)
  sudo bash <(wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)

  # 本地运行
  bash deploy.sh [选项]

模式：
  -m, --mode <vless|snell|anytls|nowhere|both|all>
                                  部署模式；both=VLESS+Snell，all=四种全部部署
                                  不指定则进入交互菜单
  -a, --address <域名|IP>         客户端连接地址；同时部署时复用
      --core <xray|sing-box>      VLESS-Reality 核心，默认 sing-box

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
      --snell-engine <official|singbox>
                                  服务端引擎；默认 glibc 用 official，Alpine/musl 用 singbox
      --snell-port <端口>         监听端口，默认 8443
      --snell-domain <域名>       obfs-host/伪装域名，默认 www.bing.com
      --snell-psk <密钥>          PSK，默认随机生成
      --snell-obfs <tls|http|none> 官方默认 tls；sing-box 只支持 http/none
      --snell-version <版本>      官方默认 4.1.1（可选 5.0.1）；sing-box 支持 5/6
      --snell-ipv6 <true|false>   是否启用 IPv6，默认 false

AnyTLS：
      --anytls-port <端口>        监听端口，默认 9443
      --anytls-sni <域名>         伪装域名/SNI，默认 www.microsoft.com
      --anytls-security <tls|reality>
                                  tls=自签证书（Surge 可用，默认）；reality=仅 sing-box 客户端
      --anytls-dest-port <端口>    Reality 目标端口，默认 443
      --anytls-password <密码>     客户端密码，默认随机生成
      --anytls-user <用户名>       用户名，默认 node-deploy
      --anytls-private-key <key>  自定义 Reality 私钥
      --anytls-public-key <key>   自定义 Reality 公钥
      --anytls-short-id <hex>     自定义 shortId，默认随机生成

Nowhere：
      --nowhere-port <端口>       监听端口（同时占用 TCP+UDP），默认 2077
      --nowhere-key <密钥>        共享密钥，默认随机生成
      --nowhere-tls <1|2>         1=自签证书（默认），2=使用 PEM 证书
      --nowhere-crt <路径>        TLS=2 时的证书链路径
      --nowhere-tls-key <路径>    TLS=2 时的私钥路径
      --nowhere-morph <0|1>       Morph 变换，默认 0
      --nowhere-client <anywhere|vector|both>
                                   生成的客户端链接类型，默认 both
      --nowhere-version <版本>    Nowhere 版本，默认 v2.1.1
      --nowhere-listen-host <地址> 监听地址，留空=全部
      --nowhere-rate <Mbps>       限速，0=不限速
      --nowhere-etar <Mbps>       Etar 限速，0=不限速
      --nowhere-log <级别>        日志级别，默认 info

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

  # 同时部署 VLESS + Snell，复用同一地址，端口独立
  bash $0 --mode both --address node.example.com \\
    --core sing-box \\
    --vless-port 443 --vless-sni www.microsoft.com \\
    --snell-port 8443 --snell-domain www.bing.com --snell-obfs http

  # Alpine 上用 sing-box 跑 Snell v5
  bash $0 --mode snell --address 1.2.3.4 --snell-engine singbox \\
    --snell-port 8443 --snell-obfs http

  # 部署 AnyTLS（Surge 兼容的 tls 模式）
  bash $0 --mode anytls --address 1.2.3.4 --anytls-port 9443 \\
    --anytls-sni www.microsoft.com --anytls-security tls

  # 部署 Nowhere（TCP+UDP 同端口）
  bash $0 --mode nowhere --address 1.2.3.4 --nowhere-port 2077 \\
    --nowhere-client both

  # 全部部署（VLESS + Snell + AnyTLS + Nowhere）
  bash $0 --mode all --address 1.2.3.4 -y --force

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
      --snell-engine)
        need_value "$@"
        SNELL_ENGINE="$2"; SNELL_ENGINE_CLI="true"; shift 2 ;;
      --anytls-port)
        need_value "$@"
        ANYTLS_PORT="$2"; shift 2 ;;
      --anytls-sni)
        need_value "$@"
        ANYTLS_SNI="$2"; shift 2 ;;
      --anytls-dest-port)
        need_value "$@"
        ANYTLS_DEST_PORT="$2"; shift 2 ;;
      --anytls-password)
        need_value "$@"
        ANYTLS_PASSWORD="$2"; shift 2 ;;
      --anytls-user)
        need_value "$@"
        ANYTLS_USER="$2"; shift 2 ;;
      --anytls-security)
        need_value "$@"
        ANYTLS_SECURITY="$2"; shift 2 ;;
      --anytls-private-key)
        need_value "$@"
        ANYTLS_PRIVATE_KEY="$2"; shift 2 ;;
      --anytls-public-key)
        need_value "$@"
        ANYTLS_PUBLIC_KEY="$2"; shift 2 ;;
      --anytls-short-id)
        need_value "$@"
        ANYTLS_SHORT_ID="$2"; shift 2 ;;
      --nowhere-port)
        need_value "$@"
        NOWHERE_PORT="$2"; shift 2 ;;
      --nowhere-key)
        need_value "$@"
        NOWHERE_KEY="$2"; shift 2 ;;
      --nowhere-tls)
        need_value "$@"
        NOWHERE_TLS="$2"; shift 2 ;;
      --nowhere-crt)
        need_value "$@"
        NOWHERE_CRT="$2"; shift 2 ;;
      --nowhere-tls-key)
        need_value "$@"
        NOWHERE_TLS_KEY="$2"; shift 2 ;;
      --nowhere-morph)
        need_value "$@"
        NOWHERE_MORPH="$2"; shift 2 ;;
      --nowhere-client)
        need_value "$@"
        NOWHERE_CLIENT="$2"; shift 2 ;;
      --nowhere-version)
        need_value "$@"
        NOWHERE_VERSION="$2"; shift 2 ;;
      --nowhere-listen-host)
        need_value "$@"
        NOWHERE_LISTEN_HOST="$2"; shift 2 ;;
      --nowhere-rate)
        need_value "$@"
        NOWHERE_RATE="$2"; shift 2 ;;
      --nowhere-etar)
        need_value "$@"
        NOWHERE_ETAR="$2"; shift 2 ;;
      --nowhere-log)
        need_value "$@"
        NOWHERE_LOG="$2"; shift 2 ;;
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
      vless|snell|anytls|nowhere|both|all) ;;
      *) die "--mode 必须是 vless、snell、anytls、nowhere、both 或 all，当前：$MODE" ;;
    esac
  fi

  if [[ -n "$SNELL_ENGINE" ]]; then
    case "$SNELL_ENGINE" in
      official|singbox) ;;
      *) die "--snell-engine 必须是 official 或 singbox，当前：$SNELL_ENGINE" ;;
    esac
  fi

  validate_anytls_security

  case "$NOWHERE_TLS" in
    1|2) ;;
    *) die "--nowhere-tls 必须是 1 或 2，当前：$NOWHERE_TLS" ;;
  esac
  case "$NOWHERE_MORPH" in
    0|1) ;;
    *) die "--nowhere-morph 必须是 0 或 1，当前：$NOWHERE_MORPH" ;;
  esac
  case "$NOWHERE_CLIENT" in
    anywhere|vector|both) ;;
    *) die "--nowhere-client 必须是 anywhere、vector 或 both，当前：$NOWHERE_CLIENT" ;;
  esac
  if [[ -n "$NOWHERE_KEY" ]]; then
    [[ "${#NOWHERE_KEY}" -le 255 ]] || die "--nowhere-key 必须不超过 255 个字符"
  fi
  [[ "$NOWHERE_RATE" =~ ^[0-9]+$ ]] || die "--nowhere-rate 必须是非负整数，当前：$NOWHERE_RATE"
  [[ "$NOWHERE_ETAR" =~ ^[0-9]+$ ]] || die "--nowhere-etar 必须是非负整数，当前：$NOWHERE_ETAR"
  case "$NOWHERE_LOG" in
    none|debug|info|warn|error) ;;
    *) die "--nowhere-log 必须是 none/debug/info/warn/error，当前：$NOWHERE_LOG" ;;
  esac
  if [[ -n "$NOWHERE_LISTEN_HOST" ]]; then
    validate_host "$NOWHERE_LISTEN_HOST" || die "--nowhere-listen-host 无效：$NOWHERE_LISTEN_HOST"
  fi
  if [[ "$NOWHERE_TLS" == "2" ]]; then
    [[ -f "$NOWHERE_CRT" && -f "$NOWHERE_TLS_KEY" ]] || die "--nowhere-tls 2 需要 --nowhere-crt 和 --nowhere-tls-key 指向存在的文件"
  fi
  NOWHERE_VERSION="v${NOWHERE_VERSION#v}"

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
    anytls)
      deploy_anytls
      ;;
    nowhere)
      deploy_nowhere
      ;;
    both)
      if [[ "$SNELL_ENGINE_CLI" == "true" && "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
        die "当前系统无法运行官方 Snell，请使用 --snell-engine singbox。"
      fi
      deploy_vless
      deploy_snell
      ;;
    all)
      if [[ "$SNELL_ENGINE_CLI" == "true" && "$SNELL_ENGINE" == "official" ]] && ! check_snell_platform; then
        die "当前系统无法运行官方 Snell，请使用 --snell-engine singbox。"
      fi
      deploy_vless
      deploy_snell
      deploy_anytls
      deploy_nowhere
      ;;
  esac

  save_config
  show_info
}

main "$@"
