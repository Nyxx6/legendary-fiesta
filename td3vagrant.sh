#!/bin/bash

set -e

PROJECT_DIR="td3vagrant"

mkdir -p $PROJECT_DIR/{templates,group_vars,host_vars}
cd $PROJECT_DIR

echo "Création du fichier d'inventaire (inventory.ini)..."
cat > inventory.ini <<'EOF'
[serveur_web]
web1 ansible_host=localhost ansible_port=2201 ansible_connection=local
web2 ansible_host=localhost ansible_port=2202 ansible_connection=local

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

echo "Création des variables de groupe (group_vars/serveur_web.yml)..."
cat > group_vars/serveur_web.yml <<'EOF'
---
nginx_user: www-data
nginx_group: www-data
EOF

echo "Création des variables pour web1 (host_vars/web1.yml)..."
cat > host_vars/web1.yml << 'EOF'
---
nginx_port: 8081
nginx_server_name: web1.local
nginx_document_root: /var/www/web1
site_title: "Serveur Web1"
site_description: "Premier serveur web déployé"
EOF

echo "Création des variables pour web2 (host_vars/web2.yml)..."
cat > host_vars/web2.yml << 'EOF'
---
nginx_port: 8082
nginx_server_name: web2.local
nginx_document_root: /var/www/web2
site_title: "Serveur Web2"
site_description: "Deuxième serveur web déployé"
EOF

echo "Création du template Nginx (templates/nginx-site.conf.j2)..."
cat > templates/nginx-site.conf.j2 <<'EOF'
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

echo "Création du template HTML (templates/index.html.j2)..."
cat > templates/index.html.j2 << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ site_title }} - {{ nginx_server_name }}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background: #f4f4f4; }
        .container { background: white; padding: 30px; border-radius: 10px; max-width: 800px; margin: 0 auto; box-shadow: 0 0 20px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        .info { background: #e7f3ff; padding: 15px; border-left: 4px solid #2196F3; margin: 10px 0; }
        .info span { font-weight: bold; color: #2196F3; }
    </style>
</head>
<body>
    <div class="container">
        <h1>✅ {{ site_title }}</h1>
        <p>{{ site_description }}</p>
        <div class="info">
            <p><span>Serveur:</span> {{ nginx_server_name }}</p>
            <p><span>Port:</span> {{ nginx_port }}</p>
            <p><span>Document Root:</span> {{ nginx_document_root }}</p>
            <p><span>User/Group:</span> {{ nginx_user }}/{{ nginx_group }}</p>
        </div>
    </div>
</body>
</html>
EOF

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

    - name: Configurer le site Nginx
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
    
    - name: S'assurer que Nginx est démarré et activé
      service:
        name: nginx
        state: started
        enabled: yes

    - name: Forcer le redémarrage de Nginx
      meta: flush_handlers

    - name: Attendre que Nginx soit prêt
      pause:
        seconds: 3

    - name: Vérifier que Nginx écoute sur le bon port
      wait_for:
        port: "{{ nginx_port }}"
        timeout: 30
        host: 127.0.0.1

    - name: Afficher les informations de connexion
      debug:
        msg: |
          ==========================================
          ✅ Configuration terminée pour {{ nginx_server_name }}
          🌐 URL: http://localhost:{{ nginx_port }}
          📁 Document Root: {{ nginx_document_root }}
          👤 User/Group: {{ nginx_user }}/{{ nginx_group }}
          ==========================================

  handlers:
    - name: Redémarrer Nginx
      service:
        name: nginx
        state: restarted
EOF

echo "Création du fichier ansible.cfg..."
cat > ansible.cfg << 'EOF'
[defaults]
inventory = inventory.ini
host_key_checking = False

[privilege_escalation]
become = True
become_method = sudo
EOF

echo "Création du script de test (test.sh)..."
cat > test.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "🧪 Test du déploiement Nginx"
echo "=========================================="

# Vérifier la syntaxe
echo ""
echo "1️⃣ Vérification de la syntaxe..."
ansible-playbook site.yaml --syntax-check
if [ $? -eq 0 ]; then
    echo "✅ Syntaxe correcte"
else
    echo "❌ Erreur de syntaxe"
    exit 1
fi

# Test de connexion
echo ""
echo "2️⃣ Test de connexion..."
ansible serveur_web -m ping
if [ $? -eq 0 ]; then
    echo "✅ Connexion réussie"
else
    echo "❌ Échec de connexion"
    exit 1
fi

# Déploiement
echo ""
echo "3️⃣ Déploiement du playbook..."
ansible-playbook site.yaml

# Attendre un peu
echo ""
echo "⏳ Attente de 5 secondes pour que les services démarrent..."
sleep 5

# Vérifier les ports
echo ""
echo "4️⃣ Vérification des ports en écoute..."
echo "Ports Nginx:"
sudo netstat -tlnp | grep nginx || sudo ss -tlnp | grep nginx

# Test des sites
echo ""
echo "=========================================="
echo "🌐 Test d'accès aux sites"
echo "=========================================="

echo ""
echo "Test web1 (port 8081)..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081)
if [ "$RESPONSE" = "200" ]; then
    echo "✅ Web1 répond correctement (HTTP $RESPONSE)"
    echo "🌐 Accédez à: http://localhost:8081"
else
    echo "❌ Web1 ne répond pas (HTTP $RESPONSE)"
fi

echo ""
echo "Test web2 (port 8082)..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082)
if [ "$RESPONSE" = "200" ]; then
    echo "✅ Web2 répond correctement (HTTP $RESPONSE)"
    echo "🌐 Accédez à: http://localhost:8082"
else
    echo "❌ Web2 ne répond pas (HTTP $RESPONSE)"
fi

# Vérifier les fichiers de config
echo ""
echo "=========================================="
echo "📋 Vérification des configurations"
echo "=========================================="
echo ""
echo "Sites disponibles:"
ls -la /etc/nginx/sites-available/

echo ""
echo "Sites activés:"
ls -la /etc/nginx/sites-enabled/

echo ""
echo "Test de la configuration Nginx:"
sudo nginx -t

echo ""
echo "=========================================="
echo "✅ Tests terminés!"
echo "=========================================="
EOF

chmod +x test.sh

echo ""
echo "=========================================="
echo "✅ Configuration terminée!"
echo "=========================================="
echo ""
echo "Pour exécuter:"
echo "  cd $PROJECT_DIR"
echo "  ./test.sh"
echo ""
