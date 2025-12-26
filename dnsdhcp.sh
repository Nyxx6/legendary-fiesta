#!/bin/bash
set -e

PROJECT_DIR="ansible_network_lab"
mkdir -p $PROJECT_DIR/roles/{common,router,dns_master,dns_slave,dhcp_server,dhcp_relay}/tasks
mkdir -p $PROJECT_DIR/roles/{dns_master,dns_slave,dhcp_server,dhcp_relay}/templates
cd $PROJECT_DIR

# -------------------------------------------------------------------------
# 1. Infrastructure LXD (Réseaux et Conteneurs)
# -------------------------------------------------------------------------
echo "--- Étape 1 : Création des réseaux isolés ---"
lxc network create br-sub-a ipv4.address=none ipv6.address=none ipv4.dhcp=false || true
lxc network create br-sub-b ipv4.address=none ipv6.address=none ipv4.dhcp=false || true

echo "--- Étape 2 : Création des instances ---"
declare -A nodes=( 
    ["router"]="br-sub-a" ["dns-master"]="br-sub-a" ["dns-slave"]="br-sub-a" 
    ["dhcp-server"]="br-sub-a" ["dhcp-relay"]="br-sub-b" ["client-b"]="br-sub-b"
)

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

# Configuration spécifique du Router (deuxième interface)
lxc network attach br-sub-b router eth1
# Configuration DHCP Relay (besoin de privilèges pour le broadcast)
lxc config set dhcp-relay security.privileged=true 

echo "Attente du démarrage (15s)..."
sleep 15

# -------------------------------------------------------------------------
# 2. Configuration Ansible
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

[clients]
client-b ansible_connection=lxd
EOF

# -------------------------------------------------------------------------
# 3. Rôles Ansible
# -------------------------------------------------------------------------

# --- ROLE: ROUTER (IP Forwarding & Interfaces) ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer les IPs du routeur
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
- name: Configurer IP Statique
  shell: ip addr add 192.168.10.10/24 dev eth0 || true
- name: Configurer named.conf.local
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
- name: Créer fichier de zone
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
router IN A 192.168.10.1
EOF

# --- ROLE: DNS SLAVE ---
cat <<EOF > roles/dns_slave/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present
- name: Configurer IP Statique
  shell: ip addr add 192.168.10.11/24 dev eth0 || true
- name: Configurer named.conf.local (Slave)
  template: src=named.conf.slave.j2 dest=/etc/bind/named.conf.local
  notify: restart bind
EOF

cat <<EOF > roles/dns_slave/templates/named.conf.slave.j2
zone "lab.local" {
    type slave;
    file "/var/cache/bind/db.lab.local";
    masters { 192.168.10.10; };
};
EOF

# --- ROLE: DHCP SERVER ---
cat <<EOF > roles/dhcp_server/tasks/main.yml
---
- name: Installer DHCP Server
  apt: name=isc-dhcp-server state=present
- name: Configurer IP Statique
  shell: |
    ip addr add 192.168.10.12/24 dev eth0 || true
    ip route add 192.168.20.0/24 via 192.168.10.1 || true
- name: Configurer dhcpd.conf
  template: src=dhcpd.conf.j2 dest=/etc/dhcp/dhcpd.conf
  notify: restart dhcp
EOF

cat <<EOF > roles/dhcp_server/templates/dhcpd.conf.j2
option domain-name "lab.local";
option domain-name-servers 192.168.10.10, 192.168.10.11;
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.10.0 netmask 255.255.255.0 {
  range 192.168.10.50 192.168.10.100;
  option routers 192.168.10.1;
}

subnet 192.168.20.0 netmask 255.255.255.0 {
  range 192.168.20.50 192.168.20.100;
  option routers 192.168.20.1;
}
EOF

# --- ROLE: DHCP RELAY ---
cat <<EOF > roles/dhcp_relay/tasks/main.yml
---
- name: Installer DHCP Relay
  apt: name=isc-dhcp-relay state=present
- name: Configurer IP Statique
  shell: |
    ip addr add 192.168.20.2/24 dev eth0 || true
    ip route add default via 192.168.20.1 || true
- name: Lancer le relais (Interface eth0 vers Serveur 192.168.10.12)
  shell: dhcrelay -i eth0 192.168.10.12
EOF

# --- HANDLERS ---
for role in dns_master dns_slave dhcp_server; do
cat <<EOF > roles/$role/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF
done

# -------------------------------------------------------------------------
# 4. Playbook Global
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

# -------------------------------------------------------------------------
# 5. Lancement
# -------------------------------------------------------------------------
echo "--- Lancement du déploiement Ansible ---"
ansible-playbook -i hosts.ini site.yml

echo "--- Tests ---"
echo "Test DHCP Client B (Subnet B) via Relay..."
lxc exec client-b -- dhclient -v eth0
echo "Configuration IP de Client B :"
lxc exec client-b -- ip addr show eth0 | grep "inet "
