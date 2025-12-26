#!/bin/bash
set -e

PROJECT_DIR="tp_reseau_final"
mkdir -p $PROJECT_DIR/roles/{common,router,dns_master,dns_slave,dhcp_server,dhcp_relay,client}/templates
mkdir -p $PROJECT_DIR/roles/{dns_master,dns_slave,dhcp_server,dhcp_relay}/handlers
cd $PROJECT_DIR

# 1. INVENTAIRE
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

# 2. INFRASTRUCTURE LXD (Inspiré de votre play.txt)
echo "--- Création des réseaux et conteneurs ---"
lxc network create br01 ipv4.address=none ipv6.address=none ipv4.dhcp=false || true
lxc network create br02 ipv4.address=none ipv6.address=none ipv4.dhcp=false || true

# Lancement des instances
declare -A nodes=( ["router"]="br01" ["dns-master"]="br01" ["dns-slave"]="br01" ["dhcp-server"]="br01" ["dhcp-relay"]="br02" ["client-b"]="br02" )
for node in "${!nodes[@]}"; do
    lxc delete -f $node 2>/dev/null || true
    lxc launch ubuntu:22.04 $node --network ${nodes[$node]}
done

# Interfaces secondaires (Gateway)
lxc network attach br02 router eth1
lxc config set dhcp-relay security.privileged=true

echo "Booting (10s)..." ; sleep 10

# -------------------------------------------------------------------------
# 3. RÔLES ANSIBLE (Templates Netplan & Services)
# -------------------------------------------------------------------------

# --- TEMPLATE NETPLAN GÉNÉRIQUE (Utilisé par les rôles) ---
cat <<EOF > roles/common/templates/netplan_static.yaml.j2
network:
  version: 2
  ethernets:
    eth0:
      addresses: [{{ lab_ip }}/24]
      routes:
        - to: default
          via: {{ gateway_ip }}
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

# --- ROLE: ROUTER (NAT & Forwarding) ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Installer Iptables
  apt: name=iptables-persistent state=present update_cache=yes
- name: Configuration IP Routeur (Netplan)
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
- name: NAT Masquerade
  iptables: table=nat chain=POSTROUTING out_interface=eth0 jump=MASQUERADE
EOF

# --- ROLE: DNS MASTER ---
cat <<EOF > roles/dns_master/tasks/main.yml
---
- name: Config Réseau
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.10.10", gateway_ip: "192.168.10.1" }
  notify: apply netplan
- name: Install Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Zone Config
  copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "tp.local" { type master; file "/etc/bind/db.tp.local"; allow-transfer { 192.168.10.11; }; };
- name: Zone File
  copy:
    dest: /etc/bind/db.tp.local
    content: |
      \$TTL 604800
      @ IN SOA ns1.tp.local. root.tp.local. (1 604800 86400 2419200 604800)
      @ IN NS ns1.tp.local.
      ns1 IN A 192.168.10.10
  notify: restart bind
EOF

# --- ROLE: DHCP SERVER ---
cat <<EOF > roles/dhcp_server/tasks/main.yml
---
- name: Config Réseau
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.10.12", gateway_ip: "192.168.10.1" }
  notify: apply netplan
- name: Route vers Subnet B via Routeur
  shell: ip route add 192.168.20.0/24 via 192.168.10.1 || true
- name: Install DHCP Server
  apt: name=isc-dhcp-server state=present update_cache=yes
- name: Config DHCPD
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      option domain-name-servers 192.168.10.10;
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
  notify: restart dhcp
EOF

# --- ROLE: DHCP RELAY ---
cat <<EOF > roles/dhcp_relay/tasks/main.yml
---
- name: Config Réseau
  template: src=../../common/templates/netplan_static.yaml.j2 dest=/etc/netplan/60-static.yaml
  vars: { lab_ip: "192.168.20.2", gateway_ip: "192.168.20.1" }
  notify: apply netplan
- name: Install Relay
  apt: name=isc-dhcp-relay state=present
- name: Run Relay
  shell: killall dhcrelay || true; dhcrelay -id eth0 192.168.10.12
EOF

# --- HANDLERS (Communs) ---
for r in router dns_master dhcp_server dhcp_relay; do
cat <<EOF > roles/$r/handlers/main.yml
---
- name: apply netplan
  shell: netplan apply
- name: restart bind
  service: name=bind9 state=restarted
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
- name: restart nginx
  service: name=nginx state=restarted
EOF
done

# -------------------------------------------------------------------------
# 4. PLAYBOOK PRINCIPAL
# -------------------------------------------------------------------------
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

echo "--- Lancement Ansible ---"
ansible-playbook -i hosts.ini site.yml

echo "--- Test DHCP Client B ---"
lxc exec client-b -- dhclient -v eth0
echo "IP obtenue par le client :"
lxc exec client-b -- ip addr show eth0 | grep "inet "
