#!/bin/bash
set -e

PROJECT_DIR="ansible_network_lab"

# 1. Création propre de TOUTE la structure des dossiers dès le début
echo "--- Étape 1 : Création de la structure des rôles ---"
ROLES=("router" "dns_master" "dns_slave" "dhcp_server" "dhcp_relay")
for role in "${ROLES[@]}"; do
    mkdir -p "$PROJECT_DIR/roles/$role/tasks"
    mkdir -p "$PROJECT_DIR/roles/$role/templates"
    mkdir -p "$PROJECT_DIR/roles/$role/handlers"
done
cd $PROJECT_DIR

# -------------------------------------------------------------------------
# 2. Infrastructure LXD (Réseaux et Conteneurs)
# -------------------------------------------------------------------------
echo "--- Étape 2 : Configuration des réseaux LXD ---"
lxc network create br-sub-a ipv4.address=none ipv6.address=none ipv4.dhcp=false || true
lxc network create br-sub-b ipv4.address=none ipv6.address=none ipv4.dhcp=false || true

echo "--- Étape 3 : Lancement des conteneurs ---"
declare -A nodes=( 
    ["router"]="br-sub-a" ["dns-master"]="br-sub-a" ["dns-slave"]="br-sub-a" 
    ["dhcp-server"]="br-sub-a" ["dhcp-relay"]="br-sub-b" ["client-b"]="br-sub-b"
)

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

# Ajout de la 2ème interface au routeur pour relier les deux sous-réseaux
lxc network attach br-sub-b router eth1
# Privilèges pour le relais DHCP (broadcast raw sockets)
lxc config set dhcp-relay security.privileged=true 

echo "Attente du démarrage des instances (15s)..."
sleep 15

# -------------------------------------------------------------------------
# 3. Configuration Ansible
# -------------------------------------------------------------------------
cat <<EOF > hosts.ini
[routers]
router ansible_connection=lxd

[dns_master]
dns-master ansible_connection=lxd

[dns_slave]
dns-slave ansible_connection=lxd

[dhcp_server]
dhcp-server ansible_connection=lxd

[dhcp_relay]
dhcp-relay ansible_connection=lxd
EOF

# -------------------------------------------------------------------------
# 4. Définition des Rôles
# -------------------------------------------------------------------------

# --- ROLE: ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer IP forwarding et interfaces
  shell: |
    ip addr add 192.168.10.1/24 dev eth0 || true
    ip addr add 192.168.20.1/24 dev eth1 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE: DNS MASTER ---
cat <<EOF > roles/dns_master/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: IP Statique Master
  shell: ip addr add 192.168.10.10/24 dev eth0 || true
- name: Config zone master
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
- name: Fichier de zone
  template: src=db.lab.local.j2 dest=/var/cache/bind/db.lab.local
  notify: restart bind
EOF

cat <<EOF > roles/dns_master/templates/named.conf.local.j2
zone "lab.local" {
    type master;
    file "/var/cache/bind/db.lab.local";
    allow-transfer { 192.168.10.11; };
};
EOF

cat <<EOF > roles/dns_master/templates/db.lab.local.j2
\$TTL 604800
@ IN SOA ns1.lab.local. admin.lab.local. (1 604800 86400 2419200 604800)
@ IN NS ns1.lab.local.
@ IN NS ns2.lab.local.
ns1 IN A 192.168.10.10
ns2 IN A 192.168.10.11
EOF

cat <<EOF > roles/dns_master/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF

# --- ROLE: DNS SLAVE ---
cat <<EOF > roles/dns_slave/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present
- name: IP Statique Slave
  shell: ip addr add 192.168.10.11/24 dev eth0 || true
- name: Config zone slave
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
  notify: restart bind
EOF

cat <<EOF > roles/dns_slave/templates/named.conf.local.j2
zone "lab.local" {
    type slave;
    file "/var/cache/bind/db.lab.local";
    masters { 192.168.10.10; };
};
EOF

cat <<EOF > roles/dns_slave/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF

# --- ROLE: DHCP SERVER ---
cat <<EOF > roles/dhcp_server/tasks/main.yml
---
- name: Installer ISC DHCP Server
  apt: name=isc-dhcp-server state=present
- name: IP Statique DHCP et Route vers Subnet B
  shell: |
    ip addr add 192.168.10.12/24 dev eth0 || true
    ip route add 192.168.20.0/24 via 192.168.10.1 || true
- name: Config dhcpd.conf
  template: src=dhcpd.conf.j2 dest=/etc/dhcp/dhcpd.conf
  notify: restart dhcp
EOF

cat <<EOF > roles/dhcp_server/templates/dhcpd.conf.j2
subnet 192.168.10.0 netmask 255.255.255.0 {
  range 192.168.10.50 192.168.10.100;
  option routers 192.168.10.1;
  option domain-name-servers 192.168.10.10;
}
subnet 192.168.20.0 netmask 255.255.255.0 {
  range 192.168.20.50 192.168.20.100;
  option routers 192.168.20.1;
  option domain-name-servers 192.168.10.10;
}
EOF

cat <<EOF > roles/dhcp_server/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# --- ROLE: DHCP RELAY ---
cat <<EOF > roles/dhcp_relay/tasks/main.yml
---
- name: Installer Relay
  apt: name=isc-dhcp-relay state=present
- name: IP Statique Relay
  shell: |
    ip addr add 192.168.20.2/24 dev eth0 || true
    ip route add default via 192.168.20.1 || true
- name: Activer le relais DHCP (Vers serveur 192.168.10.12)
  shell: dhcrelay -i eth0 192.168.10.12
EOF

# -------------------------------------------------------------------------
# 5. Playbook Global et Exécution
# -------------------------------------------------------------------------
cat <<EOF > site.yml
---
- hosts: routers
  roles: [router]
- hosts: dns_master
  roles: [dns_master]
- hosts: dns_slave
  roles: [dns_slave]
- hosts: dhcp_server
  roles: [dhcp_server]
- hosts: dhcp_relay
  roles: [dhcp_relay]
EOF

echo "--- Étape 4 : Lancement d'Ansible ---"
ansible-playbook -i hosts.ini site.yml

echo "--- Étape 5 : Test Client B ---"
lxc exec client-b -- dhclient -v eth0
echo "Adresse IP obtenue par le Client B :"
lxc exec client-b -- ip addr show eth0 | grep "inet "
