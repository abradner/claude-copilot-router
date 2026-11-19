# claude-copilot-router

Run the [Claude Code](https://code.claude.com) CLI on the Claude models in your GitHub Copilot
plan. A local [LiteLLM](https://github.com/BerriAI/litellm) proxy on `127.0.0.1` forwards Claude
Code's Anthropic Messages requests to Copilot, and a separate Claude Code profile
(`CLAUDE_CONFIG_DIR`) keeps this setup apart from your normal one.

```
claude-copilot ──► LiteLLM proxy (127.0.0.1:4141) ──► GitHub Copilot /v1/messages
 (own profile)       key via apiKeyHelper              your GitHub token, your seat
```

> **Check the terms first.** GitHub does not list the Claude Code CLI as a supported Copilot
> client. LiteLLM's `github_copilot` provider signs in as GitHub's own Copilot editor plugin and
> calls undocumented Copilot endpoints. That may conflict with GitHub's terms or your
> employer's AI policy, and GitHub may rate-limit or suspend Copilot access it considers abusive.
> If your Copilot seat belongs to an organisation, get written approval before using this.
> Officially supported alternatives: the Claude agent in VS Code's Agents window and GitHub's
> Claude coding agent, both billed to Copilot.

## Requirements

- macOS on Apple Silicon (the hash-locked `cryptography` wheel is arm64-only on macOS).
- Claude Code **2.1.304 or later** (`claude update`). Earlier versions don't retry on their own
  when an upstream rejects a newer request feature, so you'd see more `400` errors.
- [uv](https://docs.astral.sh/uv/) (`brew install uv`).
- A GitHub account with a Copilot plan that includes Claude models (an org admin may have to
  enable them).

## Setup

```bash
git clone https://github.com/abradner/claude-copilot-router && cd claude-copilot-router
```

Clone it anywhere except `~/.config/claude-copilot-router`: that is where the router keeps its
state, and the installer refuses to use a git checkout there.

```bash
./install.sh
```

Installs LiteLLM into a private venv from a hash-locked, wheels-only lock file, creates a random
proxy key, the proxy config, the `~/.claude-copilot` profile and a `claude-copilot` alias in
`~/.zshrc`. No sign-in yet.

```bash
./login.sh
```

GitHub device flow. It prints a URL and a code: open `github.com/login/device` in a browser
signed in to the account with the Copilot seat, enter the code within a minute, approve
"GitHub Copilot Plugin", and authorize SSO for your org if asked.

```bash
./models.sh
```

Lists the Claude ids your seat may use, with context and output limits. If they differ from the
defaults (`claude-sonnet-5.5`, `claude-opus-5.5`, `claude-haiku-5.5`), set them:

```bash
./install.sh --sonnet claude-sonnet-5.5 --opus claude-opus-5.5 --haiku claude-haiku-5.5
```

## Use

Terminal 1, leave it running:

```bash
./run.sh
```

Terminal 2:

```bash
./smoke.sh
```

```bash
exec zsh && claude-copilot
```

`smoke.sh` checks that the proxy refuses a request without the key, then a hello, streaming and
tool use, and prints which model answered. In Claude Code, `/status` should show base URL
`http://127.0.0.1:4141` and auth source `apiKeyHelper`. Plain `claude` is unchanged.

## Options

Pass to `./install.sh`; they are saved in `~/.config/claude-copilot-router/router.conf` and reused
on the next run. (All router state lives under `$XDG_CONFIG_HOME/claude-copilot-router` when
`XDG_CONFIG_HOME` is set; keep it the same between runs.)

| Flag | Default | |
|---|---|---|
| `--port N` | `4141` | 4000 is refused: LiteLLM silently moves to a random port when 4000 is busy |
| `--profile DIR` | `~/.claude-copilot` | a directory under `$HOME` (letters, digits, `._/@+-`; relative paths and symlinks are resolved). Never `~/.claude`, `~/.config`, anything inside them, or the `CLAUDE_CONFIG_DIR` of the shell you run it from (unless that is the router's own profile). To move it later, run `./uninstall.sh` first |
| `--alias NAME` | `claude-copilot` | shell alias that starts Claude Code with this profile (not `claude`) |
| `--sonnet` / `--opus` / `--haiku ID` | `claude-*-5.5` | Copilot model ids from `./models.sh` |
| `--main sonnet\|opus\|haiku` | `sonnet` | model Claude Code starts on |
| `--link-from DIR` | | share an existing setup, below |
| `--no-hooks` | | with `--link-from`: link only, don't copy hooks (ignored otherwise) |
| `--unlink` | | undo `--link-from` |
| `--adopt` | | use an existing Claude Code config dir (one with a `.claude.json`) as `--profile`; uninstall then leaves the dir, removes the router's links and marker, and puts back the settings the router replaced |

Re-running `./install.sh` is safe: it rewrites only the keys it owns in the profile's
`settings.json` (`apiKeyHelper` and its `env` entries) and keeps everything else, including hooks.
The first run saves what those keys held, for uninstall to restore. If the profile's
`settings.json` is a symlink or not valid JSON, the installer stops before changing anything: it never
writes through a link, so it cannot change the file a link points at (say `~/.claude/settings.json`).

## Your normal Claude Code setup and this one

The router profile is a separate `CLAUDE_CONFIG_DIR`.

| | Shared with your normal `~/.claude`? |
|---|---|
| Project files: a repo's `CLAUDE.md`, `.claude/skills`, `.claude/settings.json` | yes, they live in the repo |
| User skills, user `CLAUDE.md` | no, unless you use `--link-from` |
| Hooks, status line, output style | no, unless you use `--link-from` (copied) |
| Plugins | no: install them inside `claude-copilot` with `/plugin` |
| Permissions, memory, history, sessions, sign-in | no, never |
| Messaging between sessions | probably not: each profile keeps its own session registry |

To share an existing setup:

```bash
./install.sh --link-from ~/.claude
```

This links `skills/` and `CLAUDE.md` (so they stay in step) and copies `hooks`, `statusLine` and
`outputStyle` from `~/.claude/settings.json`, printing each hook. The source is only read.
Permissions and `env` are never copied. Run it again after changing hooks; `./install.sh --unlink`
removes the links and restores whatever those keys held in the router profile before.

**Billing gotcha:** anything started from a `claude-copilot` session inherits its profile. A hook
or script that runs `claude -p` therefore goes through the proxy and spends Copilot usage. Jobs
started outside it (cron, launchd) still use your normal profile and account.

## What works and what doesn't

- Streaming, tool use, effort and the beta headers Claude Code sends: forwarded unchanged to
  Copilot's native `/v1/messages`.
- **WebSearch** doesn't work (Copilot doesn't run server-side web search). WebFetch does.
- **Auto mode** works, with Claude Code's own classifier requests: they go through the proxy and
  use Copilot quota. Its no-charge server-side checks need an upstream that handles Anthropic's
  `safeguards` request field, which Copilot doesn't, so the profile sets
  `CLAUDE_CODE_AUTO_MODE_SERVER=0`. That also stops the "this session isn't eligible" notice,
  which otherwise holds the first checked action until you press Enter. Claude Code calls the
  variable temporary; if a release drops it, expect the notice back.
- The context window is likely smaller than in VS Code. Stay under the `ctx=` limit from
  `./models.sh` and don't use `[1m]` model ids.
- Prompt caching: unverified. On the second turn of a long chat, `/cost` should show cache reads.
- Copilot bills by token. Long contexts and compaction add up; check your usage on GitHub.

## Security

- Secrets live in `~/.config/claude-copilot-router/` (mode 0700): `master-key`, `hdr` and
  `tokens/` (a long-lived GitHub token and a short-lived Copilot token). Don't sync, back up to
  the cloud, paste or commit it. Optional: `tmutil addexclusion ~/.config/claude-copilot-router`.
- No secret is ever passed on a command line: the key goes file → environment, `apiKeyHelper`
  reads the file, curl reads a header file.
- The proxy binds `127.0.0.1` only, refuses requests without the key, runs with an allow-listed
  environment (no debug flags, database URLs, metrics ports or token-URL overrides can leak in),
  doesn't load `.env` files, and has its admin UI off. Never start LiteLLM by hand with
  `--detailed_debug`: it logs request headers.
- The `claude-copilot` alias unsets any exported Anthropic keys, tokens and provider switches,
  and the profile's `env` blanks the same variables, so only the proxy key is sent. Non-essential traffic to Anthropic is off.
- Corporate TLS inspection: LiteLLM trusts `SSL_CERT_FILE` or its bundled CA list, not the macOS
  Keychain. Export `SSL_CERT_FILE=/path/to/roots.pem` (or `REQUESTS_CA_BUNDLE`) before `./run.sh`.
- Each person signs in with their own GitHub account. Never share token files, a proxy or a key.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `400` naming a beta, `context_management`, `strict` or `output_config` | update Claude Code; else add `"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"` to the profile's `settings.json` `env` |
| `400` model not supported | wrong id or not enabled for your seat: `./models.sh`, then `./install.sh --sonnet …` |
| `401` from the proxy | `./run.sh` isn't running, or the key changed: rerun `./install.sh` |
| `401`/`403` from Copilot | no seat, SSO not authorized or token revoked: `rm ~/.config/claude-copilot-router/tokens/*`, `./login.sh` |
| `port … already in use` | `lsof -nP -iTCP:4141 -sTCP:LISTEN` (use your port), or reinstall with `--port` |
| certificate errors | set `SSL_CERT_FILE`, above |
| switch GitHub account | `rm ~/.config/claude-copilot-router/tokens/*`, `./login.sh` |

## Updating LiteLLM

LiteLLM is pinned (`requirements.in`) and installed from `requirements.lock` with
`--require-hashes --only-binary :all:`. To move to a new version, check
[its security advisories](https://github.com/BerriAI/litellm/security/advisories), edit
`requirements.in`, then:

```bash
uv pip compile --universal --generate-hashes --python-version 3.12 --only-binary :all: --no-header -o requirements.lock requirements.in
```

Run the tests, then `./install.sh` to sync the venv.

## Uninstall

```bash
./uninstall.sh
```

Removes the venv, tokens, key, config and alias, and the router profile if this tool created it.
An `--adopt`ed profile stays: the router's links and marker are removed and the settings it replaced
are restored. If that saved state is missing, only values that are plainly the router's are removed,
and uninstall names any it kept for you to check. A profile whose marker is missing or unrecognised is left alone.
Shared links are removed, never followed. Then revoke the token on GitHub: Settings →
Applications → Authorized GitHub Apps → GitHub Copilot Plugin (this also signs out other editors
that use that app).

## Tests

```bash
python3 -I tests/test_settings_merge.py && zsh -f tests/test_lib.zsh
```

No network, uv or GitHub needed. CI runs them on macOS.

## Licence

MIT, see [LICENSE](LICENSE). Not affiliated with Anthropic, GitHub or BerriAI.
