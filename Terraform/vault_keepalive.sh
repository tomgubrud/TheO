#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f ".vault_creds.env" ]]; then
  echo "ERROR: .vault_creds.env not found in current directory"
  exit 1
fi

# shellcheck disable=SC1091
source .vault_creds.env

if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_NAMESPACE:-}" || -z "${VAULT_TOKEN:-}" || -z "${LEASE_ID:-}" ]]; then
  echo "ERROR: Missing required values in .vault_creds.env"
  exit 1
fi

export VAULT_ADDR VAULT_NAMESPACE VAULT_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]"
  exit 1
fi

USER_CMD=("$@")

# --- Background keepalive ---
keepalive() {
  while true; do
    echo "[keepalive] Renewing Vault token..."
    if vault token renew >/dev/null 2>&1; then
      TTL=$(vault token lookup -format=json | jq -r '.data.ttl' || echo "unknown")
      echo "[keepalive] Token TTL remaining: ${TTL}s"
    else
      echo "[keepalive] ERROR: Vault token renew failed — token likely expired. Stopping."
      kill "$$"
      exit 1
    fi

    echo "[keepalive] Renewing lease $LEASE_ID..."
    if ! vault lease renew "$LEASE_ID" >/dev/null 2>&1; then
      echo "[keepalive] WARNING: Lease renew failed (may be expired or already revoked)"
    fi

    sleep 1800
  done
}

keepalive &
KEEPALIVE_PID=$!

cleanup() {
  echo "[keepalive] Stopping renewal loop (PID $KEEPALIVE_PID)"
  kill "$KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[keepalive] Starting command: ${USER_CMD[*]}"
"${USER_CMD[@]}"
