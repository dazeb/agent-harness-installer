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
#   ./install-agent-harnesses.sh                 interactive on a TTY, else install missing
#   ./install-agent-harnesses.sh --interactive   force the picker (also when piped)
#   ./install-agent-harnesses.sh --no-input      never prompt; keep the vendor default
#   ./install-agent-harnesses.sh --backend mise  let mise own versions (non-interactive)
#   ./install-agent-harnesses.sh --upgrade       re-run upstream installers / mise @latest
#   ./install-agent-harnesses.sh --check         verify only, install nothing
#   ./install-agent-harnesses.sh --only claude,pi
#   ./install-agent-harnesses.sh --skip gemini
#   ./install-agent-harnesses.sh --fix-path      persist PATH to profile (backed up)
#   ./install-agent-harnesses.sh --restore       undo the edits of the last run
#   ./install-agent-harnesses.sh --restore-list  show what --restore can undo
#   ./install-agent-harnesses.sh --verbose       print installer logs
#   ./install-agent-harnesses.sh --dry-run       show the plan only
#   ./install-agent-harnesses.sh --help
#
# Every file this script edits (~/.profile, ~/.zprofile, mise's config.toml) is
# copied to ~/.local/state/agent-harnesses/backups/<run>/ first and recorded in
# manifest.tsv, so --restore puts the previous content back.
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

# mise specs for --backend mise. Short names resolve through mise's registry
# (aqua where available, npm otherwise); amp is npm-only and its short name
# cannot list versions (`mise ls-remote amp` is empty), so it is spelled out.
declare -A MISE_SPEC=(
    [claude]=claude                    # aqua:anthropics/claude-code
    [codex]=codex                      # aqua:openai/codex
    [opencode]=opencode                # aqua:anomalyco/opencode
    [gemini]=gemini                    # npm:@google/gemini-cli
    [amp]="npm:@ampcode/cli"           # same tarball as @sourcegraph/amp
    [pi]=pi                            # aqua:earendil-works/pi
)


declare -A STATUS=()   # ok | planned | failed | skipped
declare -A VERSION=()  # version string reported by --version
declare -A METHOD=()   # how it was installed
declare -A BACKED_UP=() # files already copied this run (one backup per file)

UPGRADE=0
CHECK_ONLY=0
DRY_RUN=0
FIX_PATH=0
BACKEND="vendor"   # vendor | mise
BACKEND_SET=0      # 1 when --backend was given explicitly
INTERACTIVE=0      # 1 when the picker should run
NO_INPUT=0         # 1 when --no-input was given
RESTORE=0          # 1 for --restore
RESTORE_RUN=""     # optional run id for --restore=<run>
RESTORE_LIST=0
VERBOSE="${AH_VERBOSE:-}"
ONLY=""
SKIP=""

# Created lazily by ensure_log_dir with mktemp -d (mode 0700): a predictable name
# in a world-writable /tmp lets another user pre-create it and redirect our
# `>>` log appends through a symlink.
LOG_DIR=""
CHILD_PID=""           # detached installer currently running (for the signal trap)
CLEANUP_FILES=()       # temp installer scripts to remove on exit

# Reversibility bookkeeping: every edit is copied here first.
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-harnesses"
BACKUP_DIR="$STATE_DIR/backups/$RUN_ID"
MANIFEST="$STATE_DIR/manifest.tsv"

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

usage() {
    # Print the "# Usage:" comment block itself, so the text cannot drift.
    awk '/^# Usage:/{f=1; next} f && /^#$/{exit} f{sub(/^# ?/, ""); print}' "$0"
}


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

