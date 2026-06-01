#!/bin/bash

set -Ee
set -o pipefail

shopt -s inherit_errexit 2>/dev/null || true
trap 'echo "ERROR: deploy.sh failed at line ${LINENO} while running: ${BASH_COMMAND}" >&2' ERR

APP_NAME=etm
SCRIPT_VERSION=5
APP_USER=etm
APP_DIR=/opt/etm
SECRETS_FILE=${APP_DIR}/secrets.txt

APP_REPO_DIR=/opt/etm/repo
SERVER_REPO_DIR=${APP_REPO_DIR}/server
GIT_REPO=${GIT_REPO:-https://github.com/jmaster1/elisa-traffic-mon}
JMASTER_REPO_DIR=/opt/etm/jmaster-web
JMASTER_GIT_REPO=${JMASTER_GIT_REPO:-https://github.com/jmaster1/jmaster-web}

APP_PORT=${APP_PORT:-8181}
SERVICE_NAME=etm
RELEASES_DIR=${APP_DIR}/releases
HEALTH_TIMEOUT_SECONDS=90

GIT_AUTH_HEADER=
BUILD_RELEASE_JAR=

echo "=== ETM deploy v${SCRIPT_VERSION} ==="

write_etm_service() {
  local jar=$1

  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=ETM Server
After=network.target mariadb.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/java -jar ${jar} \\
--server.port=${APP_PORT} \\
--spring.datasource.url=jdbc:mariadb://localhost:3306/${DB_NAME} \\
--spring.datasource.username=${DB_USER} \\
--spring.datasource.password=${DB_PASS} \\
--etm.security.username=${ETM_SECURITY_USERNAME} \\
--etm.security.password=${ETM_SECURITY_PASSWORD} \\
--spring.profiles.active=prod
Restart=on-failure
RestartSec=10
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))

  until curl -fsS "http://127.0.0.1:${APP_PORT}/actuator/health" >/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Health check failed on port ${APP_PORT}" >&2
      journalctl -u "${SERVICE_NAME}" --no-pager -n 120 >&2 || true
      exit 1
    fi
    sleep 2
  done
}

open_app_port() {
  if command -v ufw >/dev/null; then
    ufw allow "${APP_PORT}/tcp"
    return
  fi

  echo "ufw not found; skipping local firewall rule for ${APP_PORT}/tcp"
}

ensure_database() {
  mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
}

ensure_app_user_and_dirs() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd -r -m -d "${APP_DIR}" -s /bin/bash "${APP_USER}"
  fi

  mkdir -p "$APP_DIR" "$RELEASES_DIR"
  chown -R ${APP_USER}:${APP_USER} "$APP_DIR"
}

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Secrets file not found: ${SECRETS_FILE}. Create it with GIT_PAT before deploy." >&2
    exit 1
  fi

  source "$SECRETS_FILE"

  DB_NAME=${DB_NAME:-etm}
  DB_USER=${DB_USER:-etm}
  DB_PASS=${DB_PASS:-etm}
  ETM_SECURITY_USERNAME=${ETM_SECURITY_USERNAME:-etm}
  ETM_SECURITY_PASSWORD=${ETM_SECURITY_PASSWORD:-etm}

  if [ -z "${GIT_PAT:-}" ]; then
    echo "GIT_PAT is not set in ${SECRETS_FILE}" >&2
    exit 1
  fi

  GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GIT_PAT}" | base64 -w0)
}

checkout_or_update_repo() {
  local repo_url=$1
  local repo_dir=$2
  local repo_name=$3

  if [ ! -d "$repo_dir" ]; then
    echo "Cloning ${repo_name} repository..."
    sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" clone "$repo_url" "$repo_dir" >&2
    return
  fi

  echo "Updating ${repo_name} repository..."
  cd "$repo_dir"
  sudo -u ${APP_USER} git -c http.extraHeader="Authorization: Basic ${GIT_AUTH_HEADER}" fetch --all >&2
  sudo -u ${APP_USER} git reset --hard origin/main >&2
}

install_jmaster_web() {
  cd "$JMASTER_REPO_DIR"
  sudo -u ${APP_USER} mvn clean install -DskipTests >&2
}

build_release() {
  local release_dir=${RELEASES_DIR}/$(date -u +%Y%m%d%H%M%S)
  local jar=
  mkdir -p "$release_dir"

  cd "$SERVER_REPO_DIR"

  sudo -u ${APP_USER} mvn clean package -DskipTests >&2

  jar=$(find target -maxdepth 1 -type f -name "server-*.jar" ! -name "*.original" -print -quit)
  if [ -z "$jar" ]; then
    echo "Build succeeded but jar was not found in ${SERVER_REPO_DIR}/target" >&2
    exit 1
  fi

  cp "$jar" "${release_dir}/${APP_NAME}.jar"
  chown -R ${APP_USER}:${APP_USER} "$release_dir"
  BUILD_RELEASE_JAR="${release_dir}/${APP_NAME}.jar"
}

load_secrets
ensure_app_user_and_dirs
ensure_database

checkout_or_update_repo "$JMASTER_GIT_REPO" "$JMASTER_REPO_DIR" "jmaster-web"
checkout_or_update_repo "$GIT_REPO" "$APP_REPO_DIR" "etm"
install_jmaster_web
build_release

write_etm_service "$BUILD_RELEASE_JAR"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
open_app_port
systemctl restart "$SERVICE_NAME"
wait_for_health
systemctl status "$SERVICE_NAME" --no-pager -l

echo "===================================="
echo " ETM deploy complete"
echo " Script version: ${SCRIPT_VERSION}"
echo " Service: ${SERVICE_NAME}"
echo " Port: ${APP_PORT}"
echo " Jar: ${BUILD_RELEASE_JAR}"
echo "===================================="
