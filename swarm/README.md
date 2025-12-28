# Ansible LXD Infrastructure Automation

Minimal Ansible automation for deploying a multi-tier web infrastructure with HAProxy, WAF, web servers, and Redis.
(automated version of https://github.com/Nyxx6/legendary-fiesta/blob/main/infra/launchme.sh)
## Architecture

```
Internet → HAProxy (SSL termination) → WAF (ModSecurity) → Web Servers → Redis
          20.0.0.1                     20.0.0.2-3          192.168.1.3-5    30.0.0.1
```

## Quick Start

```bash
# 1. Run setup script
chmod +x setup.sh
./setup.sh

# 2. Install Ansible + LXD module
pip install ansible ansible-pylxd

# 3. Deploy infrastructure
ansible-playbook -i inventory.ini ansible-playbook.yml

# 4. Test
curl -k https://ssi.local
curl -k https://gil.local

# 5. Destroy
ansible-playbook -i inventory.ini ansible-playbook.yml --tags destroy
```

## Components

- **HAProxy** (20.0.0.1): SSL termination, load balancing
- **WAF1/WAF2** (20.0.0.2-3): Nginx + ModSecurity with OWASP CRS
- **Web1/Web3**: Nginx servers for ssi.local and gil.local
- **Web2**: Apache server for gil.local
- **Redis** (30.0.0.1): Shared cache/session storage

## Requirements

- LXD installed and initialized
- Python 3 + pip
- ansible-pylxd module
- OpenSSL for certificate generation

## Notes

- SSL certificates are self-signed (stored in `ssl_certs/`)
- ModSecurity runs in blocking mode with OWASP Core Rule Set
- All HTTP traffic redirects to HTTPS
- Redis binds to 30.0.0.1 (not localhost)
