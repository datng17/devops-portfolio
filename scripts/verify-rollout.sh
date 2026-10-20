#!/usr/bin/env bash
# Waits for the portfolio Deployment rollout. If it fails (e.g. ImagePullBackOff
# until progressDeadlineSeconds), prints diagnostics, undoes the rollout to the
# revision that was live before the deploy and exits non-zero.
#
# maxUnavailable: 0 keeps the old ReplicaSet serving the whole time, so a failed
# rollout never takes the site down.
#
# Env:
#   NAMESPACE        default portfolio
#   DEPLOYMENT       default portfolio
#   TIMEOUT          seconds to wait for each rollout (default 300; the
#                    Deployment's progressDeadlineSeconds of 120 normally ends it first)
#   PREV_REVISION    revision live before the deploy (empty = first deploy, no undo)
#   EXPECTED_IMAGE   optional; on success the Deployment must run this image
#
# Exit codes: 0 rolled out; 1 rollout failed and was undone; 2 undo failed too.
set -euo pipefail

NAMESPACE="${NAMESPACE:-portfolio}"
DEPLOYMENT="${DEPLOYMENT:-portfolio}"
TIMEOUT="${TIMEOUT:-300}"
PREV_REVISION="${PREV_REVISION:-}"
EXPECTED_IMAGE="${EXPECTED_IMAGE:-}"

k() { kubectl -n "$NAMESPACE" "$@"; }
revision() { k get deployment "$DEPLOYMENT" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'; }
image() { k get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[?(@.name=="portfolio")].image}'; }

echo "Waiting for deployment/$DEPLOYMENT (revision $(revision), image $(image))"
if k rollout status "deployment/$DEPLOYMENT" --timeout="${TIMEOUT}s"; then
  current_image="$(image)"
  if [[ -n "$EXPECTED_IMAGE" && "$current_image" != "$EXPECTED_IMAGE" ]]; then
    echo "FAIL: deployment runs $current_image, expected $EXPECTED_IMAGE" >&2
    exit 1
  fi
  echo "Rollout complete: revision $(revision), image $current_image"
  exit 0
fi

echo "::: Rollout of deployment/$DEPLOYMENT failed. Diagnostics:" >&2
k get deployment "$DEPLOYMENT" -o wide >&2 || true
k get replicasets -l app.kubernetes.io/name=portfolio -o wide >&2 || true
k get pods -l app.kubernetes.io/name=portfolio -o wide >&2 || true
k get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 20 >&2 || true

failed_revision="$(revision)"
if [[ -z "$PREV_REVISION" ]]; then
  echo "No previous revision recorded (first deploy?); nothing to undo." >&2
  exit 1
fi
if [[ "$failed_revision" == "$PREV_REVISION" ]]; then
  echo "Revision unchanged ($failed_revision); the deploy did not create a new rollout, nothing to undo." >&2
  exit 1
fi

echo "::: Undoing rollout: revision $failed_revision -> $PREV_REVISION" >&2
if ! k rollout undo "deployment/$DEPLOYMENT" --to-revision="$PREV_REVISION"; then
  echo "FAIL: rollout undo failed" >&2
  exit 2
fi
if ! k rollout status "deployment/$DEPLOYMENT" --timeout="${TIMEOUT}s"; then
  echo "FAIL: rollback did not become ready" >&2
  exit 2
fi
echo "Rolled back to $(image) (now revision $(revision)). Failing the build." >&2
exit 1
