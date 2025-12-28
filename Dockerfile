ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"
ARG ARG_UBUNTU_BASE_IMAGE_TAG="20.04"

FROM ${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG}
WORKDIR /azp
# BuildKit sets TARGETARCH/TARGETPLATFORM when using buildx/--platform
ARG TARGETARCH=amd64
ARG ARG_VSTS_AGENT_VERSION=4.266.2
ARG ARG_VSTS_AGENT_SHA256_AMD64=303124cf6296a18bda06fcc6ed2e2424792a25324378a9a62df72fc0f564a27a
ARG ARG_VSTS_AGENT_SHA256_ARM64=f6d0b96fac0e8dd290be18d92d70b9de4a683928faa89ac76547d4c5154f56d0

# Tool versions for reproducible builds
ARG BUILDKIT_VERSION=0.26.3
ARG BUILDKIT_SHA256_AMD64=249ae16ba4be59fadb51a49ff4d632bbf37200e2b6e187fa8574f0f1bce8166b
ARG BUILDKIT_SHA256_ARM64=a98829f1b1b9ec596eb424dd03f03b9c7b596edac83e6700adf83ba0cb0d5f80
ARG YQ_VERSION=v4.50.1
ARG YQ_SHA256_AMD64=c7a1278e6bbc4924f41b56db838086c39d13ee25dcb22089e7fbf16ac901f0d4
ARG YQ_SHA256_ARM64=cf0a663d8e4e00bb61507c5237b95b45a6aaa1fbedac77f4dc8abdadd5e2b745
ARG HELM_VERSION=v4.0.4
ARG HELM_SHA256_AMD64=29454bc351f4433e66c00f5d37841627cbbcc02e4c70a6d796529d355237671c
ARG HELM_SHA256_ARM64=16b88acc6503d646b7537a298e7389bef469c5cc9ebadf727547abe9f6a35903
ARG KUBECTL_VERSION=v1.35.0
ARG KUBECTL_SHA256_AMD64=a2e984a18a0c063279d692533031c1eff93a262afcc0afdc517375432d060989
ARG KUBECTL_SHA256_ARM64=58f82f9fe796c375c5c4b8439850b0f3f4d401a52434052f2df46035a8789e25
ARG APT_UPGRADE=1
ARG USER_ID=1000
ARG USER_NAME=azdouser

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

# Add Microsoft repository and install Azure CLI & PowerShell
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    curl -fsSLO "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"; \
    dpkg -i packages-microsoft-prod.deb; \
    rm -f packages-microsoft-prod.deb; \
    apt-get update; \
    apt-get install -y azure-cli powershell; \
    az extension add --name azure-devops

# Install yq
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt \
    useradd -m -s /bin/bash -u "${USER_ID}" "${USER_NAME}"; \
    echo "${USER_NAME} ALL=(root) NOPASSWD:ALL" >> /etc/sudoers

# Copy start script
COPY --chmod=775 --chown=${USER_NAME}:${USER_NAME} ./start.sh .

RUN chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME} /azp \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
USER ${USER_NAME}

ENTRYPOINT ["./start.sh"]
