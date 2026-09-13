LUA ?= lua
DEST ?= $(HOME)/.config/hypr/hyprplace
SRC := init.lua config.lua db.lua identity.lua placement.lua json.lua policy.lua cli.lua

.PHONY: check test all install

all: test

## check: does every Lua file parse?
check:
	@for f in $(SRC) tests/*.lua harness/*.lua bin/hyprplace; do \
		$(LUA) -e "assert(loadfile('$$f'))" || exit 1; \
		echo "  ok  $$f"; \
	done

## test: syntax check, then unit tests (no compositor required)
test: check
	@$(LUA) tests/run.lua

## install: copy into the live Hyprland config. Run this yourself; it touches ~/.config.
install:
	@mkdir -p $(DEST)
	@cp $(SRC) $(DEST)/
	@echo "installed to $(DEST) -- add require(\"hyprplace\").setup({}) to hyprland.lua"
