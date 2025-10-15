#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# vault_keepalive.sh (v2)
#
# Purpose
#   Run any long command (e.g., `aws s3 sync …`) while:
#     1) Automatically renewing your Vault TOKEN
#     2) Automatically renewing a Vault LEASE (e.g., aws/data/creds/*)
#     3) Emitting a lightweight heartbeat to keep DevSpaces alive
#
# Quick start
#   - Put your creds in a file (default: .vault_creds.env) with at least:
#       VAULT_ADDR="https://vault.example.com"
#       VAULT_NAMESPACE="nc-dev-data"    # or "" for root
#       VAULT_TOKEN="hvs.XXXX..."        # UI/devtools token
#       VAULT_LEASE_ID="aws/data/creds/admin/..."   # optional
#     (Optionally add CA bundle:  AWS_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt)
#
#   - Run:
#       ./vault_keepalive.sh aws s3 sync s3://src s3://dst --no-progress
#
# Env overrides (set in shell or in the env file)
#   VAULT_ENV_FILE=./.vault_creds.env      # path to env file to source (if present)
#   SESSION_KEEPALIVE=1                    # 1=print heartbeat; 0=disable
#   HEARTBEAT_SECS=240                     # heartbeat every N seconds
#
#   TOKEN_RENEW_AT=1200                    # renew token if TTL <= this many seconds
#   TOKEN_INCREMENT=3600                   # token renew increment in seconds
#
#   LEASE_RENEW_AT=1800                    # renew lease if TTL <= this many seconds
#   LEASE_INCREMENT=3600                   # lease renew increment in seconds
#
# Notes
#   - Requires the `vault` CLI in PATH.
#   - Does not require `jq`; parses small bits of JSON with grep.
#   - Prints terse status lines; detailed stderr from the child command is untouched.
# ------------------------------------------------------------------------------

# -------- config defaults ----------
VAULT_ENV_FILE="${VAULT_ENV_FILE:-.vault_creds.env}"

SESSION_KEEPALIVE="${SESSION_KEEPALIVE:-1}"
HEARTBEAT_SECS="${HEARTBEAT_SECS:-240}"

TOKEN_RENEW_AT="${TOKEN_RENEW_AT:-1200}"
TOKEN_INCREMENT="${TOKEN_INCREMENT:-3600}"

LEASE_RENEW_AT="${LEASE_RENEW_AT:-1800}"
LEASE_INCREMENT="${LEASE_INCREMENT:-3600}"

