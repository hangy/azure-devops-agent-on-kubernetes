ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"
ARG ARG_UBUNTU_BASE_IMAGE_TAG="24.04"
# Pinned manifest-list digest of the base image above (covers amd64/arm64).
# Kept current by Renovate (docker:pinDigests preset) / Dependabot: bump together with the tag.
# Look up the current digest with: docker buildx imagetools inspect ubuntu:24.04
ARG ARG_UBUNTU_BASE_IMAGE_DIGEST="sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac"
# Pinned point-in-time view of the Ubuntu archive, UTC (YYYYMMDDTHHMMSSZ).
# Every apt operation against the Ubuntu archive resolves as of this timestamp,
# so builds are reproducible and the exact package set stays traceable.
# Bump regularly (first of each month) to pull in security updates; a scheduled
# workflow proposes the bump automatically. Must be >= the noble release date.
ARG ARG_UBUNTU_SNAPSHOT="20261025T203000Z"

FROM ${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG}@${ARG_UBUNTU_BASE_IMAGE_DIGEST} AS base
WORKDIR /azp
# BuildKit sets TARGETARCH/TARGETPLATFORM when using buildx/--platform
ARG TARGETARCH=amd64
# Re-declare global ARGs to use them after FROM
ARG ARG_UBUNTU_BASE_IMAGE
ARG ARG_UBUNTU_BASE_IMAGE_TAG
ARG ARG_UBUNTU_BASE_IMAGE_DIGEST
ARG ARG_UBUNTU_SNAPSHOT

# Tool versions for reproducible builds
ARG APT_UPGRADE=1
ARG USER_NAME=ubuntu

LABEL org.opencontainers.image.title="Azure DevOps Agent on Kubernetes" \
      org.opencontainers.image.source="https://github.com/hangy/azure-devops-agent-on-kubernetes" \
      org.opencontainers.image.description="Self-hosted Azure DevOps build agent image with pinned tool versions" \
      org.opencontainers.image.vendor="hangy" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG}" \
      org.opencontainers.image.base.digest="${ARG_UBUNTU_BASE_IMAGE_DIGEST}" \
      io.ubuntu.snapshot="${ARG_UBUNTU_SNAPSHOT}"

# To make it easier for build and release pipelines to run apt-get,
# configure apt to not require confirmation (assume the -y argument by default)
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

