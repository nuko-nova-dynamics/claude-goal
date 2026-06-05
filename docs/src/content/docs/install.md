---
title: Install
description: Three ways to install claude-goal — marketplace, tarball, or from source.
sidebar:
  order: 1
---

`claude-goal` is a Claude Code plugin. Choose the install method that fits your workflow.

## Marketplace (recommended)

```
/plugin marketplace add nuko-nova-dynamics/claude-marketplace
/plugin install claude-goal@nuko-nova-tools
```

Claude Code clones the plugin, registers the MCP server, and the `/goal-start` skill becomes available immediately. Updates land via `/plugin update claude-goal` once new versions are tagged.

## Release tarball (offline / air-gapped)

```bash
mkdir -p ~/.claude/plugins/local/claude-goal
tar -xzf claude-goal-v0.2.1.tar.gz -C ~/.claude/plugins/local/claude-goal
claude --plugin-dir ~/.claude/plugins/local/claude-goal
```

The tarball ships:

- Prebuilt MCP server (`mcp/goal-server/dist/`)
- Pruned production dependencies (`mcp/goal-server/node_modules/`)
- Skills, hooks, prompts, scripts, statusline
- `LICENSE`, `README.md`, `RELEASE_NOTES.md`, `ROADMAP.md`

The target machine needs **Node 22+** to execute the server. No package-manager install step is required beyond that.

Download tarballs from the [Releases page](https://github.com/nuko-nova-dynamics/claude-goal/releases).

## From git (development / contributors)

```bash
git clone https://github.com/nuko-nova-dynamics/claude-goal.git
cd claude-goal
(cd mcp/goal-server && npm ci && npm run build)
claude --plugin-dir "$PWD"
```

After making changes:

```bash
# Bats — hook scripts, skills, integration loops, release packaging
bats $(find tests -name '*.bats' | sort)

# Vitest — MCP server, migrations, tools, token math, fixtures
npm --prefix mcp/goal-server test
```

## Verify the install

Once installed, run the preflight self-test:

```
/goal-doctor
```

`/goal-doctor` checks SQLite availability, MCP connectivity, hook registration, and shell dependencies. If it reports green, the plugin is ready.

## Requirements

| | |
|---|---|
| **Claude Code** | 2.1.139 or later |
| **Node** | 22.x |
| **OS** | macOS · Linux · WSL (best-effort) |
| **Shell** | bash (the hooks are bash scripts) |
| **Tools** | `sqlite3`, `jq` — usually preinstalled |

Native Windows (cmd.exe or Git Bash without a proper bash layer) is **not supported** — the Stop hook ships a fail-fast guard for that environment.
