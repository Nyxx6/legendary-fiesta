#!/bin/bash
set -e

# === VARIABLES ===
WEB1="web1" WEB3="web3"
WAF1="waf1" WAF2="waf2"
HA_PROXY="haproxy"
REDIS="redis"

WAF_NET="waf_net" BACK_NET="back_net" REDIS_NET="redis_net"
NETS="$WAF_NET $BACK_NET $REDIS_NET"
WEBS="$WEB1 $WEB3"
WAFS="$WAF1 $WAF2"

DELETE_ALL=0
while getopts "drh" opt; do
    case $opt in
        d|r) DELETE_ALL=1 ;;
        h) echo "Usage: $0 [-d|-r]"; exit 0 ;;
    esac
done

# === SUPPRESSION ===
if [ $DELETE_ALL -eq 1 ]; then
    echo "Suppression de l'infrastructure..."
    for c in $WEBS $WAFS $HA_PROXY $REDIS; do lxc delete $c --force; done
    for n in $NETS; do lxc network delete $n; done
    rm -rf ssl_certs haproxy.cfg nginx-*.conf *.html
    echo "Infrastructure supprimée."
    exit 0
fi

# === CONFIGS HÔTE ===
echo "Génération des configurations..."

# HAProxy - SSL Termination + Load Balancing
cat > haproxy.cfg << 'EOF'
global
    log /dev/log local0
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http_front
    bind *:80
    redirect scheme https code 301 if !{ ssl_fc }

frontend https_front
    bind *:443 ssl crt /etc/ssl/private/haproxy-ecdsa.pem crt /etc/ssl/private/haproxy-rsa.pem
    default_backend waf_backend

backend waf_backend
    balance roundrobin
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check
EOF

