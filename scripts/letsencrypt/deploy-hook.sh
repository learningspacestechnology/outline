#!/usr/bin/env bash
#
# Certbot deploy hook — runs only after a successful issue/renew.
# Certbot provides RENEWED_LINEAGE (path to /etc/letsencrypt/live/<domain>).
#
# Installs fullchain.pem + privkey.pem into the project's ./certs directory
# (volume-mounted into the nginx container) and reloads nginx.
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

# Per-host (auto-detected from hostname so one docker.env can serve prod+dev boxes):
: "${CERT_NAME:=$(_le_get_var CERT_NAME)}"
: "${CERT_NAME:=$(hostname -s)}"
: "${CERT_DIR:=$(_le_get_var CERT_DIR)}"
: "${CERT_DIR:=$(cd "$DIR/../.." && pwd)/certs}"

: "${NGINX_CONTAINER:=$(_le_get_var NGINX_CONTAINER)}"
: "${NGINX_CONTAINER:=nginx}"

install -m 0644 "${RENEWED_LINEAGE}/fullchain.pem" "${CERT_DIR}/${CERT_NAME}.crt"
install -m 0600 "${RENEWED_LINEAGE}/privkey.pem"   "${CERT_DIR}/${CERT_NAME}.key"
echo "[deploy-hook] installed ${CERT_NAME}.crt/.key into ${CERT_DIR}"

if docker ps --format '{{.Names}}' | grep -qx "${NGINX_CONTAINER}"; then
  docker exec "${NGINX_CONTAINER}" nginx -s reload
  echo "[deploy-hook] reloaded container '${NGINX_CONTAINER}'"
else
  echo "[deploy-hook] WARNING: container '${NGINX_CONTAINER}' not running; cert copied but nginx NOT reloaded." >&2
fi
