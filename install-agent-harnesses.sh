#!/usr/bin/env bash
# =============================================================================
# install-agent-harnesses.sh
#
# Installs the six terminal coding-agent harnesses from the "Agent" panel:
#
#   claude    Claude Code   Anthropic      https://claude.com/product/claude-code
#   codex     Codex CLI     OpenAI         https://developers.openai.com/codex
#   opencode  OpenCode      Anomaly        https://opencode.ai
#   gemini    Gemini CLI    Google         https://geminicli.com
#   amp       Amp CLI       Sourcegraph    https://ampcode.com
#   pi        Pi            Earendil Works https://pi.dev
#
# DESIGNED FOR A HEADLESS LINUX BOX (no browser, no desktop session, no sudo):
#
#   * Every upstream installer runs under `setsid -w` with stdin from
#     /dev/null and stdout to a log file. The child has no controlling
#     terminal, so the `[ -t 1 ]` / `/dev/tty` prompt paths inside the
#     installers take their non-interactive branch instead of hanging.
#   * Nothing is installed system-wide. Binaries land in $HOME only:
#     ~/.local/bin (claude, codex, amp, pi), ~/.opencode/bin (opencode),
#     npm's user prefix (gemini). No sudo, no apt.
#   * PATH is exported for this process, and persisted only with --fix-path.
#   * Idempotent: already-working harnesses are skipped unless --upgrade.
#   * Prints the exact headless auth recipe per harness (device code, CLI
#     token, or env var) instead of pretending a browser login will work.
#
# Usage:
#   ./install-agent-harnesses.sh                 install whatever is missing
#   ./install-agent-harnesses.sh --upgrade       re-run upstream installers
#   ./install-agent-harnesses.sh --check         verify only, install nothing
#   ./install-agent-harnesses.sh --only claude,pi
#   ./install-agent-harnesses.sh --skip gemini
#   ./install-agent-harnesses.sh --fix-path      persist PATH to profile
#   ./install-agent-harnesses.sh --verbose       print installer logs
#   ./install-agent-harnesses.sh --dry-run       show the plan only
#   ./install-agent-harnesses.sh --help
#
# Exit codes: 0 all requested harnesses installed+verified, 1 otherwise, 2 usage.
#
# Repo: https://github.com/dazeb/agent-harness-installer   (MIT)
# Note: Gemini has no vendor script for Linux — it installs from npm and treats
#       Homebrew as a last resort. In a container where brew exists but its
#       registry is blocked, prefer:  --skip gemini  (then npm install manually).
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------

TOOL_ORDER=(claude codex opencode gemini amp pi)

declare -A TOOL_LABEL=(
    [claude]="Claude Code (Anthropic)"
    [codex]="Codex CLI (OpenAI)"
    [opencode]="OpenCode (Anomaly)"
    [gemini]="Gemini CLI (Google)"
    [amp]="Amp CLI (Sourcegraph)"
    [pi]="Pi (Earendil Works)"
)

# Binary that must exist on PATH afterwards (amp/pi install into their own dir
# and get symlinked into a PATH dir by their installers).
declare -A TOOL_BIN=(
    [claude]=claude
    [codex]=codex
    [opencode]=opencode
    [gemini]=gemini
    [amp]=amp
    [pi]=pi
)

# Local credential files, used only as a "probably logged in" heuristic.
declare -A TOOL_CREDS=(
    [claude]="$HOME/.claude/.credentials.json"
    [codex]="$HOME/.codex/auth.json"
    [opencode]="$HOME/.local/share/opencode/auth.json"
    [gemini]="$HOME/.gemini/oauth_creds.json"
    [amp]="$HOME/.config/amp/settings.json"
    [pi]="$HOME/.pi/agent/auth.json"
)

# Env vars that make a harness usable without any login step at all.
declare -A TOOL_ENV=(
    [claude]="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
    [codex]="OPENAI_API_KEY"
    [opencode]="ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY"
    [gemini]="GEMINI_API_KEY GOOGLE_APPLICATION_CREDENTIALS"
    [amp]="AMP_API_KEY"
    [pi]="ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY"
)


declare -A STATUS=()   # ok | planned | failed | skipped
declare -A VERSION=()  # version string reported by --version
declare -A METHOD=()   # how it was installed

UPGRADE=0
CHECK_ONLY=0
DRY_RUN=0
FIX_PATH=0
VERBOSE="${VERBOSE:-}"
ONLY=""
SKIP=""

LOG_DIR="${TMPDIR:-/tmp}/agent-harnesses-$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

section() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info()    { printf '    %s\n' "$*"; }
ok()      { printf '    %s[ok]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skipmsg() { printf '    %s[skip]%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()    { printf '    %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
failmsg() { printf '    %s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

usage() { sed -n '28,39p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Prune a stale symlink left behind by an older npm/git install. Left in place,
# these break `command -v` lookups and make installers pick a different bin dir.
prune_dangling() {
    local p=$1
    if [ -L "$p" ] && [ ! -e "$p" ]; then
        rm -f "$p" && info "removed stale symlink $p"
    fi
}

# has_creds TOOL -> yes | yes (env VAR) | no
# A file that exists but is empty or `{}` (pi writes that before first login)
# is not a credential.
has_creds() {
    local tool=$1 f=${TOOL_CREDS[$1]:-} v first2
    if [ -n "$f" ] && [ -s "$f" ]; then
        first2=$(head -c 2 "$f" 2>/dev/null)
        if [ "$first2" != "{}" ]; then printf 'yes'; return 0; fi
    fi
    for v in ${TOOL_ENV[$tool]:-}; do
        if [ -n "${!v:-}" ]; then printf 'yes (env %s)' "$v"; return 0; fi
    done
    printf 'no'
}


# version_ge A B  -> true when A >= B (sort -V semantics)
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

node_version() {
    have node || return 0
    node -v 2>/dev/null | sed 's/^v//'
}

# download URL DEST — curl first, wget fallback, retries included.
download() {
    local url=$1 dest=$2
    if have curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
             --max-time 900 "$url" -o "$dest" && return 0
    fi
    if have wget; then
        wget -q --tries=3 --timeout=60 "$url" -O "$dest" && return 0
    fi
    return 1
}

# Pick the interpreter the upstream installer asks for (its shebang).
installer_interp() {
    local script=$1 first
    first=$(sed -n '1s/^#![[:space:]]*//p' "$script" 2>/dev/null)
    case "$first" in
        *bash*) printf 'bash' ;;
        *sh*)   printf 'sh' ;;
        *)      printf 'bash' ;;
    esac
}

# run_detached LOGFILE CMD... — run with no controlling terminal.
# This is the core of headless safety: without /dev/tty no prompt can block.
run_detached() {
    local log=$1; shift
    if have setsid; then
        setsid -w "$@" </dev/null >>"$log" 2>&1
    else
        "$@" </dev/null >>"$log" 2>&1
    fi
}

show_log_tail() {
    local log=$1
    [ -s "$log" ] || return 0
    tail -n 25 "$log" | sed 's/^/    | /' >&2
}

# run_upstream_installer NAME URL [ARGS...]
# Download first, then execute: avoids partial-pipe execution, lets us keep a
# log, and keeps the installer away from the controlling TTY.
run_upstream_installer() {
    local name=$1 url=$2; shift 2
    local script log interp rc
    mkdir -p "$LOG_DIR"
    log="$LOG_DIR/$name-install.log"
    script=$(mktemp "${TMPDIR:-/tmp}/${name}-install.XXXXXX.sh") || return 1

    info "download $url"
    download "$url" "$script"
    if [ ! -s "$script" ]; then
        failmsg "could not download $url"
        rm -f "$script"
        return 1
    fi

    interp=$(installer_interp "$script")
    info "run installer ($interp, no tty; log: $log)"
    run_detached "$log" "$interp" "$script" "$@"
    rc=$?
    rm -f "$script"

    if [ "$rc" -ne 0 ]; then
        failmsg "$name installer exited $rc"
        show_log_tail "$log"
    elif [ -n "$VERBOSE" ] && [ -s "$log" ]; then
        sed 's/^/    | /' "$log"
    fi
    return "$rc"
}

# npm_global_install PKG [ARGS...] — quiet, non-interactive global install.
npm_global_install() {
    local pkg=$1; shift
    local log slug rc
    mkdir -p "$LOG_DIR"
    slug=$(printf '%s' "$pkg" | tr '/@' '__')
    log="$LOG_DIR/npm-$slug.log"
    info "npm install -g $pkg $*"
    run_detached "$log" npm install -g "$pkg" "$@" \
        --no-audit --no-fund --loglevel=error
    rc=$?
    if [ "$rc" -ne 0 ]; then
        failmsg "npm install -g $pkg failed (log: $log)"
        show_log_tail "$log"
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Per-harness installers.
#
# The vendor's own installer is always preferred (it places the binary in a
# predictable user dir and is the supported path); the npm package is the
# documented fallback.
# ---------------------------------------------------------------------------

install_claude() {
    # Native installer -> ~/.local/bin/claude, data in ~/.local/share/claude.
    if run_upstream_installer claude https://claude.ai/install.sh; then
        METHOD[claude]="native installer (~/.local/bin)"
        return 0
    fi
    if ! have npm; then
        failmsg "native installer failed and npm is not available"
        return 1
    fi
    warn "native installer failed, falling back to npm"
    npm_global_install @anthropic-ai/claude-code || return 1
    METHOD[claude]="npm (@anthropic-ai/claude-code)"
}

install_codex() {
    # Standalone installer -> ~/.local/bin/codex, releases in ~/.codex/packages.
    # CODEX_NON_INTERACTIVE is exported globally so it never asks "Start now?".
    if run_upstream_installer codex https://chatgpt.com/codex/install.sh; then
        METHOD[codex]="standalone installer (~/.codex/packages)"
        return 0
    fi
    if ! have npm; then
        failmsg "standalone installer failed and npm is not available"
        return 1
    fi
    warn "standalone installer failed, falling back to npm"
    npm_global_install @openai/codex || return 1
    METHOD[codex]="npm (@openai/codex)"
}

install_opencode() {
    # --no-modify-path: we manage PATH ourselves instead of letting the
    # installer append to ~/.zshrc / ~/.bashrc behind our back.
    # NOTE: this installs OpenCode 1 (`opencode`). OpenCode 2 ships as
    # `opencode2` and cannot take over the default command name.
    if run_upstream_installer opencode https://opencode.ai/install --no-modify-path; then
        METHOD[opencode]="native installer (~/.opencode/bin)"
        return 0
    fi
    if ! have npm; then
        failmsg "native installer failed and npm is not available"
        return 1
    fi
    warn "native installer failed, falling back to npm"
    npm_global_install opencode-ai || return 1
    METHOD[opencode]="npm (opencode-ai)"
}

install_gemini() {
    # Gemini CLI is npm-only on Linux besides Homebrew; no standalone installer.
    if have npm; then
        if npm_global_install @google/gemini-cli; then
            METHOD[gemini]="npm (@google/gemini-cli)"
            return 0
        fi
    fi
    if have brew; then
        warn "npm install failed, falling back to Homebrew"
        mkdir -p "$LOG_DIR"
        if run_detached "$LOG_DIR/gemini-brew.log" brew install gemini-cli; then
            METHOD[gemini]="homebrew (gemini-cli)"
            return 0
        fi
        show_log_tail "$LOG_DIR/gemini-brew.log"
    fi
    failmsg "could not install Gemini CLI (needs Node >= 20 with npm, or brew)"
    return 1
}

install_amp() {
    # Native installer -> ~/.amp/bin/amp, symlinked into ~/.local/bin.
    if run_upstream_installer amp https://ampcode.com/install.sh; then
        METHOD[amp]="native installer (~/.amp/bin)"
        return 0
    fi
    if ! have npm; then
        failmsg "native installer failed and npm is not available"
        return 1
    fi
    warn "native installer failed, falling back to npm"
    npm_global_install @sourcegraph/amp || return 1
    METHOD[amp]="npm (@sourcegraph/amp)"
}

install_pi() {
    # Managed installer -> ~/.pi/agent/install plus a symlink in a PATH dir.
    # It refuses to run without Node >= 22.19 (otherwise it would try to
    # install Node via apt/sudo, which a headless box without a sudo password
    # must never attempt from a script).
    local nv
    nv=$(node_version)
    if [ -z "$nv" ] || ! version_ge "$nv" "22.19.0"; then
        failmsg "Pi needs Node >= 22.19 (found: ${nv:-none}); install Node 22 first (nvm) and re-run"
        return 1
    fi
    if run_upstream_installer pi https://pi.dev/install.sh; then
        METHOD[pi]="managed installer (~/.pi/agent)"
        return 0
    fi
    if ! have npm; then
        failmsg "managed installer failed and npm is not available"
        return 1
    fi
    warn "managed installer failed, falling back to npm"
    # --ignore-scripts is what Pi's own docs use for the npm path.
    npm_global_install @earendil-works/pi-coding-agent --ignore-scripts || return 1
    METHOD[pi]="npm (@earendil-works/pi-coding-agent)"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# verify_bin CMD -> echoes a version string; non-zero when the binary is dead.
verify_bin() {
    local cmd=$1 out
    for flag in --version -v; do
        # stderr is dropped on purpose: shims (mise) print warnings there and
        # they would otherwise be mistaken for the version string.
        out=$(timeout 120 "$cmd" "$flag" </dev/null 2>/dev/null | head -n1)
        out=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
        if [ -n "${out//[[:space:]]/}" ] &&
           ! printf '%s' "$out" | grep -qiE 'unknown (flag|option)|unrecognized|usage:'; then
            printf '%s' "$out"
            return 0
        fi
    done
    if timeout 60 "$cmd" --help </dev/null >/dev/null 2>&1; then
        printf 'installed (no --version)'
        return 0
    fi
    return 1
}

# installed_ok TOOL — binary present AND actually starts.
installed_ok() {
    local tool=$1 bin=${TOOL_BIN[$1]}
    have "$bin" || return 1
    case "$tool" in
        claude)   timeout 120 claude --version </dev/null >/dev/null 2>&1 ;;
        *)        timeout 60 "$bin" --version </dev/null >/dev/null 2>&1 ;;
    esac
}

is_selected() {
    local tool=$1
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$tool,"*) ;; *) return 1 ;; esac
    fi
    if [ -n "$SKIP" ]; then
        case ",$SKIP," in *",$tool,"*) return 1 ;; esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# PATH handling
# ---------------------------------------------------------------------------

PATH_DIRS=("$HOME/.local/bin" "$HOME/.opencode/bin" "$HOME/.amp/bin" "$HOME/.pi/agent/bin")

build_path() {
    local d out="" IFS=:
    for d in "${PATH_DIRS[@]}" $PATH; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        case ":$out:" in *":$d:"*) continue ;; esac
        out="$out:$d"
    done
    printf '%s' "${out#:}"
}

