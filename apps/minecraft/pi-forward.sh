#!/usr/bin/env bash
# Run ON the relay Pi (mom's network) as root: sudo bash pi-forward.sh
# Forwards the public Minecraft NetherNet ports (arriving via the Fritz!Box) over Tailscale to the
# MetalLB addresses in the cluster. Needs the Pi to accept cp-01's subnet route:
#   sudo tailscale set --accept-routes
# Survival: TCP 19132 + UDP 32000-32019            -> 192.168.50.104 (same ports)
# Creative: TCP 19133 -> .113:19132, UDP 32100-32119 -> .113:32000-32019
# Undo: sudo iptables -t nat -F MC-PRE; sudo iptables -t nat -F MC-POST   (or reboot if not persisted)
set -euo pipefail

SURVIVAL=192.168.50.104
CREATIVE=192.168.50.113

echo "Checking the route to the cluster..."
if ! nc -zv -w3 "$SURVIVAL" 19132; then
  echo "Cannot reach $SURVIVAL:19132. Run: sudo tailscale set --accept-routes  (and check cp-01 is online)"
  exit 1
fi

sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-minecraft-forward.conf

# own chains so the script is re-runnable and easy to undo
iptables -t nat -N MC-PRE 2>/dev/null || true
iptables -t nat -N MC-POST 2>/dev/null || true
iptables -t nat -F MC-PRE
iptables -t nat -F MC-POST
iptables -t nat -C PREROUTING -j MC-PRE 2>/dev/null || iptables -t nat -A PREROUTING -j MC-PRE
iptables -t nat -C POSTROUTING -j MC-POST 2>/dev/null || iptables -t nat -A POSTROUTING -j MC-POST

# survival
iptables -t nat -A MC-PRE -p tcp --dport 19132 -j DNAT --to-destination "$SURVIVAL:19132"
for p in $(seq 32000 32019); do
  iptables -t nat -A MC-PRE -p udp --dport "$p" -j DNAT --to-destination "$SURVIVAL:$p"
done

# creative (public port -> internal port, one rule per port so the mapping stays 1:1)
iptables -t nat -A MC-PRE -p tcp --dport 19133 -j DNAT --to-destination "$CREATIVE:19132"
for i in $(seq 0 19); do
  iptables -t nat -A MC-PRE -p udp --dport $((32100 + i)) -j DNAT --to-destination "$CREATIVE:$((32000 + i))"
done

# replies must return through the Pi
iptables -t nat -A MC-POST -d 192.168.50.0/24 -o tailscale0 -j MASQUERADE

# the filter table might drop forwarded packets
iptables -C FORWARD -d 192.168.50.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD -d 192.168.50.0/24 -j ACCEPT
iptables -C FORWARD -s 192.168.50.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD -s 192.168.50.0/24 -j ACCEPT

# persist across reboots
if command -v netfilter-persistent >/dev/null; then
  netfilter-persistent save
else
  echo "Not persistent yet: sudo apt install iptables-persistent && sudo netfilter-persistent save"
fi
echo "Done."
