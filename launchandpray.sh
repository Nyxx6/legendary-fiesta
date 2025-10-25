#!/bin/bash
set -e

# === VARIABLES ===
WEB1="web1" WEB2="web2" WEB3="web3"
WAF1="waf1" WAF2="waf2"
HA_PROXY="haproxy"
REDIS="redis"

APACHE_SERVER="$WEB2"
NGINX_SERVER="$WEB1 $WEB3"
WAFS="$WAF1 $WAF2"
WEB_SERVERS="$WEB1 $WEB2 $WEB3"

WAF_NET="waf_net" BACK_NET="back_net" REDIS_NET="redis_net"
NETS="$WAF_NET $BACK_NET $REDIS_NET"

DELETE_ALL=0
while getopts "drh" opt; do
    case $opt in
        d|r) DELETE_ALL=1 ;;
        h) echo "Usage: $0 [-d|-r] (détruire)"; exit 0 ;;
        *) exit 1 ;;
    esac
done

# === MODE SUPPRESSION ===
if [ $DELETE_ALL -eq 1 ]; then
    echo "Suppression de l'infrastructure..."
    for c in $WEB_SERVERS $WAFS $HA_PROXY $REDIS; do lxc delete $c --force 2>/dev/null || true; done
    for n in $NETS; do lxc network delete $n 2>/dev/null || true; done
    rm -rf ssl_certs haproxy.cfg nginx-*.conf ssi.conf gil.conf apache-*.conf index-*.html
    echo "Infrastructure supprimée."
    exit 0
fi

# === CONFIGS HÔTE ===
echo "Génération des configurations..."

# HAProxy - SSL + Load Balancing
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

frontend http_in
    bind *:80
    redirect scheme https code 301 if !{ ssl_fc }

frontend https_in
    bind *:443 ssl crt /etc/ssl/private/haproxy-ecdsa.pem crt /etc/ssl/private/haproxy-rsa.pem
    default_backend waf_backend

backend waf_backend
    balance roundrobin
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check
EOF

# Nginx WAF
cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events { worker_connections 768; }

