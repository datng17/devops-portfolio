#!/usr/bin/env bash
# Tears down the eks-portfolio environment so it stops costing money
# (about $249/mo, $0.34/h, with the ALB and 3 interface endpoints).
#
# Order: controller-created AWS resources (ALB, EBS) live outside Terraform
# state, so they go first; otherwise terraform destroy hangs on VPC
# dependencies (ALB ENIs in the subnets).
#   1. stop local Jenkins (a pollSCM build would recreate the Ingress)
#   2. delete Ingresses / LoadBalancer Services, wait for the ALB and its ENIs
#   3. delete namespace portfolio (app, log-sink, PVC), StorageClass gp3 and
#      the Released PVs
#   4. delete the EBS volumes behind them (gp3 is reclaimPolicy Retain)
#   5. delete the jenkins-ci access keys (created outside Terraform; they
#      block the IAM user deletion)
#   6. terraform destroy terraform/platform (LBC Helm release, env file)
#   7. terraform destroy terraform/infra (EKS, nodes, VPC, NAT, endpoints,
#      ECR, IAM, log groups; the KMS key goes to PendingDeletion, 30 days)
#   8. delete the control plane log group if EKS recreated it, then check
#      for leftovers
#
# Kept: the S3 state bucket (prevent_destroy; removal is manual, see
# docs/deployment-guide.md), the ACM certificate (Terraform only reads it)
# and the DNS records at the DNS provider.
#
# Usage (Windows: Git Bash, plain `bash` may be WSL):
#   "C:\Program Files\Git\bin\bash.exe" scripts/teardown.sh     prompts first
#   scripts/teardown.sh --yes     no prompts, terraform -auto-approve
#   scripts/teardown.sh --check   read-only leftover check, changes nothing
# Env: AWS_REGION (us-east-1), CLUSTER_NAME (terraform output, else
#      eks-portfolio), NAMESPACE (portfolio), PROJECT (eks-portfolio),
#      ENVIRONMENT (dev), DOMAIN (test.name.vn), WAIT_TIMEOUT seconds (600)
# Exit: 0 done and clean; 1 aborted, a step failed or leftovers found;
#       2 usage or preflight error.

set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash would rewrite args such as /aws/eks/... or /readyz into Windows
# paths before handing them to aws.exe / kubectl.exe.
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAMESPACE="${NAMESPACE:-portfolio}"
PROJECT="${PROJECT:-eks-portfolio}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DOMAIN="${DOMAIN:-test.name.vn}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
INFRA_DIR=terraform/infra
PLATFORM_DIR=terraform/platform
JENKINS_CONTAINER=eks-portfolio-jenkins
STORAGE_CLASS=gp3

MODE=teardown
ASSUME_YES=0

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }

for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=1 ;;
    --check) MODE=check ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\n::: %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
mask() { sed -E 's/[0-9]{12}/************/g'; }

# aws.exe prints CRLF on Windows. awsl: one value per line, "None" dropped.
awsl() { aws --region "$REGION" --output text "$@" | tr -d '\r' | tr '\t' '\n' | sed '/^None$/d;/^$/d'; }
awst() { aws --region "$REGION" --output text "$@" | tr -d '\r'; }
tf_out() { terraform -chdir="$INFRA_DIR" output -raw "$1" 2>/dev/null | tr -d '\r' || true; }

tagged_arns() { # <resource type> <tag key> <tag value>
  awsl resourcegroupstaggingapi get-resources --resource-type-filters "$1" \
    --tag-filters "Key=$2,Values=$3" --query 'ResourceTagMappingList[].ResourceARN' 2>/dev/null || true
}

log_group_exists() {
  [[ -n "$(awsl logs describe-log-groups --log-group-name-prefix "$1" \
    --query "logGroups[?logGroupName=='$1'].logGroupName" 2>/dev/null || true)" ]]
}

