# Deployment guide: resilience and HPA drills

These drills show that the `portfolio` Deployment autoscales and stays up
through pod loss, the loss of one AZ's node, and rolling updates. Run them
against the live cluster (`eks-portfolio`, namespace `portfolio`).

On Windows, run the shell scripts with Git Bash
(`"C:\Program Files\Git\bin\bash.exe" scripts/...`); plain `bash` may resolve
to WSL.

## What makes it work

- 2 replicas minimum, spread across us-east-1a and us-east-1b (zone
  anti-affinity + topology spread).
- `maxSurge: 1`, `maxUnavailable: 0`: a rollout never drops below the current
  capacity.
- PDB `minAvailable: 1`: a drain can evict only one portfolio pod at a time.
- `preStop` sleep 10 s + 30 s grace: a terminating pod keeps serving while the
  ALB deregisters it and endpoints update.
- ALB readiness gates (`elbv2.k8s.aws/pod-readiness-gate-inject`): a new pod
  only counts as Ready once the ALB reports its target healthy, so a rollout
  can't outrun the ALB.
- HPA (2-5, CPU 60%, memory 75%) measures against the requests (50m CPU,
  64Mi). Static nginx uses almost no CPU, so the load test has to be
  aggressive. The 120 s scale-down stabilization window stops flapping.

## Availability probe (curl loop)

Every drill runs this in a second terminal and is judged on its output:

```bash
scripts/availability-probe.sh https://test.name.vn/ 0   # Ctrl-C to stop
```

It sends one request per loop (fresh connection each time, `INTERVAL=0.2`,
5 s timeout) and prints the count per status code. `000` means no HTTP
response. Pass = `non-200: 0`. Give it a fixed duration instead of `0` to stop
on its own. The rate is bounded by round-trip latency to us-east-1 (about
1 request/s from Vietnam); run two copies for more samples.

The bare-curl equivalent:

```bash
while true; do curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 https://test.name.vn/; sleep 0.2; done | sort | uniq -c
```

## Drill 1: HPA scale-out and scale-in

```bash
scripts/hpa-load-test.sh
```

Applies `k8s/tests/k6-load.yaml` (pinned `grafana/k6` Job, about 5 minutes,
up to 40 VUs with no think time, no connection reuse so new replicas get
traffic), prints `current/desired/ready` replicas, CPU/memory utilization and
pods per node every 15 s, prints the k6 summary, waits for the HPA to return
to 2, and deletes the Job and ConfigMap (also on Ctrl-C).

Expected: 2 → 5 within about a minute of load, back to 2 about 2-3 minutes
after the load stops (120 s window plus metrics lag), k6 thresholds pass
(`http_req_failed < 1%`). 5 replicas need 250m CPU of requests, which fits on
the 2 existing t3.medium nodes; there is no cluster autoscaler.

## Drill 2: delete a pod

```bash
scripts/availability-probe.sh https://test.name.vn/ 0 &   # or second terminal
kubectl -n portfolio get pods -l app.kubernetes.io/name=portfolio -o wide
kubectl -n portfolio delete pod <one portfolio pod>
kubectl -n portfolio get pods -l app.kubernetes.io/name=portfolio -o wide -w   # until the replacement shows READINESS GATES 1/1 and 1/1 Ready
# stop the probe
```

Expected: `non-200: 0`. The other pod serves while the deleted one runs its
preStop sleep and the ReplicaSet brings up a replacement.

## Drill 3: lose one AZ (cordon + drain a node)

Drain the us-east-1b node. The us-east-1a node holds `log-sink-0`, whose gp3
volume is zonal, so draining 1a would leave log-sink Pending until uncordon
(serving would be fine, nginx syslog would drop).

```bash
scripts/availability-probe.sh https://test.name.vn/ 0 &
NODE=$(kubectl get nodes -l topology.kubernetes.io/zone=us-east-1b -o name)
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=5m
kubectl -n portfolio get pods -o wide        # both portfolio pods now in 1a
# keep the probe running a minute in the degraded state, then:
kubectl uncordon "$NODE"
# stop the probe
```

Expected: `non-200: 0`. The PDB lets the drain evict one portfolio pod; it is
recreated in us-east-1a while the existing 1a pod serves. kube-system
deployments (LBC, CoreDNS, metrics-server, EBS CSI) run 2 replicas with
`maxUnavailable: 1` PDBs. After uncordon nothing moves back on its own; the
rollout in Drill 4 re-spreads the pods across both AZs.

## Drill 4: rolling update under load

Run the load Job and the probe, and roll the Deployment while the HPA is at 5:

```bash
scripts/hpa-load-test.sh &                       # wait until current=5
scripts/availability-probe.sh https://test.name.vn/ 0 &
kubectl -n portfolio rollout restart deployment/portfolio
kubectl -n portfolio rollout status deployment/portfolio --timeout=10m
# stop the probe after the rollout; let hpa-load-test.sh finish
```

A Jenkins deploy (push to `main`) is the same kind of rollout with a new
image; run the probe across a pipeline run to measure it.

Expected: `non-200: 0`, k6 `http_req_failed` stays under 1%.

## Cleanup

`hpa-load-test.sh` deletes the Job/ConfigMap itself. If it was killed hard:

```bash
kubectl delete -f k8s/tests/k6-load.yaml --ignore-not-found
kubectl get nodes        # no SchedulingDisabled
```
