# Operations runbook

Everyday tasks. Commands run from a machine with `kubectl` access to the cluster (your Mac),
unless they say "on k3s-cp-01".

## After a reboot / power outage
1. Check nodes: `kubectl get nodes` (all `Ready`).
2. **Unseal OpenBao**: the Homepage dot for OpenBao is red while sealed. Run three times, with
   three different unseal keys from the password manager:
   ```bash
   kubectl -n openbao exec -it openbao-0 -- bao operator unseal
   ```
   Apps keep working while sealed (their Secrets are already synced); only new/changed secrets wait.
3. Check for stuck pods: `kubectl get pods -A | grep -vE 'Running|Completed'`.

## Changing things (GitOps)
Since 13 Oct 2026 Flux applies the repo. **Flux also commits to it** (image bumps for
ruilingen, author `fluxcdbot`), so always `git pull` before you edit. The normal way to change anything is:
1. Edit the file (`apps/<app>/values.yaml`, a manifest, or a version in `apps/flux/helmreleases.yaml`).
2. Commit + push to `main`. Flux picks it up within a minute (Helm values ConfigMaps trigger
   the upgrade immediately). Force it now with:
   ```bash
   kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```
3. Check: `kubectl -n flux-system get kustomization,helmrelease`: everything `True`.
   A failure shows the reason in the STATUS column.

**Don't** `helm upgrade` an app that Flux manages (see `apps/flux/helmreleases.yaml`); Flux
would undo it at the next sync. Only Traefik (k3s) and Minecraft are still updated by hand.

**Emergency: stop Flux from touching things** (e.g. while debugging by hand):
```bash
kubectl -n flux-system patch kustomization apps --type merge -p '{"spec":{"suspend":true}}'
# ... and resume with "suspend":false
```

**Renovate PRs**: review the release notes linked in the PR, merge, and Flux deploys it.
Majors only appear after you tick them on the "Dependency Dashboard" issue.

