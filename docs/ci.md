# CI when GitHub Actions is unavailable

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
`--dry-run --backend {vendor,mise}` plans, the interactive picker (piped `q`/`1`/`2`, plus
`--no-input`), a `--fix-path` → `--restore` round-trip, regressions for the audit findings (a dry
run never bootstraps mise, `--check --upgrade`, `--only`/`--skip` typos, restore snapshotting
created files, SIGTERM stopping the detached installer), and the usage-error rejections.
`.github/workflows/ci.yml` and `ci/run-gate.sh` both end up running it, so the verdict is identical
either way.

`ci/run-gate.sh` is the runner stand-in. It keeps a mirror clone, gates `origin/main`'s SHA in the
`ci/Dockerfile` image (so the box needs no `shellcheck` of its own), and posts `pending` → `success`
/`failure` under the context `ah-gate`. The commit page shows a check dot, and the badge works:

```markdown
![gate](https://img.shields.io/github/checks-status/dazeb/agent-harness-installer/main)
```

(the path form `github/commit-status/…/main/ah-gate` 404s — that endpoint takes no context segment;
`checks-status` is the one that renders from the posted status.)

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


[Back to the README](../README.md)
