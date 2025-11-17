#!/bin/bash

### Kernel & limits for SonarQube / Elasticsearch
cp /etc/sysctl.conf /root/sysctl.conf_backup
cat <<EOT> /etc/sysctl.conf
vm.max_map_count=524288
fs.file-max=131072
EOT

cp /etc/security/limits.conf /root/sec_limit.conf_backup
cat <<EOT> /etc/security/limits.conf
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOT

# Apply sysctl changes
sysctl -p

### Java 17
sudo apt-get update -y
sudo apt-get install openjdk-17-jdk -y
# If only one JDK is installed this is optional / non-interactive
# sudo update-alternatives --config java

java -version

### PostgreSQL for SonarQube
sudo apt update -y
wget -q https://www.postgresql.org/media/keys/ACCC4CF8.asc -O - | sudo apt-key add -

sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" >> /etc/apt/sources.list.d/pgdg.list'
sudo apt install postgresql postgresql-contrib -y

sudo systemctl enable postgresql.service
sudo systemctl start  postgresql.service

sudo echo "postgres:admin123" | chpasswd

runuser -l postgres -c "createuser sonar"
sudo -i -u postgres psql -c "ALTER USER sonar WITH ENCRYPTED PASSWORD 'admin123';"
sudo -i -u postgres psql -c "CREATE DATABASE sonarqube OWNER sonar;"
sudo -i -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;"

systemctl restart postgresql
netstat -tulpena | grep postgres || true

### SonarQube 25.11.0.114957
SONARQUBE_VERSION=25.11.0.114957
SONAR_ZIP="sonarqube-${SONARQUBE_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

sudo mkdir -p /sonarqube/
cd /sonarqube/

sudo curl -O "${SONAR_URL}"

sudo apt-get install unzip -y
sudo unzip -o "${SONAR_ZIP}" -d /opt/

# Rename extracted directory to /opt/sonarqube for consistency
sudo mv "/opt/sonarqube-${SONARQUBE_VERSION}" /opt/sonarqube

### SonarQube user / permissions
sudo groupadd sonar || true
sudo useradd -c "SonarQube - User" -d /opt/sonarqube/ -g sonar sonar 2>/dev/null || true
sudo chown -R sonar:sonar /opt/sonarqube/

cp /opt/sonarqube/conf/sonar.properties /root/sonar.properties_backup

cat <<EOT> /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonar
sonar.jdbc.password=admin123
sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube

sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.web.javaAdditionalOpts=-server

sonar.search.javaOpts=-Xmx512m -Xms512m -XX:+HeapDumpOnOutOfMemoryError

sonar.log.level=INFO
sonar.path.logs=logs
EOT

### Systemd service for SonarQube 25.11
cat <<EOT> /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=syslog.target network.target postgresql.service

[Service]
Type=forking

ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop

User=sonar
Group=sonar
Restart=always

LimitNOFILE=131072
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable sonarqube.service
# systemctl start sonarqube.service
# systemctl status -l sonarqube.service

### Nginx reverse proxy
apt-get install nginx -y

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat <<EOT> /etc/nginx/sites-available/sonarqube
server{
    listen      80;
    server_name sonarqube.groophy.in;

    access_log  /var/log/nginx/sonar.access.log;
    error_log   /var/log/nginx/sonar.error.log;

    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    location / {
        proxy_pass  http://127.0.0.1:9000;
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_redirect off;

        proxy_set_header    Host            \$host;
        proxy_set_header    X-Real-IP       \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto http;
    }
}
EOT

ln -s /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/sonarqube
systemctl enable nginx.service
# systemctl restart nginx.service

sudo ufw allow 80,9000,9001/tcp || true

echo "System reboot in 30 sec"
sleep 30
reboot
