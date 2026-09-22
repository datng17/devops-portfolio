# Capacity Planning

## Metrics to track (CloudWatch, weekly)

CPU avg & p95, memory used %, disk used % and growth rate, network throughput, DB connections, slow-query count, request rate & p95 latency.

## Scaling triggers

- Sustained CPU p95 > 70% for a week -> scale up instance type or add a web node behind an ALB.
- Memory used > 80% sustained -> increase instance memory or tune workers / `innodb_buffer_pool_size`.
- Disk trend reaching 85% within 30 days -> expand EBS volume, tighten log/backup retention.
- DB connections nearing `max_connections` -> add pooling limits / a read replica for read scaling.

## Review cadence

- Weekly: dashboard review, alarm history, backup success, top slow queries, patch status.
- Monthly: capacity trend report (CPU/mem/disk/traffic), test DB restore, cost review, revisit alarm thresholds, security patch audit.
