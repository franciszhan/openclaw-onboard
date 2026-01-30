#!/usr/bin/env bash
set -euo pipefail

# OpenClaw bootstrap (Ubuntu 22.04)
# - no secrets
# - harden SSH (Tailscale-only + key-only)
# - install OpenClaw from GitHub source
#
# This script is intended to be run via curl from a public repo.
# It will download the companion scripts (openclaw-onboard, openclaw-update, tg_tools.py)
# from the same repo via ONBOARD_RAW_BASE.

export DEBIAN_FRONTEND=noninteractive

OWNER_USER=${OWNER_USER:-openclaw}
OWNER_PUBKEY=${OWNER_PUBKEY:-}  # optional: temporary key for initial access
# How to install OpenClaw:
# - "npm" (recommended): install global CLI and run as a daemon via systemd
# - "source": clone and build (more fragile; requires pnpm)
OPENCLAW_INSTALL=${OPENCLAW_INSTALL:-npm}
OPENCLAW_REPO=${OPENCLAW_REPO:-https://github.com/openclaw/openclaw}
OPENCLAW_BRANCH=${OPENCLAW_BRANCH:-main}

# Raw base for *this* onboarding repo (required when running via curl):
# e.g. https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main
ONBOARD_RAW_BASE=${ONBOARD_RAW_BASE:-""}

LOG_FILE=/var/log/openclaw-bootstrap.log
log() { echo "[bootstrap] $*" | tee -a "$LOG_FILE"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

touch "$LOG_FILE"
chmod 600 "$LOG_FILE" || true
log "starting (log: $LOG_FILE)"

if [[ -z "$ONBOARD_RAW_BASE" ]]; then
  log "ERROR: ONBOARD_RAW_BASE is required."
  log "Example:"
  log "  ONBOARD_RAW_BASE=https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main"
  exit 2
fi

log "updating packages"
apt-get update -y
apt-get upgrade -y

log "installing baseline deps"
apt-get install -y \
  git ca-certificates curl gnupg \
  ufw fail2ban \
  python3 python3-pip \
  jq

# Node.js: prefer nodesource (already used in many setups)
if ! command -v node >/dev/null 2>&1; then
  log "installing nodejs (nodesource 24.x)"
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi

log "installing python deps for telethon tooling"
python3 -m pip install --upgrade pip
python3 -m pip install telethon python-dotenv

log "installing tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
if ! command -v tailscale >/dev/null 2>&1; then
  log "ERROR: tailscale still not found after install"
  exit 3
fi

log "creating owner user: $OWNER_USER"
if ! id "$OWNER_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$OWNER_USER"
  usermod -aG sudo "$OWNER_USER"
fi

log "setting up SSH authorized_keys for $OWNER_USER (optional)"
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" "/home/$OWNER_USER/.ssh"
AK="/home/$OWNER_USER/.ssh/authorized_keys"
if [[ -n "$OWNER_PUBKEY" ]]; then
  echo "$OWNER_PUBKEY bootstrap" >> "$AK"
  chown "$OWNER_USER:$OWNER_USER" "$AK"
  chmod 600 "$AK"
fi

log "hardening sshd (disable root login + passwords)"
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-openclaw-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF

/usr/sbin/sshd -t
systemctl reload ssh || systemctl reload sshd || systemctl restart ssh || systemctl restart sshd

log "configuring UFW (tailscale-only ssh)"
# ensure sysctl is discoverable for ufw
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
mkdir -p /opt/openclaw
/usr/sbin/ufw --force reset
/usr/sbin/ufw default deny incoming
/usr/sbin/ufw default allow outgoing
/usr/sbin/ufw allow in on lo
/usr/sbin/ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH via Tailscale only'
/usr/sbin/ufw --force enable

log "enabling fail2ban"
install -d -m 755 /etc/fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban

log "installing OpenClaw ($OPENCLAW_INSTALL)"
install -d -m 755 /opt/openclaw

if [[ "$OPENCLAW_INSTALL" == "npm" ]]; then
  # Stable + easiest. Owner can switch channels later via `openclaw update --channel dev|beta|stable`.
  npm install -g openclaw@latest
  command -v openclaw >/dev/null 2>&1 || { log "ERROR: openclaw CLI not found after npm install"; exit 4; }
  # Don't run the wizard here; leave secrets and pairing to the owner.
else
  log "Installing from source repo: $OPENCLAW_REPO ($OPENCLAW_BRANCH)"
  # Source installs are more fragile; prefer pnpm.
  npm install -g pnpm
  rm -rf /opt/openclaw/app
  git clone --branch "$OPENCLAW_BRANCH" "$OPENCLAW_REPO" /opt/openclaw/app
  cd /opt/openclaw/app
  pnpm install
  pnpm build
fi

log "installing service + helper scripts"
install -d -m 755 /opt/openclaw/bin
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" /opt/openclaw/secret

curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/openclaw-onboard" -o /opt/openclaw/bin/openclaw-onboard
curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/openclaw-update" -o /opt/openclaw/bin/openclaw-update
curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/tg_tools.py" -o /opt/openclaw/bin/tg_tools.py
chmod +x /opt/openclaw/bin/openclaw-onboard /opt/openclaw/bin/openclaw-update /opt/openclaw/bin/tg_tools.py

# systemd unit (always fetched)
curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/systemd/openclaw.service" -o /etc/systemd/system/openclaw.service

systemctl daemon-reload
systemctl enable --now openclaw

log "bootstrap complete"
log "Tailscale IP (once joined): $(tailscale ip -4 2>/dev/null || true)"
log "Next (owner): sudo /opt/openclaw/bin/openclaw-onboard"
