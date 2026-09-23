#!/bin/sh
# nginx/certbot-entrypoint.sh
# Obtains a real Let's Encrypt certificate on first run (webroot http-01),
# then loops forever renewing every 12h. Shares the `letsencrypt` volume and
# the `certbot_www` webroot volume with nginx.
#
# Required env:
#   TLS_DOMAIN   - the FQDN that resolves to this host's public IP
#   TLS_EMAIL    - contact email for Let's Encrypt (expiry notices)
# Optional env:
#   TLS_STAGING  - "1" to use Let's Encrypt staging (avoids rate limits while testing)
set -eu

DOMAIN="${TLS_DOMAIN:-test.name.vn}"
EMAIL="${TLS_EMAIL:-datng416@gmail.com}"
WEBROOT="/var/www/certbot"
LIVE="/etc/letsencrypt/live/${DOMAIN}"

STAGING_FLAG=""
if [ "${TLS_STAGING:-0}" = "1" ]; then
    STAGING_FLAG="--staging"
    echo "certbot: STAGING mode enabled (certs will NOT be trusted by browsers)."
fi

mkdir -p "${WEBROOT}"

# Wait until nginx is answering on port 80 so the challenge can be served.
echo "certbot: waiting for nginx on port 80..."
i=0
while ! wget -qO- "http://nginx/health" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 60 ] && { echo "certbot: nginx not reachable after 60s, continuing anyway."; break; }
    sleep 1
done

# Obtain the cert only if we don't already have a Let's Encrypt-issued one.
# (nginx may have dropped a 1-day self-signed placeholder; certbot's own
# state dir is the source of truth, so we key off certbot, not the file.)
if certbot certificates 2>/dev/null | grep -q "Domains:.*\b${DOMAIN}\b"; then
    echo "certbot: certificate for ${DOMAIN} already present; skipping issuance."
else
    echo "certbot: requesting certificate for ${DOMAIN} via webroot http-01..."
    certbot certonly \
        --webroot -w "${WEBROOT}" \
        -d "${DOMAIN}" \
        --email "${EMAIL}" \
        --agree-tos --no-eff-email \
        --non-interactive \
        --keep-until-expiring \
        ${STAGING_FLAG} || echo "certbot: issuance failed (check DNS A record and that ports 80/443 are open)."
fi

# Renewal loop. certbot renew is a no-op until certs are within 30 days of
# expiry, so running it every 12h is safe and standard.
while true; do
    sleep 12h &
    wait $! || true
    echo "certbot: running renewal check..."
    certbot renew --webroot -w "${WEBROOT}" --non-interactive --quiet || \
        echo "certbot: renewal check failed; will retry next cycle."
done
