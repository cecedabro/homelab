#!/usr/bin/env bash
# One-time OpenBao setup for External Secrets Operator. Run from your Mac AFTER
# `bao operator init` and unsealing. Safe to re-run.
#
# - KV v2 secrets engine at secret/
# - Kubernetes auth, with role "external-secrets" for ESO's ServiceAccount (read-only)
# - Seeds secret/monitoring/grafana from the existing grafana-admin Secret
#
# The root token is read from a hidden prompt and passed to the pod over stdin,
# so it never shows up in shell history, process args or the Kubernetes API.
set -euo pipefail

NS=openbao
POD=openbao-0

read -rsp "OpenBao root token: " TOKEN; echo

# bao <args...> [stdin data] : runs bao inside the pod; first stdin line is the token
bao() {
  local stdin_data="${BAO_STDIN:-}"
  printf '%s\n%s' "$TOKEN" "$stdin_data" | kubectl -n "$NS" exec -i "$POD" -- \
    sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

echo "==> KV v2 at secret/"
bao secrets list -format=json | grep -q '"secret/"' || bao secrets enable -path=secret kv-v2

echo "==> Kubernetes auth"
bao auth list -format=json | grep -q '"kubernetes/"' || bao auth enable kubernetes
# Running in-cluster: OpenBao uses its own ServiceAccount token + CA to review tokens
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

echo "==> Read-only policy for ESO"
BAO_STDIN='path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }' \
  bao policy write external-secrets-read -

echo "==> Role for the external-secrets ServiceAccount"
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-read \
  ttl=1h

echo "==> Seed secret/monitoring/grafana from the existing grafana-admin Secret"
GRAFANA_PW=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
BAO_STDIN="$GRAFANA_PW" bao kv put secret/monitoring/grafana admin-user=admin admin-password=-
unset GRAFANA_PW

echo "==> Done. Check: bao kv get secret/monitoring/grafana (in the pod, logged in)"
unset TOKEN
