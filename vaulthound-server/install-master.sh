#!/usr/bin/env bash
# ============================================================
#  VaultHound — Master Server Installer
#  Service name : vaulthound-server
#  Config dir   : /etc/vaulthound/
#  App dir      : /opt/vaulthound/master/
# ============================================================
set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
hdr()  { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━${NC}"; }

# ── Must run as root ─────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root:  sudo bash install-master.sh"

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}"
cat <<'BANNER'
 __   __            _ _     _  _                      _
 \ \ / /_ _ _  _| | |_  | || |___ _  _ _ _  __| |
  \ V / _` | || | |  _| | __ / _ \ || | ' \/ _` |
   \_/\__,_|\_,_|_|\__| |_||_\___/\_,_|_||_\__,_|
         MASTER SERVER INSTALLER  v1.0.0
BANNER
echo -e "${NC}"

# ── Config ───────────────────────────────────────────────────
APP_DIR="/opt/vaulthound/master"
DASHBOARD_DIR="/opt/vaulthound/dashboard"
CFG_DIR="/etc/vaulthound"
LOG_DIR="/var/log/vaulthound"
SERVICE="vaulthound-server"
SERVICE_USER="vaulthound"
NODE_MAJOR=20
DEFAULT_PORT=4000

# Generate a secure 48-char hex token
SERVER_TOKEN=$(openssl rand -hex 24)

# ── Detect OS ────────────────────────────────────────────────
hdr "Detecting OS"
if   [ -f /etc/debian_version ]; then PKG_MGR="apt";   DISTRO="debian"
elif [ -f /etc/redhat-release ];  then PKG_MGR="dnf";   DISTRO="rhel"
elif [ -f /etc/amazon-linux-release ] || grep -qi "Amazon Linux" /etc/os-release 2>/dev/null; then
     PKG_MGR="dnf"; DISTRO="amzn"
else err "Unsupported OS. Supported: Ubuntu/Debian, RHEL/CentOS, Amazon Linux"; fi
log "OS: $DISTRO  Package manager: $PKG_MGR"

