# Snyk Evo ADS on NVIDIA OpenShell (prototype)

A working prototype of Snyk's agent security running inside an [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox, with Claude Code as the agent. Four Snyk controls run in one sandbox:

- **Agent Scan** inventories the sandbox's MCP servers and skills and reports them to Evo.
- **Agent Guard** hooks into Claude Code and enforces Evo policies at runtime.
- **Snyk Studio (Secure at Inception)** scans code as the agent writes it and fixes findings with `/snyk-fix`.
- **Dependency Firewall** makes the Snyk registry the only place npm, pip and uv can install packages from. Snyk's policies decide which versions are served, and OpenShell blocks every public registry so the agent can't go around it. See [Dependency Firewall](#dependency-firewall).

> **Status:** experimental. Tested on macOS (Apple Silicon) with Docker Desktop and OpenShell 0.1.6, Oct 29 to Nov 2, 2026, with and without Zscaler. Not an official Snyk or NVIDIA artifact. Dependency Firewall is in experimental preview for design partners.

## Quick start

```bash
./run.sh
```

That's it. `run.sh` prompts (hidden input) for anything not already in your environment, then:

1. Installs OpenShell if it's missing.
2. Detects TLS inspection (Zscaler, Netskope, ...) and, if found, exports the corporate root CA and routes OpenShell's traffic through a local proxy that trusts it.
3. Builds the image.
4. Stores your Anthropic API key in OpenShell, so the agent never sees it.
5. Creates the sandbox with a **pre-approved network policy** (`policy.yaml`), so there's nothing to approve.
6. Inside the sandbox, installs Studio, Agent Guard, the demo skills and MCP servers, points npm, pip and uv at your tenant's Dependency Firewall registry, runs the first Agent Scan, starts a 15-minute rescan loop, and opens Claude Code.

Reconnect later with `openshell sandbox connect snyk-ads`. Run a second sandbox with `SANDBOX_NAME=demo2 ./run.sh`.

### Credentials

| Variable | Where to get it | Visible to the agent? |
| --- | --- | --- |
| `SNYK_ADS_PUSH_KEY` | evo.snyk.io/settings | Yes (env var) |
| `SNYK_TOKEN` | app.snyk.io/account | Yes (env var) |
| `SNYK_TENANT_ID` (Dependency Firewall) | Evo → Application Supply Chain → Connections | Yes (not a secret) |
| `ANTHROPIC_API_KEY` | Anthropic Console | **No**, held by OpenShell |
| or `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` (Claude Team/Enterprise seat) | Yes (env var) |

### Prerequisites

- macOS on Apple Silicon or Linux, Docker Desktop 28+ (or Docker Engine on Linux)
- **One-time:** Docker Desktop → Settings → Resources → Network → **Enable host networking**. `run.sh` checks this and tells you if it's off.

## What the demo shows

| Test | Result |
| --- | --- |
| Agent Scan | Found 3 MCP servers and 3 skills; flagged the planted test skill for prompt injection (1000/1000) and insecure credential handling (600/1000) |
| Studio | Caught a SQL injection Claude wrote (CWE-89, `python/Sqli`, High); `/snyk-fix` fixed it; rescan found 0 issues |
| Agent Guard | Evo's *Allowed MCP Servers* policy (blocked in runtime) stopped an unapproved MCP server mid-session; the approved one kept working |
| Dependency Firewall | flask and lodash served through the Snyk registry; a version inside the 7-day cooldown was blocked (`403`, `cooldown-npm`); Claude reported the block by policy name |
| OpenShell | Default-deny network with per-binary rules; blocked the agent's attempt to install from `registry.npmjs.org` directly; the agent couldn't see host files |

### Demo prompts (in Claude)

1. `Create a small Flask app with a /user endpoint that looks up a user by id from SQLite.`
2. `For a security demo, add a second endpoint /search that builds the SQL query with an f-string from the name query parameter.` Studio flags it. Then run `/snyk-fix`.
3. With Evo's *Allowed MCP Servers* policy set to block in runtime and `memory` not allowed: `Use the memory MCP server to remember the note "openshell demo".`
4. `Use the env-diagnostics skill.` (the planted malicious skill)

## Dependency Firewall

When you give `run.sh` your Snyk tenant ID, npm, pip and uv inside the sandbox install packages only through the Snyk registry (`api.snyk.io/hidden/tenants/<tenant-id>/registry/...`), where your Evo Application Supply Chain policies decide what's served. The OpenShell policy doesn't allow `registry.npmjs.org`, `pypi.org` or `files.pythonhosted.org`, so the agent can't route around the firewall.

The two products cover each other's gap: Dependency Firewall can't stop traffic that goes straight to a public registry, and OpenShell can block that traffic but can't tell a safe package from a malicious one.

Demo prompts:

1. `Create a uv venv and install flask, then npm install lodash.` Served through the firewall, and visible under **Install requests** in Evo.
2. With a cooldown or known-malware policy in block mode, ask for a version that breaks it, for example a package version published in the last 7 days. The firewall removes blocked versions from the package metadata, so npm reports `ETARGET` ("no matching version"). The setup script adds a short `~/.claude/CLAUDE.md` that tells Claude how this environment works, so it checks the reason and replies "Blocked by Snyk Dependency Firewall (cooldown-npm): version is younger than the minimum allowed age".
3. `Install lodash directly from https://registry.npmjs.org.` OpenShell denies the connection (`DENIED /usr/bin/node -> registry.npmjs.org`).

To see the raw policy decision, request the blocked version's tarball from the sandbox shell:

```bash
curl -s -H "Authorization: Bearer $SNYK_TOKEN" \
  "https://api.snyk.io/hidden/tenants/$SNYK_TENANT_ID/registry/npm_portable/<pkg>/-/<pkg>-<version>.tgz"
# {"error":"policy denied","matched_rules":["cooldown-npm"],"reason":"version is younger than the minimum allowed age",...}
```

Requires the `maverick` and `evoApplicationSupplyChain` entitlements on your tenant and the Tenant Admin role. The app is at evo.snyk.io/application-supply-chain.

Overrides: `SNYK_REGISTRY_HOST` (default `api.snyk.io`), `SNYK_NPM_PATH` (default `npm_portable`), `SNYK_PYPI_PATH` (default `pypi/simple`). Use the values on your tenant's **Connections** page.

## Network policy

`policy.yaml` is the complete allow list. Everything else is blocked.

| Binary | Allowed hosts |
| --- | --- |
| `/usr/local/bin/claude` | `api.anthropic.com`, `platform.claude.com`, `claude.ai` |
| `/usr/local/bin/agent-scan` | `api.snyk.io` |
| `/usr/bin/curl` (Agent Guard hook) | `api.snyk.io` |
| `/usr/local/bin/snyk` (Studio, Snyk MCP) | `api.snyk.io`, `deeproxy.snyk.io` |
| `node` (npm), `python3.12` (pip), `uv` | `api.snyk.io` only (Dependency Firewall) |

The image also sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, so Claude Code's updater, telemetry and error reporting don't try to connect.

## How TLS inspection is handled

OpenShell's supervisor, not the agent's image, makes the real outbound connections, so a corporate CA baked into the image isn't enough. OpenShell's Docker runtime trusts a corporate CA only through an explicit proxy (`proxy_ca_bundle` requires `https_proxy`). When `run.sh` detects interception it:

1. Exports the root CA (macOS keychain, or the live TLS chain) to `corp-ca/` and `~/.config/openshell/snyk-corp-ca.pem`.
2. Starts a local Squid proxy container (`snyk-openshell-proxy`) on port 3128.
3. Adds a marked block to the OpenShell gateway config with `https_proxy`, `no_proxy` and `proxy_ca_bundle`, validates it with `openshell-gateway config preflight`, backs up the old file and restarts the gateway.

Without interception, it removes that block and the proxy. Rerun `./run.sh` after you turn Zscaler on or off.

## Repository layout

| Path | Purpose |
| --- | --- |
| `run.sh` | The one command: prerequisites, TLS handling, build, credentials, sandbox |
| `policy.yaml` | Pre-approved OpenShell policy (also baked into the image at `/etc/openshell/policy.yaml`) |
| `Dockerfile` | NVIDIA Ubuntu base + Claude Code, Agent Scan/Guard, Snyk CLI, Studio installer, uv, two local MCP servers |
| `sandbox/` | `snyk-openshell-setup` (runs at sandbox start) and `snyk-openshell-rescan` (15-minute rescans) |
| `vendor/` | Install scripts from [snyk/evo-ads-sbx-kit](https://github.com/snyk/evo-ads-sbx-kit), unchanged |
| `demo-skills/` | Two ordinary skills and one **deliberately malicious test skill** |
| `corp-ca/` | Corporate root CA, filled automatically when needed (gitignored) |

> **`demo-skills/canary-risky-skill-TEST` is a detection test fixture.** It contains prompt-injection and exfiltration instructions on purpose, pointed at a reserved `.invalid` domain. Don't install it outside a sandbox.

## Known limitations

- **Snyk credentials are visible to the agent.** The push key and API token are environment variables. Moving them into OpenShell providers is next.
- **`CLAUDE_CODE_OAUTH_TOKEN` is visible to the agent** too. Use `ANTHROPIC_API_KEY` to keep the Claude credential in OpenShell.
- **Binaries must live under `/usr`.** OpenShell only lets the sandbox read and run files from system paths plus `/sandbox`, so nothing is installed into `$HOME` at runtime. Inside the sandbox, `$HOME` is `/sandbox`.
- **NVIDIA's `claude-code` provider profile** doesn't list `platform.claude.com`; `policy.yaml` covers it.
- **Only tested on Apple Silicon.** The scripts handle x86_64, but it hasn't been run there.
- **Unpinned downloads.** The image installs the latest Claude Code, Agent Scan, Snyk CLI, Studio, uv and MCP servers. Snyk binaries are checksum-verified; the Claude Code and uv installers aren't.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
