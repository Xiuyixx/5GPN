#!/usr/bin/env bash
#
# install.sh - High-performance transparent proxy + Smart DNS (DoT) one-click installer
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12/13, CentOS 7/8/9 Stream,
#           Rocky Linux 8/9, AlmaLinux 8/9, RHEL 8/9, Fedora 39+
#

set -euo pipefail

# =============================================================================
# Configurable defaults
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="/opt/proxy-gateway"
CONF_DIR="${BASE_DIR}/etc"
LOG_DIR="${BASE_DIR}/log"
SRC_DIR="${BASE_DIR}/src"
WWW_DIR="${BASE_DIR}/www"
IOS_PROFILE_PORT=8111
GFWLIST_URL="https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt"
CHINALIST_URL="https://github.com/felixonmars/dnsmasq-china-list/raw/master/accelerated-domains.china.conf"
CLOUDNS_FREE_TLDS=("abrdns.com" "cloud-ip.cc")
DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_PUBLIC_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8")

REPO_OWNER="${REPO_OWNER:-Xiuyixx}"
REPO_NAME="${REPO_NAME:-5GPN}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
REQUIRED_PROJECT_FILES=(
    "quic-proxy.go"
    "china-dns-race-proxy.go"
    "dnsdist.conf.template"
    "sniproxy.conf"
    "renew-hook.sh"
    "update-rules.sh"
)

# =============================================================================
# Colors
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

render_overseas_dns_servers() {
    local input="${1:-}"
    local pool="${2:-overseas}"
    local prefix="${3:-overseas}"
    local dns_list=()
    local item order=1 name

    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi

    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid overseas DNS address: $item"
            continue
        fi
        name="${prefix}${order}"
        printf 'newServer({address="%s:53", pool="%s", name="%s", order=%d, useClientSubnet=true})\n' "$item" "$pool" "$name" "$order"
        order=$((order + 1))
    done
}

render_sniproxy_dns_nameservers() {
    local input="${1:-}"
    local dns_list=()
    local item

    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi

    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid sniproxy DNS address: $item"
            continue
        fi
        printf '    nameserver %s\n' "$item"
    done
}

configure_overseas_dns() {
    local legacy="${OVERSEAS_DNS:-}"
    local private_selected="${PRIVATE_OVERSEAS_DNS:-$legacy}"
    local public_selected="${PUBLIC_OVERSEAS_DNS:-}"
    local sniproxy_selected="${SNIPROXY_DNS:-}"

    if [[ -z "$private_selected" && -t 0 ]]; then
        echo ""
        read -r -p "Private overseas DNS upstreams [1.1.1.1,8.8.8.8,9.9.9.9]: " private_selected
    fi
    if [[ -z "$public_selected" && -t 0 ]]; then
        read -r -p "Public overseas DNS upstreams [1.1.1.1,8.8.8.8]: " public_selected
    fi
    if [[ -z "$sniproxy_selected" && -t 0 ]]; then
        read -r -p "sniproxy resolver upstreams [same as private overseas DNS]: " sniproxy_selected
    fi

    if [[ -z "$private_selected" ]]; then
        private_selected="${DEFAULT_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$public_selected" ]]; then
        public_selected="${DEFAULT_PUBLIC_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$sniproxy_selected" ]]; then
        sniproxy_selected="$private_selected"
    fi

    OVERSEAS_DNS="$private_selected"
    PRIVATE_OVERSEAS_DNS="$private_selected"
    PUBLIC_OVERSEAS_DNS="$public_selected"
    SNIPROXY_DNS="$sniproxy_selected"

    mkdir -p "$CONF_DIR"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_dns"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_private_dns"
    echo "$PUBLIC_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_public_dns"
    echo "$SNIPROXY_DNS" > "${CONF_DIR}/.sniproxy_dns"
    info "Private overseas DNS upstreams: $PRIVATE_OVERSEAS_DNS"
    info "Public overseas DNS upstreams: $PUBLIC_OVERSEAS_DNS"
    info "sniproxy resolver upstreams: $SNIPROXY_DNS"
}


download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=10 --tries=2 -O "$output" "$url"
    else
        err "curl or wget is required for one-line remote install."
        exit 1
    fi
}

