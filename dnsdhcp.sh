#!/bin/bash
set -e

# =========================================================================
# TP RÉSEAU COMPLET : DNS, DHCP, RELAIS, ROUTEUR (LXD + ANSIBLE)
# =========================================================================

PROJECT_DIR="lab_reseau_complet"
ROLES=("common" "router" "dns_master" "dhcp_server" "dhcp_relay")

echo "--- 1. NETTOYAGE ET PRÉPARATION DES RÉPERTOIRES ---"
# Suppression de l'ancien projet pour éviter les conflits
rm -rf $PROJECT_DIR

# Création de TOUTE la structure des dossiers Ansible pour éviter les erreurs "not found"
for role in "${ROLES[@]}"; do
    mkdir -p "$PROJECT_DIR/roles/$role/tasks"
    mkdir -p "$PROJECT_DIR/roles/$role/templates"
    mkdir -p "$PROJECT_DIR/roles/$role/handlers"
done

# -------------------------------------------------------------------------
# 2. INFRASTRUCTURE LXD (Inspiré de Netplan/Bridges)
# -------------------------------------------------------------------------
echo "--- 2. CONFIGURATION DE L'INFRASTRUCTURE LXD ---"
# Création des bridges isolés (br01=Sub-A, br02=Sub-B)
lxc network create br01 ipv4.address=none ipv6.address=none ipv4.dhcp=false || true
lxc network create br02 ipv4.address=none ipv6.address=none ipv4.dhcp=false || true

# Lancement des conteneurs
declare -A nodes=( 
    ["router"]="br01" ["dns-master"]="br01" ["dhcp-server"]="br01" 
    ["dhcp-relay"]="br02" ["client-b"]="br02" 
)

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

# Configuration multi-interfaces du Routeur (eth1=Sub-A, eth2=Sub-B)
lxc network attach br02 router eth1
lxc config set dhcp-relay security.privileged=true 

echo "Attente du boot (15s)..."
sleep 15

# -------------------------------------------------------------------------
# 3. CRÉATION DES FICHIERS ANSIBLE
# -------------------------------------------------------------------------
cd $PROJECT_DIR

cat <<EOF > hosts.ini
[routers]
router ansible_connection=lxd
[dns_master]
dns-master ansible_connection=lxd
[dhcp_server]
dhcp-server ansible_connection=lxd
[dhcp_relay]
dhcp-relay ansible_connection=lxd
EOF

# --- TEMPLATE NETPLAN (Commun) ---
cat <<EOF > roles/common/templates/netplan_static.yaml.j2
network:
  version: 2
  ethernets:
    eth0:
      addresses: [{{ lab_ip }}/24]
      nameservers:
        addresses: [8.8.8.8]
EOF

# --- ROLE: ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer Interfaces Routeur
  copy:
    dest: /etc/netplan/60-router.yaml
    content: |
      network:
        version: 2
        ethernets:
          eth0: { addresses: [192.168.10.1/24] }
          eth1: { addresses: [192.168.20.1/24] }
  notify: apply netplan
- name: Enable IP Forwarding
  sysctl: name=net.ipv4.ip_forward value=1 state=present
EOF

# --- ROLE: DNS MASTER ---
cat <<EOF > roles/dns_master/tasks/main.yml
---
- name: Config IP DNS
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.10.10" }
  notify: apply netplan
- name: Install Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Config Zone Master
  copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" { type master; file "/etc/bind/db.lab"; allow-transfer { any; }; };
  notify: restart bind
EOF

# --- ROLE: DHCP SERVER ---
cat <<EOF > roles/dhcp_server/tasks/main.yml
---
- name: Config IP DHCP
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.10.12" }
  notify: apply netplan
- name: Route vers Subnet B
  shell: ip route add 192.168.20.0/24 via 192.168.10.1 || true
- name: Install DHCP Server
  apt: name=isc-dhcp-server state=present update_cache=yes
- name: Config DHCPD
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.60; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.60; option routers 192.168.20.1; }
  notify: restart dhcp
EOF

# --- ROLE: DHCP RELAY ---
cat <<EOF > roles/dhcp_relay/tasks/main.yml
---
- name: Config IP Relay
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.20.2" }
  notify: apply netplan
- name: Install Relay
  apt: name=isc-dhcp-relay state=present
- name: Lancer Relay (Ecoute eth0, Serveur 192.168.10.12)
  shell: killall dhcrelay || true; dhcrelay -id eth0 192.168.10.12
EOF

# --- HANDLERS (Communs pour chaque rôle) ---
for r in "${ROLES[@]}"; do
cat <<EOF > roles/$r/handlers/main.yml
---
- name: apply netplan
  command: netplan apply
- name: restart bind
  service: name=bind9 state=restarted
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF
done

# --- PLAYBOOK PRINCIPAL ---
cat <<EOF > site.yml
---
- hosts: routers
  roles: [router]
- hosts: dns_master
  roles: [dns_master]
- hosts: dhcp_server
  roles: [dhcp_server]
- hosts: dhcp_relay
  roles: [dhcp_relay]
EOF

# -------------------------------------------------------------------------
# 4. EXÉCUTION ET TEST
# -------------------------------------------------------------------------
echo "--- 4. EXÉCUTION DU PLAYBOOK ---"
ansible-playbook -i hosts.ini site.yml

echo ""
echo "--- 5. TEST FINAL CLIENT B ---"
# On force le client B à demander une IP sur eth0 (qui est branché sur br02)
lxc exec client-b -- dhclient -v eth0
echo ""
echo "Résultat de l'adresse IP obtenue par le Client B :"
lxc exec client-b -- ip addr show eth0 | grep "inet 192.168.20"
