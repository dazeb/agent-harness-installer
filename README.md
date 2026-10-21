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

Passing `--backend mise` swaps the whole table for [mise](https://mise.jdx.dev/) specs instead (see
[Version management](#version-management-vendor-installers-or-mise)).

## Version management: vendor installers or mise

Default (`--backend vendor`): each harness is installed by its own vendor installer with npm as
fallback — the path each vendor supports, and the one that keeps self-updating.

If the machine already runs [mise](https://mise.jdx.dev/), you can hand version ownership to it:

```bash
./install-agent-harnesses.sh --backend mise            # install/repair through mise
./install-agent-harnesses.sh --backend mise --check    # verify, touch nothing
./install-agent-harnesses.sh --backend mise --upgrade  # re-resolve @latest for each tool
```

Each tool is written to the global `~/.config/mise/config.toml` with `mise use -g <spec>@latest`,
and the result is verified through `mise which` — so nothing depends on `mise activate` being
loaded in the current shell, and a shim that prints warnings on stderr cannot poison the version
string. Specs come from mise's registry: aqua (signed GitHub releases) where available, npm
otherwise.

| Harness | mise spec | Backend | Notes |
|---|---|---|---|
| claude | `claude` | `aqua:anthropics/claude-code` | also `http:claude` |
| codex | `codex` | `aqua:openai/codex` | npm backend exists too |
| opencode | `opencode` | `aqua:anomalyco/opencode` | |
| gemini | `gemini` | `npm:@google/gemini-cli` | npm backend needs Node on `PATH` |
| amp | `npm:@ampcode/cli` | npm only | the `amp` short name cannot list versions (`mise ls-remote amp` is empty); the package is byte-identical to `@sourcegraph/amp` |
| pi | `pi` | `aqua:earendil-works/pi` | also `github:` / npm |

Why you might prefer it:

- **Pin and roll back** — `mise use -g codex@0.160.0` is one line; the vendor installers only ever
  give you "latest". `mise upgrade` then updates everything together, `mise ls -g` is the inventory.
- **Verified artifacts** — aqua downloads checksummed/signed releases instead of piping an
  `install.sh` into a shell.
- **No sudo, no npm global prefix** — the same reason this script exists.

What it costs:

- mise becomes a dependency (`curl https://mise.run | sh`, or apt/brew): a bare box that has none
  fails fast with that hint rather than silently falling back.
- the npm backend shells out to Node, so Gemini needs a Node runtime in mise's resolution too.
- the registry can lag a vendor release, and `ls-remote` is blind for npm-only names like Amp.

**Do not run both.** Two owners per command name is how a box ends up with `codex` 0.163.0 on
`PATH` while mise still pins 0.160.0 — exactly the drift `--check` surfaces. If you switch, delete
the losing copy (`mise prune`, or the leftover `~/.local/bin` wrapper).

`--fix-path` writes the block that matches your backend: the plain `PATH` entries for vendor
installs, plus `mise activate bash` / `mise activate zsh` when `--backend mise` is in use.

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
  --backend NAME   vendor (default, each vendor's own installer) or mise
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
./install-agent-harnesses.sh --backend mise        # let mise own the versions
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
make lint      # bash -n + shellcheck --severity=warning (all scripts)
make test      # lint, --help, both --backends, unknown tool/backend rejection
make gate      # = ./ci/gate.sh — the canonical gate, used by CI and by ci/run-gate.sh
```

`ci/gate.sh` is the single source of truth: `.github/workflows/ci.yml` is a thin job that runs it, and
`ci/run-gate.sh` runs the same file on a VM when GitHub cannot schedule jobs. It also works on a box
where nothing is installed — the dry runs execute with a scrubbed `HOME`/`PATH`, so the plan is the
same there as on a fully provisioned laptop. There is no build step and no runtime dependency beyond
`bash` and `curl`/`wget` (mise is only touched by `--backend mise`, and the gate proves the
`--backend mise` plan works with no mise on the box at all).

Adding a harness means five things: an entry in `TOOL_ORDER` / `TOOL_LABEL` / `TOOL_BIN`, its
credential path in `TOOL_CREDS` (or env var in `TOOL_ENV`), its `MISE_SPEC` (registry short name,
or an explicit `npm:`/`aqua:` spec), an `install_<tool>()` function that prefers the vendor
installer with an npm fallback, and a row in the table inside `print_auth_guide()`.

## CI when GitHub Actions is unavailable

Sometimes the workflow is valid, the repo says Actions is enabled, registration tokens are still
issued — and nothing ever runs: every dispatch answers `HTTP 422: Actions has been disabled for this
user`. **A self-hosted runner does not fix that.** The runner only executes jobs; if GitHub refuses to
create the workflow run, there is no job to hand out, so the runner sits idle forever.

What is *not* part of Actions is the commit status API, and that is enough to keep a real gate:

```bash
./ci/gate.sh                     # the assertions from ci.yml, no make, no Actions
./ci/run-gate.sh --once          # fetch main -> gate in a container -> post a commit status
./ci/run-gate.sh --loop 300      # poll every 5 minutes instead of using systemd
```

`ci/gate.sh` is the shared payload: `bash -n`, `shellcheck --severity=warning`, `--help`, both
`--dry-run --backend {vendor,mise}` plans, and the two usage-error rejections. `.github/workflows/ci.yml`
and `ci/run-gate.sh` both end up running it, so the verdict is identical either way.

`ci/run-gate.sh` is the runner stand-in. It keeps a mirror clone, gates `origin/main`'s SHA in the
`ci/Dockerfile` image (so the box needs no `shellcheck` of its own), and posts `pending` → `success`
/`failure` under the context `ah-gate`. The commit page shows a check dot and the badge works:

```markdown
![gate](https://img.shields.io/github/commit-status/dazeb/agent-harness-installer/main/ah-gate)
```

Setup on any box with docker (Debian/Ubuntu shown; 4 cores / 2 GB is plenty — the gate is bash):

```bash
sudo install -d /usr/local/lib/ah-gate /var/lib/ah-gate /var/log/ah-gate
sudo install -m 755 ci/run-gate.sh /usr/local/bin/ah-gate
sudo install -m 644 ci/Dockerfile /usr/local/lib/ah-gate/Dockerfile
sudo install -m 600 deploy/ah-gate.env.example /etc/ah-gate.env   # then edit: add AH_GATE_TOKEN
sudo install -m 644 deploy/ah-gate.service deploy/ah-gate.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ah-gate.timer
journalctl -u ah-gate.service -n 20      # first run builds the image, then gates HEAD
```

`AH_GATE_TOKEN` is a classic PAT with `repo` (or a fine-grained token with *Commit statuses: write*).
Without it the gate still runs and logs `PASS`/`FAIL` — you just lose the public status. Keep
`ci.yml` in the repo: the day Actions is usable again, delete the timer and nothing else changes.

Alternative if you want a CI *UI* rather than a status: mirror the repo to a forge you control
(Gitea/Forgejo) and run `act_runner` there. That is a separate CI system, not a GitHub workaround.

## License

MIT — see [LICENSE](LICENSE).
