#!/bin/bash

set -eE

handle_error() {
	local lineno=${1:-?}
	local cmd=${2:-?}
	echo "[ERROR] command '${cmd}' failed at line ${lineno}" >&2
	exit 1
}
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

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

usage(){
    echo "Usage: $0 [h|r|d]"
    echo "  -h           Affiche ce menu d'aide"
    echo "  -d, -r       Supprime toute l'architecture"
}

push_file() {
	local src="$1"
	local container="$2"
	local dest_path="$3"

	if [ ! -f "$src" ]; then
		echo "[ERROR] Local source file $src does not exist" >&2
		return 1
	fi

	if ! lxc exec "$container" -- true >/dev/null 2>&1; then
		echo "[ERROR] Container $container is not reachable or not running" >&2
		return 1
	fi
	local dest_dir
	dest_dir=$(dirname "$dest_path")
	lxc exec "$container" -- mkdir -p "$dest_dir" || true

	if ! lxc file push "$src" "${container}${dest_path}"; then
		echo "[ERROR] lxc file push $src ${container}${dest_path} failed" >&2
		return 1
	fi

	return 0
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

BACK_NET="back_net"
WAF_NET="waf_net"
REDIS_NET="redis_net"
NETS="$BACK_NET $WAF_NET $REDIS_NET"
WEB_SERVERS="$WEB1 $WEB2 $WEB3"

while getopts "drh" opt; do
	case ${opt} in
		d|r) DELETE_ALL=1 ;;
		h) usage; exit 0 ;;
		*) usage; exit 1 ;;
	esac
done

if [ $DELETE_ALL -eq 1 ]; then
	echo "Suppression de l'architecture..."
	for server in $WEB_SERVERS $HA_PROXY $WAFS $REDIS; do
		lxc delete $server --force || true
	done
	for net in $NETS; do
		lxc network delete $net || true
	done
    
	rm -rf ssl_certs
	rm -f haproxy.cfg nginx-waf.conf nginx-web.conf ssi.conf gil.conf index-ssi.html index-gil.html Dockerfile
    
	echo "====== Infrastructure supprimée ======"
	exit 0
fi

echo "Création des fichiers de configuration sur l'hôte..."

cat > haproxy.cfg << 'EOF'
global
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	stats socket /run/haproxy/admin.sock mode 660 level admin
	stats timeout 30s
	user haproxy
	group haproxy
	daemon

	ca-base /etc/ssl/certs
	crt-base /etc/ssl/private

	ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
	ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
	ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
	option forwardfor
	timeout connect 5000
	timeout client  50000
	timeout server  50000
	errorfile 400 /etc/haproxy/errors/400.http
	errorfile 403 /etc/haproxy/errors/403.http
	errorfile 408 /etc/haproxy/errors/408.http
	errorfile 500 /etc/haproxy/errors/500.http
	errorfile 502 /etc/haproxy/errors/502.http
	errorfile 503 /etc/haproxy/errors/503.http
	errorfile 504 /etc/haproxy/errors/504.http

# HTTP Frontend - Redirect to HTTPS
frontend http_front
	bind *:80
	# Redirect all HTTP to HTTPS
	redirect scheme https code 301 if !{ ssl_fc }

# HTTPS Frontend - SSL TERMINATION HERE
frontend https_front
	bind *:443 ssl crt /etc/ssl/private/haproxy-ecdsa.pem crt /etc/ssl/private/haproxy-rsa.pem alpn h2,http/1.1
	
	# Security headers
	http-response set-header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
	http-response set-header X-Frame-Options "SAMEORIGIN"
	http-response set-header X-Content-Type-Options "nosniff"
	http-response set-header X-XSS-Protection "1; mode=block"
	
	# Add headers for backend (WAF will see these)
	http-request set-header X-Forwarded-Proto https
	http-request set-header X-Forwarded-Port 443
	http-request add-header X-SSL-Client-CN %{+Q}[ssl_c_s_dn(cn)]
	
	# Log what domain is being accessed
	capture request header Host len 50
	
	# Send decrypted HTTP traffic to WAFs
	default_backend serveurswaf

