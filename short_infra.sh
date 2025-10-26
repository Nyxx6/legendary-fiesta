#!/bin/bash
set -eE
trap 'echo "[ERROR] at line ${LINENO}" >&2; exit 1' ERR

check_requirements() {
	for bin in lxc openssl curl; do
		command -v $bin >/dev/null 2>&1 || { echo "Missing: $bin" >&2; exit 1; }
	done
}
check_requirements

WEB1="web1"; WEB2="web2"; WEB3="web3"
WAF1="waf1"; WAF2="waf2"; HA_PROXY="haproxy"; REDIS="redis"
BACK_NET="back_net"; WAF_NET="waf_net"; REDIS_NET="redis_net"

[ "${1}" = "-d" ] && {
	echo "Deleting infrastructure..."
	for c in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY $REDIS; do lxc delete $c --force 2>/dev/null || true; done
	for n in $BACK_NET $WAF_NET $REDIS_NET; do lxc network delete $n 2>/dev/null || true; done
	rm -rf ssl_certs *.conf *.html
	echo "Done"; exit 0
}

# HAProxy config
cat > haproxy.cfg <<'EOF'
global
	daemon
	ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
defaults
	mode http
	timeout connect 5s
	timeout client 50s
	timeout server 50s
frontend http_front
	bind *:80
	redirect scheme https code 301
frontend https_front
	bind *:443 ssl crt /etc/ssl/private/haproxy.pem alpn h2,http/1.1
	http-response set-header Strict-Transport-Security "max-age=31536000"
	http-request set-header X-Forwarded-Proto https
	default_backend wafs
backend wafs
	balance roundrobin
	http-check send meth GET uri / ver HTTP/1.1 hdr Host healthcheck
	http-check expect status 200
	server waf1 20.0.0.2:80 check
	server waf2 20.0.0.3:80 check
EOF

# WAF Nginx config
cat > nginx-waf.conf <<'EOF'
user www-data;
worker_processes auto;
events { worker_connections 768; }
http {
	include /etc/nginx/mime.types;
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
		location = / {
			if ($http_host = "healthcheck") {
				return 200 "OK\n";
			}
			proxy_pass http://web_cluster;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
		}
		location / {
			proxy_pass http://web_cluster;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
		}
	}
}
EOF

# Web Nginx config
cat > nginx-web.conf <<'EOF'
user www-data;
worker_processes auto;
events { worker_connections 768; }
http {
	include /etc/nginx/mime.types;
	server {
		listen 80 default_server;
		root /var/www/html;
		index index.html;
		location / { try_files $uri $uri/ =404; }
	}
}
EOF

# Apache config
cat > apache-site.conf <<'EOF'
<VirtualHost *:80>
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Require all granted
    </Directory>
</VirtualHost>
EOF

# Simple HTML
cat > index.html <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Lab Site</title>
<style>body{font-family:sans-serif;text-align:center;padding:50px;background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;min-height:100vh;display:flex;align-items:center;justify-content:center;flex-direction:column;}h1{font-size:3em;margin:0;}</style>
</head><body><h1>Lab Infrastructure</h1><p>Server Ready</p></body></html>
EOF

# SSL cert (single RSA)
echo "Generating SSL..."
mkdir -p ssl_certs
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout ssl_certs/haproxy-key.pem -out ssl_certs/haproxy-cert.pem \
    -subj "/CN=haproxy.local" 2>/dev/null
cat ssl_certs/haproxy-cert.pem ssl_certs/haproxy-key.pem > ssl_certs/haproxy.pem

echo "Creating containers..."
for c in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY $REDIS; do
    lxc launch ubuntu:24.04 $c 2>/dev/null || true
done

echo "Waiting for containers to initialize..."
for c in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY $REDIS; do
	timeout=30
	while [ $timeout -gt 0 ]; do
		lxc exec $c -- systemctl is-system-running --wait 2>/dev/null && break
		sleep 2
		timeout=$((timeout-2))
	done
done

# Fix time sync issues
echo "Syncing time..."
for c in $WEB1 $WEB2 $WEB3 $WAF1 $WAF2 $HA_PROXY $REDIS; do
	lxc exec $c -- timedatectl set-ntp true 2>/dev/null || true
done
sleep 5

echo "Installing packages..."
for c in $WEB1 $WEB3; do
	lxc exec $c -- bash -c "
		for i in 1 2 3; do apt update 2>/dev/null && break; sleep 10; done
		DEBIAN_FRONTEND=noninteractive apt install -y nginx
	" &
done
wait

for c in $WAF1 $WAF2; do
	lxc exec $c -- bash -c "
		# Retry apt update if time sync issue
		for i in 1 2 3; do
			add-apt-repository -y universe 2>/dev/null || true
			apt update 2>/dev/null && break
			echo 'Retrying apt update (attempt \$i)...'
			sleep 10
		done
		DEBIAN_FRONTEND=noninteractive apt install -y nginx libnginx-mod-http-modsecurity modsecurity-crs
	" &
done
wait

