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

# --- interactive picker -----------------------------------------------------
# The picker reads answers from stdin, so a pipe drives it exactly like a human.
# The point of these checks: the prompt must explain both methods, detect what
# is already installed, honour the choice, and never install during a dry run.

begin "--interactive: quit leaves everything alone"
if ! printf 'q\n' | "${CLEAN[@]}" ./"$SCRIPT" --interactive --dry-run >"$WORK/pick-quit.log" 2>&1; then
    bad "quit path exited non-zero" "$WORK/pick-quit.log"
elif ! grep -q 'nothing was changed' "$WORK/pick-quit.log"; then
    bad "no 'nothing was changed' marker" "$WORK/pick-quit.log"
elif grep -q 'would run' "$WORK/pick-quit.log"; then
    bad "quit path still planned work" "$WORK/pick-quit.log"
elif ! grep -q 'Regular install' "$WORK/pick-quit.log" ||
     ! grep -q 'mise upgrade' "$WORK/pick-quit.log"; then
    bad "picker does not explain both methods" "$WORK/pick-quit.log"
else
    pass "explained both methods, exited without a plan"
fi

begin "--interactive: choice 1 = vendor plan"
if ! printf '1\n' | "${CLEAN[@]}" ./"$SCRIPT" --interactive --dry-run >"$WORK/pick-vendor.log" 2>&1; then
    bad "vendor choice exited non-zero" "$WORK/pick-vendor.log"
elif [ "$(grep -c 'would run install_' "$WORK/pick-vendor.log")" -ne 6 ]; then
    bad "expected 6 vendor plans" "$WORK/pick-vendor.log"
elif grep -q 'would run: mise use -g' "$WORK/pick-vendor.log"; then
    bad "vendor choice planned a mise call" "$WORK/pick-vendor.log"
elif ! grep -q 'claude .*\.local/bin/claude' "$WORK/pick-vendor.log"; then
    bad "claude executable location is not shown" "$WORK/pick-vendor.log"
else
    pass "6 vendor plans + claude location"
fi

# A stub mise on PATH: the picker must not try to bootstrap it, and the plan
# must be mise's, including the one-command upgrade hint.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/mise" <<'STUBEOF'
#!/bin/sh
case "$1" in
    --version) printf '2026.10.0 linux-x64\n' ;;
    which)     exit 1 ;;
    *)         exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/mise"

begin "--interactive: choice 2 = mise plan"
if ! printf '2\n' | env -i "HOME=$WORK/home" "PATH=$STUB:/usr/bin:/bin" \
        "SHELL=/bin/bash" "TERM=dumb" ./"$SCRIPT" --interactive --dry-run \
        >"$WORK/pick-mise.log" 2>&1; then
    bad "mise choice exited non-zero" "$WORK/pick-mise.log"
elif ! grep -q 'method: mise' "$WORK/pick-mise.log"; then
    bad "picker did not switch to mise" "$WORK/pick-mise.log"
elif [ "$(grep -c 'would run: mise use -g' "$WORK/pick-mise.log")" -ne 6 ]; then
    bad "expected 6 mise plans" "$WORK/pick-mise.log"
elif ! grep -q 'mise upgrade' "$WORK/pick-mise.log"; then
    bad "mise upgrade command is not shown" "$WORK/pick-mise.log"
else
    pass "6 mise plans + upgrade command"
fi

begin "--no-input never prompts"
if ! printf '1\n' | "${CLEAN[@]}" ./"$SCRIPT" --no-input --dry-run >"$WORK/noinput.log" 2>&1; then
    bad "--no-input exited non-zero" "$WORK/noinput.log"
elif grep -q 'Choose 1' "$WORK/noinput.log"; then
    bad "--no-input still prompted" "$WORK/noinput.log"
elif ! grep -q 'backend: vendor' "$WORK/noinput.log"; then
    bad "--no-input did not keep the vendor default" "$WORK/noinput.log"
else
    pass "no prompt, vendor default kept"
