# Let's Encrypt certificates (DNS-01 / RFC2136 TSIG)

Publicly-trusted TLS for Outline (`lst.is.ed.ac.uk`), issued with **Let's
Encrypt** using **DNS-01** validation via the University's
`acme.www-dyn.ed.ac.uk` delegation: we hold a **TSIG key** authorised to update
that zone, and `nsupdate -k` writes the challenge TXT record. Adapted from the
`learningspacesdatastore` fleet setup.

DNS-01 means **no inbound 80/443 is needed for validation**.

## How it fits together

1. `certbot` runs **on the host** (not in a container) and performs DNS-01.
2. `auth-hook.sh` adds the `_acme-challenge` TXT via `nsupdate -k`; `cleanup-hook.sh`
   removes it afterwards.
3. `deploy-hook.sh` copies the issued `fullchain.pem`/`privkey.pem` into
   `../../certs/lst.crt` + `lst.key`, then runs `docker exec nginx nginx -s reload`.
4. The `nginx` container (see `docker-compose.yml`) volume-mounts `./certs`
   read-only at `/etc/nginx/certs` and terminates TLS, reverse-proxying to the
   `outline` container (with WebSocket upgrade support).

This **replaced the old `https-portal` container**, which self-managed certs via
HTTP-01 and could not use the University's DNS-01 delegation.

## DNS prerequisite (CIS / Unidesk ticket)

```
_acme-challenge.lst.is.ed.ac.uk  CNAME  _acme-challenge.lst.is.ed.ac.uk.acme.www-dyn.ed.ac.uk.
```

## Config

Per-host config is read from the project's **`docker.env`** at the repo root
(the same file Compose loads). Add:

```
ACME_DOMAIN=lst.is.ed.ac.uk
CERT_NAME=lst                 # cert files become certs/lst.crt + lst.key (match nginx-conf/default.conf)
ACME_EMAIL=<functional-mailbox>@ed.ac.uk
CERT_DIR=/absolute/path/to/this/repo/certs
```

Fleet-wide constants default to the Edinburgh values and only need overriding in
`docker.env` if a host differs:
`ACME_ZONE` (= `acme.www-dyn.ed.ac.uk`), `NSUPDATE_SERVER` (= `10.64.10.8`),
`TSIG_KEYFILE` (= `scripts/letsencrypt/acme-key.key`), `NGINX_CONTAINER` (= `nginx`).

## Per-box setup

```bash
# 1. Tools
sudo apt-get install -y certbot dnsutils

# 2. Drop the TSIG key into this dir (gitignored via *.key)
sudo install -m 600 acme-key.key scripts/letsencrypt/acme-key.key

# 3. Add the ACME_/CERT_ vars above to docker.env, and create ./certs
mkdir -p certs
chmod +x scripts/letsencrypt/*.sh

# 4. Test against staging first (proves the TSIG hook works end-to-end)
sudo ./scripts/letsencrypt/issue.sh --staging

# 5. Real issuance (then bring up / reload nginx)
sudo ./scripts/letsencrypt/issue.sh

# 6. Confirm renewal is wired up
sudo certbot renew --dry-run
```

## How renewal works

`issue.sh` saves the auth/cleanup/deploy hooks into the certbot renewal config,
so the distro's `certbot.timer` renews automatically and re-runs `deploy-hook.sh`
(which reloads the `nginx` container). No extra cron.

## Verify it worked

```bash
echo | openssl s_client -connect lst.is.ed.ac.uk:443 -servername lst.is.ed.ac.uk 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

Issuer should be Let's Encrypt; no browser warning = done. Or use the wrapper
`sudo ./scripts/letsencrypt/issue-and-verify.sh` which issues then checks the
served cert.

## Files

| File | Role |
|---|---|
| `auth-hook.sh` | certbot manual auth hook — `nsupdate -k` deletes any stale TXT and adds the challenge TXT |
| `cleanup-hook.sh` | `nsupdate -k` deletes the challenge TXT after validation |
| `deploy-hook.sh` | on success, installs `fullchain`/`privkey` into `../../certs/lst.crt`/`.key` and reloads the `nginx` container |
| `issue.sh` | one-time issuance wrapper (`--staging` supported); registers the hooks so `certbot renew` is automatic |
| `issue-and-verify.sh` | runs `issue.sh` then verifies the host is serving the new cert |
