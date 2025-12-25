#!/bin/bash

# =========================================================================
# Script: setup_vagrant_windows.sh
# Fixes the MySQL permission issue common on Windows hosts.
# =========================================================================

# 1) Create directories (on Windows, ~ usually points to your User folder)
echo "--- Step 1: Creating directories ---"
mkdir -p ~/TP/site_web
mkdir -p ~/TP/mysql_data
PROJECT_DIR="vagrant_tp_multi"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# 2, 4, 5, 6) Create the Vagrantfile with specific fixes for Windows
echo "--- Step 2: Creating Vagrantfile ---"
cat <<EOF > Vagrantfile
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"

  # --- VM Web (Apache) ---
  config.vm.define "web" do |web|
    web.vm.hostname = "web-server"
    web.vm.network "private_network", ip: "192.168.56.10"
    
    # Standard sync for web works fine
    web.vm.synced_folder "~/TP/site_web", "/var/www/html", 
      owner: "www-data", group: "www-data"

    web.vm.provision "shell", inline: <<-SHELL
      apt-get update
      apt-get install -y apache2 php php-mysql mysql-client
      systemctl restart apache2
    SHELL
  end

  # --- VM Database (MySQL) ---
  config.vm.define "db" do |db|
    db.vm.hostname = "db-server"
    db.vm.network "private_network", ip: "192.168.56.11"
    
    # FIX FOR WINDOWS: 
    # We pre-emptively map the shared folder to UID 111 (default for mysql on Ubuntu)
    # and use fmode/dmode to give full permissions.
    db.vm.synced_folder "~/TP/mysql_data", "/var/lib/mysql",
      owner: "111", group: "121", mount_options: ["dmode=775", "fmode=664"]

    db.vm.provision "shell", inline: <<-SHELL
      export DEBIAN_FRONTEND=noninteractive
      
      # Pre-create the mysql user with fixed IDs so the mount ownership matches
      groupadd -g 121 mysql || true
      useradd -u 111 -g 121 -s /bin/false -d /var/lib/mysql mysql || true
      
      apt-get update
      apt-get install -y mysql-server
      
      # Allow remote connections
      sed -i "s/127.0.0.1/0.0.0.0/" /etc/mysql/mysql.conf.d/mysqld.cnf
      systemctl restart mysql
      
      # Create a test database and user
      mysql -e "CREATE DATABASE IF NOT EXISTS testdb;"
      mysql -e "CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY 'password';"
      mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%';"
      mysql -e "FLUSH PRIVILEGES;"
    SHELL
  end
end
EOF

# 7) Start the machines
echo "--- Step 7: Starting Vagrant machines ---"
# We run 'destroy' first in case of a previous failed attempt to clean the state
vagrant destroy -f
vagrant up

# 9) Create test file
echo "--- Step 9: Creating test site ---"
cat <<EOF > ~/TP/site_web/index.php
<?php
\$conn = new mysqli("192.168.56.11", "admin", "password");
if (\$conn->connect_error) {
    echo "<h1>Connection Failed</h1>" . \$conn->connect_error;
} else {
    echo "<h1>Success!</h1><p>Connected to MySQL from Apache.</p>";
}
?>
EOF

# 8) Test connection
echo "--- Step 8: Testing DB connection from Web VM ---"
vagrant ssh web -c "mysql -h 192.168.56.11 -u admin -ppassword -e 'SHOW DATABASES;'"

echo "--------------------------------------------------"
echo "Setup finished!"
echo "Access the site at: http://192.168.56.10"
echo "Press Enter to destroy the environment..."
read
vagrant destroy -f