#!/usr/bin/env bash
# ci/gate.sh — the CI gate, runnable anywhere.
#
#   ci/gate.sh [REPO_DIR]
#
# Same assertions as .github/workflows/ci.yml, in the same order, with no
# dependency on GitHub Actions and no dependency on `make`. Exit 0 means every
# check passed. It is the payload both of the workflow and of ci/run-gate.sh,
# so a green run here is a green run there.
#
# Must run as a non-root user: install-agent-harnesses.sh refuses root by
# design, and one of the checks asserts exactly that.
set -uo pipefail

ROOT=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd) || exit 1
cd "$ROOT" || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
STEP=0
SCRIPT=install-agent-harnesses.sh

pass()  { printf '  ok    %s\n' "$1"; }
begin() { STEP=$((STEP + 1)); printf '\n[%d] %s\n' "$STEP" "$1"; }
bad() {
    printf '  FAIL  %s\n' "$1" >&2
    if [ -s "$2" ]; then tail -n 15 "$2" | sed 's/^/        | /' >&2; fi
    FAILED=$((FAILED + 1))
}

if [ "$(id -u)" -eq 0 ]; then
    printf 'gate: run as a normal user, not root (the installer refuses root)\n' >&2
    exit 2
fi

begin "bash -n $SCRIPT"
if bash -n "$SCRIPT" 2>"$WORK/syntax.log"; then
    pass "parses"
else
    bad "syntax error" "$WORK/syntax.log"
fi

begin "shellcheck --severity=warning"
if [ "${AH_GATE_SKIP_SHELLCHECK:-0}" = "1" ]; then
    pass "skipped (AH_GATE_SKIP_SHELLCHECK=1)"
elif ! command -v shellcheck >/dev/null 2>&1; then
    printf '  FAIL  shellcheck is not installed (apt install shellcheck)\n' >&2
    printf '        set AH_GATE_SKIP_SHELLCHECK=1 to run the rest anyway\n' >&2
    FAILED=$((FAILED + 1))
elif shellcheck --severity=warning --format=gcc "$SCRIPT" ci/gate.sh ci/run-gate.sh >"$WORK/shellcheck.log" 2>&1; then
    pass "no warnings"
else
    bad "shellcheck findings" "$WORK/shellcheck.log"
fi

begin "--help documents --backend"
if ./"$SCRIPT" --help >"$WORK/help.log" 2>&1 && grep -q -- '--backend' "$WORK/help.log"; then
    pass "--backend listed"
else
    bad "--help is missing --backend or failed" "$WORK/help.log"
fi

# Both dry runs must complete without touching the network or installing.
# They run in a scrubbed environment (empty HOME, PATH without ~/.local/bin), so
# the plan is the same whether the gate runs on a bare container or on a box
# where every harness is already installed.
CLEAN=(env -i "HOME=$WORK/home" "PATH=/usr/bin:/bin" "SHELL=/bin/bash" "TERM=dumb")

begin "--dry-run --backend vendor"
if ! "${CLEAN[@]}" ./"$SCRIPT" --dry-run >"$WORK/dry-vendor.log" 2>&1; then
    bad "dry run exited non-zero" "$WORK/dry-vendor.log"
elif ! grep -q 'backend: vendor' "$WORK/dry-vendor.log"; then
    bad "header does not report backend: vendor" "$WORK/dry-vendor.log"
elif ! grep -q 'dry run complete' "$WORK/dry-vendor.log"; then
    bad "no 'dry run complete' marker" "$WORK/dry-vendor.log"
elif ! grep -q 'would run install_claude' "$WORK/dry-vendor.log"; then
    bad "vendor plan did not plan the vendor installer" "$WORK/dry-vendor.log"
elif grep -q 'mise use -g' "$WORK/dry-vendor.log"; then
    bad "vendor backend planned a mise call" "$WORK/dry-vendor.log"
else
    pass "planned the vendor installers, nothing installed"
fi

begin "--dry-run --backend mise (no mise required)"
if ! "${CLEAN[@]}" ./"$SCRIPT" --dry-run --backend mise >"$WORK/dry-mise.log" 2>&1; then
    bad "dry run exited non-zero without mise installed" "$WORK/dry-mise.log"
elif ! grep -q 'backend: mise' "$WORK/dry-mise.log"; then
    bad "header does not report backend: mise" "$WORK/dry-mise.log"
elif ! grep -q 'dry run complete' "$WORK/dry-mise.log"; then
    bad "no 'dry run complete' marker" "$WORK/dry-mise.log"
elif [ "$(grep -c 'would run: mise use -g' "$WORK/dry-mise.log")" -ne 6 ]; then
    bad "expected 6 mise plans, got $(grep -c 'would run: mise use -g' "$WORK/dry-mise.log")" "$WORK/dry-mise.log"
elif ! grep -q 'mise use -g npm:@ampcode/cli@latest' "$WORK/dry-mise.log"; then
    bad "amp is not pinned to the npm spec" "$WORK/dry-mise.log"
else
    pass "planned 6 mise specs (amp via npm), nothing installed"
fi

# Rejections: usage errors must exit 2, not install anything.
begin "unknown backend is rejected"
./"$SCRIPT" --backend not-a-backend >"$WORK/backend.log" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "exit 2"
else
    bad "expected exit 2, got $rc" "$WORK/backend.log"
fi

begin "unknown tool is rejected"
./"$SCRIPT" --only not-a-tool >"$WORK/tool.log" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "exit 2"
else
    bad "expected exit 2, got $rc" "$WORK/tool.log"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf 'gate: PASS (%d checks)\n' "$STEP"
    exit 0
fi
printf 'gate: FAIL (%d of %d checks)\n' "$FAILED" "$STEP" >&2
exit 1
