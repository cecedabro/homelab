# Local AI coding agent (cluster side)

The model runs on the Windows PC (WSL2 + llama.cpp, served as alias `coder`). The agent runs here, in
an always-on **devbox** pod, wakes the PC with Wake-on-LAN when there is work, and lets it sleep
again afterwards. PC scripts, the devbox image and the loop harness live in
**github.com/cecedabro/local-ai-agent** (public); this folder is only what runs on the cluster.

| Object | What |
|---|---|
| namespace `ai-agent` (Pod Security *restricted*) | StatefulSet `devbox` (1 pod, 30 Gi Longhorn home, not in the nightly backup), ConfigMap `devbox-config`, ExternalSecret `devbox`, NetworkPolicy `devbox` |
| namespace `ai-waker` (Pod Security *privileged*) | Deployment `waker` (hostNetwork on k3s-worker-01, listens on 192.168.50.11:9009 only), ExternalSecret `waker` |

Why the waker has its own namespace: magic packets are LAN broadcasts and pod networks don't carry
them, so it needs hostNetwork, which *restricted* forbids. hostNetwork pods are not covered by
NetworkPolicy, so `/wake` needs the token.

The devbox has **no inbound access at all**. Its egress is: DNS, the internet on 80/443 plus
Tailscale's ports (private ranges excluded), the waker, and (once added) the PC on 8080/2222. It
cannot reach other services in the cluster or on the LAN.

## Setup (your steps)

1. **Make the image pullable.** The repo is public, but GitHub keeps the image package private (its
   visibility is separate and has no API). On GitHub: your profile → Packages → `local-ai-agent-devbox`
   → Package settings → Change visibility → **Public** (only public tools, no secrets). Until then the
   pod shows `ImagePullBackOff`.
2. **Tailscale** (admin console): add the tag to the ACL `tagOwners` (`"tag:devbox": ["autogroup:admin"]`),
   then Settings → Keys → generate an auth key: *not* reusable, tags `tag:devbox`. Allow your own
   devices SSH to it (ACL `ssh` rule: src your user, dst `tag:devbox`, users `agent`).
3. **Secrets in OpenBao** (https://openbao.home.cedricschippers.dev, token login), engine `secret`:
   - `ai-agent/waker`: `PC_MAC` = the PC's wired NIC MAC (`getmac /v`), `WAKER_TOKEN` = output of
     `openssl rand -hex 32`.
   - `ai-agent/devbox`: `GITHUB_TOKEN` (fine-grained PAT, only the project repo the agent works on,
     Contents + Pull requests read/write), `TS_AUTHKEY` (step 2), `NTFY_TOPIC` (a long random topic
     name; subscribe to it in the ntfy app), `LLAMA_API_KEY` (from the PC, `/etc/llama/api-key`; put
     `unset` until then: ESO only creates the Secret when *every* key exists).
   Then: `kubectl -n ai-agent annotate externalsecret devbox force-sync=$(date +%s) --overwrite`
   (same for `-n ai-waker externalsecret waker`). Then set `replicas: 1` in `devbox.yaml` (it is 0
   so a missing image or secret doesn't page you) and commit; Flux starts it.
4. **The PC on the LAN:** reserve **192.168.50.17** for the PC in the router (MAC `30-9C-23-6A-7E-39`).
   `devbox.yaml` already uses it (`PC_HOST`, `LLAMA_BASE_URL`, NetworkPolicy). The PC runs Windows 10,
   so WSL is behind NAT and `ai-power.ps1` forwards 8080/2222 from the PC's LAN address into WSL.
5. **Waker:** set `replicas: 1` in `waker.yaml` once `ai-agent/waker` is in OpenBao (and Wake-on-LAN
   is set up on the PC, `pc/README.md` Phase 2).
6. **PC key:** the devbox generates its own SSH key on first start. Get the public half with
   `kubectl -n ai-agent logs devbox-0 | grep "PC key"` and use it in `pc/power/setup-wsl.sh`.

## Checks
```bash
kubectl -n ai-agent get pod devbox-0                 # Running
kubectl -n ai-agent exec -it devbox-0 -- bash        # shell without Tailscale
kubectl -n ai-agent get externalsecret devbox        # SecretSynced
# from the devbox: wake the PC, then ask the model
curl -s -X POST -H "X-Waker-Token: $WAKER_TOKEN" "$WAKER_URL/wake"
curl -s -H "Authorization: Bearer $LLAMA_API_KEY" "$LLAMA_BASE_URL/models"
```

## Operations
- **New devbox image:** CI builds one per push to main in local-ai-agent (tag = commit sha, only after
  lint + self-test pass). Bump the tag in `devbox.yaml` by hand, never while a loop is running: the
  pod restarts and the tmux session is gone (the loop resumes from `PLAN.md`, but the run stops).
- **waker.py changed:** `kubectl -n ai-waker rollout restart deploy/waker` (ConfigMap has no hash suffix).
- **Home volume:** not backed up on purpose (work is in git). To include it, remove the two
  `recurring-job` labels from the Longhorn volume.

## Undo
Remove `ai-agent` from `apps/kustomization.yaml`, then (Flux prune is off)
`kubectl delete ns ai-agent ai-waker` (deletes the home volume too), and delete
`secret/ai-agent/*` in OpenBao and the Tailscale device/key.