# Backend to WAFs (HTTP - no SSL)
backend serveurswaf
	balance roundrobin
	http-check send meth GET uri / ver HTTP/1.1 hdr Host healthcheck
	http-check expect status 200

	# Forward original client IP and protocol info
	http-request set-header X-Real-IP %[src]

	# Send to WAFs on HTTP (port 80)
	server waf1 20.0.0.2:80 check inter 2000 rise 2 fall 3
	server waf2 20.0.0.3:80 check inter 2000 rise 2 fall 3
EOF

# Nginx WAF Configuration (with host-based routing to separate upstreams for compatibility with original)
cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 768;
}

http {
	sendfile on;
	tcp_nopush on;
	types_hash_max_size 2048;

	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	# Logging format with security info
	log_format security '$remote_addr - $remote_user [$time_local] '
	                    '"$request" $status $body_bytes_sent '
	                    '"$http_referer" "$http_user_agent" '
	                    '"$http_x_forwarded_for" "$http_x_forwarded_proto"';

	access_log /var/log/nginx/access.log security;
	gzip on;

	# Real IP from HAProxy
	set_real_ip_from 20.0.0.0/24;
	real_ip_header X-Real-IP;
	real_ip_recursive on;

	# Upstream web servers (all nodes handle both, but separate for original-like routing)
	upstream web_ssi {
		server 192.168.1.3:80;
		server 192.168.1.4:80;
		server 192.168.1.5:80;
	}
	upstream web_gil {
		server 192.168.1.3:80;
		server 192.168.1.4:80;
		server 192.168.1.5:80;
	}

	# WAF Server: receives HTTP from HAProxy
	server {
		listen 80;
		
		modsecurity on;
		modsecurity_rules_file /etc/nginx/modsec/main.conf;
		
		location / {
			if ($http_host = "healthcheck") {
				access_log off;
				return 200 "OK\n";
			}

			# Routing for ssi.local
			if ($host = "ssi.local") {
				proxy_pass http://web_ssi;
			}

			# Fallback to gil.local
			proxy_pass http://web_gil;

			# Preserve headers from HAProxy
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
			proxy_set_header X-Forwarded-Port $http_x_forwarded_port;
			
			# Additional proxy settings
			proxy_redirect off;
			proxy_buffering on;
			proxy_http_version 1.1;
		}
	}
}
EOF

# Nginx Web Server Configuration for custom image
cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 768;
}

