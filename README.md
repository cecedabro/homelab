# Homelab

Personal Kubernetes homelab on bare-metal hardware: a k3s cluster that runs a media stack,
Nextcloud, monitoring, a portfolio site and Minecraft, with secrets in OpenBao and internal
HTTPS on `*.home.cedricschippers.dev`.

**Start here:**
- [docs/architecture.md](docs/architecture.md): how everything fits together (network, storage, secrets, apps)
- [docs/operations.md](docs/operations.md): runbook (unseal, restarts, backups, adding apps/nodes)
- [docs/changes-2026-10.md](docs/changes-2026-10.md): the October 2026 hardening pass, with undo steps

## Hardware
| Node | Machine | Role |
|---|---|---|
| k3s-cp-01 | Dell Latitude 3420 + USB 4-bay drive caddy | control plane, NFS server (media + backups) |
| k3s-worker-01/02 | HP EliteDesk 800 G2 (i7) | workloads, Longhorn storage |
| k3s-gpu-01 | HP Z400 + GTX 1070 | Jellyfin transcoding, Longhorn storage |
| k3s-uwv-01/02 | – | kept empty for the UWV DevOps project |

Network: ASUS RT-AX82U + 8-port gigabit switch. Remote access: Tailscale.

## Stack
| Layer | Tools |
|---|---|
| Cluster | k3s (SQLite datastore), Helm |
| Networking | MetalLB, Traefik, cert-manager (Let's Encrypt DNS-01), Cloudflare Tunnel, Tailscale, NetworkPolicies |
| Storage | Longhorn (3 replicas, nightly backups to the NAS), NFS for media |
| Secrets | OpenBao + External Secrets Operator |
| Monitoring | Prometheus, Alertmanager, Grafana, Homepage |
| Housekeeping | descheduler, Longhorn trim/backup jobs, encrypted k3s datastore backups |
| Management | Portainer, OpenLens |

## Services
Media (Jellyfin, Sonarr, Radarr, Prowlarr, Readarr, qBittorrent behind a Mullvad VPN,
FlareSolverr), Nextcloud, Grafana/Prometheus, Homepage, OpenBao, Portainer, the portfolio site
and two Minecraft Bedrock servers (via a relay, see `apps/minecraft/minecraft-bedrock-relay.md`).

## Repo layout
`apps/<name>/` holds the Helm values or manifests for each app (applied by hand with
`helm upgrade` / `kubectl apply`; the command is at the top of most files). No secret values are
stored here: ExternalSecrets reference OpenBao paths instead.
