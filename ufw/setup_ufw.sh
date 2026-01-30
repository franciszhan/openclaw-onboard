#!/usr/bin/env bash
set -euo pipefail

# Tailscale-only inbound SSH; deny other inbound by default.

UFW_BIN=${UFW_BIN:-/usr/sbin/ufw}

if [[ ! -x "$UFW_BIN" ]]; then
  echo "ufw not found at $UFW_BIN" >&2
  exit 1
fi

$UFW_BIN --force reset
$UFW_BIN default deny incoming
$UFW_BIN default allow outgoing

# allow loopback
$UFW_BIN allow in on lo

# allow SSH only via tailscale
$UFW_BIN allow in on tailscale0 to any port 22 proto tcp comment 'SSH via Tailscale only'

$UFW_BIN --force enable
$UFW_BIN status verbose
