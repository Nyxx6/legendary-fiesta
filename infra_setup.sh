#!/bin/bash
set -e

# Container names
WEB1="web1"  # Nginx
WEB2="web2"  # Apache
WEB3="web3"  # Nginx
WAF1="waf1"
WAF2="waf2"
HA_PROXY="haproxy"

# Networks
BACK_NET="back_net"  # Web servers and WAFs
WAF_NET="waf_net"    # WAFs and HAProxy

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    for container in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY; do
        lxc delete $container --force 2>/dev/null || true
    done
    for net in $BACK_NET $WAF_NET; do
        lxc network delete $net 2>/dev/null || true
    done
    rm -rf ssl_certs
    echo "Cleanup complete."
}

# Handle cleanup flag
if [ "$1" = "-d" ]; then
    cleanup
    exit 0
fi

# Create networks
echo "Creating networks..."
lxc network create $BACK_NET ipv4.address=192.168.1.1/24 ipv4.nat=true
lxc network create $WAF_NET ipv4.address=20.0.0.1/24 ipv4.nat=true

# Launch containers
echo "Launching containers..."
for container in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY; do
    lxc launch ubuntu:24.04 $container
done
echo "Waiting for containers to initialize..."
sleep 10

# Configure networks
echo "Configuring networks..."
# Web servers
lxc network attach $BACK_NET $WEB1 eth0
lxc network attach $BACK_NET $WEB2 eth0
lxc network attach $BACK_NET $WEB3 eth0

# WAFs
lxc network attach $BACK_NET $WAF1 eth1
lxc network attach $BACK_NET $WAF2 eth1
lxc network attach $WAF_NET $WAF1 eth0
lxc network attach $WAF_NET $WAF2 eth0

# HAProxy
lxc network attach $WAF_NET $HA_PROXY eth0

# Set IPs
echo "Configuring IP addresses..."
# Web servers
lxc exec $WEB1 -- ip addr add 192.168.1.3/24 dev eth0
lxc exec $WEB2 -- ip addr add 192.168.1.4/24 dev eth0
lxc exec $WEB3 -- ip addr add 192.168.1.5/24 dev eth0

# WAFs
lxc exec $WAF1 -- ip addr add 192.168.1.100/24 dev eth1
lxc exec $WAF1 -- ip addr add 20.0.0.2/24 dev eth0
lxc exec $WAF2 -- ip addr add 192.168.1.101/24 dev eth1
lxc exec $WAF2 -- ip addr add 20.0.0.3/24 dev eth0

# HAProxy
lxc exec $HA_PROXY -- ip addr add 20.0.0.1/24 dev eth0

# Update and install common packages
echo "Installing common packages..."
for container in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY; do
    lxc exec $container -- bash -c "apt update && apt install -y curl"
done

# Configure web servers
echo "Configuring web servers..."

