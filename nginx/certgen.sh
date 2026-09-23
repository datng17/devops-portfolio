#!/bin/sh
# nginx/certgen.sh
# Auto-generate a self-signed TLS certificate for nginx if none exists yet.
# Populates the shared `letsencrypt` volume at the exact paths nginx expects:
#   /etc/letsencrypt/live/<DOMAIN>/fullchain.pem
#   /etc/letsencrypt/live/<DOMAIN>/privkey.pem
#
# Idempotent: skips generation when a valid cert is already present, so it is
# safe to run on every `docker compose up`. Replace with a real Let's Encrypt
# certbot flow in production once DNS points at the host.
set -eu

DOMAIN="${TLS_DOMAIN:-app.example.com}"
DAYS="${TLS_DAYS:-365}"
LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
CRT="${LIVE_DIR}/fullchain.pem"
KEY="${LIVE_DIR}/privkey.pem"

if [ -s "${CRT}" ] && [ -s "${KEY}" ]; then
    echo "certgen: existing certificate found at ${CRT}, skipping."
    exit 0
fi

echo "certgen: generating self-signed certificate for ${DOMAIN} (valid ${DAYS} days)..."
mkdir -p "${LIVE_DIR}"

openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "${KEY}" \
    -out "${CRT}" \
    -days "${DAYS}" \
    -subj "/CN=${DOMAIN}/O=devops-portfolio/C=US" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1"

chmod 600 "${KEY}"
chmod 644 "${CRT}"

echo "certgen: certificate written to ${CRT}"
