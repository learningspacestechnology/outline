#!/usr/bin/env bash
#
# One-time (and re-runnable) Let's Encrypt issuance for this host.
# Reads per-host config from the project's docker.env at the repo root.
#
#   ./issue.sh --staging   # test against LE staging (untrusted certs, no rate limit)
#   ./issue.sh             # real issuance
#
# Certbot saves the hooks into the renewal config, so subsequent renewals are
# handled automatically by certbot's systemd timer.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/../../docker.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "NOTE: ${ENV_FILE} not found -- relying on auto-detected defaults." >&2
fi

# Read only the vars we need from docker.env (rather than `source`, which trips
# over shell-special characters in values).
# Pick the deploy-env suffix (PROD/TEST) so vars like ACME_EMAIL_PROD /
# ACME_EMAIL_TEST resolve per-host. Explicit DEPLOY_ENV in env or docker.env
# wins; otherwise derived from hostname (-dev/-test -> TEST, else PROD).
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
: "${ACME_DOMAIN:=$(_le_get_var ACME_DOMAIN)}"
: "${ACME_DOMAIN:=$(hostname -s).is.ed.ac.uk}"
: "${CERT_NAME:=$(_le_get_var CERT_NAME)}"
: "${CERT_NAME:=$(hostname -s)}"
: "${CERT_DIR:=$(_le_get_var CERT_DIR)}"
: "${CERT_DIR:=$(cd "$DIR/../.." && pwd)/certs}"

# Fleet-wide (Edinburgh defaults; override in docker.env if a host ever differs):
: "${ACME_EMAIL:=$(_le_get_var ACME_EMAIL)}"
: "${ACME_ZONE:=$(_le_get_var ACME_ZONE)}"
: "${ACME_ZONE:=acme.www-dyn.ed.ac.uk}"
: "${NSUPDATE_SERVER:=$(_le_get_var NSUPDATE_SERVER)}"
: "${NSUPDATE_SERVER:=10.64.10.8}"
: "${TSIG_KEYFILE:=$(_le_get_var TSIG_KEYFILE)}"
: "${TSIG_KEYFILE:=$DIR/acme-key.key}"

# ---- preflight -----------------------------------------------------------
for v in ACME_DOMAIN CERT_NAME ACME_EMAIL CERT_DIR; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: ${v} is empty. Add it to ${ENV_FILE} or set in the environment." >&2
    exit 1
  fi
done
for bin in certbot nsupdate dig docker; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' not found (install certbot + dnsutils)." >&2; exit 1; }
done
[[ -r "$TSIG_KEYFILE" ]] || { echo "ERROR: TSIG key file '$TSIG_KEYFILE' not readable." >&2; exit 1; }
keyperms=$(stat -c '%a' "$TSIG_KEYFILE" 2>/dev/null || echo "?")
if [[ "$keyperms" != "600" && "$keyperms" != "400" ]]; then
  echo "WARNING: TSIG key '$TSIG_KEYFILE' perms are ${keyperms}; should be 600." >&2
fi
[[ -d "$CERT_DIR" ]] || { echo "ERROR: CERT_DIR '$CERT_DIR' does not exist." >&2; exit 1; }

# Warn early if CIS hasn't added the CNAME yet — issuance would fail otherwise.
if ! dig +short CNAME "_acme-challenge.${ACME_DOMAIN}" | grep -q "${ACME_ZONE}"; then
  echo "WARNING: _acme-challenge.${ACME_DOMAIN} does not CNAME into ${ACME_ZONE} yet." >&2
  echo "         The CIS request may still be pending. Continue? [y/N]" >&2
  read -r ans; [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

STAGING_FLAG=""
if [[ "${1:-}" == "--staging" || "${STAGING:-0}" == "1" ]]; then
  STAGING_FLAG="--staging"
  echo ">>> Using Let's Encrypt STAGING (certs will be untrusted; for testing only)."
fi

# ---- issue ---------------------------------------------------------------
certbot certonly \
  --non-interactive --agree-tos -m "${ACME_EMAIL}" \
  --preferred-challenges dns --manual \
  --manual-auth-hook    "${DIR}/auth-hook.sh" \
  --manual-cleanup-hook "${DIR}/cleanup-hook.sh" \
  --deploy-hook         "${DIR}/deploy-hook.sh" \
  -d "${ACME_DOMAIN}" \
  ${STAGING_FLAG}

echo
echo "Done. Verify renewal is wired up with:  certbot renew --dry-run"
