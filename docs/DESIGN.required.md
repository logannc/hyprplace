# hyprplace — Design

Status: **pre-implementation**. Requirements and dev environment settled; no plugin code written yet.
Target: Hyprland **0.56.2** (Lua config API, `hl.*`).

## Problem

Hyprland does not remember where windows lived. Reopening an app — or starting a fresh
session after a reboot — drops its windows wherever the layout happens to put them.
hyprplace learns which workspace each app is used on and puts it back there on open.

## Scope

**In scope**

- Remember the workspace a window was on, keyed by a fingerprint of the app.
- On window open, move the window to its remembered workspace, silently.
- Learn continuously from deliberate user moves.
- Persist across compositor restarts and reboots.

**Out of scope** (deliberately, see Decisions)

- Launching or relaunching applications. hyprplace never spawns a process.
- Window geometry, size, floating position.
- Fullscreen, pinned, or grouped state.
- Position within the tiling tree.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Placement only; never launches apps | Smallest blast radius. Works identically for apps launched mid-session, not just at startup. |
| 2 | Workspace only — no geometry or window state | The only property with an unambiguous correct answer. Tiled geometry is owned by the layout; restoring fullscreen/pin surprises more than it helps. |
| 3 | Layered identity: `class` → `/proc/<pid>/cmdline` → ordinal | Distinguishes `kitty btop` from a bare `kitty`, which class alone cannot. Falls back gracefully when a pid serves many windows (Firefox, Electron). |
| 4 | Auto-learn, last deliberate move wins | Zero configuration; adapts as habits change. Requires a strict definition of "deliberate" (see Learning). |
| 5 | Store raw workspace ids, not `(monitor, slot)` | hyprsplit migrates whole workspaces between monitors on hotplug. The workspace is the durable identity and the monitor follows it. Also removes any coupling to hyprsplit internals. |
| 6 | Event hooks + dispatch, **not** generated window rules | Window state must stay independent of config. Rules cannot express ordinals or cmdline matching anyway. |
| 7 | Standalone repo, installed by copy | Keeps the dev tree out of the live config tree. |
| 8 | Fake-`hl` unit tests + manual probe harness | Most logic (key derivation, cmdline parsing, ordinals, DB round-trip) needs no compositor. |
| 9 | Test against v0.56.2 built from source | Exact parity with the running desktop; no dependency work required. |
| 10 | Nothing may affect anything outside the dev environment | Verified: see Development Environment. |

## Architecture

hyprplace is a Lua module loaded in-process by the compositor:

```
~/.config/hypr/hyprland.lua
  └── require("hyprplace")        -- resolved via ~/.config/hypr/?/init.lua
        ├── hl.on("window.open_early", place)
        ├── hl.on("window.move_to_workspace", learn)
        └── hl.on("window.close", record_last_known)
```

**Placement path** (`window.open_early`)

1. Derive identity key from the window.
2. Look up the key in the in-memory DB. Miss → do nothing.
3. Resolve the remembered workspace id. Gone → do nothing.
4. Set the self-move guard, dispatch `hl.dsp.window.move{window, workspace}` silently, clear the guard.

**Learning path** (`window.move_to_workspace`)

1. If the self-move guard is set, ignore — this is our own move echoing back.
2. If the move is not deliberate (see below), ignore.
3. Record `key → workspace id`, debounce, write atomically.

## Window identity

No stable cross-session id exists. `address` and `stable_id` die on close; `pid` dies on
reboot. The key is layered, most specific first:

1. `class` + normalized `/proc/<pid>/cmdline` — used only when the pid maps to exactly one
   window. Wrapper prefixes (`uwsm app --`) are stripped.
2. `class` + instance ordinal — for multi-window apps sharing one pid.
3. `class` alone — last resort.

For multi-instance apps the record is an *ordered list* of workspaces. On open, take the
first remembered workspace not already occupied by a live window with the same key.
Windows beyond the remembered count get no placement rather than a guess.

## Learning: what counts as "deliberate"

`window.move_to_workspace` fires for far more than user intent. It must **not** learn from:

- Our own placement dispatch (guard flag).
- hyprsplit's `swap_monitors`, which mass-moves every window on two workspaces.
- The workspace reflow triggered by `monitor.added` / `monitor.removed` — the KVM fires
  this on every machine swap, and learning from it would rewrite the entire database.

Working definition: a single focused window, moved on its own, while no monitor event is
in flight.

## Storage

