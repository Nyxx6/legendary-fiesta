set -eE

handle_error() {
	local lineno=${1:-?}
	local cmd=${2:-?}
	echo "[ERROR] command '${cmd}' failed at line ${lineno}" >&2
	exit 1
}
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

check_requirements() {
	local need="lxc openssl"
	for bin in $need; do
		if ! command -v $bin >/dev/null 2>&1; then
			echo "Missing required tool: $bin. Install it and retry." >&2
			exit 1
		fi
	done
}
check_requirements

# --- Variables et configuration ---
WEB1="web1"
WEB2="web2"
WEB3="web3"
WAF1="waf1"
WAF2="waf2"
HA_PROXY="haproxy"
REDIS="redis"
APACHE_SERVER="$WEB2"
NGINX_SERVER="$WEB1 $WEB3"
WAFS="$WAF1 $WAF2"
WEB_SERVERS="$APACHE_SERVER $NGINX_SERVER"

BACK_NET="back_net"
WAF_NET="waf_net"
REDIS_NET="redis_net"
NETS="$BACK_NET $WAF_NET $REDIS_NET"

# --- Fonctions ---
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
	lxc exec "$container" -- mkdir -p "$(dirname "$dest_path")" || true
	lxc file push "$src" "${container}${dest_path}"
}

check_container_ready() {
	local container=$1
	local max_attempts=30
	local attempt=0
	while [ $attempt -lt $max_attempts ]; do
		if lxc exec "$container" -- true >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		attempt=$((attempt+1))
	done
	return 1
}

# --- Traitement des arguments ---
DELETE_ALL=0
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
	rm -f haproxy.cfg nginx-waf.conf nginx-web.conf ssi.conf gil.conf index-ssi.html index-gil.html apache-*.conf
    
	echo "====== Infrastructure supprimée ======"
	exit 0
fi

# --- Génération des fichiers de configuration sur l'hôte ---
echo "Création des fichiers de configuration sur l'hôte..."

# 1. HAProxy Config (Simplified SSL binding)
cat > haproxy.cfg << 'EOF'
global
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	user haproxy
	group haproxy
	daemon

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
	option forwardfor
	timeout connect 5000
	timeout client  50000
	timeout server  50000

# HTTP Frontend - Redirect to HTTPS
frontend http_front
	bind *:80
	redirect scheme https code 301 if !{ ssl_fc }

# HTTPS Frontend - SSL TERMINATION HERE (using simplified self-signed cert)
frontend https_front
	bind *:443 ssl crt /etc/ssl/private/haproxy.pem
	
	http-request set-header X-Forwarded-Proto https
	http-request set-header X-Forwarded-Port 443
	capture request header Host len 50
	
	default_backend serveurswaf

# Backend to WAFs (HTTP - no SSL)
backend serveurswaf
	balance roundrobin
	http-check send meth GET uri / ver HTTP/1.1 hdr Host healthcheck
	http-check expect status 200

	http-request set-header X-Real-IP %[src]
	http-request set-header X-Client-IP %[src]

	# Send to WAFs on HTTP (port 80)
	server waf1 20.0.0.2:80 check inter 2000 rise 2 fall 3
	server waf2 20.0.0.3:80 check inter 2000 rise 2 fall 3
EOF

# 2. Nginx WAF Configuration (Minimal changes)
cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
	worker_connections 768;
}

http {
	sendfile on;
	tcp_nopush on;
	types_hash_max_size 2048;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;

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

	# Upstream web servers
	upstream web_cluster {
		server 192.168.1.3:80;
		server 192.168.1.5:80;
		server 192.168.1.4:80;
	}

	# WAF Server - receives HTTP from HAProxy
	server {
		listen 80;
		
		# Enable ModSecurity WAF
		modsecurity on;
		modsecurity_rules_file /etc/nginx/modsec/main.conf;
		
		# Health check endpoint (bypass WAF)
		location = / {
			if ($http_host = "healthcheck") {
				access_log off;
				return 200 "OK\n";
			}
			
			# Regular traffic
			proxy_pass http://web_cluster;
			
			# Preserve headers from HAProxy
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
			proxy_set_header X-Forwarded-Port $http_x_forwarded_port;
			
			proxy_redirect off;
			proxy_buffering on;
			proxy_http_version 1.1;
		}
		
		# Forward all other requests
		location / {
			proxy_pass http://web_cluster;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
			proxy_set_header X-Forwarded-Port $http_x_forwarded_port;
		}
	}
}
EOF

