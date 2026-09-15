-- Install-time logic, kept separate from the filesystem actions so the delicate part --
-- editing the user's hyprland.lua -- is plain string handling that can be unit tested.
--
-- Not part of the plugin; never copied into the config tree.

local M = {}

--- The plugin's runtime modules. The single source of truth for what gets installed;
--- tests assert the Makefile agrees with this list.
M.MODULES = {
    "init.lua", "config.lua", "db.lua", "identity.lua",
    "placement.lua", "policy.lua", "learn.lua", "json.lua", "cli.lua",
}

-- The block is nested. Everything between BEGIN and END belongs to the installer and
-- is regenerated on every run; everything between CFG_BEGIN and CFG_END is the user's
-- and is spliced back untouched. The inner markers hug the table body only, so the
-- variable name and the setup() call -- which the config must not be able to break --
-- stay on the generated side.
M.BEGIN     = "-- >>> hyprplace >>>"
M.END       = "-- <<< hyprplace <<<"
M.CFG_BEGIN = "-- >>> hyprplace-config >>>"
M.CFG_END   = "-- <<< hyprplace-config <<<"

M.VAR  = "hyprplace_cfg"
M.CALL = 'require("hyprplace").setup(' .. M.VAR .. ")"

--- What goes between the config markers on a fresh install. Deliberately a stub and
--- not a copy of example_config.lua: inlining every default would pin all of them at
--- install time, so a later change to a default could never reach an existing user.
M.STUB = {
    "    -- Your settings go here. This section is preserved when the installer",
    "    -- re-runs; everything outside it is regenerated, so do not edit that.",
    "    -- See example_config.lua for every option and its default.",
}

--- The shape written by versions before the config section existed. Recognised so a
--- pristine old block can be upgraded in place rather than refused.
M.LEGACY_CALL = 'require("hyprplace").setup({})'

---@param text string
---@return string[]
local function split_lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    -- gmatch above yields one trailing empty for a text already ending in newline
    if #out > 0 and out[#out] == "" and text:sub(-1) == "\n" then
        table.remove(out)
    end
    return out
end
M.split_lines = split_lines

