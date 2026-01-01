echo "0" > /proc/sys/net/ipv4/ip_forward
IF_INT="eth1"
IF_EXT="eth0"
IP_DMZ="192.168.1.10"
IP_FW2="192.168.1.254"
IP_PUBLIC="10.2.2.1"

IP_WEB="192.168.1.50"
IP_DNS="192.168.1.50"

PORT_WEB="80,443"
PORT_DNS="53"

iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -X SERVICES
iptables -F 
iptables -t nat -F
iptables -Z
iptables -t nat -Z

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Regles NAT
iptables -t nat -A PREROUTING -i $IF_EXT -p tcp -m multiport --dports $PORT_WEB -j DNAT --to-destination $IP_WEB
iptables -t nat -A POSTROUTING -o $IF_EXT -j SNAT --to-source $IP_PUBLIC

iptables -A FORWARD -i $IF_EXT -m state --state NEW,ESTABLISHED -j SERVICES
# Regles de services
iptables -N SERVICES
iptables -A SERVICES -p tcp -m multiport --dports $PORT_WEB -j ACCEPT
iptables -A SERVICES -p tcp -m multiport --dports $PORT_DNS -j ACCEPT

iptables -A SERVICES -j LOG --log-prefix "FW DROP: "
iptables -A SERVICES -j DROP

iptables -p tcp -A FORWARD -i $IF_INT -m state --state ESTABLISHED -m multiport --sports $PORT_WEB -j ACCEPT

# Regles nft

#script comme celui de /etc/nftables.conf

nft -f ./nftscript.conf

# Ajout rÃ©gle SSH

iptables -A INPUT -i $IF_EXT -p tcp --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o $IF_EXT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i $IF_EXT -p tcp --dport 2222 -m state --state NEW,ESTABLISHED -j DNAT --to-destination $IP_FW2:22
iptables -A OUTPUT -o $IF_EXT -p tcp --sport 2222 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i $IF_EXT -p tcp --dport 2223 -m state --state NEW,ESTABLISHED -j DNAT --to-destination $IP_FW2:2222
iptables -A OUTPUT -o $IF_EXT -p tcp --sport 2223 -m state --state ESTABLISHED -j ACCEPT

echo "1" > /proc/sys/net/ipv4/ip_forward
