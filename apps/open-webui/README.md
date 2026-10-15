# Open WebUI

ChatGPT-style web UI for the Ollama instance on the Windows PC (model `gemma4:12b`). Ollama is
reached over Tailscale at `http://100.93.62.83:11434`, so **the PC must be on** for chatting; the UI
itself runs on the cluster and keeps working (history, settings) when the PC is off.

- Chart `open-webui/open-webui` 17.0.0, deployed by Flux (`apps/flux/helmreleases.yaml`), values in
  `values.yaml`. It is a **StatefulSet**: the pod is `open-webui-0`.
- Pinned to `k3s-worker-01`, the only node with Tailscale (it carries the traffic to the PC).
- Bundled Ollama, Pipelines and Redis are switched off. Data (SQLite DB, uploads) is on a 5 Gi
  Longhorn volume, included in the nightly backup.
- LAN address `http://192.168.50.107` (MetalLB). Plain HTTP: fine for chatting, not enough to
  install it as an app, see "HTTPS" below.
- The new cluster you are planning does not depend on this: nothing here references it.

## First-time setup (manual steps)

### 1. Secret (never in git)
Open WebUI signs its login tokens with `WEBUI_SECRET_KEY`. Create it once, with a generated value
that is never printed or stored anywhere else (the namespace exists once Flux has applied the repo):
```bash
kubectl -n open-webui create secret generic open-webui-secret \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
```
The pod waits (`CreateContainerConfigError`) until this exists, then starts by itself.
If the cluster is ever rebuilt, just create a new one: the only effect is that everyone is logged out.

### 2. Admin account
Open `http://192.168.50.107` and **create your account first**: the first account becomes admin.
Signup is still open at this point (`ENABLE_SIGNUP: "true"` in `values.yaml`).

### 3. Close signup (after step 2)
Set `ENABLE_SIGNUP` to `"false"` in `values.yaml`, commit and push. Flux restarts the pod within a
couple of minutes. New people can then only be added by an admin (Admin panel → Users).

## Checks
```bash
kubectl -n open-webui get pods,pvc                  # open-webui-0 Running, PVC Bound
kubectl -n open-webui exec open-webui-0 -- curl -s -m 5 http://100.93.62.83:11434/api/tags
```
The second command lists the models. If it times out:
- **Fails from the pod but works from `k3s-worker-01` itself** (`curl` on the node): pod-to-Tailscale
  routing (pod traffic must be masqueraded out through `tailscale0`).
- **Fails from the node too**: the PC is off, or its Windows firewall rule only allows
  `100.64.0.0/10` and the node's Tailscale address isn't coming from there. Don't change anything
  on the PC from here.

## HTTPS (needed to install it as an app / PWA)
Browsers only offer "install" on HTTPS. Two ways, pick one:

**A. Through Traefik (no node changes, valid certificate)**: add a host to `apps/traefik/ingresses.yaml`,
e.g. `chat.home.cedricschippers.dev` → service `open-webui` port 80 in namespace `open-webui` (the
wildcard certificate and DNS record already exist). Works at home and on Tailscale as long as the
phone/Mac can reach `192.168.50.0/24` over the subnet route.

**B. `tailscale serve` on k3s-worker-01** (works from anywhere on the tailnet, independent of the
LAN). One-time, by hand, nothing here is automated:
1. Tailscale admin console → DNS → enable **MagicDNS** and **HTTPS Certificates**.
2. On `k3s-worker-01`, check the syntax of the installed version first: `tailscale serve --help`.
3. Publish the service (in the background, survives reboots):
   ```bash
   sudo tailscale serve --bg --https=443 http://192.168.50.107:80
   ```
4. `tailscale serve status` shows the address: `https://k3s-worker-01.<tailnet>.ts.net`.
5. Open it on your Mac or phone and use "Install" / "Add to Home Screen".
To remove it: `sudo tailscale serve reset`.

## Operations
- Restart: `kubectl -n open-webui delete pod open-webui-0` (StatefulSet recreates it).
- Update: Renovate proposes chart version bumps; merging deploys them (Flux).
- Logs: `kubectl -n open-webui logs open-webui-0`.
