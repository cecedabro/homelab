# Homelab architecture

How the cluster is put together and how the pieces depend on each other.
For day-to-day tasks see [operations.md](operations.md); for the history of changes (and how to
undo them) see [changes-2026-10.md](changes-2026-10.md).

## The big picture

```
                    Internet
                       │
        ┌──────────────┴───────────────┐
        │ Cloudflare                   │   public:  jellyfin.cedricschippers.dev
        │  - Tunnel (k3s-homelab)      │            cedricschippers.dev
        │  - DNS for cedricschippers.dev│           hva-portfolio.cedricschippers.dev
        └──────────────┬───────────────┘   (outbound tunnel, no open ports at home)
                       │ cloudflared x2 (namespace cloudflare)
 Home LAN 192.168.50.0/24 ── ASUS RT-AX82U ── 8-port gigabit switch
   │
   ├─ k3s-cp-01      .10  Dell Latitude 3420   control plane + SQLite datastore + NFS server
   │                       └─ USB 4-bay drive caddy, ext4, /mnt/media-storage (3.6 TB)
   ├─ k3s-worker-01  .11  HP EliteDesk 800 G2  general workloads + Longhorn
   ├─ k3s-worker-02  .12  HP EliteDesk 800 G2  general workloads + Longhorn
   ├─ k3s-gpu-01     .13  HP Z400 + GTX 1070   Jellyfin (taint dedicated=gpu) + Longhorn
   ├─ k3s-uwv-01     .14                       kept empty on purpose (taint dedicated=uwv)
   └─ k3s-uwv-02     .15                       kept empty on purpose (taint dedicated=uwv)

 Internal names:  https://<app>.home.cedricschippers.dev  ──►  Traefik 192.168.50.100
 Remote (you):    Tailscale on the nodes (subnet routing)
 Minecraft:       phone ─► mom's Fritz!Box ─► Pi 2 relay ─(Tailscale)─► NodePort  (see apps/minecraft)
```

All nodes run Ubuntu 24.04 and k3s v1.35. The uwv nodes are reserved as a clean practice
environment for the UWV DevOps project; nothing schedules there unless it tolerates
`dedicated=uwv`.

## Layers

### 1. Cluster: k3s
- Single server (`k3s-cp-01`) with the embedded **SQLite** datastore (not etcd). Workers keep
  running their pods if the server is down, but nothing can be changed or rescheduled.
- k3s' built-in **ServiceLB is disabled** (`/etc/rancher/k3s/config.yaml` on cp-01:
  `disable: [servicelb]`), MetalLB hands out LoadBalancer IPs instead.
- k3s' built-in **NetworkPolicy controller** enforces the policies in `apps/network-policies`.
- The datastore is backed up nightly, encrypted, to the NAS (`apps/k3s-backup`).

### 2. Networking
| Piece | Role |
|---|---|
| **MetalLB** (L2) | gives `LoadBalancer` services an IP from 192.168.50.100–200 |
| **Traefik** (k3s bundled) | single HTTPS entry point at **192.168.50.100**, routes by hostname |
| **cert-manager** | gets a Let's Encrypt wildcard cert `*.home.cedricschippers.dev` via DNS-01 on Cloudflare |
| **Cloudflare DNS** | `*.home.cedricschippers.dev → 192.168.50.100` (DNS-only, private IP: works only at home) |
| **Cloudflare Tunnel** | the only way in from the internet; cloudflared dials out |
| **Tailscale** | personal remote access; also carries Minecraft traffic from the Pi relay |
| **NetworkPolicies** | app namespaces only accept traffic from themselves, Traefik, Homepage, monitoring, LAN/Tailscale and the node addresses (plus the tunnel where public) |

Internal HTTPS names (all `https://<name>.home.cedricschippers.dev`):
`home` (Homepage), `jellyfin`, `sonarr`, `radarr`, `prowlarr`, `readarr`, `qbittorrent`,
`grafana`, `prometheus`*, `alertmanager`*, `longhorn`*, `openbao`, `portainer`, `nextcloud`.
\* behind basic auth (secret `dashboard-login` in `monitoring` / `longhorn-system`).

