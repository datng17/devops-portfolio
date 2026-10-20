# syntax=docker/dockerfile:1

# ---------- Stage 1: build the static bundle ----------
# node:22-alpine, pinned by multi-arch index digest
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS build
WORKDIR /app

# Dependency layer: only invalidated when the lockfile changes
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# Source layer
COPY tsconfig.json ./
COPY public ./public
COPY src ./src

# Serve from the domain root by default; override for subpath hosting (e.g. GitHub Pages)
ARG PUBLIC_URL=/
ENV PUBLIC_URL=${PUBLIC_URL} \
    GENERATE_SOURCEMAP=false
RUN npm run build

# ---------- Stage 2: unprivileged nginx runtime ----------
# nginxinc/nginx-unprivileged:1.30-alpine (stable), pinned by multi-arch index digest
FROM nginxinc/nginx-unprivileged:1.30-alpine@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03

COPY --chown=101:101 nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=101:101 --from=build /app/build /usr/share/nginx/html

USER 101
EXPOSE 8080

# busybox wget ships with the alpine base image
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
