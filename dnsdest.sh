#!/bin/bash

# =========================================================================
# Script de destruction : Lab Réseau (DNS Master/Slave, DHCP, Relay, Router)
# =========================================================================

PROJECT_DIR="ansible_network_lab"
CONTAINERS=("router" "dns-master" "dns-slave" "dhcp-server" "dhcp-relay" "client-b")
NETWORKS=("br-sub-a" "br-sub-b")

echo "--- 1. Suppression des instances LXD ---"
for container in "${CONTAINERS[@]}"; do
    if lxc info "$container" >/dev/null 2>&1; then
        lxc delete -f "$container"
        echo "Conteneur $container supprimé."
    else
        echo "Conteneur $container introuvable, passage..."
    fi
done

echo ""
echo "--- 2. Suppression des réseaux isolés ---"
for network in "${NETWORKS[@]}"; do
    if lxc network show "$network" >/dev/null 2>&1; then
        lxc network delete "$network"
        echo "Réseau $network supprimé."
    else
        echo "Réseau $network introuvable, passage..."
    fi
done

echo ""
echo "--- 3. Nettoyage du répertoire de projet ---"
if [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
    echo "Répertoire $PROJECT_DIR supprimé."
else
    echo "Répertoire de projet introuvable."
fi

echo ""
echo "===================================================="
echo "      LAB RÉSEAU ENTIÈREMENT DÉTRUIT               "
echo "===================================================="
