FROM ubuntu:22.04
LABEL org.opencontainers.image.source https://github.com/elastisys/compliantkubernetes-apps

ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Etc/UTC

RUN  apt-get update && \
     apt-get install -y apache2-utils bats curl dnsutils gettext-base git gpg iputils-ping jq net-tools pwgen s3cmd ssh unzip wget && \
     apt-get clean && \
     rm -rf /var/lib/apt/lists/*

# Kubectl
ENV KUBECTL_VERSION "v1.24.4"
RUN wget --progress=dot:giga "https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -Tm 755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

# sops
# NOTE: This needs to be installed before the helm-secrets plugin.
ENV SOPS_VERSION="3.6.1"
RUN wget --progress=dot:giga "https://github.com/mozilla/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux" && \
    install -Tm 755 "sops-v${SOPS_VERSION}.linux" /usr/local/bin/sops && \
    rm "sops-v${SOPS_VERSION}.linux"

# Helm
ENV HELM_VERSION "v3.8.0"
RUN wget --progress=dot:giga "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" && \
    tar -zxvf "helm-${HELM_VERSION}-linux-amd64.tar.gz" && \
    install -Tm 755 linux-amd64/helm /usr/local/bin/helm && \
    rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"
# We need to use this variable to override the default data path for helm
# TODO Change when this is closed https://github.com/helm/helm/issues/7919
# Should come with v3.3.0, see https://github.com/helm/helm/pull/7983
ENV XDG_DATA_HOME=/root/.config
RUN helm plugin install https://github.com/databus23/helm-diff --version v3.1.2
RUN helm plugin install https://github.com/jkroepke/helm-secrets --version v3.12.0

# Helmfile
ENV HELMFILE_VERSION "v0.144.0"
RUN wget --progress=dot:giga "https://github.com/roboll/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_linux_amd64" && \
    install -Tm 755 helmfile_linux_amd64 /usr/local/bin/helmfile && \
    rm helmfile_linux_amd64

# yq
ENV YQ_VERSION "3.4.1"
RUN wget --progress=dot:giga "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" && \
    install -Tm 755 yq_linux_amd64 /usr/local/bin/yq && \
    rm yq_linux_amd64

# yq4
ENV YQ_VERSION "v4.26.1"
RUN wget --progress=dot:giga "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" && \
    install -Tm 755 yq_linux_amd64 /usr/local/bin/yq4 && \
    rm yq_linux_amd64

# opa
ENV OPA_VERSION "v0.17.2"
RUN wget --progress=dot:giga "https://github.com/open-policy-agent/opa/releases/download/${OPA_VERSION}/opa_linux_amd64" && \
    install -Tm 755 opa_linux_amd64 /usr/local/bin/opa && \
    rm opa_linux_amd64
