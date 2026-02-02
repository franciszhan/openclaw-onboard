# openclaw-onboard

Bootstrap scripts to turn a fresh Ubuntu VPS into a **Tailscale-only SSH** box with **OpenClaw installed**, plus a minimal, safe handoff flow.

This repo is optimized for:
- you spin up the server + run one bootstrap
- the new owner runs one command to optionally enable Telethon and remove your temporary access
- the new owner runs the official `openclaw onboard --install-daemon` wizard (best UX for models/OAuth)


## Prerequisites (before you start)
Have these ready:
- **Telegram Bot token** from @BotFather (for the owner)
- **Model auth** ready (API key or OAuth), since the OpenClaw wizard will prompt
- Ability to join Tailscale on the server (either your tailnet temporarily or the owner’s)


## Phase 1 (you / operator): bootstrap the VPS

1) SSH in as root (fresh Hetzner images usually start with your SSH pubkey on `root`):

```bash
ssh root@<server-public-ip>
```

2) Run bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main/bootstrap.sh | sudo -E bash
```

What bootstrap does:
- apt update/upgrade
- installs: `tailscale`, `ufw`, `fail2ban`, Node.js, OpenClaw CLI
- creates the `openclaw` user
- configures **key-only SSH** and **disables root SSH login**
- configures UFW to allow SSH **only on `tailscale0`**
- copies `/root/.ssh/authorized_keys` → `/home/openclaw/.ssh/authorized_keys` (lines marked with `bootstrap`) so you can SSH as `openclaw`
- prepares OpenClaw directories:
  - `/opt/openclaw/secret` (700)
  - `/home/openclaw/.openclaw` (700)
- installs Telethon tooling into a venv at `/opt/openclaw/py` (to avoid system Python pip issues)

3) **Bring Tailscale up before you disconnect**.

Once UFW is set to allow SSH only on `tailscale0`, you must join Tailscale before ending your current SSH session, otherwise you can lock yourself out.

```bash
tailscale up
# confirm you got a tailnet IP
tailscale ip -4
```

4) Exit root session.


## Phase 2 (new owner): optional Telethon + lockout

1) SSH in as the `openclaw` user over Tailscale:

```bash
ssh openclaw@<tailscale-ip>
```

2) Run the handoff script:

```bash
sudo /opt/openclaw/bin/openclaw-onboard
```

This script:
- optionally enables **Telethon (user session)** for advanced Telegram read/search
- optionally removes `bootstrap` SSH keys from `/home/openclaw/.ssh/authorized_keys`


## Phase 3 (new owner): run the official OpenClaw wizard

Run this as `openclaw` (NOT via sudo):

```bash
openclaw onboard --install-daemon
```

Suggested wizard choices:
- use your preferred model/OAuth (Codex / Claude Opus, etc)
- keep defaults unless you know you need custom behavior


## Quickstart after wizard

1) Message your Telegram bot: send any first message.
2) Approve pairing:

```bash
openclaw pairing approve telegram <code>
```


## Updating OpenClaw

```bash
sudo /opt/openclaw/bin/openclaw-update
```


## Security notes / posture
- SSH is **Tailscale-only** (UFW allows `22/tcp` only on `tailscale0`).
- Root SSH login is disabled; key-only auth.
- Secrets live in `/opt/openclaw/secret` (dir 700, files 600).
- Telethon session (if enabled) is stored locally under `/opt/openclaw/secret/`.
- If you expose any OpenClaw UI through a reverse proxy, configure `gateway.trustedProxies` (otherwise keep the Gateway local-only).
