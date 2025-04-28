#!/bin/bash
# -----------------------------------------------------------------------------
# Firecracker Micro-VM Networking Script
# - Setup WireGuard interface for micro-VM communication
# - Use eBPF for packet routing instead of traditional routing tables
# - Setup bridge and TAP devices for multi-VM networking
# - Cleanup network setup after use
#
# Usage:
#   sudo ./network.sh setup    # to create WireGuard interface + tap devices
#   sudo ./network.sh cleanup  # to remove WireGuard interface + taps
# -----------------------------------------------------------------------------

set -e

# Configurable variables
BRIDGE=fcbr0
HOST_IP=fe80::1    # IPv6 address for the host bridge (use unique subnet)
SUBNET=fe80::/64   # IPv6 subnet for internal network
TAPS=(tapfc10 tapfc11 tapfc12)
WG_INTERFACE=wg0   # WireGuard interface
WG_PRIVATE_KEY=$(wg genkey)  # WireGuard private key
WG_PUBLIC_KEY=$(echo $WG_PRIVATE_KEY | wg pubkey)  # WireGuard public key

# Setup the WireGuard interface and configure it for communication between VMs
setup_wireguard() {
  echo "==> Setting up WireGuard interface $WG_INTERFACE..."

  # Create WireGuard interface
  sudo wg-quick up $WG_INTERFACE

  # Assign IPv6 address to WireGuard interface
  sudo ip -6 addr add $HOST_IP/64 dev $WG_INTERFACE

  # Enable IPv6 forwarding
  sudo sysctl -w net.ipv6.conf.all.forwarding=1

  echo "✅ WireGuard setup complete!"
}

# Setup network bridge and TAP devices
setup_network() {
  echo "==> Creating bridge $BRIDGE..."

  # Check if bridge already exists
  if ! ip link show $BRIDGE &>/dev/null; then
    sudo ip link add name $BRIDGE type bridge
  fi

  sudo ip addr flush dev $BRIDGE
  sudo ip addr add $HOST_IP/64 dev $BRIDGE
  sudo ip link set $BRIDGE up

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

  echo "==> Configuring eBPF for routing..."

  # eBPF setup for packet filtering/routing instead of traditional routing tables
  sudo ip link set $BRIDGE xdp obj /path/to/ebpf_program.o

  echo "✅ Network setup complete!"
}

# Cleanup network configuration
cleanup_network() {
  echo "==> Cleaning up TAP devices..."
  for TAP in "${TAPS[@]}"; do
    if ip link show $TAP &>/dev/null; then
      echo "    Deleting $TAP..."
      sudo ip link del $TAP
    fi
  done

  echo "==> Cleaning up WireGuard interface..."
  sudo wg-quick down $WG_INTERFACE

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
    setup_wireguard
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
