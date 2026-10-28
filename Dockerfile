# syntax=docker/dockerfile:1

FROM docker.io/library/ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive

ARG DEV_USER=dev
ARG DEV_UID=1000
ARG DEV_GID=1000

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Jakarta


# ============================================================
# Prevent package installs from trying to start services
# during docker/podman build.
# ============================================================

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d


# ============================================================
# Base development packages
#
# Includes the dependencies required by Swift on Ubuntu 24.04.
# ============================================================

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        gnupg2 \
        software-properties-common \
        sudo \
        git \
        git-lfs \
        gh \
        ripgrep \
        build-essential \
        pkg-config \
        unzip \
        zip \
        xz-utils \
        jq \
        less \
        nano \
        vim \
        procps \
        iproute2 \
        iputils-ping \
        dnsutils \
        netcat-openbsd \
        rsync \
        bash-completion \
        locales \
        tzdata \
        binutils \
        libc6-dev \
        libcurl4-openssl-dev \
        libedit2 \
        libgcc-13-dev \
        libncurses-dev \
        libpython3-dev \
        python3 \
        python3-pip \
        python3-venv \
        libsqlite3-0 \
        libsqlite3-dev \
        libstdc++-13-dev \
        libxml2-dev \
        libxml2-utils \
        poppler-utils \
        default-mysql-client \
        libz3-dev \
        zlib1g-dev \
        sqlite3 \
        tmux \
        bubblewrap \
        ssh \
        supervisor \
        libvips-tools \
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# Python tooling
#
# Official uv binaries are shared by both images. Use uv/venv
# for project dependencies rather than changing system Python.
# ============================================================

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

RUN uv --version \
    && uvx --version \
    && python3 --version \
    && python3 -m pip --version \
    && gh --version \
    && rg --version \
    && xmllint --version \
    && pdftotext -v \
    && mysql --version


# ============================================================
# Development user
#
# Ubuntu 24.04 may already contain UID/GID 1000 ("ubuntu").
# Reuse/rename that account instead of blindly creating another
# UID/GID 1000 and failing with:
#
#   groupadd: GID '1000' already exists
#
# DEV_UID / DEV_GID can also be overridden at build time.
# ============================================================

RUN set -eux; \
    existing_user="$(getent passwd "${DEV_UID}" | cut -d: -f1 || true)"; \
    existing_group="$(getent group "${DEV_GID}" | cut -d: -f1 || true)"; \
    \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != "${DEV_USER}" ]; then \
        groupmod \
            --new-name "${DEV_USER}" \
            "${existing_group}"; \
    elif [ -z "${existing_group}" ]; then \
        groupadd \
            --gid "${DEV_GID}" \
            "${DEV_USER}"; \
    fi; \
    \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != "${DEV_USER}" ]; then \
        usermod \
            --login "${DEV_USER}" \
            "${existing_user}"; \
        usermod \
            --home "/home/${DEV_USER}" \
            --move-home \
            "${DEV_USER}"; \
        usermod \
            --shell /bin/bash \
            "${DEV_USER}"; \
    elif ! getent passwd "${DEV_USER}" >/dev/null; then \
        useradd \
            --uid "${DEV_UID}" \
            --gid "${DEV_GID}" \
            --create-home \
            --home-dir "/home/${DEV_USER}" \
            --shell /bin/bash \
            "${DEV_USER}"; \
    else \
        usermod \
            --uid "${DEV_UID}" \
            --gid "${DEV_GID}" \
            --home "/home/${DEV_USER}" \
            --shell /bin/bash \
            "${DEV_USER}"; \
    fi; \
    \
    usermod --gid "${DEV_GID}" "${DEV_USER}"; \
    usermod --append --groups sudo "${DEV_USER}"; \
    \
    printf '%s\n' \
        "${DEV_USER} ALL=(ALL:ALL) NOPASSWD:ALL" \
        > "/etc/sudoers.d/${DEV_USER}"; \
    chmod 0440 "/etc/sudoers.d/${DEV_USER}"; \
    \
    mkdir -p "/home/${DEV_USER}/Developer"; \
    chown -R "${DEV_UID}:${DEV_GID}" "/home/${DEV_USER}"