# Web1 (Nginx) - SSI site
lxc exec $WEB1 -- bash -c "apt install -y nginx"
lxc exec $WEB1 -- mkdir -p /var/www/ssi
lxc exec $WEB1 -- bash -c "echo '<html><body><h1>SSI Site on Web1</h1><p>Server: $(hostname)</p></body></html>' > /var/www/ssi/index.html"
lxc exec $WEB1 -- bash -c "cat > /etc/nginx/sites-available/ssi << 'EOF'
server {
    listen 80;
    server_name ssi.local;
    root /var/www/ssi;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF"
lxc exec $WEB1 -- ln -sf /etc/nginx/sites-available/ssi /etc/nginx/sites-enabled/
lxc exec $WEB1 -- systemctl restart nginx

# Web2 (Apache) - GIL site
lxc exec $WEB2 -- bash -c "apt install -y apache2"
lxc exec $WEB2 -- mkdir -p /var/www/gil
lxc exec $WEB2 -- bash -c "echo '<html><body><h1>GIL Site on Web2</h1><p>Server: $(hostname)</p></body></html>' > /var/www/gil/index.html"
lxc exec $WEB2 -- bash -c "cat > /etc/apache2/sites-available/gil.conf << 'EOF'
<VirtualHost *:80>
    ServerName gil.local
    DocumentRoot /var/www/gil
    <Directory /var/www/gil>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF"
lxc exec $WEB2 -- a2ensite gil.conf
lxc exec $WEB2 -- systemctl restart apache2

# Web3 (Nginx) - Backup for both sites
lxc exec $WEB3 -- bash -c "apt install -y nginx"
lxc exec $WEB3 -- mkdir -p /var/www/{ssi,gil}
lxc exec $WEB3 -- bash -c "echo '<html><body><h1>SSI Site on Web3 (Backup)</h1><p>Server: $(hostname)</p></body></html>' > /var/www/ssi/index.html"
lxc exec $WEB3 -- bash -c "echo '<html><body><h1>GIL Site on Web3 (Backup)</h1><p>Server: $(hostname)</p></body></html>' > /var/www/gil/index.html"
lxc exec $WEB3 -- bash -c "cat > /etc/nginx/sites-available/ssi << 'EOF'
server {
    listen 80;
    server_name ssi.local;
    root /var/www/ssi;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF"
lxc exec $WEB3 -- bash -c "cat > /etc/nginx/sites-available/gil << 'EOF'
server {
    listen 80;
    server_name gil.local;
    root /var/www/gil;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF"
lxc exec $WEB3 -- ln -sf /etc/nginx/sites-available/ssi /etc/nginx/sites-enabled/
lxc exec $WEB3 -- ln -sf /etc/nginx/sites-available/gil /etc/nginx/sites-enabled/
lxc exec $WEB3 -- systemctl restart nginx

# Configure WAFs
for waf in $WAF1 $WAF2; do
    echo "Configuring $waf..."
    lxc exec $waf -- bash -c "apt install -y nginx"
    lxc exec $waf -- bash -c "cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    upstream ssi_backend {
        server 192.168.1.3:80;  # web1
        server 192.168.1.5:80 backup;  # web3
    }

    upstream gil_backend {
        server 192.168.1.4:80;  # web2 (apache)
        server 192.168.1.5:80 backup;  # web3
    }

    server {
        listen 80;
        
        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 80;
        server_name ssi.local;
        
        location / {
            proxy_pass http://ssi_backend;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    server {
        listen 80;
        server_name gil.local;
        
        location / {
            proxy_pass http://gil_backend;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF"
    lxc exec $waf -- systemctl restart nginx
done

# Generate SSL certificates
echo "Generating SSL certificates..."
mkdir -p ssl_certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ssl_certs/haproxy.key -out ssl_certs/haproxy.crt \
    -subj "/CN=*.local" -addext "subjectAltName=DNS:*.local"

# Configure HAProxy
echo "Configuring HAProxy..."
lxc exec $HA_PROXY -- bash -c "apt install -y haproxy"
lxc file push ssl_certs/haproxy.key ${HA_PROXY}/etc/ssl/private/
lxc file push ssl_certs/haproxy.crt ${HA_PROXY}/etc/ssl/private/
lxc exec $HA_PROXY -- chown -R haproxy:haproxy /etc/ssl/private

lxc exec $HA_PROXY -- bash -c "cat > /etc/haproxy/haproxy.cfg << 'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

frontend http_front
    bind *:80
    redirect scheme https if !{ ssl_fc }

frontend https_front
    bind *:443 ssl crt /etc/ssl/private/haproxy.crt
    http-request set-header X-Forwarded-Proto https if { ssl_fc }
    
    acl host_ssi hdr(host) -i ssi.local
    acl host_gil hdr(host) -i gil.local
    
    use_backend ssi_servers if host_ssi
    use_backend gil_servers if host_gil

backend ssi_servers
    balance roundrobin
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check backup

backend gil_servers
    balance roundrobin
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check backup
EOF"

lxc exec $HA_PROXY -- systemctl restart haproxy

# Add hosts entries for local testing
echo -e "\nAdd these to your /etc/hosts (on your host machine):"
echo "20.0.0.1 ssi.local gil.local"
echo -e "\nTest with:"
echo "curl -k https://ssi.local"
echo "curl -k https://gil.local"
echo -e "\nClean up with: $0 -d"