ensure_log_dir() {
    if [ -z "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
        LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-harnesses-$(date +%Y%m%d-%H%M%S).XXXXXX") ||
            { failmsg "could not create a log directory under ${TMPDIR:-/tmp}"; exit 1; }
    fi
}

# Signals: installers run in their own session (setsid), so the terminal's
# Ctrl-C never reaches them. Forward the stop to the child's process group,
# remove temp scripts, and exit like a normal interrupted command.
cleanup_files() {
    local f
    for f in "${CLEANUP_FILES[@]}"; do rm -f "$f"; done
    CLEANUP_FILES=()
}

on_signal() {  # on_signal SIGNAL-NUMBER
    trap '' INT TERM
    printf '\n' >&2
    warn "interrupted — stopping the running installer"
    if [ -n "$CHILD_PID" ]; then
        kill -TERM -- "-$CHILD_PID" 2>/dev/null || kill -TERM "$CHILD_PID" 2>/dev/null
        sleep 1
        kill -KILL -- "-$CHILD_PID" 2>/dev/null || kill -KILL "$CHILD_PID" 2>/dev/null
    fi
    cleanup_files
    exit $((128 + $1))
}

trap cleanup_files EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

# ---------------------------------------------------------------------------
# Reversibility: backups + manifest (--restore)
# ---------------------------------------------------------------------------
# Files this script edits are copied before the edit and recorded in
# manifest.tsv. A restore is a change too, so it snapshots the current file
# first — an undone restore is itself undoable.

manifest_add() {  # KIND ORIGINAL BACKUP
    mkdir -p "$STATE_DIR" || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Is)" "$RUN_ID" "$1" "$2" "$3" >>"$MANIFEST"
}

backup_file() {
    local f=$1 rel b
    # One backup per file per run: a second copy would capture the already
    # patched content and restore nothing useful.
    if [ -n "${BACKED_UP[$f]:-}" ]; then
        return 0
    fi
    # A file that does not exist yet is a change too: restore has to remove it.
    if [ ! -e "$f" ]; then
        manifest_add absent "$f" "" || return 1
        BACKED_UP[$f]=1
        info "noted: $f does not exist (restore will remove it)"
        return 0
    fi
    rel=${f#"$HOME"/}
    b="$BACKUP_DIR/$rel"
    if ! mkdir -p "$(dirname "$b")" || ! cp -p "$f" "$b"; then
        warn "could not back up $f — leaving it untouched"
        return 1
    fi
    manifest_add file "$f" "$b" || return 1
    BACKED_UP[$f]=1
    info "backup: $f -> $b"
}

# Record a symlink target before removing it, so --restore can recreate it.
backup_symlink() {
    local l=$1 t
    [ -L "$l" ] || return 0
    t=$(readlink "$l") || return 0
    manifest_add symlink "$l" "$t" || return 0
}

restore_list() {
    local run
    section "Restore points"
    if [ ! -s "$MANIFEST" ]; then
        info "nothing recorded yet (manifest: $MANIFEST)"
        return 0
    fi
    for run in $(awk -F'\t' '{print $2}' "$MANIFEST" | sort -ru | head -n 10); do
        printf '    %s\n' "$run"
        awk -F'\t' -v r="$run" '$2==r {printf "      %-8s %s\n", $3, $4}' "$MANIFEST"
    done
    info "newest: --restore      specific run: --restore=<run>"
}

restore_run() {  # restore_run [RUN_ID] — default: newest run in the manifest
    local wanted=${1:-} run kind orig bak n=0 snapshot
    if [ ! -s "$MANIFEST" ]; then
        failmsg "nothing to restore (no $MANIFEST)"
        return 1
    fi
    run=$wanted
    if [ -z "$run" ]; then
        run=$(awk -F'\t' 'END{print $2}' "$MANIFEST")
    fi
    section "Restore $run"

    # 1) snapshot what is on disk now, so this restore can be undone too
    while IFS=$'\t' read -r _ r kind orig bak; do
        [ "$r" = "$run" ] || continue
        # "absent" entries are files the run created; restore deletes them, so
        # whatever is there now (possibly edited since) must be saved first.
        [ "$kind" = "file" ] || [ "$kind" = "absent" ] || continue
        [ -f "$orig" ] || continue
        snapshot="$BACKUP_DIR/${orig#"$HOME"/}"
        mkdir -p "$(dirname "$snapshot")" && cp -p "$orig" "$snapshot" &&
            manifest_add file "$orig" "$snapshot"
    done < <(awk -F'\t' -v r="$run" '$2==r' "$MANIFEST")

    # 2) put the recorded content back
    while IFS=$'\t' read -r _ r kind orig bak; do
        [ "$r" = "$run" ] || continue
        case $kind in
            file)
                if mkdir -p "$(dirname "$orig")" && cp -p "$bak" "$orig" 2>/dev/null; then
                    ok "restored $orig"
                    n=$((n + 1))
                else
                    warn "could not restore $orig from $bak"
                fi
                ;;
            symlink)
                if ln -sfn "$bak" "$orig" 2>/dev/null; then
                    ok "recreated symlink $orig -> $bak"
                    n=$((n + 1))
                fi
                ;;
            absent)
                if rm -f "$orig" 2>/dev/null; then
                    ok "removed $orig (it did not exist before this run)"
                    n=$((n + 1))
                fi
                ;;
        esac
    done < <(awk -F'\t' -v r="$run" '$2==r' "$MANIFEST")

    if [ "$n" -eq 0 ]; then
        warn "run $run had nothing restorable (see --restore-list)"
        return 1
    fi
    ok "$n item(s) restored — back to the pre-run state"
    info "files were restored whole: edits made to them after the run are gone,"
    info "but their previous content is saved in $BACKUP_DIR (undo: --restore)"
    info "installed binaries are additive and stay in place; to remove them too:"
    info "  rm -rf ~/.local/bin/<tool> ~/.local/share/claude ~/.opencode/bin ..."
    info "  mise uninstall <tool>            (if mise owned the version)"
}

