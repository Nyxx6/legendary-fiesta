#!/bin/bash

# Usage: sudo ./container_setup.sh <container_name> <path_base_dir>
set -e

CONTAINER_NAME="${1:-mycontainer}"
BASE_DIR="${2:-/tmp/containers}"
DEBIAN_MIRROR="http://deb.debian.org/debian/"

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    if mountpoint -q "$BASE_DIR/$CONTAINER_NAME/merged"; then
        umount "$BASE_DIR/$CONTAINER_NAME/merged" || echo "Failed to unmount OverlayFS"
    fi
    if [ -d "/sys/fs/cgroup/$CONTAINER_NAME" ]; then
        rmdir "/sys/fs/cgroup/$CONTAINER_NAME" || echo "Failed to remove cgroup"
    fi
    echo "Cleanup complete."
}

# Trap EXIT to run cleanup
trap cleanup EXIT

# Create directories
mkdir -p "$BASE_DIR/$CONTAINER_NAME"/{lower,upper,work,merged}

# Debootstrap minimal Debian if lower doesn't exist
if [ ! -d "$BASE_DIR/$CONTAINER_NAME/lower" ] || [ -z "$(ls -A "$BASE_DIR/$CONTAINER_NAME/lower")" ]; then
    debootstrap --variant=minbase stable "$BASE_DIR/$CONTAINER_NAME/lower" "$DEBIAN_MIRROR"
fi

# Mount OverlayFS
mount -t overlay overlay -o lowerdir="$BASE_DIR/$CONTAINER_NAME/lower",upperdir="$BASE_DIR/$CONTAINER_NAME/upper",workdir="$BASE_DIR/$CONTAINER_NAME/work" "$BASE_DIR/$CONTAINER_NAME/merged"

# Create cgroup for resource limits
CGROUP_PATH="/sys/fs/cgroup/$CONTAINER_NAME"
mkdir -p "$CGROUP_PATH"
echo "+cpu +memory" > "$CGROUP_PATH/cgroup.subtree_control"
echo "500000 1000000" > "$CGROUP_PATH/cpu.max"  # 50% CPU (period 1s, quota 0.5s)
echo "512M" > "$CGROUP_PATH/memory.max"  # 512M Ram

# Enter namespaces, pivot root, and exec shell
unshare --mount --pid --net --fork --mount-proc --cgroup -R "$BASE_DIR/$CONTAINER_NAME/merged" /bin/bash -c "
    mount --make-rprivate /  # Prevent propagation
    pivot_root . old_root
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    umount -l old_root
    rm -rf old_root
    hostname '$CONTAINER_NAME'
    echo \$\$ > /sys/fs/cgroup/$CONTAINER_NAME/cgroup.procs
    exec /bin/bash
"
