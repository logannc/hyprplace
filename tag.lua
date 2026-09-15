-- Reading a window tag out of a title.
--
-- The tag is published by the hypr-tags Firefox extension, which prepends `[<tag>] ` to
-- every normal window's title. The title is the only channel an extension can write and
-- a compositor can read; see docs/FIREFOX-TAGS.md for why, and for the contract this
-- implements. There is no channel the other way -- hyprplace reads tags and never sets
-- them.
--
-- Pure string handling, no `hl` dependency, so the plugin and the CLI tools share it.

local M = {}

-- The contract's alphabet: [A-Za-z0-9_-]{1,32}, bracketed, anchored at the start of the
-- title, followed by a space. Lua patterns have no counted repetition, so the length
-- bound is checked after matching.
M.PATTERN = "^%[([A-Za-z0-9_%-]+)%] "
M.MAX_LEN = 32

--- The tag in `title`, or nil if there is not one.
---
--- Deliberately strict. A title that merely happens to start with a bracketed word --
--- and plenty do -- must not be mistaken for a tagged window, because that would invent
--- an identity for a window that has none and place it somewhere arbitrary.
---@param title string|nil
---@return string|nil
function M.of(title)
    if type(title) ~= "string" then
        return nil
    end
    local tag = title:match(M.PATTERN)
    if not tag or #tag > M.MAX_LEN then
        return nil
    end
    return tag
end

--- `title` with the tag preface removed, for display.
---@param title string|nil
---@return string
function M.strip(title)
    if type(title) ~= "string" then
        return ""
    end
    if not M.of(title) then
        return title
    end
    return (title:gsub(M.PATTERN, "", 1))
end

return M
