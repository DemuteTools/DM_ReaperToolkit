---@diagnostic disable: undefined-global

local M = {}

local _Fetch

local _resource_path     = nil
local _file_exists_cache = {}
local _file_exists_time  = 0
local _cached_versions   = {}  -- key "index_name:script_name" -> version or false

function M.Init(Fetch)
    _Fetch = Fetch
end

local function FileExists(path)
    local now = reaper.time_precise()
    if (now - _file_exists_time) > 10 then
        _file_exists_cache = {}
        _file_exists_time  = now
    end
    if _file_exists_cache[path] == nil then
        local f = io.open(path, "r")
        _file_exists_cache[path] = f ~= nil
        if f then f:close() end
    end
    return _file_exists_cache[path]
end

local function GetScriptPath(pkg)
    local idx = _Fetch.index_cache[pkg.reapack_url]
    if type(idx) ~= "table" or idx.error then return nil end
    if not _resource_path then
        _resource_path = reaper.GetResourcePath():gsub("/", "\\")
    end
    -- ReaPack installs to: Scripts\{index_name}\{category}\{script_name}
    local script_name = pkg.main_script or idx.name
    local category    = (idx.scripts and idx.scripts[script_name]) or idx.category
    return _resource_path .. "\\Scripts\\"
        .. idx.index_name:gsub("/", "\\") .. "\\"
        .. category:gsub("/", "\\")       .. "\\"
        .. script_name
end

M.GetScriptPath = GetScriptPath

-- Returns "none", "imported", or "installed"
function M.GetPackageStatus(pkg)
    if not IsRepoRegistered(pkg.reapack_url) then return "none" end
    local path = GetScriptPath(pkg)
    if not path then return "imported" end
    return FileExists(path) and "installed" or "imported"
end

-- Returns the online version string for the package's main script, or nil
function M.GetOnlineVersion(pkg)
    local idx = _Fetch.index_cache[pkg.reapack_url]
    if type(idx) ~= "table" or idx.error then return nil end
    local script_name = pkg.main_script or idx.name
    return idx.versions and idx.versions[script_name]
end

-- Reads the first <version name="..."> for this package's script from
-- ReaPack's local cache XML ({ResourcePath}\ReaPack\cache\{index_name}.xml).
-- This reflects what version ReaPack has synced locally.
function M.GetCachedVersion(pkg)
    local idx = _Fetch.index_cache[pkg.reapack_url]
    if type(idx) ~= "table" or idx.error then return nil end
    local script_name = pkg.main_script or idx.name
    local key = idx.index_name .. ":" .. script_name
    if _cached_versions[key] ~= nil then
        return _cached_versions[key] or nil
    end
    if not _resource_path then
        _resource_path = reaper.GetResourcePath():gsub("/", "\\")
    end
    local cache_path = _resource_path .. "\\ReaPack\\cache\\" .. idx.index_name .. ".xml"
    local f = io.open(cache_path, "r")
    if not f then
        _cached_versions[key] = false
        return nil
    end
    local xml = f:read("*a")
    f:close()
    -- Find the reapack block for this script, then grab its first version tag
    local esc = script_name:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
    local pos = xml:find('reapack[^>]+name="' .. esc .. '"')
    local ver
    if pos then
        ver = xml:sub(pos):match('<version[^>]+name="([^"]*)"')
    end
    -- Fallback: first version anywhere in the file
    ver = ver or xml:match('<version[^>]+name="([^"]*)"')
    _cached_versions[key] = ver or false
    return ver
end

-- True when the online version is newer than ReaPack's local cached version
function M.IsUpdateAvailable(pkg)
    local online = M.GetOnlineVersion(pkg)
    if not online then return false end
    local cached = M.GetCachedVersion(pkg)
    if not cached then return false end
    -- Compare dot-separated numeric segments
    local function nums(v)
        local t = {}
        for n in (v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local a, b = nums(cached), nums(online)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x < y then return true end
        if x > y then return false end
    end
    return false
end

function M.InvalidateFileCache()
    _file_exists_cache = {}
end

function M.InvalidateVersionCache()
    _cached_versions = {}
end

return M
