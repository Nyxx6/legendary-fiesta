#!/bin/bash
set -e

# 1. CLEANUP
echo "Cleaning up..."
lxc delete -f router dns-master dns-slave dhcp-server dhcp-relay client-b 2>/dev/null || true
lxc network delete br-sub-a 2>/dev/null || true
lxc network delete br-sub-b 2>/dev/null || true

# 2. INFRASTRUCTURE
echo "Creating private bridges..."
lxc network create br-sub-a ipv4.address=none ipv6.address=none
lxc network create br-sub-b ipv4.address=none ipv6.address=none

echo "Launching containers on default bridge (for internet access)..."
# They start on lxdbr0 (eth0) to get internet/DNS automatically
for node in router dns-master dns-slave dhcp-server dhcp-relay; do
    lxc launch ubuntu:22.04 $node
done
lxc launch ubuntu:22.04 client-b --network br-sub-b

echo "Attaching lab interfaces..."
lxc network attach br-sub-a router eth1
lxc network attach br-sub-b router eth2
lxc network attach br-sub-a dns-master eth1
lxc network attach br-sub-a dns-slave eth1
lxc network attach br-sub-a dhcp-server eth1
lxc network attach br-sub-b dhcp-relay eth1

echo "Waiting for boot..."
sleep 10

# 3. ANSIBLE CONFIG
mkdir -p roles/{dns,dhcp,router}/tasks
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

# 4. ROLES DEFINITION
# --- ROUTER ---
cat <<EOF > roles/router/tasks/main.yml
---
- name: Setup Router Interfaces
  shell: |
    ip addr add 192.168.10.1/24 dev eth1 || true
    ip addr add 192.168.20.1/24 dev eth2 || true
    sysctl -w net.ipv4.ip_forward=1
EOF

# --- DNS ---
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Install Bind9
  apt: name=bind9 state=present update_cache=yes
- name: Setup IP
  shell: ip addr add {{ lab_ip }}/24 dev eth1 || true
- name: Simple Master/Slave Config
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

# --- DHCP ---
cat <<EOF > roles/dhcp/tasks/main.yml
---
- name: Install DHCP Service
  apt: name={{ pkg_name }} state=present update_cache=yes
- name: Setup IP
  shell: |
    ip addr add {{ lab_ip }}/24 dev eth1 || true
    {% if inventory_hostname == 'dhcp-server' %} ip route add 192.168.20.0/24 via 192.168.10.1 || true {% endif %}
- name: Config DHCP Server
  when: inventory_hostname == 'dhcp-server'
  copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      subnet 192.168.10.0 netmask 255.255.255.0 { range 192.168.10.50 192.168.10.100; option routers 192.168.10.1; }
      subnet 192.168.20.0 netmask 255.255.255.0 { range 192.168.20.50 192.168.20.100; option routers 192.168.20.1; }
  notify: restart dhcp
- name: Start Relay
  when: inventory_hostname == 'dhcp-relay'
  shell: killall dhcrelay || true; dhcrelay -i eth1 192.168.10.12
EOF

# 5. PLAYBOOK
cat <<EOF > site.yml
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
    pkg_name: "{{ 'isc-dhcp-server' if inventory_hostname == 'dhcp-server' else 'isc-dhcp-relay' }}"
    lab_ip: "{{ '192.168.10.12' if inventory_hostname == 'dhcp-server' else '192.168.20.2' }}"

  handlers:
    - name: restart bind
      service: name=bind9 state=restarted
    - name: restart dhcp
      service: name=isc-dhcp-server state=restarted
EOF

# 6. RUN
echo "Running Ansible..."
ansible-playbook -i hosts.ini site.yml

echo "--- TEST CLIENT-B ---"
lxc exec client-b -- dhclient -v eth0
lxc exec client-b -- ip addr show eth0 | grep "inet 192.168.20"
