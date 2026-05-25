#!/usr/bin/env bash
set -euo pipefail

# Hermes Agent bootstrap (Ubuntu 22.04/24.04)
# - no secrets in this script
# - harden SSH: key-only, no root login, Tailscale-only ingress
# - install Hermes Agent for a normal owner user
#
# Intended to be run via curl from a public repo.
# It downloads companion scripts from ONBOARD_RAW_BASE.

export DEBIAN_FRONTEND=noninteractive

OWNER_USER=${OWNER_USER:-hermes}
OWNER_PUBKEY=${OWNER_PUBKEY:-}  # optional: public key for owner access
ONBOARD_RAW_BASE=${ONBOARD_RAW_BASE:-"https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main"}

HERMES_OPT=/opt/hermes
LOG_FILE=/var/log/hermes-bootstrap.log

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
  exit 2
fi

log "updating packages"
apt-get update -y
apt-get upgrade -y

log "installing baseline deps"
apt-get install -y \
  git ca-certificates curl gnupg \
  ufw fail2ban \
  python3 python3-pip python3-venv \
  jq openssh-server

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

log "configuring passwordless sudo for $OWNER_USER"
SUDOERS_FILE="/etc/sudoers.d/90-${OWNER_USER}-nopasswd"
echo "${OWNER_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"

log "creating Hermes dirs with strict perms"
install -d -m 755 "$HERMES_OPT"
install -d -m 755 "$HERMES_OPT/bin"
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" "$HERMES_OPT/secret"
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" "/home/$OWNER_USER/.hermes"
printf '%s\n' "$OWNER_USER" > "$HERMES_OPT/OWNER"
chmod 644 "$HERMES_OPT/OWNER"

log "setting up SSH authorized_keys for $OWNER_USER"
install -d -m 700 -o "$OWNER_USER" -g "$OWNER_USER" "/home/$OWNER_USER/.ssh"
AK="/home/$OWNER_USER/.ssh/authorized_keys"
TMP_AK="$(mktemp)"

# Build a clean, deduplicated authorized_keys file atomically.
# Priority:
#  1) OWNER_PUBKEY env override (if provided)
#  2) /root/.ssh/authorized_keys (common on cloud images)
#  3) existing owner authorized_keys (preserve prior access)
if [[ -n "${OWNER_PUBKEY:-}" ]]; then
  printf '%s bootstrap\n' "${OWNER_PUBKEY//$'\r'/}" >> "$TMP_AK"
fi

for SRC in /root/.ssh/authorized_keys "$AK"; do
  if [[ -f "$SRC" ]]; then
    sed -e 's/\r$//' "$SRC" \
      | awk 'NF && $1 !~ /^#/ {print}' \
      >> "$TMP_AK"
  fi
done

awk '!seen[$0]++' "$TMP_AK" > "${TMP_AK}.dedup"
mv "${TMP_AK}.dedup" "$TMP_AK"

if [[ ! -s "$TMP_AK" ]]; then
  log "ERROR: no SSH public keys found. Provide OWNER_PUBKEY or ensure /root/.ssh/authorized_keys exists."
  rm -f "$TMP_AK"
  exit 5
fi

install -m 600 -o "$OWNER_USER" -g "$OWNER_USER" "$TMP_AK" "$AK"
KEY_COUNT="$(awk 'NF' "$AK" | wc -l | tr -d ' ')"
log "authorized_keys ready for $OWNER_USER: $KEY_COUNT key(s) at $AK"
rm -f "$TMP_AK"

log "hardening sshd (disable root login + passwords)"
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hermes-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF

/usr/sbin/sshd -t
systemctl reload ssh || systemctl reload sshd || systemctl restart ssh || systemctl restart sshd

log "configuring UFW (tailscale-only ssh)"
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
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

log "installing Hermes Agent for $OWNER_USER"
sudo -u "$OWNER_USER" -H bash -lc 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash'

if ! sudo -u "$OWNER_USER" -H bash -lc 'export PATH="$HOME/.local/bin:$PATH"; command -v hermes >/dev/null 2>&1'; then
  log "ERROR: hermes CLI not found after install"
  log "Try: sudo -u $OWNER_USER -H bash -lc 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash'"
  exit 4
fi

log "installing helper scripts"
curl -fsSL "$ONBOARD_RAW_BASE/bin/hermes-onboard" -o "$HERMES_OPT/bin/hermes-onboard"
curl -fsSL "$ONBOARD_RAW_BASE/bin/hermes-update" -o "$HERMES_OPT/bin/hermes-update"
chmod +x "$HERMES_OPT/bin/hermes-onboard" "$HERMES_OPT/bin/hermes-update"

log "bootstrap complete"
log "IMPORTANT: run 'tailscale up' before ending this SSH session."
log "Tailscale IP (once joined): $(tailscale ip -4 2>/dev/null || true)"
log "Next: ssh $OWNER_USER@<tailscale-ip> and run /opt/hermes/bin/hermes-onboard"
