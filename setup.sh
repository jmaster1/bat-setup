#!/bin/bash

set -e
set -x

APP_NAME=bat
APP_USER=bat
APP_DIR=/opt/bat
GIT_REPO=https://github.com/jmaster1/bat

DB_NAME=bat
DB_USER=bat
DB_PASS_FILE=/root/.bat-db-pass

echo "=== BAT idempotent bootstrap 1.1 ==="

############################################
# 1. Java 21 + Maven
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
# 2. MariaDB
############################################
if ! command -v mariadb >/dev/null; then
  apt install -y mariadb-server
  systemctl enable mariadb
  systemctl start mariadb
fi

############################################
# 3. DB password
############################################
if [ ! -f "$DB_PASS_FILE" ]; then
  openssl rand -base64 24 > "$DB_PASS_FILE"
fi
DB_PASS=$(cat "$DB_PASS_FILE")

############################################
# 4. DB + user
############################################
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

############################################
# 5. Linux user
############################################
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -r -m -d ${APP_DIR} -s /bin/bash ${APP_USER}
fi

############################################
# 6. Git checkout / update
############################################
if [ ! -d "$APP_DIR/.git" ]; then
  echo "Cloning repository..."
  sudo -u ${APP_USER} git clone ${GIT_REPO} ${APP_DIR}
else
  echo "Updating repository..."
  cd ${APP_DIR}
  sudo -u ${APP_USER} git fetch --all
  sudo -u ${APP_USER} git reset --hard origin/main
fi

############################################
# 7. Build
############################################
cd ${APP_DIR}
sudo -u ${APP_USER} mvn clean package -DskipTests

JAR=$(ls target/*.jar | head -n1)

############################################
# 8. App config
############################################
cat > ${APP_DIR}/application.properties <<EOF
spring.datasource.url=jdbc:mariadb://localhost:3306/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASS}
spring.jpa.hibernate.ddl-auto=update
server.port=8080
EOF

chown ${APP_USER}:${APP_USER} ${APP_DIR}/application.properties

############################################
# 9. systemd service
############################################
cat > /etc/systemd/system/bat.service <<EOF
[Unit]
Description=BAT Server
After=network.target mariadb.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/java -jar ${JAR} --spring.config.location=${APP_DIR}/application.properties
Restart=always
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bat
systemctl restart bat

############################################
# 10. Output
############################################
IP=$(hostname -I | awk '{print $1}')

echo "===================================="
echo " BAT is running"
echo " URL: http://${IP}:8080"
echo " DB: ${DB_NAME}"
echo " DB User: ${DB_USER}"
echo " DB Pass: ${DB_PASS}"
echo " Re-run safe ✔"
echo "===================================="
