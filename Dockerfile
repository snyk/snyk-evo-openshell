# OpenShell 0.1.x sandbox image: Claude Code + tools for Snyk Evo ADS testing
# Follows NVIDIA's bring-your-own-container requirements:
#   https://github.com/NVIDIA/OpenShell/tree/main/examples/bring-your-own-container
FROM nvcr.io/nvidia/base/ubuntu:24.04

# Corporate root CA for TLS-inspecting networks (Zscaler etc.). run.sh puts it
# in ./corp-ca/ automatically when it detects interception; empty otherwise.
COPY corp-ca/ /usr/local/share/ca-certificates/corp-ca/

# iproute2 is required for full network namespace isolation.
# libatomic1 is a runtime dependency of the nodejs.org Node binary below.
# python3 used to arrive via Ubuntu's npm package (npm > gyp > python3); Snyk
# Studio's hooks and policy.yaml rely on /usr/bin/python3.12.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq bash iproute2 libatomic1 python3 \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# --- Node.js LTS from nodejs.org (checksum verified) ----------------------------
# Ubuntu's nodejs/npm packages install outdated JS libraries under
# /usr/share/nodejs, which the container scan flags. Use the upstream tarball.
ARG NODE_VERSION=26.13.0
RUN set -eux; \
    case "$(uname -m)" in aarch64|arm64) a=arm64 ;; x86_64|amd64) a=x64 ;; *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; esac; \
    f="node-v${NODE_VERSION}-linux-${a}.tar.gz"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${f}" -o "/tmp/${f}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
    printf '%s  %s\n' "$(awk -v f="${f}" '$2 == f { print $1 }' /tmp/SHASUMS256.txt)" "/tmp/${f}" > /tmp/node.sha256; \
    sha256sum -c /tmp/node.sha256; \
    tar -xzf "/tmp/${f}" -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    rm -f "/tmp/${f}" /tmp/SHASUMS256.txt /tmp/node.sha256; \
    node --version; \
    npm --version; \
    test ! -e /usr/share/nodejs

# The npm bundled with Node 26.13.0 (11.20.0) pins brace-expansion 5.0.9,
# undici 6.28.0 and postcss-selector-parser 7.1.4, all past their fix versions.
# npm 11.21.2 resolves brace-expansion 5.0.12, undici 6.29.1 and
# postcss-selector-parser 7.1.6.
RUN npm install -g npm@11.21.2 \
 && npm --version \
 && test ! -e /usr/share/nodejs

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
RUN chmod -R a+rX /usr/local/share/snyk-demo

# --- Pre-approved OpenShell policy and the in-sandbox setup scripts ----------
# OpenShell uses /etc/openshell/policy.yaml when no --policy is given.
COPY policy.yaml /etc/openshell/policy.yaml
COPY --chmod=0755 sandbox/snyk-openshell-setup sandbox/snyk-openshell-rescan /usr/local/bin/

# Stop Claude Code's auto-updater, telemetry and error reporting. The policy
# blocks those hosts anyway; this keeps the logs free of denied connections.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV PATH="/sandbox/.local/bin:${PATH}"
USER sandbox
WORKDIR /sandbox