LoadBalancer IPs still in use (legacy, to be phased out in favour of the names above):

| IP | Service | | IP | Service |
|---|---|---|---|---|
| .100 | Traefik | | .108 | Nextcloud |
| .101 | Homepage | | .109 | FlareSolverr |
| .102 | Jellyfin (TV app) | | .110 | Sonarr |
| .103 | Readarr | | .111 | qBittorrent (arr apps use this) |
| .105 | Prowlarr | | .112 | Grafana |
| .106 | Radarr | | .114 | OpenBao UI |

Freed: .104 (Longhorn) and .113 (Prometheus): only reachable through Traefik + login now.

### 3. Storage
| Storage | What lives there | Protection |
|---|---|---|
| **Longhorn** (`longhorn` StorageClass) | app config volumes, databases, OpenBao, Prometheus | 3 replicas across cp-01/worker-01/worker-02/gpu-01; nightly backup to the NAS (7 kept); weekly fstrim |
| **NAS / NFS** `192.168.50.10:/mnt/media-storage` | media (`movies`, `tv`, `books`, `downloads`), Longhorn backups, k3s datastore backups | single ext4 volume on the drive caddy: **no redundancy and no off-site copy yet** |
| `local-path` | Alertmanager, Portainer (node-bound, on worker-01) | none |

NAS layout:
```
/mnt/media-storage
├── movies/      Radarr root folder  → Jellyfin "Movies" library
├── tv/          Sonarr root folder  → Jellyfin "Shows" library
├── books/       Readarr
├── downloads/   qBittorrent (seeding copies; imports are hardlinked, so no double space)
├── longhorn-backups/   Longhorn backup target (exported to the pod network 10.42.0.0/16)
└── k3s-backups/        encrypted k3s datastore backups (root only)
```
Exports (`/etc/exports` on cp-01): the whole share to the LAN and Tailscale, plus
`longhorn-backups` to the pod network (Longhorn mounts it from inside its pods).

### 4. Secrets
```
 OpenBao (namespace openbao, manual Shamir unseal, KV v2 at secret/)
     │  Kubernetes auth, role "external-secrets" (read-only policy)
     ▼
 External Secrets Operator ── ClusterSecretStore "openbao"
     │  ExternalSecret per secret, refresh every hour
     ▼
 normal Kubernetes Secrets ──► apps (env vars / mounted)
```
| OpenBao path | Kubernetes Secret | Used by |
|---|---|---|
| `monitoring/grafana` | `monitoring/grafana-admin` | Grafana admin |
| `media/gluetun-mullvad` | `media/gluetun-mullvad` | VPN sidecar of qBittorrent |
| `media/jellyfin` | `media/jellyfin-api` | Radarr/Sonarr → Jellyfin library scans |
| `hva/portfolio-db-secret` | `hva/portfolio-db-secret` | portfolio Postgres |
| `cloudflare/cloudflared-token` | `cloudflare/cloudflared-token` | tunnel connectors |
| `nextcloud/nextcloud-admin` | `nextcloud/nextcloud-admin` | Nextcloud admin |
| `cert-manager/cloudflare` | `cert-manager/cloudflare-api-token` | DNS-01 challenges (Zone DNS:Edit only) |

Not (yet) in OpenBao: `dashboard-login` / `dashboard-basic-auth` (basic auth),
`k3s-backup-passphrase` (backup encryption key; also keep it in your password manager).
Rule of thumb: **values live in OpenBao, the repo only says where they go.**