# CSI-provisioned volumes of this cluster (node root volumes don't carry these tags).
cluster_pvc_volumes() {
  awsl ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
    "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" --query 'Volumes[].VolumeId' 2>/dev/null || true
}

project_vpcs() {
  { [[ -n "$VPC_ID" ]] && printf '%s\n' "$VPC_ID"
    awsl ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId' 2>/dev/null || true
  } | sort -u
}

project_kms_keys() {
  { [[ -n "${KMS_KEY_ID:-}" ]] && printf '%s\n' "$KMS_KEY_ID"
    awsl kms describe-key --key-id "alias/eks/$CLUSTER" --query KeyMetadata.KeyId 2>/dev/null || true
    tagged_arns kms:key Project "$PROJECT" | sed 's#.*key/##'
  } | sed '/^$/d' | sort -u
}

# ---------------------------------------------------------------- preflight
preflight() {
  local c
  for c in aws kubectl terraform; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found on PATH"
  done
  CALLER="$(awst sts get-caller-identity --query Arn 2>/dev/null)" || die "AWS credentials don't work (aws sts get-caller-identity)"
  ACCOUNT_ID="$(awst sts get-caller-identity --query Account)"

  if [[ "$MODE" == teardown ]]; then
    for c in "$INFRA_DIR" "$PLATFORM_DIR"; do
      [[ -d "$c/.terraform" ]] || die "$c is not initialised. Run: terraform -chdir=$c init \"-backend-config=backend.hcl\""
    done
    [[ -f "$INFRA_DIR/terraform.tfvars" ]] || die "$INFRA_DIR/terraform.tfvars is missing (admin_cidrs is required, even for destroy)"
  fi

  CLUSTER="${CLUSTER_NAME:-$(tf_out cluster_name)}"
  CLUSTER="${CLUSTER:-eks-portfolio}"
  VPC_ID="$(tf_out vpc_id)"
  JENKINS_USER="$(tf_out jenkins_ci_user_name)"
  JENKINS_USER="${JENKINS_USER:-jenkins-ci}"
  ECR_REPO="$(tf_out ecr_repository_name)"
  ECR_REPO="${ECR_REPO:-portfolio}"
  OIDC_ISSUER="$(tf_out cluster_oidc_issuer_url)"
  KMS_KEY_ID="$(awsl kms describe-key --key-id "alias/eks/$CLUSTER" --query KeyMetadata.KeyId 2>/dev/null || true)"
  CLUSTER_STATUS="$(awsl eks describe-cluster --name "$CLUSTER" --query cluster.status 2>/dev/null || true)"

  info "AWS identity: $(mask <<<"$CALLER")"
  info "Region $REGION, cluster $CLUSTER (${CLUSTER_STATUS:-not found}), VPC ${VPC_ID:-unknown}"
}

