# Task 2 - Production Docker image

## Status
- [ ] Not started / - [x] Done

## Objective
A small, non-root, cache-friendly image that serves the SPA on port 8080.

## Dependencies
Task 1.

## Files to create/modify
- `Dockerfile`, `.dockerignore`
- `nginx/nginx.conf`
- `scripts/smoke-test.sh`
- `.gitattributes` (keeps `*.sh`, `nginx/*.conf` and `Dockerfile` on LF so they work inside Linux containers when edited on Windows)

## Implementation guidance
- Stage 1, `node:22-alpine` (pinned by digest):
  - copy `package*.json`, then `npm ci` with a BuildKit cache mount
  - copy the source, then `ARG PUBLIC_URL=/` and `npm run build`
- Stage 2, `nginxinc/nginx-unprivileged:<stable>-alpine` (pinned by digest):
  - UID 101, port 8080
  - `COPY --chown=101:101` the build output
- nginx.conf:
  - SPA fallback
  - `/healthz` returning 200 `ok` (no access log)
  - gzip
  - `/static/` cached for 1 year with immutable; `index.html` no-cache
  - security headers and `server_tokens off`
  - access log to stdout plus `include /etc/nginx/logging/*.conf`
  - pid and temp paths under `/tmp` so `readOnlyRootFilesystem` works
- `HEALTHCHECK` using busybox `wget`.
- `scripts/smoke-test.sh <base-url>` checks four things: `/healthz`, the HTML on `/`, a hashed static asset, and that a deep link falls back to index.html.

## Test requirements
- Build and run:
  ```
  docker build -t portfolio:local .
  docker run -d -p 8080:8080 --read-only --tmpfs /tmp portfolio:local
  bash scripts/smoke-test.sh http://localhost:8080
  ```
- `docker inspect` shows user `101`.
- The image is about 30 MB or less.

## Demo / acceptance criteria
The portfolio renders at http://localhost:8080 from a read-only container.

## Interview talking points
- Multi-stage build: about 1 GB of node_modules never ships. The runtime image is nginx plus static files.
- The layers are ordered so `npm ci` stays cached until the lockfile changes.
- Running as non-root on 8080 works with `runAsNonRoot` and `readOnlyRootFilesystem` and needs no `NET_BIND_SERVICE`.
- `PUBLIC_URL` as a build arg makes the same source deployable to GitHub Pages or a domain root.
