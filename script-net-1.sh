#!/bin/bash

# set -e
set -x

usage(){
        echo "Usage: $0 [h|r|d]"
	echo "  -h    		Affiche ce menu d'aide"
	echo "  -d, -r		Supprime toute l'architecture"
}

DELETE_ALL=0
WEB1="web1"
WEB2="web2"
WEB3="web3"
WAF1="waf1"
WAF2="waf2"
APACHE_SERVER="$WEB2"
NGINX_SERVER="$WEB1 $WEB3"
WAFS="$WAF1 $WAF2"
HA_PROXY="haproxy"
REDIS="redis"

BACK_NET="back_net"
WAF_NET="waf_net"
REDIS_NET="redis_net"
NETS="$BACK_NET $WAF_NET $REDIS_NET"
WEB_SERVERS="$APACHE_SERVER $NGINX_SERVER"

while getopts ":drh:" opt; do
	case ${opt} in
		d|r) DELETE_ALL=1 ;;
		h|*)
			usage
			exit 1
			;;
	esac
done



if [ $DELETE_ALL -eq 1 ]; then
        echo "Suppression de l'architecture..."
        for server in $WEB_SERVERS $HA_PROXY $WAFS $REDIS; do
            lxc delete $server --force >& /dev/null || true
        done

        for net in $NETS; do
            lxc network delete $net >& /dev/null || true
        done
        echo "====== Infrastructure supprimee ======"
    exit 0
fi


echo "Création des conteneurs..."
for server in $WEB_SERVERS $REDIS $HA_PROXY $WAFS; do
    lxc launch ubuntu:24.04 $server || true
done


echo "Installation d'Apache et ngninx sur les serveurs (web & reverse proxy)"

for server in $NGINX_SERVER; do
    lxc exec $server -- apt update #>& /dev/null
    lxc exec $server -- apt install -y nginx php-fpm #>& /dev/null
done

for server in $WAFS; do
    lxc exec $server -- apt update #>& /dev/null
    lxc exec $server -- apt install -y nginx libnginx-mod-security3 #>& /dev/null
done

for server in $APACHE_SERVER; do
    lxc exec $server -- apt update #>& /dev/null
    lxc exec $server -- apt install -y apache2 #>& /dev/null
done

for server in $REDIS; do
    lxc exec $server -- apt update #>& /dev/null
    lxc exec $server -- apt install -y redis #>& /dev/null
done

for server in $HA_PROXY; do
    lxc exec $server -- apt update #>& /dev/null
    lxc exec $server -- apt install -y haproxy #>& /dev/null
done

echo "Création et configuration du réseau"
for net in $NETS; do
    lxc network create $net ipv6.dhcp=false ipv4.dhcp=false \
                            ipv6.nat=false ipv4.nat=false \
                            --type bridge >& /dev/null || true
done


lxc network attach $REDIS_NET $REDIS eth0
lxc exec $REDIS -- ip addr flush dev eth0 >& /dev/null || true


for server in $WEB_SERVERS; do
        lxc config device add $server eth1 nic nictype=bridged parent=$REDIS_NET >& /dev/null || true
        lxc exec $server -- ip link set dev eth1 up >& /dev/null || true
        lxc network attach $BACK_NET $server eth0
        lxc exec $server -- ip addr flush dev eth0 >& /dev/null || true
done

for server in $WAFS; do
        lxc config device add $server eth1 nic nictype=bridged parent=$BACK_NET >& /dev/null || true
		lxc exec $server -- ip link set dev eth1 up >& /dev/null || true
        lxc network attach $WAF_NET $server eth0
        lxc exec $server -- ip addr flush dev eth0 >& /dev/null || true
done

lxc config device add $HA_PROXY eth1 nic nictype=bridged parent=$WAF_NET >& /dev/null || true
lxc exec $HA_PROXY -- ip link set dev eth1 up >& /dev/null || true




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


echo "Fin de la configuration"
