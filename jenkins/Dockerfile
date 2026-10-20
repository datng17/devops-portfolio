# syntax=docker/dockerfile:1

# Local Jenkins controller for the eks-portfolio pipeline.
# Builds run on the built-in node, so the controller image carries the tools:
# docker CLI + buildx, AWS CLI v2, kubectl, kustomize and Node 22.
# Every download is pinned by version and checked against a SHA-256.

# jenkins/jenkins:2.580.1-lts-jdk21, pinned by multi-arch index digest
FROM jenkins/jenkins:2.580.1-lts-jdk21@sha256:a660310e39ade10631f774bacd5219de767dfd08947ea5c32a739b5e5bb382c1

USER root

# docker CLI only (no daemon): builds go to the host daemon through the socket
ARG DOCKER_VERSION=29.9.1
ARG DOCKER_SHA256=c158ecc55adb3afb01bbd3539ed3b997d20c26dbdc418080506cc1bf5243ff57
# buildx: the app Dockerfile uses BuildKit cache mounts
ARG BUILDX_VERSION=0.38.0
ARG BUILDX_SHA256=4fe4cc38adf48169132749b6ca22a990928db0118e3407584ee553723115d287
ARG AWSCLI_VERSION=2.38.1
ARG AWSCLI_SHA256=b11ed416d91f4251da363a17706938eeaf0e520745754c104c0c1890dd8363c7
# Within one minor version of the cluster (1.37)
ARG KUBECTL_VERSION=1.37.1
ARG KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
ARG KUSTOMIZE_VERSION=5.8.3
ARG KUSTOMIZE_SHA256=cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61
ARG NODE_VERSION=22.23.3
ARG NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/tools

RUN curl -fsSLo docker.tgz "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
 && echo "${DOCKER_SHA256}  docker.tgz" | sha256sum -c - \
 && tar -xzf docker.tgz --strip-components=1 -C /usr/local/bin docker/docker \
 && mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSLo /usr/local/lib/docker/cli-plugins/docker-buildx \
      "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64" \
 && echo "${BUILDX_SHA256}  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c - \
 && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx \
 && rm -f docker.tgz

RUN curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
 && echo "${AWSCLI_SHA256}  awscliv2.zip" | sha256sum -c - \
 && unzip -q awscliv2.zip \
 && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
 && rm -rf aws awscliv2.zip

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/kubectl \
 && curl -fsSLo kustomize.tgz \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
 && echo "${KUSTOMIZE_SHA256}  kustomize.tgz" | sha256sum -c - \
 && tar -xzf kustomize.tgz -C /usr/local/bin kustomize \
 && rm -f kustomize.tgz

RUN curl -fsSLo node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  node.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/node \
 && tar -xJf node.tar.xz --strip-components=1 -C /opt/node \
 && rm -f node.tar.xz

ENV PATH="/opt/node/bin:${PATH}"

# The repo is bind-mounted read-only at /repo with host ownership; let git use it.
RUN git config --system --add safe.directory '*'

WORKDIR /

USER jenkins

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as Code: admin user, credentials (from /run/secrets) and the
# "portfolio" pipeline job. Lives outside JENKINS_HOME so a rebuild applies it.
COPY --chown=jenkins:jenkins casc.yaml /usr/share/jenkins/casc/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc/casc.yaml \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true"
