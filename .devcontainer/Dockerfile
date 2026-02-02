ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# System packages
RUN apt-get update && apt-get install -y \
    sudo \
    curl \
    wget \
    git \
    vim \
    ca-certificates \
    build-essential \
    libreadline-dev \
    zlib1g-dev \
    libssl-dev \
    bison \
    flex \
    pkg-config \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# User: superuser (for devcontainer)
# ============================================
ARG SUPERUSER=superuser
ARG PASSWORD=secret_password

ARG SUPERUSER_UID=1000
ARG SUPERUSER_GID=1000

RUN groupadd --gid ${SUPERUSER_GID} ${SUPERUSER} \
    && useradd --uid ${SUPERUSER_UID} --gid ${SUPERUSER_GID} -m -s /bin/bash ${SUPERUSER} \
    && echo "${SUPERUSER}:${PASSWORD}" | chpasswd \
    && echo "${SUPERUSER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${SUPERUSER} \
    && chmod 0440 /etc/sudoers.d/${SUPERUSER}



# Switch to superuser for devcontainer
USER ${SUPERUSER}
WORKDIR /workspaces/app
