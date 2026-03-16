FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base packages
RUN apt-get update && apt-get install -y \
    openssh-server \
    build-essential gcc g++ make cmake \
    python3 python3-pip \
    git curl wget nano sudo \
    ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Enable corepack and install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# SSH configuration
RUN mkdir -p /run/sshd \
    && sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create non-root user with sudo access
RUN useradd -m -s /bin/bash openclaw \
    && echo 'openclaw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openclaw \
    && chmod 440 /etc/sudoers.d/openclaw \
    && mkdir -p /home/openclaw/.ssh \
    && chown openclaw:openclaw /home/openclaw/.ssh \
    && chmod 700 /home/openclaw/.ssh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
