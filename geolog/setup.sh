#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: setup.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=geolog
SCRIPT_VERSION=1
APP_USER=geolog
APP_DIR=/opt/geolog
APP_DOMAIN=geolog.jmaster.online
SECRETS_FILE=${APP_DIR}/secrets.txt

APP_PORT=${APP_PORT:-8080}
RELEASES_DIR=${APP_DIR}/releases
NGINX_SITE=/etc/nginx/sites-available/geolog
NGINX_ENABLED_SITE=/etc/nginx/sites-enabled/geolog

DB_NAME=${DB_NAME:-geolog}
DB_USER=${DB_USER:-geolog}

echo "=== GeoLog bootstrap v${SCRIPT_VERSION} ==="

reload_nginx() {
  nginx -t
  systemctl reload nginx
}

ensure_app_user_and_dirs() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd -r -m -d "${APP_DIR}" -s /bin/bash "${APP_USER}"
  fi

  mkdir -p "$APP_DIR" "$RELEASES_DIR"
  chown -R ${APP_USER}:${APP_USER} "$APP_DIR"
}

ensure_secret() {
  local name=$1
  local prompt=$2
  local secret=${3:-false}
  local default_value=${4:-}
  local value=${!name:-}

  if [ -n "$value" ]; then
    return
  fi

  if [ "$secret" = true ]; then
    read -s -p "$prompt" value
    echo
  else
    read -p "$prompt" value
  fi

  value=${value:-$default_value}
  if [ -z "$value" ]; then
    echo "${name} is required" >&2
    exit 1
  fi

  printf '%s=%q\n' "$name" "$value" >> "$SECRETS_FILE"
  export "$name=$value"
}

load_or_create_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    touch "$SECRETS_FILE"
    chown ${APP_USER}:${APP_USER} "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi

  source "$SECRETS_FILE" || true

  ensure_secret DB_PASS "Enter DB password: " true
  ensure_secret GIT_PAT "Enter GitHub Personal Access Token: " true
  ensure_secret LETSENCRYPT_EMAIL "Enter Let's Encrypt email: "
  ensure_secret GEOLOG_SECURITY_USERNAME "Enter GeoLog admin username [geolog]: " false geolog
  ensure_secret GEOLOG_SECURITY_PASSWORD "Enter GeoLog admin password: " true

  DB_NAME=${DB_NAME:-geolog}
  DB_USER=${DB_USER:-geolog}

  if ! grep -q '^DB_NAME=' "$SECRETS_FILE"; then
    echo "DB_NAME=${DB_NAME}" >> "$SECRETS_FILE"
  fi
  if ! grep -q '^DB_USER=' "$SECRETS_FILE"; then
    echo "DB_USER=${DB_USER}" >> "$SECRETS_FILE"
  fi
}

ensure_packages() {
  apt update

  if ! java -version 2>/dev/null | grep -q "21"; then
    if ! command -v add-apt-repository >/dev/null; then
      apt install -y software-properties-common
    fi
    add-apt-repository -y ppa:openjdk-r/ppa
    apt update
    apt install -y openjdk-21-jdk
  fi

  apt install -y curl git maven mariadb-server nginx certbot python3-certbot-nginx

  systemctl enable mariadb
  systemctl start mariadb

  systemctl enable nginx
  systemctl start nginx
}

ensure_database() {
  mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
}

write_nginx_site() {
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${APP_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
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

  if [ ! -L "$NGINX_ENABLED_SITE" ]; then
    ln -s "$NGINX_SITE" "$NGINX_ENABLED_SITE"
  fi
}

ensure_firewall() {
  if command -v ufw >/dev/null; then
    ufw allow 'Nginx Full'
  fi
}

ensure_ssl() {
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "${LETSENCRYPT_EMAIL}" \
    --redirect \
    --keep-until-expiring \
    -d "${APP_DOMAIN}"
}

ensure_app_user_and_dirs
load_or_create_secrets
ensure_packages
ensure_database
write_nginx_site
ensure_firewall
reload_nginx
ensure_ssl
reload_nginx

echo "===================================="
echo " GeoLog server is ready for deploy"
echo " Script version: ${SCRIPT_VERSION}"
echo " Public domain: https://${APP_DOMAIN}"
echo " App port: ${APP_PORT}"
echo " Nginx site: ${NGINX_SITE}"
echo " Next step: run geolog/deploy.sh"
echo " DB name: ${DB_NAME}"
echo " DB user: ${DB_USER}"
echo "===================================="
