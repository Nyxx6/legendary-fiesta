#!/bin/bash
set -e

# 1. NETTOYAGE COMPLET
echo "--- Nettoyage ---"
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# 2. RÉSEAUX ISOLÉS
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

# 3. INSTANCES
for node in router dns-master dns-slave dhcp-server dhcp-relay client-b; do
    lxc launch ubuntu:22.04 $node
    lxc config set $node security.privileged=true
done

# Attachement interfaces réseaux
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
lxc network attach br-sub-b dhcp-relay eth1
lxc network attach br-sub-b client-b eth1

echo "Attente démarrage (10s)..."
sleep 10

# 4. STRUCTURE ANSIBLE
PROJECT_DIR="lab_ansible_final"
mkdir -p $PROJECT_DIR/roles/{dns,dhcp,router}/{tasks,handlers}
cd $PROJECT_DIR

cat <<EOF > hosts.ini
[routers]
router ansible_connection=lxd
[dns]
dns-master ansible_connection=lxd
dns-slave ansible_connection=lxd
[dhcp_server]
dhcp-server ansible_connection=lxd
[dhcp_relay]
dhcp-relay ansible_connection=lxd
EOF

# --- ROLE ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer Routage
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE DNS ---
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Config IP et Route vers le Lab
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    ip route add 192.168.0.0/16 via {{ gateway }} || true
EOF

# --- ROLE DHCP (CORRIGÉ AVEC ROUTAGE PRÉCIS) ---
cat <<EOF > roles/dhcp/tasks/main.yml
---
- name: Installer Package DHCP
  apt: name={{ pkg }} state=present update_cache=yes

- name: Configurer IP Lab et ROUTAGE INTERNE (Crucial)
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    # On force tout le trafic 192.168.x.x à passer par le routeur, PAS par eth0
    ip route add 192.168.0.0/16 via {{ gateway }} || true

- name: Configurer SERVEUR DHCP
  when: inventory_hostname == 'dhcp-server'
  block:
    - copy:
        dest: /etc/dhcp/dhcpd.conf
        content: |
          log-facility local7;
          authoritative;
          subnet 192.168.10.0 netmask 255.255.255.0 { 
            range 192.168.10.50 192.168.10.60; 
            option routers 192.168.10.1; 
          }
          subnet 192.168.20.0 netmask 255.255.255.0 { 
            range 192.168.20.50 192.168.20.60; 
            option routers 192.168.20.1; 
          }
    - shell: |
        sed -i 's/INTERFACESv4=""/INTERFACESv4="eth1"/' /etc/default/isc-dhcp-server
    - service: name=isc-dhcp-server state=restarted

- name: Lancer RELAIS DHCP
  when: inventory_hostname == 'dhcp-relay'
  shell: |
    killall dhcrelay || true
    # dhcrelay [options] -i <interface_client> <ip_serveur>
    dhcrelay -4 -i eth1 192.168.10.12
EOF

# 5. PLAYBOOK
cat <<EOF > site.yml
---
- hosts: routers
  roles: [router]
- hosts: dns
  roles: [dns]
  vars:
    lab_ip: "{{ '192.168.10.10' if inventory_hostname == 'dns-master' else '192.168.10.11' }}"
    gateway: 192.168.10.1
- hosts: dhcp_server,dhcp_relay
  roles: [dhcp]
  vars:
    pkg: "{{ 'isc-dhcp-server' if inventory_hostname == 'dhcp-server' else 'isc-dhcp-relay' }}"
    lab_ip: "{{ '192.168.10.12' if inventory_hostname == 'dhcp-server' else '192.168.20.2' }}"
    gateway: "{{ '192.168.10.1' if inventory_hostname == 'dhcp-server' else '192.168.20.1' }}"
EOF

ansible-playbook -i hosts.ini site.yml

echo ""
echo "--- TEST FINAL SUR LE CLIENT B ---"
# 1. Éteindre eth0 pour être sûr de ne pas recevoir l'IP de LXD
lxc exec client-b -- ip link set eth0 down
# 2. Lancer la requête sur eth1
echo "Envoi de la requête DHCP sur eth1..."
lxc exec client-b -- dhclient -v eth1
echo ""
echo "Vérification de l'IP (Plage 192.168.20.50-60 attendue) :"
lxc exec client-b -- ip addr show eth1 | grep "inet 192.168.20"
# 3. Rallumer eth0
lxc exec client-b -- ip link set eth0 up
