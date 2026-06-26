# Minecraft Bedrock Server — Relay & Pong Fix

## Overview

This document covers the full architecture of the Minecraft Bedrock server setup running in the k3s homelab, the BDS RakNet bug encountered in versions 1.26.30.5 and 1.26.31.1, and the workaround implemented in the Pi 2 UDP relay to fix connectivity without waiting for Mojang to patch the server binary.

---

## Architecture

```
Phone (Minecraft Bedrock v26.31)
        │
        │ UDP 19132
        ▼
Mom's Fritz!Box (public IP: 92.109.226.18)
  Port forward: UDP 19132 → 192.168.178.85
        │
        │ UDP 19132
        ▼
Pi 2 at mom's house
  Local IP:     192.168.178.85
  Tailscale IP: 100.81.60.13
  Script:       /usr/local/bin/udp-proxy.py
  Service:      minecraft-relay (systemd)
        │
        │ UDP via Tailscale → 100.113.240.94:30000
        ▼
k3s-worker-01
  Local IP:     192.168.50.11
  Tailscale IP: 100.113.240.94
  NodePort:     30000 → 19132
        │
        │ Kubernetes NodePort
        ▼
Minecraft Bedrock Pod (namespace: minecraft)
  Chart:    itzg/minecraft-bedrock v2.9.0
  Node:     k3s-worker-01
  Storage:  Longhorn PVC
```

The Pi 2 relay exists because Tailscale subnet routing doesn't support UDP hole-punching for external devices (the phone). The Fritz!Box forwards incoming UDP traffic from the public internet to the Pi, which then proxies it over Tailscale to the k3s NodePort.

---

## The Bug — BDS RakNet Truncated Pong

### Background: How Minecraft Bedrock finds a server

Before a Minecraft client attempts a full connection, it performs a **status check** using the RakNet protocol:

1. Client sends an **Unconnected Ping** (33 bytes) to the server
2. Server responds with an **Unconnected Pong** (~150 bytes) containing server metadata
3. Client parses the pong, displays the server as online in the server list
4. Only then, when the user taps the server, does an actual connection attempt begin

If the pong is malformed, the client never progresses to step 4. The server appears offline or times out.

### What RakNet is

Minecraft Bedrock uses **UDP** rather than TCP for its network transport. UDP is faster but unreliable — packets can be lost, arrive out of order, or arrive duplicated. **RakNet** is a library layered on top of UDP that adds reliability, ordering, and connection management while keeping the low-latency characteristics of UDP.

### The pong packet format

A correct Unconnected Pong packet has this structure:

```
0x1c                     — 1 byte:  packet type identifier
timestamp                — 8 bytes: big-endian uint64, echoed from the ping
server GUID              — 8 bytes: big-endian uint64, unique server ID
magic                    — 16 bytes: always 00ffff00fefefefefdfdfdfd12345678
string length            — 2 bytes: big-endian uint16, byte length of string below
Server ID String         — variable: semicolon-separated metadata string
```

The Server ID String format:
```
MCPE;<server name>;<protocol version>;<game version>;<players>;<max players>;<server GUID>;<world name>;<gamemode>;<gamemode numeric>;<IPv4 port>;<IPv6 port>;
```

Example:
```
MCPE;Cedrics Server;1001;1.26.31;0;20;13253860892328930865;Bedrock level;Survival;1;19132;19133;
```

A healthy pong is ~150 bytes because it carries all of the above.

### The bug

BDS versions **1.26.30.5** and **1.26.31.1** introduced a regression in the code that builds the Server ID String payload. The server sends a pong that contains only the RakNet framing fields (type byte + timestamp + GUID + magic) but writes zero bytes for the string length and string body.

This produces a **33-byte pong** — exactly the size of the framing alone with no payload.

Confirmed via tcpdump on k3s-worker-01:
```
tailscale0 In  ... pi2 > k3s-worker-01:30000: UDP, length 33   ← phone's ping
tailscale0 Out ... k3s-worker-01:30000 > pi2: UDP, length 33   ← broken BDS pong
```

The client receives the 33-byte pong, finds no Server ID String, and cannot display or connect to the server.

### Why it's definitely BDS and not our config

The tcpdump intercepts traffic at the NodePort on k3s-worker-01, which is inside the cluster and past all networking layers (Tailscale, NAT, port forwarding, Python proxy). The 33-byte response originates from the BDS process itself. If the issue were network-related, we would see no response at all — not a consistently sized broken one.

Others confirmed the same issue on fresh installs across multiple machines:
> "It appears to boot correctly, but then fails on mc-monitor readiness probe: `ping raknet: read unconnected pong: unexpected EOF`. I have multiple MC servers all with the same issue... Multiple different machines same problem." — itzg/docker-minecraft-bedrock-server issue #649

### What Mojang fixed (and didn't)

