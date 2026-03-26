# vix-eval

Docker-based test harness for evaluating coding agents in isolated containers.

Each test case is a YAML config. A single `run_test.sh` orchestrates: parse config, build image, run container with mitmproxy + agent, user interacts, then extract artifacts (diff, plan, flow file).

## Prerequisites

- Docker
- Python 3.10+ with `pip`
- Bash 4+

Install host-side dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## .env Setup

```bash
cp .env.example .env
# Edit .env and set your Anthropic API key
```

## Quickstart

```bash
pip install -r requirements.txt
cp .env.example .env && vim .env   # set ANTHROPIC_API_KEY
./run_test.sh tasks/example-test.yaml  --agent cc --settings settings/vix/
```

For single-agent configs (using the `agent:` key), the `--agent` flag is optional:

```bash
./run_test.sh tasks/single-agent-test.yaml
```

## Config Reference

Test configs live in `tasks/` as YAML files.

### Single agent (backward compatible)

```yaml
test_id: my-test              # Required. Unique identifier.
description: "What to do"     # Optional.

repository:
  enabled: true               # Default: true
  url: https://github.com/... # Repo to clone
  commit: ""                  # Optional. Specific commit to checkout.

proxy:
  enabled: true               # Default: true
  listen_host: "127.0.0.1"    # Default. Internal proxy bind address.
  listen_port: 58000          # Default. Proxy port inside container.
  web_port: 8099              # Default. mitmweb UI port (published to host).
  target: "https://api.anthropic.com"  # Default.
  flow_filename: "cc.flow"    # Default.

agent:
  type: claude-code            # Default.
  version: latest              # Default.

environment:
  extra_env:                   # Optional. Additional env vars.
    MY_VAR: "value"
    FROM_HOST: "${HOST_VAR}"   # Interpolated from host environment.
```

### Multi-agent

```yaml
test_id: my-test
description: "What to do"

repository:
  url: https://github.com/...

agents:
  claude-code:
    type: claude-code
    version: latest
  vix:
    type: vix
    version: latest
```

Use `--agent <name>` to select which agent to run:

```bash
./run_test.sh --agent vix tasks/my-test.yaml
```

The `agent` type maps to a Dockerfile: `docker/Dockerfile.<type>`. You cannot specify both `agent:` and `agents:` in the same config.

## Output Artifacts

After a test run, artifacts are saved to `tasks/<task_dir>/results/<agent_name>/<timestamp>/`:

| File | Description |
|------|-------------|
| `changes.diff` | Combined staged + unstaged + untracked changes |
| `plan.md` | Agent's plan file (from `.claude/plans/`) |
| `plans/` | Raw plan files as written by the agent |
| `cc.flow` | mitmproxy flow file (API traffic capture) |

## What Happens When the Container Exits

When you exit the interactive shell (Ctrl-D or `exit`), the following happens automatically before the container shuts down:

1. **Diff generation** (inside container): All changes the agent made to the cloned repo (staged, unstaged, and untracked files) are captured into `/output/changes.diff`. The repo itself is ephemeral and discarded with the container.
2. **Container stops**: The `--rm` flag removes the container. Only the `/output` volume (mapped to `tasks/<task_dir>/results/<agent_name>/<timestamp>/`) survives.
3. **Artifact summary** (on host): `extract_artifacts.sh` runs and prints a summary of what was captured — diff stats, plan files, and flow file size.

Plans and the flow file are written directly to `/output` during the session (via symlinks and mitmproxy's `--save-stream-file`), so they are available immediately.

## Architecture

```
run_test.sh
├── scripts/parse_config.py       # YAML → .env key=value file
├── docker/Dockerfile.<type>      # Agent-specific Dockerfiles
│   ├── Dockerfile.claude-code    # node:20-bookworm + mitmproxy + claude-code
│   └── Dockerfile.vix            # golang:1.22-bookworm + mitmproxy + vix
├── docker/entrypoint.sh          # Clone repo, start proxy, launch shell, generate diff on exit
├── scripts/wait_for_proxy.sh     # Poll mitmweb until ready
└── scripts/extract_artifacts.sh  # Post-run: summarize and copy plan artifacts
```

Each agent type has its own Dockerfile at `docker/Dockerfile.<type>` with all runtime dependencies and the agent itself baked in.

- **Isolation**: Each test runs in a fresh Docker container. The cloned repo lives only inside the container.
- **Proxy**: mitmproxy runs as a reverse proxy to Anthropic's API, capturing all traffic.
- **Artifacts only**: Only the diff, plans, and flow file are persisted to the host — no repo checkout on disk.
- **Security**: `ANTHROPIC_API_KEY` is passed via `-e`, never written to disk in env files.

## Proxy Web UI

While a test is running with `proxy.enabled: true` (the default), mitmweb's web interface is accessible from the host at:

```
http://localhost:8099
```

The UI lets you inspect all API traffic between the agent and Anthropic in real time — requests, responses, headers, and bodies. The port is configurable via `proxy.web_port` in the test config.

## vix-daemon

For `type: vix` agents, `vix-daemon` starts automatically in the background when the container launches. Its working directory is `/workspace` (the cloned repo).

Logs are written to `/output/vix-daemon.log` and persisted to the host alongside other artifacts:

```bash
# Inside container
tail -f /output/vix-daemon.log

# From host
tail -f tasks/<task_dir>/results/<agent_name>/<timestamp>/vix-daemon.log
```

The daemon PID and log path are shown in the container banner at startup.
