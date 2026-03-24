--[[
@version 1.0
@noindex
@description Toolkit-specific helper functions for Reaper Toolkit.
  Generic utilities (Colors, HashURL, GetImageSize, UI helpers) are in Common/Scripts/.
--]]


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

    -- Open the Manage Repositories window so the user can install from it
    local manageAction = reaper.NamedCommandLookup("_REAPACK_MANAGE")
    if manageAction > 0 then reaper.Main_OnCommand(manageAction, 0) end
end

-- reapack.ini cache (re-read at most every 10 s)
local _reapack_ini_cache = nil
local _reapack_ini_time  = 0
local _url_results       = {}  -- per-URL boolean cache, cleared on ini refresh

-- Returns true if the repo URL is registered in ReaPack's reapack.ini
function IsRepoRegistered(url)
    local now = reaper.time_precise()
    if not _reapack_ini_cache or (now - _reapack_ini_time) > 10 then
        local path = reaper.GetResourcePath() .. "/reapack.ini"
        local f = io.open(path, "r")
        _reapack_ini_cache = f and f:read("*a") or ""
        if f then f:close() end
        _reapack_ini_time = now
        _url_results = {}
    end
    if _url_results[url] == nil then
        _url_results[url] = _reapack_ini_cache:find(url, 1, true) ~= nil
    end
    return _url_results[url]
end