# ============================================================
# PHP 8.4 + Nginx
# ============================================================

# Use the signed Sury APT repository instead of the Launchpad PPA.
# The base image is Ubuntu 24.04 (noble).
RUN set -eux; \
    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb \
        https://packages.sury.org/debsuryorg-archive-keyring.deb; \
    dpkg -i /tmp/debsuryorg-archive-keyring.deb; \
    rm -f /tmp/debsuryorg-archive-keyring.deb; \
    . /etc/os-release; \
    printf 'Types: deb\nURIs: https://packages.sury.org/php/\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debsuryorg-archive-keyring.gpg\n' \
        "$VERSION_CODENAME" > /etc/apt/sources.list.d/php.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx \
        php8.4 \
        php8.4-cli \
        php8.4-fpm \
        php8.4-common \
        php8.4-bcmath \
        php8.4-curl \
        php8.4-gd \
        php8.4-intl \
        php8.4-mbstring \
        php8.4-mysql \
        php8.4-opcache \
        php8.4-readline \
        php8.4-sqlite3 \
        php8.4-xml \
        php8.4-zip \
    && php --version \
    && nginx -v \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# Composer
#
# Keep the checksum-verified installation from the working
# nspawn Dockerfile instead of depending on composer:2.
# ============================================================

RUN set -eux; \
    expected_checksum="$(curl -fsSL https://composer.github.io/installer.sig)"; \
    curl -fsSL \
        https://getcomposer.org/installer \
        -o /tmp/composer-setup.php; \
    actual_checksum="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"; \
    test "${expected_checksum}" = "${actual_checksum}"; \
    php /tmp/composer-setup.php \
        --install-dir=/usr/local/bin \
        --filename=composer; \
    rm -f /tmp/composer-setup.php; \
    composer --version


# ============================================================
# Java 21
# ============================================================

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-21-jdk \
    && JAVA_HOME_REAL="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" \
    && ln -sfn "${JAVA_HOME_REAL}" /opt/java \
    && java --version \
    && javac --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/opt/java


# ============================================================
# Node.js 24 LTS + npm
# ============================================================

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && node --version \
    && npm --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# Browser inspection and screenshots — shared by both images
#
# Install Chromium and its Linux dependencies during the build,
# rather than relying on a browser cached in an existing container.
# Store it outside the dev home so mounting that home does not hide it.
# NODE_PATH also makes Playwright available to node -e / CommonJS scripts.
# ============================================================

ARG PLAYWRIGHT_VERSION=latest

ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    NODE_PATH=/usr/local/lib/node_modules

RUN npm install -g --prefix /usr/local "playwright@${PLAYWRIGHT_VERSION}" \
    && playwright install --with-deps chromium \
    && ln -s "$(node -p 'require("playwright").chromium.executablePath()')" /usr/local/bin/chromium \
    && chmod -R a+rX /opt/playwright \
    && playwright --version \
    && npm cache clean --force \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Fail the build if the dev account cannot launch the same browser
