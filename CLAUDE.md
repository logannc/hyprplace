# hyprplace

A Hyprland Lua plugin that remembers which workspace each app lives on and puts its
windows back there when they open.

**Status: pre-implementation.** Requirements and dev environment are settled and
documented; no plugin code exists yet.

## Required reading

**Read every `docs/*.required.md` file before doing anything in this repo.** They are
required, not background: they carry decisions that are already settled and constraints
that are not obvious from the code.

- [docs/DESIGN.required.md](docs/DESIGN.required.md) — problem, scope, decisions ledger,
  identity model, storage, acceptance criteria, open questions.
- [docs/ENVIRONMENT.required.md](docs/ENVIRONMENT.required.md) — the contained test
  compositor: how to build it, how to run it, the four non-obvious constraints, the
  containment contract.

Docs *without* the `.required` marker are optional — read them when the task makes them
relevant. Currently: [docs/FUTURE.md](docs/FUTURE.md) (near-term work and the post-MVP
feature exploration backlog; **do not** pull this work forward into the MVP). When adding a doc, mark it `.required.md` only if every agent must read it to
work safely here.

The decisions in DESIGN.required.md were made deliberately, and several of them reverse an
obvious-looking default — do not silently re-litigate them.

## Ground rules

**Do not modify the system.** No package installs, no `pacman`, no system-wide writes, no
edits outside this repo and the dev environment. If something appears to need installing,
stop and say so rather than working around it.

**Do not touch the live Hyprland session.** The user's desktop is running Hyprland 0.56.2
with real work in it. Specifically:

- Never `hyprctl dispatch`, `hyprctl keyword`, or any other mutating command against the
  live instance. Read-only queries (`hyprctl -j clients`, `monitors`, `workspaces`) are
  fine.
- `hyprctl eval` and `hyprctl repl` execute Lua **inside the live compositor**. Read-only
  expressions only, and prefer not to use them at all.
- Never write to `~/.config/hypr` or `~/.local/state/hyprplace`.
- Before signalling any process, confirm `/proc/<pid>/cmdline` matches the dev build. Never
  pattern-match on `Hyprland` alone.

**Best effort: nothing outside the dev environment is affected.** That is the standard the
containment contract in ENVIRONMENT.md exists to meet. Hold new work to it.

**Ask before launching a compositor** or doing anything else that could put a window on the
user's screen.

**Use jj, not git.** This repo is jj. Reach for git only where jj genuinely cannot do the
job — submodules and worktrees in the Hyprland checkouts are the known cases. The Hyprland
trees at `~/workspace/Hyprland` (the user's fork) and `~/workspace/Hyprland-upstream` are
jj-colocated; leave their working copies alone.

**Never enable tracy.** Do not init `subprojects/tracy`, do not set `USE_TRACY`. It takes
forever to compile and nothing here needs it.

**Sync before proceeding.** Discuss and agree before scaffolding or implementing. Work in
reviewable steps and pause at decision points rather than running ahead — especially for
anything that mutates the workspace, spawns processes, or commits.

## Installing

`./install.lua install | uninstall | status`, with `--dry-run` to preview. It handles
three separable concerns -- the Lua modules, the `require()` block in `hyprland.lua`, and
a CLI wrapper on PATH -- each skippable with `--no-plugin` / `--no-config` / `--no-bin`.
Re-running converges; `uninstall` restores `hyprland.lua` byte for byte and keeps learned
state unless `--purge`.

Not a make target: it is reversible, touches the live config, and its delicate part
(editing `hyprland.lua`) lives in `installer.lua` where it is unit tested.

Note the CLI wrapper execs the *installed* copy, so `hyprplace` on PATH and the running
plugin always agree. Running `./bin/hyprplace` from the repo uses repo modules instead --
`./install.lua status` reports when the two have drifted.

## Environment facts

- Hyprland **0.56.2** (`efb50993`), configured in **Lua**, not hyprlang.
- The live config at `~/.config/hypr/` is modular Lua (`hyprland.lua` requires `monitors`,
  `plugins`, `rules`, `binds`, `autostart`, …).
- **hyprsplit** is loaded as a Lua plugin, giving per-monitor workspace blocks:
  1-10, 11-20, 21-30, 31-40 across four monitors.
- The Lua API stubs live at `/usr/share/hypr/stubs/hl.meta.lua` — the authoritative
  reference for `hl.*`, events, and object fields.
- The compositor's Lua is **5.5, unsandboxed** — `io`, `os`, `package`, `debug` all
  present.
- `~/workspace/Hyprland` is the user's fork and has upstream Lua work in it. Do not disturb
  it.
