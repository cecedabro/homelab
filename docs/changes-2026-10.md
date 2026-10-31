# Changes of 12–13 October 2026 (and how to undo them)

A hardening and clean-up pass over the whole cluster. Each entry: what changed, where, and how
to revert. Commits are on `main`; `git log --oneline` shows them in order. "Live only" means the
change was made in the cluster and is not (fully) expressed in this repo.

## Cluster and nodes
| Change | Where | Undo |
|---|---|---|
| k3s ServiceLB disabled (MetalLB does all LoadBalancer IPs) | on k3s-cp-01: `/etc/rancher/k3s/config.yaml` = `disable: [servicelb]` | remove the file/line, `sudo systemctl restart k3s` |
| multipathd blacklist for Longhorn devices on worker-02 (fixed "mount point busy") | on k3s-worker-02: `/etc/multipath.conf` | delete the `blacklist {}` block, restart multipathd (not recommended) |
| NAS uplink fixed: cp-01 moved to a gigabit port (was 100 Mbit/s) | hardware | – |
| Leftover `prometheus-operator` (default ns) + its 10 `monitoring.coreos.com` CRDs removed | live | reinstall from prometheus-operator bundle (nothing used it) |
| Descheduler (nightly rebalance, system namespaces + openbao excluded) | `apps/descheduler/values.yaml` | `helm -n kube-system uninstall descheduler` |
| Resource requests/limits on all app workloads | values/manifests per app | remove the `resources:` blocks, redeploy |
| Image pins: FlareSolverr v3.5.2, Minecraft, gluetun (by digest) | `apps/flaresolverr`, `apps/minecraft`, `apps/qbittorrent` | change back to `:latest` |

## Storage and backups
| Change | Where | Undo |
|---|---|---|
| Longhorn: pods move off a dead node; drain waits for replica eviction | live `settings.longhorn.io` (recorded in `apps/longhorn/values.yaml`) | `kubectl -n longhorn-system patch settings.longhorn.io node-down-pod-deletion-policy --type=merge -p '{"value":"do-nothing"}'` (and `node-drain-policy` → `block-if-contains-last-replica`) |
| Prometheus volume: old system snapshot removed + trimmed (20 GB → 10 GB) | live | – |
| Weekly fstrim job | `apps/longhorn/recurring-trim.yaml` | `kubectl delete -f` it |
| Prometheus volume in group `metrics` (no backups, still trimmed) | live label on the volume | `kubectl -n longhorn-system label volumes.longhorn.io pvc-5e0e47f7-10f3-4bc2-acb7-9f5dd72a26fa recurring-job-group.longhorn.io/metrics-` |
| Backup target `nfs://192.168.50.10:/mnt/media-storage/longhorn-backups` | live `backuptargets.longhorn.io/default` | set `spec.backupTargetURL` to `""` |
| NFS export of `longhorn-backups` to the pod network | on cp-01: `/etc/exports` (last line) + `exportfs -ra` | remove the line, `sudo exportfs -ra` |
| Daily Longhorn backup (02:00, keep 7) | `apps/longhorn/recurring-backup.yaml` | `kubectl delete -f` it |
| Encrypted nightly k3s datastore backup to `/mnt/media-storage/k3s-backups` | `apps/k3s-backup/cronjob.yaml`, secret `kube-system/k3s-backup-passphrase` (live only) | `kubectl delete -f` it; delete the secret |

