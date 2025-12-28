#!/bin/bash
# Minimal setup script for Ansible infrastructure

set -e

echo "Creating directory structure..."
mkdir -p templates

echo "Extracting templates from original script..."

# HAProxy config
cat > templates/haproxy.cfg << 'EOF'
global
	daemon
	ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
	mode http
	timeout connect 5000
	timeout client 50000
	timeout server 50000

frontend http_front
	bind *:80
	redirect scheme https code 301

frontend https_front
	bind *:443 ssl crt /etc/ssl/private/haproxy-ecdsa.pem crt /etc/ssl/private/haproxy-rsa.pem alpn h2,http/1.1
	http-response set-header Strict-Transport-Security "max-age=31536000"
	default_backend serveurswaf

backend serveurswaf
	balance roundrobin
	server waf1 20.0.0.2:80 check
	server waf2 20.0.0.3:80 check
EOF

# Nginx WAF config
cat > templates/nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
events { worker_connections 768; }
http {
	include /etc/nginx/mime.types;
	set_real_ip_from 20.0.0.0/24;
	real_ip_header X-Real-IP;
	
	upstream web_ssi { server 192.168.1.3:80; server 192.168.1.5:80; }
	upstream web_gil { server 192.168.1.3:80; server 192.168.1.4:80; server 192.168.1.5:80; }
	
	server {
		listen 80;
		modsecurity on;
		modsecurity_rules_file /etc/nginx/modsec/main.conf;
		
		location / {
			if ($http_host = "healthcheck") { return 200; }
			if ($host = "ssi.local") { proxy_pass http://web_ssi; }
			proxy_pass http://web_gil;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
		}
	}
}
EOF

# Nginx Web config
cat > templates/nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
events { worker_connections 768; }
http {
	include /etc/nginx/mime.types;
	set_real_ip_from 192.168.1.0/24;
	real_ip_header X-Real-IP;
	include /etc/nginx/sites-enabled/*;
}
EOF

# SSI site config
cat > templates/ssi.conf << 'EOF'
server {
	listen 80;
	server_name ssi.local;
	root /var/www/ssi;
	index index.html;
	location / { try_files $uri $uri/ =404; }
}
EOF

# GIL site config
cat > templates/gil.conf << 'EOF'
server {
	listen 80;
	server_name gil.local;
	root /var/www/gil;
	index index.html;
	location / { try_files $uri $uri/ =404; }
}
EOF

# Apache GIL config
cat > templates/apache-gil.conf << 'EOF'
<VirtualHost *:80>
    ServerName gil.local
    DocumentRoot /var/www/gil
    <Directory /var/www/gil>
        Require all granted
    </Directory>
</VirtualHost>
EOF

# HTML pages
cat > templates/index-ssi.html << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>SSI Website</title></head>
<body><h1>Site SSI</h1><p><strong>Bienvenue sur le site SSI</strong></p></body></html>
EOF

cat > templates/index-gil.html << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>GIL Website</title></head>
<body><h1>Site GIL</h1><p><strong>Bienvenue sur le site GIL</strong></p></body></html>
EOF

echo "Setup complete! Directory structure:"
echo "."
echo "├── ansible-playbook.yml"
echo "├── inventory.ini"
echo "├── setup.sh"
echo "└── templates/"
echo "    ├── haproxy.cfg"
echo "    ├── nginx-waf.conf"
echo "    ├── nginx-web.conf"
echo "    ├── ssi.conf"
echo "    ├── gil.conf"
echo "    ├── apache-gil.conf"
echo "    ├── index-ssi.html"
echo "    └── index-gil.html"
echo ""
echo "Install requirements:"
echo "  pip install ansible"
echo "  pip install ansible-pylxd"
echo ""
echo "Run playbook:"
echo "  ansible-playbook -i inventory.ini ansible-playbook.yml"
echo ""
echo "Destroy infrastructure:"
echo "  ansible-playbook -i inventory.ini ansible-playbook.yml --tags destroy"
