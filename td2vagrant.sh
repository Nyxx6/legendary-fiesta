#!/bin/bash

# Script de configuration d'environnement multi-conteneurs avec Vagrant
# Configure une VM client et un conteneur Docker Nginx

set -e 

echo "--- Configuration de l'environnement ---"

PROJECT_DIR="vagrant-td2"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

mkdir -p html

cat > html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <title>TD 5 Ex2</title>
</head>
<body>
    <div>
        <p>Page de test</p>
        <p><strong>Serveur:</strong> Nginx dans Docker</p>
    </div>
</body>
</html>
EOF

cat > Vagrantfile << 'EOF'
Vagrant.configure("2") do |config|
  config.vm.define "client" do |client|
    client.vm.box = "ubuntu/focal64"
    client.vm.hostname = "web-client"
    
    client.vm.network "private_network", ip: "192.168.56.10"
    
    client.vm.provider "virtualbox" do |vb|
      vb.name = "web-client"
      vb.memory = "512"
      vb.cpus = 1
    end
    
    client.vm.provision "shell", inline: <<-SHELL   
      apt-get update
      apt-get install -y curl wget net-tools
      
      echo "192.168.56.11 nginx-server" >> /etc/hosts
      
      echo "Client configuré avec succès"
      echo "Utilisez: curl http://192.168.56.11"
      echo "Ou: curl http://nginx-server"
    SHELL
  end
  
  config.vm.define "docker-host" do |docker|
    docker.vm.box = "ubuntu/focal64"
    docker.vm.hostname = "docker-host"
    
    docker.vm.network "private_network", ip: "192.168.56.11"
    
    docker.vm.synced_folder "./html", "/vagrant/html", create: true
    
    docker.vm.provider "virtualbox" do |vb|
      vb.name = "docker-host"
      vb.memory = "1024"
      vb.cpus = 1
    end
    
    docker.vm.provision "shell", inline: <<-SHELL
      apt-get update
      apt-get install -y apt-transport-https ca-certificates curl software-properties-common
      
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
      add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
      
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io
      
      usermod -aG docker vagrant

      docker stop nginx-web 2>/dev/null || true
      docker rm nginx-web 2>/dev/null || true
      
      docker run -d \
        --name nginx-web \
        --restart unless-stopped \
        -p 80:80 \
        -v /vagrant/html:/usr/share/nginx/html:ro \
        nginx:alpine
      
      echo "Docker et Nginx configurés avec succès"
      echo "Le serveur Nginx accessible sur http://192.168.56.11"
      
      sleep 3
      docker ps
    SHELL
  end
  
end
EOF

cat > test.sh << 'EOF'
#!/bin/bash

echo "--- Test de l'environnement ---"

echo ""
echo "1. Test de connectivité : vagrant ssh client -c 'ping -c 2 192.168.56.11' ..."
vagrant ssh client -c "ping -c 2 192.168.56.11" || echo "Erreur de connectivité"

echo ""
echo "2. Test du serveur Nginx : vagrant ssh client -c 'curl -s http://192.168.56.11' ..."
vagrant ssh client -c "curl -s http://192.168.56.11" || echo "Le serveur ne répond pas"

echo ""
echo "3. Vérification du conteneur Docker : vagrant ssh docker-host -c 'docker ps | grep nginx-web' ..."
vagrant ssh docker-host -c "docker ps | grep nginx-web"

echo ""
echo "========================================="
echo "Tests terminés!"
echo "========================================="
EOF

chmod +x test.sh

# Créer un README
cat > README.md << 'EOF'
# Environnement Multi-Conteneurs avec Vagrant

## Architecture

- **VM Client** (192.168.56.10) : Client web avec curl
- **VM Docker Host** (192.168.56.11) : Héberge le conteneur Docker Nginx
- **Réseau Privé** : 192.168.56.0/24

## Installation et Démarrage

```bash
# Démarrer l'environnement
vagrant up

# Vérifier le statut
vagrant status

# Tester la connectivité
./test.sh
```

## Commandes Utiles

```bash
# Se connecter au client
vagrant ssh client

# Depuis le client, tester le serveur Nginx
curl http://192.168.56.11
curl http://nginx-server

# Se connecter à l'hôte Docker
vagrant ssh docker-host

# Voir les conteneurs Docker
vagrant ssh docker-host -c "docker ps"

# Modifier la page web
# Éditez ./html/index.html puis rechargez la page
```

## Arrêt et Nettoyage

```bash
# Arrêter les VMs
vagrant halt

# Détruire l'environnement
vagrant destroy -f
```
EOF

echo ""
echo "--- Configuration terminée! ---"
echo "--- Starting Vagrant machines ---"
vagrant destroy -f
vagrant up
echo "--- Tester la configuration ---"
./test.sh

echo "--- Tester depuis le client ---"
vagrant ssh client -c "curl http://192.168.56.11"
echo "========================================="
echo "Press Enter to destroy the environment..."
read
vagrant destroy -f
