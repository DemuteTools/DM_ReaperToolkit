---@diagnostic disable: undefined-global, unused-local, lowercase-global

-- Common UI colors in 0xRRGGBBAA format (last byte = opacity, FF = opaque)
Colors = {
    -- Neutrals
    white        = 0xFFFFFFFF,
    black        = 0x000000FF,
    transparent  = 0x00000000,

    -- Greys
    grey_dark    = 0x1A1A1AFF,
    grey         = 0x555555FF,
    grey_mid     = 0x888888FF,
    grey_light   = 0xCCCCCCFF,

    -- Accent
    red          = 0xFF3333FF,
    orange       = 0xFF8800FF,
    amber        = 0xFFAA00FF,
    yellow       = 0xFFFF00FF,
    green        = 0x44FF44FF,
    green_dark   = 0x226622FF,
    teal         = 0x00CCAAFF,
    blue         = 0x4488CCFF,
    blue_dark    = 0x1A1A2EFF,
    purple       = 0x8844CCFF,
    pink         = 0xFF44AAFF,

    -- Semantic
    success      = 0x55CC55FF,
    warning      = 0xFF8800FF,
    error        = 0xFF3333FF,
    info         = 0x4488CCFF,

    -- Semi-transparent whites (overlays, borders, splitters)
    white_dim    = 0xFFFFFF0D,   -- ~5%
    white_faint  = 0xFFFFFF1A,   -- ~10%
    white_ghost  = 0xFFFFFF33,   -- ~20%
    white_mid    = 0xFFFFFF88,   -- ~53%
    white_soft   = 0xFFFFFF99,   -- ~60%
    white_bright = 0xFFFFFFCC,   -- ~80%

    -- Semi-transparent blacks (dark bars, overlays)
    black_glass  = 0x00000066,   -- ~40%
    black_smoke  = 0x000000BB,   -- ~73%

    -- Near-black image tints (for darkening image overlays)
    dark_tint     = 0x22222244,
    dark_tint_sub = 0x11111133,

    -- Widget interaction colours
    grey_hover   = 0x777777FF,
    grey_press   = 0x444444FF,
    red_hover    = 0xCC3333FF,
    red_press    = 0x993333FF,
    red_light    = 0xFF4444FF,   -- softer error / warning text

    -- Teal button family (matches Ambiance Creator's primary button colour)
    teal_btn       = 0x15856DFF,   -- base
    teal_btn_hover = 0x2E9E86FF,   -- base + 25 per channel
    teal_btn_press = 0x006C54FF,   -- base − 25 per channel
}

-- reapack.ini remote format: remoteN=Name|URL|enabled|autoinstall
--   enabled:     1 = on
--   autoinstall: 1 = off, 2 = auto-install new packages
function ImportReapackRepo(url, display_name)
    local importAction = reaper.NamedCommandLookup("_REAPACK_IMPORT")
    if importAction == 0 then
        reaper.ShowMessageBox("Could not find ReaPack. Is it installed?", "Error", 0)
        return
    end

    -- _REAPACK_IMPORT is the only way to update ReaPack's live in-memory state.
    -- We pre-fill the clipboard so the user only has to paste and confirm.
    reaper.CF_SetClipboard(url)
    reaper.ShowMessageBox(
        "The Repository URL has been copied to your clipboard.\n\n"
        .. "Please paste it into the window that opens next.",
        "Step 1: Add Repo", 0)
    reaper.Main_OnCommand(importAction, 0)

    -- _REAPACK_IMPORT adds the repo with autoinstall=1 (off). Patch the ini entry
    -- to autoinstall=2 so that the sync below (and all future syncs) auto-install.
    local ini_path = reaper.GetResourcePath() .. "/reapack.ini"
    local f = io.open(ini_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        -- Find the line that was just added: ends with |URL|enabled|1
        local escaped = url:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
        local updated = content:gsub("(" .. escaped .. "|%d+)|1\n", "%1|2\n")
        if updated ~= content then
            local out = io.open(ini_path, "w")
            if out then out:write(updated); out:close() end
            InvalidateRepoCache()
        end
    end

    local syncAction = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if syncAction > 0 then reaper.Main_OnCommand(syncAction, 0) end
end

-- djb2 hash of a URL string → safe temp filename fragment
function HashURL(url)
    local h = 5381
    for i = 1, #url do h = ((h * 33) + url:byte(i)) % 0x100000000 end
    return string.format("%08x", h)
end

-- Read pixel dimensions from a PNG file header (first 24 bytes)
function GetPNGSize(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local hdr = f:read(24)
    f:close()
    if not hdr or #hdr < 24 then return nil, nil end
    if hdr:byte(1) ~= 0x89 or hdr:sub(2, 4) ~= "PNG" then return nil, nil end
    local w = hdr:byte(17)*16777216 + hdr:byte(18)*65536 + hdr:byte(19)*256 + hdr:byte(20)
    local h = hdr:byte(21)*16777216 + hdr:byte(22)*65536 + hdr:byte(23)*256 + hdr:byte(24)
    return w, h
end

-- Read pixel dimensions from a JPEG/PNG file (tries PNG header first, then
-- scans JPEG SOF markers). Reads at most 64 KB so large files stay fast.
function GetImageSize(path)
    local w, h = GetPNGSize(path)
    if w then return w, h end
    -- Try JPEG: scan for SOF marker (FF C0/C1/C2... contain h/w)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local data = f:read(65536)
    f:close()
    if not data or #data < 4 then return nil, nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, nil end
    local i = 3
    while i <= #data - 1 do
        if data:byte(i) ~= 0xFF then break end
        local m = data:byte(i + 1)
        if m == 0xDA then break end  -- start of scan, no more headers
        if (m >= 0xC0 and m <= 0xC3) or (m >= 0xC5 and m <= 0xC7) or
           (m >= 0xC9 and m <= 0xCB) or (m >= 0xCD and m <= 0xCF) then
            if i + 8 <= #data then
                return data:byte(i+7)*256 + data:byte(i+8),  -- width
                       data:byte(i+5)*256 + data:byte(i+6)   -- height
            end
            break
        end
        if i + 3 > #data then break end
        i = i + 2 + (data:byte(i+2)*256 + data:byte(i+3))
    end
    return nil, nil
end

-- reapack.ini cache (re-read at most every 10 s)
local _reapack_ini_cache = nil
local _reapack_ini_time  = 0
local _url_results       = {}  -- per-URL boolean cache, cleared on ini refresh

-- Returns true if the repo URL is registered in ReaPack's reapack.ini
function IsRepoRegistered(url)
    local now = reaper.time_precise()
    if not _reapack_ini_cache or (now - _reapack_ini_time) > 10 then
        local t0 = reaper.time_precise()
        local path = reaper.GetResourcePath() .. "/reapack.ini"
        local f = io.open(path, "r")
        _reapack_ini_cache = f and f:read("*a") or ""
        if f then f:close() end
        _reapack_ini_time = now
        _url_results = {}  -- clear per-URL cache when file is refreshed
        reaper.ShowConsoleMsg(string.format("[PROFILE] IsRepoRegistered: read reapack.ini (%d bytes): %.2f ms\n",
            #_reapack_ini_cache, (reaper.time_precise() - t0) * 1000))
    end
    if _url_results[url] == nil then
        local t0 = reaper.time_precise()
        _url_results[url] = _reapack_ini_cache:find(url, 1, true) ~= nil
        local dt = (reaper.time_precise() - t0) * 1000
        if dt > 0.1 then
            reaper.ShowConsoleMsg(string.format("[PROFILE] IsRepoRegistered: find(): %.2f ms\n", dt))
        end
    end
    return _url_results[url]
end

-- Force the next IsRepoRegistered call to re-read the file
function InvalidateRepoCache()
    _reapack_ini_cache = nil
end
