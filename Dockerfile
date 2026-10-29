# OpenShell 0.1.x sandbox image: Claude Code + tools for Snyk Evo ADS testing
# Follows NVIDIA's bring-your-own-container requirements:
#   https://github.com/NVIDIA/OpenShell/tree/main/examples/bring-your-own-container
FROM nvcr.io/nvidia/base/ubuntu:24.04

# Optional: drop Zscaler root cert (PEM, .crt) into ./corp-ca/ before building
COPY corp-ca/ /usr/local/share/ca-certificates/corp-ca/

# iproute2 is required for full network namespace isolation
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq bash iproute2 nodejs npm \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# Non-root user + writable /sandbox workspace
RUN useradd -m -s /bin/bash sandbox \
 && install -d -o sandbox -g sandbox /sandbox

# Claude Code native binary, copied to /usr/local/bin/claude so it matches the
# binaries path in NVIDIA's claude-code provider profile (binary identity check)
USER sandbox
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
RUN cp -L /home/sandbox/.local/bin/claude /usr/local/bin/claude \
 && chmod 755 /usr/local/bin/claude

# Snyk Agent Scan / Agent Guard (one binary), installed at build time with the
# SHA-256-verified script from snyk/evo-ads-sbx-kit (upstream main), vendored
# in vendor/ (Apache-2.0).
# Lands at /home/sandbox/.local/share/snyk-agent-scan/agent-scan
COPY --chmod=0755 vendor/install-agent-scan.sh /tmp/install-agent-scan.sh
USER sandbox
RUN sh /tmp/install-agent-scan.sh \
 && /home/sandbox/.local/share/snyk-agent-scan/agent-scan help | head -3
# OpenShell's filesystem policy (Landlock) does not allow executing from
# /home, so install the binary under /usr/local/bin like claude
USER root
RUN install -m 0755 /home/sandbox/.local/share/snyk-agent-scan/agent-scan /usr/local/bin/agent-scan

# --- Snyk CLI (standalone binary, checksum verified) for Snyk Studio ---------
RUN set -eux; \
    case "$(uname -m)" in aarch64|arm64) a=snyk-linux-arm64 ;; *) a=snyk-linux ;; esac; \
    curl -fsSL "https://downloads.snyk.io/cli/stable/$a" -o /tmp/snyk; \
    curl -fsSL "https://downloads.snyk.io/cli/stable/$a.sha256" -o /tmp/snyk.sha256; \
    echo "$(cut -d' ' -f1 /tmp/snyk.sha256)  /tmp/snyk" | sha256sum -c -; \
    install -m 0755 /tmp/snyk /usr/local/bin/snyk; rm -f /tmp/snyk /tmp/snyk.sha256; \
    snyk --version

# --- Snyk Studio installer binary (Secure at Inception) ----------------------
# Uses the kit's verified download script, vendored as
#   vendor/install-studio.sh (from snyk/evo-ads-sbx-kit, Apache-2.0).
# The script also tries to run the installer; that part may fail at build time
# and is fine to ignore. We only keep the binary and run it inside the sandbox.
COPY --chmod=0755 vendor/install-studio.sh /tmp/install-studio.sh
RUN HOME=/tmp/studio sh /tmp/install-studio.sh || true; \
    install -m 0755 /tmp/studio/.local/share/snyk-studio/snyk-studio-installer /usr/local/bin/snyk-studio-installer; \
    rm -rf /tmp/studio

# --- Demo MCP servers (local only, no network needed) -------------------------
RUN npm install -g @modelcontextprotocol/server-filesystem @modelcontextprotocol/server-memory \
 && ls /usr/local/bin | grep mcp-server

# --- uv (Python tool runner), required by the Snyk Studio installer -----------
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
 && uv --version

# --- Demo skills, copied into ~/.claude/skills inside the sandbox -------------
# Must live under /usr: OpenShell's filesystem policy can't read /opt
COPY demo-skills/ /usr/local/share/snyk-demo/skills/

ENV PATH="/sandbox/.local/bin:${PATH}"
USER sandbox
WORKDIR /sandbox
