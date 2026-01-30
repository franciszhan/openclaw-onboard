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
OPENCLAW_REPO=${OPENCLAW_REPO:-https://github.com/openclaw/openclaw}
OPENCLAW_BRANCH=${OPENCLAW_BRANCH:-main}
# Raw base for *this* onboarding repo (set to your published GitHub repo):
# e.g. https://raw.githubusercontent.com/frannzhan/openclaw-onboard/main
ONBOARD_RAW_BASE=${ONBOARD_RAW_BASE:-""}

log() { echo "[bootstrap] $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

log "updating packages"
apt-get update -y
apt-get upgrade -y

log "installing baseline deps"
apt-get install -y \
  git ca-certificates curl \
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

log "installing OpenClaw from source: $OPENCLAW_REPO ($OPENCLAW_BRANCH)"
install -d -m 755 /opt/openclaw
if [[ ! -d /opt/openclaw/app/.git ]]; then
  rm -rf /opt/openclaw/app
  git clone --branch "$OPENCLAW_BRANCH" "$OPENCLAW_REPO" /opt/openclaw/app
else
  (cd /opt/openclaw/app && git fetch --all --prune && git checkout "$OPENCLAW_BRANCH" && git pull --ff-only)
fi

cd /opt/openclaw/app
npm ci
npm run build || true

log "installing service + helper scripts"
install -d -m 755 /opt/openclaw/bin
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" /opt/openclaw/secret

if [[ -z "$ONBOARD_RAW_BASE" ]]; then
  log "WARNING: ONBOARD_RAW_BASE is empty."
  log "Set it to your onboarding repo raw URL so this script can fetch helper scripts, e.g.:"
  log "  ONBOARD_RAW_BASE=https://raw.githubusercontent.com/<org>/<repo>/main"
else
  curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/openclaw-onboard" -o /opt/openclaw/bin/openclaw-onboard
  curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/openclaw-update" -o /opt/openclaw/bin/openclaw-update
  curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/bin/tg_tools.py" -o /opt/openclaw/bin/tg_tools.py
  chmod +x /opt/openclaw/bin/openclaw-onboard /opt/openclaw/bin/openclaw-update /opt/openclaw/bin/tg_tools.py
fi

# systemd unit (fetched from repo if possible)
if [[ -n "$ONBOARD_RAW_BASE" ]]; then
  curl -fsSL "$ONBOARD_RAW_BASE/openclaw-onboard/systemd/openclaw.service" -o /etc/systemd/system/openclaw.service
else
  cat > /etc/systemd/system/openclaw.service <<'EOF'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/opt/openclaw/app
Environment=NODE_ENV=production
EnvironmentFile=-/opt/openclaw/secret/openclaw.env
ExecStart=/usr/bin/node /opt/openclaw/app/dist/index.js gateway run --bind loopback
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/openclaw /var/log

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now openclaw

log "bootstrap complete"
log "Tailscale IP (once joined): $(tailscale ip -4 2>/dev/null || true)"
log "Next (owner): sudo /opt/openclaw/bin/openclaw-onboard"
