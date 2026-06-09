#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: deploy-resto.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=bat
APP_USER=bat
APP_DIR=/opt/bat
APP_REPO_DIR=${APP_DIR}/repo
GIT_REPO=https://github.com/jmaster1/bat
SECRETS_FILE=${APP_DIR}/secrets.txt

RESTO_DOMAIN=resto.tablepass.app
RESTO_ROOT=${APP_REPO_DIR}/docs/resto/htdocs
NGINX_SITE=/etc/nginx/sites-available/resto
NGINX_ENABLED_SITE=/etc/nginx/sites-enabled/resto
NGINX_USER=www-data

GIT_AUTH_HEADER=

DNS_EMAIL_VAR_NAME=LETSENCRYPT_EMAIL

echo "=== RESTO deploy ==="

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Secrets file not found: ${SECRETS_FILE}. Run setup.sh first." >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  if [ -z "$GIT_PAT" ]; then
    echo "GIT_PAT is not set in ${SECRETS_FILE}" >&2
    exit 1
  fi

  GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GIT_PAT}" | base64 -w0)
}

checkout_or_update_repo() {
  if [ ! -d "$APP_REPO_DIR" ]; then
    echo "Cloning ${APP_NAME} repository..."
    sudo -u ${APP_USER} git \
      -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" \
      clone ${GIT_REPO} "$APP_REPO_DIR" >&2
    return
  fi

  echo "Updating repository..."
  cd "$APP_REPO_DIR"
  sudo -u ${APP_USER} git \
    -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" \
    fetch --all >&2
  sudo -u ${APP_USER} git reset --hard origin/main >&2
}

ensure_resto_root_exists() {
  if [ ! -d "$RESTO_ROOT" ]; then
    echo "RESTO root directory not found: ${RESTO_ROOT}" >&2
    exit 1
  fi

  if [ ! -f "${RESTO_ROOT}/index.html" ]; then
    echo "RESTO index.html not found: ${RESTO_ROOT}/index.html" >&2
    exit 1
  fi
}

fix_nginx_read_permissions() {
  echo "Fixing nginx read permissions..."

  # nginx needs execute permission on every parent directory in order to stat/read files.
  chmod o+x /opt || true
  chmod o+x "$APP_DIR"
  chmod o+x "$APP_REPO_DIR"
  chmod o+x "${APP_REPO_DIR}/docs"
  chmod o+x "${APP_REPO_DIR}/docs/resto"

  # Static files should be readable by nginx, directories traversable.
  chmod -R o+rX "${APP_REPO_DIR}/docs/resto"

  if ! sudo -u "$NGINX_USER" test -r "${RESTO_ROOT}/index.html"; then
    echo "${NGINX_USER} still cannot read ${RESTO_ROOT}/index.html" >&2
    namei -l "${RESTO_ROOT}/index.html" >&2 || true
    exit 1
  fi
}

write_nginx_site() {
  cat > "$NGINX_SITE" <<EOF_NGINX
server {
    listen 80;
    server_name ${RESTO_DOMAIN};

    root ${RESTO_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF_NGINX

  ln -sf "$NGINX_SITE" "$NGINX_ENABLED_SITE"
}

reload_nginx() {
  nginx -t
  systemctl reload nginx
}

issue_or_renew_certificate() {
  if [ -z "${LETSENCRYPT_EMAIL:-}" ]; then
    echo "LETSENCRYPT_EMAIL is not set in ${SECRETS_FILE}; skipping certbot." >&2
    return
  fi

  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "${LETSENCRYPT_EMAIL}" \
    --redirect \
    --keep-until-expiring \
    -d "${RESTO_DOMAIN}"
}

load_secrets
checkout_or_update_repo
ensure_resto_root_exists
fix_nginx_read_permissions
write_nginx_site
reload_nginx
issue_or_renew_certificate
fix_nginx_read_permissions
reload_nginx

echo "===================================="
echo "RESTO deploy complete"
echo "Public URL: https://${RESTO_DOMAIN}"
echo "Root: ${RESTO_ROOT}"
echo "===================================="
