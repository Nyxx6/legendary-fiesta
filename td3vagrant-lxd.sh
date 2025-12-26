#!/bin/bash

# =========================================================================
# TD3: Deployment of 2 Nginx Web Servers using LXD & Ansible
# Target: Linux (VMware/Ubuntu/Debian)
# =========================================================================

set -e

PROJECT_DIR="td3_lxd_ansible"
mkdir -p $PROJECT_DIR/{templates,host_vars}
cd $PROJECT_DIR

echo "--- Step 1: Initializing LXD (if not already done) ---"
# Check if LXD is installed, if not, you may need: sudo apt install lxd lxd-client -y
# Ensure the user is in the 'lxd' group
if ! lxc query / > /dev/null 2>&1; then
    echo "Initializing LXD with defaults..."
    sudo lxd init --auto
fi

echo "--- Step 2: Launching Containers ---"
# Launch two Ubuntu containers
lxc launch images:ubuntu/22.04 web1 || echo "web1 already exists"
lxc launch images:ubuntu/22.04 web2 || echo "web2 already exists"

echo "Waiting for containers to be ready..."
sleep 5

# -------------------------------------------------------------------------
# 3. Create Ansible Inventory (Using LXD Connection)
# -------------------------------------------------------------------------
echo "--- Step 3: Creating Inventory ---"
cat <<EOF > inventory.ini
[serveur_web]
web1 ansible_connection=lxd
web2 ansible_connection=lxd

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

# -------------------------------------------------------------------------
# 4. Create Host Variables
# -------------------------------------------------------------------------
echo "--- Step 4: Creating Variables ---"
cat <<EOF > host_vars/web1.yml
nginx_port: 8081
nginx_server_name: web1.local
site_title: "Bienvenue sur Web1 (LXD)"
EOF

cat <<EOF > host_vars/web2.yml
nginx_port: 8082
nginx_server_name: web2.local
site_title: "Bienvenue sur Web2 (LXD)"
EOF

# -------------------------------------------------------------------------
# 5. Create Templates
# -------------------------------------------------------------------------
echo "--- Step 5: Creating Templates ---"
# Nginx Config
cat <<EOF > templates/nginx.conf.j2
server {
    listen {{ nginx_port }};
    server_name {{ nginx_server_name }};
    root /var/www/{{ inventory_hostname }};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# HTML Index
cat <<EOF > templates/index.html.j2
<!DOCTYPE html>
<html>
<head>
    <title>{{ site_title }}</title>
    <style>body { font-family: sans-serif; background: #f0f0f0; text-align: center; }</style>
</head>
<body>
    <h1>{{ site_title }}</h1>
    <p>Ce serveur est un conteneur <strong>LXD</strong> nommé {{ inventory_hostname }}</p>
    <p>Configuré via Ansible sur le port {{ nginx_port }}</p>
</body>
</html>
EOF

# -------------------------------------------------------------------------
# 6. Create Ansible Playbook
# -------------------------------------------------------------------------
echo "--- Step 6: Creating Playbook ---"
cat <<EOF > site.yaml
---
- name: Configuration des conteneurs Nginx via LXD
  hosts: serveur_web
  become: yes
  tasks:
    - name: Installer Nginx
      apt:
        name: nginx
        update_cache: yes
        state: present

    - name: Créer le répertoire du site
      file:
        path: "/var/www/{{ inventory_hostname }}"
        state: directory
        mode: '0755'

    - name: Déployer l'index HTML
      template:
        src: templates/index.html.j2
        dest: "/var/www/{{ inventory_hostname }}/index.html"

    - name: Configurer le site Nginx
      template:
        src: templates/nginx.conf.j2
        dest: "/etc/nginx/sites-available/{{ inventory_hostname }}"
      notify: Reload Nginx

    - name: Activer le site
      file:
        src: "/etc/nginx/sites-available/{{ inventory_hostname }}"
        dest: "/etc/nginx/sites-enabled/{{ inventory_hostname }}"
        state: link

    - name: Supprimer le site par défaut
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Reload Nginx

  handlers:
    - name: Reload Nginx
      service:
        name: nginx
        state: reloaded
EOF

# -------------------------------------------------------------------------
# 7. Run Playbook and Test
# -------------------------------------------------------------------------
echo "--- Step 7: Running Ansible Playbook ---"
ansible-playbook -i inventory.ini site.yaml

echo "--- Step 8: Testing Connectivity ---"
# Get IP addresses of containers
IP_WEB1=$(lxc list web1 -c 4 --format csv | cut -d' ' -f1)
IP_WEB2=$(lxc list web2 -c 4 --format csv | cut -d' ' -f1)

echo "Testing Web1 ($IP_WEB1:8081)..."
curl -s http://$IP_WEB1:8081 | grep "Web1" && echo "SUCCESS" || echo "FAILED"

echo "Testing Web2 ($IP_WEB2:8082)..."
curl -s http://$IP_WEB2:8082 | grep "Web2" && echo "SUCCESS" || echo "FAILED"

echo ""
echo "Deployment Complete!"
echo "URL Web1: http://$IP_WEB1:8081"
echo "URL Web2: http://$IP_WEB2:8082"
