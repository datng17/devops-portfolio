# Technical Interview Q&A — DevOps Portfolio Stack

30 questions with model answers, scoped to this stack: FastAPI + Docker + Nginx +
MySQL 8.0 on AWS EC2, CI/CD via Jenkins + SonarQube, monitoring via CloudWatch.
Grouped by: **Linux Performance Tuning**, **Jenkins Quality Gate Failures**, and
**CloudWatch Alert Troubleshooting**.

---

## A. Linux Performance Tuning (1–10)

**1. A CloudWatch alarm fires for high CPU. What's your first triage step on the host?**
Run `top` / `htop` or `uptime` to read load average against core count
(`nproc`). Compare `load_1m_per_core` (see `sys_diag.py`) — sustained > 1.0 means
CPU is the bottleneck. Then `ps -eo pid,comm,%cpu --sort=-%cpu | head` to find the
offender. Distinguish user vs system vs iowait time with `top`'s CPU line before
assuming it's compute-bound.

**2. Load average is high but CPU usage looks low. What's happening?**
Load average counts runnable **and** uninterruptible (D-state) processes. Low CPU
with high load usually means I/O wait — disk or network. Confirm with
`iostat -x 1` (look at `%util`, `await`) and `top`'s `wa` figure. On EC2 also
check for EBS throughput/IOPS throttling (burst-balance exhaustion on gp2).

**3. How do you diagnose a memory leak in the FastAPI container?**
Watch `docker stats` for the container's RSS trend over time. Inside, use
`/proc/<pid>/status` (VmRSS) or the `sys_diag.py` memory section. If RSS climbs
without plateau, it's a leak. Set a container memory limit so the OOM killer
contains blast radius, capture a heap profile (`tracemalloc`), and correlate with
request patterns.

**4. What sysctl settings did you tune and why?**
See `scripts/harden.sh`: `tcp_syncookies` (SYN-flood resistance),
`tcp_max_syn_backlog` and `somaxconn` for connection bursts, `rp_filter` and
disabled source-routing/redirects for anti-spoofing, `randomize_va_space=2` for
ASLR. For a high-connection proxy you'd also raise `net.core.somaxconn` and
`net.ipv4.ip_local_port_range`.

**5. Nginx returns 502s under load. Where do you look?**
502 = upstream unreachable/erroring. Check the app container is healthy
(`/health`), then upstream capacity: uvicorn worker count vs concurrency, and
whether connections exhaust ephemeral ports. Inspect `nginx/error.log` for
"connect() failed" or "upstream timed out". Tune `proxy_read_timeout`, worker
count, and `worker_connections`.

**6. Disk usage keeps growing on the EC2 host. How do you find the cause?**
`df -h` to spot the full mount, then `du -sh /var/* | sort -h` to drill down.
Common culprits: Docker layers/volumes (`docker system df`), unrotated logs, and
MySQL binlogs. Fix with `docker system prune`, logrotate (`scripts/log_rotate.conf`),
and `binlog_expire_logs_seconds`.

**7. How do you detect and clean up zombie processes?**
Zombies are defunct children whose parent hasn't reaped them (`Z` state in
`/proc/<pid>/stat`; `sys_diag.py` reports them). They hold only a PID slot, not
memory. You can't kill a zombie directly — signal or restart the **parent** so it
`wait()`s. Many zombies indicate a bug in the parent's child handling.

**8. MySQL is slow. What OS-level and DB-level checks do you run?**
OS: `iostat` for disk saturation, `free -m` for memory pressure/swapping,
`vmstat 1` for context switches. DB: enable the slow query log (already streamed
to CloudWatch), `SHOW PROCESSLIST`, `EXPLAIN` on slow queries, and check
`innodb_buffer_pool_size` — it should hold the hot dataset (typically ~70% of RAM
on a dedicated DB host).

**9. What is the difference between `load average` and CPU utilization, and why track both?**
Utilization is the percentage of time CPUs are busy (0–100% per core). Load
average is the count of processes running or waiting to run. Utilization can sit
at 100% with load average = core count (healthy saturation), while a load far
above core count signals a queue backlog. Together they distinguish "busy" from
"overwhelmed."

