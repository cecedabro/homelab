# Homelab

Personal Kubernetes homelab running on bare metal hardware.

## Hardware

- **Control plane:** Dell Latitude 3420 (Ubuntu Server 24.04)
- **Worker nodes:** 2x HP EliteDesk 800 G2 i7
- **GPU node (coming):** HP Z400 + GTX 1070
- **Network:** 8-port gigabit switch, ASUS RT-AX82U

## Stack

- **Orchestration:** k3s
- **Package management:** Helm
- **Storage:** Longhorn (WIP)
- **Networking:** MetalLB, Tailscale
- **Monitoring:** Prometheus + Grafana
- **Management:** Portainer, OpenLens

## Services

- Minecraft Bedrock server
- Prometheus + Grafana monitoring

## Access

Remote access via Tailscale with subnet routing.