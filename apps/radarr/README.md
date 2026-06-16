# Radarr

Same as Prowlarr — image runs as UID/GID 65534 (nobody).
After first install, before letting the pod start, fix Longhorn volume ownership:

kubectl scale deployment radarr -n media --replicas=0
kubectl run -n media fix-perms --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"fix-perms","image":"busybox","command":["sh","-c","chown -R 65534:65534 /config"],"volumeMounts":[{"name":"config","mountPath":"/config"}]}],"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"radarr-config"}}]}}'
kubectl delete pod fix-perms -n media
kubectl scale deployment radarr -n media --replicas=1