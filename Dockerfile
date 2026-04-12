ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"
ARG ARG_UBUNTU_BASE_IMAGE_TAG="24.04"

FROM ${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG} AS base
WORKDIR /azp
# BuildKit sets TARGETARCH/TARGETPLATFORM when using buildx/--platform
ARG TARGETARCH=amd64
ARG ARG_VSTS_AGENT_VERSION=4.270.0
ARG ARG_VSTS_AGENT_SHA256_AMD64=20ab7708d9140e649794aa0680c771313f9845e9b4d62f9ba942bad8305c1233
ARG ARG_VSTS_AGENT_SHA256_ARM64=7bfe11aea0422ae150a2b8d91fc5d93319659578c45145cb3f08dcab79516677

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

FROM base AS download-agent
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Download and extract the Azure DevOps Agent (with optional checksum verification)
WORKDIR /agent-download
RUN case "${TARGETARCH}" in \
        amd64) AGENT_ARCH=linux-x64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_AMD64}" ;; \
        arm64|aarch64) AGENT_ARCH=linux-arm64; AGENT_SHA="${ARG_VSTS_AGENT_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
    esac; \
    echo "Downloading Azure DevOps Agent version ${ARG_VSTS_AGENT_VERSION} for ${AGENT_ARCH}"; \
    curl -fsSL -o agent.tar.gz "https://download.agent.dev.azure.com/agent/${ARG_VSTS_AGENT_VERSION}/vsts-agent-${AGENT_ARCH}-${ARG_VSTS_AGENT_VERSION}.tar.gz"; \
    if [ "${AGENT_SHA}" != "unset" ] && [ -n "${AGENT_SHA}" ]; then echo "${AGENT_SHA}  agent.tar.gz" | sha256sum -c -; else echo "Skipping checksum verification for agent (checksum unset for ${TARGETARCH})"; fi; \
    tar -xzf agent.tar.gz; \
    rm -f agent.tar.gz

FROM base AS download-buildkit
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Install buildkit (download, extract, cleanup)
ARG BUILDKIT_VERSION=0.29.0
ARG BUILDKIT_SHA256_AMD64=ab8d93c72253b450f34a43e1c480abc52380f4aec3a8a395aebf09489efef7a0
ARG BUILDKIT_SHA256_ARM64=99a279e30be2947294eece98d82d1461fcfdc47da59514cb85252bb5ef414801
RUN case "${TARGETARCH}" in \
        amd64) BK_ARCH=linux-amd64; BK_SHA="${BUILDKIT_SHA256_AMD64:-}";; \
        arm64|aarch64) BK_ARCH=linux-arm64; BK_SHA="${BUILDKIT_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL -o /tmp/buildkit.tar.gz "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${BK_ARCH}.tar.gz"; \
    if [ -n "${BK_SHA}" ]; then echo "${BK_SHA}  /tmp/buildkit.tar.gz" | sha256sum -c -; else echo "Skipping BuildKit checksum verification for ${TARGETARCH}"; fi; \
    tar -xzf /tmp/buildkit.tar.gz -C /tmp/; \
    mv /tmp/bin/* /usr/local/bin; \
    rm -rf /tmp/buildkit.tar.gz /tmp/bin

FROM base AS download-powershell
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Install PowerShell from binary archive for all architectures (verify checksum)
ARG POWERSHELL_VERSION=7.6.0
ARG POWERSHELL_SHA256_AMD64=04517472CF57D7F9CBD93897DA9BED467C73CA6063C29D7655EBC20AA1D6023F
ARG POWERSHELL_SHA256_ARM64=DDDF7564FB3B52DC26BE5580FC5B4E08EB3FA65B094488AAE6D4B3CAD5FEA460
RUN case "${TARGETARCH}" in \
        amd64) PS_ARCH="x64"; PS_SHA="${POWERSHELL_SHA256_AMD64}";; \
        arm64|aarch64) PS_ARCH="arm64"; PS_SHA="${POWERSHELL_SHA256_ARM64}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    PS_TGZ="powershell-${POWERSHELL_VERSION}-linux-${PS_ARCH}.tar.gz"; \
    PS_URL="https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${PS_TGZ}"; \
    curl -fsSL "${PS_URL}" -o /tmp/${PS_TGZ}; \
    echo "${PS_SHA}  /tmp/${PS_TGZ}" | tr '[:upper:]' '[:lower:]' | sha256sum -c - || { echo "PowerShell checksum mismatch"; exit 1; }; \
    mkdir -p /opt/microsoft/powershell/latest && \
    tar -xzf /tmp/${PS_TGZ} -C /opt/microsoft/powershell/latest && \
    chmod +x /opt/microsoft/powershell/latest/pwsh; \
    ln -sf /opt/microsoft/powershell/latest/pwsh /usr/bin/pwsh; \
    rm -f /tmp/${PS_TGZ}

# Install yq
FROM base AS download-yq
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG YQ_VERSION=v4.52.5
ARG YQ_SHA256_AMD64=75d893a0d5940d1019cb7cdc60001d9e876623852c31cfc6267047bc31149fa9
ARG YQ_SHA256_ARM64=90fa510c50ee8ca75544dbfffed10c88ed59b36834df35916520cddc623d9aaa
RUN case "${TARGETARCH}" in \
        amd64) YQ_ARCH=amd64; YQ_SHA="${YQ_SHA256_AMD64:-}";; \
        arm64|aarch64) YQ_ARCH=arm64; YQ_SHA="${YQ_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" -o /usr/bin/yq; \
    if [ -n "${YQ_SHA}" ]; then echo "${YQ_SHA}  /usr/bin/yq" | sha256sum -c -; else echo "Skipping yq checksum verification for ${TARGETARCH}"; fi; \
    chmod +x /usr/bin/yq

# Install Helm
FROM base AS download-helm
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG HELM_VERSION=v4.1.4
ARG HELM_SHA256_AMD64=70b2c30a19da4db264dfd68c8a3664e05093a361cefd89572ffb36f8abfa3d09
ARG HELM_SHA256_ARM64=13d03672be289045d2ff00e4e345d61de1c6f21c1257a45955a30e8ae036d8f1
RUN case "${TARGETARCH}" in \
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
FROM base AS download-kubectl
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG KUBECTL_VERSION=v1.35.3
ARG KUBECTL_SHA256_AMD64=fd31c7d7129260e608f6faf92d5984c3267ad0b5ead3bced2fe125686e286ad6
ARG KUBECTL_SHA256_ARM64=6f0cd088a82dde5d5807122056069e2fac4ed447cc518efc055547ae46525f14
RUN case "${TARGETARCH}" in \
        amd64) KUBECTL_ARCH=amd64; KUBECTL_SHA_CHECK="${KUBECTL_SHA256_AMD64:-}";; \
        arm64|aarch64) KUBECTL_ARCH=arm64; KUBECTL_SHA_CHECK="${KUBECTL_SHA256_ARM64:-}";; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1;; \
    esac; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl" -o /usr/bin/kubectl; \
    if [ -n "${KUBECTL_SHA_CHECK}" ]; then echo "${KUBECTL_SHA_CHECK}  /usr/bin/kubectl" | sha256sum -c -; else echo "Skipping kubectl checksum verification for ${TARGETARCH}"; fi; \
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