# Nginx WAF - ModSecurity + Proxy
cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 768; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    sendfile on;

    set_real_ip_from 20.0.0.0 bosques/24;
    real_ip_header X-Real-IP;

    upstream web_cluster {
        server 192.168.1.3:80;
        server 192.168.1.4:80;
    }

    server {
        listen 80;
        modsecurity on;
        modsecurity_rules_file /etc/nginx/modsec/main.conf;

        location / {
            proxy_pass http://web_cluster;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOF

# Nginx Web - PHP + Virtual Hosts
cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 768; }

http {
    include /etc/nginx/mime.types;
    sendfile on;

    set_real_ip_from 192.168.1.0/24;
    real_ip_header X-Real-IP;

    include /etc/nginx/sites-enabled/*;
}
EOF

# Virtual Host SSI
cat > ssi.conf << 'EOF'
server {
    listen 80;
    server_name ssi.local;
    root /var/www/ssi;
    index index.php index.html;

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

# Page HTML + PHP
cat > index.php << 'EOF'
<!DOCTYPE html>
<html><head><title>SSI Lab</title></head>
<body style="font-family:Arial;text-align:center;padding:50px;background:#667eea;color:white;">
<h1>Site SSI - <?= php_uname('n') ?></h1>
<p>Heure: <span id="time"></span></p>
<script>
setInterval(() => document.getElementById('time').textContent = new Date().toLocaleString('fr-FR'), 1000);
</script>
</body></html>
EOF

# === CERTIFICATS SSL ===
echo "Génération certificats SSL..."
mkdir -p ssl_certs
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout ssl_certs/haproxy-rsa.pem -out ssl_certs/ca.pem -subj "/CN=LabCA" >/dev/null 2>&1
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) -nodes -days 365 -keyout ssl_certs/haproxy-ecdsa-key.pem -out ssl_certs/haproxy-ecdsa.pem -subj "/CN=haproxy.local" -addext "subjectAltName=DNS:haproxy.local,IP:20.0.0.1" >/dev/null 2>&1
cat ssl_certs/haproxy-ecdsa.pem ssl_certs/haproxy-ecdsa-key.pem > ssl_certs/haproxy-ecdsa.pem

# === CONTENEURS & RÉSEAUX ===
echo "Création conteneurs..."
for c in $WEBS $WAFS $HA_PROXY $REDIS; do
    lxc launch ubuntu:24.04 $c
done

for net in $NETS; do
    lxc network create $net --type=bridge ipv4.address=none ipv6.address=none
done

# === ATTRIBUTION IP ===
lxc exec $HA_PROXY -- ip addr add 20.0.0.1/24 dev eth1
lxc network attach $WAF_NET $WAF1 eth0; lxc exec $WAF1 -- ip addr add 20.0.0.2/24 dev eth0
lxc network attach $WAF_NET $WAF2 eth0; lxc exec $WAF2 -- ip addr add 20.0.0.3/24 dev eth0
lxc network attach $BACK_NET $WAF1 eth1; lxc exec $WAF1 -- ip addr add 192.168.1.1/24 dev eth1
lxc network attach $BACK_NET $WAF2 eth1; lxc exec $WAF2 -- ip addr add 192.168.1.2/24 dev eth1
lxc network attach $BACK_NET $WEB1 eth0; lxc exec $WEB1 -- ip addr add 192.168.1.3/24 dev eth0
lxc network attach $BACK_NET $WEB3 eth0; lxc exec $WEB3 -- ip addr add 192.168.1.4/24 dev eth0
lxc network attach $REDIS_NET $WEB1 eth1; lxc exec $WEB1 -- ip addr add 30.0.0.3/24 dev eth1
lxc network attach $REDIS_NET $WEB3 eth1; lxc exec $WEB3 -- ip addr add 30.0.0.4/24 dev eth1
lxc network attach $REDIS_NET $REDIS eth0; lxc exec $REDIS -- ip addr add 30.0.0.1/24 dev eth0

# Routage
lxc exec $WEB1 -- ip route add default via 192.168.1.1
lxc exec $WEB3 -- ip route add default via 192.168.1.2
for w in $WAFS; do lxc exec $w -- sysctl -w net.ipv4.ip_forward=1; done

# === INSTALLATION PAQUETS ===
echo "Installation des paquets..."

# HAProxy
lxc exec $HA_PROXY -- apt update && lxc exec $HA_PROXY -- apt install -y haproxy

# WAFs : Nginx + ModSecurity + CRS
for w in $WAFS; do
    lxc exec $w -- apt update
    lxc exec $w -- apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs
done

# Web : Nginx + PHP 8.3
for w in $WEBS; do
    lxc exec $w -- apt update
    lxc exec $w -- apt install -y nginx php8.3-fpm php8.3-cli
    lxc exec $w -- rm -f /etc/nginx/sites-enabled/default
done

# Redis
lxc exec $REDIS -- apt update && lxc exec $REDIS -- apt install -y redis-server
PASS=$(openssl rand -base64 16)
lxc exec $REDIS -- bash -c "sed -i 's/# requirepass.*/requirepass $PASS/' /etc/redis/redis.conf && systemctl restart redis"
echo "Redis password: $PASS (à conserver)"

# === CONFIGURATION SERVICES ===
# HAProxy
lxc file push haproxy.cfg $HA_PROXY/etc/haproxy/haproxy.cfg
lxc file push ssl_certs/haproxy-ecdsa.pem $HA_PROXY/etc/ssl/private/haproxy-ecdsa.pem
lxc exec $HA_PROXY -- systemctl restart haproxy

# WAFs
for w in $WAFS; do
    lxc file push nginx-waf.conf $w/etc/nginx/nginx.conf
    lxc exec $w -- mkdir -p /etc/nginx/modsec
    lxc exec $w -- bash -c "cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf"
    lxc exec $w -- sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf
    lxc exec $w -- bash -c "echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf"
    lxc exec $w -- bash -c "echo 'Include /usr/share/modsecurity-crs/*.load' >> /etc/nginx/modsec/main.conf || true"
    lxc exec $w -- nginx -t && lxc exec $w -- systemctl restart nginx
done

# Web
for w in $WEBS; do
    lxc file push nginx-web.conf $w/etc/nginx/nginx.conf
    lxc exec $w -- mkdir -p /etc/nginx/sites-enabled /var/www/ssi
    lxc file push ssi.conf $w/etc/nginx/sites-enabled/ssi.conf
    lxc file push index.php $w/var/www/ssi/index.php
    lxc exec $w -- chown -R www-data:www-data /var/www
    lxc exec $w -- systemctl restart nginx php8.3-fpm
done

echo "Infrastructure déployée !"
echo "Test: curl -k https://20.0.0.1 -H 'Host: ssi.local'"