ensure_bin_dir() { [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin"; }

# Export a deduped PATH with the harness dirs first. Assignment is split from
# the export to keep the tool's return value (and linters) happy.
refresh_path() {
    local p
    p=$(build_path)
    export PATH="$p"
}

persist_path() {
    local targets=("$HOME/.profile") t
    # zsh login shells read .zprofile, not .profile.
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        targets+=("${ZDOTDIR:-$HOME}/.zprofile")
    fi
    for t in "${targets[@]}"; do
        if [ -f "$t" ] && grep -qF '# >>> agent-harnesses PATH >>>' "$t"; then
            info "$t already patched"
            continue
        fi
        mkdir -p "$(dirname "$t")"
        cat >>"$t" <<'EOF'

# >>> agent-harnesses PATH >>>
# Added by install-agent-harnesses.sh — keeps user-space agent CLIs on PATH.
for _ah_dir in "$HOME/.local/bin" "$HOME/.opencode/bin" "$HOME/.amp/bin" "$HOME/.pi/agent/bin"; do
    case ":$PATH:" in
        *":$_ah_dir:"*) ;;
        *) [ -d "$_ah_dir" ] && PATH="$_ah_dir:$PATH" ;;
    esac
done
export PATH
unset _ah_dir
# <<< agent-harnesses PATH <<<
EOF
        ok "patched $t"
    done
    info "open shells still need: export PATH=\"\$HOME/.local/bin:\$PATH\""
}