**10. How would you tune the host for a connection-heavy Nginx workload?**
Raise `net.core.somaxconn` and Nginx `worker_connections`, widen
`net.ipv4.ip_local_port_range`, enable `tcp_tw_reuse`, increase the open-file
limit (`ulimit -n` / systemd `LimitNOFILE`), and set Nginx `worker_processes auto`.
Verify with `ss -s` for socket states and `ss -tan state time-wait | wc -l`.

---

## B. Jenkins Quality Gate Failures (11–20)

**11. The pipeline fails at the `Quality Gate` stage. Walk through what happened.**
`waitForQualityGate abortPipeline: true` polls SonarQube after the scan. If the
project's gate conditions (coverage, bugs, vulnerabilities, code smells,
duplication) aren't met, SonarQube returns `ERROR` and the step aborts the build.
The fix is in the code/tests, not the pipeline — open the SonarQube project to see
which condition failed.

**12. The Quality Gate step hangs and times out. Why?**
`waitForQualityGate` relies on a SonarQube **webhook** calling back into Jenkins.
If the webhook isn't configured (Administration → Configuration → Webhooks) or
Jenkins isn't reachable from SonarQube, the step waits until the `timeout(10 min)`
expires. Verify the webhook URL points to `<jenkins>/sonarqube-webhook/`.

**13. Coverage dropped below the gate threshold after a change. How do you respond?**
SonarQube's default gate enforces coverage on **new code**. Add tests for the new
lines rather than lowering the bar. Confirm `coverage.xml` is actually produced
(pytest `--cov-report=xml`) and that `sonar.python.coverage.reportPaths` points to
it. A missing report reads as 0% coverage and fails the gate.

**14. SonarQube reports 0% coverage even though tests pass. Diagnose it.**
Almost always a report path/format mismatch. Check that `coverage.xml` exists in
the scanner's working dir, `sonar.python.coverage.reportPaths=coverage.xml`
matches, and paths inside the XML are relative to `sonar.sources`. Running the
scanner from a different directory than pytest is a common cause.

**15. A legacy file trips the gate with hundreds of issues. How do you handle it without disabling quality?**
Prefer scoping over disabling. Use `sonar.exclusions` for generated/vendored code
(this project excludes tests, `.venv`, `__pycache__`, SQL, migrations). For code
you own, fix incrementally — the "clean as you code" model gates **new** code, so
legacy debt won't block you if you're not modifying it.

**16. What conditions would you put in a Quality Gate for this Python service?**
On new code: coverage ≥ 80%, 0 new bugs, 0 new vulnerabilities, security hotspots
reviewed at 100%, duplicated lines < 3%, maintainability rating A. Keep gates on
**new code** so the codebase improves continuously without an unbounded backlog.

**17. The scan passes locally but fails in Jenkins. What differs?**
Environment: Jenkins uses `withSonarQubeEnv('sonarqube')` which injects the server
URL and token; locally you may hit a different server or an older cache. Also check
the analyzed commit — Jenkins scans the checked-out `GIT_COMMIT`, and new-code
comparison depends on the correct base branch being configured in SonarQube.

**18. How do you keep the SonarQube token secure in the pipeline?**
Store it as a Jenkins credential and reference it through `withSonarQubeEnv` /
`withCredentials` — never inline it. This project uses `credentialsId` for the
registry login the same way. Tokens should be project-scoped and rotated; avoid
printing them (`set +x` around sensitive commands).

**19. Lint passes but the Quality Gate still fails on "code smells." Are they the same thing?**
No. flake8 (in the Lint stage) checks style/syntax; SonarQube code smells are
maintainability issues (complexity, duplication, dead code) scored independently.
A build can be lint-clean yet fail the gate. Address the specific smells SonarQube
flags, or justify/mark them in the SonarQube UI.

**20. How would you make the Quality Gate non-blocking temporarily during an incident hotfix?**
Set `waitForQualityGate abortPipeline: false` (or gate the abort behind a
parameter) so the result is recorded but doesn't stop deploy — used only with
sign-off. Better: use a dedicated hotfix branch with a relaxed gate, and reconcile
debt afterward. Never silently delete the gate.

---

## C. CloudWatch Alert Troubleshooting (21–30)