# used by MCP, inspect an element, and capture a PNG screenshot.
# Chromium runs without its own sandbox inside this container.
RUN runuser -u "${DEV_USER}" -- env HOME="/home/${DEV_USER}" node <<'BROWSER_CHECK'
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
(async () => {
    const browser = await chromium.launch({
        executablePath: '/usr/local/bin/chromium',
        headless: true,
        args: ['--no-sandbox'],
    });
    try {
        const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
        await page.setContent('<h1>Browser ready</h1>');
        assert.equal(await page.locator('h1').innerText(), 'Browser ready');
        const png = await page.screenshot({ type: 'png' });
        assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
        console.log('Chromium inspection and screenshot check passed as the dev user');
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exit(1); });
BROWSER_CHECK


# ============================================================
# Swift — latest stable
#
# Swiftly is installed under the dev account, and "swiftly init"
# downloads the latest stable Swift release.
# ============================================================

RUN set -eux; \
    install \
        -d \
        -o "${DEV_UID}" \
        -g "${DEV_GID}" \
        /tmp/swiftly-install; \
    \
    runuser -u "${DEV_USER}" -- \
        env HOME="/home/${DEV_USER}" \
        bash -c '\
            set -eux; \
            cd /tmp/swiftly-install; \
            curl -fL \
                "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
                -o swiftly.tar.gz; \
            tar -xzf swiftly.tar.gz; \
            ./swiftly init \
                --assume-yes \
                --quiet-shell-followup \
                --no-modify-profile \
        '; \
    \
    rm -rf /tmp/swiftly-install

RUN runuser -u "${DEV_USER}" -- \
        env HOME="/home/${DEV_USER}" \
        bash -c '\
            set -e; \
            . "$HOME/.local/share/swiftly/env.sh"; \
            swiftly --version; \
            swift --version \
        '


# ============================================================
# Shell configuration
#
# Includes:
# - ~/.local/bin
# - Swift / swiftly
# ============================================================

RUN printf '%s\n' \
        '' \
        '# ------------------------------------------------------------' \
        '# User-local tools' \
        '# ------------------------------------------------------------' \
        'export PATH="$HOME/.local/bin:$PATH"' \
        '' \
        '# ------------------------------------------------------------' \
        '# Swift / swiftly' \
        '# ------------------------------------------------------------' \
        'if [ -f "$HOME/.local/share/swiftly/env.sh" ]; then' \
        '    . "$HOME/.local/share/swiftly/env.sh"' \
        'fi' \
        '' \
        >> "/home/${DEV_USER}/.bashrc" \
    && chown \
        "${DEV_UID}:${DEV_GID}" \
        "/home/${DEV_USER}/.bashrc"

# Also make these tools available when executing commands directly
# with `podman exec`, without relying on an interactive shell.
ENV PATH="/home/${DEV_USER}/.local/bin:/home/${DEV_USER}/.local/share/swiftly/bin:/opt/java/bin:${PATH}"


# ============================================================
# Package installation is finished.
#
# Remove policy-rc.d so services can be started manually from
# inside the running devbox.
# ============================================================

USER root

RUN rm -f /usr/sbin/policy-rc.d \
    && mkdir -p \
        /run/php \
        /run/nginx \
    && chown -R "${DEV_UID}:${DEV_GID}" "/home/${DEV_USER}"


# The runtime may mount its own /etc/hostname. Update that file at
# startup as well as storing a default in each image. The existing
# passwordless sudo setup lets the dev account perform this write.
COPY --chmod=0755 <<'ENTRYPOINT_SCRIPT' /usr/local/bin/devbox-entrypoint
#!/bin/sh
set -eu
: "${CONTAINER_HOSTNAME:?Image must define CONTAINER_HOSTNAME}"
if [ "$(cat /etc/hostname 2>/dev/null || true)" != "$CONTAINER_HOSTNAME" ]; then
    if [ "$(id -u)" = 0 ]; then
        printf '%s\n' "$CONTAINER_HOSTNAME" > /etc/hostname
    else
        printf '%s\n' "$CONTAINER_HOSTNAME" | sudo -n tee /etc/hostname >/dev/null
    fi
fi
exec "$@"
ENTRYPOINT_SCRIPT

ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]


# ============================================================
# Runtime
#
# Quadlet/Podman owns the container lifecycle.
# ============================================================

USER ${DEV_USER}

WORKDIR /home/${DEV_USER}/Developer

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]


# ============================================================
# devbox — development tools without an AI coding agent
#
# podman build --target devbox -t devbox:latest -f Dockerfile .
# Use --hostname devbox (or HostName=devbox in Quadlet) at runtime.
# ============================================================

FROM base AS devbox

ENV CONTAINER_HOSTNAME=devbox