## Networking and access
| Change | Where | Undo |
|---|---|---|
| IP conflicts fixed: Grafana → .112, Longhorn UI → .104 (later removed), Readarr pinned to .103 | values files | – |
| Homepage/Jellyfin/Prowlarr services declared as LoadBalancer in values (were hand-patched) | values files | – |
| Prometheus exposed on .113 (later removed again) | `apps/prometheus/values.yaml` | – |
| **cert-manager** + Let's Encrypt ClusterIssuers (DNS-01 on Cloudflare) | `apps/cert-manager/` (installed with `--no-hooks`) | `kubectl delete -f apps/cert-manager/clusterissuers.yaml`; `helm -n cert-manager uninstall cert-manager` |
| Wildcard cert `*.home.cedricschippers.dev` as Traefik default | `apps/traefik/home-certificate.yaml` | `kubectl delete -f` it |
| DNS records `*.home` and `home` → 192.168.50.100 (DNS only) | Cloudflare dashboard (live only) | delete both A records in Cloudflare |
| Ingresses for every UI + basic auth for Longhorn/Prometheus/Alertmanager | `apps/traefik/ingresses.yaml`; secrets `dashboard-basic-auth`/`dashboard-login` (live only) | `kubectl delete -f apps/traefik/ingresses.yaml` |
| Prometheus and Longhorn UI moved to ClusterIP (IPs .113/.104 freed) | `apps/prometheus/values.yaml`; Longhorn svc patched live (recorded in `apps/longhorn/values.yaml`) | set the type back to `LoadBalancer` with the `metallb.io/loadBalancerIPs` annotation |
| Nextcloud trusts the pod network as proxy, no fixed `overwriteprotocol` | `apps/nextcloud/values.yaml` | restore `'overwriteprotocol' => 'http'`, remove `trusted_proxies` |
| NetworkPolicies: portfolio DB, OpenBao, and ingress isolation per app namespace | `apps/hva/networkpolicy-portfolio-db.yaml`, `apps/openbao/networkpolicy.yaml`, `apps/network-policies/` | `kubectl delete -f` the file(s) |
| Cloudflare tunnel: Helm chart replaced by a plain Deployment; token rotated | `apps/cloudflare/`; old release uninstalled | (the old token is invalid, so no way back to it) |

## Secrets
| Change | Where | Undo |
|---|---|---|
| OpenBao (manual unseal) + External Secrets Operator | `apps/openbao/`, `apps/external-secrets/` | – (secrets would have to be recreated by hand) |
| 7 secrets moved to OpenBao (see architecture.md § Secrets) | `apps/*/externalsecret*.yaml` | delete the ExternalSecret with `--cascade=orphan`: the Secret stays as a normal Secret |
| Grafana admin password changed (was the placeholder) | OpenBao `monitoring/grafana` | – |
| Nextcloud admin password rotated (old one leaked via git history) | OpenBao `nextcloud/nextcloud-admin` v2 | – |
| Git history rewritten: old Nextcloud password and relay IP removed from all commits; force-pushed | GitHub `main` | backup mirror existed only in a temp folder (gone); old clones must re-clone |

## Media stack
| Change | Undo |
|---|---|
| Radarr/Sonarr/Readarr run as UID 1000 (`podSecurityContext`) so imports hardlink instead of copy | remove `podSecurityContext` from their values |
| 37 untracked downloads imported (moved) into `/media/movies`; subtitles and extras moved next to them; leftover junk, 2 duplicates, a fake `.exe` and Obsession's extra dub tracks deleted | – (deleted files are gone) |
| Radarr: "On the Silver Globe" added; 4 movies without files removed from the list | re-add in Radarr |
| Sonarr: broken S01E01 (6% download) deleted and unmonitored | re-monitor in Sonarr |
| Radarr/Sonarr: import extra files (`srt,ass,ssa,sub,idx`) on | Settings → Media Management |
| Radarr/Sonarr → Jellyfin connection (library scan after import) | Settings → Connect → delete "Jellyfin" |
| Jellyfin Movies library path `/media` → `/media/movies` (done in the Jellyfin UI) | Jellyfin → Libraries |

## Monitoring
| Change | Undo |
|---|---|
| Grafana: Prometheus datasource provisioned | remove `datasources:` from `apps/grafana/values.yaml` |
| Alertmanager → ntfy (Secret `monitoring/alertmanager-ntfy`, live only) | remove `alertmanager.config`/`extraSecretMounts` from `apps/prometheus/values.yaml` |
| 10 alert rules + Longhorn metrics scrape | remove `serverFiles:` / `extraScrapeConfigs:` from `apps/prometheus/values.yaml` |

## Minecraft (stopgap, still to be finished)
Bedrock 1.26.52 only supports the NetherNet transport. Live only: `transport=nethernet` in both
servers' `server.properties`, and both Deployments patched to TCP probes on 19132. A plain
`helm upgrade` reverts the probes. The network path (NodePort, Pi relay, Fritz!Box) still has to
be redesigned for TCP 19132 + a UDP range.

