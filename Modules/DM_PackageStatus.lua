---@diagnostic disable: undefined-global

local M = {}

local _Fetch

local _resource_path     = nil
local _file_exists_cache = {}
local _file_exists_time  = 0
local _cached_versions   = {}  -- key "index_name:script_name" -> version or false

-- Returns true if version string a is numerically greater than b
local function VersionGT(a, b)
    local function nums(v)
        local t = {}
        for n in (v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local na, nb = nums(a), nums(b)
    for i = 1, math.max(#na, #nb) do
        local x, y = na[i] or 0, nb[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

-- Returns the highest version name found within an XML block
local function HighestVersionIn(xml_block)
    local best
    for v in xml_block:gmatch('<version[^>]+name="([^"]*)"') do
        if not best or VersionGT(v, best) then best = v end
    end
    return best
end

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
    -- Drive package: path is computed directly, no index needed
    if type(pkg.drive_url) == "string" and pkg.reapack_url == "None" then
        if not pkg.main_script then return nil end
        if not _resource_path then
            _resource_path = reaper.GetResourcePath():gsub("/", "\\")
        end
        return _resource_path .. "\\Scripts\\Demute_toolkit\\pythonScripts\\" .. pkg.main_script
    end

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

-- Returns "none" or "installed" based purely on whether the main script file exists on disk.
function M.GetPackageStatus(pkg)
    local path = GetScriptPath(pkg)
    if not path then return "none" end
    return FileExists(path) and "installed" or "none"
end

-- Returns the online version string for the package's main script, or nil
function M.GetOnlineVersion(pkg)
    local idx = _Fetch.index_cache[pkg.reapack_url]
    if type(idx) ~= "table" or idx.error then return nil end
    local script_name = pkg.main_script or idx.name
    return idx.versions and idx.versions[script_name]
end

-- Returns the installed version for this package's script.
-- Checks (in order):
--   1. Our cache folder ({Res}\Scripts\DM_ReaperToolkit\cache\{index_name}.xml)
--      written by DM_DirectInstaller after each direct install.
--   2. ReaPack's local cache XML ({Res}\ReaPack\cache\{index_name}.xml) as fallback.
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

    local esc = script_name:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")

    -- 1. Our cache folder (populated by DM_DirectInstaller)
    local cash_path = _resource_path .. "\\Scripts\\DM_ReaperToolkit\\cache\\" .. idx.index_name .. ".xml"
    local cf = io.open(cash_path, "r")
    if cf then
        local cash_xml = cf:read("*a")
        cf:close()
        local cpos = cash_xml:find('reapack[^>]+name="' .. esc .. '"')
        local cver
        if cpos then
            local rp_end = cash_xml:find('</reapack>', cpos, true) or #cash_xml
            cver = HighestVersionIn(cash_xml:sub(cpos, rp_end))
        end
        cver = cver or HighestVersionIn(cash_xml)
        if cver then
            _cached_versions[key] = cver
            return cver
        end
    end

    -- 2. ReaPack's local cache (fallback for ReaPack-managed installs)
    local cache_path = _resource_path .. "\\ReaPack\\cache\\" .. idx.index_name .. ".xml"
    local f = io.open(cache_path, "r")
    if not f then
        _cached_versions[key] = false
        return nil
    end
    local xml = f:read("*a")
    f:close()
    local pos = xml:find('reapack[^>]+name="' .. esc .. '"')
    local ver
    if pos then
        local rp_end = xml:find('</reapack>', pos, true) or #xml
        ver = HighestVersionIn(xml:sub(pos, rp_end))
    end
    ver = ver or HighestVersionIn(xml)
    _cached_versions[key] = ver or false
    return ver
end

-- True when the online version is newer than the locally cached version
function M.IsUpdateAvailable(pkg)
    local online = M.GetOnlineVersion(pkg)
    if not online then return false end
    local cached = M.GetCachedVersion(pkg)
    if not cached then return false end
    return VersionGT(online, cached)
end

function M.InvalidateFileCache()
    _file_exists_cache = {}
end

function M.InvalidateVersionCache()
    _cached_versions = {}
end

return M
