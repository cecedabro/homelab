# Radarr

Runs as **UID/GID 1000** (`podSecurityContext` in `values.yaml`), the same user qBittorrent
writes downloads as. That is what lets imports *hardlink* from `/media/downloads` into
`/media/movies` instead of silently copying (with `fs.protected_hardlinks=1` a user can't
hardlink another user's 0644 file). Sonarr and Readarr use the same setting.

`fsGroup: 1000` keeps the existing config volume (originally created as 65534/nobody) writable,
so no manual chown is needed anymore.

Root folder: `/media/movies`. Download client: qBittorrent at `192.168.50.111:8080`, category
`radarr`. Settings → Connect → "Jellyfin" triggers a library scan after each import.
