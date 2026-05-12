# Contributing to claude-goal

Thanks for taking the time to look. `claude-goal` is a small, focused plugin — the bar for changes is high, but we welcome thoughtful contributions.

## Before you open a PR

Open an issue first if your change is non-trivial. "Non-trivial" means:

- New commands, new hook event handlers, schema migrations
- Changes to budget / cap math, token accounting, or completion paths
- New MCP tools
- Anything that changes the on-disk SQLite schema

For small fixes (typos, doc improvements, obvious bugs), skip the issue and open the PR directly.

## Development setup

```bash
git clone https://github.com/nuko-nova-dynamics/claude-goal.git
cd claude-goal
(cd mcp/goal-server && npm ci && npm run build)
```

Run the plugin locally against Claude Code:

```bash
claude --plugin-dir "$PWD"
```

## Tests

Every change ships with tests. The bar is **all green** on both suites.

```bash
# Hook scripts, skills, integration loops, release packaging, regression probes
bats $(find tests -name '*.bats' | sort)

# MCP server, migrations, tools, token math, fixtures
npm --prefix mcp/goal-server test
```

Current baseline: **131 bats + 59 Vitest = 190 green**. CI on Ubuntu via GitHub Actions blocks merges if anything regresses.

For new behavior:

- **New hook logic** → add a `tests/unit/hooks/*.bats` case
- **New MCP tool** → add `mcp/goal-server/test/*.test.ts` covering happy path + error cases
- **New status transition or schema field** → add to the integration suite under `tests/integration/`
- **New skill or command surface** → if it's user-facing, add a fixture in `tests/fixtures/`

## Style

- **Bash:** `set -euo pipefail` at the top of every script. Quote all variables. Use `[[ ]]` for tests, not `[ ]`. Use `${var:-default}` syntax for defaults.
- **TypeScript (MCP server):** strict mode is on. Use the existing helpers in `src/db.ts` and `src/goals-repo.ts` rather than reaching for raw SQL.
- **Comments:** prefer no comment over a redundant one. Only write a comment when the WHY is non-obvious.
- **Commit messages:** present-tense, imperative ("fix X", not "fixed X"). Reference the issue number if there is one.

## Pull request flow

1. Branch off `main`
2. Run the tests locally before pushing
3. Open the PR with a clear title and a description of what changed and why
4. CI must be green
5. Squash-and-merge is the only merge mode — keep history linear and clean

## Reporting bugs

Open an issue using the **Bug report** template at `.github/ISSUE_TEMPLATE/bug_report.yml`. Include:

- `claude-goal` version (`cat .claude-plugin/plugin.json`)
- Claude Code version (`claude --version`)
- OS + shell
- Minimal repro

## Reporting security issues

See [`SECURITY.md`](SECURITY.md). **Do not open a public issue for security vulnerabilities.**

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