## GitOps (Flux + Renovate)
| Change | Where | Undo |
|---|---|---|
| Flux v2.9.5 installed, syncing `clusters/homelab` from GitHub | `clusters/homelab/` | see below |
| 45 plain manifests applied by Flux (`prune: false`) | `apps/kustomization.yaml` | remove the file from the list (object stays) |
| 14 Helm releases adopted as HelmReleases (no restarts) | `apps/flux/` | see below |
| Renovate config | `renovate.json` (+ the Renovate GitHub App, installed by hand) | delete the file / uninstall the app |

**Removing Flux without losing apps**: HelmReleases and Kustomizations have finalizers; deleting
Flux's CRDs while they exist makes helm-controller *uninstall* the releases. So first:
```bash
kubectl -n flux-system patch kustomization apps flux-system --type merge -p '{"spec":{"suspend":true}}'
for r in $(kubectl -n flux-system get helmrelease -o name); do kubectl -n flux-system patch $r --type merge -p '{"spec":{"suspend":true}}'; kubectl -n flux-system patch $r --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'; done
for k in apps flux-system; do kubectl -n flux-system patch kustomization $k --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'; done
kubectl delete -f clusters/homelab/flux-system/gotk-components.yaml
```
The Helm releases, their pods and all manifests stay; you're back to `helm upgrade` by hand.

## Ruilingen (13 Oct)
| Change | Where | Undo |
|---|---|---|
| Ruilingen app: namespace, PVC, Deployment, ExternalSecret, NetworkPolicy | `apps/ruilingen/`, `apps/network-policies/ruilingen.yaml` | remove from `apps/kustomization.yaml` and delete the namespace (prune is off) |
| Flux image automation (follows `main-<timestamp>-<sha>` builds) | `apps/flux/image-automation.yaml` | remove it from `apps/kustomization.yaml`; delete the objects |
| Write deploy key "flux-image-automation (k3s homelab)" on GitHub + Secret `flux-system/homelab-git-write` | GitHub repo settings → Deploy keys; live Secret | delete the deploy key on GitHub and the Secret |

## 14 Oct: off-site backups, secrets, upgrades, Longhorn/MetalLB under Flux
| Change | Where | Undo |
|---|---|---|
| Off-site backup to Backblaze B2 (rclone crypt), nightly 05:00 | `apps/backup-offsite/` | remove from `apps/kustomization.yaml`, delete the CronJob |
| Alerts BackupJobFailed, OffsiteBackupStale | `apps/prometheus/values.yaml` | remove the two rules |
| ntfy URLs, dashboard login (ESO now generates a bcrypt htpasswd), k3s backup passphrase moved to OpenBao | `apps/prometheus/externalsecret-ntfy.yaml`, `apps/traefik/externalsecret-basic-auth-*.yaml`, `apps/k3s-backup/externalsecret.yaml` | delete the ExternalSecret with `--cascade=orphan` (the Secret stays) |
| system-upgrade-controller v0.20.2 + k3s Plans (opt-in per node label) + Renovate k3s manager | `apps/system-upgrade/`, `renovate.json` | remove from `apps/kustomization.yaml`, delete namespace `system-upgrade` |
| unattended-upgrades on every node (security updates, no auto reboot) | on the nodes | `sudo apt remove unattended-upgrades` |
| MetalLB and Longhorn adopted as Flux HelmReleases (no restarts), MetalLB pool in git | `apps/flux/helmreleases.yaml`, `apps/metallb/` | see "Removing Flux without losing apps" above |
| Jellyfin only mounts the NAS folders `movies` and `tv` (was: the whole NAS, incl. downloads and backups) | `apps/jellyfin/values.yaml` (`persistence.media.enabled: false` + `volumes`/`volumeMounts`) | restore `persistence.media` with `existingClaim: nfs-media`. Note: changing the type of the `media` volume needs the Deployment deleted once (`kubectl -n media delete deploy jellyfin`), Flux recreates it; a server-side merge can't change a volume's type |

