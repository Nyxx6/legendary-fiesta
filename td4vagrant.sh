#!/bin/bash

# Script d'automatisation complète de l'exercice Ansible - Création d'un rôle Nginx
# Crée toute la structure de répertoires, fichiers et configurations nécessaires

set -e  # Arrêt en cas d'erreur

echo "=========================================="
echo "Configuration de l'exercice Ansible Role"
echo "=========================================="

# Créer la structure de base
BASE_DIR="$HOME/TP5/EXO4"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo ""
echo "Création de la structure des répertoires..."

# Créer le répertoire roles
mkdir -p roles
cd roles

# Utiliser ansible-galaxy init pour créer le rôle nginx
echo ""
echo "Création du rôle nginx avec ansible-galaxy init..."
ansible-galaxy init nginx --offline 2>/dev/null || ansible-galaxy init nginx

cd ..

echo ""
echo "Structure du rôle créée!"

# Créer le fichier d'inventaire
echo ""
echo "Création du fichier d'inventaire..."
cat > inventory.ini << 'EOF'
[serveur_web]
webserver1 ansible_host=localhost ansible_connection=local

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

# Créer le playbook original site.yaml (pour référence)
echo ""
echo "Création du playbook original site.yaml (référence)..."
cat > site_original.yaml << 'EOF'
---
- name: Installation et configuration de Nginx
  hosts: serveur_web
  become: yes
  
  vars:
    nginx_port: 8080
    server_name: "monsite.local"
    document_root: "/var/www/monsite"
  
  tasks:
    - name: Installer Nginx
      apt:
        name: nginx
        state: present
        update_cache: yes
      when: ansible_os_family == "Debian"
    
    - name: Créer le répertoire du site web
      file:
        path: "{{ document_root }}"
        state: directory
        mode: '0755'
    
    - name: Copier la page d'accueil
      template:
        src: index.html.j2
        dest: "{{ document_root }}/index.html"
        mode: '0644'
    
    - name: Configurer Nginx
      template:
        src: nginx.conf.j2
        dest: /etc/nginx/sites-available/monsite
        mode: '0644'
      notify: Redémarrer Nginx
    
    - name: Activer le site
      file:
        src: /etc/nginx/sites-available/monsite
        dest: /etc/nginx/sites-enabled/monsite
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
  
  handlers:
    - name: Redémarrer Nginx
      service:
        name: nginx
        state: restarted
EOF

# Créer les tâches dans le rôle (tasks/main.yml)
echo ""
echo " Configuration des tâches du rôle..."
cat > roles/nginx/tasks/main.yml << 'EOF'
---
# Tasks pour le rôle nginx

- name: Installer Nginx
  apt:
    name: nginx
    state: present
    update_cache: yes
  when: ansible_os_family == "Debian"
  tags:
    - nginx
    - install

- name: Créer le répertoire du site web
  file:
    path: "{{ nginx_document_root }}"
    state: directory
    mode: '0755'
    owner: www-data
    group: www-data
  tags:
    - nginx
    - config

- name: Copier la page d'accueil
  template:
    src: index.html.j2
    dest: "{{ nginx_document_root }}/index.html"
    mode: '0644'
    owner: www-data
    group: www-data
  tags:
    - nginx
    - content

- name: Configurer le site Nginx
  template:
    src: nginx.conf.j2
    dest: "/etc/nginx/sites-available/{{ nginx_server_name }}"
    mode: '0644'
  notify: Redémarrer Nginx
  tags:
    - nginx
    - config

- name: Activer le site
  file:
    src: "/etc/nginx/sites-available/{{ nginx_server_name }}"
    dest: "/etc/nginx/sites-enabled/{{ nginx_server_name }}"
    state: link
  notify: Redémarrer Nginx
  tags:
    - nginx
    - config

- name: Désactiver le site par défaut
  file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Redémarrer Nginx
  tags:
    - nginx
    - config

- name: S'assurer que Nginx est démarré et activé
  service:
    name: nginx
    state: started
    enabled: yes
  tags:
    - nginx
    - service
EOF

# Créer les variables par défaut (defaults/main.yml)
echo ""
echo " Configuration des variables par défaut..."
cat > roles/nginx/defaults/main.yml << 'EOF'
---
# Variables par défaut pour le rôle nginx

# Port d'écoute du serveur
nginx_port: 8080

