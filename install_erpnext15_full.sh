#!/bin/bash

set -e

LOG_FILE="/var/log/erpnext_install_$(date +%F_%H-%M-%S).log"
echo "Logging installation to $LOG_FILE"

log() {
    echo "[$(date +%F_%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_input() {
    if [ -z "$1" ]; then
        log "Input cannot be empty."
        exit 1
    fi
}

# === Step 0: Fix any interrupted dpkg operations ===
log "Checking and fixing dpkg lock or interrupted installations..."
if [ -f /var/lib/dpkg/lock ]; then
    log "dpkg lock file detected. Waiting for any ongoing process to complete..."
    sleep 10
fi

sudo dpkg --configure -a || {
    log "Failed to configure dpkg packages. Manual intervention may be needed."
    exit 1
}

sudo apt-get install -f -y || {
    log "Failed to fix broken dependencies with apt-get install -f."
    exit 1
}

# === Step 1: User Prompts ===
log "Starting ERPNext 15 Installation"
read -rp "Enter Frappe system user (e.g., frappe): " frappe_user
validate_input "$frappe_user"

read -srp "Enter MySQL root password to set: " mysql_root_password; echo
read -srp "Enter ERPNext Admin password: " admin_password; echo
read -rp "Enter Site Name (e.g., erp.mysite.com): " site_name
validate_input "$site_name"

if id "$frappe_user" >/dev/null 2>&1; then
    log "User $frappe_user already exists. Exiting."
    exit 1
fi

# === Step 2: Basic Package Update ===
log "Updating apt and installing core transport packages..."
sudo apt-get update -y
sudo apt-get install -y software-properties-common apt-transport-https curl ca-certificates gnupg lsb-release

# === Step 3: Install Dependencies ===
log "Installing prerequisites..."
sudo apt-get install -y \
    python3.10 python3.10-dev python3.10-venv python3-pip \
    git wget xvfb libfontconfig libmysqlclient-dev libxrender1 libxext6 xfonts-75dpi \
    redis-server nginx mariadb-server mariadb-client cron supervisor

# === Step 4: Node.js 18 with Fallback ===
log "Installing Node.js 18 with fallback..."
if ! command_exists node || ! node -v | grep -q "v18"; then
    curl -fsSL https://deb.nodesource.com/setup_18.x -o nodesetup.sh
    if ! sudo bash nodesetup.sh; then
        curl -LO https://nodejs.org/dist/v18.18.2/node-v18.18.2-linux-x64.tar.xz
        sudo mkdir -p /usr/local/lib/nodejs
        sudo tar -xJf node-v18.18.2-linux-x64.tar.xz -C /usr/local/lib/nodejs
        export PATH=/usr/local/lib/nodejs/node-v18.18.2-linux-x64/bin:$PATH
        echo 'export PATH=/usr/local/lib/nodejs/node-v18.18.2-linux-x64/bin:$PATH' >> ~/.bashrc
        source ~/.bashrc
    else
        sudo apt-get install -y nodejs
    fi
fi

log "Installing Yarn with fallback..."
if ! sudo npm install -g yarn; then
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
    sudo apt-get update -y
    sudo apt-get install -y yarn
fi

# === Step 5: wkhtmltopdf (Qt patched) ===
log "Installing wkhtmltopdf 0.12.6.1 with patched Qt..."
wget -O wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo dpkg -i wkhtmltox.deb || sudo apt-get install -f -y
rm wkhtmltox.deb

# === Step 6: MariaDB Setup ===
log "Configuring MariaDB..."
sudo systemctl enable mariadb --now
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mysql_root_password'; FLUSH PRIVILEGES;"
sudo mysql_secure_installation <<EOF
$mysql_root_password
Y
Y
Y
N
Y
Y
EOF

sudo tee /etc/mysql/mariadb.conf.d/99-erpnext.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF

sudo systemctl restart mariadb

# === Step 7: Create User ===
log "Creating frappe user..."
sudo adduser --disabled-password --gecos "" "$frappe_user"
sudo usermod -aG sudo "$frappe_user"

# === Step 8: Bench CLI ===
log "Installing Frappe Bench CLI..."
sudo pip3 install -U pip
sudo pip3 install frappe-bench honcho

# === Step 9: Frappe + Apps Setup ===
log "Setting up bench and apps..."
sudo -u "$frappe_user" bash <<EOF
cd /home/$frappe_user
bench init --frappe-branch version-15 frappe-bench
cd frappe-bench
bench new-site $site_name --mariadb-root-password $mysql_root_password --admin-password $admin_password
bench get-app payments
bench get-app --branch version-15 erpnext
bench get-app --branch version-15 hrms
bench get-app chat
bench --site $site_name install-app erpnext
bench --site $site_name install-app hrms
bench --site $site_name install-app chat
EOF

# === Step 10: Setup Production Mode + Force Port 80 Bind ===
log "Setting up ERPNext in production mode and ensuring Nginx binds to port 80..."

sudo -u "$frappe_user" bash <<EOF
cd /home/$frappe_user/frappe-bench
bench set-nginx-port $site_name 80
bench config dns_multitenant on
bench use $site_name
bench setup nginx
bench setup production $frappe_user
EOF

if ! grep -q "listen 80;" "/etc/nginx/sites-enabled/$site_name.conf"; then
    log "WARNING: Nginx config doesn't bind to port 80 explicitly. Forcing manual configuration..."

    sudo tee /etc/nginx/sites-available/$site_name > /dev/null <<NGINX_FALLBACK
server {
    listen 80;
    server_name $site_name;

    root /home/$frappe_user/frappe-bench/sites;

    client_max_body_size 50M;

    location / {
        try_files \$uri @webserver;
    }

    location @webserver {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frappe-Site-Name \$host;
    }

    location ~ ^/assets/.* {
        root /home/$frappe_user/frappe-bench/sites;
        access_log off;
        expires max;
        try_files \$uri =404;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:9000;
    }

    location /private/ {
        internal;
        try_files \$uri =404;
    }

    location /files/ {
        try_files \$uri =404;
    }
}
NGINX_FALLBACK

    sudo ln -sf /etc/nginx/sites-available/$site_name /etc/nginx/sites-enabled/$site_name
fi

sudo nginx -t
sudo systemctl reload nginx
log "Nginx configured and running on port 80 for $site_name"

log "ERPNext 15 setup completed successfully."
echo "Access ERPNext at: http://<your-server-ip> or http://$site_name"
echo "Username: Administrator"
echo "Password: $admin_password"
echo "Bench Directory: /home/$frappe_user/frappe-bench"
echo "Logs: $LOG_FILE"