# Prune a stale symlink left behind by an older npm/git install. Left in place,
# these break `command -v` lookups and make installers pick a different bin dir.
prune_dangling() {
    local p=$1
    if [ -L "$p" ] && [ ! -e "$p" ]; then
        backup_symlink "$p"
        rm -f "$p" && info "removed stale symlink $p (undo: --restore)"
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

# Display helpers: an empty string reads as a bug in the transcript, so say
# "missing" instead of printing nothing.
node_or_missing() {
    local v
    v=$(node_version)
    printf '%s' "${v:-missing}"
}

mise_or_missing() {
    local v=""
    if have mise; then
        v=$(mise --version 2>/dev/null | awk 'NR==1{print $1}')
    fi
    printf '%s' "${v:-missing}"
}

# download URL DEST — curl first, wget fallback, retries included.
download() {
    local url=$1 dest=$2
    if have curl; then
        curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
             --retry 3 --retry-delay 2 --connect-timeout 15 \
             --max-time 900 "$url" -o "$dest" && return 0
    fi
    if have wget; then
        wget -q --https-only --tries=3 --timeout=60 "$url" -O "$dest" && return 0
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
    local log=$1 rc; shift
    # Backgrounded + `wait` so a trapped signal runs the handler at once instead
    # of after the installer finishes; setsid makes CHILD_PID the group leader.
    if have setsid; then
        setsid -w "$@" </dev/null >>"$log" 2>&1 &
    else
        "$@" </dev/null >>"$log" 2>&1 &
    fi
    CHILD_PID=$!
    wait "$CHILD_PID"
    rc=$?
    CHILD_PID=""
    return "$rc"
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
    ensure_log_dir
    log="$LOG_DIR/$name-install.log"
    script=$(mktemp "${TMPDIR:-/tmp}/${name}-install.XXXXXX.sh") || return 1
    CLEANUP_FILES+=("$script")

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
    ensure_log_dir
    slug=$(printf '%s' "$pkg" | tr '/@' '__')
    log="$LOG_DIR/npm-$slug.log"
    local prefix_args=() gp
    gp=$(npm prefix -g 2>/dev/null)
    if [ -n "$gp" ] && [ ! -w "$gp" ]; then
        # System Node (apt, /usr/local): the global prefix is root-owned. Install
        # into ~/.local instead of failing with EACCES; ~/.local/bin is on PATH.
        prefix_args=(--prefix "$HOME/.local")
        info "npm global prefix $gp is not writable; using $HOME/.local"
    fi
    info "npm install -g $pkg $*"
    run_detached "$log" npm install -g "$pkg" "$@" ${prefix_args[@]+"${prefix_args[@]}"} \
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
    local nv
    nv=$(node_version)
    if [ -n "$nv" ] && ! version_ge "$nv" "20.0.0"; then
        warn "Gemini CLI needs Node >= 20 (found $nv); skipping npm"
    elif have npm; then
        if npm_global_install @google/gemini-cli; then
            METHOD[gemini]="npm (@google/gemini-cli)"
            return 0
        fi
    fi
    if have brew; then
        warn "npm install failed, falling back to Homebrew"
        ensure_log_dir
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
# mise backend (--backend mise) — opt-in
# ---------------------------------------------------------------------------
# When selected, mise owns the version (in ~/.config/mise/config.toml), fetches
# verified artifacts (aqua = signed GitHub releases) and gives one upgrade path
# (`mise upgrade`). It is NOT the default: a bare headless box may have no mise,
# and the vendor installers are the officially supported path per harness.

mise_which() {
    # Resolved binary path. stderr is dropped: mise prints update notices there
    # and they would otherwise be captured as output.
    local bin=$1 p
    p=$(timeout 60 mise which "$bin" 2>/dev/null | tail -n1)
    [ -n "$p" ] && [ -x "$p" ] && printf '%s' "$p"
}

install_via_mise() {
    local tool=$1 spec=${MISE_SPEC[$1]} log rc
    ensure_log_dir
    log="$LOG_DIR/mise-$tool.log"

    if ! have mise; then
        failmsg "mise is not installed (curl https://mise.run | sh), or drop --backend mise"
        return 1
    fi
    # mise's npm backend shells out to a Node runtime and never adds one itself.
    if [ "$tool" = "gemini" ] && [ -z "$(node_version)" ]; then
        failmsg "gemini via mise needs Node for the npm backend (mise use -g node@lts)"
        return 1
    fi

    # Idempotent: re-running with @latest upgrades, and pins stay editable in
    # config.toml afterwards (mise use -g codex@0.160.0 to roll back).
    # mise rewrites that config file, so snapshot it before handing over.
    if ! backup_file "${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"; then
        failmsg "refusing to let mise edit its config without a backup"
        return 1
    fi
    info "mise use -g $spec@latest"
    run_detached "$log" mise use -g "$spec@latest"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        failmsg "mise failed for $tool (log: $log)"
        show_log_tail "$log"
        if grep -q 'no versions found' "$log" 2>/dev/null; then
            # mise's minimum_release_age hides builds that are too new. Amp ships
            # a new build every few hours, so a default mise can see none of them.
            info "mise found no version old enough to install (minimum_release_age)."
            info "  accept newer builds for this tool:  mise settings set minimum_release_age 0s"
            info "  or install just this one natively:   $0 --backend vendor --only $tool"
        fi
        return 1
    fi
    METHOD[$tool]="mise ($spec)"
}

# backend_install TOOL — dispatch on --backend.
backend_install() {
    if [ "$BACKEND" = "mise" ]; then
        install_via_mise "$1"
    else
        "install_$1"
    fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# verify_bin CMD -> echoes a version string; non-zero when the binary is dead.
verify_bin() {
    local cmd=$1 out flag
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
    local tool=$1 bin=${TOOL_BIN[$1]} cmd
    cmd=$bin
    if ! have "$bin"; then
        # --backend mise installs outside the normal PATH dirs; ask mise where
        # the binary is instead of requiring `mise activate` in this shell.
        [ "$BACKEND" = "mise" ] || return 1
        cmd=$(mise_which "$bin") || return 1
    fi
    timeout 120 "$cmd" --version </dev/null >/dev/null 2>&1
}

# resolve_cmd TOOL — command used for verification. Under --backend mise the
# binary may live outside our PATH dirs, so ask mise before using the bare name.
resolve_cmd() {
    local bin=${TOOL_BIN[$1]}
    if ! have "$bin" && [ "$BACKEND" = "mise" ]; then
        mise_which "$bin" && return 0
    fi
    printf '%s' "$bin"
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

# npm's global bin dir, when it lives under $HOME (nvm, ~/.npm-global, ...):
# a user-prefix `npm install -g` lands there, not in a fixed PATH_DIRS entry.
npm_user_bin() {
    local gp
    have npm || return 0
    gp=$(npm prefix -g 2>/dev/null) || return 0
    case $gp in "$HOME"/*) printf '%s/bin' "$gp" ;; esac
}

build_path() {
    local d out="" IFS=: nb
    nb=$(npm_user_bin)
    for d in "${PATH_DIRS[@]}" ${nb:+"$nb"} $PATH; do
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
    local p mp
    p=$(build_path)
    if [ "$BACKEND" = "mise" ] && have mise; then
        # bin dirs of the tools mise currently resolves — works without shims.
        mp=$(mise bin-paths 2>/dev/null | awk 'NF { printf "%s%s", sep, $0; sep = ":" }')
        [ -n "$mp" ] && p="$mp${p:+:$p}"
    fi
    export PATH="$p"
}

persist_path() {
    local targets=("$HOME/.profile") t shellname=bash
    # bash login shells read ~/.bash_profile INSTEAD of ~/.profile when it exists.
    if [ -f "$HOME/.bash_profile" ]; then
        targets+=("$HOME/.bash_profile")
    fi
    # zsh login shells read .zprofile, not .profile.
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        targets+=("${ZDOTDIR:-$HOME}/.zprofile")
    fi
    for t in "${targets[@]}"; do
        mkdir -p "$(dirname "$t")"
        if [ -f "$t" ] && grep -qF '# >>> agent-harnesses PATH >>>' "$t"; then
            info "$t already has the PATH block"
        else
            backup_file "$t" || continue
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
            ok "patched $t (PATH)"
        fi

        # mise installs outside those dirs, so shell activation is what makes
        # its bin dirs reachable in future shells.
        if [ "$BACKEND" = "mise" ] && ! grep -qF '# >>> agent-harnesses mise >>>' "$t" 2>/dev/null; then
            backup_file "$t" || continue
            shellname=bash
            case "$t" in *.zprofile) shellname=zsh ;; esac
            cat >>"$t" <<EOF

# >>> agent-harnesses mise >>>
# Added by install-agent-harnesses.sh --backend mise
command -v mise >/dev/null 2>&1 && eval "\$(mise activate $shellname)"
# <<< agent-harnesses mise <<<
EOF
            ok "patched $t (mise activate $shellname)"
        fi
    done
    info "open shells still need: export PATH=\"\$HOME/.local/bin:\$PATH\""
}

# ---------------------------------------------------------------------------
# Interactive picker (default on a TTY, or --interactive)
# ---------------------------------------------------------------------------
# Text only on purpose: readable over SSH, in a serial console, in CI logs, and
# in `printf '2\n' | ./install-agent-harnesses.sh --interactive` style tests.
# No emoji, no curses, no arrow keys — plain read -r on stdin.

INTERACTIVE_INSTALLED=0   # selected harnesses that were already runnable

is_tty() { [ -t 0 ] && [ -t 1 ]; }

os_pretty() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-linux}}" )
    else
        uname -s
    fi
}

# ask VAR "question" default — reads stdin, so piped answers behave like a human.
# The read goes into `_v`, never into a variable named like the caller's, or
# printf -v would write to this function's own local instead of the target.
ask() {
    local __var=$1 q=$2 def=${3:-} _v=""
    printf '    %s' "$q"
    [ -n "$def" ] && printf ' [%s]' "$def"
    printf ' '
    IFS= read -r _v || { printf '\n'; _v=""; }
    # Piped answers are not echoed by the shell; show what was chosen so the
    # transcript (and the gate log) stays readable.
    if ! [ -t 0 ]; then
        printf '%s\n' "${_v:-$def}"
    fi
    [ -n "$_v" ] || _v=$def
    printf -v "$__var" '%s' "$_v"
}

ask_yes_no() {  # ask_yes_no "question" [y|n]
    local ans
    while :; do
        ask ans "$1" "${2:-n}"
        case ${ans,,} in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) printf '    please answer y or n\n' ;;
        esac
    done
}

# Absolute path of a harness binary, empty when it is not resolvable.
tool_path() {
    local bin=${TOOL_BIN[$1]} p=""
    p=$(command -v "$bin" 2>/dev/null) || p=""
    if [ -z "$p" ] && have mise; then
        p=$(mise_which "$bin") || p=""
    fi
    printf '%s' "$p"
}

explain_methods() {
    cat <<'EOF'
    [1] Regular install  (default)
        Runs each harness's own installer once. Everything stays in $HOME:
        ~/.local/bin (claude, codex, amp, pi), ~/.opencode/bin, npm's user
        prefix. Upgrade later:  ./install-agent-harnesses.sh --upgrade
        Vendor-supported and simple; each tool moves at its own pace and
        pinning an older version means reinstalling by hand.

    [2] mise
        mise owns the versions in ~/.config/mise/config.toml and downloads
        verified artifacts (aqua = signed GitHub releases; npm for gemini/amp).
        Upgrade everything later with one command:  mise upgrade
        Pin or roll back one tool:                   mise use -g claude@2.1.305
        Needs mise installed (offer below); gemini and amp also need Node.
        Do not drive the same tool through [1] and [2] — two owners, two paths.
EOF
}

detect_installed() {
    section "What is already installed"
    local tool path ver
    INTERACTIVE_INSTALLED=0
    for tool in "${TOOL_ORDER[@]}"; do
        if ! is_selected "$tool"; then
            printf '    %-9s %s\n' "$tool" "(deselected)"
            continue
        fi
        if installed_ok "$tool"; then
            path=$(tool_path "$tool")
            ver=$(verify_bin "${path:-${TOOL_BIN[$tool]}}" 2>/dev/null | cut -c1-28)
            [ -n "$ver" ] || ver="installed"
            printf '    %-9s %-29s %s\n' "$tool" "$ver" "${path:-path unknown}"
            INTERACTIVE_INSTALLED=$((INTERACTIVE_INSTALLED + 1))
        else
            printf '    %-9s %s\n' "$tool" "not installed"
        fi
    done
    if [ "$INTERACTIVE_INSTALLED" -eq 0 ]; then
        info "nothing selected is installed yet"
    fi
    return 0
}

# Install mise itself from https://mise.run — user-space, no sudo; the only
# file it adds is ~/.local/bin/mise.
bootstrap_mise() {
    local log script rc
    ensure_log_dir
    log="$LOG_DIR/mise-bootstrap.log"
    # Download first, then execute (same as the harness installers): a pipe would
    # run a truncated script if the connection dropped mid-transfer.
    script=$(mktemp "${TMPDIR:-/tmp}/mise-install.XXXXXX.sh") || return 1
    CLEANUP_FILES+=("$script")
    info "download https://mise.run"
    if ! download https://mise.run "$script" || [ ! -s "$script" ]; then
        rm -f "$script"
        failmsg "could not download https://mise.run (need curl or wget)"
        return 1
    fi
    run_detached "$log" sh "$script"
    rc=$?
    rm -f "$script"
    hash -r 2>/dev/null || true
    refresh_path
    if [ "$rc" -eq 0 ] && have mise; then
        ok "mise $(mise_or_missing) installed"
        METHOD[mise]="https://mise.run"
        return 0
    fi
    failmsg "mise bootstrap failed (log: $log)"
    show_log_tail "$log"
    return 1
}

# choose_backend — OS + installed state, method choice, upgrade question.
choose_backend() {
    local choice=""
    section "Environment"
    info "os:      $(os_pretty)"
    info "arch:    $(uname -m), kernel $(uname -r)"
    info "shell:   ${SHELL:-unknown}"
    info "node:    $(node_or_missing)"
    info "npm:     $(npm -v 2>/dev/null || printf 'missing')"
    info "mise:    $(mise_or_missing)"

    detect_installed

    if [ "$BACKEND_SET" -eq 1 ]; then
        # --backend wins over the menu: still report state, but do not ask.
        ok "method: $BACKEND (from --backend)"
    else
        section "Which install method?"
        explain_methods
        while :; do
            ask choice "Choose 1 (regular), 2 (mise) or q to quit:" "1"
            case $choice in
                1) BACKEND=vendor; break ;;
                2) BACKEND=mise;   break ;;
                q|Q) ok "nothing was changed"; exit 0 ;;
                *) printf '    please type 1, 2 or q\n' ;;
            esac
        done
        ok "method: $BACKEND"
    fi

    if [ "$BACKEND" = "mise" ] && ! have mise; then
        warn "mise is not on PATH"
        if [ "$DRY_RUN" -eq 1 ]; then
            info "dry run: would offer to install mise (https://mise.run); not installing"
        elif ask_yes_no "Install mise now (downloads and runs https://mise.run, user-space)?" y; then
            if ! bootstrap_mise; then
                BACKEND=vendor
                warn "falling back to the regular installers"
            fi
        else
            BACKEND=vendor
            warn "falling back to the regular installers"
        fi
    fi

    if [ "$INTERACTIVE_INSTALLED" -gt 0 ] && [ "$UPGRADE" -eq 0 ]; then
        if ask_yes_no "Upgrade the $INTERACTIVE_INSTALLED installed harness(es) as well?" n; then
            UPGRADE=1
        fi
    fi
}

print_upgrade_hint() {
    section "Upgrading later"
    if [ "$BACKEND" = "mise" ]; then
        info "mise upgrade                    all selected tools to newest"
        info "mise use -g claude@latest       just claude"
        info "mise use -g claude@2.1.305      pin or roll back"
        info "mise ls                         what resolves right now"
        info "config: ~/.config/mise/config.toml (backed up before every edit)"
    else
        info "./install-agent-harnesses.sh --upgrade"
        info "  re-runs each upstream installer; whatever upstream ships wins"
    fi
}

# Where the binaries actually live after this run (claude called out by name).
print_locations() {
    local tool path real printed=0 real_claude="" base
    section "Executable locations"
    for tool in "${TOOL_ORDER[@]}"; do
        case "${STATUS[$tool]:-}" in
            ok|planned) ;;
            *) continue ;;
        esac
        path=$(tool_path "$tool")
        if [ -z "$path" ]; then
            if [ "${STATUS[$tool]:-}" = "planned" ]; then
                # Best guess at the install target when nothing is on disk yet.
                if [ "$BACKEND" = "mise" ]; then
                    printf '    %-9s %s\n' "$tool" "mise: ${MISE_SPEC[$tool]}  (after install)"
                    printed=1
                    continue
                fi
                case ${TOOL_BIN[$tool]} in
                    opencode) base="$HOME/.opencode/bin" ;;
                    gemini)   base="$(npm prefix -g 2>/dev/null || printf '%s' "$HOME/.local")/bin" ;;
                    *)        base="$HOME/.local/bin" ;;
                esac
                printf '    %-9s %s\n' "$tool" "$base/${TOOL_BIN[$tool]}  (after install)"
                printed=1
            fi
            continue
        fi
        real=$path
        case $path in /*) real=$(readlink -f "$path" 2>/dev/null) || real=$path ;; esac
        [ "$tool" = "claude" ] && real_claude=$real
        printf '    %-9s %s\n' "$tool" "$real"
        printed=1
    done
    if [ "$printed" -eq 0 ]; then
        info "no harness binary resolved yet"
    fi
    if [ -n "$real_claude" ]; then
        info "claude runs from: $real_claude"
        info "smoke test:       $real_claude --version"
    else
        info "claude not resolvable yet — install it, then: command -v claude"
    fi
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
        creds=$(has_creds "$tool")
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
            --interactive|-i) INTERACTIVE=1 ;;
            --no-input|--yes|-y) NO_INPUT=1 ;;
            --restore)    RESTORE=1 ;;
            --restore=*)  RESTORE=1; RESTORE_RUN="${1#*=}" ;;
            --restore-list) RESTORE_LIST=1 ;;
            --verbose|-v) VERBOSE=1 ;;
            --only)       ONLY="${2:-}"; shift ;;
            --only=*)     ONLY="${1#*=}" ;;
            --skip)       SKIP="${2:-}"; shift ;;
            --skip=*)     SKIP="${1#*=}" ;;
            --backend)    BACKEND="${2:-}"; BACKEND_SET=1; shift ;;
            --backend=*)  BACKEND="${1#*=}"; BACKEND_SET=1 ;;
            -h|--help)    usage; exit 0 ;;
            *)            failmsg "unknown option: $1 (try --help)"; exit 2 ;;
        esac
        shift
    done

    ONLY=$(printf '%s' "$ONLY" | tr ' ' ',')
    SKIP=$(printf '%s' "$SKIP" | tr ' ' ',')

    case "$BACKEND" in
        vendor|mise) ;;
        *) failmsg "--backend must be 'vendor' or 'mise' (got: ${BACKEND:-empty})"; exit 2 ;;
    esac

    # Reject typos instead of silently ignoring them: every name must be known.
    local list name t known
    for list in ONLY SKIP; do
        for name in $(printf '%s' "${!list}" | tr ',' ' '); do
            known=0
            for t in "${TOOL_ORDER[@]}"; do
                [ "$name" = "$t" ] && known=1
            done
            if [ "$known" -eq 0 ]; then
                failmsg "--${list,,}: unknown harness '$name' (known: ${TOOL_ORDER[*]})"
                exit 2
            fi
        done
    done

    if [ "$(id -u)" -eq 0 ]; then
        failmsg "do not run this as root — every harness installs into \$HOME"
        exit 2
    fi

    # Reversibility has to work offline and without curl, so it is handled
    # before any network/tooling preconditions (and before the banner, which is
    # about installing).
    if [ "$RESTORE_LIST" -eq 1 ]; then
        restore_list
        exit 0
    fi
    if [ "$RESTORE" -eq 1 ]; then
        restore_run "$RESTORE_RUN"
        exit $?
    fi

    printf '%s\n' "${C_BOLD}agent harness installer${C_RESET} — headless, user-space, no sudo"
    info "host:    $(uname -s) $(uname -m) — $(os_pretty)"
    info "user:    $(id -un) (uid $(id -u), shell ${SHELL:-unknown})"
    info "node:    $(node_or_missing)"
    info "npm:     $(npm -v 2>/dev/null || echo missing)"
    ensure_log_dir
    info "log dir: $LOG_DIR"

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

    # --check is read-only: do not create ~/.local/bin for it.
    [ "$CHECK_ONLY" -eq 1 ] || ensure_bin_dir
    refresh_path

    # Interactive by default when a human is at the keyboard, unless the method
    # was chosen with --backend, input was disabled, or this is --check.
    if [ "$INTERACTIVE" -eq 0 ] && [ "$NO_INPUT" -eq 0 ] && [ "$BACKEND_SET" -eq 0 ] &&
       [ "$CHECK_ONLY" -eq 0 ] && is_tty; then
        INTERACTIVE=1
    fi
    if [ "$NO_INPUT" -eq 1 ]; then
        INTERACTIVE=0
    fi

    if [ "$INTERACTIVE" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        choose_backend
        # The picker can change BACKEND (mise unavailable) and UPGRADE.
        refresh_path
    fi
    info "backend: $BACKEND"
    if [ "$UPGRADE" -eq 1 ]; then
        info "upgrade: re-run installers / re-resolve @latest"
    fi

    local tool bin rc failures=0
    for tool in "${TOOL_ORDER[@]}"; do
        if ! is_selected "$tool"; then
            STATUS[$tool]="skipped"
            continue
        fi

        bin=${TOOL_BIN[$tool]}
        section "${TOOL_LABEL[$tool]}"

        if installed_ok "$tool"; then
            # --check never upgrades: an installed, runnable tool is simply ok.
            if [ "$UPGRADE" -eq 0 ] || [ "$CHECK_ONLY" -eq 1 ]; then
                VERSION[$tool]=$(verify_bin "$(resolve_cmd "$tool")" || printf 'installed')
                ok "$bin — ${VERSION[$tool]} (already installed; --upgrade to refresh)"
                STATUS[$tool]="ok"
                continue
            fi
            if [ "$BACKEND" = "mise" ]; then
                info "upgrading: re-resolving @latest through mise"
            else
                info "upgrading: re-running the upstream installer"
            fi
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
            if [ "$BACKEND" = "mise" ]; then
                info "would run: mise use -g ${MISE_SPEC[$tool]}@latest"
            else
                info "would run install_${tool}"
            fi
            STATUS[$tool]="planned"
            continue
        fi

        # Clear leftovers from an older npm/git install of the same tool.
        prune_dangling "$HOME/.local/bin/$bin"
        prune_dangling "$HOME/bin/$bin"

        backend_install "$tool"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            STATUS[$tool]="failed"
            failures=$((failures + 1))
            continue
        fi

        hash -r 2>/dev/null || true
        refresh_path
        if installed_ok "$tool"; then
            VERSION[$tool]=$(verify_bin "$(resolve_cmd "$tool")" || printf 'installed')
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
    print_locations

    if [ "$CHECK_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        print_auth_guide
    fi

    # Ask before touching a profile, and say exactly what will be backed up.
    if [ "$INTERACTIVE" -eq 1 ] && [ "$FIX_PATH" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] &&
       [ "$CHECK_ONLY" -eq 0 ]; then
        if ask_yes_no "Add the install dirs to ~/.profile (backed up first, undo with --restore)?" y; then
            FIX_PATH=1
        else
            info "skipped; PATH additions are not applied"
        fi
    fi

    if [ "$FIX_PATH" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        section "Persisting PATH"
        persist_path
    fi

    if [ "$CHECK_ONLY" -eq 0 ]; then
        print_upgrade_hint
    fi

    if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        section "Reversibility"
        info "backups:   $BACKUP_DIR"
        info "manifest:  $MANIFEST"
        info "undo last: ./install-agent-harnesses.sh --restore"
        info "see all:   ./install-agent-harnesses.sh --restore-list"
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
