#!/bin/bash
WAN=$(ip route get 8.8.8.8 | awk '/dev/ {print $5}')
nft add rule ip filter FORWARD iifname "lxdbr0" oifname $WAN accept
nft add rule ip filter FORWARD iifname $WAN oifname "lxdbr0" ct state established,related accept
