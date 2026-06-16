# Prowlarr

Image runs as UID/GID 65534 (nobody), not the bjw-s standard 568.
This chart (pree/prowlarr) does not expose a securityContext values key,
so Longhorn volume ownership must be fixed manually after first PVC creation:

kubectl scale deployment prowlarr -n media --replicas=0
kubectl run -n media fix-perms --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"fix-perms","image":"busybox","command":["sh","-c","chown -R 65534:65534 /config"],"volumeMounts":[{"name":"config","mountPath":"/config"}]}],"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"prowlarr-config"}}]}}'
kubectl delete pod fix-perms -n media
kubectl scale deployment prowlarr -n media --replicas=1