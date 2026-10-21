# Hermetic environment for ci/gate.sh — used by ci/run-gate.sh on a VM/box that
# has no shellcheck of its own, and by anyone who wants a reproducible gate.
#
#   docker build -t ah-gate ci/
#   docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/src:ro" ah-gate
#
# The gate must not run as root (install-agent-harnesses.sh refuses root), so
# the image ships a normal user and the runner passes --user anyway.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      shellcheck \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1000 --shell /bin/bash gate

WORKDIR /src
USER gate

ENTRYPOINT ["/src/ci/gate.sh"]
