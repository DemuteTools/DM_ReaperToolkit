---@diagnostic disable: undefined-global

-- DM_StringUtils.lua
-- Common string and path utility functions for all Demute tools.
-- Usage: dofile(COMMON .. "DM_StringUtils.lua")

-- Split a string by a delimiter and return an array of parts.
-- Example: split("a,b,c", ",")  →  {"a", "b", "c"}
function split(str, delimiter)
    local result = {}
    for match in (str .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result
end

-- Normalize path separators to forward slashes.
-- Removes duplicate slashes and trailing slash.
-- Prevents "invalid path" errors caused by backslash escaping in shell commands.
function NormalizePath(path)
    if not path then return "" end
    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("//+", "/")
    normalized = normalized:gsub("/$", "")
    return normalized
end

-- djb2 hash of a string → 8-char hex fragment safe for use in temp filenames.
function HashURL(url)
    local h = 5381
    for i = 1, #url do h = ((h * 33) + url:byte(i)) % 0x100000000 end
    return string.format("%08x", h)
end