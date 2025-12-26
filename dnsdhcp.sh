#!/bin/bash
set -e

# 1. NETTOYAGE
echo "Nettoyage des anciennes instances..."
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# 2. INFRASTRUCTURE RÉSEAU
echo "Création des bridges isolés pour le Lab..."
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

echo "Lancement des conteneurs (Internet via eth0)..."
for node in router dns-master dns-slave dhcp-server dhcp-relay client-b; do
    lxc launch ubuntu:22.04 $node
done

echo "Attachement des interfaces du Lab (eth1, eth2)..."
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
lxc network attach br-sub-b dhcp-relay eth1

echo "Attente du démarrage (15s)..."
sleep 15

# 3. STRUCTURE ANSIBLE
PROJECT_DIR="lab_network"
mkdir -p $PROJECT_DIR/roles/{dns,dhcp,router}/{tasks,handlers}
cd $PROJECT_DIR

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

# 4. DÉFINITION DES RÔLES ET HANDLERS

# --- ROLE: ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer Interfaces Routeur
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE: DNS ---
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Configurer IP Lab
  shell: ip addr add {{ lab_ip }}/24 dev eth1 || true
- name: Configurer Bind9 (Master/Slave)
  copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" { 
        type {{ dns_type }};
        file "/var/cache/bind/db.lab";
        {% if dns_type == 'master' %} allow-transfer { 192.168.10.11; }; {% else %} masters { 192.168.10.10; }; {% endif %}
      };
  notify: restart bind
EOF

cat <<EOF > roles/dns/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF

# --- ROLE: DHCP ---
cat <<EOF > roles/dhcp/tasks/main.yml
---
- name: Installer Package DHCP
  apt: name={{ pkg_name }} state=present update_cache=yes
- name: Configurer IP Lab et Route
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    {% if inventory_hostname == 'dhcp-server' %} ip route add 192.168.20.0/24 via 192.168.10.1 || true {% endif %}
- name: Configurer Serveur DHCP
  when: inventory_hostname == 'dhcp-server'
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
  notify: restart dhcp
- name: Configurer Relais DHCP
  when: inventory_hostname == 'dhcp-relay'
  shell: killall dhcrelay || true; dhcrelay -i eth1 192.168.10.12
EOF

cat <<EOF > roles/dhcp/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# 5. PLAYBOOK PRINCIPAL
cat <<EOF > site.yml
---
- hosts: routers
  roles: [router]

- hosts: dns_master,dns_slave
  roles: [dns]
  vars:
    dns_type: "{{ 'master' if inventory_hostname == 'dns-master' else 'slave' }}"
    lab_ip: "{{ '192.168.10.10' if inventory_hostname == 'dns-master' else '192.168.10.11' }}"

- hosts: dhcp_server,dhcp_relay
  roles: [dhcp]
  vars:
    pkg_name: "{{ 'isc-dhcp-server' if inventory_hostname == 'dhcp-server' else 'isc-dhcp-relay' }}"
    lab_ip: "{{ '192.168.10.12' if inventory_hostname == 'dhcp-server' else '192.168.20.2' }}"
EOF

# 6. EXÉCUTION
echo "Lancement d'Ansible..."
ansible-playbook -i hosts.ini site.yml

echo ""
echo "--- TEST FINAL DU CLIENT B ---"
# Le client B est sur br-sub-b, il doit recevoir une IP via le relais
lxc exec client-b -- dhclient -v eth0
echo "Résultat de l'IP du Client B :"
lxc exec client-b -- ip addr show eth0 | grep "inet 192.168.20"