# 3. Nginx Web Server Configuration (Minimal changes)
cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
	worker_connections 768;
}

http {
	sendfile on;
	tcp_nopush on;
	types_hash_max_size 2048;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;

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

# 4. Nginx VHost Config (ssi.conf)
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
		if ($http_x_forwarded_proto = "https") {
			add_header X-Secure-Connection "true";
		}
	}
}
EOF

# 5. Nginx VHost Config (gil.conf)
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

# 6. Apache VHost Config (apache-ssi.conf)
cat > apache-ssi.conf << 'EOF'
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
EOF

# 7. Apache VHost Config (apache-gil.conf)
cat > apache-gil.conf << 'EOF'
<VirtualHost *:80>
    ServerName gil.local
    DocumentRoot /var/www/gil
    
    ErrorLog ${APACHE_LOG_DIR}/gil-error.log
    CustomLog ${APACHE_LOG_DIR}/gil-access.log combined
    
    <Directory /var/www/gil>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

# 8. SSI Website HTML (Removed PHP/FPM logic for simplification)
cat > index-ssi.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>SSI Website</title>
	<style>
		body {
			font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
			text-align: center;
			padding: 50px;
			background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
			color: white;
			margin: 0;
			min-height: 100vh;
			display: flex;
			flex-direction: column;
			justify-content: center;
		}
		h1 {
			font-size: 3em;
			margin-bottom: 20px;
			text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
		}
		.info {
			background: rgba(255,255,255,0.1);
			padding: 20px;
			border-radius: 10px;
			max-width: 600px;
			margin: 20px auto;
			backdrop-filter: blur(10px);
		}
		.info p {
			margin: 10px 0;
			font-size: 1.2em;
		}
	</style>
</head>
<body>
	<h1>Site SSI</h1>
	<div class="info">
		<p><strong>Bienvenue sur le site SSI</strong></p>
		<p>Serveur: Nginx/Apache</p>
	</div>
</body>
</html>
EOF

# 9. GIL Website HTML (Removed PHP/FPM logic for simplification)
cat > index-gil.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>GIL Website</title>
	<style>
		body {
			font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
			text-align: center;
			padding: 50px;
			background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
			color: white;
			margin: 0;
			min-height: 100vh;
			display: flex;
			flex-direction: column;
			justify-content: center;
		}
		h1 {
			font-size: 3em;
			margin-bottom: 20px;
			text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
		}
		.info {
			background: rgba(255,255,255,0.1);
			padding: 20px;
			border-radius: 10px;
			max-width: 600px;
			margin: 20px auto;
			backdrop-filter: blur(10px);
		}
		.info p {
			margin: 10px 0;
			font-size: 1.2em;
		}
	</style>
</head>
<body>
	<h1>Site GIL</h1>
	<div class="info">
		<p><strong>Bienvenue sur le site GIL</strong></p>
		<p>Serveur: Nginx/Apache</p>
	</div>
</body>
</html>
EOF

echo "Fichiers de configuration créés"

# --- Génération du certificat auto-signé simplifié ---
echo "Génération du certificat auto-signé pour HAProxy..."
mkdir -p ssl_certs
# Generate a single self-signed key and cert in one go (PEM format)
openssl req -x509 -newkey rsa:2048 -nodes -keyout ssl_certs/haproxy.key -out ssl_certs/haproxy.crt -days 3650 \
    -subj "/C=FR/ST=IDF/L=Paris/O=TestLab/CN=haproxy.local" \
    -addext "subjectAltName = DNS:haproxy.local,IP:20.0.0.1" 2>/dev/null