# -------- load env file if present ---
if [[ -f "$VAULT_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$VAULT_ENV_FILE"
fi

# -------- sanity checks --------------
command -v vault >/dev/null 2>&1 || { echo "[keepalive] ERROR: vault CLI not found in PATH" >&2; exit 127; }

: "${VAULT_ADDR:?Set VAULT_ADDR in $VAULT_ENV_FILE or env}"
export VAULT_ADDR

# VAULT_NAMESPACE can be blank (root). Export either way so `vault` sees it.
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"

# Token must be present to run lookup/renew. We don’t fetch it here.
: "${VAULT_TOKEN:?Set VAULT_TOKEN in $VAULT_ENV_FILE or env}"
export VAULT_TOKEN

VAULT_LEASE_ID="${VAULT_LEASE_ID:-${LEASE_ID:-}}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# -------- small helpers --------------
vault_token_ttl() {
  # returns TTL seconds for current token, or 0 on error
  # Try JSON: "ttl":1234
  local out ttl
  if ! out=$(vault token lookup -format=json 2>/dev/null); then
    echo 0; return
  fi
  ttl=$(grep -o '"ttl":[0-9]\+' <<<"$out" | grep -o '[0-9]\+' || true)
  echo "${ttl:-0}"
}

vault_token_renew() {
  # renew token by increment seconds
  local inc="${1:-$TOKEN_INCREMENT}"
  vault token renew -increment="${inc}s" >/dev/null 2>&1 || true
}

vault_lease_ttl() {
  # returns TTL seconds for lease id, or 0 on error
  local id="$1" out ttl
  if [[ -z "$id" ]]; then echo 0; return; fi
  if ! out=$(vault lease lookup -format=json "$id" 2>/dev/null); then
    echo 0; return
  fi
  ttl=$(grep -o '"ttl":[0-9]\+' <<<"$out" | grep -o '[0-9]\+' || true)
  echo "${ttl:-0}"
}

vault_lease_renew() {
  local id="$1" inc="${2:-$LEASE_INCREMENT}"
  [[ -z "$id" ]] && return 0
  vault lease renew -increment="${inc}s" "$id" >/dev/null 2>&1 || true
}

# -------- loops ----------------------
token_loop() {
  while :; do
    local ttl
    ttl="$(vault_token_ttl)"
    printf "[keepalive] %s Token TTL remaining: %ss\n" "$(timestamp)" "$ttl"
    if (( ttl <= TOKEN_RENEW_AT )); then
      printf "[keepalive] %s Renewing Vault token...\n" "$(timestamp)"
      vault_token_renew "$TOKEN_INCREMENT"
      # small pause so the next lookup sees the new TTL
      sleep 2
      ttl="$(vault_token_ttl)"
      printf "[keepalive] %s Token TTL after renew: %ss\n" "$(timestamp)" "$ttl"
    fi
    # Sleep a conservative chunk, but wake early if TTL is short
    local sleep_for=$(( ttl > 0 ? ( ttl > 600 ? 300 : ttl/2 ) : 60 ))
    (( sleep_for < 30 )) && sleep_for=30
    sleep "$sleep_for" || true
  done
}

lease_loop() {
  # Optional: only if VAULT_LEASE_ID is set
  local id="$VAULT_LEASE_ID"
  [[ -z "$id" ]] && return 0

  while :; do
    local ttl
    ttl="$(vault_lease_ttl "$id")"
    printf "[keepalive] %s Lease TTL remaining (%s): %ss\n" "$(timestamp)" "$id" "$ttl"
    if (( ttl <= LEASE_RENEW_AT )); then
      printf "[keepalive] %s Renewing lease %s...\n" "$(timestamp)" "$id"
      vault_lease_renew "$id" "$LEASE_INCREMENT"
      sleep 2
      ttl="$(vault_lease_ttl "$id")"
      printf "[keepalive] %s Lease TTL after renew: %ss\n" "$(timestamp)" "$ttl"
    fi
    local sleep_for=$(( ttl > 0 ? ( ttl > 600 ? 300 : ttl/2 ) : 60 ))
    (( sleep_for < 30 )) && sleep_for=30
    sleep "$sleep_for" || true
  done
}

heartbeat_loop() {
  # Keep DevSpaces terminal session alive with a single, infrequent line.
  local every="${HEARTBEAT_SECS}"
  (( every < 60 )) && every=60
  while :; do
    printf "[heartbeat] %s\n" "$(timestamp)"
    sleep "$every" || true
  done
}

# -------- run child command -----------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 2
fi

# Start loops
token_loop &  TOKEN_PID=$!
lease_loop &  LEASE_PID=$!
if [[ "${SESSION_KEEPALIVE}" -eq 1 ]]; then
  heartbeat_loop & HEART_PID=$!
else
  HEART_PID=""
fi

# Forward signals to the child process group and cleanup
cleanup() {
  printf "[keepalive] %s Stopping renewal loop%s\n" "$(timestamp)" "${HEART_PID:+ and heartbeat}"
  [[ -n "${TOKEN_PID:-}" ]] && kill "${TOKEN_PID}" 2>/dev/null || true
  [[ -n "${LEASE_PID:-}" ]] && kill "${LEASE_PID}" 2>/dev/null || true
  [[ -n "${HEART_PID:-}" ]] && kill "${HEART_PID}" 2>/dev/null || true
}
# On Ctrl-C/TERM, forward to child, then cleanup
forward_and_cleanup() {
  if [[ -n "${CHILD_PID:-}" ]]; then
    kill -TERM "-${CHILD_PID}" 2>/dev/null || true
  fi
  cleanup
}
trap forward_and_cleanup INT TERM
trap cleanup EXIT

# Run the requested command in its own process group
# so we can forward signals cleanly.
set +e
"$@" &
CHILD_PID=$!
set -e

# Wait for the child, capture exit
wait "$CHILD_PID"
EXIT_CODE=$?

# Normal cleanup (will also run via trap EXIT)
cleanup

exit "$EXIT_CODE"
