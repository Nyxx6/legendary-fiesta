#!/bin/bash

# =========================================================================
# Lab: Deploying CodeIgniter 4 with Ansible Roles on LXD
# =========================================================================

set -e

PROJECT_DIR="tpansible-ci4"
CONTAINER_NAME="ci4-server"

echo "--- Step 1: Preparing LXD Container (The Remote Server) ---"
lxc delete -f $CONTAINER_NAME >/dev/null 2>&1 || true
lxc launch ubuntu:22.04 $CONTAINER_NAME
echo "Waiting for container to boot..."
sleep 10

# Create project structure
mkdir -p $PROJECT_DIR/roles/{nginx,php,mysql,app}/{tasks,templates,handlers,defaults}
cd $PROJECT_DIR

# -------------------------------------------------------------------------
# 2. Ansible Infrastructure
# -------------------------------------------------------------------------
cat <<EOF > ansible.cfg
[defaults]
inventory = hosts.ini
roles_path = ./roles
EOF

cat <<EOF > hosts.ini
[webservers]
$CONTAINER_NAME ansible_connection=lxd
EOF

# -------------------------------------------------------------------------
# 3. Roles Definitions
# -------------------------------------------------------------------------

# --- ROLE: MYSQL ---
cat <<EOF > roles/mysql/tasks/main.yml
---
- name: Install MySQL
  apt: name={{ item }} state=present update_cache=yes
  with_items: [mysql-server, python3-mysqldb]

- name: Create Database
  mysql_db:
    name: "tpansible_db"
    state: present
    login_unix_socket: /var/run/mysqld/mysqld.sock

- name: Create User
  mysql_user:
    name: "tpansible_usr"
    password: "password123"
    priv: "tpansible_db.*:ALL"
    host: "localhost"
    state: present
    login_unix_socket: /var/run/mysqld/mysqld.sock
EOF

# --- ROLE: PHP ---
cat <<EOF > roles/php/tasks/main.yml
---
- name: Install PHP and Extensions for CI4
  apt:
    name: [php-fpm, php-mysql, php-intl, php-mbstring, php-curl, php-xml, php-gd, unzip]
    state: present
EOF

# --- ROLE: NGINX ---
cat <<EOF > roles/nginx/tasks/main.yml
---
- name: Install Nginx
  apt: name=nginx state=present

- name: Configure VHost
  template:
    src: ci4.conf.j2
    dest: /etc/nginx/sites-available/ci4
  notify: restart nginx

- name: Enable VHost
  file:
    src: /etc/nginx/sites-available/ci4
    dest: /etc/nginx/sites-enabled/ci4
    state: link

- name: Disable Default Site
  file: path=/etc/nginx/sites-enabled/default state=absent
  notify: restart nginx
EOF

cat <<EOF > roles/nginx/templates/ci4.conf.j2
server {
    listen 80;
    root /var/www/ci4/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}
EOF

cat <<EOF > roles/nginx/handlers/main.yml
---
- name: restart nginx
  service: name=nginx state=restarted
EOF

# --- ROLE: APP (CodeIgniter 4) ---
cat <<EOF > roles/app/tasks/main.yml
---
- name: Install Composer
  get_url:
    url: https://getcomposer.org/installer
    dest: /tmp/composer-setup.php

- name: Finalize Composer Install
  command: php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer creates=/usr/local/bin/composer

- name: Create Web Root
  file: path=/var/www/ci4 state=directory owner=www-data group=www-data

- name: Deploy CI4 App Starter via Composer
  command: composer create-project codeigniter4/appstarter . chdir=/var/www/ci4
  args:
    creates: /var/www/ci4/spark

- name: Configure .env file
  template:
    src: env.j2
    dest: /var/www/ci4/.env
    owner: www-data
    group: www-data

- name: Set Writable Permissions
  file:
    path: /var/www/ci4/writable
    state: directory
    owner: www-data
    group: www-data
    recurse: yes
    mode: '0775'
EOF

cat <<EOF > roles/app/templates/env.j2
CI_ENVIRONMENT = development
database.default.hostname = localhost
database.default.database = tpansible_db
database.default.username = tpansible_usr
database.default.password = password123
database.default.DBDriver = MySQLi
EOF

# -------------------------------------------------------------------------
# 4. Main Playbook
# -------------------------------------------------------------------------
cat <<EOF > site.yml
---
- name: Deploy CodeIgniter 4 Lab
  hosts: webservers
  become: yes
  roles:
    - mysql
    - php
    - nginx
    - app
EOF

# -------------------------------------------------------------------------
# 5. Execution
# -------------------------------------------------------------------------
echo "--- Running Ansible Deployment ---"
ansible-playbook site.yml

echo "--- Testing Deployment ---"
CONTAINER_IP=$(lxc list $CONTAINER_NAME -c 4 --format csv | cut -d' ' -f1)
echo "LXD Container IP: $CONTAINER_IP"

# Check if CI4 is responding
RESPONSE=$(curl -s -L http://$CONTAINER_IP | grep -i "CodeIgniter")
if [ ! -z "$RESPONSE" ]; then
    echo "SUCCESS: CodeIgniter 4 is running at http://$CONTAINER_IP"
else
    echo "FAILED: Check logs in container"
fi
