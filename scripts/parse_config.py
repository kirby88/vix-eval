#!/usr/bin/env python3
"""Parse a test config YAML and emit a .env-format key=value file."""

import argparse
import os
import re
import sys

import yaml
from pydantic import BaseModel, Field, ValidationError, model_validator


class RepositoryConfig(BaseModel):
    enabled: bool = True
    url: str = ""
    commit: str = ""



class ProxyConfig(BaseModel):
    enabled: bool = True
    listen_host: str = "127.0.0.1"
    listen_port: int = 58000
    web_port: int = 8099
    target: str = "https://api.anthropic.com"
    flow_filename: str = "requests.flow"


class AgentConfig(BaseModel):
    type: str = "claude-code"
    version: str = "latest"


class OutputConfig(BaseModel):
    diff: bool = True
    plan: bool = True
    flow: bool = True


class EnvironmentConfig(BaseModel):
    extra_env: dict[str, str] = Field(default_factory=dict)


class TestConfig(BaseModel):
    test_id: str
    description: str = ""
    repository: RepositoryConfig = Field(default_factory=RepositoryConfig)
    workspace: str = ""
    languages: list[str] = Field(default_factory=list)
    proxy: ProxyConfig = Field(default_factory=ProxyConfig)
    agent: AgentConfig | None = None
    agents: dict[str, AgentConfig] | None = None
    output: OutputConfig = Field(default_factory=OutputConfig)
    environment: EnvironmentConfig = Field(default_factory=EnvironmentConfig)

    @model_validator(mode="after")
    def validate_agent_fields(self):
        if self.agent is not None and self.agents is not None:
            raise ValueError("Cannot specify both 'agent' and 'agents'")
        if self.agent is None and self.agents is None:
            self.agent = AgentConfig()
        return self

    # CLI aliases for agent names (e.g. --agent cc → claude-code)
    AGENT_ALIASES: dict[str, str] = {"cc": "claude-code"}

    def resolve_agent(self, agent_name: str | None) -> tuple[str, AgentConfig]:
        """Resolve which agent to use. Returns (name, config)."""
        # Expand aliases
        if agent_name is not None:
            agent_name = self.AGENT_ALIASES.get(agent_name, agent_name)

        if self.agent is not None:
            # Single-agent mode: --agent flag is optional
            name = agent_name if agent_name else self.agent.type
            return (name, self.agent)

        # Multi-agent mode: --agent flag is required
        assert self.agents is not None
        available = list(self.agents.keys())
        if agent_name is None:
            print(
                f"Error: config defines multiple agents. Use --agent to select one: {', '.join(available)}",
                file=sys.stderr,
            )
            sys.exit(1)
        if agent_name not in self.agents:
            print(
                f"Error: unknown agent '{agent_name}'. Available: {', '.join(available)}",
                file=sys.stderr,
            )
            sys.exit(1)
        return (agent_name, self.agents[agent_name])


def interpolate_env(value: str) -> str:
    """Resolve ${VAR} references using os.environ."""
    return re.sub(
        r"\$\{([^}]+)\}",
        lambda m: os.environ.get(m.group(1), ""),
        value,
    )


def emit_env(config: TestConfig, agent_name: str, agent_config: AgentConfig, config_dir: str, output) -> None:
    """Write .env-format key=value pairs to output."""
    lines = [
        ("TEST_ID", config.test_id),
        ("REPO_ENABLED", str(config.repository.enabled).lower()),
        ("REPO_URL", config.repository.url),
        ("REPO_COMMIT", config.repository.commit),
        ("PROXY_ENABLED", str(config.proxy.enabled).lower()),
        ("PROXY_LISTEN_HOST", config.proxy.listen_host),
        ("PROXY_LISTEN_PORT", str(config.proxy.listen_port)),
        ("PROXY_WEB_PORT", str(config.proxy.web_port)),
        ("PROXY_TARGET", config.proxy.target),
        ("FLOW_FILENAME", config.proxy.flow_filename),
        ("AGENT_NAME", agent_name),
        ("AGENT_TYPE", agent_config.type),
        ("AGENT_VERSION", agent_config.version),
        ("LANGUAGES", ",".join(config.languages)),
    ]

    for key, value in lines:
        output.write(f'{key}={value}\n')

    # Workspace directory: resolve relative to config file
    if config.workspace:
        abs_workspace = os.path.normpath(os.path.join(config_dir, config.workspace))
        output.write(f'WORKSPACE_DIR={abs_workspace}\n')

    for key, value in config.environment.extra_env.items():
        resolved = interpolate_env(value)
        output.write(f'{key}={resolved}\n')


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse test config YAML")
    parser.add_argument("config", help="Path to YAML config file")
    parser.add_argument("--output", "-o", default=None, help="Output file (default: stdout)")
    parser.add_argument("--agent", "-a", default=None, help="Agent name to select (required for multi-agent configs)")
    args = parser.parse_args()

    try:
        with open(args.config) as f:
            raw = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"Error: config file not found: {args.config}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error: invalid YAML: {e}", file=sys.stderr)
        sys.exit(1)

    if raw is None:
        print("Error: config file is empty", file=sys.stderr)
        sys.exit(1)

    try:
        config = TestConfig(**raw)
    except ValidationError as e:
        print(f"Error: config validation failed:\n{e}", file=sys.stderr)
        sys.exit(1)

    agent_name, agent_config = config.resolve_agent(args.agent)
    config_dir = os.path.dirname(os.path.abspath(args.config))

    if args.output:
        with open(args.output, "w") as f:
            emit_env(config, agent_name, agent_config, config_dir, f)
    else:
        emit_env(config, agent_name, agent_config, config_dir, sys.stdout)


if __name__ == "__main__":
    main()
