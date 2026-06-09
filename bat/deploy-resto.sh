#!/bin/bash

set -Ee
set -o pipefail

APP_USER=bat
APP_DIR=/opt/bat

APP_REPO_DIR=${APP_DIR}/repo
GIT_REPO=https://github.com/jmaster1/bat

SECRETS_FILE=${APP_DIR}/secrets.txt

RESTO_DOMAIN=resto.tablepass.app
RESTO_ROOT=${APP_REPO_DIR}/docs/resto/htdocs

NGINX_SITE=/etc/nginx/sites-available/resto

source "$SECRETS_FILE"

if [ -z "$GIT_PAT" ]; then
  echo "GIT_PAT is not configured"
  exit 1
fi

GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GIT_PAT}" | base64 -w0)

echo "Updating repository..."

if [ ! -d "$APP_REPO_DIR" ]; then
  sudo -u ${APP_USER} git \
    -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" \
    clone ${GIT_REPO} "$APP_REPO_DIR"
else
  cd "$APP_REPO_DIR"

  sudo -u ${APP_USER} git \
    -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" \
    fetch --all

  sudo -u ${APP_USER} git reset --hard origin/main
fi

if [ ! -d "$RESTO_ROOT" ]; then
  echo "Directory not found: $RESTO_ROOT"
  exit 1
fi

cat > ${NGINX_SITE} <<EOF
server {
    listen 80;
    server_name ${RESTO_DOMAIN};

    root ${RESTO_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf ${NGINX_SITE} /etc/nginx/sites-enabled/resto

nginx -t
systemctl reload nginx

if [ -n "$LETSENCRYPT_EMAIL" ]; then
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    --email ${LETSENCRYPT_EMAIL} \
    -d ${RESTO_DOMAIN}
fi

nginx -t
systemctl reload nginx

echo "===================================="
echo "RESTO deployed"
echo "https://${RESTO_DOMAIN}"
echo "root: ${RESTO_ROOT}"
echo "===================================="
