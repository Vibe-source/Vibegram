# vibe-sandbox: the bot's computer. bash/python/node/chromium + browser.js. No secrets, no
# setuid binaries; the entrypoint just idles so sandbox-gateway can exec into it on demand.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl ca-certificates git jq \
        ripgrep less unzip \
        python3 python3-pip python3-venv \
        nodejs npm \
        chromium fonts-liberation \
        xvfb dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# Chromium runs headed on this display: headless is refused by Google sign-in.
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium \
    DISPLAY=:99 \
    XVFB_SCREEN=1280x800x24

RUN useradd --create-home --home-dir /home/agent --uid 1000 --shell /bin/bash agent

COPY package.json /opt/vibe/package.json
COPY browser.js /opt/vibe/browser.js
COPY safe-url.js /opt/vibe/safe-url.js
RUN cd /opt/vibe && npm install --omit=dev --no-audit --no-fund \
    && chown -R agent:agent /opt/vibe

# agix: the same code-intelligence CLI the developers use, so the agent reads a repo by query
# instead of by cat. Absent vendor drop is not an error -- the image just ships without it.
COPY vendor/ /tmp/agix-vendor/
RUN set -eu; \
    if [ -f /tmp/agix-vendor/agix-linux-x86_64.tar.gz ]; then \
      tar -xzf /tmp/agix-vendor/agix-linux-x86_64.tar.gz -C /usr/local/bin agix; \
      chmod 0755 /usr/local/bin/agix; \
      /usr/local/bin/agix --version; \
    fi; \
    rm -rf /tmp/agix-vendor

RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# No setuid/setgid binaries anywhere: this image should never be able to escalate privilege.
# dbus-x11 ships a setuid helper, so this must stay after every apt install.
RUN find / -xdev -perm -4000 -exec chmod u-s {} + 2>/dev/null || true \
    && find / -xdev -perm -2000 -exec chmod g-s {} + 2>/dev/null || true

USER agent
WORKDIR /home/agent
ENTRYPOINT ["sleep", "infinity"]
