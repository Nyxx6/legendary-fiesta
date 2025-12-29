# Ansible Automation for Infranet LXD Topology

This project automates the deployment of the network infrastructure defined in the original `infranet.sh` script using **Ansible** and **LXD containers**. It preserves the exact network topology, container roles, and service configurations.

## Prerequisites

To run this automation, you must have the following installed and configured on your host machine:

1.  **LXD:** The LXD daemon must be running and initialized (`lxd init`).
2.  **Ansible:** Version 2.10 or newer.
3.  **Ansible LXD Connection Plugin:** Ensure you can connect to LXD containers via Ansible. This typically requires the `ansible-connection-lxd` plugin or similar configuration.

## Infrastructure Topology

The automated deployment creates the following seven containers and three isolated LXD networks:

| Container | Role | Networks | IP Addresses | Services |
| :--- | :--- | :--- | :--- | :--- |
| `haproxy` | Load Balancer (SSL Termination) | `waf_net` (20.0.0.0/24) | `eth1`: 20.0.0.1/24 | HAProxy |
| `waf1` | Web Application Firewall | `waf_net`, `back_net` (192.168.1.0/24) | `eth0`: 20.0.0.2/24, `eth1`: 192.168.1.1/24 | Nginx, ModSecurity |
| `waf2` | Web Application Firewall | `waf_net`, `back_net` | `eth0`: 20.0.0.3/24, `eth1`: 192.168.1.2/24 | Nginx, ModSecurity |
| `web1` | Web Server (Nginx) | `back_net`, `redis_net` (30.0.0.0/24) | `eth0`: 192.168.1.3/24, `eth1`: 30.0.0.3/24 | Nginx, PHP-FPM |
| `web2` | Web Server (Apache) | `back_net`, `redis_net` | `eth0`: 192.168.1.4/24, `eth1`: 30.0.0.4/24 | Apache2 |
| `web3` | Web Server (Nginx) | `back_net`, `redis_net` | `eth0`: 192.168.1.5/24, `eth1`: 30.0.0.5/24 | Nginx, PHP-FPM |
| `redis` | Database | `redis_net` | `eth0`: 30.0.0.1/24 | Redis |

## Usage

### 1. Install Ansible Collections

This project uses the `community.general` collection.

```bash
ansible-galaxy collection install community.general
```

### 2. Deploy the Infrastructure

Navigate to the project directory and run the main playbook. This will:
1.  Create the three LXD networks (`waf_net`, `back_net`, `redis_net`).
2.  Launch all seven containers using the `ubuntu:24.04` image.
3.  Attach the network interfaces and configure static IP addresses and routing.
4.  Install and configure all services (HAProxy, Nginx, Apache, ModSecurity, Redis).
5.  Generate and push the required SSL certificates to the HAProxy container.

```bash
# Navigate to the project directory
cd /path/to/ansible-infranet

# Run the deployment playbook
ansible-playbook -i inventory.ini site.yml
```

### 3. Clean Up the Infrastructure

To tear down the entire environment, run the cleanup playbook:

```bash
# Run the cleanup playbook
ansible-playbook -i inventory.ini cleanup.yml
```

## Key Configuration Files

The original script's configurations have been converted into Ansible templates:

| Original File | Ansible Template | Role | Description |
| :--- | :--- | :--- | :--- |
| `haproxy.cfg` | `roles/haproxy/templates/haproxy.cfg.j2` | `haproxy` | HAProxy configuration for SSL termination and load balancing to WAFs. |
| `nginx-waf.conf` | `roles/waf/templates/nginx-waf.conf.j2` | `waf` | Nginx configuration for WAFs, including ModSecurity and routing to web servers. |
| `nginx-web.conf` | `roles/web_nginx/templates/nginx-web.conf.j2` | `web_nginx` | Base Nginx configuration for web servers. |
| `ssi.conf`, `gil.conf` | `roles/web_nginx/templates/*.conf.j2` | `web_nginx` | Nginx virtual host configurations for `ssi.local` and `gil.local`. |
| `apache-gil.conf` | `roles/web_apache/templates/apache-gil.conf.j2` | `web_apache` | Apache virtual host configuration for `gil.local` on `web2`. |
| SSL Certificates | `files/ssl_certs/` | `haproxy` | Generated ECDSA and RSA certificates for HAProxy SSL termination. |
| Web Content | `roles/web_nginx/templates/index-*.j2` | `web_nginx` | HTML and PHP content for the `ssi.local` and `gil.local` sites. |

The static IP addresses and routing rules are managed via variables in `group_vars/all.yml` and applied using the `common` role. The Redis password is dynamically generated and stored in a temporary file during execution, mirroring the original script's behavior.
