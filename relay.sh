#!/bin/bash
set -e

LAB="netlab"
ANSIBLE_DIR=$LAB
IMAGE="ubuntu:22.04"

ROUTER=router
DNS_MASTER=dns-master
DNS_SLAVE=dns-slave
DHCP_SERVER=dhcp-server
DHCP_RELAY=dhcp-relay
CLIENT1=client1
CLIENT2=client2

# Network Definitions
Sub_A="192.168.10.0/24"
Sub_B="192.168.20.0/24"
Sub_A_Net="192.168.10.0"
Sub_B_Net="192.168.20.0"
Netmask="255.255.255.0"

# IP Addresses
IP_Router_eth1="192.168.10.1/24"
IP_Router_eth2="192.168.20.1/24"
IP_dns_master="192.168.10.10/24"
IP_dns_slave="192.168.20.10/24"
IP_dhcp_server="192.168.10.2/24"
IP_dhcp_relay="192.168.20.2/24"

# IP Addresses (without CIDR)
IP_Router_eth1_raw="192.168.10.1"
IP_Router_eth2_raw="192.168.20.1"
IP_dns_master_raw="192.168.10.10"
IP_dns_slave_raw="192.168.20.10"
IP_dhcp_server_raw="192.168.10.2"
IP_dhcp_relay_raw="192.168.20.2"

# DHCP Ranges
DHCP_SubA_Start="192.168.10.100"
DHCP_SubA_End="192.168.10.150"
DHCP_SubB_Start="192.168.20.100"
DHCP_SubB_End="192.168.20.150"

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
lxc network create br-sub-a ipv4.address=$IP_Router_eth1 ipv4.nat=false ipv6.address=none
lxc network create br-sub-b ipv4.address=$IP_Router_eth2 ipv4.nat=false ipv6.address=none

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

# Subnet A : DNS Master, DHCP Server, Client1
for c in $DNS_MASTER $DHCP_SERVER $CLIENT1; do
  lxc network attach br-sub-a $c eth1
done

# Subnet B : DNS Slave, DHCP Relay, Client2
for c in $DNS_SLAVE $DHCP_RELAY $CLIENT2; do
  lxc network attach br-sub-b $c eth1
done

#################################
# Package install
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
# Configure network with netplan
#################################
echo "[+] Configuring network with netplan"

# DNS Master
lxc exec $DNS_MASTER -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [$IP_dns_master]
      routes:
        - to: default
          via: $IP_Router_eth1_raw
NETPLAN
netplan apply"

# DNS Slave
lxc exec $DNS_SLAVE -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [$IP_dns_slave]
      routes:
        - to: default
          via: $IP_Router_eth2_raw
NETPLAN
netplan apply"

# DHCP Server
lxc exec $DHCP_SERVER -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [$IP_dhcp_server]
      routes:
        - to: default
          via: $IP_Router_eth1_raw
NETPLAN
netplan apply"

# DHCP Relay
lxc exec $DHCP_RELAY -- bash -c "cat > /etc/netplan/10-eth1.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth1:
      addresses: [$IP_dhcp_relay]
      routes:
        - to: default
          via: $IP_Router_eth2_raw
NETPLAN
netplan apply"

sleep 5
echo "[+] Network configured with netplan"

#################################
# Ansible roles
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

- command: ip addr add $IP_Router_eth1 dev eth1
  ignore_errors: yes

- command: ip addr add $IP_Router_eth2 dev eth2
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
        allow-recursion { $Sub_A; $Sub_B; };
      };

- name: Configure master zone
  copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" {
        type master;
        file "/etc/bind/db.lab.local";
        allow-transfer { $IP_dns_slave_raw; };
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
      dns-master IN A $IP_dns_master_raw
      dns-slave  IN A $IP_dns_slave_raw
      router     IN A $IP_Router_eth1_raw

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
        allow-recursion { $Sub_A; $Sub_B; };
      };

- copy:
    dest: /etc/bind/named.conf.local
    content: |
      zone "lab.local" {
        type slave;
        masters { $IP_dns_master_raw; };
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
      subnet $Sub_A_Net netmask $Netmask {
        range $DHCP_SubA_Start $DHCP_SubA_End;
        option routers $IP_Router_eth1_raw;
        option domain-name-servers $IP_dns_master_raw;
        option domain-name "lab.local";
      }
      subnet $Sub_B_Net netmask $Netmask {
        range $DHCP_SubB_Start $DHCP_SubB_End;
        option routers $IP_Router_eth2_raw;
        option domain-name-servers $IP_dns_slave_raw;
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
      SERVERS="$IP_dhcp_server_raw"
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
# Tests & Validation
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
lxc exec client1 -- ping -c 2 $IP_Router_eth2_raw || echo "FAILED"

echo "[TEST] Routing Client2 -> Router Subnet A"
lxc exec client2 -- ping -c 2 $IP_Router_eth1_raw || echo "FAILED"

echo "[TEST] DNS Master check service status"
lxc exec dns-master -- systemctl status bind9

echo "[TEST] DNS Slave check service status"
lxc exec dns-slave -- systemctl status bind9

echo "[TEST] DNS Master resolves router.lab.local"
lxc exec dns-master -- dig @127.0.0.1 router.lab.local +short

echo "[TEST] DNS Slave zone transfer file check"
lxc exec dns-slave -- ls -l /var/cache/bind/db.lab.local

echo "[TEST] DNS Slave resolves router.lab.local"
lxc exec dns-slave -- dig @127.0.0.1 router.lab.local +short

echo "[TEST] Client1 queries DNS Master"
lxc exec client1 -- dig @$IP_dns_master_raw router.lab.local +short

echo "[TEST] Client1 queries DNS Slave (cross-subnet)"
lxc exec client1 -- dig @$IP_dns_slave_raw router.lab.local +short

echo "[TEST] Client2 queries DNS Slave (local subnet)"
lxc exec client2 -- dig @$IP_dns_slave_raw router.lab.local +short

echo "[TEST] DHCP Server leases"
lxc exec dhcp-server -- cat /var/lib/dhcp/dhcpd.leases

echo "[+] Verification tests completed"
echo "[+] Containers are running.. Press Ctrl+C to terminate (automatic cleanup will be performed in 1 hour)"

sleep 3600
