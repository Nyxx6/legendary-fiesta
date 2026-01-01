#!/bin/bash
set -e

# ==============================================================================
# 1. INVENTAIRE ET VARIABLES
# ==============================================================================
DELETE_ALL=0

# --- Machines ---
CLIENT_WAN="client"     # NOUVEAU : Client sur le réseau externe (simule internet)
FW1="fw1"               # Pare-feu frontal
FW2="fw2"               # Pare-feu interne
SRV_DMZ="srv-dmz"     # Serveur Web en DMZ
CLIENT_LAN="client-lan" # Client (Coeur)
ADMIN_LAN="admin-lan"   # Admin (L)

# --- Groupes ---
ALL_VMS="$CLIENT_WAN $FW1 $FW2 $SRV_DMZ $CLIENT_LAN $ADMIN_LAN"

# --- Réseaux ---
# br-wan : Réseau Externe (Remplace lxdbr0) - 10.2.2.0/24
NET_WAN="br-wan"
# br01 : Zone DMZ (Entre FW1 et FW2) - 192.168.1.0/24
NET_DMZ="br-dmz"
# br02 : Zone LAN (Derrière FW2) - 10.1.1.0/8
NET_LAN="br-lan"

ALL_NETS="$NET_WAN $NET_DMZ $NET_LAN"

# --- Image ---
IMAGE="ubuntu:24.04"

# ==============================================================================
# 2. FONCTIONS
# ==============================================================================

while getopts ":drh:" opt; do
    case ${opt} in
        d|r) DELETE_ALL=1 ;;
        h|*) echo "Usage: $0 [-d (delete)]"; exit 0 ;;
    esac
done

if [ $DELETE_ALL -eq 1 ]; then
    echo "=== Suppression de l'infrastructure ==="
    for vm in $ALL_VMS; do
        lxc delete $vm --force >& /dev/null || true
        echo "  - $vm supprimé"
    done
    for net in $ALL_NETS; do
        lxc network delete $net >& /dev/null || true
        echo "  - $net supprimé"
    done
    exit 0
fi

create_net() {
    lxc network create "$1" ipv4.address=none ipv4.dhcp=false ipv6.address=none ipv6.dhcp=false 2>/dev/null || true
}

create_vm() {
    echo "[+] VM : $1"
    # Par défaut, LXD attache eth0 à lxdbr0 (Vrai Internet)
    lxc launch $IMAGE "$1" >/dev/null 2>&1 || echo "    (Existe déjà)"
}

install_pkgs() {
    local vm=$1
    local pkgs=$2
    echo "    [$vm] Installation des paquets..."
    lxc exec "$vm" -- apt-get update >/dev/null 2>&1
    lxc exec "$vm" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
}

repurpose_eth0() {
    local vm=$1
    local bridge=$2
    # On retire l'eth0 par défaut (Internet) pour le mettre sur notre pont privé
    lxc config device add "$vm" eth0 nic nictype=bridged parent="$bridge" name=eth0 >/dev/null 2>&1
}

add_nic() {
    local vm=$1
    local iface=$2
    local bridge=$3
    lxc config device add "$vm" "$iface" nic nictype=bridged parent="$bridge" name="$iface" >/dev/null 2>&1
}

disable_auto_conf() {
    local vm=$1
    lxc exec "$vm" -- rm -f /etc/netplan/50-cloud-init.yaml
    lxc exec "$vm" -- rm -f /etc/netplan/00-installer-config.yaml
    lxc exec "$vm" -- netplan apply >/dev/null 2>&1 || true
}

set_ip() {
    local vm=$1
    local iface=$2
    local cidr=$3
    echo "    -> Config IP : $vm [$iface] = $cidr"
    disable_auto_conf "$vm"
    lxc exec "$vm" -- ip link set dev "$iface" up
    lxc exec "$vm" -- ip addr flush dev "$iface"
    lxc exec "$vm" -- ip addr add "$cidr" dev "$iface"
}

add_route() {
    local vm=$1
    local target=$2
    local gw=$3
    lxc exec "$vm" -- ip route add "$target" via "$gw"
}

# ==============================================================================
# 3. DÉPLOIEMENT
# ==============================================================================

echo "=== 1. CRÉATION INFRASTRUCTURE ==="
# Création des 3 switchs
create_net "$NET_WAN"
create_net "$NET_DMZ"
create_net "$NET_LAN"

