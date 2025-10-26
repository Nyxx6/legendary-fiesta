#!/bin/bash

# LXD Network Topology Setup Script with Proper Bridge Configuration
# Creates a network with 3 routers (R1, R2, R3) and 3 clients (C1, C2, C3)
# Using 192.168.1.0/24 with proper subnetting

set -e

# Function to cleanup existing setup
cleanup() {
    echo "=== Cleaning up existing setup ==="
    
    # Delete containers if they exist
    for container in R1 R2 R3 C1 C2 C3; do
        if lxc list --format csv -c n | grep -q "^${container}$"; then
            echo "Deleting container: $container"
            lxc delete -f $container
        fi
    done
    
    # Delete bridges if they exist
    for bridge in br1 br11 br13 br2 br23 br3; do
        if lxc network list --format csv -c n | grep -q "^${bridge}$"; then
            echo "Deleting bridge: $bridge"
            lxc network delete $bridge
        fi
    done
    
    echo "Cleanup completed!"
}

# Check if cleanup flag is provided
if [ "$1" == "cleanup" ] || [ "$1" == "--cleanup" ] || [ "$1" == "-c" ]; then
    cleanup
    exit 0
fi

# Run cleanup before setup
cleanup

echo ""
echo "=== Creating Bridge Networks ==="
echo ""

# Create bridges without any IP configuration (pure L2 bridges)
# br1: R1 to C1 - 192.168.1.48/28
lxc network create br1 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

# br11: R1 to R2 - 192.168.1.36/30
lxc network create br11 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

# br13: R1 to R3 - 192.168.1.32/30
lxc network create br13 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

# br2: R2 to C2 - 192.168.1.128/25
lxc network create br2 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

# br23: R2 to R3 - 192.168.1.28/30
lxc network create br23 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

# br3: R3 to C3 - 192.168.1.40/29
lxc network create br3 \
    ipv4.address=none \
    ipv6.address=none \
    ipv4.dhcp=false \
    ipv6.dhcp=false

echo "=== Creating Containers ==="

# Create containers with only eth0 (default management interface)
lxc launch ubuntu:22.04 R1
lxc launch ubuntu:22.04 R2
lxc launch ubuntu:22.04 R3
lxc launch ubuntu:22.04 C1
lxc launch ubuntu:22.04 C2
lxc launch ubuntu:22.04 C3

echo "=== Waiting for containers to start ==="
sleep 15

echo "=== Attaching NICs to bridges ==="

# R1 interfaces
lxc config device add R1 eth1 nic nictype=bridged parent=br1
lxc config device add R1 eth2 nic nictype=bridged parent=br11
lxc config device add R1 eth3 nic nictype=bridged parent=br13

# R2 interfaces
lxc config device add R2 eth1 nic nictype=bridged parent=br11
lxc config device add R2 eth2 nic nictype=bridged parent=br23
lxc config device add R2 eth3 nic nictype=bridged parent=br2

# R3 interfaces
lxc config device add R3 eth1 nic nictype=bridged parent=br13
lxc config device add R3 eth2 nic nictype=bridged parent=br23
lxc config device add R3 eth3 nic nictype=bridged parent=br3

# Client interfaces
lxc config device add C1 eth1 nic nictype=bridged parent=br1
lxc config device add C2 eth1 nic nictype=bridged parent=br2
lxc config device add C3 eth1 nic nictype=bridged parent=br3

echo "=== Waiting for interfaces to be ready ==="
sleep 5

echo "=== Configuring R1 (Router 1) ==="
lxc exec R1 -- bash -c "
# Configure interfaces
ip addr add 192.168.1.62/28 dev eth1
ip addr add 192.168.1.38/30 dev eth2
ip addr add 192.168.1.34/30 dev eth3

ip link set eth1 up
ip link set eth2 up
ip link set eth3 up

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1

# Add routes to other subnets
ip route add 192.168.1.128/25 via 192.168.1.37 dev eth2
ip route add 192.168.1.40/29 via 192.168.1.33 dev eth3
ip route add 192.168.1.28/30 via 192.168.1.37 dev eth2
"

