# hyprplace

A Hyprland Lua plugin that remembers which workspace each app lives on and puts its
windows back there when they open.

## Status

**Installed and running on the author's live session.** The core acceptance criteria have
been verified against a real compositor, not just in tests: AC-1 (close an app, reopen
it, it returns), AC-2 (placement never steals focus), AC-3 (an empty database is
indistinguishable from not being installed), AC-6 (errors are contained *and* visible).
The Firefox tag path works end to end through a signed extension.

| | |
|---|---|
| Plugin | `init.lua` + `config` `db` `identity` `placement` `policy` `learn` `tag` `cache` |
| Tools | `bin/hyprplace` — `fingerprint` `plan` `db` `diff` `prune` `forget` `watch` |
| Extension | `extension/` — hypr-tags, signed and installed. See `extension/README.md` |
| Installer | `./install.lua install \| uninstall \| status` |
| Test harness | `./harness/compositor.sh start\|stop\|cmd\|repl` |
| Tests | `make test` (555, no compositor needed); `make check` parses only |
| Public docs | `README.md` is user-facing; this file is for agents working in the repo |

**Not yet verified: a full reboot.** That is the one remaining gap, and it is the
dangerous one — teardown closes every window after monitors are removed, so if
`hyprland.shutdown` does not beat the close storm the database is rewritten with the
collapsing layout and the evidence is destroyed with it. Copy `db.lua` aside before
logging out and diff afterwards rather than trusting it. The reboot also settles whether
`w.active == false` really filters hyprsplit's mass moves.

Two of the three original unknowns are settled and recorded in
[docs/OBSERVED.md](docs/OBSERVED.md): XWayland windows **do** carry a `class` at
`window.open_early` (observed via Steam), and `floating` is populated there too.

**Publishing is in progress** — MIT licence, README, and CI are in place. Still to do: a
redaction audit over every revision (secrets, identifiers, behavioural profile, fixtures,
and revision descriptions), then the push itself. Nothing has been pushed anywhere yet,
which is the only moment rewriting history is cheap.

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
relevant. Currently:

- [docs/OBSERVED.md](docs/OBSERVED.md) — how Hyprland actually behaves, measured or read
  from its source. Several entries reverse what the API's shape suggests; check here
  before assuming.
- [docs/FUTURE.md](docs/FUTURE.md) — near-term work and the post-MVP feature exploration
  backlog.
- [docs/FIREFOX-TAGS.md](docs/FIREFOX-TAGS.md) — design for a WebExtension that gives
  Firefox windows stable identities, plus what that implies for the plugin.

**Do not** pull work from either forward into the MVP. When adding a doc, mark it `.required.md` only if every agent must read it to
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

The block it writes is nested. The outer `-- >>> hyprplace >>>` markers delimit generated
code that is regenerated on every run; the inner `-- >>> hyprplace-config >>>` markers
delimit the user's settings, which are spliced back verbatim. The inner pair hugs the
table body only, so the variable name and the `setup()` call stay on the generated side
and a config edit cannot break the wiring. `example_config.lua` documents every option at
its default and is what users copy from -- a test asserts it covers every key in
`Config.defaults()`.

Anything the installer cannot read unambiguously -- duplicate markers, an unpaired one, a
hand-written block with no config section -- is a **refusal**, never a guess: clobbering
settings is the failure the nesting exists to prevent. `install` and `status` also `load()`
the file, so an unbalanced brace is caught there rather than as a session that will not
come up.

The plugin writes the configuration it resolved to `~/.local/state/hyprplace/config.lua`
at every config load, and the CLI reads it. Without that the tools run on built-in
defaults, so `hyprplace plan` reports `move` for a window the plugin defers and calls a
window tracked that `require_cmdline` excludes -- a tool disagreeing with the plugin is
worse than no tool. It is generated state, not user data: `uninstall` deletes it,
`--purge` is only needed for the learned state, and `hyprplace --no-config` ignores it.
`hyprplace db` prints which config it used.

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