- Path: `~/.local/state/hyprplace/db.lua`, overridable via `HYPRPLACE_DB` (tests).
- Format: a versioned Lua table, loaded with `load()` — no JSON dependency.
- Writes are debounced and atomic (`tmp` + `os.rename`) so a crash cannot corrupt it.
- Entries carry a `seen` timestamp and expire after `ttl_days`. Placement refreshes
  `seen` (recency only, never the slot order), so an app in regular use does not expire
  just because it is never explicitly moved.
- Recorded on deliberate move and on window close. `hyprland.shutdown` alone is
  insufficient — it does not fire on a hard crash.

## Acceptance criteria

**AC-1 (core).** Open an app on workspace 3, close it, relaunch it from anywhere → it
appears on workspace 3.

**AC-2 (silent).** Placement never changes focus or the active workspace. The user stays
exactly where they were.

**AC-3 (safe uncertainty).** No record, ambiguous match, or a workspace that no longer
exists → hyprplace does nothing and Hyprland decides. Behavior is indistinguishable from
the plugin not being installed.

**AC-4 (no fighting).** A window the user moves stays moved. hyprplace acts only at open
time; it never relocates an existing window.

**AC-5 (persistence).** State survives a full compositor restart.

**AC-6 (harmless failure).** Any error inside hyprplace is contained and never breaks the
compositor or the config.

## Constraints and risks

- **hyprplace runs inside the compositor process.** An uncaught Lua error or a slow
  handler in `window.open_early` blocks the compositor. Every entry point is `pcall`
  wrapped; no blocking I/O in hot paths.
- **Reload wipes all in-memory state.** `hyprctl reload` destroys and recreates the Lua
  VM (measured). The DB must be loaded from disk at module load; nothing may be cached
  only in `_G` across a reload.
- **XWayland class timing.** `class` may be empty at `window.open_early` for XWayland
  windows, requiring a deferral to `window.class`. *(Still unverified — XWayland is
  disabled in the probe config to avoid stray coredumps.)*

## Version skew (v0.56.2 → upstream main)

Relevant if the desktop is upgraded. `HL.API` and the whole `dsp.window` namespace are
unchanged; what moved is data shape:

| Item | v0.56.2 | main |
|------|---------|------|
| `config.unload` event | absent | present — clean teardown hook |
| `HL.Window.stable_id` | `integer` | `string` |
| `HL.Workspace.config_name` | present | renamed `addressable_name` |
| `HL.Workspace.id` | `integer` | `integer\|nil` |

Write against the intersection: nil-guard every workspace id, do not depend on
`stable_id`'s type, feature-detect `config.unload`.

## Development environment

See [ENVIRONMENT.required.md](ENVIRONMENT.required.md). In short: a contained Hyprland v0.56.2 built from
source at the same commit as the installed binary, running nested-but-invisible with an
isolated runtime dir and no GPU access, verified to leave the live session untouched.

## Measured behaviour

All measured in the contained harness against v0.56.2. See `harness/probe.lua`.

**The Lua VM is destroyed and recreated on `hyprctl reload`.** A marker planted in `_G`
via the repl does not survive a reload, and the config's load counter reads 1 afterwards,
not 2. Consequences: `hl.on` subscriptions *cannot* stack, so idempotent registration is
unnecessary; and every reload starts from an empty `_G`, so the DB must be read from disk
at module load. The absence of `config.unload` in 0.56.2 therefore does not matter.

**Event order on window open is `window.class` → `window.open_early` → `window.open`.**
At `open_early` a native Wayland window already has `class`, `initial_class`, `title`,
`pid`, and `workspace.id` populated — everything placement needs. `window.class` fires
earlier still, but with empty `initial_class`/`title` and a nil workspace, so it is only
useful as an XWayland fallback.

**Our own dispatch does echo back as `window.move_to_workspace`, synchronously.** The
handler runs inside the `hl.dispatch` call, while the guard flag is still set. So a plain
non-reentrant boolean guard is both necessary (the echo is real) and sufficient (there is
no async window in which the flag has already been cleared).

**`hl.dsp.window.move` follows focus by default; `follow = false` makes it silent.** With
`follow = false` the window moves and the active monitor and workspace do not change,
which is exactly AC-2. Placement must always pass it.

**Handler signature.** `window.move_to_workspace` receives `(window, workspace)`.

## Open questions

- Is `class` populated at `window.open_early` for **XWayland** windows, or must placement
  defer to `window.class`? Requires re-enabling XWayland in the probe config.
- Which apps belong on the default exclusion list (dialogs, file pickers, `hyprland-run`,
  a password manager)?
- How should the ordinal be assigned when several windows of one app open near-
  simultaneously at session start?
