# agent-harness-installer

[![ci](https://github.com/dazeb/agent-harness-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/dazeb/agent-harness-installer/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

One self-contained Bash script that installs the six mainstream **terminal coding agents** on a
**headless machine** — no browser, no desktop session, no interactive prompts, no `sudo`, nothing
outside `$HOME`.

```console
$ ./install-agent-harnesses.sh --check
    claude    2.1.305 (Claude Code)          ok      yes
    codex     codex-cli 0.163.0              ok      yes
    opencode  1.18.35                        ok      yes
    gemini    0.63.0                         ok      no
    amp       0.0.1792540877-gcc084c (relea... ok      no
    pi        1.3.0                          ok      no
```

## What it installs

| Harness | Command | Vendor | Primary installer | Fallback | Binary lands in |
|---|---|---|---|---|---|
| Claude Code | `claude` | Anthropic | `claude.ai/install.sh` | `@anthropic-ai/claude-code` (npm) | `~/.local/bin/claude` |
| Codex CLI | `codex` | OpenAI | `chatgpt.com/codex/install.sh` | `@openai/codex` (npm) | `~/.local/bin/codex` |
| OpenCode | `opencode` | Anomaly | `opencode.ai/install --no-modify-path` | `opencode-ai` (npm) | `~/.opencode/bin` + symlink |
| Gemini CLI | `gemini` | Google | npm `@google/gemini-cli` | `brew install gemini-cli` | npm global prefix |
| Amp | `amp` | Sourcegraph | `ampcode.com/install.sh` | `@sourcegraph/amp` (npm) | `~/.amp/bin` + symlink |
| Pi | `pi` | Earendil Works | `pi.dev/install.sh` | `@earendil-works/pi-coding-agent` (npm) | `~/.pi/agent` + symlink |

The vendor installer is always preferred; npm is the documented fallback and is only used when the
vendor path fails. Verification is a real `--version` call under `timeout` — a zero exit code from
an installer is not trusted on its own.

## Quick start

```bash
git clone git@github.com:dazeb/agent-harness-installer.git
cd agent-harness-installer
./install-agent-harnesses.sh --check        # what is present / missing, nothing changes
./install-agent-harnesses.sh --dry-run      # show the plan, install nothing
./install-agent-harnesses.sh                # install everything missing
```

Or without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/dazeb/agent-harness-installer/main/install-agent-harnesses.sh \
  | bash -s -- --check
```

Every run ends with a summary table, a headless-authentication checklist, the log directory, and a
non-zero exit code if anything failed.

## Usage

```
./install-agent-harnesses.sh [options]

  --check          report status only; never install   (exit 1 if something is missing)
  --dry-run        print what would be installed; change nothing
  --upgrade        re-run the upstream installer even if the tool already works
  --only TOOLS     restrict to a comma/space list: claude,codex,opencode,gemini,amp,pi
  --skip TOOLS     exclude a comma/space list
  --fix-path       append a guarded PATH block to ~/.profile and ~/.zprofile
  --verbose        stream installer output instead of only logging it
  -h, --help       this help
```

Examples:

```bash
./install-agent-harnesses.sh --only amp,pi         # install just two
./install-agent-harnesses.sh --skip gemini         # everything except Gemini
./install-agent-harnesses.sh --only codex --upgrade
```

Idempotent: tools that already answer `--version` are skipped (or upgraded with `--upgrade`).

## Requirements

- Linux or macOS, `bash` 4+ (arrays, `printf -v`), `curl` or `wget`.
- Node.js 22.19+ **only** for Gemini (npm-only upstream) and Pi — the script checks and skips with an
  explanation rather than trying to install Node or reach for `sudo`.
- Not root: the script refuses to run as `root` because every installer writes into `$HOME`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | every requested harness is installed and answers `--version` (or `--check` found them all) |
| `1` | at least one harness failed, or `--check` found a missing harness |
| `2` | usage error (unknown flag, unknown tool name, missing curl/wget, running as root) |

## Why the installers don't hang

Upstream installers branch on whether stdout is a terminal. Give them a pipe or a bogus `TERM` and
they either hang waiting on `/dev/tty` or silently pick the wrong path. This script sidesteps the
whole class of problems:

- each installer is **downloaded to a temp file first**, then executed as
  `setsid -w CMD </dev/null >>log 2>&1` — its own session, no controlling terminal, stdin at EOF,
  so the `[ -t 1 ]` checks land on the non-interactive branch;
- `CI=1`, `CODEX_NON_INTERACTIVE=1`, `npm_config_yes=true`, `npm_config_fund/audit=false` and
  `DEBIAN_FRONTEND=noninteractive` are exported for children;
- the installer's `--no-modify-path` / `--prefix` style flags are used where they exist, and PATH is
  rebuilt and re-exported after each install instead of relying on a login shell;
- **nothing escalates**: no `sudo`, no `apt`, no writes outside `$HOME` (Pi's installer would
  otherwise try to `apt install nodejs` when Node is too old — this script pre-checks the version
  and skips instead);
- dangling `~/.local/bin/<tool>` and `~/bin/<tool>` symlinks left by an older npm or git install are
  pruned before installing, because they make "installer succeeded" look truthful while
  `command -v` resolves to nothing.

Failure output is the last 25 lines of the log, with the full log kept under
`/tmp/agent-harnesses-<timestamp>/`.

## Authentication (headless)

Installing is the easy half. These agents still need credentials, and none of them can open a
browser for you. The script's built-in **Headless authentication** section prints the exact
commands; the short version:

| Harness | Headless path | Notes |
|---|---|---|
| Claude Code | `claude setup-token` → `export CLAUDE_CODE_OAUTH_TOKEN=…` | long-lived token created from a browser session on another machine; `ANTHROPIC_API_KEY` also works |
| Codex CLI | `codex login --device-auth` | device-code flow: prints a URL + code, paste it into any browser; or use `OPENAI_API_KEY` |
| OpenCode | `opencode auth login` (paste an API key) | providers live in `~/.local/share/opencode/auth.json`; provider env vars also work |
| Gemini CLI | `gemini` then `/auth`, or `GEMINI_API_KEY` | upstream is deprecated in favour of Antigravity CLI (June 2026); still functional |
| Amp | `export AMP_API_KEY=…` | **no device-code flow.** The value must be an access token from `ampcode.com/settings/security`; `amp login` is a browser-callback flow and cannot complete headless. Check with `amp account list` (there is no `whoami`) |
| Pi | `pi` interactive login, or provider env vars | subscriptions (`~/.pi/agent/auth.json`) need a browser/device step; API keys via env are the headless route |

Keep secrets in a `600` file sourced from your profile (e.g. `~/.config/agent-env.sh`), not inline in
shell history. `--check` and the summary treat a tool as credentialed only when its credential file
is non-empty **or** the matching env var is set — `{}` counts as absent.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Installer seems to hang | something is still waiting on a TTY. Run with `--verbose`, then read the log in `/tmp/agent-harnesses-*`. Every installer runs under `timeout`, so a hang surfaces as a failure with a log tail instead of a stuck terminal |
| `installer reported success but <bin> is not runnable` | usually a dangling shim: `command -v <bin>; ls -l "$(command -v <bin>)"`. Re-run the script — it prunes dangling links before installing |
| Version reported is a `mise` warning | fixed: `verify_bin` drops stderr and strips ANSI/CR, and prefers the real binary over a shim |
| `gemini` / `pi` skipped | no `node`/`npm`, or Node < 22.19. Install Node yourself (no sudo here by design) or point npm's prefix at `~/.local` |
| New shell doesn't see a tool | run `--fix-path` (guarded block in `~/.profile` **and** `~/.zprofile`, since zsh login shells skip `.profile`) or source the profile |
| The brew fallback fires in a container | it is the last resort for Gemini only; if Homebrew exists but its registry is unreachable, `--skip gemini` and install via npm |

## Uninstall

Everything is user-space, so removal is a `rm` (or the package manager that installed it):

```bash
rm -rf ~/.local/share/claude ~/.local/bin/claude     # Claude Code (native installer)
rm -rf ~/.codex ~/.local/bin/codex                   # Codex CLI (native installer)
rm -rf ~/.opencode ~/.local/bin/opencode             # OpenCode
npm uninstall -g @google/gemini-cli                  # Gemini CLI
rm -rf ~/.amp ~/.local/bin/amp                       # Amp
rm -rf ~/.pi/agent ~/bin/pi                          # Pi
```

Remove the `# >>> agent-harnesses PATH >>>` block from `~/.profile` / `~/.zprofile` to undo
`--fix-path`.

## Development

```bash
make lint      # bash -n + shellcheck --severity=warning
make test      # lint, --help, --dry-run, unknown-tool rejection
```

`make test` is the same gate as `.github/workflows/ci.yml`, so it can be run locally when hosted CI
is unavailable. There is no build step and no runtime dependency beyond `bash` and `curl`/`wget`.

Adding a harness means four things: an entry in `TOOL_ORDER` / `TOOL_LABEL` / `TOOL_BIN`, its
credential path in `TOOL_CREDS` (or env var in `TOOL_ENV`), an `install_<tool>()` function that
prefers the vendor installer with an npm fallback, and a row in the table inside
`print_auth_guide()`.

## License

MIT — see [LICENSE](LICENSE).
