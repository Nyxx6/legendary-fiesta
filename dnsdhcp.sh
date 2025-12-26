#!/bin/bash
set -e

# 1. PRÉPARATION DE L'INFRASTRUCTURE LXD
echo "--- 1. Nettoyage et Création des réseaux ---"
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# Réseaux isolés (DHCP LXD désactivé)
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

echo "--- 2. Lancement des instances (Installation via eth0) ---"
for node in router dns-master dns-slave dhcp-server dhcp-relay client-b; do
    lxc launch ubuntu:22.04 $node
done

echo "--- 3. Branchement des interfaces Lab ---"
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
lxc network attach br-sub-b dhcp-relay eth1
lxc network attach br-sub-b client-b eth1

# Privilèges pour les sockets brutes (DHCP)
lxc config set dhcp-server security.privileged=true
lxc config set dhcp-relay security.privileged=true

echo "Attente du démarrage (15s)..."
sleep 15

# 2. PRÉPARATION ANSIBLE
PROJECT_DIR="lab_final_fixed"
mkdir -p $PROJECT_DIR/roles/{dns,dhcp,router}/{tasks,handlers}
cd $PROJECT_DIR

# Inventaire clair avec des noms de groupes simples
cat <<EOF > hosts.ini
[routers]
router ansible_connection=lxd

[dns_servers]
dns-master ansible_connection=lxd
dns-slave ansible_connection=lxd

[dhcp_servers]
dhcp-server ansible_connection=lxd
dhcp-relay ansible_connection=lxd
EOF

# -------------------------------------------------------------------------
# 3. PHASE D'INSTALLATION (SÉPARÉE POUR ÉVITER LES SKIPS)
# -------------------------------------------------------------------------
cat <<EOF > site_install.yml
---
- name: Installer Router
  hosts: routers
  tasks:
    - apt: name=iptables-persistent state=present update_cache=yes

- name: Installer DNS
  hosts: dns_servers
  tasks:
    - apt: name=bind9 state=present update_cache=yes

- name: Installer DHCP Server
  hosts: dhcp-server
  tasks:
    - apt: name=isc-dhcp-server state=present update_cache=yes

- name: Installer DHCP Relay
  hosts: dhcp-relay
  tasks:
    - apt: name=isc-dhcp-relay state=present update_cache=yes
EOF

# -------------------------------------------------------------------------
# 4. DÉFINITION DES RÔLES DE CONFIGURATION
# -------------------------------------------------------------------------

# --- ROLE ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Configurer Interfaces Lab et Forwarding
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- ROLE DNS ---
cat <<EOF > roles/dns/tasks/main.yml
---
- name: IP Lab DNS
  shell: ip addr add {{ lab_ip }}/24 dev eth1 || true
- name: Configurer Bind9
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
- name: IP Lab DHCP et Route
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    {% if inventory_hostname == 'dhcp-server' %} ip route add 192.168.20.0/24 via 192.168.10.1 || true {% endif %}

- name: Config Serveur DHCP
  when: inventory_hostname == 'dhcp-server'
  block:
    - copy:
        dest: /etc/dhcp/dhcpd.conf
        content: |
          option domain-name-servers 192.168.10.10;
          subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
          subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
    - service: name=isc-dhcp-server state=restarted

- name: Lancer Relais DHCP (Ecoute eth1)
  when: inventory_hostname == 'dhcp-relay'
  shell: killall dhcrelay || true; dhcrelay -id eth1 192.168.10.12
EOF

# HANDLERS
cat <<EOF > roles/dns/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF
cat <<EOF > roles/dhcp/handlers/main.yml
---
- name: restart dhcp
  service: name=isc-dhcp-server state=restarted
EOF

# -------------------------------------------------------------------------
# 5. PLAYBOOK DE CONFIGURATION
# -------------------------------------------------------------------------
cat <<EOF > site_config.yml
---
- hosts: routers
  roles: [router]

- hosts: dns_servers
  roles: [dns]
  vars:
    dns_type: "{{ 'master' if inventory_hostname == 'dns-master' else 'slave' }}"
    lab_ip: "{{ '192.168.10.10' if inventory_hostname == 'dns-master' else '192.168.10.11' }}"

- hosts: dhcp_servers
  roles: [dhcp]
  vars:
    lab_ip: "{{ '192.168.10.12' if inventory_hostname == 'dhcp-server' else '192.168.20.2' }}"
EOF

# -------------------------------------------------------------------------
# 6. EXÉCUTION
# -------------------------------------------------------------------------
echo "--- Étape 4 : Installation des paquets ---"
ansible-playbook -i hosts.ini site_install.yml

echo "--- Étape 5 : Configuration des services ---"
ansible-playbook -i hosts.ini site_config.yml

echo ""
echo "--- TEST FINAL SUR LE CLIENT B ---"
# Désactiver eth0 (LXD) pour forcer le DHCP sur eth1 (votre Lab)
lxc exec client-b -- ip link set eth0 down
lxc exec client-b -- dhclient -v eth1
echo ""
echo "Résultat de l'IP du Client B (réseau 192.168.20.x attendu) :"
lxc exec client-b -- ip addr show eth1 | grep "inet "
# Rallumer eth0
lxc exec client-b -- ip link set eth0 up
