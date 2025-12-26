#!/bin/bash

# =========================================================================
# TD3: Deployment of 2 Nginx Web Servers using LXD & Ansible
# FIX: Force delete old instances + Correct image source (ubuntu:22.04)
# =========================================================================

set -e

PROJECT_DIR="td3_lxd_ansible"
mkdir -p $PROJECT_DIR/{templates,host_vars}
cd $PROJECT_DIR

echo "--- Step 1: Cleaning up old instances ---"
# Deleting existing containers to avoid "already exists" errors
# '|| true' ensures the script continues even if containers don't exist
lxc delete -f web1 >/dev/null 2>&1 || true
lxc delete -f web2 >/dev/null 2>&1 || true
echo "Cleanup done."

echo "--- Step 2: Initializing LXD (if needed) ---"
if ! lxc query / > /dev/null 2>&1; then
    sudo lxd init --auto
fi

echo "--- Step 3: Launching Containers with correct image ---"
# We use 'ubuntu:22.04' which is the official Canonical remote
echo "Launching web1..."
lxc launch ubuntu:22.04 web1

echo "Launching web2..."
lxc launch ubuntu:22.04 web2

echo "Waiting for containers to initialize and get IP addresses..."
sleep 10

# -------------------------------------------------------------------------
# 4. Create Ansible Inventory
# -------------------------------------------------------------------------
echo "--- Step 4: Creating Inventory ---"
cat <<EOF > inventory.ini
[serveur_web]
web1 ansible_connection=lxd
web2 ansible_connection=lxd

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

# -------------------------------------------------------------------------
# 5. Create Host Variables
# -------------------------------------------------------------------------
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
# 6. Create Templates
# -------------------------------------------------------------------------
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

cat <<EOF > templates/index.html.j2
<!DOCTYPE html>
<html>
<head><title>{{ site_title }}</title></head>
<body style="text-align:center; font-family:sans-serif; background:#f4f4f4; padding-top:50px;">
    <h1>{{ site_title }}</h1>
    <hr>
    <p>ID du Conteneur: <strong>{{ inventory_hostname }}</strong></p>
    <p>Port d'écoute: {{ nginx_port }}</p>
</body>
</html>
EOF

# -------------------------------------------------------------------------
# 7. Create Ansible Playbook
# -------------------------------------------------------------------------
echo "--- Step 5: Creating Playbook ---"
cat <<EOF > site.yaml
---
- name: Configuration Nginx sur LXD
  hosts: serveur_web
  become: yes
  tasks:
    - name: Mise à jour APT et Installation Nginx
      apt:
        name: nginx
        update_cache: yes
        state: present

    - name: Création du répertoire racine du site
      file:
        path: "/var/www/{{ inventory_hostname }}"
        state: directory
        mode: '0755'

    - name: Déploiement du fichier index.html
      template:
        src: templates/index.html.j2
        dest: "/var/www/{{ inventory_hostname }}/index.html"

    - name: Configuration du VirtualHost Nginx
      template:
        src: templates/nginx.conf.j2
        dest: "/etc/nginx/sites-available/{{ inventory_hostname }}"
      notify: Restart Nginx

    - name: Activation du nouveau site
      file:
        src: "/etc/nginx/sites-available/{{ inventory_hostname }}"
        dest: "/etc/nginx/sites-enabled/{{ inventory_hostname }}"
        state: link

    - name: Désactivation du site par défaut
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Restart Nginx

  handlers:
    - name: Restart Nginx
      service:
        name: nginx
        state: restarted
EOF

# -------------------------------------------------------------------------
# 8. Execution and Test
# -------------------------------------------------------------------------
echo "--- Step 6: Running Ansible Playbook ---"
ansible-playbook -i inventory.ini site.yaml

echo "--- Step 7: Final Connectivity Test ---"
IP1=$(lxc list web1 -c 4 --format csv | cut -d' ' -f1)
IP2=$(lxc list web2 -c 4 --format csv | cut -d' ' -f1)

echo "Testing Web1 (http://$IP1:8081)..."
curl -s http://$IP1:8081 | grep "Web1" && echo "SUCCESS" || echo "FAILED"

echo "Testing Web2 (http://$IP2:8082)..."
curl -s http://$IP2:8082 | grep "Web2" && echo "SUCCESS" || echo "FAILED"

echo ""
echo "Deployment Finished Successfully!"
echo "You can access the sites at:"
echo "-> Web1: http://$IP1:8081"
echo "-> Web2: http://$IP2:8082"
