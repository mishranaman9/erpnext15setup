#!/bin/bash

set -e

LOG_FILE="/var/log/erpnext_install_$(date +%F_%H-%M-%S).log"
echo "Logging installation to $LOG_FILE"

log() {
    echo "[$(date +%F_%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

validate_input() {
    if [ -z "$1" ]; then
        log "Input cannot be empty."
        exit 1
    fi
}

# === Step 1: User Prompts ===
read -rp "Enter Frappe system user (e.g., frappe): " frappe_user
validate_input "$frappe_user"

read -srp "Enter password for Linux system user '$frappe_user': " frappe_user_pass; echo
read -srp "Confirm password: " frappe_user_pass_confirm; echo

if [ "$frappe_user_pass" != "$frappe_user_pass_confirm" ]; then
    log "Error: Passwords do not match!"
    exit 1
fi

read -srp "Enter MySQL root password to set: " mysql_root_password; echo
read -srp "Enter ERPNext Admin password: " admin_password; echo
read -rp "Enter Site Name (e.g., erp.mysite.com): " site_name
validate_input "$site_name"

# === Step 2: Update & Install Essentials ===
log "Updating APT and installing essentials..."
sudo apt-get update -y
sudo apt-get install -y software-properties-common apt-transport-https curl ca-certificates gnupg lsb-release

log "Installing dependencies..."
sudo apt-get install -y python3.10 python3.10-dev python3.10-venv python3-pip git wget xvfb libfontconfig libmysqlclient-dev libxrender1 libxext6 xfonts-75dpi redis-server nginx mariadb-server mariadb-client cron supervisor

log "Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g yarn || (curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - && echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list && sudo apt-get update && sudo apt-get install -y yarn)

log "Installing wkhtmltopdf..."
wget -O wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo dpkg -i wkhtmltox.deb || sudo apt-get install -f -y
rm wkhtmltox.deb

# === Step 3: MariaDB Setup ===
log "Initializing MariaDB..."
sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
sudo systemctl start mariadb
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mysql_root_password'; FLUSH PRIVILEGES;"
sudo mysql_secure_installation

sudo tee /etc/mysql/mariadb.conf.d/99-erpnext.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF

sudo systemctl restart mariadb

# === Step 4: Create Frappe System User ===
log "Creating Linux user $frappe_user..."
sudo adduser --disabled-password --gecos "" "$frappe_user"
echo "$frappe_user:$frappe_user_pass" | sudo chpasswd
sudo usermod -aG sudo "$frappe_user"

# === Step 5: Install Bench CLI and ERPNext ===
log "Installing Bench CLI..."
sudo pip3 install -U pip
sudo pip3 install frappe-bench honcho

log "Setting up ERPNext as $frappe_user..."
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
bench set-nginx-port $site_name 80
bench setup nginx
bench setup production $frappe_user
EOF

sudo systemctl restart nginx supervisor

log "ERPNext 15 installed successfully at http://$site_name"
echo "Admin Username: Administrator"
echo "Admin Password: $admin_password"
echo "Linux user: $frappe_user (password hidden)"
echo "Bench path: /home/$frappe_user/frappe-bench"