bootstrap_remote_project() {
    local missing=0
    local file

    for file in "${REQUIRED_PROJECT_FILES[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${file}" ]]; then
            missing=1
            break
        fi
    done

    [[ "$missing" == "0" ]] && return 0

    info "Detected one-line remote install mode; downloading full ${REPO_OWNER}/${REPO_NAME} project..."
    local workdir archive_file extracted_dir archive_url
    workdir=$(mktemp -d /tmp/5gpn-install.XXXXXX)
    archive_file="${workdir}/${REPO_NAME}.tar.gz"

    local archive_urls=(
        "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"
        "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    )

    for archive_url in "${archive_urls[@]}"; do
        if download_file "$archive_url" "$archive_file"; then
            if tar -xzf "$archive_file" -C "$workdir" 2>/dev/null; then
                extracted_dir=$(find "$workdir" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)
                if [[ -n "$extracted_dir" && -f "${extracted_dir}/install.sh" ]]; then
                    chmod +x "${extracted_dir}/install.sh"
                    info "Continuing installation from ${extracted_dir}"
                    cd "$extracted_dir"
                    exec bash "${extracted_dir}/install.sh" "$@"
                fi
            fi
        fi
        warn "Unable to download project archive from ${archive_url}; trying next source..."
    done

    warn "Archive download failed; falling back to raw.githubusercontent.com file download."
    extracted_dir="${workdir}/${REPO_NAME}"
    mkdir -p "${extracted_dir}/tests"
    download_file "${REPO_RAW_BASE}/install.sh" "${extracted_dir}/install.sh"
    for file in "${REQUIRED_PROJECT_FILES[@]}"; do
        download_file "${REPO_RAW_BASE}/${file}" "${extracted_dir}/${file}"
    done
    chmod +x "${extracted_dir}/install.sh" "${extracted_dir}/update-rules.sh" "${extracted_dir}/renew-hook.sh"
    info "Continuing installation from ${extracted_dir}"
    cd "$extracted_dir"
    exec bash "${extracted_dir}/install.sh" "$@"
}

# =============================================================================
# Command-line dispatch
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  (none)         Full interactive installation
  --status       Show service status
  --update-rules Update GFWList/ChinaList and reload dnsdist
  --renew-cert   Force renew certificates and reload services
  --uninstall    Remove all installed components
  -ios          Regenerate iOS DoT profile and QR code
  -h, --help     Show this help

Environment variables (for non-interactive use):
  DOMAIN         Pre-configured domain (skip ClouDNS registration)
  OVERSEAS_DNS   Backward-compatible alias for PRIVATE_OVERSEAS_DNS
  PRIVATE_OVERSEAS_DNS  Overseas upstream DNS for 172.22.0.0/16 DoT clients
  PUBLIC_OVERSEAS_DNS   Overseas upstream DNS for non-private DoT clients
  SNIPROXY_DNS   Resolver upstream DNS for TCP sniproxy backends
  CLOUDNS_ID     ClouDNS API auth-id
  CLOUDNS_PASS   ClouDNS API auth-password
  EMAIL          Email for Let's Encrypt
EOF
}

# =============================================================================
# Basic checks
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        err "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *)
            err "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    info "Detected OS: $OS $VER (package manager: $PKG_MGR)"
}

get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || echo "")
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "")
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        err "Failed to detect public IPv4 address. Please set PUBLIC_IP manually."
        exit 1
    fi
    info "Public IP detected: $PUBLIC_IP"
}

check_port_53() {
    info "Checking port 53 availability..."
    local pid
    pid=$(find_port53_pid)

    if [[ -n "$pid" ]]; then
        local proc
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        warn "Port 53 is already in use by: $proc (PID: $pid)"

        read -r -p "Stop and disable '$proc' to free port 53? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            err "Port 53 must be free for dnsdist to start. Aborting."
            exit 1
        fi

        stop_port53_owner "$pid" "$proc"
        sleep 1

        # Double check
        pid=$(find_port53_pid)
        if [[ -n "$pid" ]]; then
            err "Failed to free port 53. Please manually stop the service using it."
            exit 1
        fi
        ok "Port 53 is now free"
    else
        ok "Port 53 is available"
    fi
}

systemd_unit_for_pid() {
    local pid="${1:-}"
    [[ -z "$pid" || ! -r "/proc/$pid/cgroup" ]] && return 0
    grep -aoE '[^/]+\.service' "/proc/$pid/cgroup" | head -n1 || true
}

find_port53_pid() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lnptu 2>/dev/null | awk '
            $5 ~ /(^|\]|:)53$/ || $5 ~ /:53$/ {
                if (match($0, /pid=[0-9]+/)) {
                    print substr($0, RSTART + 4, RLENGTH - 4)
                    exit
                }
            }'
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN -t 2>/dev/null | head -n1
        return 0
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -lnptu 2>/dev/null | awk '
            $4 ~ /(^|\]|:)53$/ || $4 ~ /:53$/ {
                split($7, p, "/")
                if (p[1] ~ /^[0-9]+$/) {
                    print p[1]
                    exit
                }
            }'
        return 0
    fi

    return 0
}

ensure_system_dns() {
    local resolv_conf="/etc/resolv.conf"
    local backup="/etc/resolv.conf.proxy-gateway.bak"

    if [[ -f "$resolv_conf" ]] && grep -Eq '^nameserver[[:space:]]+([0-9a-fA-F:.]+)' "$resolv_conf"; then
        if ! grep -Eq '^nameserver[[:space:]]+(127\.0\.0\.53|127\.0\.0\.1|::1)([[:space:]]|$)' "$resolv_conf"; then
            return 0
        fi
    fi

    warn "Writing fallback DNS to /etc/resolv.conf before changing local DNS services"
    if [[ ! -e "$backup" && -e "$resolv_conf" ]]; then
        cp -aL "$resolv_conf" "$backup" 2>/dev/null || true
    fi
    rm -f "$resolv_conf"
    cat > "$resolv_conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
}