# Fail fast on a malformed snapshot ID (expected format: YYYYMMDDTHHMMSSZ, UTC)
RUN if ! [[ "${ARG_UBUNTU_SNAPSHOT}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then echo "error: ARG_UBUNTU_SNAPSHOT='${ARG_UBUNTU_SNAPSHOT}' is not in YYYYMMDDTHHMMSSZ format" >&2; exit 1; fi

# snapshot.ubuntu.com is HTTPS-only but the minimal base image ships no CA
# certificates yet, so bootstrap just ca-certificates from the live archive.
# Exception to pinning: this one package tracks the live archive at build time
# (taking the latest CA bundle is also the safer choice); everything else below
# resolves to the snapshot.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates

# Pin every subsequent Ubuntu-archive operation to the snapshot timestamp.
# Third-party repos (Microsoft, Docker) do not advertise snapshot support and
# are unaffected: they keep resolving to their latest packages.
RUN echo "APT::Snapshot \"${ARG_UBUNTU_SNAPSHOT}\";" > /etc/apt/apt.conf.d/50snapshot

# Install required base tools from the snapshot (optional upgrade controlled by APT_UPGRADE)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        git \
        git-lfs \
        iputils-ping \
        libunwind8 \
        jq \
        lsb-release \
        software-properties-common \
        sudo \
        unzip; \
    if [ "${APT_UPGRADE}" = "1" ]; then apt-get -y upgrade; fi

FROM base AS download-agent
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/agent.json /tmp/agent.json
RUN AGENT_ARCH="${TARGETARCH}"; \
    AGENT_RELEASE_ARCH=$(jq -r ".download_arch[\"${AGENT_ARCH}\"] // \"${AGENT_ARCH}\"" /tmp/agent.json); \
    AGENT_VERSION=$(jq -r '.version' /tmp/agent.json); \
    AGENT_SHA256=$(jq -r ".sha256[\"${AGENT_ARCH}\"]" /tmp/agent.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/agent.json | sed "s/{version}/${AGENT_VERSION}/g" | sed "s/{arch}/${AGENT_RELEASE_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o agent.tar.gz; \
    echo "${AGENT_SHA256}  agent.tar.gz" | sha256sum -c -; \
    mkdir -p /agent-download; \
    tar -xzf agent.tar.gz -C /agent-download; \
    rm agent.tar.gz

FROM base AS download-powershell
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/powershell.json /tmp/powershell.json
RUN PS_ARCH="${TARGETARCH}"; \
    PS_RELEASE_ARCH=$(jq -r ".download_arch[\"${PS_ARCH}\"] // \"${PS_ARCH}\"" /tmp/powershell.json); \
    PS_VERSION=$(jq -r '.version' /tmp/powershell.json); \
    PS_SHA256=$(jq -r ".sha256[\"${PS_ARCH}\"]" /tmp/powershell.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/powershell.json | sed "s/{version}/${PS_VERSION}/g" | sed "s/{arch}/${PS_RELEASE_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o powershell.tar.gz; \
    echo "${PS_SHA256}  powershell.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/microsoft/powershell/latest; \
    tar -xzf powershell.tar.gz -C /opt/microsoft/powershell/latest; \
    chmod +x /opt/microsoft/powershell/latest/pwsh; \
    ln -sf /opt/microsoft/powershell/latest/pwsh /usr/bin/pwsh; \
    rm powershell.tar.gz; \
    pwsh --version

FROM base AS download-buildkit
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/buildkit.json /tmp/buildkit.json
RUN BK_ARCH="${TARGETARCH}"; \
    BK_VERSION=$(jq -r '.version' /tmp/buildkit.json); \
    BK_SHA256=$(jq -r ".sha256[\"${BK_ARCH}\"]" /tmp/buildkit.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/buildkit.json | sed "s/{version}/${BK_VERSION}/g" | sed "s/{arch}/${BK_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o buildkit.tar.gz; \
    echo "${BK_SHA256}  buildkit.tar.gz" | sha256sum -c -; \
    tar -xzf buildkit.tar.gz -C /usr/local/bin --strip-components=1; \
    rm buildkit.tar.gz; \
    buildctl --version

# Install yq
FROM base AS download-yq
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/yq.json /tmp/yq.json
RUN YQ_ARCH="${TARGETARCH}"; \
    YQ_VERSION=$(jq -r '.version' /tmp/yq.json); \
    YQ_SHA=$(jq -r ".sha256[\"${YQ_ARCH}\"]" /tmp/yq.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/yq.json | sed "s/{version}/${YQ_VERSION}/g" | sed "s/{arch}/${YQ_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o /usr/bin/yq; \
    echo "${YQ_SHA}  /usr/bin/yq" | sha256sum -c -; \
    chmod +x /usr/bin/yq

# Install Helm
FROM base AS download-helm
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/helm.json /tmp/helm.json
RUN HELM_ARCH="${TARGETARCH}"; \
    HELM_VERSION=$(jq -r '.version' /tmp/helm.json); \
    HELM_SHA=$(jq -r ".sha256[\"${HELM_ARCH}\"]" /tmp/helm.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/helm.json | sed "s/{version}/${HELM_VERSION}/g" | sed "s/{arch}/${HELM_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o helm.tar.gz; \
    echo "${HELM_SHA}  helm.tar.gz" | sha256sum -c -; \
    tar -zxvf helm.tar.gz; \
    mv "linux-${HELM_ARCH}"/helm /usr/bin/helm; \
    rm -rf "linux-${HELM_ARCH}" helm.tar.gz; \
    chmod +x /usr/bin/helm

# Install Kubectl
FROM base AS download-kubectl
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
COPY dependencies/kubectl.json /tmp/kubectl.json
RUN KUBECTL_ARCH="${TARGETARCH}"; \
    KUBECTL_VERSION=$(jq -r '.version' /tmp/kubectl.json); \
    KUBECTL_SHA=$(jq -r ".sha256[\"${KUBECTL_ARCH}\"]" /tmp/kubectl.json); \
    DOWNLOAD_URL=$(jq -r '.download_url' /tmp/kubectl.json | sed "s/{version}/${KUBECTL_VERSION}/g" | sed "s/{arch}/${KUBECTL_ARCH}/g"); \
    curl -fsSL "${DOWNLOAD_URL}" -o /usr/bin/kubectl; \
    echo "${KUBECTL_SHA}  /usr/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/bin/kubectl

# Install Azure CLI using keyrings + sources approach (deb_install.sh)
FROM base AS install-apt-packages
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg; \
    chmod go+r /etc/apt/keyrings/microsoft.gpg; \
    CLI_REPO=$(lsb_release -cs); \
    # If the distribution codename is not present in the azure-cli dists, fall back to common names
    if ! curl -sL https://packages.microsoft.com/repos/azure-cli/dists/ | grep -q "${CLI_REPO}"; then \
        DIST=$(lsb_release -is); \
        case "${DIST}" in \
            Ubuntu*) CLI_REPO=jammy ;; \
            Debian*) CLI_REPO=bookworm ;; \
            *) CLI_REPO=jammy ;; \
        esac; \
    fi; \
    echo "Types: deb" > /etc/apt/sources.list.d/azure-cli.sources; \
    echo "URIs: https://packages.microsoft.com/repos/azure-cli/" >> /etc/apt/sources.list.d/azure-cli.sources; \
    echo "Suites: ${CLI_REPO}" >> /etc/apt/sources.list.d/azure-cli.sources; \
    echo "Components: main" >> /etc/apt/sources.list.d/azure-cli.sources; \
    echo "Architectures: $(dpkg --print-architecture)" >> /etc/apt/sources.list.d/azure-cli.sources; \
    echo "Signed-by: /etc/apt/keyrings/microsoft.gpg" >> /etc/apt/sources.list.d/azure-cli.sources; \
    apt-get update; \
    apt-get install -y azure-cli; \
    az extension add --name azure-devops || true; \
    rm -rf /var/lib/apt/lists/*

# Install Docker CLI
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update \
    && apt-get install -y docker-ce-cli

FROM install-apt-packages AS final
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

COPY --from=download-agent /agent-download/ /azp/
COPY --from=download-buildkit /usr/local/bin/buildctl /usr/local/bin/buildctl
COPY --from=download-powershell /opt/microsoft/powershell/ /opt/microsoft/powershell/
RUN ln -sf /opt/microsoft/powershell/latest/pwsh /usr/bin/pwsh
COPY --from=download-helm /usr/bin/helm /usr/bin/helm
COPY --from=download-kubectl /usr/bin/kubectl /usr/bin/kubectl
COPY --from=download-yq /usr/bin/yq /usr/bin/yq

# Create non-root user
RUN echo "${USER_NAME} ALL=(root) NOPASSWD:ALL" >> /etc/sudoers

# Copy start script
COPY --chmod=775 --chown=${USER_NAME}:${USER_NAME} ./start.sh .

RUN chown -R ${USER_NAME} /azp \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
USER ${USER_NAME}

ENTRYPOINT ["./start.sh"]