COPY --chmod=0644 <<'HOSTNAME_FILE' /etc/hostname
devbox
HOSTNAME_FILE


# ============================================================
# vibecoding — devbox plus OpenAI Codex and model shortcuts
#
# podman build --target vibecoding -t vibecoding:latest -f Dockerfile .
# Use --hostname vibecoding (or HostName=vibecoding in Quadlet).
# This is the default target when --target is omitted.
# ============================================================

FROM devbox AS vibecoding

USER root

ARG CODEX_VERSION=latest
ARG PLAYWRIGHT_MCP_VERSION=latest
ARG CHROME_DEVTOOLS_MCP_VERSION=latest

ENV CONTAINER_HOSTNAME=vibecoding

COPY --chmod=0644 <<'HOSTNAME_FILE' /etc/hostname
vibecoding
HOSTNAME_FILE


# ============================================================
# OpenAI Codex
#
# Installed globally; credentials/config remain under the
# runtime user's home.
# ============================================================

RUN npm install -g "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force \
    && codex --version


# ============================================================
# Browser MCP tools — vibecoding only
#
# Reuse the shared Chromium install; no runtime npx downloads.
# System defaults survive a mounted ~/.codex or dev home and
# allow the user's Codex configuration to override these settings.
# ============================================================

RUN PUPPETEER_SKIP_DOWNLOAD=true npm install -g --prefix /usr/local \
        "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
        "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
    && playwright-mcp --help >/dev/null \
    && chrome-devtools-mcp --help >/dev/null \
    && npm cache clean --force

COPY --chmod=0644 <<'CODEX_MCP_CONFIG' /etc/codex/config.toml
[mcp_servers.playwright]
command = "/usr/local/bin/playwright-mcp"
args = ["--headless", "--isolated", "--no-sandbox", "--executable-path", "/usr/local/bin/chromium"]
startup_timeout_sec = 30
tool_timeout_sec = 120

# Optional deeper debugging. Chrome DevTools MCP officially supports
# Google Chrome / Chrome for Testing; bundled Chromium is best effort.
# Enable for a session with:
# codex -c mcp_servers.chrome_devtools.enabled=true
[mcp_servers.chrome_devtools]
enabled = false
command = "/usr/local/bin/chrome-devtools-mcp"
args = ["--headless", "--isolated", "--executablePath=/usr/local/bin/chromium", "--chromeArg=--no-sandbox", "--no-performance-crux", "--no-usage-statistics"]
startup_timeout_sec = 30
tool_timeout_sec = 120
CODEX_MCP_CONFIG


# Model shortcuts are only added to the vibecoding image.
RUN printf '%s\n' \
        '' \
        '# ------------------------------------------------------------' \
        '# Codex — YOLO: no approvals, no sandbox' \
        '# ------------------------------------------------------------' \
        '' \
        'astra6() {' \
        '    command codex --model gpt-6-astra --yolo "$@"' \
        '}' \
        '' \
        'sol6() {' \
        '    command codex --model gpt-6-sol --yolo "$@"' \
        '}' \
        '' \
        'sol61() {' \
        '    command codex --model gpt-6.1-sol --yolo "$@"' \
        '}' \
        '' \
        'luna6() {' \
        '    command codex --model gpt-6-luna --yolo "$@"' \
        '}' \
        '' \
        'sol56() {' \
        '    command codex --model gpt-5.6-sol --yolo "$@"' \
        '}' \
        '' \
        'terra56() {' \
        '    command codex --model gpt-5.6-terra --yolo "$@"' \
        '}' \
        '' \
        'luna56() {' \
        '    command codex --model gpt-5.6-luna --yolo "$@"' \
        '}' \
        '' \
        'gpt55() {' \
        '    command codex --model gpt-5.5 --yolo "$@"' \
        '}' \
        '' \
        >> "/home/${DEV_USER}/.bashrc" \
    && chown \
        "${DEV_UID}:${DEV_GID}" \
        "/home/${DEV_USER}/.bashrc"

USER ${DEV_USER}