# Nom du serveur
nginx_server_name: monsite.local

# Répertoire racine du site
nginx_document_root: /var/www/monsite

# Nombre de workers
nginx_worker_processes: auto

# Nombre de connexions par worker
nginx_worker_connections: 1024

# Type MIME par défaut
nginx_default_type: application/octet-stream

# Timeout pour keepalive
nginx_keepalive_timeout: 65

# Configuration des logs
nginx_access_log: /var/log/nginx/access.log
nginx_error_log: /var/log/nginx/error.log

# Titre de la page d'accueil
site_title: "Mon Site Web avec Nginx"
site_description: "Site configuré avec un rôle Ansible"
EOF

# Créer le template nginx.conf.j2
echo ""
echo " Création du template Nginx..."
cat > roles/nginx/templates/nginx.conf.j2 << 'EOF'
# Configuration Nginx générée par Ansible
# Rôle: nginx
# Serveur: {{ nginx_server_name }}

server {
    listen {{ nginx_port }};
    listen [::]:{{ nginx_port }};
    
    server_name {{ nginx_server_name }};
    
    root {{ nginx_document_root }};
    index index.html index.htm;
    
    # Logs
    access_log {{ nginx_access_log }};
    error_log {{ nginx_error_log }};
    
    # Configuration principale
    location / {
        try_files $uri $uri/ =404;
    }
    
    # Sécurité - Cacher la version de Nginx
    server_tokens off;
    
    # Configuration des types MIME
    include /etc/nginx/mime.types;
    default_type {{ nginx_default_type }};
    
    # Gestion des erreurs
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /50x.html {
        root /usr/share/nginx/html;
    }
    
    # Optimisations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout {{ nginx_keepalive_timeout }};
    types_hash_max_size 2048;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/rss+xml font/truetype font/opentype 
               application/vnd.ms-fontobject image/svg+xml;
}
EOF

