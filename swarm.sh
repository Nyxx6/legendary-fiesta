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
    echo "  -h           Show help"
    echo "  -d, -r       Delete entire infrastructure"
}

push_file() {
    local src="$1"
    local container="$2"
    local dest_path="$3"
    if [ ! -f "$src" ]; then
        echo "[ERROR] File $src does not exist" >&2
        return 1
    fi
    lxc exec "$container" -- mkdir -p "$(dirname "$dest_path")" || true
    lxc file push "$src" "${container}${dest_path}"
}

DELETE_ALL=0
WEB1="web1" WEB2="web2" WEB3="web3"
WAF1="waf1" WAF2="waf2"
HA_PROXY="haproxy"
REDIS="redis"
WAFS="$WAF1 $WAF2"
WEB_SERVERS="$WEB1 $WEB2 $WEB3"

BACK_NET="back_net"
WAF_NET="waf_net"
REDIS_NET="redis_net"
NETS="$BACK_NET $WAF_NET $REDIS_NET"

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
    rm -f haproxy.cfg nginx-waf.conf nginx-web.conf ssi.conf gil.conf index-*.html Dockerfile
    echo "====== Infrastructure supprimée ======"
    exit 0
fi

echo "Création des fichiers de configuration..."

cat > haproxy.cfg << 'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option forwardfor
    timeout connect 5000
    timeout client 50000
    timeout server 50000

frontend http_front
    bind *:80
    redirect scheme https code 301 if !{ ssl_fc }

frontend https_front
    bind *:443 ssl crt /etc/ssl/private/haproxy-ecdsa.pem crt /etc/ssl/private/haproxy-rsa.pem alpn h2,http/1.1
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port 443
    default_backend serveurswaf

backend serveurswaf
    balance roundrobin
    http-check send meth GET uri / ver HTTP/1.1 hdr Host healthcheck
    http-check expect status 200
    server waf1 20.0.0.2:80 check
    server waf2 20.0.0.3:80 check
EOF

cat > nginx-waf.conf << 'EOF'
user www-data;
worker_processes auto;
events { worker_connections 768; }

