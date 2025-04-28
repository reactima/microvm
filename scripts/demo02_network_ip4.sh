#!/bin/bash
# -----------------------------------------------------------------------------
# Firecracker Micro-VM Networking Script
# - Setup bridge + TAP devices for multi-VM networking
# - Enable NAT for internet access
# - Cleanup everything after use
#
# Usage:
#   sudo ./network.sh setup    # to create bridge + tap devices
#   sudo ./network.sh cleanup  # to remove bridge + taps
# -----------------------------------------------------------------------------

set -e

# Configurable variables
BRIDGE=fcbr0
HOST_IP=172.16.0.1
SUBNET=172.16.0.0/24
TAPS=(tapfc10 tapfc11 tapfc12)

setup_network() {
  echo "==> Creating bridge $BRIDGE..."
  if ! ip link show $BRIDGE &>/dev/null; then
    sudo ip link add name $BRIDGE type bridge
  fi
  sudo ip addr flush dev $BRIDGE
  sudo ip addr add $HOST_IP/24 dev $BRIDGE
  sudo ip link set $BRIDGE up

  echo "==> Enabling IP forwarding..."
  sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

  echo "==> Configuring NAT (iptables MASQUERADE)..."
  if ! sudo iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s $SUBNET -j MASQUERADE
  fi

  echo "==> Setting up TAP devices and attaching to bridge $BRIDGE..."
  for TAP in "${TAPS[@]}"; do
    if ip link show $TAP &>/dev/null; then
      echo "    Deleting existing $TAP..."
      sudo ip link del $TAP
    fi
    echo "    Creating $TAP..."
    sudo ip tuntap add dev $TAP mode tap
    sudo ip link set $TAP master $BRIDGE
    sudo ip link set $TAP up
  done

  echo "✅ Network setup complete!"
}

cleanup_network() {
  echo "==> Cleaning up TAP devices..."
  for TAP in "${TAPS[@]}"; do
    if ip link show $TAP &>/dev/null; then
      echo "    Deleting $TAP..."
      sudo ip link del $TAP
    fi
  done

  echo "==> Cleaning up bridge $BRIDGE..."
  if ip link show $BRIDGE &>/dev/null; then
    sudo ip link del $BRIDGE
  fi

  echo "✅ Network cleanup complete!"
}

# -----------------------------------------------------------------------------

# Main logic
case "$1" in
  setup)
    setup_network
    ;;
  cleanup)
    cleanup_network
    ;;
  *)
    echo "Usage: $0 {setup|cleanup}"
    exit 1
    ;;
esac