http {
    include /etc/nginx/mime.types;
    sendfile on;
    set_real_ip_from 20.0.0.0/24;
    real_ip_header X-Real-IP;

    upstream web_cluster {
        server 192.168.1.3:80;
        server 192.168.1.4:80;
        server 192.168.1.5:80;
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

# Nginx Web
cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
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

# Virtual Hosts Nginx
cat > ssi.conf << 'EOF'
server {
    listen 80;
    server_name ssi.local;
    root /var/www/ssi;
    index index.php index.html;

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

cat > gil.conf << 'EOF'
server {
    listen 80;
    server_name gil.local;
    root /var/www/gil;
    index index.php index.html;

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

# Apache Virtual Hosts
cat > apache-ssi.conf << 'EOF'
<VirtualHost *:80>
    ServerName ssi.local
    DocumentRoot /var/www/ssi
    <Directory /var/www/ssi>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

cat > apache-gil.conf << 'EOF'
<VirtualHost *:80>
    ServerName gil.local
    DocumentRoot /var/www/gil
    <Directory /var/www/gil>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

# Pages minimalistes
cat > index-ssi.html << 'EOF'
<!DOCTYPE html><html><head><title>SSI</title></head>
<body style="font-family:Arial;text-align:center;padding:50px;background:#667eea;color:white;">
<h1>Site SSI - Nginx</h1>
<p>Heure: <span id="t"></span></p>
<script>setInterval(() => document.getElementById('t').textContent = new Date().toLocaleString('fr-FR'), 1000);</script>
</body></html>
EOF

cat > index-gil.html << 'EOF'
<!DOCTYPE html><html><head><title>GIL</title></head>
<body style="font-family:Arial;text-align:center;padding:50px;background:#f5576c;color:white;">
<h1>Site GIL - Apache</h1>
<p>Heure: <span id="t"></span></p>
<script>setInterval(() => document.getElementById('t').textContent = new Date().toLocaleString('fr-FR'), 1000);</script>
</body></html>
EOF

# === CERTIFICATS SSL ===
echo "Génération certificats SSL..."
mkdir -p ssl_certs
openssl genrsa -out ssl_certs/ca-key.pem 4096 >/dev/null 2>&1
openssl req -new -x509 -days 365 -key ssl_certs/ca-key.pem -sha256 -out ssl_certs/ca.pem -subj "/CN=LabCA" >/dev/null 2>&1

cat > ssl_certs/cert-ext.cnf << 'EOF'
subjectAltName = DNS:haproxy.local,DNS:ssi.local,DNS:gil.local,IP:20.0.0.1
EOF

# ECDSA
openssl ecparam -genkey -name prime256v1 -out ssl_certs/haproxy-ecdsa-key.pem >/dev/null 2>&1
openssl req -new -key ssl_certs/haproxy-ecdsa-key.pem -out ssl_certs/tmp.csr -subj "/CN=haproxy.local" >/dev/null 2>&1
openssl x509 -req -days 365 -in ssl_certs/tmp.csr -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem -CAcreateserial -out ssl_certs/haproxy-ecdsa.pem -sha256 -extfile ssl_certs/cert-ext.cnf >/dev/null 2>&1
cat ssl_certs/haproxy-ecdsa.pem ssl_certs/haproxy-ecdsa-key.pem > ssl_certs/haproxy-ecdsa.pem.tmp && mv ssl_certs/haproxy-ecdsa.pem.tmp ssl_certs/haproxy-ecdsa.pem

# RSA
openssl genrsa -out ssl_certs/haproxy-rsa-key.pem 2048 >/dev/null 2>&1
openssl req -new -key ssl_certs/haproxy-rsa-key.pem -out ssl_certs/tmp.csr -subj "/CN=haproxy.local" >/dev/null 2>&1
openssl x509 -req -days 365 -in ssl_certs/tmp.csr -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem -CAcreateserial -out ssl_certs/haproxy-rsa.pem -sha256 -extfile ssl_certs/cert-ext.cnf >/dev/null 2>&1
cat ssl_certs/haproxy-rsa.pem ssl_certs/haproxy-rsa-key.pem > ssl_certs/haproxy-rsa.pem.tmp && mv ssl_certs/haproxy-rsa.pem.tmp ssl_certs/haproxy-rsa.pem

rm -f ssl_certs/tmp.csr

# === CONTENEURS & RÉSEAUX ===
echo "Création conteneurs..."
for c in $WEB_SERVERS $WAFS $HA_PROXY $REDIS; do
    lxc launch ubuntu:24.04 $c >/dev/null
done

for net in $NETS; do
    lxc network create $net --type=bridge ipv4.address=none ipv6.address=none >/dev/null
done

# === CONFIG RÉSEAU ===
lxc network attach $WAF_NET $HA_PROXY eth1
lxc exec $HA_PROXY -- ip addr add 20.0.0.1/24 dev eth1

for w in $WAFS; do
    lxc network attach $WAF_NET $w eth0
    lxc network attach $BACK_NET $w eth1
done
lxc exec $WAF1 -- ip addr add 20.0.0.2/24 dev eth0
lxc exec $WAF2 -- ip addr add 20.0.0.3/24 dev eth0
lxc exec $WAF1 -- ip addr add 192.168.1.1/24 dev eth1
lxc exec $WAF2 -- ip addr add 192.168.1.2/24 dev eth1

for w in $WEB_SERVERS; do
    lxc network attach $BACK_NET $w eth0
    lxc network attach $REDIS_NET $w eth1
done
lxc exec $WEB1 -- ip addr add 192.168.1.3/24 dev eth0
lxc exec $WEB2 -- ip addr add 192.168.1.4/24 dev eth0
lxc exec $WEB3 -- ip addr add 192.168.1.5/24 dev eth0
lxc exec $WEB1 -- ip addr add 30.0.0.3/24 dev eth1
lxc exec $WEB2 -- ip addr add 30.0.0.4/24 dev eth1
lxc exec $WEB3 -- ip addr add 30.0.0.5/24 dev eth1

lxc network attach $REDIS_NET $REDIS eth0
lxc exec $REDIS -- ip addr add 30.0.0.1/24 dev eth0

# Routage
lxc exec $WEB1 -- ip route add default via 192.168.1.1
lxc exec $WEB2 -- ip route add default via 192.168.1.1
lxc exec $WEB3 -- ip route add default via 192.168.1.2
for w in $WAFS; do lxc exec $w -- sysctl -w net.ipv4.ip_forward=1 >/dev/null; done

# === INSTALLATION PAQUETS ===
echo "Installation des paquets..."

lxc exec $HA_PROXY -- apt update && lxc exec $HA_PROXY -- apt install -y haproxy

for server in $WAFS; do
	echo "  Installation Nginx + ModSecurity (and CRS) sur $server"
	lxc exec $server -- bash -c '
		apt update && DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common ca-certificates || true
		add-apt-repository -y universe || true
		apt update
		DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs
	' || exit 1
	lxc exec $server -- rm -f /etc/nginx/sites-enabled/default || true
done

for w in $NGINX_SERVER; do
    lxc exec $w -- apt update
    lxc exec $w -- apt install -y nginx php8.3-fpm php8.3-cli
    lxc exec $w -- rm -f /etc/nginx/sites-enabled/default
done

lxc exec $APACHE_SERVER -- apt update && lxc exec $APACHE_SERVER -- apt install -y apache2
lxc exec $APACHE_SERVER -- a2enmod rewrite headers

lxc exec $REDIS -- apt update && lxc exec $REDIS -- apt install -y redis-server

# === PUSH CONFIGS ===
echo "Push des configurations..."

lxc file push haproxy.cfg $HA_PROXY/etc/haproxy/haproxy.cfg
lxc file push ssl_certs/haproxy-ecdsa.pem $HA_PROXY/etc/ssl/private/haproxy-ecdsa.pem
lxc file push ssl_certs/haproxy-rsa.pem $HA_PROXY/etc/ssl/private/haproxy-rsa.pem
lxc exec $HA_PROXY -- systemctl restart haproxy

for w in $WAFS; do
    lxc file push nginx-waf.conf $w/etc/nginx/nginx.conf
    lxc exec $w -- mkdir -p /etc/nginx/modsec
    lxc exec $w -- cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
    lxc exec $w -- sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf
    lxc exec $w -- bash -c "echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf"
    lxc exec $w -- bash -c "echo 'Include /usr/share/modsecurity-crs/*.load' >> /etc/nginx/modsec/main.conf || true"
    lxc exec $w -- nginx -t && lxc exec $w -- systemctl restart nginx
done

for w in $NGINX_SERVER; do
    lxc file push nginx-web.conf $w/etc/nginx/nginx.conf
    lxc exec $w -- mkdir -p /etc/nginx/sites-enabled /var/www/ssi /var/www/gil
    lxc file push ssi.conf $w/etc/nginx/sites-enabled/ssi.conf
    lxc file push gil.conf $w/etc/nginx/sites-enabled/gil.conf
    lxc file push index-ssi.html $w/var/www/ssi/index.html
    lxc file push index-gil.html $w/var/www/gil/index.html
    lxc exec $w -- chown -R www-data:www-data /var/www
    lxc exec $w -- systemctl restart nginx php8.3-fpm
done

# Apache
lxc exec $WEB2 -- mkdir -p /var/www/ssi /var/www/gil
lxc file push apache-ssi.conf $WEB2/etc/apache2/sites-available/ssi.conf
lxc file push apache-gil.conf $WEB2/etc/apache2/sites-available/gil.conf
lxc file push index-ssi.html $WEB2/var/www/ssi/index.html
lxc file push index-gil.html $WEB2/var/www/gil/index.html
lxc exec $WEB2 -- a2ensite ssi gil
lxc exec $WEB2 -- systemctl restart apache2

# Redis
PASS=$(openssl rand -base64 24)
lxc exec $REDIS -- bash -c "sed -i 's/bind 127.0.0.1/bind 30.0.0.1/' /etc/redis/redis.conf"
lxc exec $REDIS -- bash -c "echo 'requirepass $PASS' >> /etc/redis/redis.conf"
lxc exec $REDIS -- systemctl restart redis
echo "Redis password: $PASS"

echo "Infrastructure déployée avec succès !"
echo "Test: curl -k -H 'Host: ssi.local' https://20.0.0.1"
