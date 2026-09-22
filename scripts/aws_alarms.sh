#!/usr/bin/env bash
# devops-portfolio/scripts/aws_alarms.sh
# Create CloudWatch alarms for CPU > 80% and Disk > 85% on an EC2 instance.
# Metrics come from the CloudWatch Agent (namespace: DevOpsPortfolio).
# Requires: awscli v2, credentials/role with cloudwatch:PutMetricAlarm.
#
# Usage:
#   INSTANCE_ID=i-0abc123 \
#   SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:ops-alerts \
#   AWS_REGION=us-east-1 \
#   ./aws_alarms.sh
set -euo pipefail

INSTANCE_ID="${INSTANCE_ID:?set INSTANCE_ID (e.g. i-0abc123)}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:?set SNS_TOPIC_ARN (arn:aws:sns:...:ops-alerts)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-DevOpsPortfolio}"

# Disk dimensions must match how the CW agent tags disk metrics.
DISK_PATH="${DISK_PATH:-/}"
DISK_FSTYPE="${DISK_FSTYPE:-xfs}"   # e.g. xfs (Amazon Linux/RHEL) or ext4 (Ubuntu)
DISK_DEVICE="${DISK_DEVICE:-nvme0n1p1}"

echo "[*] Region=$AWS_REGION Namespace=$NAMESPACE Instance=$INSTANCE_ID"

# ---- CPU > 80% used ---------------------------------------------------------
# CW agent reports cpu_usage_idle; >80% used == idle < 20%.
echo "[*] Creating alarm: webapp-high-cpu (CPU used > 80%)"
aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "webapp-high-cpu" \
  --alarm-description "CPU utilization > 80% (idle < 20%) for 15 min" \
  --namespace "$NAMESPACE" \
  --metric-name "cpu_usage_idle" \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 3 \
  --threshold 20 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data missing \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --ok-actions "$SNS_TOPIC_ARN"

# ---- Disk > 85% used --------------------------------------------------------
echo "[*] Creating alarm: webapp-high-disk (Disk used > 85% on ${DISK_PATH})"
aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "webapp-high-disk" \
  --alarm-description "Disk used_percent > 85% on ${DISK_PATH} for 15 min" \
  --namespace "$NAMESPACE" \
  --metric-name "disk_used_percent" \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 3 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --dimensions \
      "Name=InstanceId,Value=${INSTANCE_ID}" \
      "Name=path,Value=${DISK_PATH}" \
      "Name=fstype,Value=${DISK_FSTYPE}" \
      "Name=device,Value=${DISK_DEVICE}" \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --ok-actions "$SNS_TOPIC_ARN"

echo "[+] Alarms created. Verify:"
echo "    aws cloudwatch describe-alarms --region $AWS_REGION \\"
echo "      --alarm-names webapp-high-cpu webapp-high-disk \\"
echo "      --query 'MetricAlarms[].[AlarmName,StateValue]' --output table"
