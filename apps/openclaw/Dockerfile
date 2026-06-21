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

# Additional packages for plugin support and native compilation
RUN apt-get update && apt-get install -y \
    file procps locales unzip \
    pkg-config libssl-dev \
    python3-venv \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Generate UTF-8 locale (required by Homebrew and many tools)
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# SSH configuration (port 2222, host network mode)
RUN mkdir -p /run/sshd \
    && sed -i 's/^#Port 22$/Port 2222/' /etc/ssh/sshd_config \
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

# Install Homebrew (Linuxbrew) as openclaw user — brew refuses to run as root
USER openclaw
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    && echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/openclaw/.bashrc \
    && echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/openclaw/.profile
USER root

# Homebrew environment (persists for all users and layers)
ENV HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew \
    HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar \
    HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
ENV PATH="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:${PATH}"

# Install Go via Homebrew (needed by gogcli and other Go-based plugins)
RUN su - openclaw -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install go && brew cleanup'

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2222

ENTRYPOINT ["/entrypoint.sh"]