cat ssl_certs/haproxy.crt ssl_certs/haproxy.key > ssl_certs/haproxy.pem
rm -f ssl_certs/haproxy.crt ssl_certs/haproxy.key

echo "Certificat SSL auto-signé généré (ssl_certs/haproxy.pem)"

# --- Déploiement de l'infrastructure ---
echo "Création des conteneurs..."
for server in $WEB_SERVERS $REDIS $HA_PROXY $WAFS; do
    echo "  → Création de $server"
    lxc launch ubuntu:24.04 $server || true
done

# Wait for containers to be ready
echo "Attente du démarrage des conteneurs..."
for server in $WEB_SERVERS $REDIS $HA_PROXY $WAFS; do
	echo "  Waiting for $server to be reachable..."
	if ! check_container_ready "$server"; then
		echo "Warning: $server did not become reachable within timeout" >&2
	fi
done

echo "Installation des paquets sur les serveurs..."

# Simplified package installation (removed PHP/FPM)
for server in $NGINX_SERVER; do
	echo "  Installation Nginx sur $server"
	lxc exec $server -- bash -c "apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y nginx" || exit 1
	lxc exec $server -- rm -f /etc/nginx/sites-enabled/default || true
done

for server in $WAFS; do
	echo "  Installation Nginx + ModSecurity (and CRS) sur $server"
	lxc exec $server -- bash -c '
		apt update -y
		DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs
	' || exit 1
	lxc exec $server -- rm -f /etc/nginx/sites-enabled/default || true
done

for server in $APACHE_SERVER; do
	echo "  Installation Apache sur $server"
	lxc exec $server -- bash -c "apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y apache2" || exit 1
	lxc exec $server -- rm -f /etc/apache2/sites-enabled/000-default.conf || true
	lxc exec $server -- a2dissite 000-default || true
	lxc exec $server -- a2enmod rewrite headers || true # Removed ssl and proxy modules for simplification
done

echo "  Installation Redis sur $REDIS"
lxc exec $REDIS -- bash -c "apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y redis-server" || exit 1

echo "  Installation HAProxy sur $HA_PROXY"
lxc exec $HA_PROXY -- bash -c "apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y haproxy" || exit 1

echo "Création et configuration des réseaux..."
for net in $NETS; do
    echo "  → Création réseau $net"
    lxc network create $net ipv6.dhcp=false ipv4.dhcp=false \
                            ipv6.nat=false ipv4.nat=false \
                            --type bridge >& /dev/null || true
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

echo "Configuration du routage..."
# Enable IP forwarding on WAFs
for server in $WAFS; do
    lxc exec $server -- sysctl -w net.ipv4.ip_forward=1 >& /dev/null
done

# Add default routes for web servers
lxc exec $WEB1 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB2 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB3 -- ip route add default via 192.168.1.2 dev eth0 || true

echo "Envoi des fichiers de configuration..."

# Push simplified SSL certificate to HAProxy
echo "  Pushing simplified SSL certificate to HAProxy"
lxc exec $HA_PROXY -- mkdir -p /etc/ssl/private
push_file ssl_certs/haproxy.pem $HA_PROXY /etc/ssl/private/haproxy.pem
lxc exec $HA_PROXY -- chown -R haproxy:haproxy /etc/ssl/private || true
lxc exec $HA_PROXY -- chmod 600 /etc/ssl/private/haproxy.pem || true

# Push config files
push_file haproxy.cfg $HA_PROXY /etc/haproxy/haproxy.cfg
for waf in $WAFS; do
	push_file nginx-waf.conf $waf /etc/nginx/nginx.conf
