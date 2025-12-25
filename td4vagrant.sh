#!/bin/bash

# Script d'automatisation Ansible - Création d'un rôle Nginx

set -e  
echo "Configuration de l'exercice Ansible Role Nginx"

PROJECT_DIR="td4ansible"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

echo ""
echo "Création de la structure des répertoires..."

mkdir -p roles
cd roles

echo ""
echo "Création du rôle nginx avec ansible-galaxy init..."
ansible-galaxy init nginx

cd ..


echo ""
echo "Création du fichier d'inventaire..."
cat > inventory.ini << 'EOF'
[serveur_web]
webserver1 ansible_host=localhost ansible_connection=local

[serveur_web:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

# Créer le playbook original site.yaml
echo ""
echo "Création du playbook original site.yaml (référence)..."
cat > site_original.yaml << 'EOF'
---
- name: Installation et configuration de Nginx
  hosts: serveur_web
  become: yes
  
  vars:
    nginx_port: 8080
    server_name: "ssi-website.local"
    document_root: "/var/www/ssi-website"
  
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
        dest: /etc/nginx/sites-available/ssi-website
        mode: '0644'
      notify: Redémarrer Nginx
    
    - name: Activer le site
      file:
        src: /etc/nginx/sites-available/ssi-website
        dest: /etc/nginx/sites-enabled/ssi-website
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

echo ""
echo " Configuration des tâches du rôle nginx..."
cat > roles/nginx/tasks/main.yml << 'EOF'
---
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

echo " Configuration des variables par défaut..."
cat > roles/nginx/defaults/main.yml << 'EOF'
---
# Port d'écoute du serveur
nginx_port: 8080

# Nom du serveur
nginx_server_name: ssi-website.local

# Répertoire racine du site
nginx_document_root: /var/www/ssi-website

# Configuration des logs
nginx_access_log: /var/log/nginx/access.log
nginx_error_log: /var/log/nginx/error.log

# Titre de la page d'accueil
site_title: "Site Web avec Nginx"
EOF

# Créer le template nginx.conf.j2
echo ""
echo " Création du template Nginx..."
cat > roles/nginx/templates/nginx.conf.j2 << 'EOF'
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
    
    # Gestion des erreurs
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

echo ""
echo " Création du template HTML..."
cat > roles/nginx/templates/index.html.j2 << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ site_title }}</title>
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
        </div>
    </div>
</body>
</html>
EOF

echo ""
echo " Configuration des handlers..."
cat > roles/nginx/handlers/main.yml << 'EOF'
---
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

echo ""
echo " Création du fichier ansible.cfg..."
cat > ansible.cfg << 'EOF'
[defaults]
inventory = inventory.ini
roles_path = ./roles

[privilege_escalation]
become = True
EOF

echo ""
echo " Création du fichier d'explications..."
cat > STRUCTURE_EXPLICATIONS.md << 'EOF'
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

###  tests/
- **Rôle**: Tests d'intégration du rôle
- **Contient**: Playbook de test et inventaire minimal

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

echo ""
echo " Création du script de test..."
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
    echo " Le site répond correctement "
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
ansible-playbook site.yaml --syntax-check
ansible-playbook site.yaml -i inventory.ini
./test.sh
