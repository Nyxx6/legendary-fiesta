#!/bin/bash
set -e

PROJECT_DIR="ansible_network_lab"
ROLES=("router" "dns_master" "dns_slave" "dhcp_server" "dhcp_relay")

echo "--- Étape 1 : Structure des dossiers ---"
for role in "${ROLES[@]}"; do
    mkdir -p "$PROJECT_DIR/roles/$role/tasks" "$PROJECT_DIR/roles/$role/templates" "$PROJECT_DIR/roles/$role/handlers"
done
cd $PROJECT_DIR

echo "--- Étape 2 : Réseaux LXD avec NAT (pour APT) ---"
# On donne une IP au bridge côté hôte (.254) pour servir de passerelle internet
lxc network delete br-sub-a >/dev/null 2>&1 || true
lxc network create br-sub-a ipv4.address=192.168.10.254/24 ipv4.nat=true ipv4.dhcp=false

lxc network delete br-sub-b >/dev/null 2>&1 || true
lxc network create br-sub-b ipv4.address=192.168.20.254/24 ipv4.nat=true ipv4.dhcp=false

echo "--- Étape 3 : Instances ---"
declare -A nodes=( ["router"]="br-sub-a" ["dns-master"]="br-sub-a" ["dns-slave"]="br-sub-a" ["dhcp-server"]="br-sub-a" ["dhcp-relay"]="br-sub-b" ["client-b"]="br-sub-b" )

for node in "${!nodes[@]}"; do
    lxc delete -f "$node" >/dev/null 2>&1 || true
    lxc launch ubuntu:22.04 "$node" --network "${nodes[$node]}"
done

lxc network attach br-sub-b router eth1
lxc config set dhcp-relay security.privileged=true 

echo "Attente démarrage (10s)..."
sleep 10

# --- Fichiers Ansible ---
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

# --- ROLE: DNS MASTER (CORRIGÉ : IP d'abord, APT ensuite) ---
cat <<EOF > roles/dns_master/tasks/main.yml
---
- name: Configurer IP et Gateway temporaire pour Internet
  shell: |
    ip addr add 192.168.10.10/24 dev eth0 || true
    ip route add default via 192.168.10.254 || true

- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes

- name: Config zone
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
- name: Fichier zone
  template: src=db.lab.local.j2 dest=/var/cache/bind/db.lab.local
  notify: restart bind
EOF

# --- ROLE: DNS SLAVE (CORRIGÉ) ---
cat <<EOF > roles/dns_slave/tasks/main.yml
---
- name: Configurer IP et Gateway temporaire
  shell: |
    ip addr add 192.168.10.11/24 dev eth0 || true
    ip route add default via 192.168.10.254 || true
- name: Installer Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Config zone slave
  template: src=named.conf.local.j2 dest=/etc/bind/named.conf.local
  notify: restart bind
EOF

# --- ROLE: DHCP SERVER (CORRIGÉ) ---
cat <<EOF > roles/dhcp_server/tasks/main.yml
---
- name: Configurer IP et Gateway temporaire
  shell: |
    ip addr add 192.168.10.12/24 dev eth0 || true
    ip route add default via 192.168.10.254 || true
- name: Installer ISC DHCP
  apt: name=isc-dhcp-server state=present update_cache=yes
- name: Config dhcpd.conf
  template: src=dhcpd.conf.j2 dest=/etc/dhcp/dhcpd.conf
  notify: restart dhcp
EOF

# (Recopiez le reste des templates et handlers du script précédent ici...)
# Note: Pensez à bien créer les fichiers templates et handlers comme avant.

# --- HANDLERS (Exemple pour dns_master) ---
cat <<EOF > roles/dns_master/handlers/main.yml
---
- name: restart bind
  service: name=bind9 state=restarted
EOF
# (Faites de même pour les autres handlers...)

cat <<EOF > site.yml
---
- hosts: dns_master
  roles: [dns_master]
- hosts: dns_slave
  roles: [dns_slave]
- hosts: dhcp_server
  roles: [dhcp_server]
EOF

ansible-playbook -i hosts.ini site.yml
