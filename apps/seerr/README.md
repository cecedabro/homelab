# Seerr

Request manager: someone picks a movie or series in a nice web UI, Seerr hands the request to Radarr
(movies) or Sonarr (series), they download it via qBittorrent, and it shows up in Jellyfin. Seerr is
the merged successor of Jellyseerr and Overseerr. Users log in with their **Jellyfin account**.

- Address: **https://seerr.home.cedricschippers.dev** (home network or Tailscale subnet route).
- Official chart (`oci://ghcr.io/seerr-team/seerr/seerr-chart`), deployed by Flux, values in `values.yaml`.
  A StatefulSet in the `media` namespace, one pod `seerr-0`, runs as UID 1000, 1 Gi Longhorn volume
  (settings + users, included in the nightly backup).
- It talks to the other apps by service name (same namespace, so the NetworkPolicy allows it):
  `jellyfin.media.svc.cluster.local:8096`, `radarr.media.svc.cluster.local:7878`,
  `sonarr.media.svc.cluster.local:8989`.

## First-time setup (wizard in the browser, nothing goes into git)
1. Open the address and choose **Jellyfin** as the server type.
2. Jellyfin URL: `http://jellyfin.media.svc.cluster.local:8096`, then log in with your Jellyfin **admin**
   account. You become the Seerr admin. Select the libraries to sync (Movies, Shows).
3. **Radarr** (Settings → Services → Radarr → Add):
   host `radarr.media.svc.cluster.local`, port `7878`, no SSL, API key (below), pick the quality profile,
   root folder `/media/movies`, minimum availability "Released", mark it as default.
4. **Sonarr** the same way: host `sonarr.media.svc.cluster.local`, port `8989`, root folder `/media/tv`.
5. Settings → Users: import the Jellyfin users that may request things (e.g. your girlfriend), and set
   limits or auto-approval per user.
6. Optional: Settings → Notifications → add a webhook or ntfy for new requests.

API keys (print them in your own terminal only, never paste them anywhere public):
```bash
kubectl -n media exec deploy/radarr -- sh -c "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
kubectl -n media exec deploy/sonarr -- sh -c "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
```
Seerr keeps these keys in its own database on the volume.

## Operations
- Health: `kubectl -n media get pods -l app.kubernetes.io/name=seerr-chart` (or `seerr-0`), status API at `/api/v1/status`.
- Restart: `kubectl -n media delete pod seerr-0` (StatefulSet recreates it; startup takes about a minute).
- Updates: Renovate proposes chart version bumps (the chart's appVersion is the image version).
- If requests don't reach Radarr/Sonarr: Settings → Services → test the connection; check the service
  names above and that the quality profile and root folder exist in Radarr/Sonarr.
