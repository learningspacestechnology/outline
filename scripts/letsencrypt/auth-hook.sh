#!/usr/bin/env bash
#
# Certbot manual auth hook — University of Edinburgh DNS-01 via RFC2136/TSIG.
#
# Certbot provides CERTBOT_DOMAIN and CERTBOT_VALIDATION. Per-host config
# (ACME_DOMAIN, CERT_NAME, ACME_EMAIL, CERT_DIR) lives in the project's
# docker.env at the repo root. Fleet-wide constants (ACME_ZONE,
# NSUPDATE_SERVER, TSIG_KEYFILE) default to the Edinburgh values and can be
# overridden in docker.env if a host ever needs to differ.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/../../docker.env"

# Read only the vars we need from docker.env (rather than `source`, which trips
# over shell-special characters in values).
# Pick the deploy-env suffix (PROD/TEST). Explicit DEPLOY_ENV in env or
# docker.env wins; otherwise derived from hostname (-dev/-test -> TEST, else PROD).
_le_env_suffix() {
  if [[ -n "${DEPLOY_ENV:-}" ]]; then printf '%s' "${DEPLOY_ENV^^}"; return; fi
  local v=""
  [[ -f "$ENV_FILE" ]] && v=$(grep -E "^DEPLOY_ENV=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^DEPLOY_ENV=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  if [[ -n "$v" ]]; then printf '%s' "${v^^}"; else
    local h; h=$(hostname -s 2>/dev/null || hostname)
    [[ "$h" == *-dev || "$h" == *-test ]] && printf 'TEST' || printf 'PROD'
  fi
}
# Read VAR from docker.env: try VAR_<ENV> first, fall back to plain VAR.
_le_get_var() {
  [[ -f "$ENV_FILE" ]] || return
  local key=$1 val env
  env=$(_le_env_suffix)
  val=$(grep -E "^${key}_${env}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^${key}_${env}=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  [[ -n "$val" ]] || val=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E "s/^${key}=//; s/\r$//; s/^['\"]//; s/['\"]$//")
  printf '%s' "$val"
}

: "${ACME_ZONE:=$(_le_get_var ACME_ZONE)}"
: "${ACME_ZONE:=acme.www-dyn.ed.ac.uk}"
: "${NSUPDATE_SERVER:=$(_le_get_var NSUPDATE_SERVER)}"
: "${NSUPDATE_SERVER:=10.64.10.8}"
: "${TSIG_KEYFILE:=$(_le_get_var TSIG_KEYFILE)}"
: "${TSIG_KEYFILE:=$DIR/acme-key.key}"

TARGET="_acme-challenge.${CERTBOT_DOMAIN}.${ACME_ZONE}"
echo "[auth-hook] updating TXT ${TARGET} via ${NSUPDATE_SERVER}"

nsupdate -k "${TSIG_KEYFILE}" <<EOF
server ${NSUPDATE_SERVER}
zone ${ACME_ZONE}
update delete ${TARGET} 300 TXT
update add    ${TARGET} 300 IN TXT "${CERTBOT_VALIDATION}"
send
EOF

echo "[auth-hook] waiting for propagation..."
for i in $(seq 1 "${PROPAGATION_TRIES:-24}"); do
  if dig +short TXT "_acme-challenge.${CERTBOT_DOMAIN}" | grep -q "${CERTBOT_VALIDATION}"; then
    echo "[auth-hook] confirmed after ~$((i * ${PROPAGATION_SLEEP:-5}))s"
    sleep "${PROPAGATION_BUFFER:-5}"
    exit 0
  fi
  sleep "${PROPAGATION_SLEEP:-5}"
done
echo "[auth-hook] WARNING: TXT not visible within timeout; continuing anyway." >&2
