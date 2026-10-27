# Bazarr

Downloads subtitles (English) for every movie and episode that Radarr/Sonarr manage and saves them as
`.srt` next to the video file, so Jellyfin finds them. New items get subtitles automatically; the existing
library is filled in over a few days (free subtitle-site download limits).

- Address: **https://bazarr.home.cedricschippers.dev** (home network or Tailscale).
- Plain manifests in `deployment.yaml` (no Helm chart for it in our repos): Deployment (UID 1000, Recreate),
  1 Gi Longhorn volume `bazarr-config` (settings, included in the nightly backup), ClusterIP Service 6767.
  Mounts the NAS at `/media` like Sonarr/Radarr, so the paths match theirs.
- Talks to the others by service name: `sonarr.media.svc.cluster.local:8989`,
  `radarr.media.svc.cluster.local:7878`.

## First-time setup (in the browser; nothing goes into git)
1. Open the address. Settings -> **General -> Security**: set Authentication to *Form* and choose a
   username and password (Bazarr has no login by default). Save.
2. Settings -> **Languages**: add **English** under "Languages Filter"; under **Languages Profiles** add a
   profile "English" (English, plain), tick "Cutoff" off. Set it as the default profile for Series and Movies.
3. Settings -> **Providers**: add **OpenSubtitles.com** with your username and password (free account at
   opensubtitles.com). Add one or two more for backup, e.g. *Podnapisi* and *Subscene alternatives* that need
   no login.
4. Settings -> **Sonarr**: enable, address `sonarr.media.svc.cluster.local`, port `8989`, API key (below),
   Test, Save. Settings -> **Radarr**: the same with `radarr.media.svc.cluster.local`, port `7878`.
5. Settings -> **Subtitles**: leave defaults, but tick *Upgrade previously downloaded subtitles* if you like.
6. Wait for the series/movies lists to sync (Series / Movies tabs). Bazarr then searches for missing
   subtitles by itself. To start right away: Wanted -> Movies/Series -> *Search All*.
7. In Jellyfin: each user's profile -> Playback -> Preferred subtitle language **English**, Subtitle mode
   **Always** (or Default). Do it for every user, it is a per-user setting.

API keys (print them in your own terminal only, never paste them anywhere public):
```bash
kubectl -n media exec deploy/radarr -- sh -c "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
kubectl -n media exec deploy/sonarr -- sh -c "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
```

## Operations
- Health: `kubectl -n media get pods -l app=bazarr`.
- Restart: `kubectl -n media rollout restart deploy/bazarr`.
- Updates: Renovate proposes image bumps (the tag and digest are pinned in `deployment.yaml`).
- Undo: remove `bazarr/deployment.yaml` from `apps/kustomization.yaml`, the ingress host and the Homepage tile;
  `kubectl -n media delete deploy,svc bazarr` and `kubectl -n media delete pvc bazarr-config` if the data
  should go too. The downloaded `.srt` files stay on the NAS (harmless).
