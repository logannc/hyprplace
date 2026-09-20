# hyprplace

A Hyprland plugin that remembers which workspace each app's windows live on, and puts
them back there when they open.

You arrange your session: browser on 2, chat on 31, the terminal running `btop` on 21.
Then you close something, or reboot, and it all opens wherever Hyprland happens to put
it. hyprplace watches where you actually put windows, and restores that the next time
they appear -- without a config file listing every app, and without moving anything
you have already touched.

> **Requires Hyprland configured in Lua.** This is a Lua plugin using the `hl.*` API;
> it cannot work with a hyprlang (`hyprland.conf`) setup. If your config is
> `hyprland.conf`, this is not usable for you. See [Requirements](#requirements).

> **Disclosure:** this was vibe coded while I was playing games with friends.
> This is not art, it is bespoke software fulfilling a specific need I had.
> It is being released because it may be useful to others as-is or as a starting point.
> I am a full-time software engineer, so care was taken, but I am disclosing that AI was used.

## What it does

- **Learns from what you do.** No app list to maintain. Moving a window, or closing one,
  is what teaches it.
- **Only places windows, never launches them.** Nothing is started on your behalf.
- **Silent.** Placement never changes focus or the active workspace -- windows arrive
  where they belong while you stay where you are.
- **Does nothing when unsure.** No record, an ambiguous match, or more windows than it
  remembers, and it steps aside and lets Hyprland decide. With an empty database it is
  indistinguishable from not being installed.
- **Leaves your windows alone once you touch them.** It acts when a window opens, not
  while you are using it.

## Requirements

| | |
|---|---|
| Hyprland | Configured in **Lua**, not hyprlang. Developed against 0.56.2 |
| Lua | Developed against 5.5 |
| shezdy/hyprsplit | **Not** required, but I use it for multimonitor workspace support and this is compatible |
| hypr-tags | **Optional but recommended**  See below. |

Workspaces are stored as raw ids, so nothing is coupled to a particular workspace
scheme. If you use hyprsplit's per-monitor blocks, a window remembered on workspace 21
goes back to 21 wherever that workspace currently lives.

### hypr-tags

This is the firefox extension (in this repo) that prepends tags to Firefox window titles (like `[ab12ef]`),
which is required for distinguishing firefox windows correctly.

Without this, hyprplace sees N firefox windows on M workspaces.
When placement happens, you'd get that same distribution of windows - which is only marginally useful.
I tend to group tabs and windows on a particular workspace according to some topic or task.
If I restart my computer and the windows are on jumbled workspaces, that's actually less helpful than all of them bunched up on a single starting workspace.

With the extension installed, firefox puts tags in the window title that are stable across firefox restarts.
hyprplace can then remember which firefox + tag belongs on each workspace for correct placement.

## Install

```sh
git clone https://github.com/logannc/hyprplace
cd hyprplace
./install.lua install
hyprctl reload
```

`--dry-run` previews without touching anything. The installer handles three separable
concerns -- the Lua modules, a `require()` block in `hyprland.lua`, and a CLI wrapper on
`PATH` -- each skippable with `--no-plugin` / `--no-config` / `--no-bin`. Re-running
converges rather than duplicating, and `./install.lua status` reports what is installed
and whether it still matches your checkout.

Your `hyprland.lua` gets a marked block appended:

```lua
-- >>> hyprplace >>>
local hyprplace_cfg = {
-- >>> hyprplace-config >>>
    -- your settings here
-- <<< hyprplace-config <<<
}
require("hyprplace").setup(hyprplace_cfg)
-- <<< hyprplace <<<
```

Everything outside the inner markers is regenerated on every install; everything between
them is yours and is preserved. If the block is damaged or ambiguous the installer
**refuses and explains** rather than guessing, and it checks that the file still parses
as Lua before writing -- a syntax error there means a session that will not come up.

See [Firefox windows](#firefox-windows) below for extension instructions.

## Configuration

Settings go between the inner markers. Every option, with its default and the reasoning,
is in [example_config.lua](example_config.lua). The ones most people want:

```lua
    -- Windows hyprplace should ignore entirely, by class or by Hyprland tag.
    ignore_classes = { "^hyprland%-run$", "^kitty$" },
    ignore_tags    = { "^floating%-window$" }, -- an example, but see ignore_floating as a default
    -- or
    ignore_floating = true,

    -- Entries unseen this long are dropped when the database loads.
    ttl_days = 90,

    -- Log what it decides and why. Worth a session or two when setting up.
    debug = true,
```

Overrides are a **shallow merge**: setting `ignore_classes` replaces the default list
rather than extending it, so copy the whole list from the example when adding to it.

Floating windows are skipped by default. A floating window is usually a dialog or a
picker, and those belong wherever your focus is -- remembering one also poisons its app's
entry, since a dialog generally shares a class with the app's main window.

## How windows are identified

Nothing about a window survives a reboot: its address dies when it closes, its pid dies
with the session. So identity is a fingerprint, layered most specific first.

| Tier | Key | Example |
|---|---|---|
| 0 | class + a tag the app publishes | `firefox + tag:cb4e3040` |
| 1 | class + normalized command line | `kitty + kitty btop` |
| 2 | class alone | `discord` |

Tier 1 makes `kitty btop` a different thing from a bare terminal. Volatile arguments are
dropped -- Steam's command line carries a fresh pid and build id on every launch, and a
fingerprint built from those could never match twice.

Tier 1 needs a process that serves exactly one window, which rules out browsers and
Electron apps. That is what tier 0 is for; see [Firefox windows](#firefox-windows).

**Apps with several windows remember all of them.** Ten Firefox windows across
workspaces 1, 2, 3, 3, 3, 4, 4, 5, 12, 32 record all ten positions, duplicates included,
because three of them genuinely belong on workspace 3. On open, hyprplace counts how many
are already placed and takes the first remaining slot. Windows beyond what it remembers
get no placement rather than a guess.

## Firefox windows

Every Firefox window shares one class and one process, so nothing distinguishes them --
nine windows collapse to a single identity and get placed by position rather than by
which window they are.

[`extension/`](extension/) is a small Firefox extension that fixes this. It gives each
window a stable tag, keeps it in Firefox's session store so it survives a restart, and
publishes it as a title prefix: `[cb4e3040] Inbox — Mozilla Firefox`. hyprplace reads the
tag and each window gets its own identity and its own exact workspace.

It is **entirely optional and separate**. hyprplace works without it; Firefox windows
just fall back to tier 2. The extension never receives anything from the compositor --
the title is a one-way channel by design.

Because the tag arrives a moment *after* a window opens, placement has to wait for it:

```lua
    defer_classes     = { "^firefox$" },
    defer_timeout_ms  = 10000,
```

Installing it: a signed `.xpi` is attached to releases, or build your own with
`npx web-ext sign` against your own AMO account. See
[extension/README.md](extension/README.md), which also covers what it does and does not
collect (nothing), and why toolbar-less "webapp" windows are deliberately not tagged.

## Inspecting what it is doing

The CLI is read-only except where noted, and never dispatches to the compositor.

| | |
|---|---|
| `hyprplace fingerprint` | what it sees for each open window, and what closing it would record |
| `hyprplace plan` | where each open window would be placed if it opened now |
| `hyprplace db` | the learned state, newest first |
| `hyprplace diff` | where learned state and the current layout disagree |
| `hyprplace watch` | live feed of window changes and the verdicts they produce |
| `hyprplace prune` | entries the TTL would drop (writes with `--apply`) |
| `hyprplace forget PAT` | entries whose key matches (writes with `--apply`) |

These read the configuration the *running plugin* resolved, so their verdicts match its
behaviour rather than the defaults'. The plugin also keeps its own log at
`~/.local/state/hyprplace/hyprplace.log` -- it cannot use `print`, because Hyprland's
`debug:disable_logs` defaults to true and swallows it.

## Uninstall

```sh
./install.lua uninstall
hyprctl reload
```

Restores `hyprland.lua` byte for byte and keeps your learned state; `--purge` removes
that too.

## Status

Working, and in use. This is a v0. 555 unit tests run without a compositor (`make test`).

## Development

```sh
make test     # unit tests, no compositor needed
make check    # every Lua file parses
```

There is also a contained nested-compositor harness for testing against a real Hyprland
without touching your session -- see [docs/ENVIRONMENT.required.md](docs/ENVIRONMENT.required.md).

Design decisions, and the reasoning behind the ones that reverse an obvious default, are
in [docs/DESIGN.required.md](docs/DESIGN.required.md). Things measured about how Hyprland
actually behaves are in [docs/OBSERVED.md](docs/OBSERVED.md).

### Contribution and Issues

This was developed to suit my own needs on my own machine to my own preferences.
You are welcome to open up a PR for contribution, but I will only accept it if it is useful to me.
Likewise, you are welcome to open an issue, but I will close them if I do not intend to solve it myself.
When I close, I will state whether that is because I do not want to do the work or if it is an antifeature,
in which case I will likely reject pull requests on the subject.

You are welcome and encouraged to fork this project for your own needs, subject to the MIT license.

### Distribution

With the exception of the hypr-tags signed extension I will be uploading as a release asset,
I will not be packaging this for distribution. e.g., AUR or anything like that
Others are welcome to but I will be uninvolved.

## License

[MIT](LICENSE).
