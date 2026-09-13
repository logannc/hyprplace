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

M.BEGIN = "-- >>> hyprplace >>>"
M.END   = "-- <<< hyprplace <<<"
M.CALL  = 'require("hyprplace").setup({})'

--- The exact block the installer manages. Everything between the markers is ours.
---@return string
function M.block()
    return M.BEGIN .. "\n" .. M.CALL .. "\n" .. M.END
end

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

--- Ensure exactly one correct block is present. Replaces an existing one in place, so
--- re-running converges instead of stacking copies.
---@param text string
---@return string result, boolean changed
function M.upsert_block(text)
    text = text or ""
    if M.has_block(text) then
        local rebuilt, skipping, replaced = {}, false, false
        for _, line in ipairs(split_lines(text)) do
            if line == M.BEGIN then
                skipping = true
                if not replaced then
                    for _, b in ipairs(split_lines(M.block())) do
                        rebuilt[#rebuilt + 1] = b
                    end
                    replaced = true
                end
            elseif line == M.END then
                skipping = false
            elseif not skipping then
                rebuilt[#rebuilt + 1] = line
            end
        end
        local result = table.concat(rebuilt, "\n") .. "\n"
        return result, result ~= text
    end

    local prefix = text
    if prefix ~= "" and prefix:sub(-1) ~= "\n" then
        prefix = prefix .. "\n"
    end
    return prefix .. "\n" .. M.block() .. "\n", true
end

--- Quote a path for a shell command.
---@param s string
---@return string
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return M