http {
    log_format security '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log security;

    set_real_ip_from 20.0.0.0/24;
    real_ip_header X-Real-IP;

    upstream web_ssi { server 192.168.1.3:80; server 192.168.1.4:80; server 192.168.1.5:80; }
    upstream web_gil { server 192.168.1.3:80; server 192.168.1.4:80; server 192.168.1.5:80; }

    server {
        listen 80;
        modsecurity on;
        modsecurity_rules_file /etc/nginx/modsec/main.conf;

        location / {
            if ($http_host = "healthcheck") { return 200 "OK\n"; }
            if ($host = "ssi.local") { proxy_pass http://web_ssi; }
            proxy_pass http://web_gil;
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
events { worker_connections 768; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    set_real_ip_from 192.168.1.0/24;
    real_ip_header X-Real-IP;
    include /etc/nginx/sites-enabled/*;
}
EOF

cat > ssi.conf << 'EOF'
server { listen 80; server_name ssi.local; root /var/www/ssi; index index.html;
         location / { try_files $uri $uri/ =404; } }
EOF

cat > gil.conf << 'EOF'
server { listen 80; server_name gil.local; root /var/www/gil; index index.html;
         location / { try_files $uri $uri/ =404; } }
EOF

cat > index-ssi.html << 'EOF'
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"><title>SSI</title></head>
<body><h1>Site SSI</h1><p>Bienvenue sur le site SSI</p><p>Serveur: Nginx in Docker Swarm</p></body></html>
EOF

cat > index-gil.html << 'EOF'
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"><title>GIL</title></head>
<body><h1>Site GIL</h1><p>Bienvenue sur le site GIL</p><p>Serveur: Nginx in Docker Swarm</p></body></html>
EOF

cat > Dockerfile << 'EOF'
FROM nginx:latest
RUN rm -f /etc/nginx/sites-enabled/default
RUN mkdir -p /var/www/ssi /var/www/gil
COPY nginx-web.conf /etc/nginx/nginx.conf
COPY ssi.conf /etc/nginx/sites-enabled/ssi.conf
COPY gil.conf /etc/nginx/sites-enabled/gil.conf
COPY index-ssi.html /var/www/ssi/index.html
COPY index-gil.html /var/www/gil/index.html
RUN chown -R www-data:www-data /var/www
EOF

echo "Génération des certificats SSL..."
mkdir -p ssl_certs
openssl genrsa -out ssl_certs/ca-key.pem 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key ssl_certs/ca-key.pem -out ssl_certs/ca.pem -subj "/C=FR/ST=IDF/L=Paris/O=Lab/CN=RootCA" 2>/dev/null
cat > ssl_certs/cert-ext.cnf << 'EXTEOF'
subjectAltName = DNS:ssi.local,DNS:gil.local,IP:20.0.0.1
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EXTEOF
openssl ecparam -genkey -name prime256v1 -out ssl_certs/haproxy-ecdsa-key.pem
openssl req -new -key ssl_certs/haproxy-ecdsa-key.pem -out ssl_certs/haproxy-ecdsa.csr -subj "/CN=haproxy.local" 2>/dev/null
openssl x509 -req -days 365 -in ssl_certs/haproxy-ecdsa.csr -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem -out ssl_certs/haproxy-ecdsa-cert.pem -extfile ssl_certs/cert-ext.cnf 2>/dev/null
cat ssl_certs/haproxy-ecdsa-cert.pem ssl_certs/haproxy-ecdsa-key.pem > ssl_certs/haproxy-ecdsa.pem
openssl genrsa -out ssl_certs/haproxy-rsa-key.pem 2048
openssl req -new -key ssl_certs/haproxy-rsa-key.pem -out ssl_certs/haproxy-rsa.csr -subj "/CN=haproxy.local" 2>/dev/null
openssl x509 -req -days 365 -in ssl_certs/haproxy-rsa.csr -CA ssl_certs/ca.pem -CAkey ssl_certs/ca-key.pem -out ssl_certs/haproxy-rsa-cert.pem -extfile ssl_certs/cert-ext.cnf 2>/dev/null
cat ssl_certs/haproxy-rsa-cert.pem ssl_certs/haproxy-rsa-key.pem > ssl_certs/haproxy-rsa.pem

echo "Création des conteneurs..."
for server in $WEB_SERVERS $WAFS $HA_PROXY $REDIS; do
    lxc launch ubuntu:24.04 $server -q
done
sleep 8

echo "Synchronisation de l'heure et configuration LXD pour Docker..."
for ct in $WEB_SERVERS $WAFS $HA_PROXY $REDIS; do
    lxc exec $ct -- bash -c "timedatectl set-ntp true && hwclock --systohc && systemctl restart systemd-timesyncd 2>/dev/null || true"
done
for ct in $WEB_SERVERS; do
    lxc config set $ct security.nesting=true
    lxc config set $ct security.syscalls.intercept.mknod=true
    lxc config set $ct security.syscalls.intercept.setxattr=true
    lxc config set $ct security.syscalls.intercept.mount=true
done
for ct in $WEB_SERVERS; do
    lxc restart $ct --force
done
sleep 12

echo "Installation des paquets (haproxy installé avant SSL)..."
for server in $WEB_SERVERS; do
    lxc exec $server -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y docker.io"
    lxc exec $server -- systemctl enable --now docker
done
for server in $WAFS; do
    lxc exec $server -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs"
    lxc exec $server -- rm -f /etc/nginx/sites-enabled/default
done
lxc exec $HA_PROXY -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y haproxy"
lxc exec $REDIS -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y redis-server"

echo "=== Configuration du registre local Docker ==="
lxc exec $WEB1 -- docker run -d -p 5000:5000 --restart=always --name registry registry:2

for server in $WEB_SERVERS; do
    lxc exec $server -- bash -c '
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<EOF
{ "insecure-registries": ["192.168.1.3:5000"] }
EOF
        systemctl restart docker
    '
done
sleep 5

echo "=== Construction et push vers registre local (seulement sur web1) ==="
push_file Dockerfile $WEB1 /root/Dockerfile
push_file nginx-web.conf $WEB1 /root/nginx-web.conf
push_file ssi.conf $WEB1 /root/ssi.conf
push_file gil.conf $WEB1 /root/gil.conf
push_file index-ssi.html $WEB1 /root/index-ssi.html
push_file index-gil.html $WEB1 /root/index-gil.html

lxc exec $WEB1 -- docker build -t custom-nginx /root
lxc exec $WEB1 -- docker tag custom-nginx:latest 192.168.1.3:5000/custom-nginx:latest
lxc exec $WEB1 -- docker push 192.168.1.3:5000/custom-nginx:latest

echo "=== Pull sur les workers ==="
lxc exec $WEB2 -- docker pull 192.168.1.3:5000/custom-nginx:latest
lxc exec $WEB3 -- docker pull 192.168.1.3:5000/custom-nginx:latest

echo "Configuration des réseaux..."
for net in $NETS; do
    lxc network create $net ipv4.dhcp=false ipv6.dhcp=false ipv4.nat=false ipv6.nat=false --type bridge || true
done

lxc network attach $REDIS_NET $REDIS eth0
lxc exec $REDIS -- ip addr flush dev eth0

for server in $WEB_SERVERS; do
    lxc config device add $server eth1 nic nictype=bridged parent=$REDIS_NET || true
    lxc exec $server -- ip link set dev eth1 up
    lxc network attach $BACK_NET $server eth0
    lxc exec $server -- ip addr flush dev eth0
done

for server in $WAFS; do
    lxc config device add $server eth1 nic nictype=bridged parent=$BACK_NET || true
    lxc exec $server -- ip link set dev eth1 up
    lxc network attach $WAF_NET $server eth0
    lxc exec $server -- ip addr flush dev eth0
done

lxc config device add $HA_PROXY eth1 nic nictype=bridged parent=$WAF_NET || true
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

echo "Configuration du routage..."
for server in $WAFS; do
    lxc exec $server -- sysctl -w net.ipv4.ip_forward=1
done
lxc exec $WEB1 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB2 -- ip route add default via 192.168.1.1 dev eth0 || true
lxc exec $WEB3 -- ip route add default via 192.168.1.2 dev eth0 || true

echo "Initialisation Docker Swarm..."
lxc exec $WEB1 -- docker swarm init --advertise-addr 192.168.1.3
TOKEN=$(lxc exec $WEB1 -- docker swarm join-token worker -q)
lxc exec $WEB2 -- docker swarm join --token $TOKEN 192.168.1.3:2377
lxc exec $WEB3 -- docker swarm join --token $TOKEN 192.168.1.3:2377

echo "Création du service Swarm depuis le registre..."
lxc exec $WEB1 -- docker service create --name webapp --replicas 3 --publish published=80,target=80 192.168.1.3:5000/custom-nginx:latest

echo "Configuration HAProxy (SSL après installation haproxy)..."
lxc exec $HA_PROXY -- mkdir -p /etc/ssl/private
push_file ssl_certs/haproxy-ecdsa.pem $HA_PROXY /etc/ssl/private/haproxy-ecdsa.pem
push_file ssl_certs/haproxy-rsa.pem $HA_PROXY /etc/ssl/private/haproxy-rsa.pem
push_file haproxy.cfg $HA_PROXY /etc/haproxy/haproxy.cfg
lxc exec $HA_PROXY -- chown -R haproxy:haproxy /etc/ssl/private
lxc exec $HA_PROXY -- chmod 600 /etc/ssl/private/haproxy-*.pem

echo "Configuration WAFs..."
push_file nginx-waf.conf $WAF1 /etc/nginx/nginx.conf
push_file nginx-waf.conf $WAF2 /etc/nginx/nginx.conf

echo "Configuration ModSecurity..."
for server in $WAFS; do
    lxc exec $server -- mkdir -p /etc/nginx/modsec
    lxc exec $server -- cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf 2>/dev/null || true
    lxc exec $server -- sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf 2>/dev/null || true
    lxc exec $server -- bash -c 'echo "Include /etc/nginx/modsec/modsecurity.conf" > /etc/nginx/modsec/main.conf'
    lxc exec $server -- bash -c 'echo "Include /usr/share/modsecurity-crs/owasp-crs.load" >> /etc/nginx/modsec/main.conf'
done

echo "Configuration Redis..."
REDIS_PASS=$(openssl rand -base64 24)
lxc exec $REDIS -- bash -c "
    sed -i 's/bind 127.0.0.1 ::1/bind 30.0.0.1/' /etc/redis/redis.conf
    echo 'requirepass $REDIS_PASS' >> /etc/redis/redis.conf
    systemctl restart redis
"
echo "Redis password: $REDIS_PASS"

echo "Redémarrage des services..."
lxc exec $HA_PROXY -- systemctl restart haproxy
for n in $WAFS; do
    lxc exec $n -- systemctl restart nginx
done

echo ""
echo "====== Infrastructure déployée avec succès ======"
echo "Registry: http://192.168.1.3:5000"
echo "Image: 192.168.1.3:5000/custom-nginx:latest"
echo "Test: curl -k https://ssi.local"
echo "      curl -k https://gil.local"
echo "Pour supprimer: $0 -d"