http {
	sendfile on;
	tcp_nopush on;
	types_hash_max_size 2048;

	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_prefer_server_ciphers on;

	# Log format showing forwarded headers
	log_format main '$remote_addr - $remote_user [$time_local] "$request" '
	                '$status $body_bytes_sent "$http_referer" '
	                '"$http_user_agent" "$http_x_forwarded_for" '
	                'proto:$http_x_forwarded_proto';

	access_log /var/log/nginx/access.log main;
	error_log /var/log/nginx/error.log;
	
	gzip on;
	
	# Get real client IP from WAF
	set_real_ip_from 192.168.1.0/24;
	real_ip_header X-Real-IP;
	
	include /etc/nginx/sites-enabled/*;
}
EOF

cat > ssi.conf << 'EOF'
server {
	listen 80;
	server_name ssi.local;
	root /var/www/ssi;
	index index.html;

	access_log /var/log/nginx/ssi-access.log main;
	error_log /var/log/nginx/ssi-error.log;

	location / {
		try_files $uri $uri/ =404;
		
		# Check if request came via HTTPS (from HAProxy header)
		if ($http_x_forwarded_proto = "https") {
			add_header X-Secure-Connection "true";
		}
	}
}
EOF

cat > gil.conf << 'EOF'
server {
	listen 80;
	server_name gil.local;
	root /var/www/gil;
	index index.html;

	access_log /var/log/nginx/gil-access.log main;
	error_log /var/log/nginx/gil-error.log;

	location / {
		try_files $uri $uri/ =404;
		
		if ($http_x_forwarded_proto = "https") {
			add_header X-Secure-Connection "true";
		}
	}
}
EOF

# SSI Website HTML
cat > index-ssi.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
	<meta charset="UTF-8">
	<title>SSI Website</title>
</head>
<body>
	<h1>Site SSI</h1>
	<div>
		<p><strong>Bienvenue sur le site SSI</strong></p>
		<p>Serveur: Nginx in Docker</p>
	</div>
</body>
</html>
EOF

# GIL Website HTML
cat > index-gil.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
	<meta charset="UTF-8">
	<title>GIL Website</title>
</head>
<body>
	<h1>Site GIL</h1>
	<div>
		<p><strong>Bienvenue sur le site GIL</strong></p>
		<p>Serveur: Nginx in Docker</p>
	</div>
</body>
</html>
EOF

# Dockerfile for custom Nginx image
cat > Dockerfile << 'EOF'
FROM nginx:latest

# Remove default site
RUN rm -f /etc/nginx/sites-enabled/default

# Create directories for sites
RUN mkdir -p /var/www/ssi /var/www/gil

# Copy custom configs and HTML
COPY nginx-web.conf /etc/nginx/nginx.conf
COPY ssi.conf /etc/nginx/sites-enabled/ssi.conf
COPY gil.conf /etc/nginx/sites-enabled/gil.conf
COPY index-ssi.html /var/www/ssi/index.html
COPY index-gil.html /var/www/gil/index.html

# Set permissions
RUN chown -R www-data:www-data /var/www
EOF

echo "Fichiers de configuration créés"

echo "Génération des certificats SSL pour termination HAProxy..."
mkdir -p ssl_certs

# CA Certificate
openssl genrsa -out ssl_certs/ca-key.pem 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key ssl_certs/ca-key.pem -sha256 \
    -out ssl_certs/ca.pem \
    -subj "/C=FR/ST=IDF/L=Paris/O=Infrastructure/CN=RootCA" 2>/dev/null

# Extensions for all certificates
cat > ssl_certs/cert-ext.cnf << 'EXTEOF'
subjectAltName = DNS:haproxy.local,DNS:*.haproxy.local,DNS:ssi.local,DNS:*.ssi.local,DNS:gil.local,DNS:*.gil.local,IP:20.0.0.1
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EXTEOF

# ECDSA Certificate (Primary - fast, modern)
echo " Génération certificat ECDSA..."
openssl ecparam -genkey -name prime256v1 -out ssl_certs/haproxy-ecdsa-key.pem 2>/dev/null
openssl req -new -key ssl_certs/haproxy-ecdsa-key.pem \
    -out ssl_certs/haproxy-ecdsa.csr \
    -subj "/C=FR/ST=IDF/L=Paris/O=Infrastructure/CN=haproxy.local" 2>/dev/null
openssl x509 -req -days 365 -in ssl_certs/haproxy-ecdsa.csr \
    -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem \
    -CAcreateserial -out ssl_certs/haproxy-ecdsa-cert.pem \
    -sha256 -extfile ssl_certs/cert-ext.cnf 2>/dev/null
cat ssl_certs/haproxy-ecdsa-cert.pem ssl_certs/haproxy-ecdsa-key.pem > ssl_certs/haproxy-ecdsa.pem

# RSA Certificate (Fallback - compatibility)
echo " Génération certificat RSA..."
openssl genrsa -out ssl_certs/haproxy-rsa-key.pem 2048 2>/dev/null
openssl req -new -key ssl_certs/haproxy-rsa-key.pem \
    -out ssl_certs/haproxy-rsa.csr \
    -subj "/C=FR/ST=IDF/L=Paris/O=Infrastructure/CN=haproxy.local" 2>/dev/null
openssl x509 -req -days 365 -in ssl_certs/haproxy-rsa.csr \
    -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem \
    -CAcreateserial -out ssl_certs/haproxy-rsa-cert.pem \
    -sha256 -extfile ssl_certs/cert-ext.cnf 2>/dev/null
cat ssl_certs/haproxy-rsa-cert.pem ssl_certs/haproxy-rsa-key.pem > ssl_certs/haproxy-rsa.pem

echo "Certificats SSL générés (ECDSA + RSA)"

echo "Création des conteneurs..."
for server in $WEB_SERVERS $REDIS $HA_PROXY $WAFS; do
    echo "  → Création de $server"
    lxc launch ubuntu:24.04 $server || true
done

echo "Attente du démarrage des conteneurs..."

# Check whether a container is responsive (systemd running or commands can execute)
check_container_ready() {
	local container=$1
	local max_attempts=30
	local attempt=0
	while [ $attempt -lt $max_attempts ]; do
		# Try a lightweight command; if it works the container is responsive
		if lxc exec "$container" -- true >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		attempt=$((attempt+1))
	done
	return 1
}
echo "Synchronizing time in all containers..."
for server in $WEB_SERVERS $WAFS $HA_PROXY $REDIS; do
    lxc exec $server -- bash -c "
        timedatectl set-ntp true
        hwclock --systohc
        systemctl restart systemd-timesyncd || true
        sleep 3
    "
done

for server in $WEB_SERVERS $REDIS $HA_PROXY $WAFS; do
	echo "  Waiting for $server to be reachable..."
	if ! check_container_ready "$server"; then
		echo "Warning: $server did not become reachable within timeout" >&2
	fi
done

echo "Installation des paquets sur les serveurs..."

for server in $WEB_SERVERS; do
	echo "  Installation Docker sur $server"
	lxc exec $server -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y docker.io" || exit 1
	lxc exec $server -- systemctl enable --now docker
done
sleep 3
for server in $WAFS; do
	echo "  Installation Nginx + ModSecurity (and CRS) sur $server"
	# Enable 'universe' (needed for some packages) and install nginx + libnginx-mod-http-modsecurity and CRS
	lxc exec $server -- bash -c '
		apt update && DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common ca-certificates || true
		add-apt-repository -y universe || true
		apt update
		DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs
	' || exit 1
	lxc exec $server -- rm -f /etc/nginx/sites-enabled/default || true
done

echo "  Installation Redis sur $REDIS"
lxc exec $REDIS -- bash -c "apt update && DEBIAN_FRONTEND=noninteractive apt install -y redis-server" || exit 1

echo "  Installation HAProxy sur $HA_PROXY"
lxc exec $HA_PROXY -- bash -c "apt update && DEBIAN_FRONTEND=noninteractive apt install -y haproxy" || exit 1

echo "Création et configuration des réseaux..."
for net in $NETS; do
    echo "  → Création réseau $net"
    lxc network create $net ipv6.dhcp=false ipv4.dhcp=false \
                            ipv6.nat=false ipv4.nat=false \
                            --type bridge >& /dev/null || true
done


echo "Construction de l'image Docker personnalisée sur les nœuds Swarm..."
for server in $WEB_SERVERS; do
    push_file Dockerfile $server /root/Dockerfile || { echo "Failed to push Dockerfile to $server"; exit 1; }
    push_file nginx-web.conf $server /root/nginx-web.conf || { echo "Failed to push nginx-web.conf to $server"; exit 1; }
    push_file ssi.conf $server /root/ssi.conf || { echo "Failed to push ssi.conf to $server"; exit 1; }
    push_file gil.conf $server /root/gil.conf || { echo "Failed to push gil.conf to $server"; exit 1; }
    push_file index-ssi.html $server /root/index-ssi.html || { echo "Failed to push index-ssi.html to $server"; exit 1; }
    push_file index-gil.html $server /root/index-gil.html || { echo "Failed to push index-gil.html to $server"; exit 1; }
    lxc exec $server -- docker build -t custom-nginx /root || { echo "Docker build failed on $server"; exit 1; }
done


echo "Configuration des interfaces réseau..."

# Redis network
lxc network attach $REDIS_NET $REDIS eth0
lxc exec $REDIS -- ip addr flush dev eth0

# Web servers configuration
for server in $WEB_SERVERS; do
    lxc config device add $server eth1 nic nictype=bridged parent=$REDIS_NET >& /dev/null || true
    lxc exec $server -- ip link set dev eth1 up
    lxc network attach $BACK_NET $server eth0
    lxc exec $server -- ip addr flush dev eth0
done

# WAF configuration
for server in $WAFS; do
    lxc config device add $server eth1 nic nictype=bridged parent=$BACK_NET >& /dev/null || true
    lxc exec $server -- ip link set dev eth1 up
    lxc network attach $WAF_NET $server eth0
    lxc exec $server -- ip addr flush dev eth0
done

# HAProxy configuration
lxc config device add $HA_PROXY eth1 nic nictype=bridged parent=$WAF_NET >& /dev/null || true
lxc exec $HA_PROXY -- ip link set dev eth1 up

echo "Attribution des adresses IP..."
lxc exec $HA_PROXY -- ip addr add 20.0.0.1/24 dev eth1
lxc exec $WAF1 -- ip addr add 20.0.0.2/24 dev eth0
lxc exec $WAF2 -- ip addr add 20.0.0.3/24 dev eth0
lxc exec $WAF1 -- ip addr add 192.168.1.1/24 dev eth1
lxc exec $WAF2 -- ip addr add 192.168.1.2/24 dev eth1
lxc exec $WEB1 -- ip addr add 192.168.1.3/24 dev eth0
lxc exec $WEB2 -- ip addr add 192.168.1.4/24 dev eth0
lxc exec $WEB3 -- ip addr add 192.168.1.5/24 dev eth0
lxc exec $WEB1 -- ip addr add 30.0.0.3/24 dev eth1
lxc exec $WEB2 -- ip addr add 30.0.0.4/24 dev eth1
lxc exec $WEB3 -- ip addr add 30.0.0.5/24 dev eth1
lxc exec $REDIS -- ip addr add 30.0.0.1/24 dev eth0

echo "Configuration de la résolution DNS interne pour HAProxy..."
HA_EXT_IP=$(lxc exec $HA_PROXY -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
lxc exec $HA_PROXY -- bash -c "echo '$HA_EXT_IP ssi.local' >> /etc/hosts"
lxc exec $HA_PROXY -- bash -c "echo '$HA_EXT_IP gil.local' >> /etc/hosts"

echo "Configuration DNS pour résolution externe..."
for server in $WEB_SERVERS $WAFS $HA_PROXY; do
    lxc exec $server -- bash -c "mkdir -p /etc/systemd" || true
    lxc exec $server -- bash -c "echo '[Resolve]' > /etc/systemd/resolved.conf"
    lxc exec $server -- bash -c "echo 'DNS=8.8.8.8 8.8.4.4 1.1.1.1' >> /etc/systemd/resolved.conf"
    lxc exec $server -- bash -c "echo 'FallbackDNS=9.9.9.9' >> /etc/systemd/resolved.conf"
    lxc exec $server -- bash -c "echo 'Domains=~.' >> /etc/systemd/resolved.conf"  # Optional: search all domains
    lxc exec $server -- bash -c "echo 'Cache=yes' >> /etc/systemd/resolved.conf"
    lxc exec $server -- systemctl restart systemd-resolved
    lxc exec $server -- ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
done


echo "Configuration du routage..."
# IP forwarding on WAFs
for server in $WAFS; do
    lxc exec $server -- sysctl -w net.ipv4.ip_forward=1 >& /dev/null
done
echo "Configuration du routage internet pour accès externe..."
lxc exec $HA_PROXY -- sysctl -w net.ipv4.ip_forward=1 >& /dev/null
lxc exec $HA_PROXY -- bash -c "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf" && lxc exec $HA_PROXY -- sysctl -p
for server in $WAFS; do
    lxc exec $server -- ip route add default via 20.0.0.1 dev eth0 || true
done

# Default routes for web servers
lxc exec $WEB1 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB2 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB3 -- ip route add default via 192.168.1.2 dev eth0 || true

echo "Configuration de Docker Swarm..."
lxc exec $WEB1 -- docker swarm init --advertise-addr 192.168.1.3
TOKEN=$(lxc exec $WEB1 -- docker swarm join-token worker -q)
lxc exec $WEB2 -- docker swarm join --token $TOKEN 192.168.1.3:2377
lxc exec $WEB3 -- docker swarm join --token $TOKEN 192.168.1.3:2377
lxc exec $WEB1 -- docker service create --name webapp --replicas 3 --publish published=80,target=80 custom-nginx

echo "Envoi des fichiers de configuration..."

# Push SSL certificates to HAProxy container
if [ -d ssl_certs ]; then
    echo "  Pushing SSL certificates to HAProxy"
    lxc exec $HA_PROXY -- mkdir -p /etc/ssl/private

    if [ ! -f ssl_certs/haproxy-ecdsa.pem ] || [ ! -f ssl_certs/haproxy-rsa.pem ]; then
        echo "[ERROR] SSL certificate files not found in ssl_certs/" >&2
        echo "Expected: ssl_certs/haproxy-ecdsa.pem and ssl_certs/haproxy-rsa.pem" >&2
        exit 1
    fi

    if ! lxc file push ssl_certs/haproxy-ecdsa.pem ${HA_PROXY}/etc/ssl/private/ || \
       ! lxc file push ssl_certs/haproxy-rsa.pem ${HA_PROXY}/etc/ssl/private/; then
        echo "[ERROR] Failed to push SSL certificates to ${HA_PROXY}" >&2
        exit 1
    fi

    lxc exec $HA_PROXY -- chown -R haproxy:haproxy /etc/ssl/private || true
    lxc exec $HA_PROXY -- bash -c 'chmod 600 /etc/ssl/private/haproxy-*.pem' || true
fi


push_file haproxy.cfg $HA_PROXY /etc/haproxy/haproxy.cfg || { echo "Failed to push haproxy.cfg"; exit 1; }
push_file nginx-waf.conf $WAF1 /etc/nginx/nginx.conf || { echo "Failed to push nginx-waf.conf to $WAF1"; exit 1; }
push_file nginx-waf.conf $WAF2 /etc/nginx/nginx.conf || { echo "Failed to push nginx-waf.conf to $WAF2"; exit 1; }

echo "Configuration de ModSecurity sur les WAFs..."
for server in $WAFS; do
	# Prepare modsecurity directory
	lxc exec $server -- mkdir -p /etc/nginx/modsec

	# If the recommended config exists, copy and enable it; otherwise create a minimal config
	if lxc exec $server -- test -f /etc/modsecurity/modsecurity.conf-recommended; then
		lxc exec $server -- cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
		lxc exec $server -- sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf || true
	else
		# Create a minimal ModSecurity config so Nginx can include it
		lxc exec $server -- bash -c "cat > /etc/nginx/modsec/modsecurity.conf <<'MCONF'
SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off
MCONF"
	fi

	# Main include file for our nginx config
	lxc exec $server -- bash -c "echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf"
	# Include CRS loader for basic ruleset
	lxc exec $server -- bash -c "echo 'Include /usr/share/modsecurity-crs/owasp-crs.load' >> /etc/nginx/modsec/main.conf"
	# My environment didn't support IncludeOptional in CRS loader so force Include
	lxc exec $server -- bash -c "sed -i 's/^IncludeOptional/Include/' /usr/share/modsecurity-crs/owasp-crs.load"
done

echo "Configuration de Redis..."
# Backup redis.conf and set bind address + require a random password
lxc exec $REDIS -- bash -c 'cp /etc/redis/redis.conf /etc/redis/redis.conf.bak || true'
REDIS_PASS=$(openssl rand -base64 24)
lxc exec $REDIS -- bash -c "sed -i 's/bind 127.0.0.1 -::1/bind 30.0.0.1/' /etc/redis/redis.conf || true; if ! grep -q '^requirepass' /etc/redis/redis.conf; then echo 'requirepass ${REDIS_PASS}' >> /etc/redis/redis.conf; fi; systemctl restart redis"
echo "Redis password (store it safely): ${REDIS_PASS}"

echo "Redémarrage des services..."
lxc exec $HA_PROXY -- systemctl restart haproxy

echo "Testing nginx configurations..."
for n in $WAFS; do
	echo "  Testing nginx config on $n"
	if ! lxc exec $n -- nginx -t 2>&1; then
		echo "[ERROR] Nginx config test failed on $n" >&2
		echo "Showing nginx error log:" >&2
		lxc exec $n -- tail -20 /var/log/nginx/error.log || true
		echo "Showing full nginx -t output:" >&2
		lxc exec $n -- nginx -t || true
		exit 1
	fi
	echo "  Restarting nginx on $n"
	lxc exec $n -- systemctl restart nginx
done

# Simple service checker
check_service() {
	local container=$1
	local service=$2
	if ! lxc exec $container -- systemctl is-active --quiet $service; then
		echo "[ERROR] $service on $container is not active" >&2
		return 1
	fi
	return 0
}

echo "Vérification des services..."
check_service $HA_PROXY haproxy || true
for n in $WAFS; do
	check_service $n nginx || true
done
check_service $REDIS redis-server || check_service $REDIS redis || true

echo ""
echo "====== Infrastructure déployée avec succès ======"
echo ""
echo "Architecture:"
echo "  Internet → HAProxy (20.0.0.1) → WAFs (20.0.0.2-3) → Docker Swarm Cluster (192.168.1.3-5) → Redis (30.0.0.1)"
echo ""
echo "Pour tester:"
echo "  curl -k https://ssi.local"
echo "  curl -k https://gil.local"
echo "  lxc exec haproxy -- curl -k http://ssi.local"
echo "  lxc exec waf1 -- curl http://192.168.1.3"
echo ""
echo "Pour supprimer:"
echo "  $0 -d"
echo ""
