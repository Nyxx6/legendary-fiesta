#!/bin/bash

# =========================================================================
# Destroy Script: CodeIgniter 4 Lab Cleanup
# =========================================================================

PROJECT_DIR="tpansible-ci4"
CONTAINER_NAME="ci4-server"

echo "--- 1. Deleting LXD Container ($CONTAINER_NAME) ---"
if lxc info "$CONTAINER_NAME" >/dev/null 2>&1; then
    lxc delete -f "$CONTAINER_NAME"
    echo "Container $CONTAINER_NAME has been removed."
else
    echo "Container $CONTAINER_NAME not found, skipping."
fi

echo "--- 2. Removing Ansible Project Directory ---"
if [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
    echo "Directory $PROJECT_DIR has been deleted."
else
    echo "Directory $PROJECT_DIR not found, skipping."
fi

# Optional: Clean up potential temporary files
rm -f site.yml hosts.ini ansible.cfg 2>/dev/null

echo ""
echo "============================================"
echo "      LAB ENVIRONMENT DESTROYED             "
echo "============================================"
