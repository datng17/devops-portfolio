#!/usr/bin/env bash
# HPA demo: starts the k6 load Job (k8s/tests/k6-load.yaml), prints an HPA /
# pod timeline while it runs, keeps watching until the HPA is back at
# minReplicas, then deletes the Job and its ConfigMap (also on Ctrl-C/error).
#
# Usage: scripts/hpa-load-test.sh
# Env:
#   NAMESPACE           default portfolio
#   HPA                 default portfolio
#   MANIFEST            default k8s/tests/k6-load.yaml (relative to the repo root)
#   INTERVAL            seconds between samples (default 15)
#   SCALE_DOWN_TIMEOUT  seconds to wait for minReplicas after k6 ends (default 600)
#
# Exit codes: 0 HPA reached maxReplicas, came back to minReplicas and k6 passed
# its thresholds; 1 otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."
NAMESPACE="${NAMESPACE:-portfolio}"
HPA="${HPA:-portfolio}"
MANIFEST="${MANIFEST:-k8s/tests/k6-load.yaml}"
INTERVAL="${INTERVAL:-15}"
SCALE_DOWN_TIMEOUT="${SCALE_DOWN_TIMEOUT:-600}"
JOB=k6-load

k() { kubectl -n "$NAMESPACE" "$@"; }
hpa() { k get hpa "$HPA" -o jsonpath="$1"; }

cleanup() {
  echo "::: Cleaning up $MANIFEST"
  kubectl delete -f "$MANIFEST" --ignore-not-found --wait=true >/dev/null || true
}
trap cleanup EXIT

min_replicas="$(hpa '{.spec.minReplicas}')"
max_replicas="$(hpa '{.spec.maxReplicas}')"
start=$(date +%s)
peak=0
peak_at=""

sample() {
  local now cur desired metrics ready nodes
  now=$(( $(date +%s) - start ))
  cur="$(hpa '{.status.currentReplicas}')"
  desired="$(hpa '{.status.desiredReplicas}')"
  metrics="$(hpa '{range .status.currentMetrics[*]}{.resource.name}={.resource.current.averageUtilization}% {end}')"
  ready="$(k get deploy "$HPA" -o jsonpath='{.status.readyReplicas}')"
  nodes="$(k get pods -l app.kubernetes.io/name=portfolio -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')"
  printf '%s t+%4ss current=%s desired=%s ready=%s %s| %s\n' "$(date +%H:%M:%S)" "$now" "$cur" "$desired" "${ready:-0}" "$metrics" "$nodes"
  if [[ "${cur:-0}" -gt "$peak" ]]; then peak="$cur"; peak_at="t+${now}s"; fi
  last_current="${cur:-0}"
}

echo "::: HPA $HPA: min=$min_replicas max=$max_replicas; baseline:"
k get hpa "$HPA"
# A leftover Job from an earlier run would make apply a no-op.
kubectl delete -f "$MANIFEST" --ignore-not-found --wait=true >/dev/null
kubectl apply -f "$MANIFEST"

echo "::: Load running (about 5 minutes)"
job_state=""
while :; do
  sample
  job_state="$(k get job "$JOB" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')"
  [[ "$job_state" == *Complete* || "$job_state" == *Failed* ]] && break
  sleep "$INTERVAL"
done
load_end=$(( $(date +%s) - start ))
echo "::: k6 finished at t+${load_end}s ($job_state). Summary:"
k logs "job/$JOB" --tail=60 || true

echo "::: Waiting for scale-down to $min_replicas (stabilization window applies)"
deadline=$(( $(date +%s) + SCALE_DOWN_TIMEOUT ))
back_at=""
while [[ $(date +%s) -lt $deadline ]]; do
  sample
  if [[ "$last_current" -eq "$min_replicas" ]]; then back_at="t+$(( $(date +%s) - start ))s"; break; fi
  sleep "$INTERVAL"
done

echo "::: Result: peak=$peak replicas at $peak_at, back to $min_replicas at ${back_at:-never (timeout)}, k6=$job_state"
k get events --field-selector involvedObject.name="$HPA" --sort-by=.lastTimestamp | tail -n 10 || true

[[ "$peak" -eq "$max_replicas" && -n "$back_at" && "$job_state" == *Complete* ]]