# ---------------------------------------------------------------------------
# Auth guidance — the part that actually bites on a headless box
# ---------------------------------------------------------------------------

print_auth_guide() {
    section "Headless authentication"
    cat <<'EOF'
  None of these tools can finish a browser login on a box with no browser.
  Use the device-code / token / env-var path for each one.

  claude  (Claude Code)
    1) On a machine WITH a browser:  claude setup-token
       -> one-year OAuth token (Pro/Max/Team/Enterprise plans)
    2) On the headless box:          export CLAUDE_CODE_OAUTH_TOKEN=<token>
       or with a Console key:        export ANTHROPIC_API_KEY=sk-ant-...
    3) Smoke test:                   claude -p "reply with OK"
    Note: `--bare` ignores CLAUDE_CODE_OAUTH_TOKEN; use ANTHROPIC_API_KEY there.

  codex   (Codex CLI)
    Device flow (enable "device code login" in ChatGPT settings first):
                                     codex login --device-auth
    API key instead:                 printenv OPENAI_API_KEY | codex login --with-api-key
    Status:                          codex login status
    Smoke test:                      codex exec "reply with OK"
    Fallback: copy ~/.codex/auth.json from a browser machine (treat as a password).

  opencode (OpenCode)
    Key paste works over SSH, no browser:
                                     opencode auth login --provider anthropic --method api-key
    Or just export a provider key:   export ANTHROPIC_API_KEY=...
                                     (also OPENAI_API_KEY, GEMINI_API_KEY,
                                      OPENROUTER_API_KEY, OPENCODE_API_KEY, ...)
    Status:                          opencode auth list
    Smoke test:                      opencode run "reply with OK"

  gemini  (Gemini CLI)
    API key (simplest headless route):
                                     export GEMINI_API_KEY=...
    or select the auth type in ~/.gemini/settings.json:
      { "security": { "auth": { "selectedType": "gemini-api-key" } } }
    Vertex AI instead:               export GOOGLE_CLOUD_PROJECT=...
                                     GOOGLE_CLOUD_LOCATION=...
                                     GOOGLE_APPLICATION_CREDENTIALS=/path/sa.json
    Smoke test:                      gemini -p "reply with OK"
    Heads-up: Google replaced Gemini CLI with Antigravity CLI for unpaid/Google
    One users (June 2026); the package still works but is no longer the
    recommended path.

  amp     (Amp CLI)
    Browserless auth (use this):     export AMP_API_KEY=<access token>
                                     -> token from ampcode.com/settings/security
                                        (an OAuth session token in AMP_API_KEY expires)
    `amp login` is a browser flow: it opens a URL and expects the callback on
    this machine's localhost — only usable headless with an SSH tunnel
    (ssh -L <port>:localhost:<port> ...) or `amp login` from a desktop box.
    Status:                          amp account list   (no `whoami` subcommand)
    Smoke test:                      echo "reply with OK" | amp -x

  pi      (Pi)
    In the TUI:                      pi   then   /login   (OAuth device flow, or
                                                    paste the redirect URL when the
                                                    local callback cannot be reached)
    Env keys instead:                export ANTHROPIC_API_KEY=... / OPENAI_API_KEY=...
                                     / GEMINI_API_KEY=... / OPENROUTER_API_KEY=...
    Status:                          pi auth check --provider anthropic --json
    Smoke test:                      pi --print "reply with OK"

  Put keys in ~/.config/agent-env.sh (chmod 600) and `source` it from your shell
  profile — never bake them into this script.
