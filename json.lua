-- Minimal JSON decoder. Decode only -- hyprplace reads `hyprctl -j` output and never
-- produces JSON. Pure Lua, no dependencies, so the CLI tools work anywhere the plugin
-- does.
--
-- Not a general-purpose implementation: it is deliberately small and rejects malformed
-- input rather than trying to recover.

local M = {}

--- JSON null. A distinct sentinel so a null inside an array does not create a hole.
M.null = setmetatable({}, { __tostring = function() return "null" end })

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local parse_value

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function fail(i, msg)
    error(string.format("json: %s at byte %d", msg, i), 0)
end

local function parse_string(s, i)
    i = i + 1 -- opening quote
    local buf = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then
            fail(i, "unterminated string")
        elseif c == '"' then
            return table.concat(buf), i + 1
        elseif c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "u" then
                local cp = tonumber(s:sub(i + 2, i + 5), 16)
                if not cp then fail(i, "bad \\u escape") end
                i = i + 6
                -- Surrogate pair: titles can contain emoji.
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
                    local lo = tonumber(s:sub(i + 2, i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                buf[#buf + 1] = utf8.char(cp)
            else
                local r = ESCAPES[e]
                if not r then fail(i, "bad escape") end
                buf[#buf + 1] = r
                i = i + 2
            end
        else
            local j = s:find('[\\"]', i) or (#s + 1)
            buf[#buf + 1] = s:sub(i, j - 1)
            i = j
        end
    end
end

local function parse_array(s, i)
    local out, n = {}, 0
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return out, i + 1 end
    while true do
        local v
        v, i = parse_value(s, i)
        n = n + 1
        out[n] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "]" then return out, i + 1 end
        if c ~= "," then fail(i, "expected ',' or ']'") end
        i = skip_ws(s, i + 1)
    end
end

local function parse_object(s, i)
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return out, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then fail(i, "expected object key") end
        local k, v
        k, i = parse_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ":" then fail(i, "expected ':'") end
        v, i = parse_value(s, skip_ws(s, i + 1))
        out[k] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "}" then return out, i + 1 end
        if c ~= "," then fail(i, "expected ',' or '}'") end
        i = skip_ws(s, i + 1)
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "" then fail(i, "unexpected end of input") end
    if c == '"' then return parse_string(s, i) end
    if c == "{" then return parse_object(s, i) end
    if c == "[" then return parse_array(s, i) end
    if s:sub(i, i + 3) == "true"  then return true,   i + 4 end
    if s:sub(i, i + 4) == "false" then return false,  i + 5 end
    if s:sub(i, i + 3) == "null"  then return M.null, i + 4 end
    local num = s:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and num ~= "" then
        local v = tonumber(num)
        if v then return v, i + #num end
    end
    fail(i, "unexpected character " .. string.format("%q", c))
end

--- Decode a JSON document.
---@param text string
---@return any|nil value, string|nil err
function M.decode(text)
    if type(text) ~= "string" then
        return nil, "json: expected a string"
    end
    local ok, value, i = pcall(parse_value, text, 1)
    if not ok then
        return nil, tostring(value)
    end
    i = skip_ws(text, i)
    if i <= #text then
        return nil, "json: trailing content at byte " .. i
    end
    return value
end

return M
