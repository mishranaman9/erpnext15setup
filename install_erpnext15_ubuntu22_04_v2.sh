#!/bin/bash

# Exit on error
set -e

# Log file for debugging
LOG_FILE="/var/log/erpnext_install_$(date +%F_%H-%M-%S).log"
echo "Logging installation details to $LOG_FILE"

# Function to log messages
log() {
    echo "[$(date +%F_%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate user input
validate_input() {
    if [ -z "$1" ]; then
        log "Error: Input cannot be empty."
        exit 1
    fi
}

# Function to check if a port is in use
check_port() {
    local port=$1
    if sudo netstat -tuln | grep -q ":$port "; then
        log "Error: Port $port is already in use."
        exit 1
    fi
}

echo "=== ERPNext 15, HRMS 15, Chat, and wkhtmltopdf Installation Script for Ubuntu 22.04 ==="

# Step 1: Prompt for inputs
log "Prompting for user inputs..."
echo "Enter the username for the Frappe Bench user (e.g., frappe):"
read -r frappe_user
validate_input "$frappe_user"
if id "$frappe_user" >/dev/null 2>&1; then
    log "Error: User $frappe_user already exists."
    exit 1
fi

echo "Enter the MySQL root password to be set:"
read -s mysql_root_password
validate_input "$mysql_root_password"
echo

echo "Enter the Administrator password for ERPNext:"
read -s admin_password
validate_input "$admin_password"
echo

echo "Enter the site name for ERPNext (e.g., erp.mysite.com):"
read -r site_name
validate_input "$site_name"

# Check if port 80 is free
check_port 80

# Step 2: Update system packages
log "Updating system packages..."
if ! sudo apt-get update -y >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to update package list. Check network connectivity or apt sources."
    exit 1
fi
if ! sudo apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to upgrade packages. Trying to fix broken dependencies..."
    sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not fix dependencies."; exit 1; }
fi

# Step 3: Install Node.js 18
log "Installing Node.js 18..."
# Attempt NodeSource repository first
if ! curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - >> "$LOG_FILE" 2>&1; then
    log "Warning: Failed to set up NodeSource repository. Trying alternative method..."
    # Fallback: Install Node.js from Ubuntu repository
    if ! sudo apt-get install -y nodejs npm >> "$LOG_FILE" 2>&1; then
        log "Error: Failed to install Node.js from Ubuntu repository. Trying to fix dependencies..."
        sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install Node.js."; exit 1; }
    fi
else
    if ! sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1; then
        log "Error: Failed to install Node.js from NodeSource. Trying to fix dependencies..."
        sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install Node.js."; exit 1; }
    fi
fi
# Update PATH to include common Node.js locations
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/lib/node_modules
# Verify Node.js installation
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
# Verify Node.js version (ensure it's 18.x)
node_version=$(node -v)
if [[ ! "$node_version" =~ ^v18\. ]]; then
    log "Error: Installed Node.js version ($node_version) is not 18.x. ERPNext requires Node.js 18."
    exit 1
fi
# Install Yarn
if ! sudo npm install -g yarn >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to install Yarn. Ensuring npm is installed..."
    sudo apt-get install -y npm >> "$LOG_FILE" 2>&1 || { log "Error: Could not install npm."; exit 1; }
    sudo npm install -g yarn >> "$LOG_FILE" 2>&1 || { log "Error: Could not install Yarn."; exit 1; }
fi
log "Node.js $node_version and Yarn $(yarn --version) installed."

# Step 4: Install prerequisites
log "Installing prerequisites..."
if ! sudo apt-get install -y \
    python3.10 python3.10-dev python3.10-venv python3-pip \
    git curl wget software-properties-common \
    xvfb libfontconfig libmysqlclient-dev \
    redis-server nginx mariadb-server mariadb-client \
    xfonts-75dpi cron supervisor >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to install prerequisites. Trying to fix broken packages..."
    sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install prerequisites."; exit 1; }
fi

# Verify key tools
for cmd in python3.10 npm git redis-server nginx mariadb wkhtmltopdf; do
    if ! command_exists "$cmd"; then
        log "Error: $cmd not installed."
        exit 1
    fi
done
log "Prerequisites verified."

# Step 5: Install wkhtmltopdf with patched Qt
log "Installing wkhtmltopdf 0.12.6.1 with patched Qt..."
if ! wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb -O wkhtmltox.deb >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to download wkhtmltopdf."
    exit 1
fi
if ! sudo dpkg -i wkhtmltox.deb >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to install wkhtmltopdf. Attempting to fix dependencies..."
    sudo apt-get install -f -y >> "$LOG_FILE" 2>&1 || { log "Error: Could not install wkhtmltopdf."; exit 1; }
fi
rm wkhtmltox.deb
if wkhtmltopdf -V | grep -q "0.12.6.1 with patched qt"; then
    log "wkhtmltopdf 0.12.6.1 with patched Qt installed successfully."
else
    log "Error: wkhtmltopdf installation failed or incorrect version."
    exit 1
fi

# Step 6: Configure MariaDB
log "Configuring MariaDB..."
if ! sudo systemctl is-active --quiet mariadb; then
    log "Error: MariaDB service is not running. Starting it..."
    sudo systemctl start mariadb >> "$LOG_FILE" 2>&1 || { log "Error: Could not start MariaDB."; exit 1; }
fi
if ! sudo mysqladmin -u root password "$mysql_root_password" >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to set MariaDB root password. It may already be set. Please verify."
    exit 1
fi
sudo mysql_secure_installation <<EOF >> "$LOG_FILE" 2>&1
$mysql_root_password
Y
$mysql_root_password
$mysql_root_password
Y
N
Y
Y
EOF
if [ $? -ne 0 ]; then
    log "Error: MariaDB secure installation failed."
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

# Step 7: Create Frappe Bench user
log "Creating user $frappe_user..."
if ! sudo adduser --disabled-password --gecos "" "$frappe_user" >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to create user $frappe_user."
    exit 1
fi
sudo usermod -aG sudo "$frappe_user"
log "User $frappe_user created."

# Step 8: Install Frappe Bench
log "Installing Frappe Bench..."
if ! sudo pip3 install frappe-bench >> "$LOG_FILE" 2>&1; then
    log "Error: Failed to install frappe-bench. Updating pip..."
    sudo pip3 install --upgrade pip >> "$LOG_FILE" 2>&1 || { log "Error: Could not update pip."; exit 1; }
    sudo pip3 install frappe-bench >> "$LOG_FILE" 2>&1 || { log "Error: Could not install frappe-bench."; exit 1; }
fi
if ! command_exists bench; then
    log "Error: Frappe Bench not found after installation."
    exit 1
fi
log "Frappe Bench installed."

# Step 9: Set up Frappe Bench and apps
log "Setting up Frappe Bench as $frappe_user..."
sudo -u "$frappe_user" bash <<EOF >> "$LOG_FILE" 2>&1
cd /home/$frappe_user
if ! bench init --frappe-branch version-15 frappe-bench; then
    echo "Error: Failed to initialize Frappe Bench." >> "$LOG_FILE"
    exit 1
fi
cd frappe-bench
bench set-config -g developer_mode true
if ! bench new-site $site_name --db-root-password "$mysql_root_password" --admin-password "$admin_password"; then
    echo "Error: Failed to create site $site_name." >> "$LOG_FILE"
    exit 1
fi
if ! bench get-app payments; then
    echo "Error: Failed to get payments app." >> "$LOG_FILE"
    exit 1
fi
if ! bench get-app --branch version-15 erpnext; then
    echo "Error: Failed to get ERPNext app." >> "$LOG_FILE"
    exit 1
fi
if ! bench get-app --branch version-15 hrms; then
    echo "Error: Failed to get HRMS app." >> "$LOG_FILE"
    exit 1
fi
if ! bench get-app --branch version-15 frappe_chat; then
    echo "Error: Failed to get Frappe Chat app." >> "$LOG_FILE"
    exit 1
fi
if ! bench --site $site_name install-app erpnext; then
    echo "Error: Failed to install ERPNext app." >> "$LOG_FILE"
    exit 1
fi
if ! bench --site $site_name install-app hrms; then
    echo "Error: Failed to install HRMS app." >> "$LOG_FILE"
    exit 1
fi
if ! bench --site $site_name install-app frappe_chat; then
    echo "Error: Failed to install Frappe Chat app." >> "$LOG_FILE"
    exit 1
fi
EOF
if [ $? -ne 0 ]; then
    log "Error: Frappe Bench setup failed. Check logs in $LOG_FILE."
    exit 1
fi
log "Frappe Bench and apps installed."

# Step 10: Configure production setup
log "Configuring production setup to serve on port 80..."
sudo -u "$frappe_user" bash <<EOF >> "$LOG_FILE" 2>&1
cd /home/$frappe_user/frappe-bench
if ! bench setup production "$frappe_user" --yes; then
    echo "Error: Failed to set up production environment." >> "$LOG_FILE"
    exit 1
fi
EOF
if [ $? -ne 0 ]; then
    log "Error: Production setup failed."
    exit 1
fi

# Step 11: Ensure Nginx configuration for port 80
log "Configuring Nginx to serve on port 80..."
sudo tee /etc/nginx/sites-available/$site_name > /dev/null <<EOF
server {
    listen 80;
    server_name $site_name;
    root /home/$frappe_user/frappe-bench/sites;
    client_max_body_size 20M;

    location / {
        try_files /\$uri /\$uri/ /index.py;
        rewrite ^(.*/assets/.*\\.(css|js|jpg|jpeg|gif|png|svg|ico))\$ /\$1 break;
    }

    location /private/ {
        internal;
        try_files /\$uri =404;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Frappe-Site-Name \$http_host;
        proxy_pass http://127.0.0.1:9000;
    }

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_pass http://127.0.0.1:8000;
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

# Step 12: Start services
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

# Step 13: Verify site on port 80
log "Verifying ERPNext site on port 80..."
sleep 5 # Wait for services to stabilize
if curl -s "http://$site_name" | grep -q "ERPNext"; then
    log "ERPNext is running successfully at http://$site_name"
else
    log "Error: ERPNext site is not accessible on port 80. Check Nginx logs in /var/log/nginx/ or Bench logs in /home/$frappe_user/frappe-bench/logs."
    exit 1
fi

echo "=== Installation Complete ==="
log "Installation completed successfully."
echo "Access ERPNext at: http://$site_name"
echo "Admin Username: Administrator"
echo "Admin Password: $admin_password"
echo "Frappe Bench directory: /home/$frappe_user/frappe-bench"
echo "Logs available at: $LOG_FILE"
echo "To start the bench manually, run: sudo -u $frappe_user bash -c 'cd /home/$frappe_user/frappe-bench && bench start'"
