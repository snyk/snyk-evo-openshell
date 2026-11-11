#!/usr/bin/env bash
# One command to build the image and start a Snyk Evo ADS + Claude Code
# sandbox in NVIDIA OpenShell. Works with or without TLS inspection (Zscaler).
#
# Usage:  ./run.sh            (sandbox name defaults to snyk-ads)
#         SANDBOX_NAME=demo2 ./run.sh
#
# Credentials are read from your environment, or prompted for (hidden):
#   SNYK_ADS_PUSH_KEY        Evo push key            (evo.snyk.io/settings)
#   SNYK_TOKEN               Snyk API token          (app.snyk.io/account)
#   ANTHROPIC_API_KEY        held by OpenShell, never visible to the agent
#     or CLAUDE_CODE_OAUTH_TOKEN  from `claude setup-token` (Claude Team/Enterprise)
set -euo pipefail

cd "$(dirname "$0")"
NAME="${SANDBOX_NAME:-snyk-ads}"
IMAGE="${IMAGE:-snyk-openshell-claude:latest}"
PROXY_NAME="snyk-openshell-proxy"
PROXY_IMAGE="${PROXY_IMAGE:-ubuntu/squid:latest}"
PROXY_PORT=3128
MARK_BEGIN="# >>> snyk-evo-openshell (managed by run.sh) >>>"
MARK_END="# <<< snyk-evo-openshell <<<"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
command -v docker >/dev/null || die "Docker is not installed. Install Docker Desktop 28+ first."
docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."
command -v openssl >/dev/null || die "openssl is required."

if ! command -v openshell >/dev/null; then
  say "Installing NVIDIA OpenShell"
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
  hash -r
  command -v openshell >/dev/null || die "OpenShell install failed."
fi

# ---------------------------------------------------------------------------
# 2. Credentials (prompt only for what's missing; input is hidden)
# ---------------------------------------------------------------------------
ask() { # ask VAR "prompt" [optional]
  local var="$1" prompt="$2" optional="${3:-}"
  if [ -z "${!var:-}" ]; then
    printf '%s%s: ' "$prompt" "${optional:+ (Enter to skip)}"
    IFS= read -rs val; echo
    [ -n "$val" ] || [ -n "$optional" ] || die "$var is required."
    export "$var=$val"
  fi
}
ask SNYK_ADS_PUSH_KEY "Evo push key (evo.snyk.io/settings)"
ask SNYK_TOKEN "Snyk API token (app.snyk.io/account)"
if [ -z "${SNYK_TENANT_ID:-}" ]; then
  printf 'Snyk tenant ID for Dependency Firewall (Evo > Application Supply Chain > Connections, Enter to skip): '
  IFS= read -r SNYK_TENANT_ID; export SNYK_TENANT_ID
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  ask ANTHROPIC_API_KEY "Anthropic API key" optional
  [ -n "${ANTHROPIC_API_KEY:-}" ] || \
    ask CLAUDE_CODE_OAUTH_TOKEN "Claude subscription token from 'claude setup-token'" optional
  if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    say "No Claude credential given: sign in with /login inside Claude (Team/Enterprise seat)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Detect TLS inspection (Zscaler, Netskope, ...) and find its root CA
# ---------------------------------------------------------------------------
mkdir -p corp-ca
# Check every host the sandbox uses: TLS inspection often bypasses some domains.
INTERCEPTED=""; issuer=""; PROBE_HOST=api.snyk.io
for h in api.anthropic.com api.snyk.io deeproxy.snyk.io claude.ai; do
  i="$(openssl s_client -connect "$h:443" -servername "$h" </dev/null 2>/dev/null \
       | openssl x509 -noout -issuer 2>/dev/null || true)"
  if printf '%s' "$i" | grep -qiE 'zscaler|netskope|palo alto|forcepoint|blue ?coat|fortinet|umbrella|mcafee|symantec web|cloudflare gateway'; then
    INTERCEPTED=1; issuer="$h: $i"; PROBE_HOST="$h"; break
  fi
