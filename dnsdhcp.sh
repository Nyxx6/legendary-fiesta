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
# Phase 1.5: Configure network with netplan
#################################
echo "[+] Configuring network with netplan"

# DNS Master
lxc exec $DNS_MASTER -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [192.168.10.10/24]
      routes:
        - to: default
          via: 192.168.10.1
NETPLAN
netplan apply"

# DNS Slave
lxc exec $DNS_SLAVE -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [192.168.10.11/24]
      routes:
        - to: default
          via: 192.168.10.1
NETPLAN
netplan apply"

# DHCP Server
lxc exec $DHCP_SERVER -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [192.168.10.12/24]
      routes:
        - to: default
          via: 192.168.10.1
NETPLAN
netplan apply"

# DHCP Relay
lxc exec $DHCP_RELAY -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [192.168.20.2/24]
      routes:
        - to: default
          via: 192.168.20.1
NETPLAN
netplan apply"

sleep 5
echo "[+] Network configured with netplan"

#################################
# Ansible roles (Phase 2)
#################################
cat > $ANSIBLE_DIR/ansible.cfg <<EOF
[defaults]
roles_path = ./roles
inventory = ./inventory/hosts.ini
host_key_checking = False
EOF

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
- name: Ensure bind listens on all IPv4 interfaces
  copy:
    dest: /etc/default/named
    content: |
      OPTIONS="-u bind -4"

- name: Configure named.conf.options
  copy:
    dest: /etc/bind/named.conf.options
    content: |
      options {
        directory "/var/cache/bind";
        listen-on { any; };
        allow-query { any; };
        recursion yes;
        allow-recursion { 192.168.10.0/24; 192.168.20.0/24; };
      };

- name: Configure master zone
  copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" {
        type master;
        file "/etc/bind/db.lab.local";
        allow-transfer { 192.168.10.11; };
      };

- name: Create master zone file
  copy:
    dest: /etc/bind/db.lab.local
    content: |
      \$TTL 86400
      @   IN  SOA dns-master.lab.local. root.lab.local. (
                  1          ; Serial
                  604800     ; Refresh
                  86400      ; Retry
                  2419200    ; Expire
                  86400 )    ; Negative Cache TTL
      @   IN  NS  dns-master.lab.local.
      @   IN  NS  dns-slave.lab.local.
      dns-master IN A 192.168.10.10
      dns-slave  IN A 192.168.10.11
      router     IN A 192.168.10.1

- name: Restart bind
  service:
    name: bind9
    state: restarted
EOF

# DNS Slave
cat > $ANSIBLE_DIR/roles/dns_slave/tasks/main.yml <<EOF
- name: Configure named.conf.options
  copy:
    dest: /etc/bind/named.conf.options
    content: |
      options {
        directory "/var/cache/bind";
        listen-on { any; };
        allow-query { any; };
        recursion yes;
        allow-recursion { 192.168.10.0/24; 192.168.20.0/24; };
      };

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
    dest: /etc/default/isc-dhcp-server
    content: |
      INTERFACESv4="eth1"

- copy:
    dest: /etc/dhcp/dhcpd.conf
    content: |
      authoritative;
      subnet 192.168.10.0 netmask 255.255.255.0 {
        range 192.168.10.100 192.168.10.150;
        option routers 192.168.10.1;
        option domain-name-servers 192.168.10.10;
        option domain-name "lab.local";
      }
      subnet 192.168.20.0 netmask 255.255.255.0 {
        range 192.168.20.100 192.168.20.150;
        option routers 192.168.20.1;
        option domain-name-servers 192.168.10.10;
        option domain-name "lab.local";
      }

- service:
    name: isc-dhcp-server
    state: restarted
EOF

# DHCP Relay
cat > $ANSIBLE_DIR/roles/dhcp_relay/tasks/main.yml <<EOF
- copy:
    dest: /etc/default/isc-dhcp-relay
    content: |
      SERVERS="192.168.10.12"
      INTERFACES="eth1"
      OPTIONS=""

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
echo "[+] Phase 3: Running verification tests"
sleep 5

echo "[TEST] DHCP on Client 1 (Subnet A)"
lxc exec client1 -- dhclient -r eth1 2>/dev/null || true
lxc exec client1 -- dhclient -v eth1

echo "[TEST] DHCP on Client 2 (Subnet B via relay)"
lxc exec client2 -- dhclient -r eth1 2>/dev/null || true
lxc exec client2 -- dhclient -v eth1

sleep 2

echo "[TEST] Client1 IP:"
lxc exec client1 -- ip addr show eth1 | grep "inet "

echo "[TEST] Client2 IP:"
lxc exec client2 -- ip addr show eth1 | grep "inet "

echo "[TEST] Routing Client1 -> Router Subnet B"
lxc exec client1 -- ping -c 2 192.168.20.1 || echo "FAILED"

echo "[TEST] Routing Client2 -> Router Subnet A"
lxc exec client2 -- ping -c 2 192.168.10.1 || echo "FAILED"

echo "[TEST] DNS local on master"
lxc exec dns-master -- dig @127.0.0.1 router.lab.local +short

echo "[TEST] DNS remote from Client1"
lxc exec client1 -- dig @192.168.10.10 router.lab.local +short

echo "[TEST] DNS slave sync"
lxc exec dns-slave -- dig @127.0.0.1 router.lab.local +short

echo "[✓] ALL TESTS COMPLETED"

echo "[✓] Lab deployed, configured, tested"
sleep 10
