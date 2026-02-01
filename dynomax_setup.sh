#!/bin/bash

set -e
set -x

sudo chown -R bat:bat /opt/dynomax


cat > /etc/systemd/system/dynomax.service <<EOF
[Unit]
Description=dynomax Server
After=network.target mariadb.service

[Service]
User=bat
WorkingDirectory=/opt/dynomax
ExecStart=/usr/bin/java \
  -Dserver.port=8082 \
  -DSampleProviderIndex=1 \
  -DRDS_USERNAME=bat \
  -DRDS_PASSWORD=bat \
  -DRDS_HOSTNAME=localhost \
  -DRDS_PORT=3306 \
  -DRDS_DB_NAME=dynomax \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED \
  --add-opens java.base/java.text=ALL-UNNAMED \
  --add-opens java.desktop/java.awt.font=ALL-UNNAMED \
  -jar dynomax-web/target/dynomax-web.war
Restart=always

[Install]
WantedBy=multi-user.target
EOF


sudo systemctl daemon-reload
sudo systemctl start dynomax
sudo systemctl enable dynomax
