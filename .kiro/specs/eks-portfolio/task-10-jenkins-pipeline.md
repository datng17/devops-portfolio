# Task 10 - Jenkins and pipeline

## Status
- [ ] Not started / - [x] Done

## Objective
A commit ends in a verified deployment. A bad deployment rolls back automatically.

## Dependencies
Tasks 1, 2, 6, 9.

## Files to create/modify
- `jenkins/Dockerfile`, `jenkins/plugins.txt`, `jenkins/docker-compose.yml`
- `Jenkinsfile`
- `scripts/verify-rollout.sh`

## Implementation guidance
- Custom Jenkins image based on `jenkins/jenkins:lts-jdk21`, with the docker CLI, AWS CLI v2, kubectl, kustomize, Node 22 and plugins added.
- Compose file:
  - binds to `127.0.0.1:8080`
  - Docker socket mount, with a comment flagging that it gives host-root-equivalent access
- Jenkinsfile stages:
  1. Checkout (short SHA)
  2. Install
  3. Lint & Test (JUnit + coverage)
  4. Build Image
  5. Push (assume role, skip if the tag already exists)
  6. Deploy (`kustomize edit set image`, `kubectl apply -k`)
  7. Verify Rollout (undo on failure)
  8. Smoke Test
- `OVERRIDE_IMAGE_TAG` parameter for the failure demo.

## Test requirements
- A green run.
- Edit component text, commit, and the new SHA is served.
- `OVERRIDE_IMAGE_TAG=doesnotexist` → the rollout stalls, gets undone, and the build goes red while the site stays up.

## Demo / acceptance criteria
The end-to-end pipeline, plus an automatic rollback.

## Interview talking points
- Tagging with the Git SHA makes every image traceable to a commit. Tags are immutable.
- `maxUnavailable: 0` keeps the old ReplicaSet serving while the new one fails readiness, so a failed rollout never causes an outage.
- The Docker socket mount is a known tradeoff (host root). Production options are Kaniko, BuildKit rootless, or ephemeral agents.
- `pollSCM` is used because local Jenkins can't receive GitHub webhooks.
