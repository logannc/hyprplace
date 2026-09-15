-- The running plugin's resolved configuration, written where the tools can read it.
--
-- Why this exists: hyprplace's config lives inside a block in the user's hyprland.lua,
-- which only the compositor ever reads. Without this the CLI falls back to defaults, so
-- `hyprplace plan` would report `move` for a Firefox window the running plugin actually
-- defers, and would call a window tracked that `require_cmdline` excludes. A tool that
-- disagrees with the plugin is worse than no tool.
--
-- The plugin dumps what it resolved rather than anything re-deriving it, so the tools
-- are correct by construction: this is the config that is running, not a second guess
-- at it. Generated state, not user data -- deleting it only costs the tools their
-- accuracy until the next config load.

local M = {}

M.VERSION = 1

local RESERVED = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true,
    ["goto"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true,
    ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true,
    ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true,
}

local function ident(k)
    return type(k) == "string" and not RESERVED[k] and k:match("^[%a_][%w_]*$") ~= nil
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        n = n + 1
    end
    return n == #t
end

local encode

--- Sorted so the file is stable: an unchanged config must serialize identically, or
--- every reload would look like a change.
local function encode_table(t, indent)
    if is_array(t) then
        local parts = {}
        for _, v in ipairs(t) do
            local e = encode(v, indent)
            if e then
                parts[#parts + 1] = e
            end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)

    local pad, inner = string.rep("  ", indent), string.rep("  ", indent + 1)
    local lines = {}
    for _, k in ipairs(keys) do
        local e = encode(t[k], indent + 1)
        if e then
            local name = ident(k) and k or ("[" .. string.format("%q", k) .. "]")
            lines[#lines + 1] = inner .. name .. " = " .. e .. ","
        end
    end
    if #lines == 0 then
        return "{}"
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. pad .. "}"
end

--- Encode one value, or nil for anything that has no meaningful representation.
--- Skipping rather than failing: a stray function in a user's config should cost that
--- one key in the tools' view, not the whole cache.
function encode(v, indent)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        return (v == math.floor(v) and math.type(v) ~= "float")
            and string.format("%d", v) or tostring(v)
    elseif t == "table" then
        return encode_table(v, indent)
    end
    return nil
end

---@param cfg table
---@return string
function M.serialize(cfg)
    return table.concat({
        "-- hyprplace: the configuration the running plugin resolved.",
        "-- Generated at config load; edits will be overwritten. Not user data -- your",
        "-- settings live in the hyprplace-config block in hyprland.lua.",
        "return {",
        string.format("  version = %d,", M.VERSION),
        "  config = " .. encode_table(cfg or {}, 1) .. ",",
        "}",
        "",
    }, "\n")
end

--- Parse a cache file. Returns nil on any problem: the tools then fall back to
--- defaults, which is exactly where they were before this existed.
---@param text string|nil
---@return table|nil
function M.deserialize(text)
    if not text or text == "" then
        return nil
    end
    local chunk = load(text, "hyprplace-config-cache", "t", {})
    if not chunk then
        return nil
    end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" or type(value.config) ~= "table" then
        return nil
    end
    if value.version ~= M.VERSION then
        return nil
    end
    return value.config
end

---@param path string
---@return table|nil
function M.load(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    return M.deserialize(text)
end

--- Write atomically, and only when the content actually differs.
---
--- The skip matters because this is called on every config load, including every
--- `hyprctl reload`, from inside the compositor process.
---@param path string
---@param cfg table
---@return boolean ok, string|nil err
function M.save(path, cfg)
    local text = M.serialize(cfg)
    local existing = io.open(path, "r")
    if existing then
        local current = existing:read("a")
        existing:close()
        if current == text then
            return true
        end
    end

    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        return false, err
    end
    f:write(text)
    f:close()
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, rerr
    end
    return true
end

return M
