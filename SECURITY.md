# Security policy

## Supported versions

Only the latest tagged release of `claude-goal` receives security fixes. Older versions are not patched. Check the [Releases page](https://github.com/nuko-nova-dynamics/claude-goal/releases) for the current version and upgrade if you're behind.

| Version | Supported |
|---|---|
| Latest tag | ✓ |
| Anything older | ✗ |

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Email `hello@nukonova.com` with:

- A clear description of the issue
- Reproduction steps (a minimal test case if possible)
- The affected version (`claude-goal` plugin version and Claude Code version)
- Your assessment of severity and potential impact
- Any suggested mitigation

You can also use GitHub's [private vulnerability reporting](https://github.com/nuko-nova-dynamics/claude-goal/security/advisories/new) for this repository.

## Response timeline

- **Acknowledgment** within 72 hours
- **Initial triage** within 7 days
- **Fix or mitigation plan** within 30 days for confirmed high-severity issues

If we cannot meet these targets, we will communicate updated timelines proactively.

## Scope

In scope:

- The plugin's hook scripts (`scripts/*.sh`) and any subprocess they spawn
- The MCP server (`mcp/goal-server/`) — auth, input validation, SQL injection, secret leakage
- The SQLite schema and migration runner — data corruption, downgrade-protection bypass
- The completion evaluator subagent — verdict spoofing, tool surface escape
- The statusline script

Out of scope:

- Vulnerabilities in Claude Code itself — please report those to Anthropic
- Vulnerabilities in upstream dependencies (`@modelcontextprotocol/sdk`, `better-sqlite3`, etc.) — please report to their maintainers and CC us if it affects this plugin
- Social engineering, physical access, denial-of-service via runaway autonomous goals (the wall-clock cap is the safety primitive for that)

## Disclosure

We coordinate disclosure with the reporter. Default policy: public disclosure once a fix has shipped in a tagged release, with credit to the reporter unless they prefer anonymity.