**21. The high-CPU alarm never fires even though the host is pegged. Why?**
Most likely the metric isn't arriving. Custom metrics like `cpu_usage_idle` come
from the **CloudWatch Agent** in the `DevOpsPortfolio` namespace — not EC2's native
`CPUUtilization`. Check the agent is running
(`amazon-cloudwatch-agent-ctl -a status`), the EC2 role has
`CloudWatchAgentServerPolicy`, and the alarm's namespace/dimensions match what the
agent emits.

**22. Explain why the CPU alarm uses `cpu_usage_idle < 20` instead of a "CPU > 80" metric.**
The agent's Telegraf-based CPU input exposes `cpu_usage_idle`, not a "used"
metric. "80% used" equals "idle below 20%," so the alarm uses
`cpu_usage_idle` with `ComparisonOperator LessThanThreshold` and
`Threshold 20`. `aws_alarms.sh` implements exactly this.

**23. The disk alarm shows `INSUFFICIENT_DATA`. What's wrong?**
The alarm's dimensions must match the agent's disk metric exactly —
`InstanceId`, `path`, `fstype`, `device`. A mismatch (e.g. `ext4` vs `xfs`, or
wrong device like `nvme0n1p1` vs `xvda1`) means no datapoints map to the alarm.
Confirm the real dimensions with `aws cloudwatch list-metrics --namespace
DevOpsPortfolio --metric-name disk_used_percent`.

**24. Memory usage is high on the host but there's no default AWS metric for it. How do you alarm on it?**
EC2 doesn't publish memory natively — the hypervisor can't see guest RAM. The
CloudWatch Agent collects `mem_used_percent` (configured in
`amazon-cloudwatch-agent.json`). Build the alarm on that custom metric in the
`DevOpsPortfolio` namespace, exactly as with disk.

**25. You're getting alarm flapping (rapid ALARM/OK cycles). How do you fix it?**
Add hysteresis: increase `evaluation-periods` and set `datapoints-to-alarm`
(this project uses 3 of 3 over 5-minute periods). Use an appropriate statistic
(Average over p-something rather than Maximum), and consider a longer period.
Flapping usually means the threshold sits right at the steady-state value.

**26. Logs aren't showing up in CloudWatch Logs. Walk through the checks.**
Verify the agent config `logs.logs_collected.files.collect_list` paths exist and
are readable by the `cwagent` user, the log group/stream names are correct, and
the IAM role allows `logs:CreateLogStream`/`PutLogEvents`. Check the agent's own
log at `/opt/aws/amazon-cloudwatch-agent/logs/`. File permission on
`/var/log/nginx` is a frequent cause.

**27. How do you alarm on application 5xx errors that only appear in Nginx logs?**
Create a **metric filter** on the nginx access log group that matches status
codes ≥ 500, emit a custom metric, then alarm on its `Sum` over a window
(`alarms.md` documents ">10 in 5 min"). This turns unstructured log lines into a
numeric metric CloudWatch can evaluate.

**28. What IAM permissions does the EC2 instance need for full CloudWatch monitoring?**
The instance role needs `CloudWatchAgentServerPolicy` (covers
`cloudwatch:PutMetricData`, `logs:CreateLogGroup/Stream`, `logs:PutLogEvents`,
`ec2:DescribeTags` for `append_dimensions`, and SSM parameter reads for the
config). Creating alarms via `aws_alarms.sh` additionally needs
`cloudwatch:PutMetricAlarm`, run with a user/role that has it.

**29. An alarm fires but no SNS notification arrives. Where's the break?**
Check the alarm actually has `--alarm-actions` set to the SNS ARN
(`aws_alarms.sh` sets both alarm and OK actions). Then verify the SNS topic has a
**confirmed** subscription (email subscriptions must be confirmed) and the topic
policy permits CloudWatch to publish. Test with `aws sns publish` to isolate SNS
from the alarm.

**30. How would you validate the whole alerting path end to end before relying on it?**
Force the condition safely: `stress-ng --cpu N` to breach CPU, or `fallocate` a
large file to breach disk on a scratch mount. Watch the alarm transition to ALARM
in the console, confirm the SNS notification lands, then clean up and confirm it
returns to OK (the OK action verifies recovery notifications too). Document the
drill in `docs/runbook.md`.
