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

APP_REPO_DIR=/opt/bat/repo
GIT_REPO=https://github.com/jmaster1/bat
MODE=${1:-bootstrap}

PORT_8088=8088
PORT_8089=8089
ACTIVE_PORT_FILE=${APP_DIR}/active-port
RELEASES_DIR=${APP_DIR}/releases
NGINX_SITE=/etc/nginx/sites-available/bat
NGINX_UPSTREAM_SNIPPET=/etc/nginx/snippets/bat-upstream.conf
HEALTH_TIMEOUT_SECONDS=90

DB_NAME=bat
DB_USER=bat
FIREBASE_CREDENTIALS_JSON=
GIT_AUTH_HEADER=
BUILD_RELEASE_JAR=

echo "=== BAT idempotent bootstrap 2.0 (${MODE}) ==="

############################################
# Helpers
############################################
service_name_for_port() {
  local port=$1
  if [ "$port" = "$PORT_8088" ] || [ "$port" = "$PORT_8089" ]; then
    echo "${APP_NAME}-${port}"
  else
    echo "Unknown BAT port: ${port}" >&2
    exit 1
  fi
}

other_port() {
  local port=$1
  if [ "$port" = "$PORT_8088" ]; then
    echo "$PORT_8089"
  else
    echo "$PORT_8088"
  fi
}

is_known_app_port() {
  local port=$1
  [ "$port" = "$PORT_8088" ] || [ "$port" = "$PORT_8089" ]
}

detect_active_port() {
  if [ -f "$ACTIVE_PORT_FILE" ]; then
    local file_port
    file_port=$(cat "$ACTIVE_PORT_FILE")
    if is_known_app_port "$file_port"; then
      echo "$file_port"
      return
    fi
  fi

  if [ -f "$NGINX_UPSTREAM_SNIPPET" ]; then
    local detected_port
    detected_port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$NGINX_UPSTREAM_SNIPPET" | head -n1 | cut -d: -f2 || true)
    if is_known_app_port "$detected_port"; then
      echo "$detected_port"
      return
    fi
  fi

  if [ -f "$NGINX_SITE" ]; then
    local site_port
    site_port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$NGINX_SITE" | head -n1 | cut -d: -f2 || true)
    if is_known_app_port "$site_port"; then
      echo "$site_port"
      return
    fi

    if systemctl is-active --quiet bat; then
      echo "$PORT_8088"
      return
    fi
  fi

  echo "$PORT_8088"
}

write_bat_service() {
  local port=$1
  local jar=$2

  cat > /etc/systemd/system/$(service_name_for_port "$port").service <<EOF
[Unit]
Description=BAT Server (${port})
After=network.target mariadb.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/java -jar ${jar} \\
--server.port=${port} \\
--bat.instance-id=${port} \\
--spring.datasource.password=${DB_PASS} \\
--firebase.credentials.location=file:${FIREBASE_CREDENTIALS_JSON} \\
--spring.profiles.active=prod
Restart=on-failure
RestartSec=100
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
}

write_bat_services() {
  local jar=$1
  write_bat_service "$PORT_8088" "$jar"
  write_bat_service "$PORT_8089" "$jar"
  systemctl daemon-reload
}

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

wait_for_health() {
  local port=$1
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))

  until curl -fsS "http://127.0.0.1:${port}/actuator/health" >/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Health check failed on port ${port}" >&2
      journalctl -u "$(service_name_for_port "$port")" --no-pager -n 120 >&2 || true
      exit 1
    fi
    sleep 2
  done
}

load_secrets_for_deploy() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Secrets file not found: ${SECRETS_FILE}" >&2
    exit 1
  fi

  source "$SECRETS_FILE"

  if [ -z "$GIT_PAT" ]; then
    echo "GIT_PAT is not set in ${SECRETS_FILE}" >&2
    exit 1
  fi

  GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GIT_PAT}" | base64 -w0)
}

find_firebase_credentials() {
  FIREBASE_CREDENTIALS_JSON=$(find "${APP_DIR}" -maxdepth 1 -type f -name '*firebase-adminsdk*.json' | head -n1 || true)

  if [ -z "${FIREBASE_CREDENTIALS_JSON}" ]; then
    echo "Firebase credentials JSON not found in ${APP_DIR}" >&2
    exit 1
  fi
}

