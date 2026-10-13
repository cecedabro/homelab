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