## Restarting an app
```bash
kubectl -n media rollout restart deploy/jellyfin
kubectl -n media rollout status deploy/jellyfin
```
For **cloudflared, FlareSolverr and qBittorrent** (plain manifests applied by Flux) use
`kubectl -n <ns> delete pod -l app=<name>` instead: Flux strips the `rollout restart`
annotation on its next sync, which would restart the pod a second time. (cloudflared has 2
replicas: delete one pod, wait until it's back, then the other.)

Every app with a Longhorn volume uses the `Recreate` strategy, so the old pod releases the
volume before the new one starts. **Don't** `kubectl delete pod` repeatedly: it restarts the
attach/detach cycle. If a pod is stuck on its volume:
```bash
kubectl -n media scale deploy/radarr --replicas=0
# wait until the Longhorn volume shows "detached"
kubectl -n media scale deploy/radarr --replicas=1
```
"already mounted or mount point busy" on a new node: check `multipathd` on that node
(Longhorn's iSCSI devices must be blacklisted, see "Adding a node").

## Node maintenance (reboot, cable swap)
```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=5m
# reboot / maintenance (on the node)
kubectl uncordon <node>
```
For `k3s-cp-01`: a short unplug (< 1 min) is harmless; beyond ~5 min Kubernetes starts
rescheduling pods. `kubectl` doesn't work on worker nodes (no kubeconfig there).

## Adding a node
1. Install k3s agent (or server, see the HA plan in architecture.md).
2. **Blacklist Longhorn devices for multipath** (Ubuntu ships multipathd):
   ```bash
   printf 'blacklist {\n    devnode "^sd[a-z0-9]+"\n}\n' | sudo tee -a /etc/multipath.conf
   sudo systemctl restart multipathd && sudo multipath -F
   ```
3. Check the link speed: `sudo ethtool <iface> | grep Speed` → `1000Mb/s` (alert NodeLinkNotGigabit).
4. Add its flannel addresses (`10.42.<n>.0/32` and `.1/32`, see `kubectl get node -o
   jsonpath='{.spec.podCIDR}'`) to `apps/network-policies/*.yaml` and `apps/openbao/networkpolicy.yaml`.

## Secrets
Add or change a value in the OpenBao UI (https://openbao.home.cedricschippers.dev, token
login), then either wait up to an hour or force the sync:
```bash
kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
```
Apps that read a secret only at start (Grafana admin, Nextcloud admin, gluetun, cloudflared)
need a restart; Grafana and Nextcloud also need their password reset inside the app (commands
in their `externalsecret.yaml`).
New secret: put it in OpenBao, copy an existing `externalsecret.yaml`, change namespace/name/
path/keys, apply, and check `kubectl get externalsecret -A` shows `SecretSynced`.

## Exposing an app internally (HTTPS name)
Add a rule to `apps/traefik/ingresses.yaml`:
```yaml
- host: <app>.home.cedricschippers.dev
  http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: <svc>, port: {number: <port>}}}}]}
```
The wildcard certificate and DNS already cover every `*.home` name. For an app without its own
login, add the annotation
`traefik.ingress.kubernetes.io/router.middlewares: <ns>-basic-auth@kubernetescrd` and create
the middleware + secret in that namespace (see the existing ones). If the namespace has a
NetworkPolicy, Traefik is already allowed.

## Backups and restores
| What | Where | Check |
|---|---|---|
| Longhorn volumes (daily 02:00, 7 kept) | NAS `longhorn-backups/` | Longhorn UI → Backup |
| k3s datastore (daily 01:30, 14 kept, encrypted) | NAS `k3s-backups/` | `kubectl -n kube-system get jobs` |

**Restore a Longhorn volume**: Longhorn UI → Backup → pick the backup → Restore (to a new
volume), then create a PV/PVC for it (or use "Create PV/PVC" in the UI) and point the app at it.

**Restore the k3s datastore** (cp-01 lost its disk): reinstall k3s on cp-01, stop it, then
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in /mnt/media-storage/k3s-backups/k3s-<ts>.tar.gz.enc | tar xz
sudo cp state.db /var/lib/rancher/k3s/server/db/state.db
sudo cp token /var/lib/rancher/k3s/server/token
sudo systemctl start k3s
```
The passphrase is the `k3s-backup-passphrase` secret: keep a copy in the password manager,
otherwise the backups can't be opened when the cluster is gone:
```bash
kubectl -n kube-system get secret k3s-backup-passphrase -o jsonpath='{.data.passphrase}' | base64 -d; echo
```

## Off-site backups (Backblaze B2)
Nightly 05:00 `kube-system/offsite-backup` copies `/mnt/media-storage/longhorn-backups` and
`/mnt/media-storage/k3s-backups` to B2, encrypted with rclone crypt (OpenBao `backup/b2`).
Alerts: `BackupJobFailed`, `OffsiteBackupStale` (no success for 2 days). Run it now:
```bash
kubectl -n kube-system create job --from=cronjob/offsite-backup offsite-backup-manual
```
**Restore from B2** (NAS lost): on any machine with rclone, set up the same two remotes from the
values in Bitwarden (B2 key ID + application key, bucket, crypt password), then
```bash
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT=<keyID> RCLONE_CONFIG_B2_KEY=<appKey>
export RCLONE_CONFIG_OFFSITE_TYPE=crypt RCLONE_CONFIG_OFFSITE_REMOTE=b2:<bucket>/homelab
export RCLONE_CONFIG_OFFSITE_PASSWORD=$(rclone obscure '<crypt password>')
rclone copy offsite:longhorn-backups ./longhorn-backups    # point Longhorn's backup target here
rclone copy offsite:k3s-backups ./k3s-backups             # then see "Restore the k3s datastore"
```

## Upgrading k3s
Renovate opens a PR when a new k3s patch release exists (minor versions wait for approval on the
Dependency Dashboard). After merging it, nothing happens until you allow nodes:
```bash
kubectl label nodes --all homelab/k3s-upgrade=allowed
kubectl -n system-upgrade get plans,jobs -w      # server first, then agents one by one (drained)
kubectl get nodes                                # all on the new version
kubectl label nodes --all homelab/k3s-upgrade-
```
Then unseal OpenBao if its node was drained (alert `OpenBaoSealed`).

## OS updates
`unattended-upgrades` installs Ubuntu security updates nightly on every node, without rebooting.
If `/var/run/reboot-required` exists on a node, reboot it when convenient: drain → reboot →
uncordon (see "Node maintenance").

## Media stack
- Movies/series that downloaded but don't show up: Radarr/Sonarr → Activity → Queue. The
  connection "Jellyfin" in Settings → Connect triggers a Jellyfin scan after every import.
- Jellyfin's realtime monitoring doesn't work over NFS; a manual "Scan All Libraries" always helps.
- Duplicates: check `stat -c %h <file>` (2 = hardlinked, fine; 1 in both places = a copy).

## Ruilingen (ruilingen.app)
- **Deploy = release**: in the app repo, `git tag vX.Y.Z && git push origin vX.Y.Z`. CI builds image
  `X.Y.Z`; Flux image automation picks it up within ~5 min, commits the bump here and deploys it.
  Pushes to `main` build images but don't deploy.
- Rollback: set the previous tag on the marked image line in `apps/ruilingen/deployment.yaml`
  (pull first) and push. Migrations only go forward, so a schema change also needs the Longhorn
  backup restored.
- Restart: `kubectl -n ruilingen delete pod -l app=ruilingen` (1 replica, ~30 s downtime).
- Admin login link: `kubectl -n ruilingen exec deploy/ruilingen -- python -m app.cli admin-link "Name"`.
- Secrets: OpenBao `ruilingen/app` (`SESSION_SECRET`: don't rotate casually, it logs everyone out).

## Minecraft
The Bedrock chart's probes are patched by hand (NetherNet transport). **Don't** run
`helm upgrade` on the minecraft releases without re-applying the patch, see the note at the
bottom of `apps/minecraft/values.yaml`.

## Credentials (where to find them)
| What | Where |
|---|---|
| OpenBao root token, unseal keys | password manager only |
| Grafana admin | OpenBao `monitoring/grafana` |
| Nextcloud admin | OpenBao `nextcloud/nextcloud-admin` |
| Longhorn/Prometheus/Alertmanager login | OpenBao `monitoring/dashboard-login` |
| ntfy topic (alerts) | OpenBao `monitoring/ntfy` |
| k3s backup passphrase | OpenBao `kube-system/k3s-backup` (+ password manager) |
| B2 key + crypt password (off-site) | OpenBao `backup/b2` (+ password manager: needed to restore if the cluster is gone) |
