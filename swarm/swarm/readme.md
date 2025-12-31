**Main playbook** - orchestrates the entire deployment
**Inventory file** - defines the local LXD host
**Variable files** - contains all configuration variables
**Role structure** - organized tasks for each component

# Deploy infrastructure
ansible-playbook deploy.yml -i inventory.ini

# Delete all infrastructure
ansible-playbook deploy.yml -i inventory.ini -e cleanup=true