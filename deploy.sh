#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: deploy.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=bat
APP_USER=bat
APP_DIR=/opt/bat
SECRETS_FILE=${APP_DIR}/secrets.txt

APP_REPO_DIR=/opt/bat/repo
GIT_REPO=https://github.com/jmaster1/bat

PORT_8088=8088
PORT_8089=8089
ACTIVE_PORT_FILE=${APP_DIR}/active-port
RELEASES_DIR=${APP_DIR}/releases
NGINX_SITE=/etc/nginx/sites-available/bat
NGINX_UPSTREAM_SNIPPET=/etc/nginx/snippets/bat-upstream.conf
HEALTH_TIMEOUT_SECONDS=90

FIREBASE_CREDENTIALS_JSON=
GIT_AUTH_HEADER=
BUILD_RELEASE_JAR=

echo "=== BAT deploy ==="

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

  if ! systemctl is-active --quiet "$(service_name_for_port "$PORT_8088")" \
    && ! systemctl is-active --quiet "$(service_name_for_port "$PORT_8089")"; then
    echo "$PORT_8089"
    return
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

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Secrets file not found: ${SECRETS_FILE}. Run setup.sh first." >&2
    exit 1
  fi

  source "$SECRETS_FILE"

  if [ -z "$DB_PASS" ]; then
    echo "DB_PASS is not set in ${SECRETS_FILE}" >&2
    exit 1
  fi

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

checkout_or_update_repo() {
  if [ ! -d "$APP_REPO_DIR" ]; then
    echo "Cloning repository..."
    sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" clone ${GIT_REPO} "$APP_REPO_DIR" >&2
    return
  fi

  echo "Updating repository..."
  cd "$APP_REPO_DIR"
  sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" fetch --all >&2
  sudo -u ${APP_USER} git reset --hard origin/main >&2
}

load_secrets
find_firebase_credentials

checkout_or_update_repo
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
