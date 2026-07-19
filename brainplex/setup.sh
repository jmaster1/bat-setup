#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: setup.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=brainplex
SCRIPT_VERSION=2
APP_USER=brainplex
APP_DIR=/opt/brainplex
APP_DOMAIN=brainplex.jmaster.online
WWW_DIR=${APP_DIR}/www
SECRETS_FILE=${APP_DIR}/secrets.txt
PRIVACY_POLICY_URL=${PRIVACY_POLICY_URL:-https://raw.githubusercontent.com/jmaster1/bat-setup/main/brainplex/privacy_policy.html}

NGINX_SITE=/etc/nginx/sites-available/brainplex
NGINX_ENABLED_SITE=/etc/nginx/sites-enabled/brainplex

echo "=== Brainplex static site bootstrap v${SCRIPT_VERSION} ==="

reload_nginx() {
  nginx -t
  systemctl reload nginx
}

ensure_app_user_and_dirs() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd -r -m -d "${APP_DIR}" -s /bin/bash "${APP_USER}"
  fi

  mkdir -p "$APP_DIR" "$WWW_DIR"
  chown -R ${APP_USER}:${APP_USER} "$APP_DIR"
  chmod 755 "$APP_DIR" "$WWW_DIR"
}

ensure_secret() {
  local name=$1
  local prompt=$2
  local value=${!name:-}

  if [ -n "$value" ]; then
    return
  fi

  read -p "$prompt" value
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
  ensure_secret LETSENCRYPT_EMAIL "Enter Let's Encrypt email: "
}

ensure_packages() {
  apt update
  apt install -y curl nginx certbot python3-certbot-nginx

  systemctl enable nginx
  systemctl start nginx
}

verify_dns_points_here() {
  local public_ip
  local resolved_ips

  public_ip=$(curl -fsS https://api.ipify.org || true)
  if [ -z "$public_ip" ]; then
    echo "Cannot detect server public IP; refusing to continue before SSL setup." >&2
    exit 1
  fi

  resolved_ips=$(getent ahostsv4 "$APP_DOMAIN" | awk '{print $1}' | sort -u || true)
  if ! echo "$resolved_ips" | grep -qx "$public_ip"; then
    echo "${APP_DOMAIN} does not resolve to this server yet." >&2
    echo "Server public IP: ${public_ip}" >&2
    echo "Resolved IPs:" >&2
    echo "${resolved_ips:-<none>}" >&2
    echo "Fix DNS and retry after propagation." >&2
    exit 1
  fi
}

write_index_page() {
  cat > "${WWW_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Brainplex</title>
</head>
<body>
  <h1>Brainplex</h1>
  <p><a href="/privacy_policy.html">Privacy Policy</a></p>
</body>
</html>
EOF

  chown -R ${APP_USER}:${APP_USER} "$WWW_DIR"
  find "$WWW_DIR" -type d -exec chmod 755 {} \;
  find "$WWW_DIR" -type f -exec chmod 644 {} \;
}

install_privacy_policy() {
  local tmp_file
  tmp_file=$(mktemp)

  echo "Downloading privacy policy from ${PRIVACY_POLICY_URL}"
  curl -fsSL "$PRIVACY_POLICY_URL" -o "$tmp_file"

  if ! grep -qi '<h2>Privacy Policy</h2>' "$tmp_file"; then
    echo "Downloaded file does not look like the Brainplex privacy policy: ${PRIVACY_POLICY_URL}" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  install -m 644 -o ${APP_USER} -g ${APP_USER} "$tmp_file" "${WWW_DIR}/privacy_policy.html"
  rm -f "$tmp_file"
}

write_nginx_site() {
  local conflicts

  conflicts=$(grep -RslE "server_name[[:space:]].*${APP_DOMAIN}" /etc/nginx/sites-available /etc/nginx/sites-enabled 2>/dev/null \
    | grep -vE "^${NGINX_SITE}$|^${NGINX_ENABLED_SITE}$" || true)

  if [ -n "$conflicts" ]; then
    echo "Nginx server_name ${APP_DOMAIN} is already configured outside ${NGINX_SITE}:" >&2
    echo "$conflicts" >&2
    exit 1
  fi

  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${APP_DOMAIN};

    root ${WWW_DIR};
    index index.html;

    location = /privacy_policy {
        return 301 /privacy_policy.html;
    }

    location = /privacy_policy.html {
        default_type text/html;
        try_files /privacy_policy.html =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
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

verify_site() {
  curl -fsSI "https://${APP_DOMAIN}/privacy_policy.html" >/dev/null
}

ensure_app_user_and_dirs
load_or_create_secrets
ensure_packages
verify_dns_points_here
write_index_page
install_privacy_policy
write_nginx_site
ensure_firewall
reload_nginx
ensure_ssl
reload_nginx
verify_site

echo "===================================="
echo " Brainplex static site is ready"
echo " Script version: ${SCRIPT_VERSION}"
echo " Public URL: https://${APP_DOMAIN}/privacy_policy.html"
echo " Web root: ${WWW_DIR}"
echo " Nginx site: ${NGINX_SITE}"
echo " Privacy policy source: ${PRIVACY_POLICY_URL}"
echo "===================================="
