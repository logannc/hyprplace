# Observed behaviour

Optional doc. Facts about how Hyprland actually behaves, established by experiment or by
reading its source rather than by assumption. Recorded because every one of them cost
something to find, and several reverse what the API's shape suggests.

Each entry says where it came from. **Harness** means the contained test compositor
(`harness/probe.lua`, v0.56.2). **Live** means the author's running session. **Source**
means the Hyprland tree, cited by file and line.

---

## Configuration and lifecycle

**The Lua VM is destroyed and recreated on `hyprctl reload`.** *(Harness.)* A marker
planted in `_G` via the repl does not survive a reload, and the config's load counter
reads 1 afterwards, not 2. Consequences: `hl.on` subscriptions *cannot* stack, so
idempotent registration is unnecessary; and every reload starts from an empty `_G`, so
the DB must be read from disk at module load. The absence of `config.unload` in 0.56.2
therefore does not matter.

**Lua `print()` is swallowed by default.** *(Live, confirmed in source.)* It routes to
Hyprland's logger — `Log::logger->log(Log::INFO, "[Lua] {}", out)` in
`LuaBindingsRegistration.cpp:25` — which is gated on `debug:disable_logs`, and that
**defaults to `true`** (`ConfigValues.cpp:624`, read at `Logger.cpp:42`). Output from the
very first config parse slips through before the option takes effect, which is why a
plugin appears to log at boot and then goes silent on every reload afterwards. This is
why hyprplace keeps its own log file rather than relying on `print`.

## Window events

**Event order on window open is `window.class` → `window.open_early` → `window.open`.**
*(Harness.)* At `open_early` a native Wayland window already has `class`,
`initial_class`, `title`, `pid`, and `workspace.id` populated — everything placement
needs. `window.class` fires earlier still, but with empty `initial_class`/`title` and a
nil workspace, so it is only useful as an XWayland fallback.

**XWayland windows carry a `class` at `window.open_early`.** *(Live.)* Observed via
Steam, which is XWayland: its placement verdict is logged from the `open_early` handler,
which it only reaches past the no-class check. The design allowed for needing a fallback
to the `window.class` event for XWayland; that fallback is not needed.

**`floating` is populated at `window.open_early`.** *(Live.)* A floating dialog is
identifiable as such at open, before any placement decision is made — so
`ignore_floating` works on the placement path and not merely on the learning path. Worth
having checked: window rules are what float many windows, and there was no reason to
assume they had run by then.

**Handler signature.** `window.move_to_workspace` receives `(window, workspace)`.

**The workspace argument is userdata, not a table.** *(Live.)* A `type(ws) == "table"`
test fails on it, silently yielding the object where an id was expected. Serialized with
`tostring` it becomes `HL.Workspace(22:22)`, which is not valid Lua — so a state file
written from it cannot be read back and the whole database is silently lost. Index
duck-typed on `.id` rather than testing the type.

## Dispatch

**Our own dispatch echoes back as `window.move_to_workspace`, synchronously.**
*(Harness.)* The handler runs inside the `hl.dispatch` call, while the guard flag is
still set. So a plain non-reentrant boolean guard is both necessary (the echo is real)
and sufficient (there is no async window in which the flag has already been cleared).

**`hl.dsp.window.move` follows focus by default; `follow = false` makes it silent.**
*(Harness.)* With `follow = false` the window moves and the active monitor and workspace
do not change, which is exactly AC-2. Placement must always pass it.

## Timers and subscriptions

**`HL.Timer` cannot be cancelled.** *(Source: the stubs at
`/usr/share/hypr/stubs/hl.meta.lua`.)* It exposes `is_enabled`, `set_enabled` and
`set_timeout` and nothing else. A one-shot timer that should no longer fire cannot be
retracted, only ignored when it arrives — so anything cancellable needs a generation
counter or a repeating sweep that can be disabled, not a timer per item.

**`HL.EventSubscription` *can* be cancelled**, via `:remove()`, with `:is_active()` to
check. So a subscription to a high-frequency event can be held only while it is needed.

## Window tags

**A rule-applied tag is stored with a `*` suffix.** *(Source: `TagKeeper.cpp`.)*
`applyTag(tag, dynamic = true)` appends it to mark the tag dynamic, so
`tag = "+floating-window"` in a window rule arrives as `floating-window*`. Hyprland's own
`isTagged` treats `foo` and `foo*` as the same tag, so anything matching against tags
must strip the marker or patterns written against a user's rules will never fire.

**The Lua API and `hyprctl` report identical tag strings.** *(Source:
`LuaWindow.cpp:135` and `HyprCtl.cpp:345`, both reading `m_tagKeeper.getTags()`.)* So the
plugin and the CLI tools cannot disagree about a window's tags.

## Firefox

**A toolbar-less "webapp" window is a popup, and so is untagged.** *(Live.)* Add-ons
that open a site without browser chrome create a window with `type: "popup"`, which is
how the chrome goes away. The hypr-tags extension only tags `type === "normal"`, so such
a window falls back to hyprplace's class tier. See `extension/README.md`; it is a
deliberate rule meeting a case it was not written for, not a bug.

## hyprsplit

**Monitor hotplug does not move windows between workspaces.** *(Source: the installed
hyprsplit at `~/.config/hypr/hyprsplit/`.)* Its `monitor.added` handler dispatches
`hl.dsp.workspace.move` — whole workspaces between monitors — and `hl.dsp.focus`, never
`hl.dsp.window.move`. Its `monitor.removed` handler only toggles workspace persistence
rules. Windows keep the workspace they are on, so nothing hyprplace records changes.

**`swap_monitors` *does* mass-move windows**, dispatching `hl.dsp.window.move` per
window. It is a keybind the user invokes, not a reaction to hardware, and it is caught by
the focused-window test rather than by any freeze.
