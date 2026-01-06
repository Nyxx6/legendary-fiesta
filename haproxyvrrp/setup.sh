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
HA_PROXY_M="master"
HA_PROXY_B="backup"
CLIENT="client"

BACK_NET="back_net"
FRONT_NET="front_net"

while getopts "drh" opt; do
	case ${opt} in
		d|r) DELETE_ALL=1 ;;
		h) usage; exit 0 ;;
		*) usage; exit 1 ;;
	esac
done

if [ $DELETE_ALL -eq 1 ]; then
	echo "Suppression de l'architecture..."
	for server in $WEB1 $WEB2 $HA_PROXY_M $HA_PROXY_B $CLIENT; do
		lxc delete $server --force || true
	done
	for net in $BACK_NET $FRONT_NET; do
		lxc network delete $net || true
	done
    
	rm -rf ssl_certs
	rm -f haproxy.cfg nginx-web.conf ssi.conf gil.conf index-ssi.html index-gil.html keepalived-master.conf keepalived-backup.conf
    
	echo "====== Infrastructure supprimée ======"
	exit 0
fi

echo "Création des fichiers de configuration sur l'hôte..."

# HAProxy Configuration with TLS termination
cat > haproxy.cfg << 'EOF'
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend https_front
    bind *:443 ssl crt /etc/haproxy/ssl/combined.pem
    mode http
    
    acl is_ssi hdr(host) -i ssi.local
    acl is_gil hdr(host) -i gil.local
    
    use_backend ssi_backend if is_ssi
    use_backend gil_backend if is_gil
    default_backend ssi_backend

backend ssi_backend
    mode http
    balance roundrobin
    option httpchk GET /
    server web1 192.168.1.10:80 check
    server web2 192.168.1.11:80 check

backend gil_backend
    mode http
    balance roundrobin
    option httpchk GET /
    server web1 192.168.1.10:80 check
    server web2 192.168.1.11:80 check
EOF

# Keepalived Master Configuration
cat > keepalived-master.conf << 'EOF'
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    
    virtual_ipaddress {
        10.0.0.1/24
    }
}
EOF

# Keepalived Backup Configuration
cat > keepalived-backup.conf << 'EOF'
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 90
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    
    virtual_ipaddress {
        10.0.0.1/24
    }
}
EOF

