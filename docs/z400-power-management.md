# Z400 Power Management

The Z400 (k3s-gpu-01) uses S3 sleep instead of full poweroff for fast wake times.

Sleep (from Z400 itself):
sudo systemctl suspend

Wake (from any machine on the network):
wakeonlan -i 192.168.50.255 18:a9:05:c1:f2:45

Wake time from sleep: near-instant (a few seconds)
Wake time from full poweroff: 60-90+ seconds (avoid using poweroff for this node)

Caution: pods using RWO volumes can get stuck Terminating if the node
goes to sleep/off while they're still scheduled there. Consider draining
the node (kubectl drain k3s-gpu-01) before sleep if pods are actively running.