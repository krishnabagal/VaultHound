<div align="center">
<img src="https://img.shields.io/badge/VaultHound-Vulnerability%20Scanning%20Platform-ff9900?style=for-the-badge&logo=amazonaws&logoColor=white"/> <p>
<br>
<img src="/images/VaultHound-logo.png" width="100">

# VaultHound

### *Scan. Detect. Protect.*

**A self-hosted, open-source vulnerability scanning platform** with a real-time dashboard, distributed agents, and token-authenticated reporting — all without any SaaS, cloud accounts, or third-party subscriptions.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Node.js](https://img.shields.io/badge/Node.js-20%2B-339933?style=flat-square&logo=node.js&logoColor=white)](https://nodejs.org)
[![Go](https://img.shields.io/badge/Go-1.21%2B-00ADD8?style=flat-square&logo=go&logoColor=white)](https://go.dev)
[![Trivy](https://img.shields.io/badge/Powered%20by-Trivy-1904DA?style=flat-square)](https://trivy.dev)
[![Self-Hosted](https://img.shields.io/badge/Self--Hosted-No%20SaaS-ff6b35?style=flat-square)]()

![VaultHound Dashboard](images/dashboard.png)

> **No cloud accounts. No SaaS subscriptions. No credentials shipped anywhere.**
> VaultHound runs on your own infrastructure — a master server collects findings from agents installed on any Linux machine, and displays everything in a single dark-theme dashboard.

</div>

---

## Why VaultHound?

Most vulnerability scanning solutions fall into one of two camps:

- **Enterprise SaaS tools** (Snyk, Wiz, Orca) — expensive, require cloud accounts, send your code/container data to third-party servers
- **Raw CLI tools** (Trivy, Grype) — powerful but no dashboard, no multi-machine aggregation, no historical tracking

**VaultHound fills the gap**: it wraps [Trivy](https://trivy.dev) in an intelligent Go agent, aggregates results from unlimited machines into a single master server, and presents everything in a polished dashboard — all on your own hardware, behind your own firewall.

> There is currently no open-source solution that combines a proper real-time dashboard with a proper distributed agent configuration and token-based authentication — so we built one.

---
## Who Should Use VaultHound

VaultHound is built for anyone who needs vulnerability visibility across their infrastructure **without giving access to a third party**.

| Profile | Why VaultHound fits |
|---------|-------------------|
| **DevOps / Platform Engineers** | Scan Docker images and Kubernetes workloads on a schedule; get a single pane of glass across all nodes |
| **Security Engineers** | Enforce continuous scanning for CVEs, exposed secrets, and misconfigurations without shipping code to SaaS vendors |
| **Startups & Small Teams** | Professional-grade scanning at zero licensing cost; runs on a $5/month VPS |
| **Regulated Industries** (Finance, Healthcare, Government) | All scan data stays on-premises — nothing leaves your network |
| **Developers** | Scan feature branches or local directories before merging; catches secrets before they hit production |
| **Homelab / Self-hosters** | Full control, single install script, no accounts required |
| **MSPs & Consultants** | Deploy one master per client environment; agents report back silently in the background |

> If you run Linux servers, write code, or manage containers — and you don't want to pay for Snyk, Wiz, or Orca — VaultHound is for you.

---
## Features

| Feature | Details |
|---------|---------|
| **Multi-target scanning** | Docker images, Git repositories, local filesystems — all from one agent |
| **Intelligent agent** | Auto-discovers running Docker containers; resolves container → image automatically |
| **Real-time dashboard** | Dark-theme UI with severity trends, top targets, recent activity, agent registry |
| **Token authentication** | Shared secret between master and all agents; 401 on invalid token |
| **Smart deduplication** | Re-scanning the same target overwrites the existing result — counts never inflate |
| **Multi-machine** | Deploy one master, unlimited agents across any Linux hosts |
| **Daemon mode** | Agents run on a configurable schedule (default: every 30 min) |
| **PDF export** | Download branded scan reports with full CVE tables, secrets, misconfigs |
| **Severity filtering** | Filter vulnerabilities by Critical / High / Medium / Low in the detail view |
| **Secret line numbers** | Secrets view shows exact file and line numbers for fast triage |
| **systemd services** | Both master and agent install as proper Linux services with auto-restart |
| **One-command install** | Single bash script installs everything from scratch, including Node.js and Go |

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                        YOUR INFRASTRUCTURE                         │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Master Server (any Linux host)           │   │
│  │                                                             │   │
│  │   ┌────────────────────────────────────────────────────┐    │   │
│  │   │         VaultHound Server  (Node.js / Express)     │    │   │
│  │   │         Listening on  0.0.0.0:4000                 │    │   │
│  │   │                                                    │    │   │
│  │   │  ┌──────────────┐   ┌────────────────────────┐     │    │   │
│  │   │  │  In-memory   │   │  Token Auth Middleware │     │    │   │
│  │   │  │  scan store  │   │  (Bearer token check)  │     │    │   │
│  │   │  │  (dedup key) │   │                        │     │    │   │
│  │   │  └──────────────┘   └────────────────────────┘     │    │   │
│  │   │                                                    │    │   │
│  │   │  GET  /              → Dashboard UI (index.html)   │    │   │
│  │   │  GET  /api/dashboard → Aggregated stats            │    │   │
│  │   │  POST /api/ingest    → Receive scan from agent     │    │   │
│  │   │  GET  /api/scans     → Scan history                │    │   │
│  │   │  GET  /api/agents    → Registered agents           │    │   │
│  │   └────────────────────────────────────────────────────┘    │   │
│  │                                                             │   │
│  │   Config: /etc/vaulthound/server.conf                       │   │
│  │   Service: vaulthound-server (systemd)                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              ▲  ▲  ▲                               │
│              HTTP POST /api/ingest  (Bearer token)                 │
│                              │  │  │                               │
│  ┌───────────────┐  ┌────────┴──┴──┴──────────┐  ┌──────────────┐  │
│  │  Agent        │  │  Agent                  │  │  Agent       │  │
│  │  prod-web-01  │  │  prod-db-01             │  │  dev-box-01  │  │
│  │               │  │                         │  │              │  │
│  │  vaulthound   │  │  vaulthound-agent       │  │  vaulthound  │  │
│  │  -agent (Go)  │  │  --auto (containers)    │  │  -agent      │  │
│  │  --dir /app   │  │                         │  │  --repo ...  │  │
│  │               │  │  Trivy ──▶ scan images |  |              |  |
│  │  Trivy        │  │                         │  │  Trivy       │  │
│  └───────────────┘  └─────────────────────────┘  └──────────────┘  │
│                                                                    │
│  Config: /etc/vaulthound/agent.conf                                │
│  Binary: /usr/bin/vaulthound-agent                                 │
│  Service: vaulthound-agent (systemd)                               │
└────────────────────────────────────────────────────────────────────┘
```

### Scan Flow

```
vaulthound-agent --dir /var/www/html
        │
        ▼
  Read /etc/vaulthound/agent.conf   (MASTER_URL, SERVER_TOKEN, ...)
        │
        ▼
  trivy filesystem --scanners vuln,secret,misconfig /var/www/html --format json
        │
        ▼
  Parse JSON → build ScanSummary (counts per severity)
        │
        ▼
  POST /api/ingest   Authorization: Bearer <SERVER_TOKEN>
  { agent, scanType, target, trivyReport, summary }
        │
        ▼
  Master: verify token → dedup check (agentId + scanType + target)
        │
        ├── same key exists → overwrite (counts don't inflate)
        └── new key → insert
        │
        ▼
  Dashboard auto-refreshes → shows updated findings
```

---

## Dashboard

![Dashboard Overview](images/overview.png)

The dashboard is a single self-contained HTML file served directly by the master server — no build step, no npm, no bundler.

| Panel | Description |
|-------|-------------|
| **Overview cards** | Total scans, active agents, critical/high/medium/low/secrets/misconfigs totals |
| **Severity trend** | 14-day line chart of findings by severity |
| **Breakdown bars** | Proportional severity bars across all scans |
| **Recent activity** | Latest scans from all agents with target, type, critical, high counts |
| **Top vulnerable targets** | Ranked by total findings |
| **Scan history** | Full scan list with type filter, sortable, with View and PDF export |
| **Agent registry** | All connected agents with hostname, OS, last seen, scan count |

### Scan Detail View

Click **View** on any scan to open the detail panel:

- Severity filter dropdown (All / Critical / High / Medium / Low)
- Vulnerabilities table: CVE ID, package, installed version, fixed version, severity, title
- Secrets table: rule ID, file, **line number**, category, severity
- Misconfigurations table: ID, type, title, severity, status
- **Export PDF** — branded report with logo, summary boxes, full data tables

---

## What Gets Scanned

| Target Type | Flag | Vulnerabilities | Secrets | Misconfigurations |
|-------------|------|:-:|:-:|:-:|
| Docker image | `--image nginx:latest` | ✅ | ✅ | ❌ |
| Git repository | `--repo https://github.com/org/repo` | ✅ | ✅ | ✅ |
| Local filesystem | `--dir /var/www/html` | ✅ | ✅ | ✅ |
| Auto (containers) | `--auto` | ✅ | ✅ | ❌ |

Trivy detects vulnerabilities in:
- **OS packages**: Alpine, Ubuntu, Debian, RHEL, CentOS, Amazon Linux
- **Language packages**: npm, pip, Maven, Gradle, Go modules, Cargo, RubyGems, NuGet, Composer

---

## Quick Start

### 1 — Master Server

```bash
git clone https://github.com/krishnabagal/VaultHound.git
cd VaultHound/vaulthound-server

sudo bash install-master.sh
```

The installer will:
- Install Node.js 20
- Deploy the server to `/opt/vaulthound/master/`
- Write config to `/etc/vaulthound/server.conf` with a generated token
- Start `vaulthound-server` as a systemd service
- Print the **SERVER_TOKEN** — save it for agent setup

Open the dashboard at `http://<your-server-ip>:4000`

### 2 — Agent (on each machine to scan)

```bash
cd VaultHound/vaulthound-agent

sudo bash install-agent.sh
```

The installer will ask for:
- Master server URL (e.g. `http://192.168.1.10:4000`)
- Server token (from master install output)
- Scan interval, auto-discover, daemon mode

Then it installs Trivy, compiles and installs the Go agent binary, and starts the `vaulthound-agent` service.

### 3 — Manual scans (no service)

```bash
# Scan a directory — exits when done
vaulthound-agent --dir /var/www/html

# Scan a Docker image
vaulthound-agent --image nginx:latest

# Scan a Git repository
vaulthound-agent --repo https://github.com/org/repo

# Auto-discover all running Docker containers
vaulthound-agent --auto

# Verbose output (full logs to stdout)
vaulthound-agent --dir /app --log

# Stay running as daemon
vaulthound-agent --auto --daemon --interval 15
```

---

## Configuration

### Master — `/etc/vaulthound/server.conf`

```ini
# Network
PORT=4000
HOST=0.0.0.0

# Security — agents must send this in Authorization: Bearer <token>
SERVER_TOKEN=a1b2c3d4e5f6...   # 48-char hex, generated at install

# Storage
STORE_TYPE=memory               # or 'file' for persistence across restarts
STORE_PATH=/var/lib/vaulthound/db.json
MAX_SCANS=500

# Logging
LOG_LEVEL=info
LOG_FILE=/var/log/vaulthound/server.log
```

### Agent — `/etc/vaulthound/agent.conf`

```ini
# Master connection
MASTER_URL=http://192.168.1.10:4000
SERVER_TOKEN=a1b2c3d4e5f6...    # must match server.conf

# Scan targets (uncomment as needed)
#SCAN_IMAGE=nginx:latest
#SCAN_REPO=https://github.com/org/repo
#SCAN_DIR=/var/www/html

# Auto-discover running Docker containers
AUTO_DISCOVER=true

# Scheduling
DAEMON=true
SCAN_INTERVAL=30                # minutes

# Logging
LOG_FILE=/var/log/vaulthound/agent.log
```

After any config change:
```bash
sudo systemctl restart vaulthound-server   # master
sudo systemctl restart vaulthound-agent    # agent
```

---

## Project Structure

```
VaultHound/
│
├── vaulthound-server/               ← Master server
│   ├── install-master.sh            ← One-command installer
│   └── source/
│       ├── server.js                ← Express entry point
│       ├── routes.js                ← API routes + token auth
│       ├── db.js                    ← In-memory store with 
│       └── package.json             ← Dependencies manifest
|
├── Dashboard/
│       └── index.html               ← Dashboard UI (self-contained)
│
├── vaulthound-agent/                ← Scanning agent
│   ├── install-agent.sh             ← One-command installer
│   ├── main.go                      ← Go agent source
│   └── go.mod
│
├── images/                          ← Screenshots for README
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

---

## Token Security

The `SERVER_TOKEN` is a shared secret:

- Generated with `openssl rand -hex 24` at master install time
- Stored in `/etc/vaulthound/server.conf` (mode 640, root:vaulthound)
- Stored in `/etc/vaulthound/agent.conf` (mode 640, root:vaulthound)
- Sent as `Authorization: Bearer <token>` on every `/api/ingest` call
- Agents with wrong/missing token receive `401 Unauthorized`

**Rotating the token:**
```bash
# Generate new token
NEW_TOKEN=$(openssl rand -hex 24)

# Update master
sudo sed -i "s/^SERVER_TOKEN=.*/SERVER_TOKEN=${NEW_TOKEN}/" /etc/vaulthound/server.conf
sudo systemctl restart vaulthound-server

# Update each agent
sudo sed -i "s/^SERVER_TOKEN=.*/SERVER_TOKEN=${NEW_TOKEN}/" /etc/vaulthound/agent.conf
sudo systemctl restart vaulthound-agent
```

---

## Service Management

```bash
# Master
sudo systemctl start   vaulthound-server
sudo systemctl stop    vaulthound-server
sudo systemctl restart vaulthound-server
sudo systemctl status  vaulthound-server
sudo journalctl -u vaulthound-server -f

# Agent
sudo systemctl start   vaulthound-agent
sudo systemctl stop    vaulthound-agent
sudo systemctl restart vaulthound-agent
sudo systemctl status  vaulthound-agent
sudo journalctl -u vaulthound-agent -f

# Logs
sudo tail -f /var/log/vaulthound/server.log
sudo tail -f /var/log/vaulthound/agent.log
```

---

## API Reference

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET`  | `/`              | None  | Dashboard UI |
| `GET`  | `/api/health`    | None  | Health check |
| `POST` | `/api/ingest`    | Token | Receive scan data from agent |
| `GET`  | `/api/dashboard` | None  | Aggregated overview stats |
| `GET`  | `/api/scans`     | None  | List all scans (filterable) |
| `GET`  | `/api/scans/:id` | None  | Single scan with full Trivy report |
| `GET`  | `/api/agents`    | None  | List registered agents |

### Ingest payload

```json
{
  "agent": {
    "agentId": "550e8400-e29b-41d4-a716-446655440000",
    "hostname": "prod-web-01",
    "os": "linux/amd64",
    "agentVersion": "1.0.0"
  },
  "scanType": "filesystem",
  "target": "/var/www/html",
  "trivyReport": { "Results": [ ... ] },
  "summary": {
    "criticalCount": 2,
    "highCount": 14,
    "mediumCount": 31,
    "lowCount": 8,
    "secretCount": 0,
    "misconfigCount": 3
  },
  "metadata": {
    "scannedAt": "2026-05-18T10:30:00Z"
  }
}
```

---

## Supported Platforms

| OS | Master | Agent |
|----|:------:|:-----:|
| Ubuntu 20.04 / 22.04 / 24.04 | ✅ | ✅ |
| Debian 11 / 12 | ✅ | ✅ |
| Amazon Linux 2 | ✅ | ✅ |
| Amazon Linux 2023 | ✅ | ✅ |
| RHEL / CentOS 8+ | ✅ | ✅ |
| Alpine Linux | ❌ | ✅ |

Agent architectures: `amd64`, `arm64`, `armv6`

---

## Uninstalling VaultHound

### Uninstall Master Server

```bash
# 1. Stop and disable the service
sudo systemctl stop vaulthound-server
sudo systemctl disable vaulthound-server

# 2. Remove the systemd unit file
sudo rm -f /etc/systemd/system/vaulthound-server.service
sudo systemctl daemon-reload
sudo systemctl reset-failed

# 3. Remove application files
sudo rm -rf /opt/vaulthound

# 4. Remove config and data
sudo rm -rf /etc/vaulthound
sudo rm -rf /var/lib/vaulthound
sudo rm -rf /var/log/vaulthound

# 5. Remove the service user
sudo userdel vaulthound 2>/dev/null || true

# 6. Close the firewall port (if opened)
# UFW:
sudo ufw delete allow 4000/tcp 2>/dev/null || true
# firewalld:
sudo firewall-cmd --permanent --remove-port=4000/tcp 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

```

### Uninstall Agent

```bash
# 1. Stop and disable the service
sudo systemctl stop vaulthound-agent
sudo systemctl disable vaulthound-agent

# 2. Remove the systemd unit file
sudo rm -f /etc/systemd/system/vaulthound-agent.service
sudo systemctl daemon-reload
sudo systemctl reset-failed

# 3. Remove the agent binary
sudo rm -f /usr/bin/vaulthound-agent

# 4. Remove config and identity files
sudo rm -rf /etc/vaulthound

# 5. Remove logs
sudo rm -rf /var/log/vaulthound

# 6. Remove the service user (if not already removed by master uninstall)
sudo userdel vaulthound 2>/dev/null || true

```

### Uninstall Trivy (optional)

```bash
# Debian / Ubuntu
sudo apt-get remove -y trivy
sudo rm -f /etc/apt/sources.list.d/trivy.list
sudo rm -f /usr/share/keyrings/trivy.gpg

# RHEL / CentOS / Amazon Linux
sudo dnf remove -y trivy 2>/dev/null || sudo yum remove -y trivy
sudo rm -f /etc/yum.repos.d/trivy.repo

# If installed via install script
sudo rm -f /usr/local/bin/trivy

```

### Remove Node.js (optional — only if installed by VaultHound)

```bash
# Only run this if Node.js was installed solely for VaultHound
# Debian / Ubuntu
sudo apt-get remove -y nodejs
sudo rm -f /etc/apt/sources.list.d/nodesource.list

# RHEL / CentOS / Amazon Linux
sudo dnf remove -y nodejs 2>/dev/null || sudo yum remove -y nodejs
```

---



- [ ] PostgreSQL / SQLite persistence backend
- [ ] Multi-user authentication for the dashboard
- [ ] Webhook notifications (Slack, Teams, PagerDuty) on new critical findings
- [ ] SBOM (Software Bill of Materials) export
- [ ] Kubernetes DaemonSet deployment for agent
- [ ] GitHub Actions integration for CI/CD scanning
- [ ] CVE suppression / ignore rules per target
- [ ] Historical trend comparison between scans

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m 'Add my feature'`
4. Push: `git push origin feature/my-feature`
5. Open a Pull Request

---

## Security

- The dashboard API has no authentication by design (it's intended to run on an internal network)
- The ingest endpoint (`/api/ingest`) is token-protected
- All config files are created with mode `640` (readable only by root and the `vaulthound` service user)
- The `vaulthound` service user has no shell, no home directory, and no sudo access
- Agents never store scan results locally — data flows directly to the master

If you find a security issue, please open a GitHub issue or contact the maintainer directly.

---

## License

[MIT License](LICENSE) — free to use, modify, and distribute.

---

<div align="center">

Built with 🧡 by [Krishna Bagal](https://github.com/krishnabagal)

*If VaultHound helps you find and fix vulnerabilities, give it a ⭐*

</div>