fi

begin "--interactive + --backend: the flag wins over the menu"
if ! printf '1\n' | "${CLEAN[@]}" ./"$SCRIPT" --interactive --backend mise --dry-run \
        >"$WORK/pick-flag.log" 2>&1; then
    bad "exited non-zero" "$WORK/pick-flag.log"
elif grep -q 'Choose 1' "$WORK/pick-flag.log"; then
    bad "menu was shown even though --backend was given" "$WORK/pick-flag.log"
elif ! grep -q 'method: mise (from --backend)' "$WORK/pick-flag.log"; then
    bad "--backend mise was not honored" "$WORK/pick-flag.log"
elif ! grep -q 'would run: mise use -g claude@latest' "$WORK/pick-flag.log"; then
    bad "no mise plan after --backend mise" "$WORK/pick-flag.log"
else
    pass "no menu, mise plan kept"
fi

# --- reversibility ----------------------------------------------------------
# --fix-path edits ~/.profile, so it must copy it first and --restore must put
# the original bytes back.
begin "--fix-path backs up, --restore reverts"
RH="$WORK/rhome"
mkdir -p "$RH/bin"
printf '#!/bin/sh\nprintf "1.2.3 (Claude Code)\\n"\n' >"$RH/bin/claude"
chmod +x "$RH/bin/claude"
printf 'ORIGINAL\n' >"$RH/.profile"
if ! env -i "HOME=$RH" "PATH=$RH/bin:/usr/bin:/bin" "SHELL=/bin/bash" \
        ./"$SCRIPT" --check --fix-path --only claude --no-input >"$WORK/fixpath.log" 2>&1; then
    bad "--fix-path run failed" "$WORK/fixpath.log"
elif ! grep -q 'agent-harnesses PATH' "$RH/.profile"; then
    bad "PATH block was not added" "$WORK/fixpath.log"
elif ! grep -rqs '^ORIGINAL$' "$RH/.local/state/agent-harnesses/backups"; then
    bad "no backup of the original profile" "$WORK/fixpath.log"
elif ! env -i "HOME=$RH" "PATH=/usr/bin:/bin" ./"$SCRIPT" --restore >"$WORK/restore.log" 2>&1; then
    bad "--restore failed" "$WORK/restore.log"
elif [ "$(cat "$RH/.profile")" != "ORIGINAL" ]; then
    bad "--restore did not bring back the original profile" "$WORK/restore.log"
else
    pass "backed up, patched, restored byte-for-byte"
fi

# --- regressions found by the audit ------------------------------------------
# Stub curl: records every call; installers it "downloads" are tiny scripts.
CURLSTUB="$WORK/curlstub"
mkdir -p "$CURLSTUB"
cat >"$CURLSTUB/curl" <<STUBEOF
#!/bin/bash
echo "curl \$*" >>"$WORK/curl.log"
out=""
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { out=\$2; shift; }; shift; done
printf '#!/bin/bash\necho \$\$ >"%s/inst.pid"\nsleep \${AH_STUB_SLEEP:-0}\n' "$WORK" >"\$out"
STUBEOF
chmod +x "$CURLSTUB/curl"

begin "--dry-run never bootstraps mise (picker: mise + yes)"
: >"$WORK/curl.log"
mkdir -p "$WORK/drhome"
if ! printf '2\ny\nn\n' | env -i "HOME=$WORK/drhome" "PATH=$CURLSTUB:/usr/bin:/bin" "SHELL=/bin/bash" \
        ./"$SCRIPT" --interactive --dry-run --only claude >"$WORK/dry-boot.log" 2>&1; then
    bad "dry run exited non-zero" "$WORK/dry-boot.log"
elif [ -s "$WORK/curl.log" ]; then
    bad "dry run downloaded something: $(head -n1 "$WORK/curl.log")" "$WORK/dry-boot.log"
elif [ -e "$WORK/drhome/.local/bin/mise" ]; then
    bad "dry run installed mise" "$WORK/dry-boot.log"
