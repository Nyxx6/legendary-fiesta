#!/bin/bash

# =========================================================================
# TD3: Deployment of 2 Web Servers (Nginx) with Vagrant & Ansible
# Environment: Linux (VMware)
# =========================================================================

set -e

PROJECT_DIR="td3_deployment"
mkdir -p $PROJECT_DIR/{templates,host_vars}
cd $PROJECT_DIR

# -------------------------------------------------------------------------
# 1. Create Vagrantfile (The Infrastructure)
# -------------------------------------------------------------------------
echo "--- Creating Vagrantfile ---"
cat <<EOF > Vagrantfile
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"

  # Web Server 1
  config.vm.define "web1" do |web1|
    web1.vm.hostname = "web1"
    web1.vm.network "private_network", ip: "192.168.56.11"
    web1.vm.network "forwarded_port", guest: 8081, host: 8081
  end

  # Web Server 2
  config.vm.define "web2" do |web2|
    web2.vm.hostname = "web2"
    web2.vm.network "private_network", ip: "192.168.56.12"
    web2.vm.network "forwarded_port", guest: 8082, host: 8082
  end
end
EOF

# -------------------------------------------------------------------------
# 2. Create Ansible Inventory (The Map)
# -------------------------------------------------------------------------
echo "--- Creating Inventory ---"
# Note: We use the private IPs defined in Vagrant
cat <<EOF > inventory.ini
[serveur_web]
web1 ansible_host=192.168.56.11 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web1/virtualbox/private_key
web2 ansible_host=192.168.56.12 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web2/virtualbox/private_key

[serveur_web:vars]
ansible_ssh_extra_args='-o StrictHostKeyChecking=no'
EOF

# -------------------------------------------------------------------------
# 3. Create Host Variables (The Differences)
# -------------------------------------------------------------------------
echo "--- Creating Variables ---"
cat <<EOF > host_vars/web1.yml
nginx_port: 8081
nginx_server_name: web1.local
site_title: "Bienvenue sur Web1"
EOF

cat <<EOF > host_vars/web2.yml
nginx_port: 8082
nginx_server_name: web2.local
site_title: "Bienvenue sur Web2"
EOF

# -------------------------------------------------------------------------
# 4. Create Templates (The Blueprints)
# -------------------------------------------------------------------------
echo "--- Creating Templates ---"
# Nginx Config Template
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

# HTML Index Template
cat <<EOF > templates/index.html.j2
<!DOCTYPE html>
<html>
<head><title>{{ site_title }}</title></head>
<body>
    <h1>{{ site_title }}</h1>
    <p>Ceci est le serveur <strong>{{ inventory_hostname }}</strong></p>
    <p>Configuré via Ansible sur le port {{ nginx_port }}</p>
</body>
</html>
EOF

# -------------------------------------------------------------------------
# 5. Create Ansible Playbook (The Actions)
# -------------------------------------------------------------------------
echo "--- Creating Playbook ---"
cat <<EOF > site.yaml
---
- name: Configuration des serveurs Nginx
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
# 6. Deployment and Testing
# -------------------------------------------------------------------------
echo "--- Step 1: Starting Virtual Machines ---"
vagrant up

echo "--- Step 2: Running Ansible Playbook ---"
# We wait a few seconds to ensure SSH is ready
sleep 5
ansible-playbook -i inventory.ini site.yaml

echo "--- Step 3: Testing Connectivity ---"
echo "Testing Web1 (Port 8081):"
curl -s http://192.168.56.11:8081 | grep "Web1" && echo "SUCCESS" || echo "FAILED"

echo "Testing Web2 (Port 8082):"
curl -s http://192.168.56.12:8082 | grep "Web2" && echo "SUCCESS" || echo "FAILED"

echo ""
echo "Deployment Complete!"
echo "Web1: http://192.168.56.11:8081"
echo "Web2: http://192.168.56.12:8082"
