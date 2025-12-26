#!/bin/bash
set -e

# =========================================================================
# Lab Réseau Complet : DNS Master/Slave, DHCP Server/Relay & Router
# Infrastructure : LXD | Orchestration : Ansible
# =========================================================================

PROJECT_DIR="ansible_network_lab"
ROLES=("router" "dns_master" "dns_slave" "dhcp_server" "dhcp_relay")

echo "--- 1. Préparation de la structure Ansible ---"
rm -rf $PROJECT_DIR
for role in "${ROLES[@]}"; do
    mkdir -p "$PROJECT_DIR/roles/$role/tasks" "$PROJECT_DIR/roles/$role/templates" "$PROJECT_DIR/roles/$role/handlers"
done
cd $PROJECT_DIR

# -------------------------------------------------------------------------
# 2. Configuration LXD (Réseaux avec NAT pour installation packages)
# -------------------------------------------------------------------------
echo "--- 2. Configuration des réseaux LXD (NAT activé pour APT) ---"
lxc network delete br-sub-a >/dev/null 2>&1 || true
lxc network create br-sub-a ipv4.address=192.168.10.254/24 ipv4.nat=true ipv4.dhcp=false

lxc network delete br-sub-b >/dev/null 2>&1 || true
lxc network create br-sub-b ipv4.address=192.168.20.254/24 ipv4.nat=true ipv4.dhcp=false

echo "--- 3. Lancement des instances ---"
declare -A nodes=( 
    ["router"]="br-sub-a" ["dns-master"]="br-sub-a" ["dns-slave"]="br-sub-a" 
    ["dhcp-server"]="br-sub-a" ["dhcp-relay"]="br-sub-b" ["client-b"]="br-sub-b"
)

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

lxc network attach br-sub-b router eth1
lxc config set dhcp-relay security.privileged=true 

echo "Attente du démarrage (15s)..."
sleep 15

# -------------------------------------------------------------------------
# 3. Fichiers de Configuration Ansible
# -------------------------------------------------------------------------
cat <<EOF > ansible.cfg
[defaults]
inventory = hosts.ini
host_key_checking = False
EOF

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
# 4. Définition des Rôles (Tasks, Templates, Handlers)
# -------------------------------------------------------------------------

# --- ROLE: ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configuration IP et Forwarding
  shell: |
    ip addr add 192.168.10.1/24 dev eth0 || true
    ip addr add 192.168.20.1/24 dev eth1 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE: DNS MASTER ---
cat <<EOF > roles/dns_master/tasks/main.yml
---
- name: Config IP et Route Internet pour APT
  shell: |
    ip addr add 192.168.10.10/24 dev eth0 || true
    ip route add default via 192.168.10.254 || true

- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes

- name: Configuration named.conf.local
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local

- name: Configuration Fichier de Zone
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

cat <<EOF > roles/dns_master/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF

# --- ROLE: DNS SLAVE ---
cat <<EOF > roles/dns_slave/tasks/main.yml
---
- name: Config IP et Route Internet
  shell: |
    ip addr add 192.168.10.11/24 dev eth0 || true
    ip route add default via 192.168.10.254 || true

- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes

- name: Configuration zone esclave
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
- name: Config IP et Route vers Subnet B via Router
  shell: |
    ip addr add 192.168.10.12/24 dev eth0 || true
    ip route add 192.168.20.0/24 via 192.168.10.1 || true
    ip route add default via 192.168.10.254 || true

- name: Installer DHCP Server
  apt: name=isc-dhcp-server state=present update_cache=yes

- name: Configuration dhcpd.conf
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

cat <<EOF > roles/dhcp_server/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# --- ROLE: DHCP RELAY ---
cat <<EOF > roles/dhcp_relay/tasks/main.yml
---
- name: Config IP et Route Internet
  shell: |
    ip addr add 192.168.20.2/24 dev eth0 || true
    ip route add default via 192.168.20.254 || true

- name: Installer DHCP Relay
  apt: name=isc-dhcp-relay state=present update_cache=yes

- name: Lancer le service Relais (Vers serveur .12)
  shell: dhcrelay -i eth0 192.168.10.12
EOF

# -------------------------------------------------------------------------
# 5. Playbook Principal et Exécution
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

echo "--- 4. Lancement du déploiement Ansible ---"
ansible-playbook -i hosts.ini site.yml

echo "--- 5. Tests de validation ---"
echo "Demande d'IP pour le Client B sur Subnet B..."
lxc exec client-b -- dhclient -v eth0

echo "Vérification de l'IP obtenue :"
lxc exec client-b -- ip addr show eth0 | grep "inet 192.168.20"

echo ""
echo "Déploiement terminé avec succès."
