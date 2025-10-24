#!/bin/bash

# Usage: sudo ./container_setup.sh <container_name> <base_dir>
# Example: sudo ./container_setup.sh mycontainer /tmp/containers

set -e

CONTAINER_NAME="${1:-mycontainer}"
BASE_DIR="${2:-/tmp/containers}"
DEBIAN_MIRROR="http://deb.debian.org/debian/"

# Vérifier si root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté avec sudo"
    exit 1
fi

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    if mountpoint -q "$BASE_DIR/$CONTAINER_NAME/merged" 2>/dev/null; then
        umount "$BASE_DIR/$CONTAINER_NAME/merged" 2>/dev/null || echo "Failed to unmount OverlayFS"
    fi
    if [ -d "/sys/fs/cgroup/$CONTAINER_NAME" ]; then
        rmdir "/sys/fs/cgroup/$CONTAINER_NAME" 2>/dev/null || echo "Failed to remove cgroup"
    fi
    echo "Cleanup complete."
}

# Trap EXIT to run cleanup
trap cleanup EXIT

# Créer le répertoire de base avec les bonnes permissions
mkdir -p "$BASE_DIR"
chmod 755 "$BASE_DIR"

# Create directories
mkdir -p "$BASE_DIR/$CONTAINER_NAME"/{lower,upper,work,merged}

# Debootstrap minimal Debian if lower doesn't exist
if [ ! -d "$BASE_DIR/$CONTAINER_NAME/lower/bin" ]; then
    echo "Installation de Debian minimal avec debootstrap..."
    debootstrap --variant=minbase stable "$BASE_DIR/$CONTAINER_NAME/lower" "$DEBIAN_MIRROR"
fi

# Mount OverlayFS
echo "Montage d'OverlayFS..."
mount -t overlay overlay \
    -o lowerdir="$BASE_DIR/$CONTAINER_NAME/lower",upperdir="$BASE_DIR/$CONTAINER_NAME/upper",workdir="$BASE_DIR/$CONTAINER_NAME/work" \
    "$BASE_DIR/$CONTAINER_NAME/merged"

# Create cgroup for resource limits
CGROUP_PATH="/sys/fs/cgroup/$CONTAINER_NAME"
mkdir -p "$CGROUP_PATH"

# Configuration cgroup 
echo "500000 1000000" > "$CGROUP_PATH/cpu.max" 2>/dev/null || true
echo "512M" > "$CGROUP_PATH/memory.max" 2>/dev/null || true

# Créer le répertoire old_root dans merged AVANT d'entrer dans le namespace
mkdir -p "$BASE_DIR/$CONTAINER_NAME/merged/old_root"

# Enter namespaces, pivot root, and exec shell
echo "Démarrage du conteneur $CONTAINER_NAME..."
unshare --mount --pid --net --uts --ipc --cgroup --fork --mount-proc \
    -R "$BASE_DIR/$CONTAINER_NAME/merged" /bin/bash <<'CONTAINER_SCRIPT'
    # Rendre les montages privés pour éviter la propagation
    mount --make-rprivate / 2>/dev/null || mount --make-private /
    
    # Changer la racine avec pivot_root
    # pivot_root déplace la racine actuelle vers old_root et monte . comme nouvelle racine
    cd /
    pivot_root . old_root
    
    # Monter les systèmes de fichiers nécessaires
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    
    # Démonter et supprimer l'ancienne racine
    umount -l old_root
    rm -rf old_root
    
    # Définir le hostname
    hostname "$CONTAINER_NAME"
    
    # Ajouter le processus au cgroup
    if [ -f "/sys/fs/cgroup/$CONTAINER_NAME/cgroup.procs" ]; then
        echo $$ > /sys/fs/cgroup/$CONTAINER_NAME/cgroup.procs 2>/dev/null || true
    fi
    
    # Variables d'environnement
    export PS1="[\u@$CONTAINER_NAME \W]\$ "
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    
    echo "==================================="
    echo "Conteneur $CONTAINER_NAME démarré"
    echo "==================================="
    echo "Pour quitter, tapez: exit"
    echo ""
    
    # Lancer le shell
    exec /bin/bash
CONTAINER_SCRIPT

echo "Conteneur arrêté."
