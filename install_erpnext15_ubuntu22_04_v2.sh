#!/bin/bash

# Exit on error
set -e

# Immediate debug output to stderr
echo "Starting script execution at $(date)" >&2

# Initialize log file
LOG_FILE="/var/log/erpnext_install_$(date +%Y%m%d_%H%M%S).log"
echo "[$(date +%Y-%m-%d_%H:%M:%S)] Starting installation, logging to $LOG_FILE" | tee -a "$LOG_FILE" >&2

# Function to log messages
log() {
    echo "[$(date +%Y-%m-%d_%H:%M:%S)] $1" | tee -a "$LOG_FILE" >&2
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate user input with retries and timeout
validate_input() {
    local input_name="$2"
    local input_value=""
    local attempts=3
    local count=0
    while [ $count -lt $attempts ]; do
        echo "Enter $input_name (timeout 30s):" >&2
        read -t 30 -r input_value
        if [ $? -eq 0 ] && [ -n "$input_value" ]; then
            echo "$input_value"
            log "$input_name provided: $input_value"
            return
        fi
        count=$((count + 1))
        log "Error: $input_name empty or timed out. Attempt $count/$attempts."
        if [ $count -eq $attempts ]; then
            log "Error: Failed to provide $input_name after $attempts attempts."
            exit 1
        fi
    done
}

# Function to validate sensitive input (e.g., passwords) with retries and timeout
validate_sensitive_input() {
    local input_name="$2"
    local input_value=""
    local attempts=3
    local count=0
    while [ $count -lt $attempts ]; do
        echo "Enter $input_name (timeout 30s):" >&2
        read -t 30 -s input_value
        echo >&2
        if [ $? -eq 0 ] && [ -n "$input_value" ]; then
            echo "$input_value"
            log "$input_name provided."
            return
        fi
        count=$((count + 1))
        log "Error: $input_name empty or timed out. Attempt $count/$attempts."
        if [ $count -eq $attempts ]; then
            log "Error: Failed to provide $input_name after $attempts attempts."
            exit 1
        fi
    done
}

# Function to check if a port is in use
check_port() {
    local port=$1
    if sudo netstat -tuln | grep -q ":$port "; then
        log "Error: Port $port is already in use."
        exit 1
    fi
}

log "Verifying bash execution..."
if [ -z "$BASH_VERSION" ]; then
    log "Error: This script must be run with bash, not sh or another shell. Run with: sudo bash $0"
    exit 1
fi
log "Running with bash version: $BASH_VERSION"

echo "=== ERPNext 15, HRMS 15, Chat, and wkhtmltopdf Installation Script for Ubuntu 22.04 ===" >&2

# Step 1: Prompt for inputs
log "Prompting for user inputs..."
echo "Do you want to create a new user for Frappe Bench? (y/n, default: y, timeout 30s)" >&2
read -t 30 -r create_new_user
if [ $? -ne 0 ]; then
    log "Error: Timed out waiting for create_new_user input. Using default: y"
    create_new_user="y"
else
    create_new_user=${create_new_user:-y}
    log "Create new user response: $create_new_user"
fi

if [ "$create_new_user" = "y" ] || [ "$create_new_user" = "Y" ]; then
    frappe_user=$(validate_input "frappe_user" "Frappe Bench username")
    log "Frappe Bench username entered: $frappe_user"
    if id "$frappe_user" >/dev/null 2>&1; then
        log "User $frappe_user already exists. Using existing user."
        frappe_user_password=$(validate_sensitive_input "frappe_user_password" "password for existing user $frappe_user")
        if ! groups "$frappe_user" | grep -q sudo; then
            log "Adding $frappe_user to sudo group..."
            sudo usermod -aG sudo "$frappe_user" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to add $frappe_user to sudo group."; exit 1; }
        fi
    else
        frappe_user_password=$(validate_sensitive_input "frappe_user_password" "password for new user $frappe_user")
    fi
else
    frappe_user=$(whoami)
    log "Using current user $frappe_user for Frappe Bench setup."
    if ! groups | grep -q sudo; then
        log "Error: Current user $frappe_user is not in the sudo group."
        exit 1
    fi
    frappe_user_password=""
fi

mysql_root_password=$(validate_sensitive_input "mysql_root_password" "MySQL root password to be set or existing password")
admin_password=$(validate_sensitive_input "admin_password" "Administrator password for ERPNext")
site_name=$(validate_input "site_name" "site name for ERPNext (e.g., erp.mysite.com)")

# Check if port 80 is free
check_port 80

# Step 2: Clean up existing configurations
log "Cleaning up existing Frappe Bench and Nginx configurations..."
if [ -d "/home/$frappe_user/frappe-bench" ]; then
    sudo rm -rf "/home/$frappe_user/frappe-bench"
    log "Removed existing Frappe Bench directory."
fi
if [ -f "/etc/nginx/sites-available/$site_name" ]; then
    sudo rm -f "/etc/nginx/sites-available/$site_name"
    sudo rm -f "/etc/nginx/sites-enabled/$site_name"
    log "Removed existing Nginx configuration for $site_name."
fi
if [ -d "/home/$frappe_user/.bench" ]; then
    sudo rm -rf "/home/$frappe_user/.bench"
    log "Removed existing .bench directory."
fi
if [ -f "wkhtmltox.deb" ]; then
    rm wkhtmltox.deb
    log "Removed existing wkhtmltox.deb file."
fi

# Step 3: Clean up existing MariaDB/MySQL installations
log "Cleaning up existing MariaDB/MySQL installations..."
sudo systemctl stop mariadb 2>/dev/null
sudo systemctl stop mysql 2>/dev/null
sudo killall -9 mysqld 2>/dev/null || true
sudo apt-get purge -y mariadb-server mariadb-client mariadb-server-10.6 mariadb-server-core-10.6 mysql-server mysql-client 2>&1 | tee -a "$LOG_FILE"
sudo rm -rf /var/lib/mysql /etc/mysql /var/log/mysql
log "Existing MariaDB/MySQL configurations removed."

# Step 4: Update system packages
log "Updating system packages..."
for attempt in {1..3}; do
    if sudo apt-get update -y >> "$LOG_FILE" 2>&1; then
        log "Package list updated successfully."
        break
    else
        log "Warning: Failed to update package list (attempt $attempt/3). Retrying..."
        sleep 5
    fi
    if [ $attempt -eq 3 ]; then
        log "Error: Failed to update package list after 3 attempts. Check network connectivity or apt sources."
        exit 1
    fi
done
if ! sudo apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to upgrade packages. Trying to fix broken dependencies..."
    sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not fix dependencies."; exit 1; }
fi
sudo apt-get install -y sosreport >> "$LOG_FILE" 2>&1 || log "Warning: Failed to install sosreport, continuing..."

# Step 5: Install Node.js 18
log "Checking for existing Node.js installation..."
if command_exists node; then
    node_version=$(node -v)
    if [[ "$node_version" =~ ^v18\. ]]; then
        log "Node.js $node_version already installed, skipping installation."
    else
        log "Error: Node.js version $node_version found, but ERPNext requires 18.x."
        exit 1
    fi
else
    log "Installing Node.js 18..."
    for attempt in {1..3}; do
        if curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >> "$LOG_FILE" 2>&1 && sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1; then
            log "Node.js installed successfully."
            break
        else
            log "Warning: Failed to install Node.js (attempt $attempt/3). Retrying..."
            sleep 5
        fi
        if [ $attempt -eq 3 ]; then
            log "Error: Failed to install Node.js from NodeSource. Trying Ubuntu repository..."
            sudo apt-get install -y nodejs npm >> "$LOG_FILE" 2>&1 || { log "Error: Could not install Node.js."; exit 1; }
        fi
    done
    export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/lib/node_modules
    if ! command_exists node; then
        log "Error: Node.js not found after installation. Checking alternative paths..."
        if [ -f /usr/local/bin/node ]; then
            log "Node.js found in /usr/local/bin. Adding to PATH."
            sudo ln -sf /usr/local/bin/node /usr/bin/node
        else
            log "Error: Node.js installation failed. Please check $LOG_FILE for details."
            exit 1
        fi
    fi
    node_version=$(node -v)
    if [[ ! "$node_version" =~ ^v18\. ]]; then
        log "Error: Installed Node.js version ($node_version) is not 18.x. ERPNext requires Node.js 18."
        exit 1
    fi
fi
if ! command_exists yarn; then
    log "Installing Yarn..."
    for attempt in {1..3}; do
        if sudo npm install -g yarn >> "$LOG_FILE" 2>&1; then
            log "Yarn installed successfully."
            break
        else
            log "Warning: Failed to install Yarn (attempt $attempt/3). Retrying..."
            sleep 5
        fi
        if [ $attempt -eq 3 ]; then
            log "Error: Failed to install Yarn. Ensuring npm is installed..."
            sudo apt-get install -y npm >> "$LOG_FILE" 2>&1 || { log "Error: Could not install npm."; exit 1; }
            sudo npm install -g yarn >> "$LOG_FILE" 2>&1 || { log "Error: Could not install Yarn."; exit 1; }
        fi
    done
fi
log "Node.js $node_version and Yarn $(yarn --version) installed or verified."

# Step 6: Install wkhtmltopdf with patched Qt
log "Checking for existing wkhtmltopdf installation..."
arch=$(dpkg --print-architecture)
if command_exists wkhtmltopdf; then
    wkhtmltopdf_version=$(wkhtmltopdf -V 2>&1 || true)
    log "wkhtmltopdf version output: $wkhtmltopdf_version"
    if echo "$wkhtmltopdf_version" | grep -q "0.12.6.1" && echo "$wkhtmltopdf_version" | grep -qi "patched qt"; then
        log "wkhtmltopdf 0.12.6.1 with patched Qt already installed, skipping installation."
    else
        log "Error: wkhtmltopdf installed, but incorrect version. Required: 0.12.6.1 with patched Qt. Found: $wkhtmltopdf_version"
        exit 1
    fi
else
    log "Installing wkhtmltopdf 0.12.6.1 with patched Qt for architecture $arch..."
    if [ "$arch" != "amd64" ] && [ "$arch" != "arm64" ]; then
        log "Error: Unsupported architecture $arch. Only amd64 and arm64 are supported."
        exit 1
    fi
    downloaded=false
    for attempt in {1..3}; do
        if wget "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_${arch}.deb" -O wkhtmltox.deb >> "$LOG_FILE" 2>&1; then
            log "Successfully downloaded wkhtmltopdf from GitHub."
            downloaded=true
            break
        else
            log "Warning: Failed to download wkhtmltopdf from GitHub (attempt $attempt/3). Retrying..."
            sleep 5
        fi
    done
    if [ "$downloaded" = false ]; then
        for attempt in {1..3}; do
            if wget "https://downloads.wkhtmltopdf.org/0.12/0.12.6.1/wkhtmltox_0.12.6.1-2.jammy_${arch}.deb" -O wkhtmltox.deb >> "$LOG_FILE" 2>&1; then
                log "Successfully downloaded wkhtmltopdf from fallback source."
                downloaded=true
                break
            else
                log "Warning: Failed to download wkhtmltopdf from fallback source (attempt $attempt/3). Retrying..."
                sleep 5
            fi
        done
    fi
    if [ "$downloaded" = false ]; then
        log "Error: Failed to download wkhtmltopdf from all sources after 3 attempts."
        exit 1
    fi
    if ! sudo dpkg -i wkhtmltox.deb >> "$LOG_FILE" 2>&1; then
        log "Error: Failed to install wkhtmltopdf. Attempting to fix dependencies..."
        sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install wkhtmltopdf."; exit 1; }
    fi
    rm wkhtmltox.deb
    export PATH=$PATH:/usr/local/bin:/usr/bin:/bin
    if ! command_exists wkhtmltopdf; then
        log "Error: wkhtmltopdf not found after installation. Checking alternative paths..."
        if [ -f /usr/local/bin/wkhtmltopdf ]; then
            log "wkhtmltopdf found in /usr/local/bin. Adding to PATH."
            sudo ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
        else
            log "Error: wkhtmltopdf not found in expected locations."
            exit 1
        fi
    fi
    wkhtmltopdf_version=$(wkhtmltopdf -V 2>&1 || true)
    log "wkhtmltopdf version output: $wkhtmltopdf_version"
    if ! echo "$wkhtmltopdf_version" | grep -q "0.12.6.1" || ! echo "$wkhtmltopdf_version" | grep -qi "patched qt"; then
        log "Error: wkhtmltopdf installed, but incorrect version. Required: 0.12.6.1 with patched Qt. Found: $wkhtmltopdf_version"
        exit 1
    fi
    sudo chmod +x /usr/local/bin/wkhtmltopdf 2>/dev/null || true
    sudo chmod +x /usr/bin/wkhtmltopdf 2>/dev/null || true
fi
log "wkhtmltopdf 0.12.6.1 with patched Qt installed or verified."

# Step 7: Install prerequisites
log "Installing prerequisites..."
for attempt in {1..3}; do
    if sudo apt-get install -y \
        python3.10 python3.10-dev python3.10-venv python3-pip \
        git curl wget software-properties-common \
        xvfb libfontconfig libmysqlclient-dev \
        redis-server nginx mariadb-server mariadb-client \
        xfonts-75dpi cron supervisor >> "$LOG_FILE" 2>&1; then
        log "Prerequisites installed successfully."
        break
    else
        log "Warning: Failed to install prerequisites (attempt $attempt/3). Retrying..."
        sleep 5
    fi
    if [ $attempt -eq 3 ]; then
        log "Error: Failed to install prerequisites. Trying to fix broken packages..."
        sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install prerequisites."; exit 1; }
    fi
done

# Verify key tools
for cmd in python3.10 npm git redis-server nginx mariadb; do
    if ! command_exists "$cmd"; then
        log "Error: $cmd not installed."
        exit 1
    fi
done
log "Prerequisites verified."

# Step 8: Configure MariaDB
log "Configuring MariaDB..."
sudo mkdir -p /var/log/mysql
sudo chown mysql:mysql /var/log/mysql
sudo chmod 755 /var/log/mysql
sudo tee /etc/mysql/mariadb.conf.d/50-server.cnf > /dev/null <<EOF
[mysqld]
log_error = /var/log/mysql/error.log
EOF
sudo systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { log "Error: Failed to reload systemd."; exit 1; }
if ! sudo systemctl is-active --quiet mariadb; then
    log "MariaDB service is not running. Attempting to initialize and start..."
    sudo mysql_install_db --user=mysql --datadir=/var/lib/mysql >> "$LOG_FILE" 2>&1 || { log "Error: Failed to initialize MariaDB data directory."; exit 1; }
    sudo systemctl start mariadb >> "$LOG_FILE" 2>&1 || { 
        log "Error: Could not start MariaDB. Checking logs..."
        sudo journalctl -xeu mariadb.service >> "$LOG_FILE" 2>&1
        exit 1
    }
fi
sudo systemctl enable mariadb >> "$LOG_FILE" 2>&1 || { log "Error: Failed to enable MariaDB."; exit 1; }

# Check if the provided root password works
log "Checking if MariaDB root password is valid..."
if sudo mysqladmin -u root -p"$mysql_root_password" ping >> "$LOG_FILE" 2>&1; then
    log "MariaDB root password is valid, skipping password reset."
else
    log "MariaDB root password not set or invalid, attempting to set it..."
    for attempt in {1..3}; do
        if sudo mysqladmin -u root password "$mysql_root_password" >> "$LOG_FILE" 2>&1; then
            log "MariaDB root password set successfully."
            break
        else
            log "Warning: Failed to set MariaDB root password (attempt $attempt/3). Retrying..."
            sleep 5
        fi
        if [ $attempt -eq 3 ]; then
            log "Error: Failed to set MariaDB root password. Please check if MariaDB is properly installed or reset the root password manually."
            exit 1
        fi
    done
fi

# Secure MariaDB using SQL commands
log "Securing MariaDB with SQL commands..."
sudo mysql -u root -p"$mysql_root_password" -e "
    SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$mysql_root_password');
    DELETE FROM mysql.user WHERE User='' OR (User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'));
    DROP DATABASE IF EXISTS test;
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;
" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "Error: Failed to secure MariaDB with SQL commands."
    exit 1
fi

# Configure MariaDB character set
sudo tee /etc/mysql/mariadb.conf.d/99-erpnext.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF
if ! sudo systemctl restart mariadb >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to restart MariaDB."
    exit 1
fi
log "MariaDB configured and running."

# Step 9: Create Frappe Bench user
if [ "$create_new_user" = "y" ] || [ "$create_new_user" = "Y" ]; then
    if ! id "$frappe_user" >/dev/null 2>&1; then
        log "Creating user $frappe_user..."
        if ! sudo adduser --disabled-login --gecos "" "$frappe_user" >> "$LOG_FILE" 2>&1; then
            log "Error: Failed to create user $frappe_user."
            exit 1
        fi
        log "Setting password for user $frappe_user..."
        echo "$frappe_user:$frappe_user_password" | sudo chpasswd >> "$LOG_FILE" 2>&1 || { log "Error: Failed to set password for $frappe_user."; exit 1; }
        sudo usermod -aG sudo "$frappe_user"
    fi
    log "Configuring sudoers for $frappe_user to run supervisorctl without password..."
    echo "$frappe_user ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl" | sudo tee /etc/sudoers.d/$frappe_user >> "$LOG_FILE" 2>&1
    sudo chmod 0440 /etc/sudoers.d/$frappe_user
    log "User $frappe_user verified or created with sudo privileges."
fi

# Step 10: Install Frappe Bench
log "Installing Frappe Bench..."
for attempt in {1..3}; do
    if sudo pip3 install frappe-bench >> "$LOG_FILE" 2>&1; then
        log "Frappe Bench installed successfully."
        break
    else
        log "Warning: Failed to install frappe-bench (attempt $attempt/3). Updating pip..."
        sudo pip3 install --upgrade pip >> "$LOG_FILE" 2>&1 || { log "Error: Could not update pip."; exit 1; }
    fi
    if [ $attempt -eq 3 ]; then
        log "Error: Failed to install frappe-bench after 3 attempts."
        exit 1
    fi
done
if ! command_exists bench; then
    log "Error: Frappe Bench not found after installation."
    exit 1
fi
log "Frappe Bench installed."

# Step 11: Set up Frappe Bench and apps
log "Setting up Frappe Bench as $frappe_user..."
if [ "$create_new_user" = "y" ] || [ "$create_new_user" = "Y" ]; then
    cd /home/$frappe_user || { log "Error: Failed to change to /home/$frappe_user"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench init --frappe-branch version-15 frappe-bench" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to initialize Frappe Bench"; exit 1; }
    cd /home/$frappe_user/frappe-bench || { log "Error: Failed to change to frappe-bench directory"; exit 1; }
    sudo -u "$frappe_user" bash -c "yarn add less@4 stylus@0.63.0 vue-template-compiler@2.7.16" >> "$LOG_FILE" 2>&1 || log "Warning: Failed to install optional yarn dependencies."
    for i in 1 2 3; do
        if sudo -u "$frappe_user" bash -c "yarn install --check-files" >> "$LOG_FILE" 2>&1; then
            break
        else
            log "Warning: yarn install failed, retrying ($i/3)..."
            sleep 5
        fi
        if [ $i -eq 3 ]; then
            log "Error: Failed to run yarn install after 3 attempts."
            exit 1
        fi
    done
    sudo -u "$frappe_user" bash -c "bench set-config -g developer_mode true" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to set developer_mode"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench new-site $site_name --db-root-password \"$mysql_root_password\" --admin-password \"$admin_password\"" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to create site $site_name"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench get-app payments" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get payments app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench get-app --branch version-15 erpnext" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get ERPNext app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench get-app --branch version-15 hrms" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get HRMS app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench get-app --branch version-15 frappe_chat" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get Frappe Chat app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench --site $site_name install-app erpnext" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install ERPNext app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench --site $site_name install-app hrms" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install HRMS app"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench --site $site_name install-app frappe_chat" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install Frappe Chat app"; exit 1; }
else
    cd /home/$frappe_user || { log "Error: Failed to change to /home/$frappe_user"; exit 1; }
    for attempt in {1..3}; do
        if bench init --frappe-branch version-15 frappe-bench >> "$LOG_FILE" 2>&1; then
            break
        else
            log "Warning: Failed to initialize Frappe Bench (attempt $attempt/3). Retrying..."
            sleep 5
        fi
        if [ $attempt -eq 3 ]; then
            log "Error: Failed to initialize Frappe Bench."
            exit 1
        fi
    done
    cd frappe-bench || { log "Error: Failed to change to frappe-bench directory"; exit 1; }
    yarn add less@4 stylus@0.63.0 vue-template-compiler@2.7.16 >> "$LOG_FILE" 2>&1 || log "Warning: Failed to install optional yarn dependencies."
    for i in 1 2 3; do
        if yarn install --check-files >> "$LOG_FILE" 2>&1; then
            break
        else
            log "Warning: yarn install failed, retrying ($i/3)..."
            sleep 5
        fi
        if [ $i -eq 3 ]; then
            log "Error: Failed to run yarn install after 3 attempts."
            exit 1
        fi
    done
    bench set-config -g developer_mode true >> "$LOG_FILE" 2>&1 || { log "Error: Failed to set developer_mode"; exit 1; }
    bench new-site "$site_name" --db-root-password "$mysql_root_password" --admin-password "$admin_password" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to create site $site_name"; exit 1; }
    bench get-app payments >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get payments app"; exit 1; }
    bench get-app --branch version-15 erpnext >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get ERPNext app"; exit 1; }
    bench get-app --branch version-15 hrms >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get HRMS app"; exit 1; }
    bench get-app --branch version-15 frappe_chat >> "$LOG_FILE" 2>&1 || { log "Error: Failed to get Frappe Chat app"; exit 1; }
    bench --site "$site_name" install-app erpnext >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install ERPNext app"; exit 1; }
    bench --site "$site_name" install-app hrms >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install HRMS app"; exit 1; }
    bench --site "$site_name" install-app frappe_chat >> "$LOG_FILE" 2>&1 || { log "Error: Failed to install Frappe Chat app"; exit 1; }
fi
log "Frappe Bench and apps installed."

# Step 12: Configure production setup
log "Configuring production setup to serve on port 80..."
if [ "$create_new_user" = "y" ] || [ "$create_new_user" = "Y" ]; then
    cd /home/$frappe_user/frappe-bench || { log "Error: Failed to change to frappe-bench directory"; exit 1; }
    sudo -u "$frappe_user" bash -c "bench setup production $frappe_user --yes" >> "$LOG_FILE" 2>&1 || { log "Error: Failed to set up production environment"; exit 1; }
else
    cd /home/$frappe_user/frappe-bench || { log "Error: Failed to change to frappe-bench directory"; exit 1; }
    bench setup production "$frappe_user" --yes >> "$LOG_FILE" 2>&1 || { log "Error: Failed to set up production environment"; exit 1; }
fi

# Step 13: Ensure Nginx configuration for port 80
log "Configuring Nginx to serve on port 80..."
sudo tee /etc/nginx/sites-available/$site_name > /dev/null <<EOF
server {
    listen 80;
    server_name $site_name;
    root /home/$frappe_user/frappe-bench/sites;
    client_max_body_size 20M;

    location / {
        try_files \$uri \$uri/ /index.py;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_pass http://127.0.0.1:8000;
    }

    location /assets/ {
        try_files \$uri =404;
    }

    location /private/ {
        internal;
        try_files \$uri =404;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Frappe-Site-Name \$http_host;
        proxy_pass http://127.0.0.1:9000;
    }
}
EOF
if ! sudo ln -sf /etc/nginx/sites-available/$site_name /etc/nginx/sites-enabled/$site_name >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to enable Nginx site."
    exit 1
fi
if ! sudo nginx -t >> "$LOG_FILE" 2>&1; then
    log "Error: Nginx configuration test failed. Check /etc/nginx/sites-available/$site_name."
    exit 1
fi
log "Nginx configured for port 80."

# Step 14: Start services
log "Starting Nginx and Supervisor services..."
if ! sudo systemctl enable nginx supervisor >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to enable services."
    exit 1
fi
if ! sudo systemctl restart nginx supervisor >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to restart services."
    exit 1
fi
if ! sudo systemctl is-active --quiet nginx; then
    log "Error: Nginx service is not running."
    exit 1
fi
if ! sudo systemctl is-active --quiet supervisor; then
    log "Error: Supervisor service is not running."
    exit 1
fi
log "Services started successfully."

# Step 15: Verify site on port 80
log "Verifying ERPNext site on port 80..."
sleep 5
for attempt in {1..3}; do
    if curl -s "http://$site_name" | grep -q "ERPNext"; then
        log "ERPNext is running successfully at http://$site_name"
        break
    else
        log "Warning: ERPNext site not accessible on port 80 (attempt $attempt/3). Retrying..."
        sleep 5
    fi
    if [ $attempt -eq 3 ]; then
        log "Error: ERPNext site is not accessible on port 80. Check Nginx logs in /var/log/nginx/ or Bench logs in /home/$frappe_user/frappe-bench/logs."
        exit 1
    fi
done

echo "=== Installation Complete ===" >&2
log "Installation completed successfully."
echo "Access ERPNext at: http://$site_name" >&2
echo "Admin Username: Administrator" >&2
echo "Admin Password: $admin_password" >&2
echo "Frappe Bench directory: /home/$frappe_user/frappe-bench" >&2
echo "Logs available at: $LOG_FILE" >&2
echo "To start the bench manually, run: sudo -u $frappe_user bash -c 'cd /home/$frappe_user/frappe-bench && bench start'" >&2
if [ "$create_new_user" = "y" ] || [ "$create_new_user" = "Y" ]; then
    echo "Frappe user: $frappe_user" >&2
    echo "Frappe user password: [hidden for security, use the password you provided]" >&2
fi
