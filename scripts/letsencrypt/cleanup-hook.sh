#!/usr/bin/env bash
#
# Certbot manual cleanup hook — remove the challenge TXT added by auth-hook.
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
echo "[cleanup-hook] removing TXT ${TARGET}"

nsupdate -k "${TSIG_KEYFILE}" <<EOF
server ${NSUPDATE_SERVER}
zone ${ACME_ZONE}
update delete ${TARGET} 300 TXT
send
EOF
