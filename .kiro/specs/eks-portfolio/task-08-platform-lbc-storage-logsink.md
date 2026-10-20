# Task 8 - Platform layer (LBC, StorageClass, log-sink)

## Status
- [ ] Not started / - [x] Done

## Objective
Shared cluster services: the ingress controller, gp3 storage, and the log sink.

## Dependencies
Task 7.

## Files to create/modify
- `terraform/platform/{versions,backend,providers,main,variables,outputs}.tf`
- `k8s/platform/{kustomization,namespace,storageclass-gp3,log-sink}.yaml`
- `k8s/platform/log-sink-config.env` (generated, gitignored)

## Implementation guidance
- `terraform/platform`:
  - reads infra outputs through `terraform_remote_state`; depends on the Task 4 `outputs.tf` values (`vpc_id`, subnet IDs, etc.)
  - S3 backend via `backend.hcl`; on Windows/pwsh run `terraform init "-backend-config=backend.hcl"` (quoted)
  - helm and kubernetes providers authenticate with `aws eks get-token` (AWS CLI v2, see Task 6)
- Helm release `aws-load-balancer-controller` (pinned):
  - values: clusterName, region, vpcId, replicaCount 2
  - IRSA-annotated ServiceAccount
- StorageClass `gp3`:
  - provisioner `ebs.csi.aws.com`, encrypted
  - WaitForFirstConsumer, expandable, Retain
- `log-sink` StatefulSet:
  - one Fluent Bit replica with the syslog input on UDP 5140
  - outputs: a file on the 5Gi gp3 PVC and CloudWatch Logs
  - non-root with a read-only root filesystem
  - probes on `/api/v1/health`

## Test requirements
- `kubectl apply --dry-run=server -k k8s/platform`
- LBC pods are Ready.
- The PVC is Bound, and the PV's zone matches the node.
- `echo '<14>test' | nc -u -w1 log-sink.portfolio 5140`, then the line appears in `/data` and in CloudWatch.

## Demo / acceptance criteria
A syslog message lands on EBS and in CloudWatch, going through the logs endpoint.

## Interview talking points
- `WaitForFirstConsumer` creates the volume in the AZ where the pod is scheduled. Without it you get volume-node affinity conflicts.
- Retain means the data survives an accidental PVC deletion. The cost is a manual cleanup step during teardown.
- Why EBS is on `log-sink` and not on the app: RWO plus zonal storage can't be shared by replicas across AZs, and EFS would be the shared-storage answer.
