#!/bin/bash
set -e

LAB="netlab"
ANSIBLE_DIR="./ansible-$LAB"
IMAGE="ubuntu:22.04"

ROUTER=router
DNS_MASTER=dns-master
DNS_SLAVE=dns-slave
DHCP_SERVER=dhcp-server
DHCP_RELAY=dhcp-relay
CLIENT1=client1
CLIENT2=client2

cleanup() {
  lxc delete -f $ROUTER $DNS_MASTER $DNS_SLAVE $DHCP_SERVER $DHCP_RELAY $CLIENT1 $CLIENT2 2>/dev/null || true
  lxc network delete br-sub-b 2>/dev/null || true
  lxc network delete br-sub-a 2>/dev/null || true
  rm -rf $ANSIBLE_DIR
}
trap cleanup EXIT

echo "[+] Creating Ansible structure"
mkdir -p $ANSIBLE_DIR/{inventory,playbooks,roles}

for r in router dns_master dns_slave dhcp_server dhcp_relay client; do
  mkdir -p $ANSIBLE_DIR/roles/$r/tasks
done

#################################
# Inventory
#################################
cat > $ANSIBLE_DIR/inventory/hosts.ini <<EOF
[routers]
router ansible_connection=lxd

[dns_masters]
dns-master ansible_connection=lxd

[dns_slaves]
dns-slave ansible_connection=lxd

[dhcp_servers]
dhcp-server ansible_connection=lxd

[dhcp_relays]
dhcp-relay ansible_connection=lxd

[clients]
client1 ansible_connection=lxd
client2 ansible_connection=lxd
EOF

#################################
# LXD networks
#################################
lxc network create br-sub-a ipv4.address=192.168.10.1/24 ipv4.nat=false ipv6.address=none
lxc network create br-sub-b ipv4.address=192.168.20.1/24 ipv4.nat=false ipv6.address=none

#################################
# Launch containers
#################################
for c in $ROUTER $DNS_MASTER $DNS_SLAVE $DHCP_SERVER $DHCP_RELAY $CLIENT1 $CLIENT2; do
  lxc launch $IMAGE $c
done

sleep 15

#################################
# Attach NICs
#################################
lxc network attach br-sub-a $ROUTER eth1
lxc network attach br-sub-b $ROUTER eth2

for c in $DNS_MASTER $DNS_SLAVE $DHCP_SERVER $CLIENT1; do
  lxc network attach br-sub-a $c eth1
done

for c in $DHCP_RELAY $CLIENT2; do
  lxc network attach br-sub-b $c eth1
done

#################################
# Phase 1: Package install
#################################
for c in $DNS_MASTER $DNS_SLAVE; do
  lxc exec $c -- apt update
  lxc exec $c -- apt install -y bind9
done

lxc exec $DHCP_SERVER -- apt update
lxc exec $DHCP_SERVER -- apt install -y isc-dhcp-server

lxc exec $DHCP_RELAY -- apt update
lxc exec $DHCP_RELAY -- apt install -y isc-dhcp-relay

#################################
# Ansible roles (Phase 2)
#################################

# Router role
cat > $ANSIBLE_DIR/roles/router/tasks/main.yml <<EOF
- sysctl:
    name: net.ipv4.ip_forward
    value: '1'
    state: present
    reload: yes

- command: ip addr add 192.168.10.1/24 dev eth1
  ignore_errors: yes

- command: ip addr add 192.168.20.1/24 dev eth2
  ignore_errors: yes
EOF

# DNS Master
cat > $ANSIBLE_DIR/roles/dns_master/tasks/main.yml <<EOF
- copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" {
        type master;
        file "/etc/bind/db.lab.local";
        allow-transfer { 192.168.10.11; };
      };

- copy:
    dest: /etc/bind/db.lab.local
    content: |
      \$TTL 86400
      @   IN  SOA dns-master.lab.local. root.lab.local. (
              1
              604800
              86400
              2419200
              86400 )
      @   IN  NS  dns-master.lab.local.
      @   IN  NS  dns-slave.lab.local.
      dns-master IN A 192.168.10.10
      dns-slave  IN A 192.168.10.11
      router     IN A 192.168.10.1

- service:
    name: bind9
    state: restarted
EOF

# DNS Slave
cat > $ANSIBLE_DIR/roles/dns_slave/tasks/main.yml <<EOF
- copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" {
        type slave;
        masters { 192.168.10.10; };
        file "/var/cache/bind/db.lab.local";
      };

- service:
    name: bind9
    state: restarted
EOF

# DHCP Server
cat > $ANSIBLE_DIR/roles/dhcp_server/tasks/main.yml <<EOF
- copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      subnet 192.168.10.0 netmask 255.255.255.0 {
        range 192.168.10.100 192.168.10.150;
        option routers 192.168.10.1;
        option domain-name-servers 192.168.10.10;
      }

- service:
    name: isc-dhcp-server
    state: restarted
EOF

# DHCP Relay
cat > $ANSIBLE_DIR/roles/dhcp_relay/tasks/main.yml <<EOF
- lineinfile:
    path: /etc/default/isc-dhcp-relay
    regexp: '^OPTIONS='
    line: 'OPTIONS="-i eth1 192.168.10.12"'

- service:
    name: isc-dhcp-relay
    state: restarted
EOF

#################################
# Playbook
#################################
cat > $ANSIBLE_DIR/playbooks/site.yml <<EOF
- hosts: routers
  roles:
    - router

- hosts: dns_masters
  roles:
    - dns_master

- hosts: dns_slaves
  roles:
    - dns_slave

- hosts: dhcp_servers
  roles:
    - dhcp_server

- hosts: dhcp_relays
  roles:
    - dhcp_relay
EOF

#################################
# Run Ansible
#################################
cd $ANSIBLE_DIR
ansible-playbook -i inventory/hosts.ini playbooks/site.yml

#################################
# Phase 3: Tests
#################################
lxc exec $CLIENT1 -- dhclient eth1
lxc exec $CLIENT2 -- dhclient eth1
lxc exec $CLIENT1 -- dig @192.168.10.10 router.lab.local

echo "[✓] Lab deployed, configured, tested"
sleep 10
