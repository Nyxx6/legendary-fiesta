#!/bin/bash

# =========================================================================
# TD3: Deployment of 2 Nginx Web Servers using LXD & Ansible
# Fix: Using official 'ubuntu:' remote for images
# =========================================================================

set -e

PROJECT_DIR="td3_lxd_ansible"
mkdir -p $PROJECT_DIR/{templates,host_vars}
cd $PROJECT_DIR

echo "--- Step 1: Initializing LXD ---"
if ! lxc query / > /dev/null 2>&1; then
    sudo lxd init --auto
fi

echo "--- Step 2: Launching Containers ---"
# We use 'ubuntu:22.04' (Official Canonical Remote) 
# instead of 'images:ubuntu/22.04'
for container in web1 web2; do
    if lxc info "$container" >/dev/null 2>&1; then
        echo "Container $container already exists, skipping launch."
    else
        echo "Launching $container..."
        lxc launch ubuntu:22.04 "$container"
    fi
done

echo "Waiting for containers to get IPs..."
sleep 5

# -------------------------------------------------------------------------
# 3. Create Ansible Inventory
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
<body style="text-align:center; font-family:sans-serif; background:#eee;">
    <h1>{{ site_title }}</h1>
    <p>Conteneur: <strong>{{ inventory_hostname }}</strong></p>
    <p>Port: {{ nginx_port }}</p>
</body>
</html>
EOF

# -------------------------------------------------------------------------
# 6. Create Playbook
# -------------------------------------------------------------------------
cat <<EOF > site.yaml
---
- name: Configuration Nginx LXD
  hosts: serveur_web
  become: yes
  tasks:
    - name: Update and Install Nginx
      apt:
        name: nginx
        update_cache: yes
        state: present

    - name: Create Web Directory
      file:
        path: "/var/www/{{ inventory_hostname }}"
        state: directory
        mode: '0755'

    - name: Deploy Index
      template:
        src: templates/index.html.j2
        dest: "/var/www/{{ inventory_hostname }}/index.html"

    - name: Configure Nginx
      template:
        src: templates/nginx.conf.j2
        dest: "/etc/nginx/sites-available/{{ inventory_hostname }}"
      notify: Reload Nginx

    - name: Enable Site
      file:
        src: "/etc/nginx/sites-available/{{ inventory_hostname }}"
        dest: "/etc/nginx/sites-enabled/{{ inventory_hostname }}"
        state: link

    - name: Remove Default
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
# 7. Run and Test
# -------------------------------------------------------------------------
echo "--- Step 7: Running Ansible Playbook ---"
ansible-playbook -i inventory.ini site.yaml

echo "--- Step 8: Testing Connectivity ---"
IP1=$(lxc list web1 -c 4 --format csv | cut -d' ' -f1)
IP2=$(lxc list web2 -c 4 --format csv | cut -d' ' -f1)

echo "Testing Web1 at http://$IP1:8081..."
curl -s http://$IP1:8081 | grep "Web1" && echo "SUCCESS"

echo "Testing Web2 at http://$IP2:8082..."
curl -s http://$IP2:8082 | grep "Web2" && echo "SUCCESS"

echo ""
echo "Done! Access your containers at:"
echo "Web1: http://$IP1:8081"
echo "Web2: http://$IP2:8082"
