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

        -- Entries not seen within this many days are dropped when the DB loads.
        ttl_days = 90,

        -- Lua patterns matched against class:lower(). Matching windows are never
        -- remembered and never placed.
        ignore_classes = {
            "^hyprland%-run$",
        },

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

        -- Milliseconds after a monitor event during which moves are not learned from.
        -- A KVM swap or hotplug reflows whole workspaces; that is not user intent.
        monitor_settle_ms = 2000,

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
