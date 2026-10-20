# Task 11 - Resilience and HPA verification

## Status
- [ ] Not started / - [x] Done

## Objective
Evidence of autoscaling and zero-downtime behaviour.

## Dependencies
Task 9.

## Files to create/modify
- `k8s/tests/k6-load.yaml`
- `scripts/hpa-load-test.sh`
- Drills documented in `docs/deployment-guide.md`

## Implementation guidance
- A k6 Job (pinned `grafana/k6`) with a ConfigMap script that ramps virtual users against `http://portfolio.portfolio.svc.cluster.local` for about 5 minutes.
- `hpa-load-test.sh` starts the Job, watches the HPA and pods, and cleans up.
- Drills, each run with a curl loop against the site:
  - delete a pod
  - cordon and drain the node in one AZ
  - a rolling update under load

## Test requirements
- The HPA scales from 2 up to 5 and back to 2.
- Zero non-200 responses during the drills.

## Demo / acceptance criteria
A recorded scale-out and AZ-loss run.

## Interview talking points
- HPA uses `requests` as the denominator, so the request size sets scaling sensitivity.
- The scale-down stabilization window stops flapping.
- The PDB plus 2 replicas keeps drain from evicting all pods.
- Static nginx barely uses CPU, so the load test has to be aggressive, or the CPU target lowered for the demo.