The 26.31 hotfix changelog lists MCPE-239705 as "Fixed an issue causing slower server connectivity issues." This was a **client-side** tolerance patch — the official Minecraft app was made more lenient about malformed pongs in certain scenarios. The BDS binary itself was not fixed. As of BDS 1.26.31.1 the server still emits 33-byte pongs, confirmed by tcpdump.

---

## The Fix — Pong Injection in the UDP Proxy

Since the Pi relay already sits between the phone and the cluster and handles every packet, it's the natural place to intercept the broken pong and replace it with a correctly built one.

### How it works

1. Detect incoming ping packets from the phone (start with `0x01` or `0x02`, 33 bytes)
2. Store the ping's timestamp (bytes 1–9) so it can be echoed back
3. When BDS returns a broken 33-byte pong (starts with `0x1c`, exactly 33 bytes), discard it
4. Build a correct pong using the stored timestamp and hardcoded server metadata
5. Send the correct pong back to the phone
6. All subsequent actual game traffic passes through unmodified

The phone receives a valid pong, displays the server, and the full connection handshake proceeds normally.

### Protocol version

The protocol version in the Server ID String must match the client exactly or the client rejects the server as outdated. As of Bedrock Edition 26.31, the protocol version is **1001**.

---

## The Script — `/usr/local/bin/udp-proxy.py`

```python
#!/usr/bin/env python3
import socket
import threading
import struct

LOCAL_HOST = '0.0.0.0'
LOCAL_PORT = 19132
REMOTE_HOST = '100.113.240.94'  # k3s-worker-01 Tailscale IP
REMOTE_PORT = 30000             # Kubernetes NodePort

# RakNet magic bytes — always this exact 16-byte sequence in unconnected packets
RAKNET_MAGIC = bytes([
    0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
    0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78
])

SERVER_GUID = 13253860892328930865
SERVER_ID_STRING = "MCPE;Cedrics Server;1001;1.26.31;0;20;13253860892328930865;Bedrock level;Survival;1;19132;19133;"

def build_pong(ping_data):
    # Extract the timestamp from the ping packet (bytes 1-9, big-endian uint64)
    timestamp = struct.unpack_from('>Q', ping_data, 1)[0]

    server_id_bytes = SERVER_ID_STRING.encode('utf-8')
    string_length = len(server_id_bytes)

    # Build the pong packet per RakNet spec:
    # 0x1c | timestamp (8) | server GUID (8) | magic (16) | string length (2) | string
    pong = struct.pack('>B', 0x1c)
    pong += struct.pack('>Q', timestamp)
    pong += struct.pack('>Q', SERVER_GUID)
    pong += RAKNET_MAGIC
    pong += struct.pack('>H', string_length)
    pong += server_id_bytes

    return pong

def is_unconnected_ping(data):
    # Unconnected ping: starts with 0x01 or 0x02
    if len(data) < 1:
        return False
    return data[0] in (0x01, 0x02)

def is_broken_pong(data):
    # BDS broken pong: starts with 0x1c and is exactly 33 bytes (no payload)
    return len(data) == 33 and data[0] == 0x1c

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind((LOCAL_HOST, LOCAL_PORT))
    print(f"Listening on {LOCAL_HOST}:{LOCAL_PORT}")
    print(f"Forwarding to {REMOTE_HOST}:{REMOTE_PORT}")
    print("Pong repair active — intercepting broken BDS responses")

    clients = {}
    last_ping = {}  # store last ping per client to echo timestamp in pong

    while True:
        data, addr = server.recvfrom(65535)

        if is_unconnected_ping(data):
            last_ping[addr] = data

        if addr not in clients:
            client_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            client_sock.connect((REMOTE_HOST, REMOTE_PORT))
            clients[addr] = client_sock

            def forward_back(sock, client_addr):
                while True:
                    try:
                        response = sock.recv(65535)

                        if is_broken_pong(response):
                            ping_data = last_ping.get(client_addr)
                            if ping_data:
                                response = build_pong(ping_data)
                                print(f"Replaced broken pong for {client_addr} ({len(response)} bytes)")

                        server.sendto(response, client_addr)
                    except:
                        break

            t = threading.Thread(target=forward_back, args=(client_sock, addr), daemon=True)
            t.start()

        clients[addr].send(data)

if __name__ == '__main__':
    main()
```

### Updating the script when BDS is fixed

When Mojang ships a fixed BDS binary, the pong injection will no longer be needed but will not cause harm — the `is_broken_pong` check will simply never trigger because BDS will return pongs larger than 33 bytes. To confirm BDS is fixed:

```bash
# On k3s-worker-01 while phone tries to connect:
sudo tcpdump -i any udp port 30000

# If Out packets are > 33 bytes, BDS is fixed.
# You can then simplify the script back to plain forwarding.
```

### Updating protocol version

When Minecraft updates its protocol version, the `SERVER_ID_STRING` in the script must be updated to match. The current protocol version for Bedrock 26.31 is **1001**. Check the current version at:
`https://minecraft.wiki/w/Protocol_version`