# Création des machines (Toutes connectées au VRAI internet pour l'instant)
for vm in $ALL_VMS; do
    create_vm "$vm"
done

# Pause DHCP
sleep 5

echo "=== 2. INSTALLATION DES PAQUETS (AVANT COUPURE INTERNET) ==="

# CLIENT "Internet"
install_pkgs "$CLIENT_WAN" "iproute2 net-tools tcpdump netcat-openbsd nano"

# FW1
install_pkgs "$FW1" "iproute2 net-tools iptables nftables tcpdump netcat-openbsd openssh-server nano"

# FW2
install_pkgs "$FW2" "iproute2 net-tools iptables nftables tcpdump netcat-openbsd openssh-server squid nano"

# SRV DMZ
install_pkgs "$SRV_DMZ" "iproute2 net-tools nginx tcpdump netcat-openbsd nano"

# CLIENTS LAN
install_pkgs "$CLIENT_LAN" "iproute2 net-tools tcpdump netcat-openbsd openssh-client nano"
install_pkgs "$ADMIN_LAN" "iproute2 net-tools tcpdump netcat-openbsd openssh-client openssh-server nano"


echo "=== 3. CÂBLAGE PHYSIQUE (ISOLATION) ==="
echo "    Migration des interfaces vers les ponts privés..."

# --- CLIENT WAN (Simulé) ---
# Quitte internet réel -> rejoint br-wan
repurpose_eth0 $CLIENT_WAN $NET_WAN

# --- FW1 ---
# Quitte internet réel -> rejoint br-wan (eth0)
repurpose_eth0 $FW1 $NET_WAN
# Se connecte à la DMZ (eth1)
add_nic $FW1 eth1 $NET_DMZ

# --- FW2 ---
# Quitte internet réel -> rejoint DMZ (eth0)
repurpose_eth0 $FW2 $NET_DMZ
# Se connecte au LAN (eth1)
add_nic $FW2 eth1 $NET_LAN

# --- SRV DMZ ---
repurpose_eth0 $SRV_DMZ $NET_DMZ

# --- CLIENTS LAN ---
repurpose_eth0 $CLIENT_LAN $NET_LAN
repurpose_eth0 $ADMIN_LAN $NET_LAN


echo "=== 4. CONFIGURATION IP & ROUTAGE ==="

# Activation Forwarding
lxc exec $FW1 -- sysctl -w net.ipv4.ip_forward=1 >/dev/null
lxc exec $FW2 -- sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- CLIENT WAN ---
# IP dans le réseau 10.2.2.0/24. Gateway = FW1
set_ip $CLIENT_WAN eth0 10.2.2.100/24
add_route $CLIENT_WAN default 10.2.20.1

# --- FW1 ---
# eth0 : 10.2.2.1/24 (Côté "WAN" simulé)
set_ip $FW1 eth0 10.2.2.1/24
# eth1 : 192.168.1.10/24 (Côté DMZ)
set_ip $FW1 eth1 192.168.1.10/24
# Route vers le LAN (10.0.0.0/8) via FW2
add_route $FW1 10.0.0.0/8 192.168.1.254

# --- FW2 ---
# eth0 : 192.168.1.254/24 (Côté DMZ)
set_ip $FW2 eth0 192.168.1.254/24
# eth1 : 10.1.1.1/8 (Côté LAN)
set_ip $FW2 eth1 10.1.1.1/8
# Route par défaut vers FW1
add_route $FW2 default 192.168.1.10

# --- SRV DMZ ---
set_ip $SRV_DMZ eth0 192.168.1.50/24
add_route $SRV_DMZ default 192.168.1.10

# --- CLIENTS LAN ---
set_ip $CLIENT_LAN eth0 10.1.1.10/8
add_route $CLIENT_LAN default 10.1.1.1

set_ip $ADMIN_LAN eth0 10.1.1.20/8
add_route $ADMIN_LAN default 10.1.1.1


echo "=== 5. DÉMARRAGE SERVICES ==="
lxc exec $SRV_DMZ -- systemctl restart nginx
lxc exec $FW2 -- systemctl restart squid

echo "=== FIN ==="
echo "Infrastructure totalement isolée (Pas d'accès internet réel)."
