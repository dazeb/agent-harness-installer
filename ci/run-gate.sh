#!/usr/bin/env bash
# ci/run-gate.sh — self-hosted stand-in for a CI runner.
#
# For accounts where GitHub Actions cannot schedule jobs (repo permissions say
# "enabled", yet every dispatch returns "Actions has been disabled for this
# user"), a self-hosted *GitHub* runner is useless: no run is created, so there
# is no job to hand out. What still works is the status API, which is not part
# of Actions. This script closes that gap on any VM/box with git + docker:
#
#   fetch main -> run ci/gate.sh in a container -> POST a commit status
#
# so the commit page and the badge update exactly like a workflow would, and the
# workflow file stays in the repo for the day Actions is re-enabled.
#
#   ./ci/run-gate.sh --once          # exactly what the systemd timer runs
#   ./ci/run-gate.sh --loop 300      # poll every 5 min (no systemd needed)
#   ./ci/run-gate.sh --once --force  # re-gate HEAD even if already done
#
# Config comes from the environment or /etc/ah-gate.env (see
# deploy/ah-gate.env.example). Without AH_GATE_TOKEN the gate still runs and
# logs its verdict; only the public status is skipped.
set -uo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)

ENV_FILE=${AH_GATE_ENV_FILE:-/etc/ah-gate.env}
if [ -r "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
fi

REPO=${AH_GATE_REPO:-https://github.com/dazeb/agent-harness-installer.git}
BRANCH=${AH_GATE_BRANCH:-main}
SRC=${AH_GATE_SRC:-/var/lib/ah-gate/src}
STATE=${AH_GATE_STATE:-/var/lib/ah-gate/last-result}
IMAGE=${AH_GATE_IMAGE:-ah-gate:latest}
TOKEN=${AH_GATE_TOKEN:-}
SLUG=${AH_GATE_SLUG:-}
CONTEXT=${AH_GATE_CONTEXT:-ah-gate}
API=${AH_GATE_API:-https://api.github.com}
DOCKER=${AH_GATE_DOCKER:-docker}
LOG_DIR=${AH_GATE_LOG_DIR:-/var/log/ah-gate}

die() { printf 'ah-gate: %s\n' "$*" >&2; exit 2; }
log() { printf 'ah-gate: %s\n' "$*"; }

usage() { sed -n '15,17p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=once
INTERVAL=300
FORCE=0
while [ $# -gt 0 ]; do
    case $1 in
        --once)  MODE=once ;;
        --loop)  MODE=loop; INTERVAL=${2:-300}; shift ;;
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

case $INTERVAL in
    ''|*[!0-9]*) die "--loop needs a number of seconds" ;;
esac

# owner/repo, derived from the clone URL when not set explicitly.
if [ -z "$SLUG" ]; then
    SLUG=${REPO%.git}
    SLUG=${SLUG#*:}
    SLUG=$(printf '%s' "$SLUG" | sed -E 's#^.*(github\.com[/:])##')
fi

command -v git >/dev/null 2>&1 || die "git is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

dockerfile_for_image() {
    local d
    for d in "${AH_GATE_DOCKERFILE:-}" "$SELF/Dockerfile" \
             /usr/local/lib/ah-gate/Dockerfile "$SELF/../ci/Dockerfile"; do
        if [ -n "$d" ] && [ -r "$d" ]; then printf '%s' "$d"; return 0; fi
    done
    return 1
}

ensure_image() {
    [ "$DOCKER" = "none" ] && return 0
    "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 && return 0
    local df
    df=$(dockerfile_for_image) || die "image $IMAGE missing and no Dockerfile found"
    log "building $IMAGE from $df"
    "$DOCKER" build --quiet -t "$IMAGE" -f "$df" "$(dirname "$df")" >/dev/null \
        || die "docker build failed"
}

# Resolve the commit under test from origin, not from a possibly stale worktree.
sync_src() {
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" fetch --quiet origin "$BRANCH" || die "git fetch failed"
    else
        mkdir -p "$(dirname "$SRC")" || die "cannot create $(dirname "$SRC")"
        git clone --quiet --branch "$BRANCH" "$REPO" "$SRC" || die "git clone failed"
    fi
    SHA=$(git -C "$SRC" rev-parse "origin/$BRANCH") || die "cannot resolve origin/$BRANCH"
    SHORT=$(git -C "$SRC" rev-parse --short "$SHA")
}

remember() {
    mkdir -p "$(dirname "$STATE")" 2>/dev/null || STATE=/tmp/ah-gate-last-result
    printf '%s %s\n' "$SHA" "$1" >"$STATE"
}

post_status() {
    local state=$1 desc=$2 payload
    [ -n "$TOKEN" ] && [ -n "$SLUG" ] || return 0
    payload=$(printf '{"state":"%s","context":"%s","description":"%s"}' \
        "$state" "$CONTEXT" "$desc")
    if ! curl -sSf -m 20 -o /dev/null -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -d "$payload" \
            "$API/repos/$SLUG/statuses/$SHA"; then
        log "warn: could not post '$state' status for $SHORT"
        return 1
    fi
    log "status: $state -> $SLUG@$SHORT"
}

run_gate() {
    local rc
    # Run as ourselves so the mirror keeps its owner — but never as root:
    # gate.sh refuses root, exactly like the installer. Under root (the systemd
    # service) fall back to the image's own unprivileged user.
    if [ "$(id -u)" -ne 0 ]; then
        set -- --user "$(id -u):$(id -g)"
    else
        set --
    fi
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=/tmp
    LOG="$LOG_DIR/$SHORT.log"
    if [ "$DOCKER" = "none" ]; then
        # Escape hatch for a box without docker: needs bash + shellcheck there.
        "$SRC/ci/gate.sh" "$SRC" >"$LOG" 2>&1
    else
        "$DOCKER" run --rm "$@" \
            -e HOME=/tmp \
            -v "$SRC:/src:ro" \
            "$IMAGE" >"$LOG" 2>&1
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -n 25 "$LOG" | sed 's/^/ah-gate| /' >&2
    fi
    return "$rc"
}

one_pass() {
    sync_src
    local last_sha="" last_state=""
    if [ -r "$STATE" ]; then
        read -r last_sha last_state <"$STATE" || true
    fi
    if [ "$FORCE" -eq 0 ] && [ "$last_sha" = "$SHA" ]; then
        log "$SHORT already gated ($last_state); nothing to do (--force to repeat)"
        return 0
    fi

    log "gating $SLUG@$SHORT ($BRANCH)"
    post_status pending "gate running on $SHORT"
    if run_gate; then
        post_status success "ci/gate.sh passed on $SHORT"
        remember success
        log "PASS $SHORT"
        return 0
    fi
    post_status failure "ci/gate.sh failed on $SHORT"
    remember failure
    log "FAIL $SHORT (log: $LOG)"
    return 1
}

if [ "$MODE" = "once" ]; then
    ensure_image
    one_pass
    exit $?
fi

ensure_image
trap 'log "stopping"; exit 0' INT TERM
while :; do
    one_pass || true
    sleep "$INTERVAL"
done
