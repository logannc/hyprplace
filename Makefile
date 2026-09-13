LUA ?= lua
SRC := init.lua config.lua db.lua identity.lua placement.lua json.lua policy.lua cli.lua learn.lua

.PHONY: check test all

all: test

## check: does every Lua file parse?
check:
	@for f in $(SRC) tests/*.lua harness/*.lua bin/hyprplace installer.lua install.lua; do \
		$(LUA) -e "assert(loadfile('$$f'))" || exit 1; \
		echo "  ok  $$f"; \
	done

## test: syntax check, then unit tests (no compositor required)
test: check
	@$(LUA) tests/run.lua

# Installation is ./install.lua (install | uninstall | status), not a make target:
# it has three separable concerns, needs to be reversible, and touches the live config.