echo "=== Configuring R2 (Router 2) ==="
lxc exec R2 -- bash -c "
# Configure interfaces
ip addr add 192.168.1.37/30 dev eth1
ip addr add 192.168.1.30/30 dev eth2
ip addr add 192.168.1.254/25 dev eth3

ip link set eth1 up
ip link set eth2 up
ip link set eth3 up

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1

# Add routes to other subnets
ip route add 192.168.1.48/28 via 192.168.1.38 dev eth1
ip route add 192.168.1.32/30 via 192.168.1.38 dev eth1
ip route add 192.168.1.40/29 via 192.168.1.29 dev eth2
"

echo "=== Configuring R3 (Router 3) ==="
lxc exec R3 -- bash -c "
# Configure interfaces
ip addr add 192.168.1.33/30 dev eth1
ip addr add 192.168.1.29/30 dev eth2
ip addr add 192.168.1.46/29 dev eth3

ip link set eth1 up
ip link set eth2 up
ip link set eth3 up

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1

# Add routes to other subnets
ip route add 192.168.1.48/28 via 192.168.1.34 dev eth1
ip route add 192.168.1.36/30 via 192.168.1.34 dev eth1
ip route add 192.168.1.128/25 via 192.168.1.30 dev eth2
"

echo "=== Configuring C1 (Client 1) ==="
lxc exec C1 -- bash -c "
ip addr add 192.168.1.50/28 dev eth1
ip link set eth1 up
ip route add default via 192.168.1.62 dev eth1
"

echo "=== Configuring C2 (Client 2) ==="
lxc exec C2 -- bash -c "
ip addr add 192.168.1.130/25 dev eth1
ip link set eth1 up
ip route add default via 192.168.1.254 dev eth1
"

echo "=== Configuring C3 (Client 3) ==="
lxc exec C3 -- bash -c "
ip addr add 192.168.1.42/29 dev eth1
ip link set eth1 up
ip route add default via 192.168.1.46 dev eth1
"

echo ""
echo "=== Network Topology Created Successfully ==="
echo ""
echo "Bridge Networks (Layer 2):"
echo "  br1  - R1 <-> C1"
echo "  br11 - R1 <-> R2"
echo "  br13 - R1 <-> R3"
echo "  br2  - R2 <-> C2"
echo "  br23 - R2 <-> R3"
echo "  br3  - R3 <-> C3"
echo ""
echo "Subnet Allocation from 192.168.1.0/24:"
echo "  br1:  192.168.1.48/28   (14 hosts)  - R1 (.62) <-> C1 (.50)"
echo "  br11: 192.168.1.36/30   (2 hosts)   - R1 (.38) <-> R2 (.37)"
echo "  br13: 192.168.1.32/30   (2 hosts)   - R1 (.34) <-> R3 (.33)"
echo "  br2:  192.168.1.128/25  (126 hosts) - R2 (.254) <-> C2 (.130)"
echo "  br23: 192.168.1.28/30   (2 hosts)   - R2 (.30) <-> R3 (.29)"
echo "  br3:  192.168.1.40/29   (6 hosts)   - R3 (.46) <-> C3 (.42)"
echo ""
echo "Test connectivity:"
echo "  lxc exec C1 -- ping -c 3 192.168.1.130  # C1 -> C2"
echo "  lxc exec C1 -- ping -c 3 192.168.1.42   # C1 -> C3"
echo "  lxc exec C2 -- ping -c 3 192.168.1.42   # C2 -> C3"
echo ""
echo "Test routing paths:"
echo "  lxc exec C1 -- traceroute 192.168.1.130  # C1 -> R1 -> R2 -> C2"
echo "  lxc exec C1 -- traceroute 192.168.1.42   # C1 -> R1 -> R3 -> C3"
echo ""
echo "View configurations:"
echo "  lxc network list"
echo "  lxc config device list R1"
echo "  lxc exec R1 -- ip addr"
echo "  lxc exec R1 -- ip route"
echo ""

# Test connectivity
echo "Testing connectivity from C1 to C2 and C3..."
lxc exec C1 -- ping -c 3 192.168.1.130  # C1 -> C2
lxc exec C1 -- ping -c 3 192.168.1.42   # C1 -> C3
lxc exec C2 -- ping -c 3 192.168.1.42   # C2 -> C3

echo "To cleanup this setup, run: $0 cleanup"

