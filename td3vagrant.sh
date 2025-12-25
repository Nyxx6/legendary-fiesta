#!/bin/bash

set -e

PROJECT_DIR="td3vagrant"

mkdir -p $PROJECT_DIR/{templates,group_vars,host_vars}
cd $PROJECT_DIR

echo ""
echo "Création du fichier d'inventaire (inventory.ini)..."
cat > inventory.ini <<'EOF'
[serveur_web]
web1 ansible_host=localhost ansible_port=2201 ansible_connection=local
web2 ansible_host=localhost ansible_port=2202 ansible_connection=local

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

echo ""
echo "Création des variables de groupe (group_vars/serveur_web.yml)..."
cat > group_vars/serveur_web.yaml <<'EOF'
---
nginx_user: www-data
nginx_group: www-data
EOF

echo ""
echo "Création des variables pour web1 (host_vars/web1.yml)..."
cat > host_vars/web1.yml << 'EOF'
---
nginx_port: 8081
nginx_server_name: web1.local
nginx_document_root: /var/www/web1
site_title: "Serveur Web1"
site_description: "Premier serveur web déployé"
EOF

echo ""
echo "Création des variables pour web2 (host_vars/web2.yml)..."
cat > host_vars/web2.yml << 'EOF'
---
nginx_port: 8082
nginx_server_name: web2.local
nginx_document_root: /var/www/web2
site_title: "Serveur Web2"
site_description: "Deuxième serveur web déployé"
EOF

echo ""
echo "Création du template Nginx (templates/nginx.conf.j2)..."
cat > templates/nginx.conf.j2 <<'EOF'
server {
    listen {{ nginx_port }};
    listen [::]:{{ nginx_port }};
    
    server_name {{ nginx_server_name }};
    
    root {{ nginx_document_root }};
    index index.html index.htm;
    
    # Logs
    access_log /var/log/nginx/{{ nginx_server_name }}-access.log;
    error_log /var/log/nginx/{{ nginx_server_name }}-error.log;
    
    # Configuration principale
    location / {
        try_files $uri $uri/ =404;
    }
    
    # Gestion des erreurs
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

echo ""
echo "Création du template HTML (templates/index.html.j2)..."
cat > templates/index.html.j2 << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ site_title }} - {{ nginx_server_name }}</title>
</head>
<body>
    <div class="container">
        <h1> {{ site_title }}</h1>
        <div>
            <h3> Configuration du Serveur</h3>
            <div>
                <span>{{ nginx_server_name }}</span>
            </div>
            <div>
                <span>{{ nginx_port }}</span>
            </div>
            <div>
                <span>{{ nginx_document_root }}</span>
            </div>
            <div>
                <span>{{ nginx_user }} - {{ nginx_group }}</span>
            </div>
        </div>
    </div>
</body>
</html>
EOF

echo ""
echo "Création du playbook principal (site.yaml)..."
cat > site.yaml << 'EOF'
---
- name: Installation et configuration de Nginx avec templates et variables
  hosts: serveur_web
  become: yes
  
  tasks:
    - name: Mettre à jour APT
      apt:
        update_cache: yes
        cache_valid_time: 3600
      when: ansible_os_family == "Debian"

    - name: Installer Nginx
      apt:
        name: nginx
        state: present
      when: ansible_os_family == "Debian"

    - name: Installer les dépendances supplémentaires
      apt:
        name:
          - curl
          - net-tools
        state: present
      when: ansible_os_family == "Debian"

    - name: Créer le répertoire du site web
      file:
        path: "{{ nginx_document_root }}"
        state: directory
        mode: '0755'
        owner: "{{ nginx_user }}"
        group: "{{ nginx_group }}"

    - name: Déployer la page d'accueil avec le template
      template:
        src: templates/index.html.j2
        dest: "{{ nginx_document_root }}/index.html"
        mode: '0644'
        owner: "{{ nginx_user }}"
        group: "{{ nginx_group }}"

    - name: Configurer Nginx
      template:
        src: templates/nginx-site.conf.j2
        dest: "/etc/nginx/sites-available/{{ nginx_server_name }}"
        mode: '0644'
      notify: Redémarrer Nginx
    
    - name: Activer le site
      file:
        src: "/etc/nginx/sites-available/{{ nginx_server_name }}"
        dest: "/etc/nginx/sites-enabled/{{ nginx_server_name }}"
        state: link
      notify: Redémarrer Nginx
    
    - name: Désactiver le site par défaut
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Redémarrer Nginx
    
    - name: S'assurer que Nginx est démarré
      service:
        name: nginx
        state: started
        enabled: yes

    - name: Vérifier que Nginx écoute sur le bon port
      wait_for:
        port: "{{ nginx_port }}"
        timeout: 30

    - name: Afficher les informations de connexion
      debug:
        msg: |
          ==========================================
          Configuration terminée pour {{ nginx_server_name }}
          URL: http://localhost:{{ nginx_port }}
          Document Root: {{ nginx_document_root }}
          User/Group: {{ nginx_user }}/{{ nginx_group }}
          ==========================================

  handlers:
    - name: Redémarrer Nginx
      service:
        name: nginx
        state: restarted

    - name: Recharger Nginx
      service:
        name: nginx
        state: reloaded
EOF

echo ""
echo "Création du fichier ansible.cfg..."
cat > ansible.cfg << 'EOF'
[defaults]
inventory = inventory.ini
roles_path = ./roles

[privilege_escalation]
become = True
EOF

echo ""
echo "Création du script de test (test.sh)..."
cat > test.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "Test du déploiement Nginx avec Ansible"
echo "=========================================="
echo ""
echo " Vérification de la syntaxe du playbook..."
ansible-playbook site.yaml --syntax-check
if [ $? -eq 0 ]; then
    echo " Syntaxe correcte"
else
    echo " Erreur de syntaxe"
    exit 1
fi

echo ""
echo " Vérification de l'inventaire..."
ansible-inventory --list -i inventory.ini
echo " Inventaire validé"

echo ""
echo " Test de connexion aux hôtes..."
ansible serveur_web -m ping -i inventory.ini
if [ $? -eq 0 ]; then
    echo " Connexion réussie"
else
    echo " Échec de connexion"
    exit 1
fi

echo ""
echo " Exécution du playbook..."
ansible-playbook site.yaml -i inventory.ini

echo ""
echo " Vérification des serveurs web..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081)
if [ "$RESPONSE" = "200" ]; then
    echo " Le site répond correctement "
    echo ""
    echo " Accédez au siteweb1: http://localhost:8081"
else
    echo " Le site répond avec le code: $RESPONSE"
fi
echo ""
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082)
if [ "$RESPONSE" = "200" ]; then
    echo " Le site répond correctement "
    echo ""
    echo " Accédez au siteweb2: http://localhost:8082"
else
    echo " Le site répond avec le code: $RESPONSE"
fi
EOF

chmod +x test.sh
./test.sh
