#!/bin/bash

# ===================================
# Destroy Script for TD3 
# ===================================

PROJECT_DIR="td3_lxd_ansible"

echo "--- Stopping and deleting LXD containers ---"
lxc delete -f web1 web2 2>/dev/null && echo "Containers web1 and web2 deleted." || echo "Containers not found or already deleted."

echo "--- Cleaning up project directory ---"
if [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
    echo "Directory $PROJECT_DIR removed."
else
    echo "Directory $PROJECT_DIR not found."
fi

echo "--- Environment Destroyed ---"
