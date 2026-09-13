-- hyprplace -- remember which workspace each app lives on, and put it back there.
--
--   require("hyprplace").setup({ ... })
--
-- Read docs/DESIGN.required.md before changing behaviour here. Several things that look
-- like defensive paranoia below are load-bearing and were measured, not guessed:
--
--   * Our own move dispatch echoes back as window.move_to_workspace, synchronously
--     inside hl.dispatch. The guard flag is necessary, and because the echo is
--     synchronous a plain boolean is sufficient.
--   * hl.dsp.window.move follows focus unless follow=false is passed. AC-2 requires it.
--   * hyprctl reload destroys the Lua VM, so all state here is rebuilt from disk on
--     load and nothing may be cached only in _G across a reload.
--   * This runs INSIDE the compositor process. Every handler is pcall-wrapped; an error
--     in hyprplace must never take the compositor down (AC-6).

local Config    = require("hyprplace.config")
local DB        = require("hyprplace.db")
local Identity  = require("hyprplace.identity")
local Placement = require("hyprplace.placement")

local M = {
    _cfg   = nil,
    _state = nil,
    -- True while we are dispatching our own move, so the echo is not learned from.
    _guard = false,
    -- True shortly after a monitor event: hotplug reflows whole workspaces and that is
    -- not user intent.
    _settling = false,
    _dirty = false,
    _save_timer = nil,
    _subs = {},
}

-- ---------------------------------------------------------------------------
-- logging

local function log(fmt, ...)
    if M._cfg and M._cfg.debug then
        print("[hyprplace] " .. string.format(fmt, ...))
    end
end

--- Wrap a handler so a failure is logged and contained (AC-6).
local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            print(string.format("[hyprplace] error in %s: %s", name, tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- policy

--- Should hyprplace have anything to do with this window at all?
---@param w table
---@param windows table[]
---@return boolean
local function tracked(w, windows)
    if not w then
        return false
    end
    local class = w.class
    if not class or class == "" then
        class = w.initial_class
    end
    if not class or class == "" then
        return false
    end
    if Config.matches(class, M._cfg.ignore_classes) then
        return false
    end
    -- Classes whose windows only matter when they carry a distinguishing cmdline:
    -- a bare terminal is a fresh shell, `kitty btop` is a persistent thing.
    if Config.matches(class, M._cfg.require_cmdline)
        and not Identity.has_cmdline_identity(w, windows) then
        return false
    end
    return true
end

local function key_fn(windows)
    return function(w)
        local key = Identity.key_for(w, windows)
        return key
    end
end

-- ---------------------------------------------------------------------------
-- persistence

local function schedule_save()
    M._dirty = true
    if M._save_timer then
        return
    end
    M._save_timer = hl.timer(guarded("save", function()
        M._save_timer = nil
        if not M._dirty then
            return
        end
        M._dirty = false
        local ok, err = DB.save(M._cfg.db_path, M._state)
        if not ok then
            print("[hyprplace] failed to save db: " .. tostring(err))
        else
            log("saved %s", M._cfg.db_path)
        end
    end), { timeout = M._cfg.save_debounce_ms, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- placement

local function place(w)
    if not M._cfg then
        return
    end
    local windows = hl.get_windows()
    if not tracked(w, windows) then
        return
    end

    local key = Identity.key_for(w, windows)
    local entry = DB.lookup(M._state, key)
    if not entry then
        log("no record for %q", tostring(key))
        return
    end

    local occupied = Placement.occupied_workspaces(windows, key, w.address, key_fn(windows))
    local target = Placement.choose(entry, occupied)
    if not target then
        log("every remembered workspace for %q is taken", tostring(key))
        return
    end

    -- Acting on an entry is evidence it is still in use: refresh recency so an app you
    -- keep reopening never expires, even if you never explicitly move it.
    DB.touch(M._state, key, os.time())
    schedule_save()

    if w.workspace and w.workspace.id == target then
        return
    end

    -- Note: the target workspace need not exist yet. At session start most workspaces
    -- do not, and Hyprland creates one on demand -- which is exactly what we want when
    -- restoring after a reboot.
    log("placing %q -> workspace %d", tostring(key), target)
    M._guard = true
    local ok, err = pcall(function()
        hl.dispatch(hl.dsp.window.move({ window = w, workspace = target, follow = false }))
    end)
    M._guard = false
    if not ok then
        print("[hyprplace] move failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- learning

--- Record `w` as belonging to `ws_id`.
local function remember(w, ws_id, why)
    if not ws_id then
        return
    end
    local windows = hl.get_windows()
    if not tracked(w, windows) then
        return
    end
    local key = Identity.key_for(w, windows)
    if not key then
        return
    end
    DB.record(M._state, key, ws_id, os.time(), M._cfg.max_slots)
    log("learned (%s) %q -> %d", why, key, ws_id)
    schedule_save()
end

local function on_move(w, ws)
    if M._guard then
        return -- our own placement echoing back
    end
    if M._settling then
        return -- monitor hotplug reflow, not user intent
    end
    -- A deliberate move is a single focused window being moved on its own. Mass moves
    -- (hyprsplit swap_monitors) do not carry focus for every window they touch.
    if w and w.active == false then
        return
    end
    local id = ws and (type(ws) == "table" and ws.id or ws) or (w.workspace and w.workspace.id)
    remember(w, id, "move")
end

local function on_close(w)
    -- Essential for AC-1: a window the user never explicitly moved is only ever
    -- recorded here.
    if w and w.workspace then
        remember(w, w.workspace.id, "close")
    end
end

local function begin_settle()
    M._settling = true
    hl.timer(guarded("settle", function()
        M._settling = false
    end), { timeout = M._cfg.monitor_settle_ms, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- setup

---@param user_config table|nil
---@return table
function M.setup(user_config)
    M._cfg = Config.build(user_config)
    DB.ensure_dir(M._cfg.db_path)

    local state = DB.load(M._cfg.db_path)
    local dropped
    state, dropped = DB.prune(state, M._cfg.ttl_days, os.time())
    M._state = state
    if dropped > 0 then
        log("pruned %d expired entries", dropped)
        schedule_save()
    end

    M._subs = {
        hl.on("window.open_early",       guarded("open_early", place)),
        hl.on("window.move_to_workspace", guarded("move", on_move)),
        hl.on("window.close",            guarded("close", on_close)),
        hl.on("monitor.added",           guarded("monitor.added", begin_settle)),
        hl.on("monitor.removed",         guarded("monitor.removed", begin_settle)),
    }

    log("ready (db=%s, %d entries)", M._cfg.db_path, (function()
        local n = 0
        for _ in pairs(M._state.entries) do n = n + 1 end
        return n
    end)())

    return M
end

--- Current state, for inspection and tests.
function M.state()
    return M._state
end

function M.config()
    return M._cfg
end

return M
