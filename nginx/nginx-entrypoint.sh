#!/bin/sh
# nginx/nginx-entrypoint.sh
# Boots nginx so it can serve the ACME http-01 challenge on port 80 even
# before any real certificate exists, then keeps nginx running with a
# periodic reload so freshly renewed Let's Encrypt certs are picked up.
#
# Flow:
#   1. If no cert yet for $TLS_DOMAIN, drop in a temporary self-signed cert
#      so the 443 server block can load (nginx refuses to start otherwise).
#   2. Start nginx in the background.
#   3. Wait for certbot to obtain the real cert, then reload.
#   4. Reload every 12h to pick up renewals.
set -eu

DOMAIN="${TLS_DOMAIN:-app.example.com}"
LIVE="/etc/letsencrypt/live/${DOMAIN}"

# Render the templated nginx.conf (${TLS_DOMAIN} -> real value).
export TLS_DOMAIN="${DOMAIN}"
envsubst '${TLS_DOMAIN}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf

# Ensure the ACME webroot exists.
mkdir -p /var/www/certbot

# If there's no real cert yet, install a throwaway self-signed one so nginx
# can bind 443. certbot will replace it on first successful issuance.
if [ ! -s "${LIVE}/fullchain.pem" ] || [ ! -s "${LIVE}/privkey.pem" ]; then
    echo "nginx-entrypoint: no cert for ${DOMAIN} yet; installing temporary self-signed cert."
    mkdir -p "${LIVE}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout "${LIVE}/privkey.pem" \
        -out "${LIVE}/fullchain.pem" \
        -subj "/CN=${DOMAIN}" >/dev/null 2>&1
fi

# Start nginx in the background.
nginx -g 'daemon off;' &
NGINX_PID=$!

# Reload periodically so renewed certs are picked up without a restart.
while true; do
    sleep 12h &
    wait $! || true
    echo "nginx-entrypoint: reloading nginx to pick up any renewed certs."
    nginx -t && nginx -s reload || echo "nginx-entrypoint: reload skipped (config test failed)."
    # If nginx died, exit so Docker restarts the container.
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "nginx-entrypoint: nginx process gone, exiting."
        exit 1
    fi
done