# Nginx Web Server Configuration
cat > nginx-web.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    
    include /etc/nginx/sites-enabled/*;
}
EOF

cat > ssi.conf << 'EOF'
server {
    listen 80;
    server_name ssi.local;
    root /var/www/ssi;
    index index.html;
    
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

cat > gil.conf << 'EOF'
server {
    listen 80;
    server_name gil.local;
    root /var/www/gil;
    index index.html;
    
    location / {
        try_files $uri $uri/ =404;
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
		<p>Serveur: Nginx</p>
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
		<p>Serveur: Nginx</p>
	</div>
</body>
</html>
EOF

echo "Fichiers de configuration créés"

echo "Génération des certificats ECDSA pour termination HAProxy..."
mkdir -p ssl_certs

# Generate ECDSA CA
openssl ecparam -genkey -name prime256v1 -out ssl_certs/ca-key.pem 2>/dev/null
openssl req -new -x509 -days 3650 -key ssl_certs/ca-key.pem -sha256 \
    -out ssl_certs/ca.pem \
    -subj "/C=FR/ST=IDF/L=Paris/O=Infrastructure/CN=RootCA" 2>/dev/null

# Generate ECDSA server key
openssl ecparam -genkey -name prime256v1 -out ssl_certs/server-key.pem 2>/dev/null

# Create CSR
openssl req -new -key ssl_certs/server-key.pem \
    -out ssl_certs/server.csr \
    -subj "/C=FR/ST=IDF/L=Paris/O=Infrastructure/CN=*.local" 2>/dev/null

# Extensions file
cat > ssl_certs/cert-ext.cnf << 'EXTEOF'
subjectAltName = DNS:ssi.local,DNS:*.ssi.local,DNS:gil.local,DNS:*.gil.local,IP:10.0.0.1
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
EXTEOF

# Sign certificate
openssl x509 -req -in ssl_certs/server.csr -CA ssl_certs/ca.pem \
    -CAkey ssl_certs/ca-key.pem -CAcreateserial \
    -out ssl_certs/server-cert.pem -days 365 -sha256 \
    -extfile ssl_certs/cert-ext.cnf 2>/dev/null

# Create combined PEM for HAProxy (cert + key)
cat ssl_certs/server-cert.pem ssl_certs/server-key.pem > ssl_certs/combined.pem

echo "Création des conteneurs..."
for server in $WEB1 $WEB2 $HA_PROXY_M $HA_PROXY_B $CLIENT; do
    echo "  → Création de $server"
    lxc launch ubuntu:24.04 $server || true
done

echo "Attente du démarrage des conteneurs..."

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

for server in $WEB1 $WEB2 $HA_PROXY_M $HA_PROXY_B $CLIENT; do
	echo "  Waiting for $server to be reachable..."
	if ! check_container_ready "$server"; then
		echo "Warning: $server did not become reachable within timeout" >&2
	fi
done

echo "Installation des paquets sur les serveurs..."

for server in $WEB1 $WEB2; do
	echo "  Installation Nginx sur $server"
	lxc exec $server -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y nginx" || exit 1
	lxc exec $server -- rm -f /etc/nginx/sites-enabled/default || true
done

echo "  Installation HAProxy et keepalived sur $HA_PROXY_M et $HA_PROXY_B"
for hp in $HA_PROXY_M $HA_PROXY_B; do
	lxc exec $hp -- bash -c "apt update && DEBIAN_FRONTEND=noninteractive apt install -y haproxy keepalived" || exit 1
done

echo "  Mise à jour client"
lxc exec $CLIENT -- bash -c "apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl" || exit 1

echo "Création et configuration des réseaux..."
for net in $BACK_NET $FRONT_NET; do
    echo "  → Création réseau $net"
    lxc network create $net ipv6.dhcp=false ipv4.dhcp=false \
                            ipv6.nat=false ipv4.nat=false \
                            --type bridge >& /dev/null || true
done

echo "Configuration des interfaces réseau..."

# Web servers - only back_net
for server in $WEB1 $WEB2; do
    lxc network attach $BACK_NET $server eth0
    lxc exec $server -- ip addr flush dev eth0
done

# HAProxys - dual-homed (front_net on eth0, back_net on eth1)
lxc network attach $FRONT_NET $HA_PROXY_M eth0
lxc exec $HA_PROXY_M -- ip addr flush dev eth0

lxc network attach $FRONT_NET $HA_PROXY_B eth0
lxc exec $HA_PROXY_B -- ip addr flush dev eth0

lxc config device add $HA_PROXY_M eth1 nic nictype=bridged parent=$BACK_NET >& /dev/null || true
lxc exec $HA_PROXY_M -- ip link set dev eth1 up

lxc config device add $HA_PROXY_B eth1 nic nictype=bridged parent=$BACK_NET >& /dev/null || true
lxc exec $HA_PROXY_B -- ip link set dev eth1 up

# Client - only front_net
lxc network attach $FRONT_NET $CLIENT eth0
lxc exec $CLIENT -- ip addr flush dev eth0

echo "Attribution des adresses IP..."
# Front network
lxc exec $CLIENT -- ip addr add 10.0.0.10/24 dev eth0
lxc exec $HA_PROXY_M -- ip addr add 10.0.0.2/24 dev eth0
lxc exec $HA_PROXY_B -- ip addr add 10.0.0.3/24 dev eth0

# Back network
lxc exec $HA_PROXY_M -- ip addr add 192.168.1.1/24 dev eth1
lxc exec $HA_PROXY_B -- ip addr add 192.168.1.2/24 dev eth1
lxc exec $WEB1 -- ip addr add 192.168.1.10/24 dev eth0
lxc exec $WEB2 -- ip addr add 192.168.1.11/24 dev eth0

# Set default gateway for web servers
lxc exec $WEB1 -- ip route add default via 192.168.1.1
lxc exec $WEB2 -- ip route add default via 192.168.1.1

echo "Configuration de la résolution DNS..."
for hp in $HA_PROXY_M $HA_PROXY_B; do
	lxc exec $hp -- bash -c "echo '10.0.0.1 ssi.local' >> /etc/hosts"
	lxc exec $hp -- bash -c "echo '10.0.0.1 gil.local' >> /etc/hosts"
done

lxc exec $CLIENT -- bash -c "echo '10.0.0.1 ssi.local' >> /etc/hosts"
lxc exec $CLIENT -- bash -c "echo '10.0.0.1 gil.local' >> /etc/hosts"

echo "Envoi des fichiers de configuration..."

# Push SSL certificates to both HAProxy containers
for hp in $HA_PROXY_M $HA_PROXY_B; do
	lxc exec $hp -- mkdir -p /etc/haproxy/ssl
	push_file ssl_certs/combined.pem $hp /etc/haproxy/ssl/combined.pem || { echo "Failed to push SSL cert to $hp"; exit 1; }
	lxc exec $hp -- chmod 600 /etc/haproxy/ssl/combined.pem
done

# Push HAProxy config
push_file haproxy.cfg $HA_PROXY_M /etc/haproxy/haproxy.cfg || { echo "Failed to push haproxy.cfg to master"; exit 1; }
push_file haproxy.cfg $HA_PROXY_B /etc/haproxy/haproxy.cfg || { echo "Failed to push haproxy.cfg to backup"; exit 1; }

# Push keepalived configs
push_file keepalived-master.conf $HA_PROXY_M /etc/keepalived/keepalived.conf || { echo "Failed to push keepalived config to master"; exit 1; }
push_file keepalived-backup.conf $HA_PROXY_B /etc/keepalived/keepalived.conf || { echo "Failed to push keepalived config to backup"; exit 1; }

# Push nginx configs to both web servers
for web in $WEB1 $WEB2; do
	push_file nginx-web.conf $web /etc/nginx/nginx.conf || { echo "Failed to push nginx.conf to $web"; exit 1; }
	push_file ssi.conf $web /etc/nginx/sites-enabled/ssi.conf || { echo "Failed to push ssi.conf to $web"; exit 1; }
	push_file gil.conf $web /etc/nginx/sites-enabled/gil.conf || { echo "Failed to push gil.conf to $web"; exit 1; }
done

# Create web directories and push HTML
for web in $WEB1 $WEB2; do
	lxc exec $web -- mkdir -p /var/www/{ssi,gil}
	push_file index-ssi.html $web /var/www/ssi/index.html || { echo "Failed to push index-ssi.html to $web"; exit 1; }
	push_file index-gil.html $web /var/www/gil/index.html || { echo "Failed to push index-gil.html to $web"; exit 1; }
	lxc exec $web -- chown -R www-data:www-data /var/www
done

echo "Redémarrage des services..."

# Restart keepalived first to establish VIP
lxc exec $HA_PROXY_M -- systemctl restart keepalived
lxc exec $HA_PROXY_B -- systemctl restart keepalived
sleep 2

# Restart HAProxy
lxc exec $HA_PROXY_M -- systemctl restart haproxy
lxc exec $HA_PROXY_B -- systemctl restart haproxy

echo "Testing nginx configurations..."
for n in $WEB1 $WEB2; do
	echo "  Testing nginx config on $n"
	if ! lxc exec $n -- nginx -t 2>&1; then
		echo "[ERROR] Nginx config test failed on $n" >&2
		exit 1
	fi
	echo "  Restarting nginx on $n"
	lxc exec $n -- systemctl restart nginx
done

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
for n in $WEB1 $WEB2; do
	check_service $n nginx || true
done
for n in $HA_PROXY_M $HA_PROXY_B; do
	check_service $n haproxy || true
	check_service $n keepalived || true
done

echo ""
echo "====== Infrastructure déployée avec succès ======"
echo ""
echo "Architecture:"
echo "  Client (10.0.0.10)"
echo "    ↓"
echo "  VIP: 10.0.0.1 (VRRP keepalived)"
echo "    ↓"
echo "  HAProxy Master (10.0.0.2/192.168.1.1) + Backup (10.0.0.3/192.168.1.2)"
echo "    ↓"
echo "  Web1 (192.168.1.10) + Web2 (192.168.1.11)"
echo ""
echo "Pour tester depuis le client:"
echo "  lxc exec $CLIENT -- curl -k https://ssi.local"
echo "  lxc exec $CLIENT -- curl -k https://gil.local"
echo ""
echo "Vérifier VRRP:"
echo "  lxc exec $HA_PROXY_M -- ip addr show eth0 | grep 10.0.0.1"
echo ""
echo "Pour supprimer:"
echo "  $0 -d"
echo ""
