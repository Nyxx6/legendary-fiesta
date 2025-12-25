#!/bin/bash

# Script de configuration d'environnement multi-conteneurs avec Vagrant
# Configure une VM client et un conteneur Docker Nginx

set -e

echo "==================================="
echo "Configuration de l'environnement"
echo "==================================="

# Créer le répertoire du projet
PROJECT_DIR="td2vagrant"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

mkdir -p html

cat > html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TD 5.2 NGINX</title>
</head>
<body>
    <div>
        <p>Si vous voyez cette page, votre environnement multi-conteneurs est correctement configuré!</p>
        <p><strong>Serveur:</strong> Nginx dans Docker</p>
    </div>
</body>
</html>
EOF

cat > Vagrantfile << 'EOF'
# -*- mode: ruby -*-
# vi: set ft=ruby :

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
      echo "========================================="
      echo "Configuration du client web"
      echo "========================================="
      
      apt-get update
      apt-get install -y curl wget net-tools
      
      echo "192.168.56.11 nginx-server" >> /etc/hosts
      
      echo "Client configuré avec succès"
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
      echo "========================================="
      echo "Installation de Docker"
      echo "========================================="
      
      apt-get update
      apt-get install -y apt-transport-https ca-certificates curl software-properties-common
      
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
      add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
      
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io
      
      usermod -aG docker vagrant
      
      echo "========================================="
      echo "Démarrage du conteneur Nginx"
      echo "========================================="
      
      docker stop nginx-web 2>/dev/null || true
      docker rm nginx-web 2>/dev/null || true
      
      docker run -d \
        --name nginx-web \
        --restart unless-stopped \
        -p 80:80 \
        -v /vagrant/html:/usr/share/nginx/html:ro \
        nginx:alpine
      
      echo "Docker et Nginx configurés avec succès"
      echo "Le serveur Nginx est accessible sur http://192.168.56.11"
      
      sleep 3
      docker ps
    SHELL
  end
  
end
EOF

cat > test.sh << 'EOF'
#!/bin/bash

echo "========================================="
echo "Test de l'environnement"
echo "========================================="

echo ""
echo "1. Test de connectivité réseau vagrant ssh client -c ping -c 2 192.168.56.11 ..."
vagrant ssh client -c "ping -c 2 192.168.56.11" || echo "Erreur de connectivité"

echo ""
echo "2. Test du serveur Nginx avec curl vagrant ssh client -c curl -s http://192.168.56.11..."
vagrant ssh client -c "curl -s http://192.168.56.11" || echo "Le serveur ne répond pas"

echo ""
echo "3. Vérification du conteneur Docker vagrant ssh docker-host -c docker ps | grep nginx-web..."
vagrant ssh docker-host -c "docker ps | grep nginx-web"

echo ""
echo "========================================="
echo "Tests terminés!"
echo "========================================="
EOF

chmod +x test.sh

echo ""
echo "--- Starting Vagrant machines ---"
vagrant destroy -f
vagrant up
./test.sh
echo ""
echo "========================================="
echo "Press Enter to destroy the environment..."
read
vagrant destroy -f
