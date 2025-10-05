## 1. Configuration du Réseau

### 1.1 Architecture des Machines Virtuelles

Deux machines virtuelles ont été créées sous VirtualBox avec les caractéristiques suivantes :

**Machine Virtuelle 1 (Xubuntu1) : Client**
- Système d'exploitation : Xubuntu 24.04.3 LTS
- Mémoire vive : 4 Go RAM
- Processeurs : 2 CPU
- Disque dur : 20 Go
- Interfaces réseau :
  - NAT : accès Internet
  - Host-Only : communication inter-VM

**Machine Virtuelle 2 (Xubuntu2) : Serveur**
- Système d'exploitation : Xubuntu 24.04.3 LTS
- Mémoire vive : 4 Go RAM
- Processeurs : 2 CPU
- Disque dur : 20 Go
- Interfaces réseau :
  - NAT : accès Internet
  - Host-Only : communication inter-VM

### 1.2 Installation et Configuration

**Étapes d'installation :**
1. Installation de Xubuntu 24.04.3 sur les deux machines virtuelles
2. Mise à jour complète du système sur chaque machine :
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```
3. Installation d'OpenSSH :
   ```bash
   sudo apt install openssh-server openssh-client
   ```

**Version d'OpenSSH installée :**
- OpenSSH_9.7p1 Ubuntu-3ubuntu13.14
- OpenSSL 3.0.13

**Configuration du service SSH :**
1. Activation du service SSH :
   ```bash
   sudo systemctl start ssh
   sudo systemctl enable ssh
   ```
2. Vérification du statut :
   ```bash
   sudo systemctl status ssh
   ```
3. Configuration du pare-feu :
   ```bash
   sudo ufw allow ssh
   sudo ufw enable
   ```

### 1.3 Configuration des Comptes Utilisateurs

Un compte utilisateur standard a été créé sur chaque machine :
```bash
sudo adduser ziane
```

### 1.4 Configuration Réseau

Les adresses IP configurées sur l'interface Host-Only :
- **Xubuntu1** : 192.168.56.3
- **Xubuntu2** : 192.168.56.5

Test de connectivité entre les deux machines :
```bash
>xubuntu2:$ ping -c3 192.168.56.3
>xubuntu1:$ ping -c3 192.168.56.5
```

---
