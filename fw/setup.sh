#!/bin/bash
set -e

DELETE_ALL=0

# --- Machines ---
CLIENT_WAN="client-wan"
FW1="fw1"
FW2="fw2"
SRV_DMZ="srv-dmz"
CLIENT_LAN="client-lan"
ADMIN_LAN="admin-lan"

ALL_VMS="$CLIENT_WAN $FW1 $FW2 $SRV_DMZ $CLIENT_LAN $ADMIN_LAN"

# --- Networks ---
NET_WAN="br-wan"        # 10.2.2.0/24 (simulated internet)
NET_DMZ="br-dmz"        # 192.168.1.0/24
NET_LAN="br-lan"        # 10.1.1.0/24

ALL_NETS="$NET_WAN $NET_DMZ $NET_LAN"

IMAGE="ubuntu:24.04"

while getopts ":drh:" opt; do
    case ${opt} in
        d|r) DELETE_ALL=1 ;;
        h|*) echo "Usage: $0 [-d (delete)]"; exit 0 ;;
    esac
done

if [ $DELETE_ALL -eq 1 ]; then
    echo "=== Suppression ==="
    for vm in $ALL_VMS; do
        lxc delete $vm --force >/dev/null 2>&1 || true
    done
    for net in $ALL_NETS; do
        lxc network delete $net >/dev/null 2>&1 || true
    done
    exit 0
fi

create_net() {
    lxc network create "$1" ipv4.address=none ipv4.dhcp=false ipv6.address=none ipv6.dhcp=false 2>/dev/null || true
}

create_vm() {
    lxc launch $IMAGE "$1" >/dev/null 2>&1 || true
}

install_pkgs() {
    lxc exec "$1" -- apt-get update -qq
    lxc exec "$1" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y $2 -qq
}

repurpose_eth0() {
    lxc config device remove "$1" eth0 2>/dev/null || true
    lxc config device add "$1" eth0 nic nictype=bridged parent="$2"
}

add_nic() {
    lxc config device add "$1" "$2" nic nictype=bridged parent="$3"
}

disable_auto_conf() {
    lxc exec "$1" -- rm -f /etc/netplan/*.yaml
    lxc exec "$1" -- netplan apply >/dev/null 2>&1 || true
}

set_ip() {
    disable_auto_conf "$1"
    lxc exec "$1" -- ip addr flush dev "$2"
    lxc exec "$1" -- ip link set "$2" up
    lxc exec "$1" -- ip addr add "$3" dev "$2"
}

add_route() {
    lxc exec "$1" -- ip route add "$2" via "$3"
}

# --- Create networks ---
create_net "$NET_WAN"
create_net "$NET_DMZ"
create_net "$NET_LAN"

# --- Create VMs ---
for vm in $ALL_VMS; do create_vm "$vm"; done
sleep 5

# --- Install packages ---
install_pkgs "$CLIENT_WAN" "iproute2 tcpdump netcat-openbsd"
install_pkgs "$FW1" "nftables tcpdump netcat-openbsd openssh-server"
install_pkgs "$FW2" "nftables squid tcpdump netcat-openbsd openssh-server"
install_pkgs "$SRV_DMZ" "nginx tcpdump netcat-openbsd"
install_pkgs "$CLIENT_LAN" "iproute2 tcpdump netcat-openbsd"
install_pkgs "$ADMIN_LAN" "iproute2 tcpdump netcat-openbsd openssh-server"

# --- Cabling ---
repurpose_eth0 "$CLIENT_WAN" "$NET_WAN"

repurpose_eth0 "$FW1" "$NET_WAN"
add_nic "$FW1" eth1 "$NET_DMZ"

repurpose_eth0 "$FW2" "$NET_DMZ"
add_nic "$FW2" eth1 "$NET_LAN"

repurpose_eth0 "$SRV_DMZ" "$NET_DMZ"
repurpose_eth0 "$CLIENT_LAN" "$NET_LAN"
repurpose_eth0 "$ADMIN_LAN" "$NET_LAN"

# --- Enable forwarding ---
lxc exec "$FW1" -- sysctl -w net.ipv4.ip_forward=1
lxc exec "$FW2" -- sysctl -w net.ipv4.ip_forward=1

# --- IP config ---
set_ip "$CLIENT_WAN" eth0 10.2.2.100/24
add_route "$CLIENT_WAN" default 10.2.2.1

set_ip "$FW1" eth0 10.2.2.1/24
set_ip "$FW1" eth1 192.168.1.1/24
add_route "$FW1" 10.1.1.0/24 192.168.1.254

set_ip "$FW2" eth0 192.168.1.254/24
set_ip "$FW2" eth1 10.1.1.1/24
add_route "$FW2" default 192.168.1.1

set_ip "$SRV_DMZ" eth0 192.168.1.50/24
add_route "$SRV_DMZ" default 192.168.1.1

set_ip "$CLIENT_LAN" eth0 10.1.1.10/24
add_route "$CLIENT_LAN" default 10.1.1.1

set_ip "$ADMIN_LAN" eth0 10.1.1.20/24
add_route "$ADMIN_LAN" default 10.1.1.1

# --- Services ---
lxc exec "$SRV_DMZ" -- systemctl restart nginx
lxc exec "$FW2" -- systemctl restart squid

# --- nftables placeholders ---
#lxc exec "$FW1" -- bash -c 'cat > /etc/nftables.conf <<EOF
# FW1 NFTABLES RULES GO HERE
# WAN <-> DMZ
# EOF'

# lxc exec "$FW2" -- bash -c 'cat > /etc/nftables.conf <<EOF
# FW2 NFTABLES RULES GO HERE
# DMZ <-> LAN
# EOF'

echo "=== DONE ==="
echo "Infra functional. No internet. Routing OK. Firewalls empty by design."
