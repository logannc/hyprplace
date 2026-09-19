-- hyprplace configuration: defaults, and merging of user overrides.
-- Pure data + a merge function; no `hl` dependency, so it is unit-testable.

local M = {}

local function state_home()
    return os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
end

---@return table
function M.defaults()
    return {
        -- Where the learned state lives. HYPRPLACE_DB overrides, for tests.
        db_path = os.getenv("HYPRPLACE_DB") or (state_home() .. "/hyprplace/db.lua"),

        -- Where the plugin writes the configuration it resolved, so the CLI tools can
        -- report what the running plugin would actually do rather than what the
        -- defaults would. Generated, not user data. HYPRPLACE_CONFIG_CACHE overrides.
        cache_path = os.getenv("HYPRPLACE_CONFIG_CACHE")
            or (state_home() .. "/hyprplace/config.lua"),

        -- Where hyprplace writes its own log. It cannot rely on print(): Lua output
        -- goes through Hyprland's logger, and `debug:disable_logs` defaults to true,
        -- so on `hyprctl reload` every message -- including errors -- is swallowed.
        --
        -- Errors are always written here. Everything else only when `debug` is on.
        -- Set to false to disable the file entirely.
        log_path = os.getenv("HYPRPLACE_LOG")
            or (state_home() .. "/hyprplace/hyprplace.log"),

        -- Entries not seen within this many days are dropped when the DB loads.
        ttl_days = 90,

        -- Lua patterns matched against class:lower(). Matching windows are never
        -- remembered and never placed.
        ignore_classes = {
            "^hyprland%-run$",
        },

        -- Skip floating windows entirely: never remembered, never placed.
        --
        -- A floating window is usually transient -- a dialog, a picker, an unlock
        -- prompt -- and those belong wherever your focus is, which is where they open
        -- on their own. Remembering one also poisons its app's entry: a password
        -- manager's unlock dialog shares a class with its main window, so learning both
        -- records the app as living on two workspaces and sends the next dialog to one.
        --
        -- Set false if you float windows you genuinely want placed.
        ignore_floating = true,

        -- Lua patterns matched against each of a window's Hyprland tags, lowercased.
        -- A window carrying a matching tag is never remembered and never placed.
        --
        -- More useful than ignore_classes where an app's transient dialogs share a
        -- class with its main window -- a password manager's unlock prompt carries the
        -- same class as its main window, so excluding by class excludes both. If your
        -- config already tags such apps, say with
        --
        --   hl.window_rule({ match = { class = "^myvault$" }, tag = "+floating-window" })
        --
        -- then `ignore_tags = { "^floating%-window$" }` excludes every app you have
        -- classified that way, and keeps doing so as you tag more.
        --
        -- A trailing `*` -- which Hyprland adds to mark a rule-applied tag -- is
        -- stripped before matching, so patterns match what you wrote in your rules.
        ignore_tags = {},

        -- Lua patterns matched against class:lower(). For these classes, only windows
        -- with a distinguishing cmdline are remembered or placed -- a bare `kitty` is a
        -- fresh shell whose state is gone, but `kitty btop` is a persistent thing.
        --
        -- Empty by default: see docs/FUTURE.md, the defaults are not chosen yet.
        -- Example:
        --   require_cmdline = { "^kitty$", "^alacritty$", "^foot$" },
        require_cmdline = {},

        -- Flags are dropped from the cmdline fingerprint by default, because that is
        -- where volatile junk lives: Steam's argv carries -steampid=, -buildid= and
        -- -startcount=, all of which change on every launch, so a key built from them
        -- can never match again.
        --
        -- Positional arguments are always kept -- `kitty btop` keeps `btop`. This table
        -- allowlists flags worth keeping, per binary basename, as Lua patterns:
        --
        --   keep_flags = { kitty = { "^%-%-working%-directory=" } },
        --
        -- Empty by default; teaching hyprplace about specific binaries is future work.
        keep_flags = {},

        -- Backstop on fingerprint length, in case some binary has a great many
        -- positional arguments.
        max_cmdline_len = 120,

        -- Lua patterns matched against class:lower(). For these classes, placement
        -- waits: the window's identity is not knowable at window.open_early, because
        -- it arrives in a later title event.
        --
        -- The case this exists for is Firefox. Every Firefox window shares one class
        -- and one pid, so nothing tells them apart at open; the hypr-tags extension
        -- publishes a per-window tag through the title, and that tag shows up some
        -- time after the window maps. See docs/FIREFOX-TAGS.md.
        --
        -- Empty by default, which makes deferral a no-op. Without the extension there
        -- is no tag to wait for, so enabling this only delays the same decision.
        --
        --   defer_classes = { "^firefox$" },
        defer_classes = {},

        -- How long to wait for a deferred window's identity before giving up and
        -- deciding on what is known. On timeout the window is placed exactly as it
        -- would have been without deferral, so the cost of waiting too long is a late
        -- placement, not a wrong one.
        --
        -- Tune against a real session: the wait must outlast the extension applying
        -- its title preface after a Firefox restart, which is slowest at cold boot.
        defer_timeout_ms = 3000,

        -- How often the pending set is swept for expired deadlines. Also the
        -- granularity of defer_timeout_ms. The sweep only runs while something is
        -- actually pending.
        defer_poll_ms = 250,

        -- Milliseconds after the config loads during which moves are not learned from.
        -- At session start the compositor, hyprsplit and autostart all move windows
        -- around before anything settles; none of it is user intent. This also covers
        -- `hyprctl reload`, which re-runs the config and triggers hyprsplit's workspace
        -- reflow. Tune if apps on your machine take longer than this to settle.
        startup_settle_ms = 8000,

        -- Milliseconds to coalesce DB writes.
        save_debounce_ms = 1000,

        debug = false,
    }
end

--- Shallow merge of user overrides onto defaults.
---@param user table|nil
---@return table
function M.build(user)
    local cfg = M.defaults()
    for k, v in pairs(user or {}) do
        cfg[k] = v
    end
    return cfg
end

--- Does `class` match any pattern in `patterns`?
---@param class string|nil
---@param patterns string[]
---@return boolean
function M.matches(class, patterns)
    if not class or class == "" then
        return false
    end
    local lower = class:lower()
    for _, pat in ipairs(patterns or {}) do
        if lower:match(pat) then
            return true
        end
    end
    return false
end

return M