---

## Kubernetes Setup

### Helm release

```
Release name:  minecraft-bedrock
Chart:         itzg/minecraft-bedrock v2.9.0
Namespace:     minecraft
```

### values.yaml

```yaml
minecraftServer:
  eula: true
  serverName: "Cedrics Server"
  difficulty: normal
  maxPlayers: 20
  gameMode: survival
  levelSeed: ""
  onlineMode: true
  serviceType: NodePort
  nodePort: 30000
  extraEnv:
    VERSION: "LATEST"
    ALLOW_LIST: "false"

nodeSelector:
  kubernetes.io/hostname: k3s-worker-01

resources:
  requests:
    memory: 1Gi
    cpu: 500m
  limits:
    memory: 2Gi
    cpu: 2000m

persistence:
  storageClass: longhorn
  dataDir:
    enabled: true

startupProbe:
  enabled: false

livenessProbe:
  initialDelaySeconds: 30

readinessProbe:
  initialDelaySeconds: 30
```

### Upgrade procedure

The chart's liveness and readiness probes use `mc-monitor status-bedrock` which sends a RakNet ping internally. While BDS returns broken 33-byte pongs, this probe always fails and Kubernetes kills the pod. The chart does not expose an `enabled: false` option for these probes, so they must be patched out after every helm upgrade.

```bash
cd ~/homelab

# 1. Apply updated values
helm upgrade minecraft-bedrock itzg/minecraft-bedrock \
  --namespace minecraft \
  -f apps/minecraft/values.yaml

# 2. Remove broken probes (must run after every helm upgrade)
kubectl patch deployment minecraft-bedrock-minecraft-bedrock -n minecraft --type='json' -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}
]'

# 3. Watch pod come up
kubectl get pods -n minecraft -w
```

This is also saved as `apps/minecraft/upgrade.sh`.

### Scale up / down

```bash
# Up
kubectl scale deployment minecraft-bedrock-minecraft-bedrock -n minecraft --replicas=1

# Down (saves resources when not in use)
kubectl scale deployment minecraft-bedrock-minecraft-bedrock -n minecraft --replicas=0
```

---

## Pi 2 Relay — Systemd Service

File: `/etc/systemd/system/minecraft-relay.service`

```ini
[Unit]
Description=Minecraft Bedrock UDP Relay to Homelab
After=network.target tailscaled.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/udp-proxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Relay commands

```bash
# Status
sudo systemctl status minecraft-relay

# Restart (clears accumulated dead threads)
sudo systemctl restart minecraft-relay

# Watch live logs
sudo journalctl -u minecraft-relay -f
```

---

## Debugging Reference

### Check if packets are reaching the cluster

```bash
# On k3s-worker-01 while phone tries to connect:
ssh cedric@192.168.50.11
sudo tcpdump -i any udp port 30000

# Healthy (pong fix working):
#   In  ... length 33   ← phone ping
#   Out ... length ~150 ← our injected pong
#
# Broken (BDS not fixed, pong injection not running):
#   In  ... length 33   ← phone ping
#   Out ... length 33   ← broken BDS pong
```

### Check relay logs on Pi

```bash
ssh cedric@100.81.60.13
sudo journalctl -u minecraft-relay -f
# Should show: "Replaced broken pong for ..." when phone connects
```

### Check pod is running

```bash
kubectl get pods -n minecraft
kubectl logs -n minecraft deployment/minecraft-bedrock-minecraft-bedrock | grep -i version
```

### Full chain test from Pi

```bash
ssh cedric@100.81.60.13
# Test NodePort reachable
sudo nmap -sU -p 30000 100.113.240.94
# open|filtered = healthy, closed = pod not running or NodePort broken

# Watch incoming traffic from phone
sudo tcpdump -i eth0 udp port 19132
```

---

## Known Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `helm upgrade` breaks LoadBalancer | Helm conflict on svc type | Uninstall + reinstall + `kubectl patch svc` |
| Probes kill pod after ~58s | mc-monitor fails on broken pong | `kubectl patch` to remove probes after every upgrade |
| BDS sends 33-byte pong | Mojang regression in 1.26.30+ | Pi relay injects correct pong (this document) |
| Protocol version mismatch | Client updated, script not | Update `SERVER_ID_STRING` in `udp-proxy.py` |
| Relay accumulates dead threads | Python UDP proxy threading | `sudo systemctl restart minecraft-relay` periodically |

---

## Status

| Component | Status |
|-----------|--------|
| Pod running | ✅ |
| NodePort reachable | ✅ |
| Tailscale relay (Pi → cluster) | ✅ |
| Fritz!Box port forward | ✅ |
| Pong injection workaround | ✅ |
| BDS upstream bug fixed | ❌ (monitor `https://bugs.mojang.com/projects/BDS/issues`) |
