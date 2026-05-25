# openclaw-onboard

Bootstrap scripts to turn a fresh Ubuntu VPS into a **Tailscale-only SSH** box with **Hermes Agent installed** and ready to connect to a Telegram bot.

This repo is intentionally minimal:
- harden a fresh server: sudo user, key-only SSH, no root login, UFW, fail2ban
- make SSH reachable only over Tailscale
- install Hermes for the owner user
- run Hermes setup + Telegram gateway setup interactively

No handoff ceremony, no Telethon, no extra services beyond what Hermes installs.

## Prerequisites

Have these ready before starting:

- A fresh Ubuntu VPS with root SSH access
- Your SSH public key already installed on root, or pass `OWNER_PUBKEY`
- Tailscale login access for the server
- Telegram Bot token from @BotFather
- Model auth for Hermes, e.g. OpenRouter/Anthropic/OpenAI/Gemini API key or OAuth provider

## Phase 1: bootstrap the VPS as root

SSH into the fresh server:

```bash
ssh root@<server-public-ip>
```

Run bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main/bootstrap.sh | sudo -E bash
```

Optional knobs:

```bash
# default owner user is hermes
curl -fsSL https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main/bootstrap.sh | sudo env OWNER_USER=francis bash

# if the cloud image does not already have your key in /root/.ssh/authorized_keys
curl -fsSL https://raw.githubusercontent.com/franciszhan/openclaw-onboard/main/bootstrap.sh | sudo env OWNER_PUBKEY='ssh-ed25519 AAAA...' bash
```

What bootstrap does:

- `apt update && apt upgrade`
- installs baseline tools: `git`, `curl`, `jq`, Python, `ufw`, `fail2ban`, Tailscale
- creates the owner user, default: `hermes`
- gives that user passwordless sudo for setup/maintenance
- copies root SSH keys, plus optional `OWNER_PUBKEY`, into the owner user
- disables root SSH login and password/KbdInteractive auth
- configures UFW to allow SSH **only on `tailscale0`**
- enables fail2ban for sshd
- creates strict-permission state dirs:
  - `/opt/hermes/secret` (`700`)
  - `/home/<owner>/.hermes` (`700`)
- installs Hermes Agent for the owner user via the official installer
- installs two helper scripts:
  - `/opt/hermes/bin/hermes-onboard`
  - `/opt/hermes/bin/hermes-update`

## Critical: bring Tailscale up before disconnecting

After bootstrap completes, join Tailscale while your current root SSH session is still open:

```bash
tailscale up
tailscale ip -4
```

Once UFW is active, public-network SSH is blocked. If you disconnect before Tailscale is joined, you can lock yourself out.

Then test a second SSH session over Tailscale:

```bash
ssh hermes@<tailscale-ip>
```

If you used a custom `OWNER_USER`, replace `hermes` with that username.

## Phase 2: configure Hermes + Telegram bot

SSH in as the owner user over Tailscale:

```bash
ssh hermes@<tailscale-ip>
```

Run the interactive setup helper:

```bash
/opt/hermes/bin/hermes-onboard
```

The helper runs, in order:

```bash
hermes setup
hermes gateway setup
hermes gateway install
hermes gateway start
hermes gateway status
```

Use `hermes setup` to configure model/provider auth. Use `hermes gateway setup` to add Telegram with your BotFather token.

## Pair the Telegram bot

Message your Telegram bot first. Hermes should reply with a pairing code.

Approve it on the server:

```bash
hermes pairing approve telegram <code>
```

Then test the bot in Telegram.

## Updating Hermes

```bash
sudo /opt/hermes/bin/hermes-update
```

This runs `hermes update` as the owner user, then restarts the Hermes gateway service if present.

## Useful commands

```bash
hermes doctor
hermes status --all
hermes gateway status
hermes gateway restart
journalctl --user -u hermes-gateway -n 100 --no-pager
```

If the gateway stops when you log out, enable linger:

```bash
sudo loginctl enable-linger "$USER"
hermes gateway restart
```

## Security posture

- SSH is **Tailscale-only**: UFW allows `22/tcp` only on `tailscale0`.
- Root SSH login is disabled.
- Password SSH auth is disabled; public key only.
- fail2ban protects sshd.
- Hermes state lives in `/home/<owner>/.hermes` with strict owner permissions.
- Operator secrets can live in `/opt/hermes/secret` with `700` dir / `600` file perms.
- Keep Hermes gateway/admin UIs local or Tailscale-only unless you know exactly what you’re exposing.