else
    pass "no download, no mise"
fi

begin "--check --upgrade reports an installed harness as ok"
CH="$WORK/chome"
mkdir -p "$CH/bin"
printf '#!/bin/sh\nprintf "9.9.9\\n"\n' >"$CH/bin/claude"
chmod +x "$CH/bin/claude"
if ! env -i "HOME=$CH" "PATH=$CH/bin:/usr/bin:/bin" "SHELL=/bin/bash" \
        ./"$SCRIPT" --check --upgrade --only claude --no-input >"$WORK/check-up.log" 2>&1; then
    bad "--check --upgrade failed for a working harness" "$WORK/check-up.log"
elif grep -q 'is missing' "$WORK/check-up.log"; then
    bad "reported a working harness as missing" "$WORK/check-up.log"
else
    pass "ok, nothing reinstalled"
fi

begin "--only/--skip reject a typo next to a valid name"
./"$SCRIPT" --only claude,clade >"$WORK/typo-only.log" 2>&1
rc1=$?
./"$SCRIPT" --skip gemni >"$WORK/typo-skip.log" 2>&1
rc2=$?
if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    pass "both exit 2"
else
    bad "expected exit 2 twice, got $rc1 and $rc2" "$WORK/typo-only.log"
fi

begin "--restore saves a file it deletes (created-by-run files)"
RC="$WORK/rchome"
mkdir -p "$RC/bin"
cp "$RH/bin/claude" "$RC/bin/claude"
if ! env -i "HOME=$RC" "PATH=$RC/bin:/usr/bin:/bin" "SHELL=/bin/bash" \
        ./"$SCRIPT" --check --fix-path --only claude --no-input >"$WORK/rc-fix.log" 2>&1; then
    bad "--fix-path run failed" "$WORK/rc-fix.log"
else
    printf 'LATER_EDIT\n' >>"$RC/.profile"
    env -i "HOME=$RC" "PATH=/usr/bin:/bin" ./"$SCRIPT" --restore >"$WORK/rc-restore.log" 2>&1
    if [ -e "$RC/.profile" ]; then
        bad "created-by-run .profile was not removed" "$WORK/rc-restore.log"
    elif ! grep -rqs '^LATER_EDIT$' "$RC/.local/state/agent-harnesses/backups"; then
        bad "the deleted file's content was not saved first" "$WORK/rc-restore.log"
    else
        pass "removed, with its latest content saved under backups/"
    fi
fi

begin "a stop signal kills the running installer and exits"
SH="$WORK/sighome"
mkdir -p "$SH"
env -i "HOME=$SH" "TMPDIR=$WORK" "PATH=$CURLSTUB:/usr/bin:/bin" "SHELL=/bin/bash" "AH_STUB_SLEEP=47" \
    ./"$SCRIPT" --no-input --only claude >"$WORK/sig.log" 2>&1 &
SIGPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$WORK/inst.pid" ] && break
    sleep 0.5
done
INSTPID=$(cat "$WORK/inst.pid" 2>/dev/null || echo 0)
kill -TERM "$SIGPID" 2>/dev/null
GONE=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$SIGPID" 2>/dev/null || { GONE=1; break; }
    sleep 0.5
done
wait "$SIGPID" 2>/dev/null
if [ "$GONE" -eq 0 ]; then
    kill -KILL "$SIGPID" 2>/dev/null
    bad "installer script still running 5s after SIGTERM" "$WORK/sig.log"
elif [ "$INSTPID" -gt 0 ] && kill -0 "$INSTPID" 2>/dev/null; then
    kill -KILL -- "-$INSTPID" 2>/dev/null
    bad "the detached installer survived the signal" "$WORK/sig.log"
elif ls "$WORK"/claude-install.*.sh >/dev/null 2>&1; then
    bad "temp installer script was left behind" "$WORK/sig.log"
else
    pass "installer stopped, temp script removed"
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
