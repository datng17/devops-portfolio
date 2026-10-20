# Task 9 - App manifests and HTTPS Ingress

## Status
- [ ] Not started / - [x] Done

## Objective
The HA workload is live on `https://test.name.vn`.

## Dependencies
Tasks 2, 4, 5, 8.

## Files to create/modify
- `k8s/app/{kustomization,serviceaccount,nginx-logging,deployment,service,pdb,hpa,ingress}.yaml`
- `k8s/app/ingress-config.env` (generated from Terraform outputs, gitignored)
- `scripts/render-k8s-config.ps1`

## Implementation guidance
- Deployment:
  - 2 replicas; RollingUpdate with maxSurge 1, maxUnavailable 0; progressDeadline 120s
  - requests 50m/64Mi, limits 200m/128Mi
  - `/healthz` readiness and liveness probes
  - restricted securityContext
  - `/tmp` as an emptyDir
  - preferred zone and host anti-affinity, plus a zone topology spread
- Service: ClusterIP 80→8080.
- PDB: `minAvailable: 1`.
- HPA (v2): 2-5 replicas, CPU 60%, memory 75%, scale-down window 120s.
- Ingress, with the ALB annotations: internet-facing, target-type ip, 80/443, ssl-redirect, cert ARN, TLS13 policy, group `portfolio`, `/healthz` health check, Terraform SG, and `manage-backend-security-group-rules: "false"`.
- The cert ARN and SG ID come in through kustomize `replacements` from a generated ConfigMap.

## Test requirements
- Server dry-run.
- Apply with the Task 4 image.
- The user adds the CNAME.
- `scripts/smoke-test.sh https://test.name.vn` passes.
- `curl -I http://test.name.vn` returns 301.
- Pods run in both AZs.
- Logs appear in log-sink.

## Demo / acceptance criteria
The live HTTPS site, with HTTP redirecting to HTTPS.

## Interview talking points
- `maxUnavailable: 0` plus readiness gating means capacity never drops during a rollout.
- With `target-type: ip` the ALB sends traffic straight to pod IPs, skipping NodePort and the extra kube-proxy hop. That's why the node SG rule is on 8080.
- Preferred, not required, anti-affinity, because HPA can go above the number of AZs.
- `group.name` keeps a stable ALB, so the manually created CNAME doesn't go stale.
