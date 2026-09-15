LUA ?= lua
SRC := init.lua config.lua db.lua identity.lua placement.lua json.lua policy.lua cli.lua learn.lua tag.lua cache.lua

.PHONY: check check-js test all

all: test

## check: does every Lua file parse?
check:
	@for f in $(SRC) tests/*.lua harness/*.lua bin/hyprplace installer.lua install.lua example_config.lua; do \
		$(LUA) -e "assert(loadfile('$$f'))" || exit 1; \
		echo "  ok  $$f"; \
	done

## check-js: syntax check the extension, if node is available
check-js:
	@if command -v node >/dev/null 2>&1; then \
		for f in extension/*.js; do \
			node --check "$$f" || exit 1; \
			echo "  ok  $$f"; \
		done; \
		node -e "JSON.parse(require('fs').readFileSync('extension/manifest.json'))" \
			&& echo "  ok  extension/manifest.json"; \
	else \
		echo "  skip  extension (node not installed)"; \
	fi

## test: syntax check, then unit tests (no compositor required)
test: check check-js
	@$(LUA) tests/run.lua

# Installation is ./install.lua (install | uninstall | status), not a make target:
# it has three separable concerns, needs to be reversible, and touches the live config.