stop_port53_owner() {
    local pid="${1:-}"
    local proc="${2:-unknown}"
    local unit
    unit=$(systemd_unit_for_pid "$pid")

    ensure_system_dns

    if [[ -n "$unit" ]] && command -v systemctl >/dev/null 2>&1; then
        info "Stopping systemd unit owning port 53: $unit"
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    fi

    case "$proc" in
        systemd-resolve|systemd-resolved)
            info "Stopping systemd-resolved service to release DNS stub port 53"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop systemd-resolved.service 2>/dev/null || true
                systemctl disable systemd-resolved.service 2>/dev/null || true
            fi
            ;;
        dnsmasq)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop dnsmasq.service 2>/dev/null || true
                systemctl disable dnsmasq.service 2>/dev/null || true
            fi
            ;;
        named)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop named.service bind9.service 2>/dev/null || true
                systemctl disable named.service bind9.service 2>/dev/null || true
            fi
            ;;
    esac

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
}

# =============================================================================
# Dependencies
# =============================================================================
install_deps() {
    info "Installing system dependencies..."

    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                build-essential git wget curl ca-certificates \
                iproute2 procps lsof net-tools \
                libev-dev libssl-dev \
                autoconf automake libtool pkg-config \
                dnsdist certbot \
                python3 python3-pip jq libcap2-bin \
                nftables qrencode
            apt-get install -y -qq python3-certbot-dns-cloudflare 2>/dev/null || true
            apt-get install -y -qq libpcre3-dev 2>/dev/null || \
                apt-get install -y -qq libpcre2-dev 2>/dev/null || true
            apt-get install -y -qq libudns-dev 2>/dev/null || true
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                gcc gcc-c++ make git wget curl ca-certificates \
                iproute procps-ng lsof net-tools \
                libev-devel pcre-devel openssl-devel \
                autoconf automake libtool pkgconfig \
                dnsdist certbot \
                python3 python3-pip jq libcap-ng-utils \
                nftables qrencode
            $PKG_MGR install -y -q python3-certbot-dns-cloudflare 2>/dev/null || true
            ;;
    esac

    # Ensure Go is installed (for quic-proxy compilation)
    if ! command -v go >/dev/null 2>&1; then
        info "Installing Go compiler..."
        GO_VER="1.22.4"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GO_ARCH="amd64" ;;
            aarch64|arm64) GO_ARCH="arm64" ;;
            *) GO_ARCH="amd64" ;;
        esac
        wget -q "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi

    ok "Go version: $(go version)"

    # Ensure Python requests for cloudns API fallback
    pip3 install requests -q 2>/dev/null || true

    # Fix certbot compatibility on newer Python versions (e.g. 3.12+)
    if command -v certbot >/dev/null 2>&1; then
        if ! certbot --version >/dev/null 2>&1; then
            warn "Certbot has compatibility issues with the current Python version. Attempting to fix..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
        fi
    fi

    # Verify critical binaries
    for bin in dnsdist certbot; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            err "Required package '$bin' was not installed successfully."
            err "Please check your package manager output above."
            exit 1
        fi
    done
}

# =============================================================================
# Domain generation & ClouDNS
# =============================================================================
generate_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        info "Using pre-configured domain: $DOMAIN"
        DOMAIN_PRECONFIGURED=1
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi

    # Generate a deterministic 4-char lowercase alphabetic prefix from IP hash
    # Same IP always produces the same prefix, keeping reinstalls consistent
    local prefix
    prefix=$(python3 -c "
import hashlib
h = hashlib.md5('${PUBLIC_IP}'.encode()).hexdigest()[:4]
print(''.join(chr(97 + int(c, 16) % 26) for c in h))
")

    local tld=""

    # If TLD is preset via environment variable, use it directly
    if [[ -n "${CLOUDNS_TLD:-}" ]]; then
        tld="${CLOUDNS_TLD}"
        info "Using pre-selected TLD: ${tld}"
    else
        # Interactive selection
        echo ""
        echo "=================================================="
        echo "  请选择 ClouDNS 免费域名后缀"
        echo "=================================================="
        local i=1
        for t in "${CLOUDNS_FREE_TLDS[@]}"; do
            echo "  ${i}) ${prefix}.${t}"
            i=$((i + 1))
        done
        echo "=================================================="
        echo ""

        local choice=""
        while true; do
            read -r -p "请输入序号 (1-${#CLOUDNS_FREE_TLDS[@]}): " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#CLOUDNS_FREE_TLDS[@]} ]]; then
                tld="${CLOUDNS_FREE_TLDS[$((choice - 1))]}"
                break
            else
                warn "无效输入，请重新输入 1-${#CLOUDNS_FREE_TLDS[@]} 之间的数字"
            fi
        done
    fi

    DOMAIN="${prefix}.${tld}"

    info "Generated混淆域名: $DOMAIN"
    info "Prefix is derived from public IP (same IP = same prefix)"

    # Always update domain file so reinstalls pick up the current choice
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
}