# ── System packages ──────────────────────────────────────────
hdr "Installing system packages"
if [[ $PKG_MGR == "apt" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget gnupg2 ca-certificates lsb-release \
        git openssl ufw 2>/dev/null || true
else
    dnf install -y curl wget ca-certificates git openssl 2>/dev/null || \
    yum install -y curl wget ca-certificates git openssl 2>/dev/null || true
fi
log "System packages installed"

# ── Node.js ──────────────────────────────────────────────────
hdr "Installing Node.js ${NODE_MAJOR}"
if command -v node &>/dev/null; then
    CURRENT_NODE=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
    if [[ $CURRENT_NODE -ge $NODE_MAJOR ]]; then
        log "Node.js $(node --version) already installed — skipping"
    else
        warn "Node.js $CURRENT_NODE found, upgrading to $NODE_MAJOR…"
        INSTALL_NODE=1
    fi
else
    INSTALL_NODE=1
fi

if [[ ${INSTALL_NODE:-0} -eq 1 ]]; then
    if [[ $PKG_MGR == "apt" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
        apt-get install -y nodejs
    else
        curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash -
        dnf install -y nodejs || yum install -y nodejs
    fi
fi
log "Node.js $(node --version)  npm $(npm --version)"

# ── Service user ─────────────────────────────────────────────
hdr "Creating service user"
if id "$SERVICE_USER" &>/dev/null; then
    log "User '$SERVICE_USER' already exists"
else
    useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_USER"
    log "User '$SERVICE_USER' created"
fi

# ── App directory ────────────────────────────────────────────
hdr "Setting up application directory"
mkdir -p "$APP_DIR" "$LOG_DIR" "$CFG_DIR"

# Copy master server source files (expected under vaulthound-server/source/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/source"

if [[ -d "$SOURCE_DIR" ]]; then
    cp -r "$SOURCE_DIR"/. "$APP_DIR/"
    log "Copied server source files from $SOURCE_DIR"
else
    warn "Source directory not found at $SOURCE_DIR"
    warn "Creating minimal server files…"

    mkdir -p "$APP_DIR"

    cat > "$APP_DIR/package.json" <<'PKGJSON'
{
  "name": "vaulthound-master",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "body-parser": "^1.20.2",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "uuid": "^9.0.0"
  }
}
PKGJSON
    log "Created package.json"
fi

# ── Copy dashboard index.html ─────────────────────────────────
# Repo layout:
#   VaultHound/
#   ├── dashboard/index.html        ← source file
#   └── vaulthound-server/
#       └── install-master.sh      ← this script
#
# server.js serves from ../dashboard relative to APP_DIR,
# which resolves to /opt/vaulthound/dashboard/ — copy index.html there.

hdr "Installing dashboard"
mkdir -p "$DASHBOARD_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Try multiple candidate paths in order
DASHBOARD_SRC=""
for candidate in \
    "${REPO_ROOT}/dashboard/index.html" \
    "${SCRIPT_DIR}/../dashboard/index.html" \
    "${SCRIPT_DIR}/dashboard/index.html" \
    "./dashboard/index.html"; do
    if [[ -f "$candidate" ]]; then
        DASHBOARD_SRC="$(realpath "$candidate")"
        break
    fi
done

if [[ -n "$DASHBOARD_SRC" ]]; then
    cp "$DASHBOARD_SRC" "$DASHBOARD_DIR/index.html"
    log "Dashboard installed: $DASHBOARD_SRC → $DASHBOARD_DIR/index.html"
else
    warn "dashboard/index.html not found locally — downloading from GitHub…"
    if curl -fsSL \
        "https://raw.githubusercontent.com/krishnabagal/VaultHound/main/dashboard/index.html" \
        -o "$DASHBOARD_DIR/index.html" 2>/dev/null; then
        log "Dashboard downloaded from GitHub → $DASHBOARD_DIR/index.html"
    else
        warn "Could not download dashboard. Please copy index.html manually to $DASHBOARD_DIR/"
    fi
fi

# Install npm dependencies
cd "$APP_DIR"
npm install --production --silent
log "npm dependencies installed"

# ── Configuration file ───────────────────────────────────────
hdr "Writing configuration"

# Ask for port (default 4000)
read -rp "$(echo -e "${CYAN}Enter master server port [${DEFAULT_PORT}]: ${NC}")" USER_PORT
PORT="${USER_PORT:-$DEFAULT_PORT}"

cat > "$CFG_DIR/server.conf" <<EOF
# ============================================================
#  VaultHound Master Server Configuration
#  Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ============================================================

# ── Network ──────────────────────────────────────────────────
PORT=${PORT}
HOST=0.0.0.0

# ── Security ─────────────────────────────────────────────────
# Agents MUST include this token in the Authorization header:
#   Authorization: Bearer <SERVER_TOKEN>
# Keep this secret. Regenerate with: openssl rand -hex 24
SERVER_TOKEN=${SERVER_TOKEN}

# ── Storage ──────────────────────────────────────────────────
# 'memory' = in-process (resets on restart)
# 'file'   = persist to STORE_PATH as JSON
STORE_TYPE=memory
STORE_PATH=/var/lib/vaulthound/db.json
MAX_SCANS=500

# ── Logging ──────────────────────────────────────────────────
LOG_LEVEL=info
LOG_FILE=/var/log/vaulthound/server.log

# ── CORS ─────────────────────────────────────────────────────
# Comma-separated allowed origins, or * for all
CORS_ORIGINS=*
EOF

chmod 640 "$CFG_DIR/server.conf"
chown root:"$SERVICE_USER" "$CFG_DIR/server.conf"
log "Config written to $CFG_DIR/server.conf"

# ── Patch server.js to read config and enforce token auth ────
hdr "Patching server for token authentication"

cat > "$APP_DIR/config.js" <<'CONFIGJS'
/**
 * VaultHound Master — Config loader
 * Reads /etc/vaulthound/server.conf (KEY=VALUE pairs)
 */
const fs   = require('fs');
const path = require('path');

const CFG_FILE = process.env.VAULTHOUND_CONFIG || '/etc/vaulthound/server.conf';

function load() {
  const cfg = {
    PORT:         parseInt(process.env.PORT || '4000'),
    HOST:         process.env.HOST || '0.0.0.0',
    SERVER_TOKEN: process.env.SERVER_TOKEN || '',
    STORE_TYPE:   process.env.STORE_TYPE || 'memory',
    STORE_PATH:   process.env.STORE_PATH || '/var/lib/vaulthound/db.json',
    MAX_SCANS:    parseInt(process.env.MAX_SCANS || '500'),
    LOG_LEVEL:    process.env.LOG_LEVEL || 'info',
    CORS_ORIGINS: process.env.CORS_ORIGINS || '*',
  };

  if (fs.existsSync(CFG_FILE)) {
    const lines = fs.readFileSync(CFG_FILE, 'utf8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq < 0) continue;
      const key = trimmed.slice(0, eq).trim();
      const val = trimmed.slice(eq + 1).trim();
      if (key === 'PORT' || key === 'MAX_SCANS') cfg[key] = parseInt(val);
      else cfg[key] = val;
    }
  }
  return cfg;
}

module.exports = load();
CONFIGJS

# ── Inject token middleware into routes.js ───────────────────
cat > "$APP_DIR/auth.js" <<'AUTHJS'
/**
 * VaultHound — Token authentication middleware
 * Applies to POST /api/ingest only.
 */
const cfg = require('./config');

function requireToken(req, res, next) {
  if (!cfg.SERVER_TOKEN) return next(); // token not set → open (warn at startup)
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (token !== cfg.SERVER_TOKEN) {
    console.warn(`[AUTH] Rejected request from ${req.ip} — invalid token`);
    return res.status(401).json({ error: 'Unauthorized — invalid or missing token' });
  }
  next();
}

module.exports = { requireToken };
AUTHJS

log "Auth middleware created"

# ── systemd service ──────────────────────────────────────────
hdr "Installing systemd service: ${SERVICE}"

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=VaultHound Master Server — Scan. Detect. Protect.
Documentation=https://github.com/krishnabagal/VaultHound
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}

# Load config file as environment variables
EnvironmentFile=${CFG_DIR}/server.conf

ExecStart=/usr/bin/node ${APP_DIR}/server.js
ExecReload=/bin/kill -HUP \$MAINPID

Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Logging
StandardOutput=append:${LOG_DIR}/server.log
StandardError=append:${LOG_DIR}/server.error.log

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${LOG_DIR} /var/lib/vaulthound

[Install]
WantedBy=multi-user.target
EOF

# ── File permissions ─────────────────────────────────────────
log "Setting file permissions…"
# App files must be readable by the vaulthound service user
chown -R "$SERVICE_USER":"$SERVICE_USER" "$APP_DIR"
chmod -R 750 "$APP_DIR"
# node_modules and js files need to be readable (not just executable)
find "$APP_DIR" -type f -name "*.js" -exec chmod 640 {} \;
find "$APP_DIR" -type f -name "*.json" -exec chmod 640 {} \;
find "$APP_DIR" -type d -exec chmod 750 {} \;
# node_modules binaries need execute bit
find "$APP_DIR/node_modules/.bin" -type f -exec chmod 750 {} \; 2>/dev/null || true

chown -R "$SERVICE_USER":"$SERVICE_USER" "$LOG_DIR"
chmod 750 "$LOG_DIR"
mkdir -p /var/lib/vaulthound
chown "$SERVICE_USER":"$SERVICE_USER" /var/lib/vaulthound
chmod 750 /var/lib/vaulthound
log "Permissions set"

# ── Enable & start service ───────────────────────────────────
hdr "Enabling and starting service"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl start  "$SERVICE"
sleep 2

if systemctl is-active --quiet "$SERVICE"; then
    log "Service ${SERVICE} is running"
else
    warn "Service did not start cleanly. Check logs:"
    warn "  journalctl -u ${SERVICE} -n 50"
fi

# ── Firewall ─────────────────────────────────────────────────
hdr "Configuring firewall"
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" comment "VaultHound Master" >/dev/null
    log "UFW: port $PORT opened"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "firewalld: port $PORT opened"
else
    warn "No firewall detected — ensure port $PORT is accessible"
fi

# ── Summary ──────────────────────────────────────────────────
MASTER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         VaultHound Master — Installation Complete        ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Dashboard  : ${CYAN}http://${MASTER_IP}:${PORT}${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Agent URL  : ${CYAN}http://${MASTER_IP}:${PORT}/api/ingest${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Config     : ${YELLOW}${CFG_DIR}/server.conf${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Logs       : ${YELLOW}${LOG_DIR}/server.log${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Service    : ${YELLOW}systemctl {start|stop|status} ${SERVICE}${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}Agent Token (save this for agent setup):${NC}"
echo -e "${GREEN}${BOLD}║${NC}  ${YELLOW}${SERVER_TOKEN}${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
warn "Store the token securely — you will need it during agent installation."
