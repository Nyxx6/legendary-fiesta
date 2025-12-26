#!/bin/bash
set -e
PROJECT_DIR="td3vagrant"
mkdir -p $PROJECT_DIR/{templates,group_vars,host_vars}
cd $PROJECT_DIR

echo "Création de l'inventaire..."
cat > inventory.ini <<'EOF'
[serveur_web]
# On utilise ssh pour sortir du contexte "local" et simuler deux machines
web1 ansible_host=127.0.0.1 ansible_port=2201 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web1/virtualbox/private_key
web2 ansible_host=127.0.0.1 ansible_port=2202 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/web2/virtualbox/private_key

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
# Option pour ignorer la vérification des clés SSH en local
ansible_ssh_extra_args='-o StrictHostKeyChecking=no'
EOF

echo "Création des variables..."
cat > group_vars/serveur_web.yaml <<'EOF'
---
nginx_user: www-data
nginx_group: www-data
EOF

cat > host_vars/web1.yml << 'EOF'
---
nginx_port: 8081
nginx_server_name: web1.local
nginx_document_root: /var/www/web1
site_title: "Serveur Web1"
EOF

cat > host_vars/web2.yml << 'EOF'
---
nginx_port: 8082
nginx_server_name: web2.local
nginx_document_root: /var/www/web2
site_title: "Serveur Web2"
EOF

echo "Création du template Nginx (CORRIGÉ : nom de fichier)..."
# On le nomme nginx-site.conf.j2 pour correspondre au playbook
cat > templates/nginx-site.conf.j2 <<'EOF'
server {
    listen {{ nginx_port }};
    server_name {{ nginx_server_name }};
    root {{ nginx_document_root }};
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

echo "Création du template HTML..."
cat > templates/index.html.j2 << 'EOF'
<!DOCTYPE html>
<html>
<body>
    <h1>{{ site_title }}</h1>
    <p>Hostname: {{ nginx_server_name }} sur le port {{ nginx_port }}</p>
</body>
</html>
EOF

echo "Création du playbook site.yaml..."
cat > site.yaml << 'EOF'
---
- name: Installation Nginx
  hosts: serveur_web
  become: yes
  tasks:
    - name: Installer Nginx
      apt:
        name: nginx
        update_cache: yes
        state: present

    - name: Créer le répertoire web
      file:
        path: "{{ nginx_document_root }}"
        state: directory
        owner: "{{ nginx_user }}"
        mode: '0755'

    - name: Template HTML
      template:
        src: templates/index.html.j2
        dest: "{{ nginx_document_root }}/index.html"

    - name: Configurer Nginx (Utilise le bon nom de fichier source)
      template:
        src: templates/nginx-site.conf.j2
        dest: "/etc/nginx/sites-available/{{ nginx_server_name }}"
      notify: Redémarrer Nginx
    
    - name: Activer le site
      file:
        src: "/etc/nginx/sites-available/{{ nginx_server_name }}"
        dest: "/etc/nginx/sites-enabled/{{ nginx_server_name }}"
        state: link
      notify: Redémarrer Nginx
    
    - name: Supprimer le site par défaut
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Redémarrer Nginx

  handlers:
    - name: Redémarrer Nginx
      service:
        name: nginx
        state: restarted
EOF

# Note: Le script de test est omis ici pour la brièveté, mais assurez-vous 
# que vos VMs Vagrant sont lancées avant de lancer ansible.