done
if ls corp-ca/*.crt >/dev/null 2>&1; then INTERCEPTED=1; fi

CA_BUNDLE=""
if [ -n "$INTERCEPTED" ]; then
  say "TLS inspection detected ($issuer)"
  if ! ls corp-ca/*.crt >/dev/null 2>&1; then
    if [ "$(uname)" = Darwin ] && \
       security find-certificate -a -c "Zscaler Root CA" -p /Library/Keychains/System.keychain \
         > corp-ca/zscaler-root-ca.crt 2>/dev/null && [ -s corp-ca/zscaler-root-ca.crt ]; then
      say "Exported Zscaler Root CA from the macOS keychain"
    else
      rm -f corp-ca/zscaler-root-ca.crt
      # Fall back to the top certificate the proxy presents.
      openssl s_client -connect "$PROBE_HOST:443" -servername "$PROBE_HOST" -showcerts </dev/null 2>/dev/null \
        | awk '/BEGIN CERT/{b=""} {b=b $0 "\n"} /END CERT/{last=b} END{printf "%s", last}' \
        > corp-ca/corp-root-ca.crt
      [ -s corp-ca/corp-root-ca.crt ] || die "Could not find your corporate root CA. Put it in corp-ca/<name>.crt (PEM) and rerun."
      say "Captured the corporate CA from the live TLS chain"
    fi
  fi
  CA_BUNDLE="$HOME/.config/openshell/snyk-corp-ca.pem"
  mkdir -p "$(dirname "$CA_BUNDLE")"
  cat corp-ca/*.crt > "$CA_BUNDLE"
  chmod 0644 "$CA_BUNDLE"
else
  say "No TLS inspection detected"
fi

# ---------------------------------------------------------------------------
# 4. Gateway config: route the supervisor through a local proxy when TLS is
#    intercepted, so OpenShell can trust the corporate CA (proxy_ca_bundle).
# ---------------------------------------------------------------------------
if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/openshell/gateway.toml" ]; then
  GW_CONF="$XDG_CONFIG_HOME/openshell/gateway.toml"
elif [ -f "$HOME/.config/openshell/gateway.toml" ]; then
  GW_CONF="$HOME/.config/openshell/gateway.toml"
elif [ -n "$(command -v brew || true)" ] && [ -f "$(brew --prefix)/var/openshell/gateway.toml" ]; then
  GW_CONF="$(brew --prefix)/var/openshell/gateway.toml"
else
  GW_CONF="$HOME/.config/openshell/gateway.toml"
fi
mkdir -p "$(dirname "$GW_CONF")"
touch "$GW_CONF"

# Remove our previous block, keep everything else.
tmp="$(mktemp)"
awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$GW_CONF" > "$tmp"
if ! grep -qE '^[[:space:]]*version[[:space:]]*=[[:space:]]*2' "$tmp"; then
  if grep -qvE '^[[:space:]]*(#|$)' "$tmp"; then
    die "$GW_CONF is not a schema v2 gateway config. Migrate it first (see OpenShell 0.1.0 upgrade guide)."
  fi
  printf '[openshell]\nversion = 2\n' > "$tmp"
fi
if [ -n "$CA_BUNDLE" ]; then
  grep -q '^\[openshell\.drivers\.docker\]' "$tmp" && \
    die "$GW_CONF already has an [openshell.drivers.docker] section. Add https_proxy/no_proxy/proxy_ca_bundle there manually."
  cat >> "$tmp" <<EOF
$MARK_BEGIN
[openshell.drivers.docker]
https_proxy = "http://127.0.0.1:$PROXY_PORT"
no_proxy = "127.0.0.1,localhost,host.openshell.internal,host.docker.internal"
proxy_ca_bundle = "$CA_BUNDLE"
$MARK_END
EOF
fi

if ! cmp -s "$tmp" "$GW_CONF"; then
  GW_BIN="$(command -v openshell-gateway || true)"
  [ -n "$GW_BIN" ] || { [ -n "$(command -v brew || true)" ] && GW_BIN="$(brew --prefix)/opt/openshell/bin/openshell-gateway"; }
  if [ -x "${GW_BIN:-}" ] && ! "$GW_BIN" config preflight --path "$tmp" >/dev/null 2>&1; then
    "$GW_BIN" config preflight --path "$tmp" || true
    rm -f "$tmp"; die "Generated gateway config failed preflight. $GW_CONF was not changed."
  fi
  cp "$GW_CONF" "$GW_CONF.bak.$(date +%s)"
  mv "$tmp" "$GW_CONF"
  say "Updated gateway config: $GW_CONF"
  if command -v brew >/dev/null && brew services list 2>/dev/null | grep -q '^openshell'; then
    brew services restart openshell >/dev/null
  elif command -v systemctl >/dev/null; then
    systemctl --user restart openshell-gateway || true
  fi
  say "Waiting for the OpenShell gateway"
  for _ in $(seq 1 30); do openshell status >/dev/null 2>&1 && break; sleep 2; done
else
  rm -f "$tmp"
fi

# Local CONNECT proxy for the supervisor (only when TLS is intercepted).
# On Docker Desktop, 127.0.0.1 inside a host-networked container (where the
# OpenShell supervisor runs) is the Mac's loopback, so the proxy must be
# published on the Mac's 127.0.0.1, not run in the Docker VM's host network.
if [ -n "$CA_BUNDLE" ]; then
  SQUID_CONF="$HOME/.config/openshell/snyk-squid.conf"
  cat > "$SQUID_CONF" <<EOF
# Minimal CONNECT proxy for the OpenShell supervisor. Published only on
# 127.0.0.1, so nothing outside this machine can use it.
http_port $PROXY_PORT
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny CONNECT !SSL_ports
http_access allow all
cache deny all
EOF
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  say "Starting local proxy ($PROXY_IMAGE) on 127.0.0.1:$PROXY_PORT"
  docker run -d --name "$PROXY_NAME" --restart unless-stopped \
    -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
    -v "$SQUID_CONF:/etc/squid/squid.conf:ro" "$PROXY_IMAGE" >/dev/null
  for _ in $(seq 1 15); do
    docker logs "$PROXY_NAME" 2>&1 | grep -q "Accepting HTTP Socket connections" && break; sleep 1
  done
else
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 5. Build the image
# ---------------------------------------------------------------------------
say "Building $IMAGE"
docker build -t "$IMAGE" . >/dev/null

# Docker Desktop must have host networking on (Settings > Resources > Network).
if [ "$(uname)" = Darwin ]; then
  if ! docker run --rm --network host --entrypoint bash "$IMAGE" \
       -c 'timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/17670"' >/dev/null 2>&1; then
    die "Containers can't reach the OpenShell gateway. In Docker Desktop: Settings > Resources > Network > Enable host networking, then Apply & restart, and rerun."
  fi
fi
if [ -n "$CA_BUNDLE" ]; then
  code="$(docker run --rm --network host --entrypoint curl "$IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:$PROXY_PORT" https://api.snyk.io/ 2>/dev/null || true)"
  [ "$code" != "000" ] && [ -n "$code" ] || die "Local proxy check failed (api.snyk.io via 127.0.0.1:$PROXY_PORT). Check: docker logs $PROXY_NAME"
fi

# ---------------------------------------------------------------------------
# 6. Claude credential held by OpenShell (API key mode)
# ---------------------------------------------------------------------------
PROVIDER_ARGS=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  profile="$(mktemp -d)/claude-code.yaml"
  curl -fsSL https://raw.githubusercontent.com/NVIDIA/OpenShell/main/providers/claude-code.yaml -o "$profile"
  openshell provider profile import -f "$profile" --global >/dev/null 2>&1 || true
  openshell provider delete snyk-demo-claude >/dev/null 2>&1 || true
  openshell provider create --name snyk-demo-claude --type claude-code --from-existing >/dev/null
  PROVIDER_ARGS=(--provider snyk-demo-claude)
  say "Anthropic API key stored in OpenShell (the agent can't read it)"
fi

# ---------------------------------------------------------------------------
# 7. Create the sandbox and start setup + Claude Code
# ---------------------------------------------------------------------------
if openshell sandbox get "$NAME" >/dev/null 2>&1; then
  say "Replacing existing sandbox $NAME"
  openshell sandbox delete "$NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do openshell sandbox get "$NAME" >/dev/null 2>&1 || break; sleep 2; done
fi

ENV_ARGS=(--env-from SNYK_ADS_PUSH_KEY --env-from SNYK_TOKEN
          --env "SNYK_MACHINE_ID=openshell:$(hostname -s):$NAME" --no-credential-warnings)
[ -n "${SNYK_TENANT_ID:-}" ] && ENV_ARGS+=(--env "SNYK_TENANT_ID=$SNYK_TENANT_ID")
for v in SNYK_REGISTRY_HOST SNYK_NPM_PATH SNYK_PYPI_PATH; do
  [ -n "${!v:-}" ] && ENV_ARGS+=(--env "$v=${!v}")
done
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && \
  ENV_ARGS+=(--env-from CLAUDE_CODE_OAUTH_TOKEN)

say "Creating sandbox $NAME"
exec openshell sandbox create --name "$NAME" --from "$IMAGE" --policy ./policy.yaml \
  "${PROVIDER_ARGS[@]+"${PROVIDER_ARGS[@]}"}" "${ENV_ARGS[@]}" -- snyk-openshell-setup
