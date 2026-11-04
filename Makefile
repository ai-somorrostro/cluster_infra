# Makefile — repository maintenance tasks
SHELL := /bin/bash
SCRIPTS := $(shell find lib vm host guest -name '*.sh' 2>/dev/null | sort)
PYTHON := $(shell find lib vm host guest -name '*.py' 2>/dev/null | sort)
SHELLCHECK ?= shellcheck

.PHONY: help lint syntax check secrets

help:
	@echo "make lint     → shellcheck on lib/ vm/ host/ guest/"
	@echo "make syntax   → bash -n on every script, py_compile on every Python file"
	@echo "make secrets  → checks that no credentials are committed"
	@echo "make check    → all of the above"

lint:
	@$(SHELLCHECK) -x -P SCRIPTDIR $(SCRIPTS) && echo "shellcheck OK ($(words $(SCRIPTS)) scripts)"

syntax:
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done && echo "bash -n OK"
	@python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' $(PYTHON) && echo "python syntax OK ($(words $(PYTHON)) files)"

secrets:
	@bad=$$(git ls-files | grep -E '(^|/)(\.env|users\.txt|groups\.txt|usuarios\.txt|clusters\.conf|[^/]*\.pkrvars\.hcl|user-data)$$|wireward_generator/configs/|^mcp/.*/config\.json$$|^config/mig/.*\.credentials$$|^config/mig/(.*/)?[^/]*\.toml$$' | grep -v '^config/mig/example\.toml$$' || true); \
	if [ -n "$$bad" ]; then echo "Sensitive files tracked by git:"; echo "$$bad"; exit 1; else echo "secrets OK"; fi

check: syntax lint secrets
