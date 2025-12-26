#!/bin/bash
set -e

# 1. NETTOYAGE TOTAL
echo "Nettoyage..."
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# 2. INFRASTRUCTURE RÉSEAU (SANS DHCP LXD)
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

echo "Lancement des conteneurs..."
for node in router dns-master dns-slave dhcp-server dhcp-relay client-b; do
    lxc launch ubuntu:22.04 $node
done

echo "Attachement des interfaces du Lab..."
# Router : eth1(Sub-A), eth2(Sub-B)
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
# Serveurs Sub-A : eth1
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
# Sub-B : eth1
lxc network attach br-sub-b dhcp-relay eth1
lxc network attach br-sub-b client-b eth1

echo "Attente du boot (10s)..."
sleep 10

# 3. ANSIBLE STRUCTURE
PROJECT_DIR="lab_network_final"
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

# 4. RÔLES ANSIBLE

# ROUTER
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer Routage
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# DNS (MASTER/SLAVE)
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: IP Lab DNS
  shell: ip addr add {{ lab_ip }}/24 dev eth1 || true
- name: Config Bind9
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

# DHCP (SERVER/RELAY)
cat <<EOF > roles/dhcp/tasks/main.yml
---
- name: Installer Package DHCP
  apt: name={{ pkg_name }} state=present update_cache=yes
- name: IP Lab DHCP et Route
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    {% if inventory_hostname == 'dhcp-server' %} ip route add 192.168.20.0/24 via 192.168.10.1 || true {% endif %}
- name: Config Serveur DHCP
  when: inventory_hostname == 'dhcp-server'
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
  notify: restart dhcp
- name: Lancer Relais DHCP (écoute sur eth1)
  when: inventory_hostname == 'dhcp-relay'
  shell: killall dhcrelay || true; dhcrelay -id eth1 192.168.10.12
EOF
cat <<EOF > roles/dhcp/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# 5. PLAYBOOK
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

# 6. EXECUTION
ansible-playbook -i hosts.ini site.yml

echo ""
echo "--- TEST FINAL SUR INTERFACE ISOLEE (eth1) ---"
# On force dhclient sur eth1, car eth0 est déjà pris par le réseau LXD
lxc exec client-b -- dhclient -v eth1
echo ""
echo "Résultat de l'IP du Client B sur le réseau 192.168.20.x :"
lxc exec client-b -- ip addr show eth1 | grep "inet 192.168.20"
