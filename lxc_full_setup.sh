#!/bin/bash

set -eE

check_requirements() {
	local need="lxc openssl curl"
	for bin in $need; do
		if ! command -v $bin >/dev/null 2>&1; then
			echo "Missing required tool: $bin. Install it and retry." >&2
			exit 1
		fi
	done
}
check_requirements

push_file() {
	lxc file push "$1" "$2$3" 2>/dev/null || return 1
}

check_container_ready() {
	local container=$1
	local max_wait=30
	local count=0
	while [ $count -lt $max_wait ]; do
		if lxc exec $container -- true 2>/dev/null; then
			return 0
		fi
		sleep 1
		((count++))
	done
	return 1
}

usage(){
	echo "Usage: $0 [h|d]"
	echo "  -h           Affiche ce menu d'aide"
	echo "  -d           Supprime toute l'architecture"
}

DELETE_ALL=0
WEB1="web1"
WEB2="web2"
WEB3="web3"
WAF1="waf1"
WAF2="waf2"
HA_PROXY="haproxy"
REDIS="redis"
WAFS="$WAF1 $WAF2"
NGINX_SERVERS="$WEB1 $WEB3"
APACHE_SERVER="$WEB2"
ALL_WEB="$WEB1 $WEB2 $WEB3"
BACK_NET="back_net"
WAF_NET="waf_net"
REDIS_NET="redis_net"
NETS="$BACK_NET $WAF_NET $REDIS_NET"

while getopts "dh" opt; do
	case ${opt} in
		d) DELETE_ALL=1 ;;
		h) usage; exit 0 ;;
		*) usage; exit 1 ;;
	esac
done

if [ $DELETE_ALL -eq 1 ]; then
	echo "Suppression de l'architecture..."
	for server in $ALL_WEB $HA_PROXY $WAFS $REDIS; do
		lxc delete $server --force 2>/dev/null || true
	done
	for net in $NETS; do
		lxc network delete $net 2>/dev/null || true
	done
	rm -rf ssl_certs *.cfg *.conf *.html
	echo "====== Infrastructure supprimée ======"
	exit 0
fi

echo "Création des fichiers de configuration..."

cat > haproxy.cfg << 'EOF'
global
    log /dev/log local0
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend http_front
    bind *:80
    redirect scheme https code 301 if !{ ssl_fc }

frontend https_front
    bind *:443 ssl crt /etc/ssl/private/haproxy.pem
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port 443
    default_backend waf_backend

backend waf_backend
    balance roundrobin
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check
EOF

cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events { worker_connections 768; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
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
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        }
    }
}
EOF

cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events { worker_connections 768; }

