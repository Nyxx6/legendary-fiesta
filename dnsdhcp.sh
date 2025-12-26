#!/bin/bash
set -e

# =========================================================================
# Lab Réseau : DNS/DHCP/Relais/Router
# Stratégie : Install (lxdbr0) -> Config (br-sub-a/b)
# =========================================================================

# 1. PRÉPARATION DE L'INFRASTRUCTURE
echo "--- Étape 1 : Nettoyage et Création des réseaux ---"
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# Réseaux isolés pour le lab (sans DHCP LXD pour ne pas interférer)
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

echo "--- Étape 2 : Lancement sur lxdbr0 (Internet Garanti) ---"
for node in router dns-master dns-slave dhcp-server dhcp-relay client-b; do
    lxc launch ubuntu:22.04 $node
done

echo "--- Étape 3 : Branchement des câbles Lab (eth1, eth2) ---"
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
lxc network attach br-sub-b dhcp-relay eth1
lxc network attach br-sub-b client-b eth1

echo "Attente du démarrage complet (10s)..."
sleep 10

# 2. PRÉPARATION ANSIBLE
PROJECT_DIR="lab_final_smart"
mkdir -p $PROJECT_DIR/roles/{dns,dhcp,router}/{tasks,handlers}
cd $PROJECT_DIR

cat <<EOF > hosts.ini
[routers]
router ansible_connection=lxd
[dns]
dns-master ansible_connection=lxd
dns-slave ansible_connection=lxd
[dhcp]
dhcp-server ansible_connection=lxd
dhcp-relay ansible_connection=lxd
EOF

# 3. DÉFINITION DES RÔLES

# --- ROLE COMMON (Installations) ---
# On installe tout en premier pendant que eth0 est actif et fonctionnel
cat <<EOF > site_install.yml
---
- name: Phase 1 - Installation des paquets (via eth0 Internet)
  hosts: all
  become: yes
  tasks:
    - name: Installer les paquets requis
      apt:
        name: "{{ 'bind9' if 'dns' in group_names else 'isc-dhcp-server' if inventory_hostname == 'dhcp-server' else 'isc-dhcp-relay' if inventory_hostname == 'dhcp-relay' else 'iptables-persistent' }}"
        update_cache: yes
        state: present
      when: inventory_hostname != 'router' and inventory_hostname != 'client-b'
EOF

# --- ROLE ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer IP Lab et Forwarding
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE DNS ---
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Configurer IP Lab eth1
  shell: ip addr add {{ lab_ip }}/24 dev eth1 || true
- name: Configurer Bind9 pour écouter sur eth1
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

# --- ROLE DHCP ---
cat <<EOF > roles/dhcp/tasks/main.yml
---
- name: Configurer IP Lab eth1
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    {% if inventory_hostname == 'dhcp-server' %} ip route add 192.168.20.0/24 via 192.168.10.1 || true {% endif %}
- name: Configurer Serveur DHCP (Subnets A et B)
  when: inventory_hostname == 'dhcp-server'
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      option domain-name-servers 192.168.10.10;
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
  notify: restart dhcp
- name: Lancer le Relais (Ecoute eth1, vers Serveur .12)
  when: inventory_hostname == 'dhcp-relay'
  shell: killall dhcrelay || true; dhcrelay -id eth1 192.168.10.12
EOF

# HANDLERS
for r in dns dhcp; do
cat <<EOF > roles/$r/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF
done

# 4. PLAYBOOK DE CONFIGURATION
cat <<EOF > site_config.yml
---
- hosts: routers
  roles: [router]
- hosts: dns
  roles: [dns]
  vars:
    dns_type: "{{ 'master' if inventory_hostname == 'dns-master' else 'slave' }}"
    lab_ip: "{{ '192.168.10.10' if inventory_hostname == 'dns-master' else '192.168.10.11' }}"
- hosts: dhcp
  roles: [dhcp]
  vars:
    lab_ip: "{{ '192.168.10.12' if inventory_hostname == 'dhcp-server' else '192.168.20.2' }}"
EOF

# 5. EXÉCUTION
echo "--- Étape 4 : Installation logicielle ---"
ansible-playbook -i hosts.ini site_install.yml

echo "--- Étape 5 : Configuration des services ---"
ansible-playbook -i hosts.ini site_config.yml

echo ""
echo "--- TEST FINAL ---"
# On force dhclient sur eth1 pour ignorer le réseau de management eth0
lxc exec client-b -- dhclient -v eth1
echo "Résultat de l'IP du Client B (réseau 192.168.20.x attendu) :"
lxc exec client-b -- ip addr show eth1 | grep "inet "
