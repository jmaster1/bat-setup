#!/bin/bash

set -e
set -x

APP_NAME=bat
APP_USER=bat
APP_DIR=/opt/bat
SECRETS_FILE=${APP_DIR}/secrets.txt

APP_REPO_DIR=/opt/bat/repo
GIT_REPO=https://github.com/jmaster1/bat

DB_NAME=bat
DB_USER=bat

echo "=== BAT idempotent bootstrap 1.4 ==="

############################################
# Linux user/app dir
############################################
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -r -m -d ${APP_DIR} -s /bin/bash ${APP_USER}
fi

############################################
# secrets
############################################
if [ ! -f "$SECRETS_FILE" ]; then
  touch $SECRETS_FILE
fi

set +x
source $SECRETS_FILE || true

if [ -z "$DB_PASS" ]; then
  read -s -p "Enter DB password: " DB_PASS
  echo
  echo "DB_PASS=${DB_PASS}" >> $SECRETS_FILE
fi

if [ -z "$GIT_PAT" ]; then
  read -s -p "Enter GitHub Personal Access Token: " GIT_PAT
  echo
  echo "GIT_PAT=${GIT_PAT}" >> $SECRETS_FILE
fi
set -x

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
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

############################################
# Git checkout / update
############################################
GIT_REPO_AUTH="https://${GIT_PAT}@github.com/jmaster1/bat.git"
if [ ! -d "$APP_REPO_DIR" ]; then
  echo "Cloning repository..."
  sudo -u ${APP_USER} git clone $GIT_REPO_AUTH $APP_REPO_DIR
else
  echo "Updating repository..."
  cd $APP_REPO_DIR
  sudo -u ${APP_USER} git fetch --all
  sudo -u ${APP_USER} git reset --hard origin/main
fi

############################################
# Build
############################################
cd ${APP_REPO_DIR}
sudo -u ${APP_USER} mvn clean package -DskipTests

JAR=${APP_REPO_DIR}/$(ls target/*.jar | head -n1)
echo "JAR=${JAR}"

############################################
# App config
############################################
cat > ${APP_DIR}/application.properties <<EOF
spring.datasource.password=${DB_PASS}
EOF

chown ${APP_USER}:${APP_USER} ${APP_DIR}/application.properties

############################################
# systemd service
############################################
cat > /etc/systemd/system/bat.service <<EOF
[Unit]
Description=BAT Server
After=network.target mariadb.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/java -jar ${JAR} --spring.datasource.password=${DB_PASS}
Restart=on-failure
RestartSec=100
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bat
systemctl restart bat

############################################
# Output
############################################
IP=$(hostname -I | awk '{print $1}')

echo "===================================="
echo " BAT is running"
echo " URL: http://${IP}:8088"
echo " DB: ${DB_NAME}"
echo " DB User: ${DB_USER}"
echo "===================================="