### 5. Apps
| Namespace | Apps | Notes |
|---|---|---|
| `media` | Jellyfin, Sonarr, Radarr, Prowlarr, Readarr, qBittorrent (+gluetun VPN), FlareSolverr | all mount the NAS at `/media`; arr apps run as UID 1000 like qBittorrent so imports hardlink |
| `monitoring` | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics | 10 alert rules; no notification channel yet |
| `nextcloud` | Nextcloud | admin from OpenBao |
| `homepage` | Homepage dashboard | status dot per app |
| `openbao`, `external-secrets` | secrets | see above |
| `cert-manager` | certificates | |
| `cloudflare` | cloudflared | plain Deployment, pinned version |
| `hva`, `portfolio` | portfolio site, web app + Postgres | deployed from the portfolio repo |
| `minecraft` | 2× Bedrock server | NetherNet migration pending (see apps/minecraft) |
| `portainer` | Portainer | cluster-admin: guard its password |

### 6. How the media stack clicks together
```
 Prowlarr (indexers, FlareSolverr for Cloudflare-protected ones)
     │ syncs indexers to
     ▼
 Sonarr (TV) / Radarr (movies) ──grab──► qBittorrent (through gluetun → Mullvad VPN)
     ▲                                        │ downloads to /media/downloads
     │ import (hardlink, same filesystem)     │
     └────────────────────────────────────────┘
     │ files land in /media/tv or /media/movies, renamed
     ▼
 "Emby/Jellyfin" connection ──► Jellyfin rescans ──► TV app / browser / public URL
```
Why hardlinks matter: the torrent keeps seeding from `downloads` while Jellyfin reads the
same bytes from `movies`/`tv`, so nothing is stored twice. It only works because every app
mounts the **same** NFS share at the **same** path and runs as the **same** user (1000).

### 7. Self-maintenance (scheduled)
| When | Job | What |
|---|---|---|
| daily 01:30 | `kube-system/k3s-datastore-backup` | encrypted SQLite + token backup to the NAS |
| daily 02:00 | Longhorn `daily-backup` | backup of all volumes except Prometheus to the NAS |
| Sunday 03:00 | Longhorn `weekly-trim` | fstrim all volumes (keeps replicas from growing) |
| daily 04:00 | `kube-system/descheduler` | rebalances pods across worker-01/worker-02 |
| Monday 06:00 | `minecraft/minecraft-restart` | weekly restart of the Minecraft servers |

### 8. Monitoring and alerting
Prometheus scrapes nodes, kube-state-metrics and Longhorn. Alert rules (in
`apps/prometheus/values.yaml`): NodeDown, NodeDiskAlmostFull, NodeMemoryPressure,
NodeLinkNotGigabit, PodCrashLooping, PodNotReady, OpenBaoSealed, PersistentVolumeAlmostFull,
LonghornVolumeDegraded, LonghornNodeDown. They show at
https://alertmanager.home.cedricschippers.dev; **no push notifications yet** (ntfy planned).

## Known weak spots and the plan for them
1. **k3s-cp-01 is a single point of failure** for the control plane and the datastore. The NAS
   data survives a dead laptop (separate drive caddy), but backups on the NAS don't survive a
   dead NAS. Plan: off-site copy to Backblaze B2, and HA control plane (see below).
2. **The NAS volume has no redundancy** if the four drives are spanned/striped into one.
3. **No alert notifications** until ntfy is wired into Alertmanager.
4. **Updates are manual** (Renovate / Flux planned).

### HA control plane (plan, not done)
An extra weak node can serve as a control plane, but **2 control planes is worse than 1**:
HA needs embedded **etcd** with quorum, which requires an odd number of servers (3 tolerates
losing 1; 2 tolerates losing 0 and doubles the ways it can break). Path:
1. Convert cp-01 from SQLite to embedded etcd (`--cluster-init`, one restart of k3s).
2. Join the spare node and one more machine as servers (3 total). The spare node can stay
   tainted `NoSchedule` so it only runs the control plane.
3. Switch the datastore backups to `k3s etcd-snapshot` with `--etcd-snapshot-dir` on the NAS.
4. Put a fixed address in front of the API (kube-vip or a DNS name) so kubeconfigs don't
   point at a single node.