# Créer le template index.html.j2
echo ""
echo " Création du template HTML..."
cat > roles/nginx/templates/index.html.j2 << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ site_title }}</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .container {
            background: white;
            border-radius: 20px;
            padding: 40px;
            max-width: 800px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            animation: fadeIn 0.5s ease-in;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(-20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        h1 {
            color: #667eea;
            margin-bottom: 20px;
            font-size: 2.5em;
        }
        
        .badge {
            display: inline-block;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 8px 16px;
            border-radius: 20px;
            font-size: 0.9em;
            margin: 5px;
            font-weight: bold;
        }
        
        .info-box {
            background: #f8f9fa;
            border-left: 4px solid #667eea;
            padding: 20px;
            margin: 20px 0;
            border-radius: 5px;
        }
        
        .info-box h3 {
            color: #333;
            margin-bottom: 10px;
        }
        
        .info-item {
            margin: 10px 0;
            padding: 10px;
            background: white;
            border-radius: 5px;
        }
        
        .info-label {
            font-weight: bold;
            color: #667eea;
            display: inline-block;
            min-width: 200px;
        }
        
        .success {
            color: #28a745;
            font-size: 1.2em;
            margin: 20px 0;
        }
        
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 2px solid #eee;
            text-align: center;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1> {{ site_title }}</h1>
        
        <p class="success">
             Félicitations! Votre rôle Ansible fonctionne parfaitement!
        </p>
        
        <div class="info-box">
            <h3> Configuration du Serveur</h3>
            <div class="info-item">
                <span class="info-label">Serveur:</span>
                <span>{{ nginx_server_name }}</span>
            </div>
            <div class="info-item">
                <span class="info-label">Port:</span>
                <span>{{ nginx_port }}</span>
            </div>
            <div class="info-item">
                <span class="info-label">Document Root:</span>
                <span>{{ nginx_document_root }}</span>
            </div>
            <div class="info-item">
                <span class="info-label">Hostname:</span>
                <span>{{ ansible_hostname }}</span>
            </div>
            <div class="info-item">
                <span class="info-label">OS:</span>
                <span>{{ ansible_distribution }} {{ ansible_distribution_version }}</span>
            </div>
        </div>
        
        <div class="info-box">
            <h3> Technologies Utilisées</h3>
            <span class="badge">Ansible</span>
            <span class="badge">Nginx</span>
            <span class="badge">Jinja2</span>
            <span class="badge">YAML</span>
            <span class="badge">Roles</span>
        </div>
        
        <p><strong>Description:</strong> {{ site_description }}</p>
        
        <div class="footer">
            <p>Déployé par Ansible | Rôle: nginx</p>
            <p style="font-size: 0.9em; margin-top: 10px;">
                Date de déploiement: {{ ansible_date_time.date }} {{ ansible_date_time.time }}
            </p>
        </div>
    </div>
</body>
</html>
EOF

# Créer les handlers (handlers/main.yml)
echo ""
echo " Configuration des handlers..."
cat > roles/nginx/handlers/main.yml << 'EOF'
---
# Handlers pour le rôle nginx

- name: Redémarrer Nginx
  service:
    name: nginx
    state: restarted
  listen: "Redémarrer Nginx"

- name: Recharger Nginx
  service:
    name: nginx
    state: reloaded
  listen: "Recharger Nginx"

- name: Vérifier la configuration Nginx
  command: nginx -t
  changed_when: false
  listen: "Vérifier Nginx"
EOF

# Créer le fichier meta/main.yml
echo ""
echo " Configuration des métadonnées..."
cat > roles/nginx/meta/main.yml << 'EOF'
---
galaxy_info:
  author: Ceryne
  description: Rôle pour installer et configurer Nginx
  company: TP5 - EXO4
  
  license: MIT
  
  min_ansible_version: "2.9"
  
  platforms:
    - name: Ubuntu
      versions:
        - focal
        - jammy
    - name: Debian
      versions:
        - buster
        - bullseye
  
  galaxy_tags:
    - nginx
    - web
    - webserver

dependencies: []
EOF

# Créer le README du rôle
cat > roles/nginx/README.md << 'EOF'
# Rôle Ansible: nginx

Ce rôle installe et configure Nginx sur des serveurs Debian/Ubuntu.

## Prérequis

- Ansible 2.9+
- Système d'exploitation: Debian/Ubuntu
- Privilèges sudo

## Variables

Variables disponibles dans `defaults/main.yml`:

| Variable | Défaut | Description |
|----------|--------|-------------|
| `nginx_port` | 8080 | Port d'écoute |
| `nginx_server_name` | monsite.local | Nom du serveur |
| `nginx_document_root` | /var/www/monsite | Répertoire racine |
| `nginx_worker_processes` | auto | Nombre de workers |
| `site_title` | Mon Site Web avec Nginx | Titre de la page |

## Utilisation

```yaml
- hosts: serveur_web
  become: yes
  roles:
    - nginx
```

## Tags disponibles

- `nginx` - Toutes les tâches
- `install` - Installation uniquement
- `config` - Configuration uniquement
- `service` - Gestion du service
- `content` - Contenu du site

## Exemple avec variables personnalisées

```yaml
- hosts: serveur_web
  become: yes
  roles:
    - role: nginx
      nginx_port: 9090
      nginx_server_name: demo.local
      site_title: "Mon Site Demo"
```
EOF

# Créer le nouveau playbook qui utilise le rôle
echo ""
echo " Création du playbook principal (site.yaml)..."
cat > site.yaml << 'EOF'
---
- name: Déployer Nginx sur les serveurs
  hosts: serveur_web
  become: yes
  
  roles:
    - nginx
EOF

# Créer un playbook avec variables personnalisées
cat > site_custom.yaml << 'EOF'
---
- name: Déployer Nginx avec configuration personnalisée
  hosts: serveur_web
  become: yes
  
  vars:
    nginx_port: 9090
    nginx_server_name: demo.local
    site_title: "Site Demo Personnalisé"
    site_description: "Configuration personnalisée avec variables"
  
  roles:
    - nginx
EOF

# Créer ansible.cfg
echo ""
echo " Création du fichier ansible.cfg..."
cat > ansible.cfg << 'EOF'
[defaults]
inventory = inventory.ini
host_key_checking = False
retry_files_enabled = False
roles_path = ./roles

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
EOF

# Créer le fichier d'explication de la structure
echo ""
echo " Création du fichier d'explications..."
cat > STRUCTURE_EXPLICATIONS.md << 'EOF'
# Explication de la Structure du Rôle Ansible

## Structure créée par ansible-galaxy init

```
roles/nginx/
├── README.md              # Documentation du rôle
├── defaults/              # Variables par défaut (priorité la plus basse)
│   └── main.yml
├── files/                 # Fichiers statiques à copier
├── handlers/              # Handlers (actions déclenchées par notify)
│   └── main.yml
├── meta/                  # Métadonnées du rôle (dépendances, infos)
│   └── main.yml
├── tasks/                 # Tâches principales du rôle
│   └── main.yml
├── templates/             # Templates Jinja2 (.j2)
│   ├── index.html.j2
│   └── nginx.conf.j2
├── tests/                 # Tests du rôle
│   ├── inventory
│   └── test.yml
└── vars/                  # Variables du rôle (priorité plus haute)
    └── main.yml
```

## Explication de chaque répertoire/fichier

###  defaults/main.yml
- **Rôle**: Contient les variables par défaut du rôle
- **Priorité**: La plus basse (facilement écrasable)
- **Usage**: Valeurs par défaut qui peuvent être modifiées
- **Exemple**: ports, chemins, noms de serveurs

###  vars/main.yml
- **Rôle**: Variables avec priorité élevée
- **Priorité**: Plus haute que defaults
- **Usage**: Variables qui ne devraient pas être modifiées
- **Exemple**: constantes, chemins système critiques

###  tasks/main.yml
- **Rôle**: Point d'entrée des tâches du rôle
- **Contenu**: Liste séquentielle des actions à effectuer
- **Usage**: Installation, configuration, déploiement
- **Peut inclure**: D'autres fichiers de tâches

###  handlers/main.yml
- **Rôle**: Actions déclenchées par "notify"
- **Usage**: Redémarrages de services, rechargements
- **Exécution**: À la fin du playbook, une seule fois même si notifié plusieurs fois
- **Exemple**: "Redémarrer Nginx"

###  templates/
- **Rôle**: Fichiers Jinja2 (.j2) avec variables
- **Usage**: Fichiers de configuration dynamiques
- **Syntaxe**: Utilise {{ variable }} pour l'interpolation
- **Exemple**: nginx.conf.j2, index.html.j2

###  files/
- **Rôle**: Fichiers statiques à copier tel quel
- **Usage**: Scripts, certificats, fichiers binaires
- **Différence avec templates**: Pas de traitement Jinja2
- **Module**: Utilisé avec le module "copy"

###  meta/main.yml
- **Rôle**: Métadonnées et informations sur le rôle
- **Contient**:
  - Dépendances vers d'autres rôles
  - Informations Galaxy (auteur, licence, plateformes)
  - Version minimale d'Ansible
- **Usage**: Documentation et gestion des dépendances

###  tests/
- **Rôle**: Tests d'intégration du rôle
- **Contient**: Playbook de test et inventaire minimal
- **Usage**: Valider que le rôle fonctionne correctement
- **CI/CD**: Utilisé dans les pipelines de tests

###  README.md
- **Rôle**: Documentation du rôle
- **Contient**:
  - Description du rôle
  - Variables disponibles
  - Exemples d'utilisation
  - Prérequis et dépendances

## Ordre de priorité des variables (du plus bas au plus haut)

1. `defaults/main.yml` (le plus faible)
2. `vars/main.yml` du rôle
3. Variables d'inventaire
4. Variables du playbook
5. Variables extra (--extra-vars) (le plus fort)

## Bonnes pratiques

1. **defaults/main.yml**: Variables modifiables par l'utilisateur
2. **vars/main.yml**: Variables internes du rôle
3. **tasks/main.yml**: Tâches organisées logiquement avec tags
4. **handlers**: Une action par handler, noms explicites
5. **templates**: Commentaires pour expliquer la configuration
6. **meta/main.yml**: Documentation complète pour Galaxy

## Tags recommandés

```yaml
tasks:
  - name: Installer le package
    tags: [install, nginx]
  
  - name: Configurer le service
    tags: [config, nginx]
  
  - name: Démarrer le service
    tags: [service, nginx]
```

Usage: `ansible-playbook site.yaml --tags install`
EOF

# Créer le script de test
echo ""
echo " Création du script de test..."
cat > test.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "Test du déploiement Nginx avec Ansible"
echo "=========================================="

# Vérifier qu'Ansible est installé
if ! command -v ansible &> /dev/null; then
    echo " Ansible n'est pas installé!"
    echo "Installation: sudo apt install ansible"
    exit 1
fi

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
echo " Vérification du service Nginx..."
if systemctl is-active --quiet nginx; then
    echo " Nginx est actif"
else
    echo " Nginx n'est pas actif"
fi

echo ""
echo " Test d'accès au site web..."
sleep 2
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080)
if [ "$RESPONSE" = "200" ]; then
    echo " Le site répond correctement (HTTP 200)"
    echo ""
    echo " Accédez au site: http://localhost:8080"
else
    echo " Le site répond avec le code: $RESPONSE"
fi

echo ""
echo "=========================================="
echo " Tests terminés!"
echo "=========================================="
EOF

chmod +x test.sh

# Créer un Makefile pour faciliter l'utilisation
cat > Makefile << 'EOF'
.PHONY: help install check deploy test clean status custom

help:
	@echo "Commandes disponibles:"
	@echo "  make install  - Installer les dépendances"
	@echo "  make check    - Vérifier la syntaxe"
	@echo "  make deploy   - Déployer le rôle nginx"
	@echo "  make custom   - Déployer avec config personnalisée"
	@echo "  make test     - Tester le déploiement"
	@echo "  make status   - Vérifier le statut de Nginx"
	@echo "  make clean    - Nettoyer l'installation"

install:
	@echo "Installation d'Ansible..."
	sudo apt update
	sudo apt install -y ansible

check:
	@echo "Vérification de la syntaxe..."
	ansible-playbook site.yaml --syntax-check
	ansible-lint site.yaml || true

deploy:
	@echo "Déploiement du rôle nginx..."
	ansible-playbook site.yaml -i inventory.ini

custom:
	@echo "Déploiement avec configuration personnalisée..."
	ansible-playbook site_custom.yaml -i inventory.ini

test:
	@echo "Exécution des tests..."
	./test.sh

status:
	@echo "Statut de Nginx:"
	systemctl status nginx --no-pager
	@echo ""
	@echo "Test HTTP:"
	curl -I http://localhost:8080

clean:
	@echo "Nettoyage..."
	ansible-playbook -i inventory.ini -b -m apt -a "name=nginx state=absent purge=yes" serveur_web
	sudo rm -rf /var/www/monsite
	sudo rm -f /etc/nginx/sites-available/monsite.local
	sudo rm -f /etc/nginx/sites-enabled/monsite.local
EOF

# Créer le guide d'utilisation complet
cat > GUIDE_UTILISATION.md << 'EOF'
# Guide d'Utilisation - Exercice Ansible Rôle Nginx

## 🚀 Démarrage Rapide

```bash
# 1. Vérifier la syntaxe
ansible-playbook site.yaml --syntax-check

# 2. Déployer
ansible-playbook site.yaml -i inventory.ini

# 3. Tester
./test.sh

# 4. Accéder au site
curl http://localhost:8080
# ou dans un navigateur: http://localhost:8080
```

##  Commandes Utiles

### Avec Makefile
```bash
make check    # Vérifier la syntaxe
make deploy   # Déployer le rôle
make test     # Tester l'installation
make status   # Voir le statut de Nginx
make clean    # Nettoyer
```

### Commandes Ansible Directes

```bash
# Vérifier la syntaxe
ansible-playbook site.yaml --syntax-check

# Voir les tâches qui seront exécutées (dry-run)
ansible-playbook site.yaml --check

# Exécuter avec verbose
ansible-playbook site.yaml -v    # -vv, -vvv pour plus de détails

# Exécuter uniquement certains tags
ansible-playbook site.yaml --tags install
ansible-playbook site.yaml --tags config
ansible-playbook site.yaml --tags service

# Utiliser la configuration personnalisée
ansible-playbook site_custom.yaml

# Lister les tâches sans les exécuter
ansible-playbook site.yaml --list-tasks

# Lister les tags disponibles
ansible-playbook site.yaml --list-tags
```

##  Personnalisation

### Modifier les variables par défaut

Éditez `roles/nginx/defaults/main.yml`:

```yaml
nginx_port: 9090                    # Changer le port
nginx_server_name: mondomaine.com   # Changer le nom de domaine
site_title: "Mon Super Site"       # Changer le titre
```

### Surcharger les variables dans le playbook

```yaml
---
- name: Déployer Nginx
  hosts: serveur_web
  become: yes
  
  vars:
    nginx_port: 3000
    site_title: "Site de Prod"
  
  roles:
    - nginx
```

### Utiliser des variables en ligne de commande

```bash
ansible-playbook site.yaml -e "nginx_port=7777 site_title='Test Site'"
```

##  Structure des Fichiers

```
~/TP5/EXO4/
├── site.yaml                    # Playbook principal
├── site_custom.yaml             # Playbook avec config personnalisée
├── inventory.ini                # Inventaire des hôtes
├── ansible.cfg                  # Configuration Ansible
├── test.sh                      # Script de test
├── Makefile                     # Commandes facilitées
├── STRUCTURE_EXPLICATIONS.md    # Explications détaillées
├── GUIDE_UTILISATION.md         # Ce guide
└── roles/
    └── nginx/
        ├── defaults/main.yml    # Variables par défaut
        ├── tasks/main.yml       # Tâches à exécuter
        ├── handlers/main.yml    # Handlers (redémarrages)
        ├── templates/           # Templates Jinja2
        │   ├── nginx.conf.j2
        │   └── index.html.j2
        ├── meta/main.yml        # Métadonnées
        └── README.md            # Documentation du rôle
```

##  Exercices Supplémentaires

### 1. Ajouter un nouveau site

```yaml
# Dans site.yaml, ajoutez:
vars:
  nginx_sites:
    - name: site1
      port: 8080
    - name: site2
      port: 8081
```

### 2. Utiliser des certificats SSL

Créez des tâches pour:
- Installer certbot
- Générer des certificats Let's Encrypt
- Configurer Nginx pour SSL

### 3. Ajouter des tests

Créez `roles/nginx/tests/test.yml`:

```yaml
---
- hosts: localhost
  remote_user: root
  roles:
    - nginx
```

##  Dépannage

### Nginx ne démarre pas

```bash
# Vérifier les logs
sudo journalctl -u nginx -n 50

# Vérifier la configuration
sudo nginx -t

# Vérifier le statut
sudo systemctl status nginx
```

### Le site n'est pas accessible

```bash
# Vérifier que Nginx écoute
sudo netstat -tlnp | grep nginx

# Vérifier les permissions
ls -la /var/www/monsite

# Vérifier le firewall
sudo ufw status
```

### Problèmes de variables

```bash
# Afficher toutes les variables
ansible-playbook site.yaml -e debug=true --tags debug

# Voir les facts de l'hôte
ansible serveur_web -m setup
```

##  Ressources

- [Documentation Ansible](https://docs.ansible.com)
- [Ansible Galaxy](https://galaxy.ansible.com)
- [Best Practices](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html)
EOF

echo ""
echo "=========================================="
echo " Configuration terminée avec succès!"
echo "=========================================="
echo ""
echo " Structure créée dans: $BASE_DIR"
echo ""
echo " Fichiers créés:"
echo "  - site.yaml              (playbook principal)"
echo "  - site_custom.yaml       (avec variables personnalisées)"
echo "  - inventory.ini          (inventaire des hôtes)"
echo "  - ansible.cfg            (configuration Ansible)"
echo "  - test.sh                (script de test)"
echo "  - Makefile               (commandes facilitées)"
echo "  - roles/nginx/           (structure complète du rôle)"
echo "  - Documentation complète (MD files)"
echo ""
echo " Prochaines étapes:"
echo ""
echo "  Vérifier la syntaxe:"
echo "    ansible-playbook site.yaml --syntax-check"
echo ""
echo "  Déployer le rôle:"
echo "    ansible-playbook site.yaml -i inventory.ini"
echo "    # ou simplement: make deploy"
echo ""
echo "  Tester l'installation:"
echo "    ./test.sh"
echo "    # ou: make test"
echo ""
echo "  Accéder au site web:"
echo "    http://localhost:8080"
echo ""
echo " Consultez GUIDE_UTILISATION.md pour plus de détails"
echo " Consultez STRUCTURE_EXPLICATIONS.md pour comprendre la structure"
echo ""
echo "=========================================="
echo ""

# Afficher un résumé de la structure créée
echo " Structure du rôle nginx:"
tree -L 3 roles/nginx/ 2>/dev/null || find roles/nginx/ -type f

echo ""
echo "✨ Exercice prêt à être utilisé!"

echo ""