# Temporary kubeconfig, so the user's ~/.kube/config is left alone.
connect_cluster() {
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  local kcfg="$TMP_DIR/kubeconfig"
  if command -v cygpath >/dev/null 2>&1; then kcfg="$(cygpath -m "$kcfg")"; fi
  export KUBECONFIG="$kcfg"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$kcfg" >/dev/null
  if ! kubectl get --raw /readyz --request-timeout=15s >/dev/null 2>&1; then
    local ip
    ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n' || true)"
    die "The EKS API isn't reachable. The public endpoint only allows admin_cidrs and your IP may have changed (now: ${ip:-unknown}).
Fix: set admin_cidrs = [\"${ip:-<your ip>}/32\"] in $INFRA_DIR/terraform.tfvars, run
  terraform -chdir=$INFRA_DIR apply
and re-run this script. Nothing has been deleted."
  fi
  info "EKS API reachable"
}

# ------------------------------------------------------------------ summary
print_plan() {
  local n_ep has_alb
  n_ep="$(awsl ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=vpc-endpoint-type,Values=Interface" "Name=vpc-endpoint-state,Values=available,pending" \
    --query 'VpcEndpoints[].VpcEndpointId' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  has_alb=0
  [[ -n "$(tagged_arns elasticloadbalancing:loadbalancer elbv2.k8s.aws/cluster "$CLUSTER")" ]] && has_alb=1

  log "Teardown plan for $CLUSTER in $REGION"
  cat <<EOF
    DELETES
      - Ingress(es) and the ALB the controller made from them (+ target groups, ENIs)
      - namespace $NAMESPACE: portfolio Deployment/HPA/PDB/Service, log-sink
        StatefulSet and its PVC; StorageClass $STORAGE_CLASS; the Released PVs
      - EBS volumes behind those PVs (log-sink data; the logs are also in
        CloudWatch, which is deleted too)
      - all access keys of IAM user $JENKINS_USER (local jenkins/secrets go stale)
      - terraform/platform: AWS Load Balancer Controller Helm release
      - terraform/infra (about 88 resources): EKS cluster + add-ons + node group,
        VPC, subnets, NAT Gateway + EIP, S3 gateway and $n_ep interface endpoint(s),
        security groups, ECR repo '$ECR_REPO' WITH its images (force_delete),
        IAM roles/user/OIDC provider, log groups /aws/eks/$CLUSTER/cluster and
        /eks/$CLUSTER/portfolio-nginx; KMS key -> PendingDeletion (30 days)
      - stops local Jenkins container $JENKINS_CONTAINER if it is running
    KEEPS
      - S3 state bucket $PROJECT-tfstate-<account>-$REGION (prevent_destroy)
      - ACM certificate for $DOMAIN (managed outside Terraform) and DNS records
EOF
  awk -v n="$n_ep" -v alb="$has_alb" 'BEGIN {
    t = 175.94 + alb * 29.57 + n * 2 * 7.30
    printf "    COST that stops: about $%.0f/mo ($%.2f/h, $%.2f/day)\n", t, t / 730, t * 24 / 730 }'
}

confirm() {
  print_plan
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "--yes given: not prompting, terraform runs with -auto-approve"
    return 0
  fi
  local answer=""
  printf '\n'
  if ! read -r -p "This is irreversible. Type the cluster name ($CLUSTER) to continue: " answer; then
    echo; echo "Aborted (no input). Nothing was changed."; exit 1
  fi
  [[ "$answer" == "$CLUSTER" ]] || { echo "Aborted. Nothing was changed."; exit 1; }
}

# -------------------------------------------------------------------- steps
step_jenkins() {
  log "[1/8] Stop local Jenkins"
  if command -v docker >/dev/null 2>&1 &&
    [[ -n "$(docker ps -q --filter "name=^${JENKINS_CONTAINER}\$" 2>/dev/null | tr -d '\r' || true)" ]]; then
    docker stop "$JENKINS_CONTAINER" >/dev/null
    info "stopped $JENKINS_CONTAINER (start again: docker compose -f jenkins/docker-compose.yml up -d)"
  else
    info "not running"
  fi
}

wait_for_elb_enis() {
  local vpc deadline left
  deadline=$(($(date +%s) + WAIT_TIMEOUT))
  for vpc in $(project_vpcs); do
    while :; do
      left="$(awsl ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" \
        "Name=description,Values=ELB *" --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$left" -eq 0 ]] && { info "no load balancer ENIs left in $vpc"; break; }
      if [[ $(date +%s) -ge $deadline ]]; then
        warn "$left load balancer ENI(s) still in $vpc; terraform destroy will retry the subnets"
        break
      fi
      sleep 10
    done
  done
}

