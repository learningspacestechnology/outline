#!/usr/bin/env bash
#
# Wrapper around issue.sh that verifies the host is actually serving the new
# cert afterwards. Useful for unattended runs and as a one-shot post-firewall
# confirmation:
#
#   sudo ./scripts/letsencrypt/issue-and-verify.sh             # real
#   sudo ./scripts/letsencrypt/issue-and-verify.sh --staging   # staging
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/../../docker.env"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo (issue.sh needs root for certbot + the TSIG key)." >&2
  exit 1
fi

# ---- 1. issue.sh ---------------------------------------------------------
echo "=== issue.sh $* ==="
if ! "$DIR/issue.sh" "$@"; then
  rc=$?
  echo "issue.sh failed with exit ${rc}; skipping verification." >&2
  exit "$rc"
fi

# ---- 2. resolve ACME_DOMAIN (same loader the hooks use) ------------------
_le_env_suffix() {
  if [[ -n "${DEPLOY_ENV:-}" ]]; then printf '%s' "${DEPLOY_ENV^^}"; return; fi
  local v=""
  [[ -f "$ENV_FILE" ]] && v=$(grep -E "^DEPLOY_ENV=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^DEPLOY_ENV=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  if [[ -n "$v" ]]; then printf '%s' "${v^^}"; else
    local h; h=$(hostname -s 2>/dev/null || hostname)
    [[ "$h" == *-dev || "$h" == *-test ]] && printf 'TEST' || printf 'PROD'
  fi
}
_le_get_var() {
  [[ -f "$ENV_FILE" ]] || return
  local key=$1 val env
  env=$(_le_env_suffix)
  val=$(grep -E "^${key}_${env}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^${key}_${env}=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  [[ -n "$val" ]] || val=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^${key}=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  printf '%s' "$val"
}
: "${ACME_DOMAIN:=$(_le_get_var ACME_DOMAIN)}"
: "${ACME_DOMAIN:=$(hostname -s).is.ed.ac.uk}"

# ---- 3. verify -----------------------------------------------------------
# Give nginx a moment to settle after the deploy-hook's reload.
sleep 2

echo
echo "=== verification on ${ACME_DOMAIN}:443 ==="
out=$(echo | timeout 10 openssl s_client -connect "${ACME_DOMAIN}:443" \
       -servername "${ACME_DOMAIN}" 2>/dev/null \
       | openssl x509 -noout -issuer -subject -dates -ext subjectAltName 2>/dev/null || true)

if [[ -z "$out" ]]; then
  echo "FAIL: couldn't establish TLS to ${ACME_DOMAIN}:443 (firewall? nginx down?)" >&2
  exit 1
fi
echo "$out" | sed 's/^/  /'

# "Let's Encrypt" appears in both real and staging issuer strings.
if echo "$out" | grep -q "Let's Encrypt"; then
  echo
  echo "PASS: Let's Encrypt cert is being served on ${ACME_DOMAIN}."
else
  echo
  echo "WARN: cert installed but issuer is NOT Let's Encrypt." >&2
  echo "      Check that the deploy-hook reloaded nginx and that ./certs/${CERT_NAME:-...}.crt is the new file." >&2
  exit 1
fi