--- The exact block the installer manages, wrapped around `config` (the lines between
--- the inner markers). Defaults to the stub.
---@param config string[]|nil
---@return string
function M.block(config)
    local out = { M.BEGIN, "local " .. M.VAR .. " = {", M.CFG_BEGIN }
    for _, line in ipairs(config or M.STUB) do
        out[#out + 1] = line
    end
    out[#out + 1] = M.CFG_END
    out[#out + 1] = "}"
    out[#out + 1] = M.CALL
    out[#out + 1] = M.END
    return table.concat(out, "\n")
end

---@param text string
---@return boolean
function M.has_block(text)
    for _, line in ipairs(split_lines(text or "")) do
        if line == M.BEGIN then
            return true
        end
    end
    return false
end

--- Find the block and the user's config within it.
---
--- Returns `nil, nil` when there is no block and nothing is wrong -- the caller should
--- append a fresh one. Returns `nil, err` when the file is in a state we refuse to
--- touch: clobbering a hand-edited config is the failure this whole scheme exists to
--- prevent, so an ambiguous file is an error, never a guess.
---@param text string
---@return table|nil found, string|nil err
function M.locate(text)
    local lines = split_lines(text or "")
    local at = { begins = {}, ends = {}, cfg_begins = {}, cfg_ends = {} }
    for i, line in ipairs(lines) do
        if line == M.BEGIN then         at.begins[#at.begins + 1] = i
        elseif line == M.END then       at.ends[#at.ends + 1] = i
        elseif line == M.CFG_BEGIN then at.cfg_begins[#at.cfg_begins + 1] = i
        elseif line == M.CFG_END then   at.cfg_ends[#at.cfg_ends + 1] = i
        end
    end

    local nb, ne = #at.begins, #at.ends
    local cb, ce = #at.cfg_begins, #at.cfg_ends

    if nb > 1 or ne > 1 then
        return nil, string.format("found %d hyprplace blocks; there should be one",
            math.max(nb, ne))
    end
    if nb ~= ne then
        return nil, "the hyprplace block is missing its "
            .. (nb == 1 and "closing" or "opening") .. " marker"
    end
    if cb > 1 or ce > 1 then
        return nil, "found more than one hyprplace-config section"
    end
    if cb ~= ce then
        return nil, "the hyprplace-config section is missing its "
            .. (cb == 1 and "closing" or "opening") .. " marker"
    end

    if nb == 0 then
        if cb > 0 then
            return nil, "found hyprplace-config markers outside any hyprplace block"
        end
        return nil, nil
    end

    local first, last = at.begins[1], at.ends[1]
    if last < first then
        return nil, "the hyprplace block's markers are in the wrong order"
    end

    if cb == 0 then
        -- No config section. Upgrade it if it is an untouched block from an older
        -- version; refuse if someone has put something in there we would destroy.
        local body = {}
        for i = first + 1, last - 1 do
            body[#body + 1] = lines[i]
        end
        if #body == 1 and body[1] == M.LEGACY_CALL then
            return { lines = lines, first = first, last = last, config = nil, legacy = true }
        end
        return nil, "the hyprplace block has no hyprplace-config section, and its "
            .. "contents are not what an older version would have written -- it looks "
            .. "hand-edited, and rewriting it would lose that"
    end

    local cfirst, clast = at.cfg_begins[1], at.cfg_ends[1]
    if clast < cfirst then
        return nil, "the hyprplace-config markers are in the wrong order"
    end
    if cfirst < first or clast > last then
        return nil, "the hyprplace-config section is not inside the hyprplace block"
    end

    local config = {}
    for i = cfirst + 1, clast - 1 do
        config[#config + 1] = lines[i]
    end
    return { lines = lines, first = first, last = last, config = config }
end

--- The user's config lines, or nil if there is no block or no config section.
---@param text string
---@return string[]|nil
function M.config_of(text)
    local found = M.locate(text)
    return found and found.config or nil
end

--- Remove our block, including the blank line the installer put before it.
--- Anything outside the markers is left exactly as it was.
---@param text string
---@return string
function M.remove_block(text)
    local out, skipping = {}, false
    for _, line in ipairs(split_lines(text or "")) do
        if line == M.BEGIN then
            skipping = true
            if #out > 0 and out[#out]:match("^%s*$") then
                table.remove(out) -- the separator we added
            end
        elseif line == M.END then
            skipping = false
        elseif not skipping then
            out[#out + 1] = line
        end
    end
    if #out == 0 then
        return ""
    end
    return table.concat(out, "\n") .. "\n"
end

--- Ensure exactly one correct block is present, preserving the user's config section.
--- Replaces an existing block in place, so re-running converges instead of stacking
--- copies.
---@param text string
---@return string|nil result, boolean changed, string|nil err
function M.upsert_block(text)
    text = text or ""
    local found, err = M.locate(text)
    if err then
        return nil, false, err
    end

    if not found then
        local prefix = text
        if prefix ~= "" and prefix:sub(-1) ~= "\n" then
            prefix = prefix .. "\n"
        end
        return prefix .. "\n" .. M.block() .. "\n", true
    end

    local out = {}
    for i = 1, found.first - 1 do
        out[#out + 1] = found.lines[i]
    end
    for _, line in ipairs(split_lines(M.block(found.config))) do
        out[#out + 1] = line
    end
    for i = found.last + 1, #found.lines do
        out[#out + 1] = found.lines[i]
    end
    local result = table.concat(out, "\n") .. "\n"
    return result, result ~= text
end

--- Does `text` parse as Lua?
---
--- The safety net that matters: an unbalanced brace in the config section would
--- otherwise surface as a compositor that fails to load its config at next login.
--- Catching it here turns that into a refusal with a line number.
---
--- Parsed by the installer's Lua, which is not necessarily the compositor's; that is
--- fine for the class of mistake this exists to catch.
---@param text string
---@return boolean ok, string|nil err
function M.validate(text)
    local chunk, err = load(text, "@hyprland.lua")
    if chunk then
        return true
    end
    return false, err
end

--- Quote a path for a shell command.
---@param s string
---@return string
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return M
