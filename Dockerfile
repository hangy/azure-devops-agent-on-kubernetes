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
ARG BUILDKIT_SHA256=249ae16ba4be59fadb51a49ff4d632bbf37200e2b6e187fa8574f0f1bce8166b
ARG YQ_VERSION=v4.50.1
ARG YQ_SHA256=c7a1278e6bbc4924f41b56db838086c39d13ee25dcb22089e7fbf16ac901f0d4
ARG HELM_VERSION=v4.0.1
ARG HELM_SHA256=e0365548f01ed52a58a1181ad310b604a3244f59257425bb1739499372bdff60
ARG KUBECTL_VERSION=v1.35.0
ARG KUBECTL_SHA256=a2e984a18a0c063279d692533031c1eff93a262afcc0afdc517375432d060989
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
        arm64) AGENT_ARCH=linux-arm64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_ARM64}" ;; \
        aarch64) AGENT_ARCH=linux-arm64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
    esac; \
    echo "Downloading Azure DevOps Agent version ${ARG_VSTS_AGENT_VERSION} for ${AGENT_ARCH}"; \
    curl -fsSL -o agent.tar.gz "https://download.agent.dev.azure.com/agent/${ARG_VSTS_AGENT_VERSION}/vsts-agent-${AGENT_ARCH}-${ARG_VSTS_AGENT_VERSION}.tar.gz"; \
    if [ "${AGENT_SHA}" != "unset" ] && [ -n "${AGENT_SHA}" ]; then echo "${AGENT_SHA}  agent.tar.gz" | sha256sum -c -; else echo "Skipping checksum verification for agent (checksum unset for ${TARGETARCH})"; fi; \
    tar -xzf agent.tar.gz; \
    rm -f agent.tar.gz

# Install buildkit (download, extract, cleanup)
RUN curl -fsSL -o /tmp/buildkit.tar.gz "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.linux-amd64.tar.gz" \
    && tar -xzf /tmp/buildkit.tar.gz -C /tmp/ \
    && mv /tmp/bin/* /usr/local/bin \
    && rm -rf /tmp/buildkit.tar.gz /tmp/bin

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
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/bin/yq \
    && echo "${YQ_SHA256}  /usr/bin/yq" | sha256sum -c - \
    && chmod +x /usr/bin/yq



# Install Helm
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o helm.tar.gz \
    && echo "${HELM_SHA256}  helm.tar.gz" | sha256sum -c - \
    && tar -zxvf helm.tar.gz \
    && mv linux-amd64/helm /usr/bin/helm \
    && rm -rf linux-amd64 helm.tar.gz \
    && chmod +x /usr/bin/helm



# Install Kubectl
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/bin/kubectl \
    && echo "${KUBECTL_SHA256}  /usr/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/bin/kubectl



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
