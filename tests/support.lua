-- Test support: module loading and a fake `hl`.

local support = {}

--- Make `require("hyprplace.X")` resolve to <root>/X.lua regardless of the checkout's
--- directory name, so tests do not depend on the repo being named `hyprplace`.
---@param root string
function support.install_loader(root)
    table.insert(package.searchers, 2, function(name)
        local rel
        if name == "hyprplace" then
            rel = "init"
        else
            rel = name:match("^hyprplace%.(.+)$")
        end
        if not rel then
            return nil
        end
        local path = root .. "/" .. rel:gsub("%.", "/") .. ".lua"
        local chunk, err = loadfile(path)
        if chunk then
            return chunk, path
        end
        return "\n\tno file '" .. path .. "' (" .. tostring(err) .. ")"
    end)
end

--- A fake `hl` global capturing everything hyprplace does to the compositor.
---@param windows table[]
function support.fake_hl(windows)
    local h = {
        handlers   = {},   -- event name -> callback
        dispatched = {},   -- dispatch payloads, in order
        timers     = {},   -- {cb, opts}
        windows    = windows or {},
    }

    function h.on(event, cb)
        h.handlers[event] = cb
        return { remove = function() end, is_active = function() return true end }
    end

    function h.get_windows()
        return h.windows
    end

    function h.timer(cb, opts)
        h.timers[#h.timers + 1] = { cb = cb, opts = opts }
        return { set_enabled = function() end }
    end

    function h.dispatch(payload)
        h.dispatched[#h.dispatched + 1] = payload
        -- The real compositor echoes our move back synchronously, inside this call.
        -- Replaying that is the whole point: it is what the guard flag defends against.
        if payload and payload.kind == "move" and h.echo_move then
            local cb = h.handlers["window.move_to_workspace"]
            if cb then
                cb(payload.args.window, { id = payload.args.workspace })
            end
        end
    end

    h.dsp = {
        window = {
            move = function(args) return { kind = "move", args = args } end,
        },
    }

    --- Run every pending timer callback and clear the queue.
    function h.flush_timers()
        local pending = h.timers
        h.timers = {}
        for _, t in ipairs(pending) do
            t.cb()
        end
    end

    return h
end

--- Minimal window stub.
function support.window(t)
    return {
        address       = t.address or "0x1",
        class         = t.class,
        initial_class = t.initial_class or t.class,
        title         = t.title or "",
        pid           = t.pid or 1000,
        active        = t.active == nil and true or t.active,
        xwayland      = t.xwayland or false,
        workspace     = t.workspace and { id = t.workspace } or nil,
    }
end

return support
