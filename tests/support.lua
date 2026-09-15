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
        -- remove() really unsubscribes: the deferral machinery holds the window.title
        -- subscription only while something is pending, and that lifecycle is worth
        -- being able to assert on.
        return {
            remove    = function() h.handlers[event] = nil end,
            is_active = function() return h.handlers[event] ~= nil end,
        }
    end

    function h.get_windows()
        return h.windows
    end

    function h.timer(cb, opts)
        local t = { cb = cb, opts = opts or {}, enabled = true }
        function t:set_enabled(v) self.enabled = v ~= false end
        function t:is_enabled() return self.enabled end
        function t:set_timeout(_) end
        h.timers[#h.timers + 1] = t
        return t
    end

    function h.dispatch(payload)
        h.dispatched[#h.dispatched + 1] = payload
        -- A move really moves the window, so a later decision sees the new layout.
        -- Without this, placing several windows of one app in a row would compute
        -- every slot against the pre-move world and send them all to the same place.
        if payload and payload.kind == "move" and payload.args.window then
            payload.args.window.workspace = { id = payload.args.workspace }
        end
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

    --- Run every enabled timer callback once.
    ---
    --- Oneshots are consumed; repeating timers stay, so a sweep can be ticked by
    --- calling this again. Disabled timers are kept but not run -- that is how the
    --- deferral sweep goes quiet without being destroyed. The queue is swapped before
    --- the callbacks run, so timers a callback creates land in the next round rather
    --- than firing immediately.
    function h.flush_timers()
        local pending = h.timers
        local keep = {}
        for _, t in ipairs(pending) do
            if (t.opts.type or "oneshot") == "repeat" then
                keep[#keep + 1] = t
            end
        end
        h.timers = keep
        for _, t in ipairs(pending) do
            if t.enabled then
                t.cb()
            end
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