http {
	sendfile on;
	tcp_nopush on;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	log_format main '$remote_addr - $remote_user [$time_local] "$request" '
	                '$status $body_bytes_sent "$http_referer" '
	                '"$http_user_agent" "proto:$http_x_forwarded_proto"';

	access_log /var/log/nginx/access.log main;
	gzip on;
	set_real_ip_from 192.168.1.0/24;
	real_ip_header X-Real-IP;
	include /etc/nginx/sites-enabled/*;
}
EOF

# Create site configs as templates
for site in ssi gil; do
	cat > ${site}.conf << EOF
server {
	listen 80;
	server_name ${site}.local;
	root /var/www/${site};
	index index.html index.php;

	access_log /var/log/nginx/${site}-access.log main;
	error_log /var/log/nginx/${site}-error.log;

	location / {
		try_files \$uri \$uri/ =404;
		if (\$http_x_forwarded_proto = "https") {
			add_header X-Secure-Connection "true";
		}
	}

	location ~ \.php$ {
		include snippets/fastcgi-php.conf;
		fastcgi_pass unix:/var/run/php/php-fpm.sock;
		fastcgi_param HTTPS \$http_x_forwarded_proto;
		fastcgi_param SERVER_PORT \$http_x_forwarded_port;
	}
}
EOF
done

# HTML templates
for site in ssi gil; do
	UPPER=$(echo $site | tr '[:lower:]' '[:upper:]')
	cat > index-${site}.html << EOF
<!DOCTYPE html>
<html lang="fr">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>${UPPER} Website</title>
</head>
<body>
	<h1>Site ${UPPER}</h1>
	<div class="info">
		<p><strong>Bienvenue sur le site ${UPPER}</strong></p>
	</div>
</body>
</html>
EOF
done

echo "Génération des certificats SSL..."
mkdir -p ssl_certs

# Simple self-signed cert for HAProxy
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
	-keyout ssl_certs/haproxy-key.pem \
	-out ssl_certs/haproxy-cert.pem \
	-subj "/C=FR/ST=IDF/L=Paris/O=Lab/CN=haproxy.local" \
	-addext "subjectAltName=DNS:*.local,DNS:haproxy.local,DNS:ssi.local,DNS:gil.local" 2>/dev/null

cat ssl_certs/haproxy-cert.pem ssl_certs/haproxy-key.pem > ssl_certs/haproxy.pem
echo "Certificats SSL générés"

echo "Création des conteneurs..."
for server in $ALL_WEB $REDIS $HA_PROXY $WAFS; do
	lxc launch ubuntu:24.04 $server 2>/dev/null || true
done

echo "Attente du démarrage..."
sleep 10
for server in $ALL_WEB $REDIS $HA_PROXY $WAFS; do
	check_container_ready "$server" || echo "Warning: $server timeout" >&2
done

echo "Installation des paquets..."

# Nginx web servers
for server in $NGINX_SERVERS; do
	echo "  $server: Nginx + PHP"
	lxc exec $server -- bash << 'SCRIPT'
		apt update -qq
		DEBIAN_FRONTEND=noninteractive apt install -y nginx php8.3-fpm php8.3-cli
		rm -f /etc/nginx/sites-enabled/default
		systemctl enable --now php8.3-fpm
		ln -sf /var/run/php/php8.3-fpm.sock /var/run/php/php-fpm.sock
		mkdir -p /var/www/{ssi,gil}
		chown -R www-data:www-data /var/www
SCRIPT
done

# Apache web server (web2 - only SSI site)
echo "  $APACHE_SERVER: Apache"
lxc exec $APACHE_SERVER -- bash << 'SCRIPT'
	apt update -qq
	DEBIAN_FRONTEND=noninteractive apt install -y apache2
	rm -f /etc/apache2/sites-enabled/000-default.conf
	a2dissite 000-default
	a2enmod rewrite headers
	mkdir -p /var/www/ssi
SCRIPT

# WAFs
for server in $WAFS; do
	echo "  $server: Nginx + ModSecurity"
	lxc exec $server -- bash << 'SCRIPT'
		apt update -qq
		DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity
		rm -f /etc/nginx/sites-enabled/default
		mkdir -p /etc/nginx/modsec
		cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
		sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf
		echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf
SCRIPT
done

# Redis and HAProxy
echo "  $REDIS: Redis"
lxc exec $REDIS -- bash -c "apt update -qq && DEBIAN_FRONTEND=noninteractive apt install -y redis-server"

echo "  $HA_PROXY: HAProxy"
lxc exec $HA_PROXY -- bash -c "apt update -qq && DEBIAN_FRONTEND=noninteractive apt install -y haproxy"

echo "Configuration des réseaux..."
for net in $NETS; do
	lxc network create $net ipv6.dhcp=false ipv4.dhcp=false \
	                        ipv6.nat=false ipv4.nat=false \
	                        --type bridge 2>/dev/null || true
done

# Attach networks
lxc network attach $REDIS_NET $REDIS eth0
for server in $ALL_WEB; do
	lxc config device add $server eth1 nic nictype=bridged parent=$REDIS_NET 2>/dev/null || true
	lxc exec $server -- ip link set dev eth1 up
	lxc network attach $BACK_NET $server eth0
done
for server in $WAFS; do
	lxc config device add $server eth1 nic nictype=bridged parent=$BACK_NET 2>/dev/null || true
	lxc exec $server -- ip link set dev eth1 up
	lxc network attach $WAF_NET $server eth0
done
lxc config device add $HA_PROXY eth1 nic nictype=bridged parent=$WAF_NET 2>/dev/null || true
lxc exec $HA_PROXY -- ip link set dev eth1 up

echo "Attribution des IPs..."
# Define IP mappings
declare -A IPS=(
	["$HA_PROXY"]="eth1:20.0.0.1/24"
	["$WAF1"]="eth0:20.0.0.2/24 eth1:192.168.1.1/24"
	["$WAF2"]="eth0:20.0.0.3/24 eth1:192.168.1.2/24"
	["$WEB1"]="eth0:192.168.1.3/24 eth1:30.0.0.3/24"
	["$WEB2"]="eth0:192.168.1.4/24 eth1:30.0.0.4/24"
	["$WEB3"]="eth0:192.168.1.5/24 eth1:30.0.0.5/24"
	["$REDIS"]="eth0:30.0.0.1/24"
)

for container in "${!IPS[@]}"; do
	for assignment in ${IPS[$container]}; do
		IFS=: read -r iface ip <<< "$assignment"
		lxc exec $container -- ip addr add $ip dev $iface 2>/dev/null || true
	done
done

echo "Configuration du routage..."
for server in $WAFS; do
	lxc exec $server -- sysctl -w net.ipv4.ip_forward=1 >/dev/null
done
lxc exec $WEB1 -- ip route add default via 192.168.1.1 dev eth0 2>/dev/null || true
lxc exec $WEB2 -- ip route add default via 192.168.1.1 dev eth0 2>/dev/null || true
lxc exec $WEB3 -- ip route add default via 192.168.1.2 dev eth0 2>/dev/null || true

echo "Déploiement des configurations..."

# HAProxy SSL cert
lxc exec $HA_PROXY -- mkdir -p /etc/ssl/private
push_file ssl_certs/haproxy.pem $HA_PROXY /etc/ssl/private/haproxy.pem || exit 1
lxc exec $HA_PROXY -- bash -c "chown haproxy:haproxy /etc/ssl/private/haproxy.pem && chmod 640 /etc/ssl/private/haproxy.pem"
push_file haproxy.cfg $HA_PROXY /etc/haproxy/haproxy.cfg || exit 1

# WAFs
for waf in $WAFS; do
	push_file nginx-waf.conf $waf /etc/nginx/nginx.conf || exit 1
done

# Nginx web servers (both sites: ssi + gil)
for server in $NGINX_SERVERS; do
	push_file nginx-web.conf $server /etc/nginx/nginx.conf || exit 1
	for site in ssi gil; do
		push_file ${site}.conf $server /etc/nginx/sites-enabled/${site}.conf || exit 1
		push_file index-${site}.html $server /var/www/${site}/index.html || exit 1
	done
done

# Apache server (only SSI site)
lxc exec $APACHE_SERVER -- bash << 'EOF'
cat > /etc/apache2/sites-available/apache-ssi.conf << 'VHOST'
<VirtualHost *:80>
    ServerName ssi.local
    DocumentRoot /var/www/ssi
    ErrorLog ${APACHE_LOG_DIR}/ssi-error.log
    CustomLog ${APACHE_LOG_DIR}/ssi-access.log combined
    <Directory /var/www/ssi>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
VHOST
a2ensite apache-ssi
EOF
push_file index-ssi.html $APACHE_SERVER /var/www/ssi/index.html || exit 1

echo "Configuration de Redis..."
REDIS_PASS=$(openssl rand -base64 24)
lxc exec $REDIS -- bash << EOF
	sed -i 's/bind 127.0.0.1.*/bind 30.0.0.1/' /etc/redis/redis.conf
	grep -q '^requirepass' /etc/redis/redis.conf || echo 'requirepass $REDIS_PASS' >> /etc/redis/redis.conf
	systemctl restart redis
EOF
echo "Redis password: $REDIS_PASS"

echo "Redémarrage des services..."
lxc exec $HA_PROXY -- systemctl restart haproxy

for server in $NGINX_SERVERS $WAFS; do
	lxc exec $server -- nginx -t || { echo "Nginx test failed on $server"; exit 1; }
	lxc exec $server -- systemctl restart nginx
done

lxc exec $APACHE_SERVER -- systemctl restart apache2

echo ""
echo "====== Infrastructure déployée avec succès ======"
echo ""
echo "Architecture:"
echo "  Internet → HAProxy (20.0.0.1) → WAFs (20.0.0.2-3) → Web Servers (192.168.1.3-5) → Redis (30.0.0.1)"
echo ""
echo "Sites:"
echo "  - web1, web3: ssi.local + gil.local (Nginx)"
echo "  - web2: ssi.local only (Apache)"
echo ""
echo "Tests:"
echo "  lxc exec haproxy -- curl -k https://localhost -H 'Host: ssi.local'"
echo "  lxc exec waf1 -- curl http://192.168.1.3 -H 'Host: gil.local'"
echo ""
echo "Suppression: $0 -d"
echo ""