step_ingress() {
  log "[2/8] Delete Ingresses and LoadBalancer Services, wait for the ALB to go"
  local albs svcs ns name
  albs="$(tagged_arns elasticloadbalancing:loadbalancer elbv2.k8s.aws/cluster "$CLUSTER")"
  # The controller deletes the ALB and target groups, then drops the finalizer.
  kubectl delete ingress --all --all-namespaces --wait=true --timeout="${WAIT_TIMEOUT}s"
  svcs="$(kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')"
  while read -r ns name; do
    [[ -n "$ns" ]] || continue
    kubectl -n "$ns" delete svc "$name" --wait=true --timeout="${WAIT_TIMEOUT}s"
  done <<<"$svcs"
  if [[ -n "$albs" ]]; then
    info "waiting for $(wc -l <<<"$albs" | tr -d ' ') load balancer(s) to be deleted"
    # shellcheck disable=SC2086 # one ARN per word
    aws elbv2 wait load-balancers-deleted --region "$REGION" --load-balancer-arns $albs
    info "load balancer(s) deleted"
  else
    info "no controller-managed load balancers found"
  fi
  wait_for_elb_enis
}

PVS=()
VOLS=()
step_k8s_resources() {
  log "[3/8] Delete namespace $NAMESPACE, StorageClass $STORAGE_CLASS and their PVs"
  local lines pv sc ns vol
  # '|' separated: an empty field must not shift the others.
  lines="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.storageClassName}{"|"}{.spec.claimRef.namespace}{"|"}{.spec.csi.volumeHandle}{"\n"}{end}')"
  while IFS='|' read -r pv sc ns vol; do
    [[ -n "$pv" ]] || continue
    if [[ "$sc" == "$STORAGE_CLASS" || "$ns" == "$NAMESPACE" ]]; then
      PVS+=("$pv")
      [[ -n "$vol" ]] && VOLS+=("$vol")
    fi
  done <<<"$lines"
  info "PVs to delete: ${PVS[*]:-none}"

  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout="${WAIT_TIMEOUT}s"
  info "namespace $NAMESPACE deleted"
  kubectl delete storageclass "$STORAGE_CLASS" --ignore-not-found
  for pv in "${PVS[@]}"; do
    kubectl delete pv "$pv" --ignore-not-found --wait=true --timeout=300s
  done
}

step_ebs() {
  log "[4/8] Delete the retained EBS volumes"
  local vols v state
  vols="$({ printf '%s\n' "${VOLS[@]}"; cluster_pvc_volumes; } | sed '/^$/d' | sort -u)"
  if [[ -z "$vols" ]]; then info "none"; return 0; fi
  for v in $vols; do
    state="$(awsl ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' 2>/dev/null || true)"
    if [[ -z "$state" ]]; then info "$v already gone"; continue; fi
    if [[ "$state" != available ]]; then
      info "$v is $state, waiting for it to detach"
      if ! aws ec2 wait volume-available --region "$REGION" --volume-ids "$v"; then
        warn "$v did not become available; left in place (see the leftover check)"
        continue
      fi
    fi
    aws ec2 delete-volume --region "$REGION" --volume-id "$v"
    info "deleted $v"
  done
}

step_access_keys() {
  log "[5/8] Delete access keys of IAM user $JENKINS_USER"
  local keys k
  keys="$(awsl iam list-access-keys --user-name "$JENKINS_USER" --query 'AccessKeyMetadata[].AccessKeyId' 2>/dev/null || true)"
  if [[ -z "$keys" ]]; then info "none"; return 0; fi
  for k in $keys; do
    aws iam delete-access-key --user-name "$JENKINS_USER" --access-key-id "$k"
    info "deleted access key ${k:0:4}...${k: -4}"
  done
  info "jenkins/secrets/jenkins_ci_* are stale now; after a rebuild run: pwsh scripts/render-jenkins-secrets.ps1 -CreateAccessKey"
}

TF_ARGS=()
step_tf_platform() {
  log "[6/8] terraform destroy $PLATFORM_DIR"
  terraform -chdir="$PLATFORM_DIR" destroy "${TF_ARGS[@]}"
}