done
for web in $NGINX_SERVER; do
	push_file nginx-web.conf $web /etc/nginx/nginx.conf
	push_file ssi.conf $web /etc/nginx/sites-enabled/ssi.conf
	push_file gil.conf $web /etc/nginx/sites-enabled/gil.conf
	lxc exec $web -- mkdir -p /var/www/{ssi,gil}
	push_file index-ssi.html $web /var/www/ssi/index.html
	push_file index-gil.html $web /var/www/gil/index.html
done

# Configure Apache (web2)
push_file apache-ssi.conf $WEB2 /etc/apache2/sites-available/apache-ssi.conf
push_file apache-gil.conf $WEB2 /etc/apache2/sites-available/apache-gil.conf
lxc exec $WEB2 -- mkdir -p /var/www/{ssi,gil}
push_file index-ssi.html $WEB2 /var/www/ssi/index.html
push_file index-gil.html $WEB2 /var/www/gil/index.html
lxc exec $WEB2 -- a2ensite apache-ssi apache-gil || true

echo "Configuration de ModSecurity sur les WAFs..."
for server in $WAFS; do
	lxc exec $server -- mkdir -p /etc/nginx/modsec
	if lxc exec $server -- test -f /etc/modsecurity/modsecurity.conf-recommended; then
		lxc exec $server -- cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
		lxc exec $server -- sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf || true
	else
		lxc exec $server -- bash -c "cat > /etc/nginx/modsec/modsecurity.conf <<'MCONF'
SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off
MCONF"
	fi
	lxc exec $server -- bash -c "echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf"
	if lxc exec $server -- test -f /usr/share/modsecurity-crs/owasp-crs.load; then
		lxc exec $server -- bash -c "echo 'Include /usr/share/modsecurity-crs/owasp-crs.load' >> /etc/nginx/modsec/main.conf"
		lxc exec $server -- bash -c "sed -i 's/^IncludeOptional/Include/' /usr/share/modsecurity-crs/owasp-crs.load"
	fi
done

echo "Configuration de Redis..."
# Simplified Redis config: just bind to the correct IP and set a random password
lxc exec $REDIS -- bash -c 'cp /etc/redis/redis.conf /etc/redis/redis.conf.bak || true'
REDIS_PASS=$(openssl rand -base64 24)
lxc exec $REDIS -- bash -c "sed -i 's/bind 127.0.0.1 -::1/bind 30.0.0.1/' /etc/redis/redis.conf || true; if ! grep -q '^requirepass' /etc/redis/redis.conf; then echo 'requirepass ${REDIS_PASS}' >> /etc/redis/redis.conf; fi; systemctl restart redis"
echo "Redis password (store it safely): ${REDIS_PASS}"

echo "Redémarrage des services..."
lxc exec $HA_PROXY -- systemctl restart haproxy

echo "Testing and restarting web services..."
for n in $NGINX_SERVER $WAFS; do
	lxc exec $n -- nginx -t 2>/dev/null && lxc exec $n -- systemctl restart nginx || { echo "[ERROR] Nginx config test failed on $n. Check logs."; exit 1; }
done
lxc exec $WEB2 -- systemctl restart apache2

# Simple service checker (kept for robustness)
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
for n in $NGINX_SERVER $WAFS; do
	check_service $n nginx || true
done
check_service $WEB2 apache2 || true
check_service $REDIS redis-server || check_service $REDIS redis || true

echo ""
echo "====== Infrastructure déployée avec succès (Simplifié) ======"
echo ""
echo "Architecture:"
echo "  Internet → HAProxy (20.0.0.1) → WAFs (20.0.0.2-3) → Web Servers (192.168.1.3-5) → Redis (30.0.0.1)"
echo ""
echo "Pour tester (Note: le certificat est auto-signé, vous devrez peut-être utiliser -k avec curl):"
echo "  lxc exec haproxy -- curl -k https://20.0.0.1"
echo "  lxc exec waf1 -- curl http://192.168.1.3"
echo ""
echo "Pour supprimer:"
echo "  $0 -d"
echo ""
