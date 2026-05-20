#!/usr/bin/env bash
# ============================================================
#  VaultHound — Agent Installer
#  Agent binary  : /usr/bin/vaulthound-agent
#  Config dir    : /etc/vaulthound/
#  Service name  : vaulthound-agent
# ============================================================
set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
hdr()  { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━${NC}"; }

[[ $EUID -ne 0 ]] && err "Run as root:  sudo bash install-agent.sh"

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}"
cat <<'BANNER'
 __   __            _ _     _  _                      _
 \ \ / /_ _ _  _| | |_  | || |___ _  _ _ _  __| |
  \ V / _` | || | |  _| | __ / _ \ || | ' \/ _` |
   \_/\__,_|\_,_|_|\__| |_||_\___/\_,_|_||_\__,_|
              AGENT INSTALLER  v1.0.0
BANNER
echo -e "${NC}"

# ── Directories ──────────────────────────────────────────────
CFG_DIR="/etc/vaulthound"
LOG_DIR="/var/log/vaulthound"
BUILD_DIR="/tmp/vaulthound-agent-build"
AGENT_BIN="/usr/bin/vaulthound-agent"
SERVICE="vaulthound-agent"
SERVICE_USER="vaulthound"
GO_VERSION="1.22.3"

mkdir -p "$CFG_DIR" "$LOG_DIR"

# ── Detect OS ────────────────────────────────────────────────
hdr "Detecting OS and architecture"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    armv7*)  GO_ARCH="armv6l" ;;
    *)        err "Unsupported architecture: $ARCH" ;;
esac

if   [ -f /etc/debian_version ];                                     then PKG_MGR="apt";  DISTRO="debian"
elif grep -qi "amazon linux 2023" /etc/os-release 2>/dev/null;       then PKG_MGR="dnf";  DISTRO="amzn2023"
elif grep -qi "amazon linux" /etc/os-release 2>/dev/null;            then PKG_MGR="yum";  DISTRO="amzn"
elif [ -f /etc/redhat-release ] && command -v dnf &>/dev/null;        then PKG_MGR="dnf";  DISTRO="rhel"
elif [ -f /etc/redhat-release ];                                      then PKG_MGR="yum";  DISTRO="centos"
elif [ -f /etc/alpine-release ];                                      then PKG_MGR="apk";  DISTRO="alpine"
else err "Unsupported OS"; fi

log "OS: $DISTRO  Arch: $ARCH ($GO_ARCH)  PKG: $PKG_MGR"

# ── Prompt: master details ───────────────────────────────────
hdr "Master Server Configuration"
read -rp "$(echo -e "${CYAN}Enter master server URL (e.g. http://192.168.1.10:4000): ${NC}")" MASTER_URL
[[ -z "$MASTER_URL" ]] && err "Master URL is required"

read -rp "$(echo -e "${CYAN}Enter server token (from master install summary): ${NC}")" SERVER_TOKEN
[[ -z "$SERVER_TOKEN" ]] && warn "No token entered — requests may be rejected by master"

read -rp "$(echo -e "${CYAN}Scan interval in minutes [30]: ${NC}")" SCAN_INTERVAL
SCAN_INTERVAL="${SCAN_INTERVAL:-30}"

read -rp "$(echo -e "${CYAN}Auto-discover Docker containers? [Y/n]: ${NC}")" AUTO_YN
AUTO_DISCOVER="false"
[[ "${AUTO_YN,,}" != "n" ]] && AUTO_DISCOVER="true"

read -rp "$(echo -e "${CYAN}Run as daemon (continuous scanning)? [Y/n]: ${NC}")" DAEMON_YN
DAEMON="false"
[[ "${DAEMON_YN,,}" != "n" ]] && DAEMON="true"

# ── System packages ──────────────────────────────────────────
hdr "Installing system dependencies"
case "$PKG_MGR" in
    apt)
        apt-get update -qq
        apt-get install -y -qq curl wget git ca-certificates gnupg2 lsb-release \
            apt-transport-https software-properties-common
        ;;
    dnf)
        dnf install -y curl wget git ca-certificates gnupg2
        ;;
    yum)
        yum install -y curl wget git ca-certificates gnupg2
        ;;
    apk)
        apk add --no-cache curl wget git ca-certificates gnupg
        ;;
