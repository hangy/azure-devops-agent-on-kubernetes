ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"
ARG ARG_UBUNTU_BASE_IMAGE_TAG="24.04"

FROM ${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG}
WORKDIR /azp
# BuildKit sets TARGETARCH/TARGETPLATFORM when using buildx/--platform
ARG TARGETARCH=amd64
ARG ARG_VSTS_AGENT_VERSION=4.268.0
ARG ARG_VSTS_AGENT_SHA256_AMD64=00288e13696b1ef0e6817b32b780ab197f7022fe560021d6212224aff5a5e411
ARG ARG_VSTS_AGENT_SHA256_ARM64=fe6037bfc97f6bbe0a3a593a1c603790ba9793362642a99c1b6336eb43782143

# Tool versions for reproducible builds
ARG APT_UPGRADE=1
ARG USER_NAME=ubuntu

LABEL org.opencontainers.image.title="Azure DevOps Agent on Kubernetes" \
      org.opencontainers.image.source="https://github.com/hangy/azure-devops-agent-on-kubernetes" \
      org.opencontainers.image.description="Self-hosted Azure DevOps build agent image with pinned tool versions" \
      org.opencontainers.image.vendor="hangy" \
      org.opencontainers.image.licenses="MIT"

# To make it easier for build and release pipelines to run apt-get,
# configure apt to not require confirmation (assume the -y argument by default)
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

# Install required base tools (optional upgrade controlled by APT_UPGRADE)
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

# Download and extract the Azure DevOps Agent (with optional checksum verification)
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) AGENT_ARCH=linux-x64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_AMD64}" ;; \
        arm64|aarch64) AGENT_ARCH=linux-arm64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
    esac; \
    echo "Downloading Azure DevOps Agent version ${ARG_VSTS_AGENT_VERSION} for ${AGENT_ARCH}"; \
    curl -fsSL -o agent.tar.gz "https://download.agent.dev.azure.com/agent/${ARG_VSTS_AGENT_VERSION}/vsts-agent-${AGENT_ARCH}-${ARG_VSTS_AGENT_VERSION}.tar.gz"; \
    if [ "${AGENT_SHA}" != "unset" ] && [ -n "${AGENT_SHA}" ]; then echo "${AGENT_SHA}  agent.tar.gz" | sha256sum -c -; else echo "Skipping checksum verification for agent (checksum unset for ${TARGETARCH})"; fi; \
    tar -xzf agent.tar.gz; \
    rm -f agent.tar.gz

# Install buildkit (download, extract, cleanup)
ARG BUILDKIT_VERSION=0.28.0
ARG BUILDKIT_SHA256_AMD64=bc5a158c97c1f7ace1af81c375e8c28bd27e6afeb283fc5b3bfb10777f48fc83
ARG BUILDKIT_SHA256_ARM64=02a6f8c1ea519b11d312ea2fb2f45cf3a7a34814a0e61d55d2532adb211ce400
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) BK_ARCH=linux-amd64; BK_SHA="${BUILDKIT_SHA256_AMD64:-}";; \
        arm64|aarch64) BK_ARCH=linux-arm64; BK_SHA="${BUILDKIT_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL -o /tmp/buildkit.tar.gz "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${BK_ARCH}.tar.gz"; \
    if [ -n "${BK_SHA}" ]; then echo "${BK_SHA}  /tmp/buildkit.tar.gz" | sha256sum -c -; else echo "Skipping BuildKit checksum verification for ${TARGETARCH}"; fi; \
    tar -xzf /tmp/buildkit.tar.gz -C /tmp/; \
    mv /tmp/bin/* /usr/local/bin; \
    rm -rf /tmp/buildkit.tar.gz /tmp/bin

