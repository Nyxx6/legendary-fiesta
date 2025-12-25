#!/bin/bash

set -e

PROJECT_DIR="ansible-nginx-project"

mkdir -p $PROJECT_DIR/{templates,group_vars}
cd $PROJECT_DIR

# Create Vagrantfile
cat > Vagrantfile <<'EOF'
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  
  (1..2).each do |i|
    config.vm.define "web#{i}" do |web|
      web.vm.hostname = "web#{i}"
      web.vm.network "private_network", ip: "192.168.56.1#{i}"
      web.vm.provider "virtualbox" do |vb|
        vb.memory = "512"
        vb.cpus = 1
        vb.name = "ansible-web#{i}"
      end
    end
  end
end
EOF

# Create inventory
cat > inventory.ini <<'EOF'
[serveur_web]
web1 ansible_host=192.168.56.11 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web1/virtualbox/private_key
web2 ansible_host=192.168.56.12 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web2/virtualbox/private_key

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Create group_vars
cat > group_vars/serveur_web.yaml <<'EOF'
---
nginx_port: 80
nginx_root: /var/www/html
nginx_server_name: localhost
nginx_user: www-data
nginx_group: www-data
EOF

# Create Nginx template
cat > templates/nginx.conf.j2 <<'EOF'
server {
    listen {{ nginx_port }};
    server_name {{ nginx_server_name }};
    
    root {{ nginx_root }};
    index index.html index.htm;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    # Add server identification
    add_header X-Served-By $hostname;
}
EOF

# Create playbook
cat > site.yaml <<'EOF'
---
- name: Install and configure Nginx web servers
  hosts: serveur_web
  become: yes
  
  tasks:
    - name: Install Nginx
      apt:
        name: nginx
        state: present
        update_cache: yes
    
    - name: Create custom index page
      copy:
        content: |
          <!DOCTYPE html>
          <html>
          <head><title>{{ inventory_hostname }}</title></head>
          <body>
            <h1>Server: {{ inventory_hostname }}</h1>
            <p>Port: {{ nginx_port }}</p>
            <p>Root: {{ nginx_root }}</p>
            <p>Running as: {{ nginx_user }}:{{ nginx_group }}</p>
          </body>
          </html>
        dest: "{{ nginx_root }}/index.html"
        owner: "{{ nginx_user }}"
        group: "{{ nginx_group }}"
        mode: '0644'
    
    - name: Deploy custom Nginx configuration
      template:
        src: templates/nginx.conf.j2
        dest: /etc/nginx/sites-available/default
        owner: root
        group: root
        mode: '0644'
      notify: Restart Nginx
    
    - name: Ensure Nginx is started and enabled
      systemd:
        name: nginx
        state: started
        enabled: yes
  
  handlers:
    - name: Restart Nginx
      systemd:
        name: nginx
        state: restarted
EOF

# Start VMs
vagrant up

# Wait for VMs to be ready
sleep 10

# Test connectivity
echo -e " Testing Ansible connectivity..."
if ansible serveur_web -i inventory.ini -m ping; then
    echo -e "Connectivity successful!\n"
else
    echo -e " Connectivity failed. Check your VMs."
    exit 1
fi

# Run playbook
echo -e "Running Ansible playbook..."
ansible-playbook -i inventory.ini site.yaml

# Test web servers

echo -e "Testing web1 (192.168.56.11):"
curl -s http://192.168.56.11 || echo -e "Failed to reach web1"

echo -e "\nTesting web2 (192.168.56.12):"
curl -s http://192.168.56.12 || echo -e "Failed to reach web2"
# Test handler (config change)

echo -e "Changing nginx port to 8080..."
cat > group_vars/serveur_web.yaml <<'EOF'
---
nginx_port: 8080
nginx_root: /var/www/html
nginx_server_name: localhost
nginx_user: www-data
nginx_group: www-data
EOF

echo -e "Re-running playbook (watch for 'Restart Nginx' handler)..."
ansible-playbook -i inventory.ini site.yaml

echo -e "\nTesting new port 8080:"
curl -s http://192.168.56.11:8080 | head -n 5 || echo -e "Failed"
curl -s http://192.168.56.12:8080 | head -n 5 || echo -e "Failed"


echo -e "\nAccess servers:"
echo -e "  web1: http://192.168.56.11:8080"
echo -e "  web2: http://192.168.56.12:8080"

echo -e "  SSH to VM: vagrant ssh web1"
echo -e "  Run playbook: ansible-playbook -i inventory.ini site.yaml"
echo -e "  Check status: vagrant status"

# Cleanup option
echo "Press Enter to destroy the environment..."
read
vagrant destroy -f
cd ..
rm -rf $PROJECT_DIR