esac
log "System packages installed"

# ── Install Trivy ────────────────────────────────────────────
hdr "Installing Trivy (vulnerability scanner)"
install_trivy() {
    case "$DISTRO" in
        debian)
            # Official Debian/Ubuntu method from trivy.dev docs
            wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
                | gpg --dearmor | tee /usr/share/keyrings/trivy.gpg > /dev/null
            echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
                | tee /etc/apt/sources.list.d/trivy.list
            apt-get update -qq
            apt-get install -y -qq trivy
            ;;
        rhel|amzn2023)
            # Official RHEL/CentOS method
            cat > /etc/yum.repos.d/trivy.repo <<'REPO'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
REPO
            dnf install -y trivy
            ;;
        amzn)
            cat > /etc/yum.repos.d/trivy.repo <<'REPO'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
REPO
            yum install -y trivy
            ;;
        alpine)
            # Install script method for Alpine
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
                | sh -s -- -b /usr/local/bin
            ;;
        *)
            # Universal install script fallback
            warn "Using universal install script for Trivy…"
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
                | sh -s -- -b /usr/local/bin
            ;;
    esac
}

if command -v trivy &>/dev/null; then
    log "Trivy already installed: $(trivy --version 2>&1 | head -1)"
    read -rp "$(echo -e "${CYAN}Reinstall/upgrade Trivy? [y/N]: ${NC}")" REINSTALL_TRIVY
    [[ "${REINSTALL_TRIVY,,}" == "y" ]] && install_trivy
else
    install_trivy
fi

if ! command -v trivy &>/dev/null; then
    err "Trivy installation failed. Check your internet connection and try again."
fi
log "Trivy: $(trivy --version 2>&1 | head -1)"

# ── Install Go ───────────────────────────────────────────────
hdr "Installing Go ${GO_VERSION}"

install_go() {
    local go_tar="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    local go_url="https://go.dev/dl/${go_tar}"
    wget -qO "/tmp/${go_tar}" "$go_url"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${go_tar}"
    rm "/tmp/${go_tar}"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

if command -v go &>/dev/null; then
    CURRENT_GO=$(go version | awk '{print $3}' | tr -d 'go')
    log "Go ${CURRENT_GO} already installed"
    # Check if version is recent enough (1.21+)
    MAJOR_MINOR=$(echo "$CURRENT_GO" | cut -d. -f1-2)
    if awk "BEGIN{exit !($MAJOR_MINOR >= 1.21)}"; then
        log "Go version is sufficient — skipping reinstall"
    else
        warn "Go version too old, upgrading to ${GO_VERSION}…"
        install_go
    fi
else
    install_go
fi

export PATH=$PATH:/usr/local/go/bin
log "Go: $(go version)"

# ── Build the agent binary ───────────────────────────────────
hdr "Building VaultHound Agent"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SRC="${SCRIPT_DIR}/main.go"
AGENT_MOD="${SCRIPT_DIR}/go.mod"

mkdir -p "$BUILD_DIR"

if [[ -f "$AGENT_SRC" ]]; then
    cp "$AGENT_SRC" "$BUILD_DIR/main.go"
    cp "$AGENT_MOD" "$BUILD_DIR/go.mod"
else
    err "Agent source not found at $AGENT_SRC. Ensure main.go is alongside this script."
fi

cd "$BUILD_DIR"
export GOPATH="/tmp/go-pkg"
export GOCACHE="/tmp/go-cache"
go build -ldflags="-s -w -X main.Version=1.0.0" -o "$AGENT_BIN" .
chmod 755 "$AGENT_BIN"

log "Binary built: $AGENT_BIN  ($(du -h $AGENT_BIN | cut -f1))"

# ── Service user ─────────────────────────────────────────────
hdr "Creating service user"
if id "$SERVICE_USER" &>/dev/null; then
    log "User '$SERVICE_USER' already exists"
else
    useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_USER"
    log "User '$SERVICE_USER' created"
fi

# ── Configuration file ───────────────────────────────────────
hdr "Writing agent configuration"

# Preserve existing agent ID if present
EXISTING_ID=""
[[ -f "$CFG_DIR/.agent-id" ]] && EXISTING_ID=$(cat "$CFG_DIR/.agent-id")

cat > "$CFG_DIR/agent.conf" <<EOF
# ============================================================
#  VaultHound Agent Configuration
#  Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#  Binary   : ${AGENT_BIN}
# ============================================================

# ── Master Server ─────────────────────────────────────────────
# URL of the VaultHound master server
MASTER_URL=${MASTER_URL}

# ── Authentication ────────────────────────────────────────────
# Must match SERVER_TOKEN in /etc/vaulthound/server.conf on master
SERVER_TOKEN=${SERVER_TOKEN}

# ── Scan Targets ──────────────────────────────────────────────
# Uncomment and set specific targets, or use AUTO_DISCOVER
#SCAN_IMAGE=nginx:latest
#SCAN_REPO=https://github.com/your-org/your-repo
#SCAN_DIR=/var/www/html

# Auto-discover all running Docker containers and scan their images
AUTO_DISCOVER=${AUTO_DISCOVER}

# ── Scheduling ────────────────────────────────────────────────
# Run as a daemon (continuous scanning)
DAEMON=${DAEMON}
# Minutes between scan cycles (only relevant in daemon mode)
SCAN_INTERVAL=${SCAN_INTERVAL}

# ── Logging ───────────────────────────────────────────────────
LOG_FILE=/var/log/vaulthound/agent.log
EOF

chmod 640 "$CFG_DIR/agent.conf"
chown root:"$SERVICE_USER" "$CFG_DIR/agent.conf"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$LOG_DIR"

log "Config written to $CFG_DIR/agent.conf"

# ── systemd service ──────────────────────────────────────────
hdr "Installing systemd service: ${SERVICE}"

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=VaultHound Agent — Scan. Detect. Protect.
Documentation=https://github.com/krishnabagal/VaultHound
After=network.target network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}

