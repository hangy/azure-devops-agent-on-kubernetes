ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"
ARG ARG_UBUNTU_BASE_IMAGE_TAG="20.04"

FROM ${ARG_UBUNTU_BASE_IMAGE}:${ARG_UBUNTU_BASE_IMAGE_TAG}
WORKDIR /azp
ARG ARG_TARGETARCH=linux-x64
ARG ARG_VSTS_AGENT_VERSION=4.258.1
ARG ARG_VSTS_AGENT_SHA256=unset

# Tool versions for reproducible builds
ARG YQ_VERSION=v4.48.1
ARG YQ_SHA256=99df6047f5b577a9d25f969f7c3823ada3488de2e2115b30a0abb10d9324fd9f
ARG HELM_VERSION=v3.19.0
ARG HELM_SHA256=a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496
ARG KUBECTL_VERSION=v1.34.1
ARG KUBECTL_SHA256=7721f265e18709862655affba5343e85e1980639395d5754473dafaadcaa69e3
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
RUN echo "Downloading Azure DevOps Agent version ${ARG_VSTS_AGENT_VERSION} for ${ARG_TARGETARCH}" \
    && curl -fsSL -o agent.tar.gz "https://download.agent.dev.azure.com/agent/${ARG_VSTS_AGENT_VERSION}/vsts-agent-${ARG_TARGETARCH}-${ARG_VSTS_AGENT_VERSION}.tar.gz" \
    && if [ "${ARG_VSTS_AGENT_SHA256}" != "unset" ]; then echo "${ARG_VSTS_AGENT_SHA256}  agent.tar.gz" | sha256sum -c -; else echo "Skipping checksum verification for agent (ARG_VSTS_AGENT_SHA256 unset)"; fi \
    && tar -xzf agent.tar.gz \
    && rm -f agent.tar.gz


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
