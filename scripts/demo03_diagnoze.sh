#!/bin/bash
set -e

echo "[1/8] Deleting stale tapfc0 interface and route if they exist..."
sudo ip link delete tapfc0 2>/dev/null || true
sudo ip route del 172.16.0.0/24 dev tapfc0 2>/dev/null || true
sudo ip neigh flush dev tapfc0 2>/dev/null || true

echo "[2/8] Verifying remaining route for fcbr0..."
ip route show | grep 172.16.0.0/24 || {
  echo "No route for 172.16.0.0/24 found, adding it..."
  sudo ip route add 172.16.0.0/24 dev fcbr0
}

echo "[3/8] Checking fcbr0 interface details..."
ip addr show fcbr0

echo "[4/8] Pinging 172.16.0.10 to populate ARP cache..."
ping -c1 172.16.0.10 || {
  echo "Ping to 172.16.0.10 failed, continuing anyway..."
}

echo "[5/8] Checking ARP/neighbour table for 172.16.0.10..."
ip neigh show | grep 172.16.0.10 || {
  echo "No ARP entry for 172.16.0.10 yet."
}

echo "[6/8] Enabling IPv4 forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1

echo "[7/8] Final route table for verification:"
ip route show | grep 172.16.0.0/24

echo "[8/8] Trying SSH into 172.16.0.10..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@172.16.0.10 || {
  echo "SSH failed. Please check connection manually."
}

echo "✅ Debugging finished."
