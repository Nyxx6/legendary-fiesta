#!/bin/bash
set -e

# =========================================================================
# Lab Réseau Complet - Version Stable (Fix DNS Resolution for APT)
# =========================================================================

PROJECT_DIR="ansible_network_lab"
ROLES=("router" "dns_master" "dns_slave" "dhcp_server" "dhcp_relay")

echo "--- 1. Structure Ansible ---"
rm -rf $PROJECT_DIR
for role in "${ROLES[@]}"; do
    mkdir -p "$PROJECT_DIR/roles/$role/tasks" "$PROJECT_DIR/roles/$role/templates" "$PROJECT_DIR/roles/$role/handlers"
done
cd $PROJECT_DIR

echo "--- 2. Réseaux LXD ---"
lxc network delete br-sub-a >/dev/null 2>&1 || true
lxc network create br-sub-a ipv4.address=192.168.10.254/24 ipv4.nat=true ipv4.dhcp=false

lxc network delete br-sub-b >/dev/null 2>&1 || true
lxc network create br-sub-b ipv4.address=192.168.20.254/24 ipv4.nat=true ipv4.dhcp=false

echo "--- 3. Instances ---"
declare -A nodes=( ["router"]="br-sub-a" ["dns-master"]="br-sub-a" ["dns-slave"]="br-sub-a" ["dhcp-server"]="br-sub-a" ["dhcp-relay"]="br-sub-b" ["client-b"]="br-sub-b" )

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

lxc network attach br-sub-b router eth1
lxc config set dhcp-relay security.privileged=true 

echo "Attente démarrage (15s)..."
sleep 15

# --- Fichiers de base ---
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
# 4. Rôles avec Correctif de Connectivité (IP + GW + DNS Google)
# -------------------------------------------------------------------------

# Fonctions pour générer les tâches redondantes (Connectivité avant APT)
gen_connectivity_tasks() {
    local ip=$1
    local gw=$2
    cat <<TASK
- name: Configurer Connectivité Internet (IP, Gateway, DNS)
  shell: |
    ip addr add $ip/24 dev eth0 || true
    ip route add default via $gw || true
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
TASK
}

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
{
gen_connectivity_tasks "192.168.10.10" "192.168.10.254"
cat <<EOF
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Configuration Bind
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
- name: Fichier Zone
  template: src=db.lab.local.j2 dest=/var/cache/bind/db.lab.local
  notify: restart bind
EOF
} > roles/dns_master/tasks/main.yml

cat <<EOF > roles/dns_master/templates/named.conf.local.j2
zone "lab.local" { type master; file "/var/cache/bind/db.lab.local"; allow-transfer { 192.168.10.11; }; };
EOF

cat <<EOF > roles/dns_master/templates/db.lab.local.j2
\$TTL 604800
@ IN SOA ns1.lab.local. admin.lab.local. (1 604800 86400 2419200 604800)
@ IN NS ns1.lab.local.
@ IN NS ns2.lab.local.
ns1 IN A 192.168.10.10
ns2 IN A 192.168.10.11
EOF

# --- ROLE: DNS SLAVE ---
{
gen_connectivity_tasks "192.168.10.11" "192.168.10.254"
cat <<EOF
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Config Slave
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
  notify: restart bind
EOF
} > roles/dns_slave/tasks/main.yml

cat <<EOF > roles/dns_slave/templates/named.conf.local.j2
zone "lab.local" { type slave; file "/var/cache/bind/db.lab.local"; masters { 192.168.10.10; }; };
EOF

# --- ROLE: DHCP SERVER ---
{
gen_connectivity_tasks "192.168.10.12" "192.168.10.254"
cat <<EOF
- name: Route vers Subnet B
  shell: ip route add 192.168.20.0/24 via 192.168.10.1 || true
- name: Installer DHCP
  apt: name=isc-dhcp-server state=present update_cache=yes
- name: Config DHCP
  template: src=dhcpd.conf.j2 dest=/etc/dhcp/dhcpd.conf
  notify: restart dhcp
EOF
} > roles/dhcp_server/tasks/main.yml

cat <<EOF > roles/dhcp_server/templates/dhcpd.conf.j2
option domain-name "lab.local";
option domain-name-servers 192.168.10.10, 192.168.10.11;
default-lease-time 600;
max-lease-time 7200;
authoritative;
subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
EOF

# --- ROLE: DHCP RELAY ---
{
gen_connectivity_tasks "192.168.20.2" "192.168.20.254"
cat <<EOF
- name: Installer DHCP Relay
  apt: name=isc-dhcp-relay state=present update_cache=yes
- name: Lancer Relais
  shell: dhcrelay -i eth0 192.168.10.12
EOF
} > roles/dhcp_relay/tasks/main.yml

# --- Handlers ---
cat <<EOF > roles/dns_master/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF
cp roles/dns_master/handlers/main.yml roles/dns_slave/handlers/main.yml
cat <<EOF > roles/dhcp_server/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# -------------------------------------------------------------------------
# 5. Playbook & Run
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

echo "--- 4. Lancement Ansible ---"
ansible-playbook -i hosts.ini site.yml

echo "--- 5. Test Final ---"
lxc exec client-b -- dhclient -v eth0
lxc exec client-b -- ip addr show eth0 | grep "inet 192.168.20"