step_tf_infra() {
  log "[7/8] terraform destroy $INFRA_DIR (EKS create/delete takes 10-15 min each)"
  terraform -chdir="$INFRA_DIR" destroy "${TF_ARGS[@]}"
  # EKS can write one more batch of control plane logs after Terraform has
  # deleted the group, which recreates it without retention.
  local lg="/aws/eks/$CLUSTER/cluster"
  if log_group_exists "$lg"; then
    aws logs delete-log-group --region "$REGION" --log-group-name "$lg"
    info "deleted recreated log group $lg"
  fi
}

# ---------------------------------------------------------- leftover check
LEFT=0
found() { LEFT=$((LEFT + 1)); printf '    LEFTOVER %s\n' "$*"; }
ok() { printf '    ok       %s\n' "$*"; }
kept() { printf '    kept     %s\n' "$*"; }

check_list() { # <description> <values...>: leftover if any value is given
  local what="$1"; shift
  if [[ $# -gt 0 && -n "$*" ]]; then found "$what: $(echo "$*" | tr '\n' ' ' | mask)"; else ok "$what: none"; fi
}

check_leftovers() {
  LEFT=0
  log "[8/8] Leftover check (region $REGION, cluster $CLUSTER, project tag $PROJECT)"
  local s arn live vpcs vpc enis vols k state lg name host

  s="$(awsl eks describe-cluster --name "$CLUSTER" --query cluster.status 2>/dev/null || true)"
  check_list "EKS cluster" "$s"

  live=""
  for arn in $(tagged_arns elasticloadbalancing:loadbalancer elbv2.k8s.aws/cluster "$CLUSTER"); do
    aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" >/dev/null 2>&1 && live+="${arn##*:loadbalancer/} "
  done
  check_list "load balancers tagged elbv2.k8s.aws/cluster=$CLUSTER" "$live"

  live=""
  for arn in $(tagged_arns elasticloadbalancing:targetgroup elbv2.k8s.aws/cluster "$CLUSTER"); do
    aws elbv2 describe-target-groups --region "$REGION" --target-group-arns "$arn" >/dev/null 2>&1 && live+="${arn##*:targetgroup/} "
  done
  check_list "target groups tagged elbv2.k8s.aws/cluster=$CLUSTER" "$live"

  check_list "security groups tagged elbv2.k8s.aws/cluster=$CLUSTER" \
    "$(awsl ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'SecurityGroups[].GroupId' 2>/dev/null || true)"

  vpcs="$(project_vpcs)"
  live=""
  for vpc in $vpcs; do
    awsl ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[].VpcId' >/dev/null 2>&1 && live+="$vpc "
  done
  check_list "VPC" "$live"

  enis="$(awsl ec2 describe-network-interfaces --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null || true)"
  for vpc in $live; do
    enis+=$'\n'"$(awsl ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null || true)"
  done
  check_list "ENIs (cluster tag or in the VPC)" "$(sed '/^$/d' <<<"$enis" | sort -u)"

  vols="$(awsl ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Volumes[].VolumeId' 2>/dev/null || true)"
  vols+=$'\n'"$(awsl ec2 describe-volumes --filters "Name=tag:ebs.csi.aws.com/cluster-name,Values=$CLUSTER" --query 'Volumes[].VolumeId' 2>/dev/null || true)"
  check_list "EBS volumes tagged for $CLUSTER" "$(sed '/^$/d' <<<"$vols" | sort -u)"

  check_list "EC2 instances (eks:cluster-name=$CLUSTER)" \
    "$(awsl ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
      "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' 2>/dev/null || true)"

  check_list "NAT gateways (Project=$PROJECT)" \
    "$(awsl ec2 describe-nat-gateways --filter "Name=tag:Project,Values=$PROJECT" "Name=state,Values=pending,available" \
      --query 'NatGateways[].NatGatewayId' 2>/dev/null || true)"

  check_list "Elastic IPs (Project=$PROJECT)" \
    "$(awsl ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT" --query 'Addresses[].PublicIp' 2>/dev/null || true)"

  check_list "VPC endpoints (Project=$PROJECT)" \
    "$(awsl ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=$PROJECT" \
      "Name=vpc-endpoint-state,Values=pendingAcceptance,pending,available" --query 'VpcEndpoints[].VpcEndpointId' 2>/dev/null || true)"

  for lg in "/aws/eks/$CLUSTER/cluster" "/eks/$CLUSTER/portfolio-nginx"; do
    if log_group_exists "$lg"; then found "log group $lg"; else ok "log group $lg: gone"; fi
  done

  for k in $(project_kms_keys); do
    state="$(awst kms describe-key --key-id "$k" --query 'KeyMetadata.[KeyState,DeletionDate]' 2>/dev/null || true)"
    case "$state" in
      PendingDeletion*) ok "KMS key $k: PendingDeletion, deleted on $(cut -f2 <<<"$state") (not billed while pending)" ;;
      "") ok "KMS key $k: gone" ;;
      *) found "KMS key $k: $(cut -f1 <<<"$state") (\$1/mo; aws kms schedule-key-deletion --key-id $k --pending-window-in-days 7)" ;;
    esac
  done

  if aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1; then
    found "ECR repository $ECR_REPO"
  else ok "ECR repository $ECR_REPO: gone"; fi

  if aws iam get-user --user-name "$JENKINS_USER" >/dev/null 2>&1; then found "IAM user $JENKINS_USER"; else ok "IAM user $JENKINS_USER: gone"; fi
  for name in jenkins-deployer "$PROJECT-$ENVIRONMENT-ebs-csi" "$PROJECT-$ENVIRONMENT-lbc" "$PROJECT-$ENVIRONMENT-log-sink"; do
    if aws iam get-role --role-name "$name" >/dev/null 2>&1; then found "IAM role $name"; else ok "IAM role $name: gone"; fi
  done
  check_list "IAM roles named $CLUSTER-cluster-* / default-eks-node-group-*" \
    "$(awsl iam list-roles --query "Roles[?starts_with(RoleName, '$CLUSTER-cluster-') || starts_with(RoleName, 'default-eks-node-group-')].RoleName" 2>/dev/null || true)"
  if [[ -n "$OIDC_ISSUER" ]]; then
    host="${OIDC_ISSUER#https://}"
    check_list "IAM OIDC provider $host" \
      "$(awsl iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' 2>/dev/null | grep -F "$host" || true)"
  fi

  if aws s3api head-bucket --bucket "$PROJECT-tfstate-$ACCOUNT_ID-$REGION" >/dev/null 2>&1; then
    kept "S3 state bucket $PROJECT-tfstate-<account>-$REGION (cents/month; manual removal in docs/deployment-guide.md)"
  fi
  s="$(awsl acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN'].Status" 2>/dev/null || true)"
  [[ -n "$s" ]] && kept "ACM certificate for $DOMAIN ($(paste -sd ' ' <<<"$s"), free)"

  if [[ "$LEFT" -eq 0 ]]; then
    log "Clean: nothing billable left for $CLUSTER"
    return 0
  fi
  log "$LEFT leftover group(s) found (see LEFTOVER lines above)"
  return 1
}

# --------------------------------------------------------------------- main
log "Preflight"
preflight

if [[ "$MODE" == check ]]; then
  if check_leftovers; then exit 0; else exit 1; fi
fi

if [[ -n "$CLUSTER_STATUS" ]]; then
  connect_cluster
else
  warn "cluster $CLUSTER not found: the Kubernetes steps (2-3) will be skipped"
fi
confirm
if [[ "$ASSUME_YES" -eq 1 ]]; then TF_ARGS=(-auto-approve -input=false); fi

step_jenkins
if [[ -n "$CLUSTER_STATUS" ]]; then
  step_ingress
  step_k8s_resources
fi
step_ebs
step_access_keys
step_tf_platform
step_tf_infra
if check_leftovers; then exit 0; else exit 1; fi