EOF
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    local tool bin ver status cell creds d
    section "Summary"

    printf '    %-9s %-30s %-8s %s\n' "TOOL" "VERSION" "STATUS" "LOCAL CREDS"
    printf '    %-9s %-30s %-8s %s\n' "----" "-------" "------" "-----------"
    for tool in "${TOOL_ORDER[@]}"; do
        ver=${VERSION[$tool]:-"-"}
        [ ${#ver} -gt 29 ] && ver="${ver:0:29}..."
        status=${STATUS[$tool]:-unknown}
        # Pad the word BEFORE adding colour codes, otherwise printf counts the
        # escape bytes and the columns drift.
        case "$status" in
            ok)      printf -v cell '%s%-8s%s' "$C_GREEN" "ok"      "$C_RESET" ;;
            failed)  printf -v cell '%s%-8s%s' "$C_RED"   "failed"  "$C_RESET" ;;
            planned) printf -v cell '%s%-8s%s' "$C_BLUE"  "planned" "$C_RESET" ;;
            *)       printf -v cell '%s%-8s%s' "$C_DIM"   "skipped" "$C_RESET" ;;
        esac
        if [ -f "${TOOL_CREDS[$tool]}" ] || [ -n "${TOOL_ENV[$tool]}" ]; then
            creds=$(has_creds "$tool")
        else
            creds="?"
        fi
        printf '    %-9s %-30s %b%s\n' "$tool" "$ver" "$cell" "$creds"
    done

    local path_missing=0
    for d in "${PATH_DIRS[@]}"; do
        [ -d "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) path_missing=1 ;; esac
    done
    if [ "$path_missing" -eq 1 ]; then
        section "PATH"
        warn "some install dirs are not on PATH; add this to your profile:"
        info 'export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.amp/bin:$PATH"'
        info "or re-run with --fix-path to patch ~/.profile (and ~/.zprofile)"
    fi

    section "Logs"
    info "$LOG_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --upgrade)    UPGRADE=1 ;;
            --check)      CHECK_ONLY=1 ;;
            --dry-run)    DRY_RUN=1 ;;
            --fix-path)   FIX_PATH=1 ;;
            --verbose|-v) VERBOSE=1 ;;
            --only)       ONLY="${2:-}"; shift ;;
            --only=*)     ONLY="${1#*=}" ;;
            --skip)       SKIP="${2:-}"; shift ;;
            --skip=*)     SKIP="${1#*=}" ;;
            -h|--help)    usage; exit 0 ;;
            *)            failmsg "unknown option: $1 (try --help)"; exit 2 ;;
        esac
        shift
    done

    ONLY=$(printf '%s' "$ONLY" | tr ' ' ',')
    SKIP=$(printf '%s' "$SKIP" | tr ' ' ',')

    # Reject typos instead of silently doing nothing.
    if [ -n "$ONLY" ]; then
        local t known=0
        for t in "${TOOL_ORDER[@]}"; do
            case ",$ONLY," in *",$t,"*) known=1 ;; esac
        done
        if [ "$known" -eq 0 ]; then
            failmsg "--only '$ONLY' matches none of: ${TOOL_ORDER[*]}"
            exit 2
        fi
    fi

    printf '%s\n' "${C_BOLD}agent harness installer${C_RESET} — headless, user-space, no sudo"
    info "host:    $(uname -s) $(uname -m) — $( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-linux}") )"
    info "user:    $(id -un) (uid $(id -u), shell ${SHELL:-unknown})"
    info "node:    $(node_version || true)"
    info "npm:     $(npm -v 2>/dev/null || echo missing)"
    info "log dir: $LOG_DIR"

    if [ "$(id -u)" -eq 0 ]; then
        failmsg "do not run this as root — every harness installs into \$HOME"
        exit 2
    fi
    if [ "$CHECK_ONLY" -eq 0 ] && ! have curl && ! have wget; then
        failmsg "need curl or wget"
        exit 2
    fi

    # Headless/sane defaults for every child process.
    export CI=1
    export DEBIAN_FRONTEND=noninteractive
    export CODEX_NON_INTERACTIVE=1     # codex installer: skip "Start now?"
    export npm_config_yes=true
    export npm_config_fund=false
    export npm_config_audit=false

    ensure_bin_dir
    mkdir -p "$LOG_DIR"
    refresh_path

    local tool bin rc failures=0
    for tool in "${TOOL_ORDER[@]}"; do
        if ! is_selected "$tool"; then
            STATUS[$tool]="skipped"
            continue
        fi

        bin=${TOOL_BIN[$tool]}
        section "${TOOL_LABEL[$tool]}"

        if installed_ok "$tool"; then
            if [ "$UPGRADE" -eq 0 ]; then
                VERSION[$tool]=$(verify_bin "$bin" || printf 'installed')
                ok "$bin — ${VERSION[$tool]} (already installed; --upgrade to refresh)"
                STATUS[$tool]="ok"
                continue
            fi
            info "upgrading: re-running the upstream installer"
        elif have "$bin"; then
            warn "$bin exists at $(command -v "$bin") but does not answer --version; reinstalling"
        else
            info "not installed"
        fi

        if [ "$CHECK_ONLY" -eq 1 ]; then
            failmsg "$bin is missing (--check: not installing)"
            STATUS[$tool]="failed"
            failures=$((failures + 1))
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            info "would run install_${tool}"
            STATUS[$tool]="planned"
            continue
        fi

        # Clear leftovers from an older npm/git install of the same tool.
        prune_dangling "$HOME/.local/bin/$bin"
        prune_dangling "$HOME/bin/$bin"

        "install_${tool}"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            STATUS[$tool]="failed"
            failures=$((failures + 1))
            continue
        fi

        hash -r 2>/dev/null || true
        refresh_path
        if installed_ok "$tool"; then
            VERSION[$tool]=$(verify_bin "$bin" || printf 'installed')
            ok "$bin — ${VERSION[$tool]}  [${METHOD[$tool]:-installed}]"
            STATUS[$tool]="ok"
        else
            failmsg "installer reported success but $bin is not runnable"
            failmsg "debug: command -v $bin; echo \$PATH; ls -l \$HOME/.local/bin"
            STATUS[$tool]="failed"
            failures=$((failures + 1))
        fi
    done

    hash -r 2>/dev/null || true

    print_summary

    if [ "$CHECK_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        print_auth_guide
    fi

    if [ "$FIX_PATH" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        section "Persisting PATH"
        persist_path
    fi

    section "Result"
    if [ "$failures" -gt 0 ]; then
        failmsg "$failures harness(es) failed — see $LOG_DIR"
        exit 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        ok "dry run complete — nothing was installed"
    else
        ok "all requested harnesses are installed and runnable"
    fi
}

main "$@"