# Install PowerShell from binary archive for all architectures (verify checksum)
ARG POWERSHELL_VERSION=7.5.4
ARG POWERSHELL_SHA256_AMD64=1FD7983FE56CA9E6233F126925EDB24BF6B6B33E356B69996D925C4DB94E2FEF
ARG POWERSHELL_SHA256_ARM64=4B32D4CB86A43DFB83D5602D0294295BF22FAFBF9E0785D1AAEF81938CDA92F8
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) PS_ARCH="x64"; PS_SHA="${POWERSHELL_SHA256_AMD64}";; \
        arm64|aarch64) PS_ARCH="arm64"; PS_SHA="${POWERSHELL_SHA256_ARM64}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    PS_TGZ="powershell-${POWERSHELL_VERSION}-linux-${PS_ARCH}.tar.gz"; \
    PS_URL="https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${PS_TGZ}"; \
    curl -fsSL "${PS_URL}" -o /tmp/${PS_TGZ}; \
    echo "${PS_SHA}  /tmp/${PS_TGZ}" | tr '[:upper:]' '[:lower:]' | sha256sum -c - || { echo "PowerShell checksum mismatch"; exit 1; }; \
    mkdir -p /opt/microsoft/powershell/${POWERSHELL_VERSION} && \
    tar -xzf /tmp/${PS_TGZ} -C /opt/microsoft/powershell/${POWERSHELL_VERSION} && \
    chmod +x /opt/microsoft/powershell/${POWERSHELL_VERSION}/pwsh; \
    ln -sf /opt/microsoft/powershell/${POWERSHELL_VERSION}/pwsh /usr/bin/pwsh; \    
    rm -f /tmp/${PS_TGZ}

# Install Azure CLI using keyrings + sources approach (deb_install.sh)
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

# Install yq
ARG YQ_VERSION=v4.52.4
ARG YQ_SHA256_AMD64=0c4d965ea944b64b8fddaf7f27779ee3034e5693263786506ccd1c120f184e8c
ARG YQ_SHA256_ARM64=4c2cc022a129be5cc1187959bb4b09bebc7fb543c5837b93001c68f97ce39a5d
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) YQ_ARCH=amd64; YQ_SHA="${YQ_SHA256_AMD64:-}";; \
        arm64|aarch64) YQ_ARCH=arm64; YQ_SHA="${YQ_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" -o /usr/bin/yq; \
    if [ -n "${YQ_SHA}" ]; then echo "${YQ_SHA}  /usr/bin/yq" | sha256sum -c -; else echo "Skipping yq checksum verification for ${TARGETARCH}"; fi; \
    chmod +x /usr/bin/yq

# Install Helm
ARG HELM_VERSION=v4.1.0
ARG HELM_SHA256_AMD64=8e7ae5cb890c56f53713bffec38e41cd8e7e4619ebe56f8b31cd383bfb3dbb83
ARG HELM_SHA256_ARM64=81315e404b6d09b65bee577a679ab269d6d44652ef2e1f66a8f922b51ca93f6b
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) HELM_ARCH=amd64; HELM_SHA="${HELM_SHA256_AMD64:-}"; HELM_DIR=linux-amd64;; \
        arm64|aarch64) HELM_ARCH=arm64; HELM_SHA="${HELM_SHA256_ARM64:-}"; HELM_DIR=linux-arm64;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz" -o helm.tar.gz; \
    if [ -n "${HELM_SHA}" ]; then echo "${HELM_SHA}  helm.tar.gz" | sha256sum -c -; else echo "Skipping Helm checksum verification for ${TARGETARCH}"; fi; \
    tar -zxvf helm.tar.gz; \
    mv "${HELM_DIR}"/helm /usr/bin/helm; \
    rm -rf "${HELM_DIR}" helm.tar.gz; \
    chmod +x /usr/bin/helm

# Install Kubectl
ARG KUBECTL_VERSION=v1.35.2
ARG KUBECTL_SHA256_AMD64=924eb50779153f20cb668117d141440b95df2f325a64452d78dff9469145e277
ARG KUBECTL_SHA256_ARM64=cd859449f54ad2cb05b491c490c13bb836cdd0886ae013c0aed3dd67ff747467
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) KUBECTL_ARCH=amd64; KUBECTL_SHA_CHECK="${KUBECTL_SHA256_AMD64:-}";; \
        arm64|aarch64) KUBECTL_ARCH=arm64; KUBECTL_SHA_CHECK="${KUBECTL_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl" -o /usr/bin/kubectl; \
    if [ -n "${KUBECTL_SHA_CHECK}" ]; then echo "${KUBECTL_SHA_CHECK}  /usr/bin/kubectl" | sha256sum -c -; else echo "Skipping kubectl checksum verification for ${TARGETARCH}"; fi; \
    chmod +x /usr/bin/kubectl

# Install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update \
    && apt-get install -y docker-ce-cli

# Create non-root user
RUN echo "${USER_NAME} ALL=(root) NOPASSWD:ALL" >> /etc/sudoers

# Copy start script
COPY --chmod=775 --chown=${USER_NAME}:${USER_NAME} ./start.sh .

RUN chown -R ${USER_NAME} /azp \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
USER ${USER_NAME}

ENTRYPOINT ["./start.sh"]
