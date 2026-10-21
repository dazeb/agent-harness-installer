.PHONY: lint test dry check install

# Same gate as .github/workflows/ci.yml
lint:
	bash -n install-agent-harnesses.sh
	shellcheck --severity=warning --format=gcc install-agent-harnesses.sh

test: lint
	./install-agent-harnesses.sh --help > /dev/null
	./install-agent-harnesses.sh --dry-run | tee /tmp/ah-dry.log
	grep -q 'dry run complete' /tmp/ah-dry.log
	./install-agent-harnesses.sh --dry-run --backend mise | tee /tmp/ah-dry-mise.log
	grep -q 'backend: mise' /tmp/ah-dry-mise.log
	grep -q 'dry run complete' /tmp/ah-dry-mise.log
	! ./install-agent-harnesses.sh --backend not-a-backend 2>/dev/null
	! ./install-agent-harnesses.sh --only not-a-tool 2>/dev/null

dry:
	./install-agent-harnesses.sh --dry-run

check:
	./install-agent-harnesses.sh --check

install:
	./install-agent-harnesses.sh
