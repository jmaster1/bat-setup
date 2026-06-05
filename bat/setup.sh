#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: setup.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=bat
APP_USER=bat
APP_DIR=/opt/bat
APP_DOMAIN=tablepass.app
APP_WWW_DOMAIN=www.tablepass.app
SECRETS_FILE=${APP_DIR}/secrets.txt

PORT_8088=8088
RELEASES_DIR=${APP_DIR}/releases
NGINX_SITE=/etc/nginx/sites-available/bat
NGINX_UPSTREAM_SNIPPET=/etc/nginx/snippets/bat-upstream.conf

DB_NAME=bat
DB_USER=bat

echo "=== BAT bootstrap ==="

############################################
# Helpers
############################################
write_nginx_upstream() {
  local port=$1
  mkdir -p "$(dirname "$NGINX_UPSTREAM_SNIPPET")"
  cat > "$NGINX_UPSTREAM_SNIPPET" <<EOF
proxy_pass http://127.0.0.1:${port};
EOF
}

ensure_nginx_uses_upstream_snippet() {
  if [ ! -f "$NGINX_SITE" ]; then
    return
  fi

  if grep -qE 'proxy_pass http://127\.0\.0\.1:[0-9]+;' "$NGINX_SITE"; then
    sed -i -E "s#proxy_pass http://127\.0\.0\.1:[0-9]+;#include ${NGINX_UPSTREAM_SNIPPET};#g" "$NGINX_SITE"
    return
  fi

  if grep -q "include ${NGINX_UPSTREAM_SNIPPET};" "$NGINX_SITE"; then
    return
  fi

  echo "Nginx BAT site does not contain a localhost proxy_pass to replace: ${NGINX_SITE}" >&2
  exit 1
}

reload_nginx() {
  ensure_nginx_uses_upstream_snippet
  nginx -t
  systemctl reload nginx
}

############################################
# Linux user/app dir
############################################
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -r -m -d ${APP_DIR} -s /bin/bash ${APP_USER}
fi

mkdir -p "$RELEASES_DIR"
chown -R ${APP_USER}:${APP_USER} "$APP_DIR"

############################################
# secrets
############################################
if [ ! -f "$SECRETS_FILE" ]; then
  touch $SECRETS_FILE
fi

source "$SECRETS_FILE" || true

if [ -z "$DB_PASS" ]; then
  read -s -p "Enter DB password: " DB_PASS
  echo
  echo "DB_PASS=${DB_PASS}" >> "$SECRETS_FILE"
fi

if [ -z "$GIT_PAT" ]; then
  read -s -p "Enter GitHub Personal Access Token: " GIT_PAT
  echo
  echo "GIT_PAT=${GIT_PAT}" >> "$SECRETS_FILE"
fi

if [ -z "$LETSENCRYPT_EMAIL" ]; then
  read -p "Enter Let's Encrypt email: " LETSENCRYPT_EMAIL
  echo "LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}" >> "$SECRETS_FILE"
fi

############################################
# Java 21 + Maven
############################################
if ! java -version 2>/dev/null | grep -q "21"; then
  add-apt-repository -y ppa:openjdk-r/ppa
  apt update
  apt install -y openjdk-21-jdk
fi

if ! command -v mvn >/dev/null; then
  apt install -y maven
fi

if ! command -v curl >/dev/null; then
  apt install -y curl
fi

############################################
# MariaDB
############################################
if ! command -v mariadb >/dev/null; then
  apt install -y mariadb-server
  systemctl enable mariadb
  systemctl start mariadb
fi

############################################
# DB + user
############################################
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

############################################
# Nginx
############################################
if ! command -v nginx >/dev/null; then
  apt install -y nginx
  systemctl enable nginx
  systemctl start nginx
fi

apt install -y certbot python3-certbot-nginx

write_nginx_upstream "$PORT_8088"

cat > ${NGINX_SITE} <<EOF
server {
    listen 80;
    server_name ${APP_DOMAIN} ${APP_WWW_DOMAIN};

    location / {
        include ${NGINX_UPSTREAM_SNIPPET};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

if [ ! -L /etc/nginx/sites-enabled/bat ]; then
  ln -s /etc/nginx/sites-available/bat /etc/nginx/sites-enabled/bat
fi

if [ -L /etc/nginx/sites-enabled/default ]; then
  rm /etc/nginx/sites-enabled/default
fi

reload_nginx

certbot --nginx \
  --non-interactive \
  --agree-tos \
  --email ${LETSENCRYPT_EMAIL} \
  --redirect \
  --keep-until-expiring \
  -d ${APP_DOMAIN} \
  -d ${APP_WWW_DOMAIN}

ensure_nginx_uses_upstream_snippet
reload_nginx

############################################
# Output
############################################
echo "===================================="
echo " BAT server is ready for deploy"
echo " Public domain: https://${APP_DOMAIN}"
echo " Next step: run deploy.sh"
echo " DB name: ${DB_NAME}"
echo " DB User: ${DB_USER}"
echo "===================================="
