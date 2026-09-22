# CloudWatch Alarm Thresholds

All alarms notify an SNS topic (e.g. `arn:aws:sns:us-east-1:123456789012:ops-alerts`).

| Alarm | Metric | Threshold | Period | Action |
|-------|--------|-----------|--------|--------|
| High CPU | `cpu_usage_idle` | < 20% (>80% used) for 3 datapoints | 5 min | SNS notify |
| High Memory | `mem_used_percent` | > 85% for 3 datapoints | 5 min | SNS notify |
| Disk near full | `disk used_percent` (/ or /var) | > 85% | 5 min | SNS + cleanup runbook |
| Swap in use | `swap_used_percent` | > 20% | 5 min | SNS notify |
| App 5xx spike | Log metric filter on nginx status >= 500 | > 10 in 5 min | SNS page |
| DB slow queries | Log metric filter on slow.log count | > 50 in 15 min | SNS notify |
| Instance status | `StatusCheckFailed` (EC2 native) | >= 1 | 1 min | auto-recover + notify |

## Example: create the high-CPU alarm

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "webapp-high-cpu" \
  --namespace DevOpsPortfolio \
  --metric-name cpu_usage_idle \
  --statistic Average --period 300 --evaluation-periods 3 \
  --threshold 20 --comparison-operator LessThanThreshold \
  --dimensions Name=InstanceId,Value=i-0abc123 \
  --alarm-actions arn:aws:sns:us-east-1:119640367180:ops-alerts
```

## Dashboard widgets

- CPU / memory / disk used % per host
- Network throughput (bytes_sent / bytes_recv)
- Nginx request rate + 5xx count (from log metric filters)
- MySQL slow-query count

## Applying the agent config

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
```

The EC2 instance role needs the `CloudWatchAgentServerPolicy` attached.