# Config-driven — all settings in /etc/vaulthound/agent.conf
ExecStart=${AGENT_BIN}
ExecReload=/bin/kill -HUP \$MAINPID

Restart=on-failure
RestartSec=10
StartLimitIntervalSec=120
StartLimitBurst=5

# Logging
StandardOutput=append:${LOG_DIR}/agent.log
StandardError=append:${LOG_DIR}/agent.error.log

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ReadWritePaths=${LOG_DIR} ${CFG_DIR}

[Install]
WantedBy=multi-user.target
EOF

# Add docker group access if docker is installed
if command -v docker &>/dev/null; then
    if getent group docker &>/dev/null; then
        usermod -aG docker "$SERVICE_USER"
        log "Added $SERVICE_USER to docker group"
    fi
fi

# ── Enable & start ───────────────────────────────────────────
hdr "Enabling and starting service"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl start  "$SERVICE"
sleep 2

if systemctl is-active --quiet "$SERVICE"; then
    log "Service ${SERVICE} is running"
else
    warn "Service did not start. Check:"
    warn "  journalctl -u ${SERVICE} -n 50"
fi

# ── Clean up build artifacts ─────────────────────────────────
rm -rf "$BUILD_DIR" /tmp/go-pkg /tmp/go-cache

# ── Verify connectivity to master ────────────────────────────
hdr "Testing connection to master"
if curl -sf --max-time 5 "${MASTER_URL}/api/health" > /dev/null 2>&1; then
    log "Master reachable at ${MASTER_URL}"
else
    warn "Cannot reach master at ${MASTER_URL} — check network/firewall"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║          VaultHound Agent — Installation Complete        ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Binary     : ${CYAN}${AGENT_BIN}${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Config     : ${YELLOW}${CFG_DIR}/agent.conf${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Logs       : ${YELLOW}${LOG_DIR}/agent.log${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Master     : ${CYAN}${MASTER_URL}${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Daemon     : ${YELLOW}${DAEMON}${NC} (interval: ${SCAN_INTERVAL}m)"
echo -e "${GREEN}${BOLD}║${NC}  Service    : ${YELLOW}systemctl {start|stop|status} ${SERVICE}${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  One-shot scan examples:${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}vaulthound-agent --dir /var/www/html${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}vaulthound-agent --image nginx:latest${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ${CYAN}vaulthound-agent --repo https://github.com/org/repo${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Edit scan targets:${NC} $CFG_DIR/agent.conf"
echo -e "${YELLOW}Restart agent:${NC}     systemctl restart ${SERVICE}"