register_domain_cloudns() {
    if [[ "${DOMAIN_PRECONFIGURED:-0}" == "1" ]]; then
        info "Skipping ClouDNS registration prompt for pre-configured domain: $DOMAIN"
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi

    if [[ -f "${CONF_DIR}/.domain_registered" ]]; then
        info "Domain already registered flag found."
        # Ensure .domain file stays in sync even on reinstalls
        local saved_domain=""
        saved_domain=$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)
        if [[ "$saved_domain" != "$DOMAIN" ]]; then
            warn "Updating saved domain: $saved_domain -> $DOMAIN"
            echo "$DOMAIN" > "${CONF_DIR}/.domain"
        fi
        return
    fi

    info "ClouDNS 注册提示"
    info "=================================================="
    info "域名: $DOMAIN"
    info "A 记录值: $PUBLIC_IP"
    info "=================================================="
    info ""
    info "请按以下步骤完成注册（免费）:"
    info "1. 访问 https://www.cloudns.net 并登录/注册免费账户"
    info "2. 进入 Dashboard -> Create zone -> Free zone"
    info "3. 输入域名前缀: ${DOMAIN%%.*}"
    info "4. 选择后缀: .${DOMAIN##*.}"
    info "5. 创建后添加一条 A 记录:"
    info "   Host: @ (或留空)"
    info "   Type: A"
    info "   Points to: $PUBLIC_IP"
    info "   TTL: 3600"
    info ""

    # Try API registration if credentials provided
    if [[ -n "${CLOUDNS_ID:-}" && -n "${CLOUDNS_PASS:-}" ]]; then
        info "尝试通过 ClouDNS API 自动注册..."
        local resp
        resp=$(curl -s -X POST "https://api.cloudns.net/dns/register.json" \
            -d "auth-id=${CLOUDNS_ID}" \
            -d "auth-password=${CLOUDNS_PASS}" \
            -d "domain-name=${DOMAIN}" \
            -d "zone-type=domain" 2>/dev/null || echo "")
        if echo "$resp" | grep -qi "success\|registered"; then
            ok "API 注册成功 (或域名已存在)"
            sleep 2
            # Add A record
            curl -s -X POST "https://api.cloudns.net/dns/add-record.json" \
                -d "auth-id=${CLOUDNS_ID}" \
                -d "auth-password=${CLOUDNS_PASS}" \
                -d "domain-name=${DOMAIN}" \
                -d "record-type=A" \
                -d "host=" \
                -d "record=${PUBLIC_IP}" \
                -d "ttl=3600" >/dev/null || true
            mkdir -p "$CONF_DIR"
            echo "$DOMAIN" > "${CONF_DIR}/.domain"
            touch "${CONF_DIR}/.domain_registered"
            return
        else
            warn "API 注册失败或不可用 ($resp)，请手动注册"
        fi
    fi

    info ""
    read -r -p "完成注册后按 Enter 继续（或输入 'skip' 跳过验证）: " confirm
    if [[ "$confirm" == "skip" ]]; then
        warn "跳过域名解析验证，请确保 A 记录已正确配置"
    else
        info "等待 DNS 解析生效（最多 120 秒）..."
        local waited=0
        while [[ $waited -lt 120 ]]; do
            local resolved
            resolved=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null || echo "")
            if [[ "$resolved" == "$PUBLIC_IP" ]]; then
                ok "DNS 解析验证通过: $DOMAIN -> $PUBLIC_IP"
                break
            fi
            sleep 5
            waited=$((waited + 5))
            echo -n "."
        done
        if [[ $waited -ge 120 ]]; then
            warn "DNS 解析未在 120 秒内生效，将继续安装。如后续证书申请失败，请检查 DNS 配置。"
        fi
    fi

    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    touch "${CONF_DIR}/.domain_registered"
}

