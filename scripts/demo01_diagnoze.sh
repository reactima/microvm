# A. which namespace are we in?
echo "self netns:"; sudo readlink /proc/$$/ns/net

# B. delete if anything is still called tap0
sudo ip link del tap0 2>/dev/null || true

# C. create the tap, capture errno
set -x
sudo strace -fe ioctl ip tuntap add dev tap0 mode tap
set +x

# D. list again
ip link show | grep tap0 || echo "tap0 not present"