lxc exec $WEB2 -- bash -c "for i in 1 2 3; do apt update 2>/dev/null && break; sleep 10; done; DEBIAN_FRONTEND=noninteractive apt install -y apache2" &
lxc exec $HA_PROXY -- bash -c "for i in 1 2 3; do apt update 2>/dev/null && break; sleep 10; done; DEBIAN_FRONTEND=noninteractive apt install -y haproxy" &
lxc exec $REDIS -- bash -c "for i in 1 2 3; do apt update 2>/dev/null && break; sleep 10; done; DEBIAN_FRONTEND=noninteractive apt install -y redis-server" &
wait

echo "Creating networks..."
for n in $BACK_NET $WAF_NET $REDIS_NET; do
    lxc network create $n ipv6.dhcp=false ipv4.dhcp=false ipv6.nat=false ipv4.nat=false --type bridge 2>/dev/null || true
done

echo "Configuring network..."
# Redis
lxc network attach $REDIS_NET $REDIS eth0
lxc exec $REDIS -- ip addr flush dev eth0
lxc exec $REDIS -- ip addr add 30.0.0.1/24 dev eth0

# Web servers
for c in $WEB1 $WEB2 $WEB3; do
    lxc config device add $c eth1 nic nictype=bridged parent=$REDIS_NET 2>/dev/null || true
    lxc exec $c -- ip link set dev eth1 up
    lxc network attach $BACK_NET $c eth0
    lxc exec $c -- ip addr flush dev eth0
done
lxc exec $WEB1 -- bash -c "ip addr add 192.168.1.3/24 dev eth0; ip addr add 30.0.0.3/24 dev eth1; ip route add default via 192.168.1.1"
lxc exec $WEB2 -- bash -c "ip addr add 192.168.1.4/24 dev eth0; ip addr add 30.0.0.4/24 dev eth1; ip route add default via 192.168.1.1"
lxc exec $WEB3 -- bash -c "ip addr add 192.168.1.5/24 dev eth0; ip addr add 30.0.0.5/24 dev eth1; ip route add default via 192.168.1.2"

# WAFs
for c in $WAF1 $WAF2; do
    lxc config device add $c eth1 nic nictype=bridged parent=$BACK_NET 2>/dev/null || true
    lxc exec $c -- ip link set dev eth1 up
    lxc network attach $WAF_NET $c eth0
    lxc exec $c -- ip addr flush dev eth0
    lxc exec $c -- sysctl -w net.ipv4.ip_forward=1
done
lxc exec $WAF1 -- bash -c "ip addr add 20.0.0.2/24 dev eth0; ip addr add 192.168.1.1/24 dev eth1"
lxc exec $WAF2 -- bash -c "ip addr add 20.0.0.3/24 dev eth0; ip addr add 192.168.1.2/24 dev eth1"

# HAProxy
lxc config device add $HA_PROXY eth1 nic nictype=bridged parent=$WAF_NET 2>/dev/null || true
lxc exec $HA_PROXY -- bash -c "ip link set dev eth1 up; ip addr add 20.0.0.1/24 dev eth1"

echo "Pushing configs..."
lxc exec $HA_PROXY -- mkdir -p /etc/ssl/private
lxc file push ssl_certs/haproxy.pem ${HA_PROXY}/etc/ssl/private/
lxc file push haproxy.cfg ${HA_PROXY}/etc/haproxy/

for c in $WAF1 $WAF2; do
	lxc file push nginx-waf.conf ${c}/etc/nginx/nginx.conf
	lxc exec $c -- bash -c "mkdir -p /etc/nginx/modsec && cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf && sed -i 's/DetectionOnly/On/' /etc/nginx/modsec/modsecurity.conf && echo 'Include /etc/nginx/modsec/modsecurity.conf' > /etc/nginx/modsec/main.conf && echo 'Include /usr/share/modsecurity-crs/owasp-crs.load' >> /etc/nginx/modsec/main.conf"
done

for c in $WEB1 $WEB3; do
	lxc file push nginx-web.conf ${c}/etc/nginx/nginx.conf
	lxc exec $c -- mkdir -p /var/www/html
	lxc file push index.html ${c}/var/www/html/
done

lxc exec $WEB2 -- mkdir -p /var/www/html
lxc file push index.html ${WEB2}/var/www/html/
lxc file push apache-site.conf ${WEB2}/etc/apache2/sites-available/lab.conf
lxc exec $WEB2 -- bash -c "a2dissite 000-default && a2ensite lab"

REDIS_PASS=$(openssl rand -base64 16)
lxc exec $REDIS -- bash -c "sed -i 's/bind 127.0.0.1/bind 30.0.0.1/' /etc/redis/redis.conf && echo 'requirepass ${REDIS_PASS}' >> /etc/redis/redis.conf"

echo "Restarting services..."
lxc exec $HA_PROXY -- systemctl restart haproxy
lxc exec $WAF1 -- systemctl restart nginx
lxc exec $WAF2 -- systemctl restart nginx
lxc exec $WEB1 -- systemctl restart nginx
lxc exec $WEB3 -- systemctl restart nginx
lxc exec $WEB2 -- systemctl restart apache2
lxc exec $REDIS -- systemctl restart redis-server

echo ""
echo "====== Infrastructure Ready ======"
echo "Flow: Internet → HAProxy:443 (SSL term) → WAFs (ModSec) → Web servers → Redis"
echo "Test: lxc exec haproxy -- curl -k https://localhost"
echo "Redis pass: ${REDIS_PASS}"
echo "Delete: $0 -d"
