-- hyprplace: every option, at its default.
--
-- This file is a REFERENCE, not something hyprplace loads. Nothing reads it at
-- runtime; `make test` only checks that it stays in step with config.lua. Copy the
-- lines you want to change into the config block that the installer writes into your
-- hyprland.lua:
--
--     -- >>> hyprplace >>>
--     local hyprplace_cfg = {
--     -- >>> hyprplace-config >>>
--         ttl_days = 30,                  -- <- your settings go here
--     -- <<< hyprplace-config <<<
--     }
--     require("hyprplace").setup(hyprplace_cfg)
--     -- <<< hyprplace <<<
--
-- Anything between the inner markers survives re-running the installer. Everything
-- else in that block is regenerated, so do not edit it.
--
-- Overrides are a SHALLOW merge: a table you set REPLACES the default table, it does
-- not extend it. To add one pattern to `ignore_classes`, copy the whole list from
-- below and append to it -- otherwise you silently drop the defaults.

return {
    -- Where learned state lives.
    --
    -- Commented out because the default is computed: $HYPRPLACE_DB if set, else
    -- $XDG_STATE_HOME/hyprplace/db.lua, else ~/.local/state/hyprplace/db.lua. Set it
    -- only if you want the state somewhere else; there is no ~ expansion, so give an
    -- absolute path.
    --
    --   db_path = os.getenv("HOME") .. "/.local/state/hyprplace/db.lua",

    -- Where the plugin writes the configuration it resolved, so `hyprplace plan`,
    -- `diff` and `watch` report what the running plugin would actually do instead of
    -- what the defaults would. Generated, not user data: deleting it costs the tools
    -- their accuracy until the next config load, and nothing else.
    --
    -- Commented out because the default is computed, the same way db_path is:
    -- $HYPRPLACE_CONFIG_CACHE, else $XDG_STATE_HOME/hyprplace/config.lua, else
    -- ~/.local/state/hyprplace/config.lua.
    --
    --   cache_path = os.getenv("HOME") .. "/.local/state/hyprplace/config.lua",

    -- Where hyprplace writes its own log.
    --
    -- It cannot rely on print(): Lua output goes through Hyprland's logger, and
    -- `debug:disable_logs` defaults to true, so after `hyprctl reload` nothing reaches
    -- the Hyprland log at all -- errors included. This file is hyprplace's own, and is
    -- unaffected by that setting.
    --
    -- Errors and a one-line "ready" are always written. Everything else only when
    -- `debug` is on. Set to false to write no file at all. Truncated once it passes
    -- 1 MiB, so it cannot grow without bound.
    --
    -- Commented out because the default is computed: $HYPRPLACE_LOG, else
    -- $XDG_STATE_HOME/hyprplace/hyprplace.log, else
    -- ~/.local/state/hyprplace/hyprplace.log.
    --
    --   log_path = os.getenv("HOME") .. "/.local/state/hyprplace/hyprplace.log",

    -- Entries not seen within this many days are dropped when the DB loads. Stops
    -- state growing without bound as you install and remove software.
    ttl_days = 90,

    -- Lua patterns matched against the window class, lowercased. Matching windows are
    -- never remembered and never placed -- hyprplace ignores them completely.
    --
    -- Good candidates are things that are not really windows you arrange: launchers,
    -- portals, pickers, transient dialogs.
    ignore_classes = {
        "^hyprland%-run$",
    },

    -- Lua patterns matched against the window class, lowercased. For these classes,
    -- only windows with a distinguishing command line are remembered or placed.
    --
    -- The case this exists for is terminals: a bare `kitty` is a fresh shell whose
    -- state is gone the moment it closes, so there is nothing meaningful to restore,
    -- but `kitty btop` is a persistent thing that belongs somewhere. With `^kitty$`
    -- listed here, the first is ignored and the second is tracked.
    --
    -- Empty by default: which terminals you treat this way is your call.
    --
    --   require_cmdline = { "^kitty$", "^alacritty$", "^foot$" },
    require_cmdline = {},

    -- Flags are dropped from the command-line fingerprint by default, because that is
    -- where volatile junk lives. Steam's argv carries -steampid=, -buildid= and
    -- -startcount=, all of which change on every launch, so a fingerprint built from
    -- them can never match the same app twice.
    --
    -- Positional arguments are always kept, so `kitty btop` keeps `btop`. This table
    -- allowlists flags worth keeping anyway, per binary basename, as Lua patterns:
    --
    --   keep_flags = {
    --       kitty = { "^%-%-working%-directory=" },
    --   },
    keep_flags = {},

    -- Backstop on fingerprint length, in characters, for binaries launched with a
    -- great many positional arguments.
    max_cmdline_len = 120,

    -- Lua patterns matched against the window class, lowercased. For these classes
    -- placement waits instead of deciding at open, because the window's identity is
    -- not knowable that early -- it arrives in a later title event.
    --
    -- The case this exists for is Firefox. Every Firefox window shares one class and
    -- one process, so nothing tells them apart when they open. The hypr-tags extension
    -- gives each window a stable tag and publishes it through the title, but the tag
    -- appears a moment after the window does. Deciding at open would key on an identity
    -- that is not there yet.
    --
    -- Empty by default, and a no-op without the extension: with no tag to wait for,
    -- enabling this only delays the same decision by defer_timeout_ms.
    --
    --   defer_classes = { "^firefox$" },
    defer_classes = {},

    -- How long to wait for a deferred window's identity before giving up and deciding
    -- on what is known. On timeout the window is placed exactly as it would have been
    -- without deferral, so waiting too long costs a late placement, not a wrong one.
    --
    -- Worth tuning against your own session: the wait has to outlast the extension
    -- applying its title preface after Firefox restarts, which is slowest at cold boot.
    defer_timeout_ms = 3000,

    -- How often the waiting windows are checked, and so the granularity of
    -- defer_timeout_ms. The check only runs while something is actually waiting.
    defer_poll_ms = 250,

    -- Milliseconds after a monitor is added or removed during which moves are not
    -- learned from. A KVM swap or a hotplug reflows whole workspaces at once; that is
    -- the compositor rearranging things, not you deciding where a window belongs.
    monitor_settle_ms = 2000,

    -- Milliseconds after the config loads during which moves are not learned from.
    --
    -- At session start the compositor, your workspace plugin and everything in
    -- autostart move windows around before anything settles, and none of it is your
    -- intent. Without this freeze, a session where everything lands on workspace 1
    -- gets learned as "everything belongs on workspace 1" -- and then placed there
    -- next boot, which makes it true. This also covers `hyprctl reload`.
    --
    -- Raise it if your autostart apps are slow to appear.
    startup_settle_ms = 8000,

    -- Milliseconds to coalesce writes to the state file, so a burst of window moves
    -- costs one write rather than one each.
    save_debounce_ms = 1000,

    -- Log what hyprplace decides and why, to the Hyprland log. Worth turning on for a
    -- session or two when first setting up, or when a window is not going where you
    -- expect.
    debug = false,
}