build_release() {
  local release_dir=${RELEASES_DIR}/$(date -u +%Y%m%d%H%M%S)
  local jar=
  mkdir -p "$release_dir"

  cd "$APP_REPO_DIR"

  sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" fetch origin main >&2

  sudo -u ${APP_USER} git reset --hard origin/main >&2
  sudo -u ${APP_USER} mvn clean package -DskipTests >&2

  jar=$(find target -maxdepth 1 -type f -name "${APP_NAME}-*.jar" ! -name "*.original" -print -quit)
  if [ -z "$jar" ]; then
    echo "Build succeeded but jar was not found in ${APP_REPO_DIR}/target" >&2
    exit 1
  fi

  cp "$jar" "${release_dir}/${APP_NAME}.jar"
  chown -R ${APP_USER}:${APP_USER} "$release_dir"
  BUILD_RELEASE_JAR="${release_dir}/${APP_NAME}.jar"
}

############################################
# Fast modes
############################################
if [ "$MODE" = "restart" ]; then
  ACTIVE_PORT=$(detect_active_port)
  ACTIVE_SERVICE=$(service_name_for_port "$ACTIVE_PORT")
  systemctl restart "$ACTIVE_SERVICE"
  wait_for_health "$ACTIVE_PORT"
  systemctl status "$ACTIVE_SERVICE" --no-pager -l
  exit 0
fi

if [ "$MODE" = "deploy" ]; then
  load_secrets_for_deploy
  find_firebase_credentials

  if [ ! -d "$APP_REPO_DIR" ]; then
    echo "Repository not found: ${APP_REPO_DIR}. Run bootstrap first." >&2
    exit 1
  fi

  build_release
  NEW_JAR=$BUILD_RELEASE_JAR
  ACTIVE_PORT=$(detect_active_port)
  NEXT_PORT=$(other_port "$ACTIVE_PORT")
  ACTIVE_SERVICE=$(service_name_for_port "$ACTIVE_PORT")
  NEXT_SERVICE=$(service_name_for_port "$NEXT_PORT")

  write_bat_service "$NEXT_PORT" "$NEW_JAR"

  systemctl daemon-reload
  systemctl enable "$NEXT_SERVICE"
  systemctl restart "$NEXT_SERVICE"
  wait_for_health "$NEXT_PORT"

  write_nginx_upstream "$NEXT_PORT"
  reload_nginx
  echo "$NEXT_PORT" > "$ACTIVE_PORT_FILE"

  systemctl stop "$ACTIVE_SERVICE" || true
  systemctl disable "$ACTIVE_SERVICE" || true
  systemctl stop bat || true
  systemctl disable bat || true
  systemctl status "$NEXT_SERVICE" --no-pager -l

  echo "===================================="
  echo " BAT deploy complete"
  echo " Active service: ${NEXT_SERVICE}"
  echo " Active port: ${NEXT_PORT}"
  echo " Old service stopped: ${ACTIVE_SERVICE}"
  echo " Sessions on old instance were dropped"
  echo "===================================="
  exit 0
fi

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
# Git checkout / update
############################################
GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GIT_PAT}" | base64 -w0)

if [ ! -d "$APP_REPO_DIR" ]; then
  echo "Cloning repository..."
  sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" clone ${GIT_REPO} $APP_REPO_DIR
else
  echo "Updating repository..."
  cd $APP_REPO_DIR
  sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" fetch --all
  sudo -u ${APP_USER} git reset --hard origin/main
fi

############################################
# Build/release
############################################
find_firebase_credentials
build_release
JAR=$BUILD_RELEASE_JAR
echo "JAR=${JAR}"

############################################
# systemd services
############################################
write_bat_services "$JAR"

systemctl disable bat || true
systemctl stop bat || true

systemctl enable "$(service_name_for_port "$PORT_8088")"
systemctl disable "$(service_name_for_port "$PORT_8089")" || true
systemctl restart "$(service_name_for_port "$PORT_8088")"
wait_for_health "$PORT_8088"
write_nginx_upstream "$PORT_8088"
reload_nginx
echo "$PORT_8088" > "$ACTIVE_PORT_FILE"
systemctl stop "$(service_name_for_port "$PORT_8089")" || true

echo "Firebase credentials: ${FIREBASE_CREDENTIALS_JSON}"

############################################
# Output
############################################
IP=$(hostname -I | awk '{print $1}')

echo "===================================="
echo " BAT is running"
echo " APP url: http://${IP}:${PORT_8088}"
echo " Active service: $(service_name_for_port "$PORT_8088")"
echo " DB name: ${DB_NAME}"
echo " DB User: ${DB_USER}"
echo "===================================="
