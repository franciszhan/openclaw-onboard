# openclaw-onboard

Scripts + configs to bootstrap a fresh Ubuntu 22.04 VM into a secure, Tailscale-only SSH + OpenClaw install, with a clean handoff flow.

## Design goals
- **No secrets in bootstrap** (safe to run from cloud-init)
- **Tailscale-only SSH** + key-only auth
- Owner runs **one command** to finish onboarding (keys/APIs) and **lock you out**
- Install OpenClaw from **GitHub source**: https://github.com/openclaw/openclaw

## Phase 1 (you): bootstrap
On a fresh VM (as root):

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_GH_ORG>/<REPO>/main/bootstrap.sh | bash
```

Or (recommended) use Hetzner Cloud **user-data** (cloud-init) to run it automatically.

## Phase 2 (owner): onboard + lockout
After they can SSH in (via Tailscale):

```bash
sudo /opt/openclaw/bin/openclaw-onboard
```

This will:
- prompt for secrets (TG API, etc)
- run Telethon login interactively
- (optional) set up other integrations
- remove bootstrap SSH keys / temp access

## Updating OpenClaw
Manual update:

```bash
sudo /opt/openclaw/bin/openclaw-update
```

## Files
- `bootstrap.sh` → root-only installer + security baseline (no secrets)
- `handoff.sh` → owner-only interactive setup + lockout
- `systemd/openclaw.service` → OpenClaw as a service
- `ufw/` → firewall setup
- `fail2ban/` → sshd jail config

## Security notes
- Secrets live in `/opt/openclaw/secret` (`0700` dir, `0600` files)
- Telethon session stored in `/opt/openclaw/secret/telethon.session`
- SSH: `PermitRootLogin no`, `PasswordAuthentication no`, `AuthenticationMethods publickey`
- Firewall: allow inbound SSH only on `tailscale0`
