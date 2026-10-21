#!/usr/bin/env bash
# Curl loop for the resilience drills: requests URL every INTERVAL seconds with
# a fresh connection each time, then prints the count per HTTP status.
# "000" means no HTTP response (connection refused/reset, timeout, TLS error).
#
# Usage: scripts/availability-probe.sh <url> [duration-seconds]
#   duration 0 (default) = run until Ctrl-C / SIGTERM
# Env: INTERVAL (default 0.2), MAX_TIME per request (default 5), LOG (optional
#      file for "time code seconds" lines)
#
# Exit codes: 0 every response was 200; 1 at least one non-200.
set -uo pipefail

URL="${1:?usage: $0 <url> [duration-seconds]}"
DURATION="${2:-0}"
INTERVAL="${INTERVAL:-0.2}"
MAX_TIME="${MAX_TIME:-5}"
LOG="${LOG:-}"

declare -A counts=()
total=0
bad=0
first_bad=""
last_bad=""
start=$(date +%s)
stop=0
trap 'stop=1' INT TERM

report() {
  echo "::: availability-probe $URL: $total requests in $(( $(date +%s) - start ))s"
  for code in "${!counts[@]}"; do echo "    $code: ${counts[$code]}"; done
  echo "    non-200: $bad${first_bad:+ (first $first_bad, last $last_bad)}"
}

while [[ "$stop" -eq 0 ]]; do
  if [[ "$DURATION" -gt 0 && $(( $(date +%s) - start )) -ge "$DURATION" ]]; then break; fi
  out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "$MAX_TIME" "$URL" 2>/dev/null)"
  code="${out%% *}"
  [[ -z "$code" ]] && code=000
  counts[$code]=$(( ${counts[$code]:-0} + 1 ))
  total=$(( total + 1 ))
  if [[ "$code" != 200 ]]; then
    bad=$(( bad + 1 ))
    ts="$(date +%H:%M:%S)"
    first_bad="${first_bad:-$ts}"
    last_bad="$ts"
    echo "$ts non-200: $code" >&2
  fi
  [[ -n "$LOG" ]] && echo "$(date +%H:%M:%S) $out" >>"$LOG"
  sleep "$INTERVAL"
done

report
[[ "$bad" -eq 0 ]]