# =============================================================================
# Let's Encrypt Certificate
# =============================================================================
install_cert() {
    local certbot_cmd certbot_cmd_force
    install_certbot_firewall_hooks

    # Normal issuance (first time) - no force-renewal to avoid rate limits
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    # Reinstall / explicit renew - force renewal
    certbot_cmd_force=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)

    local cb_cmd=()
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        info "Let's Encrypt certificate already exists for $DOMAIN, forcing renewal..."
        cb_cmd=("${certbot_cmd_force[@]}")
    else
        info "申请 Let's Encrypt 证书 for $DOMAIN..."
        cb_cmd=("${certbot_cmd[@]}")
    fi

    run_certbot() {
        open_cert_http_port
        trap restore_reverse_proxy_firewall RETURN
        if "${cb_cmd[@]}"; then
            return 0
        fi
        # Check for known Python compatibility error
        if "${cb_cmd[@]}" 2>&1 | grep -q "AttributeError" || \
           certbot --version 2>&1 | grep -q "AttributeError"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate request..."
            "${cb_cmd[@]}"
        else
            return 1
        fi
    }

    if ! run_certbot; then
        err "证书申请失败。请检查:"
        err "  1. 域名 $DOMAIN 是否正确解析到本机 ($PUBLIC_IP)"
        err "  2. 端口 80 是否被占用"
        err "  3. 防火墙是否放行 80"
        err "  4. 是否触发了 Let's Encrypt 速率限制 (同一域名 7 天内限 5 次)"
        exit 1
    fi

    # Copy certificates to dnsdist-readable location
    info "Copying certificates to /etc/dnsdist/certs/ ..."
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/dnsdist/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/dnsdist/certs/privkey.pem
        chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
        chmod 640 /etc/dnsdist/certs/*.pem
        ok "Certificates copied to /etc/dnsdist/certs/"
    else
        warn "Could not find certificate live directory: $cert_live_dir"
    fi

    # Deploy renewal hook (also handles cert copy on renewal)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cp "${SCRIPT_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    ok "证书已就绪，自动续期 Hook 已部署"
}

# =============================================================================
# sniproxy (TCP)
# =============================================================================
install_sniproxy() {
    if ! command -v sniproxy >/dev/null 2>&1; then
        info "Compiling sniproxy (TCP SNI proxy)..."
        mkdir -p "$SRC_DIR"
        cd "$SRC_DIR"

        if [[ ! -d sniproxy ]]; then
            git clone --depth=1 https://github.com/dlundquist/sniproxy.git
        fi
        cd sniproxy

        DEBEMAIL="root@localhost" DEBFULLNAME="root" ./autogen.sh >/dev/null
        ./configure --prefix=/usr/local --sysconfdir=/etc --enable-dns >/dev/null
        make -j$(nproc) >/dev/null
        make install >/dev/null
    else
        info "sniproxy already installed"
    fi

    if [[ -f "${SCRIPT_DIR}/sniproxy.conf" ]]; then
        local sniproxy_nameservers
        sniproxy_nameservers=$(render_sniproxy_dns_nameservers "$SNIPROXY_DNS")
        python3 - "${SCRIPT_DIR}/sniproxy.conf" "$sniproxy_nameservers" /etc/sniproxy.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__SNIPROXY_NAMESERVERS__", sys.argv[2])
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    else
        err "sniproxy.conf not found in ${SCRIPT_DIR}"
        exit 1
    fi

    # systemd service
    cat > /etc/systemd/system/sniproxy.service <<'EOF'
[Unit]
Description=sniproxy (TCP SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy.conf -f
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sniproxy
    ok "sniproxy installed"
}

# =============================================================================
# quic-proxy (UDP / QUIC SNI proxy)
# =============================================================================
install_quic_proxy() {
    if [[ ! -x "${BASE_DIR}/bin/quic-proxy" ]]; then
        info "Compiling quic-proxy (UDP/QUIC SNI proxy)..."
        mkdir -p "${BASE_DIR}/bin"
        mkdir -p "${SRC_DIR}"
        cp "${SCRIPT_DIR}/quic-proxy.go" "${SRC_DIR}/quic-proxy.go"
        cd "${SRC_DIR}"

        export PATH=$PATH:/usr/local/go/bin
        go build -ldflags="-s -w" -o "${BASE_DIR}/bin/quic-proxy" quic-proxy.go
    else
        info "quic-proxy already compiled"
    fi

    # systemd service
    cat > /etc/systemd/system/quic-proxy.service <<'EOF'
[Unit]
Description=quic-proxy (UDP/QUIC SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/opt/proxy-gateway/bin/quic-proxy -l 0.0.0.0:443
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable quic-proxy
    ok "quic-proxy installed"
}

# =============================================================================
# China DNS race proxy (UDP DNS upstream racing for ChinaList)
# =============================================================================
install_china_dns_race_proxy() {
    info "Compiling china-dns-race-proxy..."
    mkdir -p "${BASE_DIR}/bin"
    mkdir -p "${SRC_DIR}"
    cp "${SCRIPT_DIR}/china-dns-race-proxy.go" "${SRC_DIR}/china-dns-race-proxy.go"
    cd "${SRC_DIR}"

    export PATH=$PATH:/usr/local/go/bin
    go build -ldflags="-s -w" -o "${BASE_DIR}/bin/china-dns-race-proxy" china-dns-race-proxy.go

    cat > /etc/systemd/system/china-dns-race-proxy.service <<'EOF'
[Unit]
Description=China DNS race proxy
After=network.target
Before=dnsdist.service

[Service]
Type=simple
ExecStart=/opt/proxy-gateway/bin/china-dns-race-proxy -l 127.0.0.1:5301
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable china-dns-race-proxy
    ok "china-dns-race-proxy installed"
}

# =============================================================================
# dnsdist (DoT + Smart DNS)
# =============================================================================
install_dnsdist() {
    info "Configuring dnsdist..."

    mkdir -p /etc/dnsdist
    cp "${SCRIPT_DIR}/dnsdist.conf.template" /etc/dnsdist/dnsdist.conf.template
    cp "${SCRIPT_DIR}/update-rules.sh" /usr/local/bin/update-dnsdist-rules.sh
    chmod +x /usr/local/bin/update-dnsdist-rules.sh

    # Save domain and IP for template generation
    echo "$DOMAIN" > /etc/dnsdist/.domain
    echo "$PUBLIC_IP" > /etc/dnsdist/.public_ip
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/dnsdist/.overseas_dns
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/dnsdist/.overseas_private_dns
    echo "$PUBLIC_OVERSEAS_DNS" > /etc/dnsdist/.overseas_public_dns
    echo "$SNIPROXY_DNS" > /etc/dnsdist/.sniproxy_dns
    local overseas_private_servers overseas_public_servers
    overseas_private_servers=$(render_overseas_dns_servers "$PRIVATE_OVERSEAS_DNS" "overseas_private" "overseas_private")
    overseas_public_servers=$(render_overseas_dns_servers "$PUBLIC_OVERSEAS_DNS" "overseas_public" "overseas_public")

    # Determine actual certificate directory name
    local cert_basename="${DOMAIN}"
    if [[ -f "${CONF_DIR}/.cert_basename" ]]; then
        cert_basename=$(cat "${CONF_DIR}/.cert_basename")
    fi

    # Generate initial config (empty rules, will be populated by update-rules.sh)
    python3 - /etc/dnsdist/dnsdist.conf.template "${PUBLIC_IP}" "${cert_basename}" "$overseas_private_servers" "$overseas_public_servers" /etc/dnsdist/dnsdist.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__GFWLIST_RULES__", "-- (rules will be loaded by update-rules.sh)")
content = content.replace("__CHINALIST_RULES__", "-- (rules will be loaded by update-rules.sh)")
content = content.replace("__SERVER_IP__", sys.argv[2])
content = content.replace("__DOMAIN__", sys.argv[3])
content = content.replace("__OVERSEAS_PRIVATE_DNS_SERVERS__", sys.argv[4])
content = content.replace("__OVERSEAS_PUBLIC_DNS_SERVERS__", sys.argv[5])
with open(sys.argv[6], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

    # systemd override for dnsdist (ensure it reads our config + supports reload)
    mkdir -p /etc/systemd/system/dnsdist.service.d
    cat > /etc/systemd/system/dnsdist.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dnsdist --supervised -C /etc/dnsdist/dnsdist.conf
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=65535
EOF

    systemctl daemon-reload
    systemctl enable dnsdist
    ok "dnsdist configured"
}

# =============================================================================
# Rules initialization
# =============================================================================
init_rules() {
    info "Initializing GFWList and ChinaList..."
    /usr/local/bin/update-dnsdist-rules.sh || warn "Rule update failed, will retry later"
}

# =============================================================================
# iOS DoT profile
# =============================================================================
generate_ios_profile() {
    info "Generating iOS DoT configuration profile..."

    mkdir -p "$WWW_DIR"
    local profile_path="${WWW_DIR}/ios-dot.mobileconfig"
    local profile_url="http://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig"

    cat > "$profile_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>TLS</string>
                <key>ServerName</key>
                <string>${DOMAIN}</string>
                <key>ServerAddresses</key>
                <array>
                    <string>${PUBLIC_IP}</string>
                </array>
            </dict>
            <key>OnDemandRules</key>
            <array>
                <dict>
                    <key>Action</key>
                    <string>Connect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>Cellular</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>WiFi</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Use ${DOMAIN} DNS over TLS only on cellular networks.</string>
            <key>PayloadDisplayName</key>
            <string>Proxy Gateway Cellular DoT</string>
            <key>PayloadIdentifier</key>
            <string>com.proxy-gateway.${DOMAIN}.dnssettings</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs a DNS over TLS profile for cellular networks only.</string>
    <key>PayloadDisplayName</key>
    <string>Proxy Gateway Cellular DoT</string>
    <key>PayloadIdentifier</key>
    <string>com.proxy-gateway.${DOMAIN}</string>
    <key>PayloadOrganization</key>
    <string>Proxy Gateway</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

    cat > "${WWW_DIR}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Proxy Gateway iOS DoT</title>
</head>
<body>
  <h1>Proxy Gateway iOS DoT</h1>
  <p><a href="/ios-dot.mobileconfig">下载 iOS 蜂窝网络 DoT 描述文件</a></p>
</body>
</html>
EOF

    cat > /etc/systemd/system/proxy-gateway-ios-profile.service <<EOF
[Unit]
Description=Proxy Gateway iOS profile static server
After=network.target

[Service]
Type=simple
WorkingDirectory=${WWW_DIR}
ExecStart=/usr/bin/python3 -m http.server ${IOS_PROFILE_PORT} --bind 0.0.0.0
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now proxy-gateway-ios-profile.service

    echo "$profile_url" > "${WWW_DIR}/ios-profile-url.txt"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$profile_url" | tee "${WWW_DIR}/ios-dot.qr.txt"
    else
        warn "qrencode is not installed; QR code skipped. Profile URL: $profile_url"
    fi

    ok "iOS profile ready: $profile_url"
}

# =============================================================================
# System tuning
# =============================================================================
system_tuning() {
    info "Applying kernel and system tuning..."

    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d
    echo nf_conntrack > /etc/modules-load.d/proxy-gateway-net.conf

    cat > /etc/sysctl.d/99-proxy-gateway.conf <<'EOF'
# Proxy Gateway Optimizations
fs.file-max=10240000
fs.nr_open=2097152
net.core.default_qdisc=fq
net.core.netdev_max_backlog=65536
net.core.somaxconn=10240000
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.ip_default_ttl=128
net.ipv4.ip_forward=1
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_fastopen=1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec=0
net.ipv4.tcp_fin_timeout=2
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_max_orphans=10240
net.ipv4.tcp_max_syn_backlog=65536
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_retries1=2
net.ipv4.tcp_retries2=2
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_rmem=8192 65536 134217728
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_wmem=8192 131072 134217728
net.netfilter.nf_conntrack_generic_timeout=10
net.netfilter.nf_conntrack_icmp_timeout=2
net.netfilter.nf_conntrack_max=10240000
net.netfilter.nf_conntrack_tcp_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_close=2
net.netfilter.nf_conntrack_tcp_timeout_close_wait=2
net.netfilter.nf_conntrack_tcp_timeout_established=30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=2
net.netfilter.nf_conntrack_tcp_timeout_last_ack=2
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=2
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=2
net.netfilter.nf_conntrack_tcp_timeout_time_wait=2
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=2
net.netfilter.nf_conntrack_udp_timeout=2
net.netfilter.nf_conntrack_udp_timeout_stream=30
vm.swappiness=0
EOF

    local mem_pages
    mem_pages=$(awk '/MemTotal/ { printf "%d", ($2 * 1024) / 4096 }' /proc/meminfo 2>/dev/null || echo "")
    if [[ -n "$mem_pages" && "$mem_pages" -gt 0 ]]; then
        {
            echo "net.ipv4.tcp_mem=$((mem_pages / 100 * 12)) $((mem_pages / 100 * 50)) $((mem_pages / 100 * 70))"
        } >> /etc/sysctl.d/99-proxy-gateway.conf
    fi

    sysctl --system >/dev/null

    # PAM limits (avoid duplicate entries)
    if ! grep -q "proxy-gateway-limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# proxy-gateway-limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/disable-transparent-huge-pages.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=basic.target
EOF

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxy-gateway.conf <<'EOF'
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF

    systemctl daemon-reload
    systemctl enable --now disable-transparent-huge-pages.service 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true

    ok "System tuning applied"
}

# =============================================================================
# Firewall (nftables preferred, fallback to iptables)
# =============================================================================
setup_firewall() {
    info "Configuring firewall..."

    if command -v nft >/dev/null 2>&1; then
        # nftables
        cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 22, 53, 853, 8111 } accept
        udp dport 53 accept
        ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept
        ip saddr 172.22.0.0/16 udp dport 443 accept
        # ICMP for basic network health
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
        chmod +x /etc/nftables.conf
        nft -f /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables 2>/dev/null || true
    else
        # iptables fallback
        iptables -F INPUT
        iptables -P INPUT DROP
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp -m multiport --dports 22,53,853,8111 -j ACCEPT
        iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p tcp -m multiport --dports 80,443 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p udp --dport 443 -j ACCEPT
        iptables -A INPUT -p icmp -j ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT

        # Save rules
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
    fi

    ok "Firewall configured (reverse proxy whitelist: 172.22.0.0/16)"
}

open_cert_http_port() {
    info "Temporarily opening TCP/80 for Let's Encrypt HTTP-01..."

    if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
        nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
    fi
}

restore_reverse_proxy_firewall() {
    info "Restoring reverse proxy firewall whitelist..."
    setup_firewall >/dev/null 2>&1 || true
}

install_certbot_firewall_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

    cat > /usr/local/bin/proxy-gateway-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
fi
EOF
    cat > /usr/local/bin/proxy-gateway-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then
    nft -f /etc/nftables.conf 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
EOF
    chmod +x /usr/local/bin/proxy-gateway-open-cert-http.sh /usr/local/bin/proxy-gateway-restore-firewall.sh
    cp /usr/local/bin/proxy-gateway-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh
    cp /usr/local/bin/proxy-gateway-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
}

# =============================================================================
# Start services
# =============================================================================
start_services() {
    info "Starting services..."
    systemctl restart china-dns-race-proxy || { err "china-dns-race-proxy failed to start"; journalctl -u china-dns-race-proxy --no-pager -n 20; exit 1; }
    systemctl restart dnsdist || { err "dnsdist failed to start"; journalctl -u dnsdist --no-pager -n 20; exit 1; }
    systemctl restart sniproxy || { err "sniproxy failed to start"; journalctl -u sniproxy --no-pager -n 20; exit 1; }
    systemctl restart quic-proxy || { err "quic-proxy failed to start"; journalctl -u quic-proxy --no-pager -n 20; exit 1; }
    ok "All services started"
}

# =============================================================================
# Cron / Systemd timers
# =============================================================================
setup_schedules() {
    info "Setting up automatic updates..."

    # Weekly rule update (Sunday 03:00)
    cat > /etc/systemd/system/update-dnsdist-rules.timer <<'EOF'
[Unit]
Description=Weekly dnsdist rules update

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/update-dnsdist-rules.service <<'EOF'
[Unit]
Description=Update dnsdist GFWList/ChinaList rules

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-dnsdist-rules.sh
EOF

    systemctl daemon-reload
    systemctl enable --now update-dnsdist-rules.timer

    install_certbot_firewall_hooks

    # Ensure certbot timer is enabled
    systemctl enable --now certbot.timer 2>/dev/null || true

    ok "Schedules configured (rules: weekly, cert: auto)"
}

# =============================================================================
# Status / Uninstall / Helpers
# =============================================================================
show_status() {
    echo "=========================================="
    echo "      Proxy Gateway Status"
    echo "=========================================="
    for svc in dnsdist sniproxy quic-proxy china-dns-race-proxy proxy-gateway-ios-profile; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        if [[ "$status" == "active" ]]; then
            echo -e "$svc: ${GREEN}running${NC}"
        else
            echo -e "$svc: ${RED}$status${NC}"
        fi
    done
    echo ""
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        echo "Domain: $(cat "${CONF_DIR}/.domain")"
    fi
    echo "Public IP: ${PUBLIC_IP:-N/A}"
    echo "=========================================="
}

do_uninstall() {
    warn "This will remove sniproxy, quic-proxy, china-dns-race-proxy, dnsdist configs, and rules."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }

    systemctl stop dnsdist sniproxy quic-proxy china-dns-race-proxy proxy-gateway-ios-profile 2>/dev/null || true
    systemctl disable dnsdist sniproxy quic-proxy china-dns-race-proxy proxy-gateway-ios-profile 2>/dev/null || true
    rm -f /etc/systemd/system/{sniproxy,quic-proxy,china-dns-race-proxy,proxy-gateway-ios-profile,update-dnsdist-rules}.*
    systemctl daemon-reload

    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/dnsdist /usr/local/bin/update-dnsdist-rules.sh
    rm -f /usr/local/sbin/sniproxy
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    rm -f /etc/sysctl.d/99-proxy-gateway.conf
    rm -f /etc/profile.d/go.sh

    # Optionally remove certbot certs
    warn "SSL certificates in /etc/letsencrypt/live/ are kept. Remove manually if needed."

    ok "Uninstall completed"
}

force_renew_cert() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot renew."
        exit 1
    fi

    local certbot_cmd
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)

    open_cert_http_port
    trap restore_reverse_proxy_firewall RETURN

    if ! "${certbot_cmd[@]}"; then
        # Check for known Python compatibility error
        if certbot --version 2>&1 | grep -q "AttributeError" || \
           "${certbot_cmd[@]}" 2>&1 | grep -q "AttributeError"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate renewal..."
            "${certbot_cmd[@]}" || { err "Certificate renewal failed"; exit 1; }
        else
            err "Certificate renewal failed"
            exit 1
        fi
    fi

    # Re-copy certificates to dnsdist-readable location
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/dnsdist/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/dnsdist/certs/privkey.pem
        chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
        chmod 640 /etc/dnsdist/certs/*.pem
    fi

    if systemctl is-active --quiet dnsdist; then
        systemctl reload dnsdist && ok "Certificate renewed and dnsdist reloaded"
    else
        systemctl start dnsdist && ok "Certificate renewed and dnsdist started"
    fi
}

regenerate_ios_profile() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    elif [[ -f /etc/dnsdist/.domain ]]; then
        DOMAIN=$(cat /etc/dnsdist/.domain)
    fi

    if [[ -f /etc/dnsdist/.public_ip ]]; then
        PUBLIC_IP=$(cat /etc/dnsdist/.public_ip)
    else
        get_public_ip
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot generate iOS profile."
        exit 1
    fi

    generate_ios_profile
}

# =============================================================================
# Main installation flow
# =============================================================================
main_install() {
    bootstrap_remote_project "$@"
    check_root
    detect_os
    get_public_ip

    echo ""
    echo "=========================================="
    echo "  高性能反代系统一键部署"
    echo "=========================================="
    echo ""

    install_deps
    check_port_53
    generate_domain
    register_domain_cloudns
    install_cert
    configure_overseas_dns
    install_sniproxy
    install_quic_proxy
    install_china_dns_race_proxy
    install_dnsdist
    init_rules
    system_tuning
    setup_firewall
    generate_ios_profile
    start_services
    setup_schedules

    echo ""
    echo "=========================================="
    echo "         部署完成！"
    echo "=========================================="
    echo ""
    echo "DoT 地址:  tls://${DOMAIN}:853"
    echo "TCP 代理:  ${PUBLIC_IP}:80, ${PUBLIC_IP}:443 (sniproxy)"
    echo "UDP 代理:  ${PUBLIC_IP}:443 (quic-proxy)"
    echo "DNS 查询:  ${PUBLIC_IP}:53"
    echo "iOS 描述文件: http://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig"
    echo ""
    echo "客户端配置示例 (Android 私人 DNS):"
    echo "  ${DOMAIN}"
    echo "iOS 扫码安装:"
    if [[ -f "${WWW_DIR}/ios-dot.qr.txt" ]]; then
        cat "${WWW_DIR}/ios-dot.qr.txt"
    fi
    echo ""
    echo "管理命令:"
    echo "  $0 --status"
    echo "  $0 --update-rules"
    echo "  $0 --renew-cert"
    echo "  $0 -ios"
    echo "  $0 --uninstall"
    echo "=========================================="
}

# =============================================================================
# Entrypoint
# =============================================================================
case "${1:-}" in
    --status)
        get_public_ip 2>/dev/null || true
        show_status
        ;;
    --update-rules)
        /usr/local/bin/update-dnsdist-rules.sh
        ;;
    --renew-cert)
        force_renew_cert
        ;;
    --uninstall)
        do_uninstall
        ;;
    -ios)
        regenerate_ios_profile
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        main_install
        ;;
esac