## 15 Oct: Open WebUI
| Change | Where | Undo |
|---|---|---|
| Open WebUI (HelmRelease, namespace, PVC 5 Gi, LB 192.168.50.107, Ingress `chat.home.cedricschippers.dev`, NetworkPolicy) | `apps/open-webui/`, `apps/traefik/ingresses.yaml`, `apps/network-policies/open-webui.yaml`, `apps/flux/helmreleases.yaml` | remove from `apps/kustomization.yaml` + the HelmRelease; delete namespace `open-webui` (prune is off) |
| Secret `open-webui-secret` (random, live only) | namespace `open-webui` | `kubectl -n open-webui delete secret open-webui-secret` |
| Homepage tile (group AI) | `apps/homepage/values.yaml` | remove the tile |

## 15 Oct: Jellyfin as non-root
| Change | Where | Undo |
|---|---|---|
| Jellyfin runs as UID/GID 1000, capabilities dropped, fsGroup 1000 (was root) | `apps/jellyfin/values.yaml` (`podSecurityContext`, `securityContext`) | remove both blocks |
| All files/folders under `movies` and `tv` chowned to 1000:1000 (34 entries were `nobody`, 8 root; the arr apps run as 1000 and couldn't modify the `nobody` ones) | on the NAS, one-off | ownership only, nothing to undo |
Tested: writes in movies/tv/config/cache, NVENC encode and a full 4K HEVC GPU pipeline (decode, scale_cuda, h264_nvenc) as UID 1000.

## 19 Oct: Seerr
| Change | Where | Undo |
|---|---|---|
| Seerr (official OCI chart 3.10.0, app v3.5.0) in `media`, 1 Gi Longhorn volume, ingress `seerr.home.cedricschippers.dev`, Homepage tile | `apps/seerr/`, `apps/flux/*`, `apps/traefik/ingresses.yaml`, `apps/homepage/values.yaml` | remove the HelmRelease + values ConfigMap + ingress host + tile; `kubectl -n media delete pvc seerr-config` if the data should go too |
| Wizard in the browser (Jellyfin login, Radarr/Sonarr connections with their API keys) | live, stored in Seerr's own volume | re-run via Settings |

## 19 Oct: Minecraft NetherNet on the LAN (step A)
| Change | Where | Undo |
|---|---|---|
| Per-server MetalLB IPs (survival 192.168.50.104, creative .113) with TCP 19132 + UDP 32000-32019, externalTrafficPolicy Local | `apps/minecraft/service-nethernet.yaml` | remove from `apps/kustomization.yaml`, delete the two Services |
| `server-udp-ports=<LAN ip>:32000-32019:32000-32019` in each server's `/data/server.properties` (live, on the volume) | live only | delete the line and restart the server |
Verified: a real client connected and spawned on the survival server over the LAN (TCP handshake, then UDP port 32000). Internet access (Pi relay + Fritz!Box) is still the old RakNet path and does not work.

## 19-26 Oct: Minecraft over the internet (step B), backup limit
| Change | Where | Undo |
|---|---|---|
| NetherNet Services use `externalTrafficPolicy: Cluster` (with Local, kube-proxy on cp-01, the Tailscale subnet router, dropped packets the Pi forwarded to the LB IPs) | `apps/minecraft/service-nethernet.yaml` | set back to Local (breaks the Pi path) |
| Pi relay forwards the public ports over Tailscale: survival TCP 19132 + UDP 32000-32019 -> .104; creative TCP 19133 -> .113:19132 and UDP 32100-32119 -> .113:32000-32019 (iptables chains MC-PRE/MC-POST on the Pi) | `apps/minecraft/pi-forward.sh` (run by hand on the Pi) | `sudo iptables -t nat -F MC-PRE; sudo iptables -t nat -F MC-POST` |
| Fritz!Box port forwards to the Pi: TCP 19132, 19133; UDP 32000-32019, 32100-32119 | router UI | delete the four rules |
| Public address added as a second entry in `server-udp-ports` (live only, never in git) | each server's `/data/server.properties` | remove the entry, restart |
| Off-site backup `rclone --max-delete` 1000 -> 10000 (Longhorn's 7-day retention prunes ~2000 block files in one go; the first rotation failed the job on 21 Oct) | `apps/backup-offsite/cronjob.yaml` | set back to 1000 |

## 27 Oct: Bazarr (subtitles)
| Change | Where | Undo |
|---|---|---|
| Bazarr 1.6.2 in `media` (Deployment, 1 Gi Longhorn volume `bazarr-config`, ClusterIP), ingress `bazarr.home.cedricschippers.dev`, Homepage tile | `apps/bazarr/`, `apps/kustomization.yaml`, `apps/traefik/ingresses.yaml`, `apps/homepage/values.yaml` | see `apps/bazarr/README.md` |
| Setup in the browser: login, English language profile, OpenSubtitles account, Sonarr/Radarr connections | live, in Bazarr's volume | re-run via Settings |

## 31 Oct: Local AI agent (cluster side)
| Change | Where | Undo |
|---|---|---|
| Namespaces `ai-agent` (restricted) and `ai-waker` (privileged), devbox StatefulSet (replicas 0 until image + secrets exist; 30 Gi Longhorn, excluded from the nightly backup), NetworkPolicy, waker Deployment (replicas 0 until the PC's MAC is in OpenBao), ExternalSecrets from `secret/ai-agent/*` | `apps/ai-agent/`, `apps/kustomization.yaml` | see `apps/ai-agent/README.md` |
| New repo github.com/cecedabro/local-ai-agent (public since 31 Oct; the GHCR image package is still private until switched by hand) (PC scripts, devbox image, harness); its own `k8s/` folder moved here (OpenBao instead of SOPS, ntfy.sh instead of in-cluster ntfy, waker binds to the node's LAN IP) | GitHub | archive/delete the repo |
| Devbox points at the PC: `PC_HOST` 192.168.50.17, `PC_SSH_USER` cedric, `LLAMA_BASE_URL` http://192.168.50.17:8080/v1; NetworkPolicy allows 192.168.50.17 on 8080/2222 (router DHCP reservation for the PC still to do) | `apps/ai-agent/devbox.yaml` | empty the three values, remove the egress rule |

## 31 Oct: AI PC set up (remotely, over SSH from the Mac)
| Change | Where | Undo |
|---|---|---|
| OpenSSH server on Windows, key-only (`~/.ssh/pc-desktop` on the Mac), firewall Tailscale-only (100.64.0.0/10), PowerShell as shell | PC | `Stop-Service sshd; Set-Service sshd -StartupType Disabled`, or delete the key from `C:\ProgramData\ssh\administrators_authorized_keys` |
| Ollama uninstalled, models (7.5 GB) and `OLLAMA_HOST` removed. Open WebUI's Ollama URL (100.93.62.83:11434) is now dead | PC | `winget install Ollama.Ollama` |
| WSL Ubuntu moved to `F:\WSL\Ubuntu` (NVMe), `.wslconfig` 26 GB RAM / 8 GB swap, NAT; hostname `ai-pc` | PC | `wsl --manage Ubuntu --move <dir>`; `.wslconfig` |
| NVIDIA driver 560.94 -> 621.01 (display driver only, via pnputil) | PC | Device Manager -> roll back driver |
| CUDA 13.3 toolkit, llama.cpp v0.8.0 (sm_86), Qwen3.6-35B-A3B UD-Q4_K_XL, `llama-server` systemd unit (alias `coder`, API key in `/etc/llama/api-key`, N_CPU_MOE 26: ~36 tok/s), sshd on 2222 (no keys yet) | WSL | `systemctl disable --now llama-server ssh` |
| Boot task `ai-power` (S4U, elevated): keeps WSL up, portproxy 8080/2222 -> WSL; firewall rule `ai-wsl-in` (LAN only); hibernate off, sleep after 20 min; NIC wake on pattern off (magic packet only) | PC | `Unregister-ScheduledTask ai-power; netsh interface portproxy reset; Remove-NetFirewallRule -Name ai-wsl-in` |
| Longhorn `storageOverProvisioningPercentage` 100 -> 150: the 30 GiB devbox volume could not place a single replica (scheduling counts full volume sizes plus the 30% reserve; disks were ~25% used) | `apps/longhorn/values.yaml` | set back to 100 (new large volumes then fail to schedule) |
| Devbox and waker started (replicas 1); ExternalSecret templates trim values (pasted tokens had a trailing newline) | `apps/ai-agent/` | replicas 0 |
