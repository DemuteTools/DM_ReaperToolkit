---@diagnostic disable: undefined-global, need-check-nil, undefined-field

-- DM_DirectInstaller.lua
-- Installs packages directly from their index.xml without requiring ReaPack.
-- Downloads all source files and places them in the correct REAPER resource
-- folders, then registers REAPER actions for all scripts with main="true".

local M = {}

-- ── Public state (read by the UI) ─────────────────────────────────────────────
M.state      = "idle"   -- "idle" | "fetching_index" | "downloading" | "done" | "error"
M.message    = ""       -- human-readable status string (current operation)
M.log        = {}       -- list of strings, one entry per downloaded / registered file
M.results    = {}       -- keyed by pkg.reapack_url: { state="done"|"error", message }
M.active_url = nil      -- reapack_url of the package currently being installed, or nil

-- ── Internals ─────────────────────────────────────────────────────────────────
local _tmp = (os.getenv("TEMP") or reaper.GetResourcePath()):gsub("/", "\\")
local _res = reaper.GetResourcePath():gsub("/", "\\")

local _vbs        = _tmp .. "\\dm_inst_launcher.vbs"
local TMP_IDX_TXT  = _tmp .. "\\dm_inst_index.txt"
local TMP_IDX_DONE = _tmp .. "\\dm_inst_index.done"
local TMP_IDX_PS1  = _tmp .. "\\dm_inst_indexfetch.ps1"
local TMP_DL_PS1   = _tmp .. "\\dm_inst_download.ps1"
local TMP_DL_DONE  = _tmp .. "\\dm_inst_download.done"
local TMP_DL_CFG   = _tmp .. "\\dm_inst_download.cfg"   -- curl parallel config file

local POLL        = 0.05  -- seconds between sentinel checks
local _last_check = 0
local _files      = nil   -- [{url, dest, is_main, name}] after index parse
local _pkg_key    = nil   -- M.results / M.active_url key for current install

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function EnsureVBS()
    local f = io.open(_vbs, "w")
    if not f then return end
    f:write('Set sh = CreateObject("WScript.Shell")\r\n')
    local ps = 'powershell -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File'
    f:write('sh.Run "' .. ps .. ' """ & WScript.Arguments(0) & """", 0, False\r\n')
    f:close()
end

local function LaunchBg(ps1_path)
    reaper.ExecProcess('wscript.exe //B //NoLogo "' .. _vbs .. '" "' .. ps1_path .. '"', -1)
end

local function IsDrivePkg(pkg)
    return type(pkg.drive_url) == "string" and pkg.reapack_url == "None"
end

local function DriveDest(pkg)
    return _res .. "\\Scripts\\DM_DrivePackages\\" .. pkg.name .. "\\" .. pkg.main_script
end
M.DriveDest = DriveDest

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

-- ── Index XML parser ──────────────────────────────────────────────────────────
-- Returns: index_name (string), files (table) or nil, err_msg
-- files[i] = { url, dest, is_main, name }
-- Collects ALL version blocks per reapack, then picks the highest version number,
-- so the correct version is installed regardless of the ordering in the XML.
local function ParseIndex(xml)
    local index_name = xml:match('<index[^>]+name="([^"]*)"')
    if not index_name then return nil, "Could not find index name" end

    local files       = {}
    local cur_cat     = nil
    local cur_rp_name = nil
    local cur_rp_type = nil
    local cat_depth   = 0
    -- per-reapack: list of { name=version_string, sources={...} }
    local rp_versions = {}
    local cur_ver_idx = nil  -- index into rp_versions for the current <version> block

    local pos = 1
    while pos <= #xml do
        local ts, te, tag = xml:find('<([^>]+)>', pos)
        if not ts then break end
        pos = te + 1

        local is_close = tag:sub(1, 1) == '/'
        local tag_name = is_close and tag:sub(2):match('^[%w_]+') or tag:match('^[%w_]+')

        if is_close then
            if tag_name == 'category' then
                cat_depth = cat_depth - 1
                if cat_depth <= 0 then cat_depth = 0; cur_cat = nil end
            elseif tag_name == 'version' then
                cur_ver_idx = nil
            elseif tag_name == 'reapack' then
                -- Pick the highest version and append its sources to files
                local best_ver, best_sources = nil, nil
                for _, ventry in ipairs(rp_versions) do
                    if not best_ver or VersionGT(ventry.name, best_ver) then
                        best_ver     = ventry.name
                        best_sources = ventry.sources
                    end
                end
                if best_sources then
                    for _, src in ipairs(best_sources) do
                        files[#files + 1] = src
                    end
                end
                cur_rp_name = nil; cur_rp_type = nil
                rp_versions = {}; cur_ver_idx = nil
            end

        else
            if tag_name == 'category' then
                cat_depth = cat_depth + 1
                if cat_depth == 1 then
                    cur_cat = tag:match('name="([^"]*)"')
                end

            elseif tag_name == 'reapack' and cur_cat then
                cur_rp_name = tag:match('name="([^"]*)"')
                cur_rp_type = tag:match('type="([^"]*)"') or 'script'
                rp_versions = {}; cur_ver_idx = nil

            elseif tag_name == 'version' and cur_rp_name then
                local vname = tag:match('name="([^"]*)"') or ""
                rp_versions[#rp_versions + 1] = { name = vname, sources = {} }
                cur_ver_idx = #rp_versions

            elseif tag_name == 'source' and cur_ver_idx and cur_rp_name and cur_cat then
                local file_attr = tag:match('file="([^"]*)"')
                local main_val  = tag:match('main="([^"]*)"')
                local is_main   = main_val ~= nil and main_val ~= ""

                -- Skip Common files (installed by toolkit already)
                local skip = cur_cat:find("^Common")

                -- URL is the text content between <source ...> and </source>
                local url_s, url_e = xml:find('</source>', pos, true)
                local url = url_s and xml:sub(pos, url_s - 1):match('^%s*(.-)%s*$') or ""
                if url_s then pos = url_e + 1 end

                if url ~= "" and not skip then
                    local rel  = (file_attr or cur_rp_name):gsub('/', '\\')
                    local dest
                    if cur_rp_type == 'data' then
                        dest = _res .. '\\' .. rel
                    elseif cur_cat ~= "" then
                        dest = _res .. '\\Scripts\\' .. index_name .. '\\'
                            .. cur_cat:gsub('/', '\\') .. '\\' .. rel
                    else
                        dest = _res .. '\\Scripts\\' .. index_name .. '\\' .. rel
                    end
                    local src_list = rp_versions[cur_ver_idx].sources
                    src_list[#src_list + 1] = {
                        url     = url,
                        dest    = dest,
                        is_main = is_main and (cur_rp_type == 'script'),
                        name    = cur_rp_name,
                    }
                end
            end
        end
    end

    if #files == 0 then return nil, "No source files found in index" end
    return index_name, files
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Start a direct install for the given package.
-- For reapack packages (reapack_url set): fetches index.xml first.
-- For drive packages (drive_url set, reapack_url == "None"): downloads directly.
-- Safe to call when state is "idle", "done", or "error".
function M.StartInstall(pkg)
    if M.state == "fetching_index" or M.state == "downloading" then return end

    _files = nil
    M.log  = {}
    EnsureVBS()

    -- ── Drive package: single file, skip index fetch ──────────────────────────
    if IsDrivePkg(pkg) then
        _pkg_key     = pkg.drive_url
        M.active_url = _pkg_key

        if not pkg.main_script then
            M.state   = "error"
            M.message = "drive_url package is missing main_script field."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end

        local file_id = pkg.drive_url:match('/file/d/([^/?#]+)')
        if not file_id then
            M.state   = "error"
            M.message = "Could not extract file ID from drive_url."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end

        local dl_url   = "https://drive.usercontent.google.com/download?id=" .. file_id .. "&export=download&confirm=t"
        local dest     = DriveDest(pkg)
        local dest_fwd = dest:gsub('\\', '/')
        local dir      = dest:match('^(.*[/\\])')
        local ext      = pkg.main_script:match('%.(%w+)$') or ""
        local is_main  = ext == "lua" or ext == "py"

        _files = {{ url = dl_url, dest = dest, is_main = is_main, name = pkg.name }}

        reaper.ShowConsoleMsg("[DM_Installer] Drive download starting\n")
        reaper.ShowConsoleMsg("[DM_Installer] URL: " .. dl_url .. "\n")
        reaper.ShowConsoleMsg("[DM_Installer] Dest: " .. dest_fwd .. "\n")

        os.remove(TMP_DL_DONE)
        local err_file = _tmp .. "\\dm_inst_curl_err.txt"
        local df = io.open(TMP_DL_PS1, "w")
        if not df then
            M.state   = "error"
            M.message = "Could not write download script."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end
        if dir then
            df:write(string.format('New-Item -ItemType Directory -Force -Path "%s" | Out-Null\r\n', dir))
        end
        local err_fwd = err_file:gsub('\\', '/')
        -- Store URL in a PS variable to avoid any quoting issues with & in the URL
        df:write(string.format('$url = "%s"\r\n', dl_url))
        df:write(string.format('$out = "%s"\r\n', dest_fwd))
        df:write('$err = & curl.exe -SL4 $url -o $out 2>&1\r\n')
        df:write(string.format(
            '$err | Out-File -FilePath "%s" -Encoding ascii\r\n', err_fwd))
        df:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_DL_DONE))
        df:close()

        LaunchBg(TMP_DL_PS1)
        M.state     = "downloading"
        M.message   = "Downloading..."
        _last_check = 0
        return
    end

    -- ── Reapack package: fetch index XML first ────────────────────────────────
    _pkg_key     = pkg.reapack_url
    M.active_url = _pkg_key

    os.remove(TMP_IDX_TXT)
    os.remove(TMP_IDX_DONE)

    local f = io.open(TMP_IDX_PS1, "w")
    if not f then
        M.state   = "error"
        M.message = "Could not write temp PS1 script."
        M.results[_pkg_key] = { state = "error", message = M.message }
        M.active_url = nil
        return
    end
    f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', pkg.reapack_url, TMP_IDX_TXT))
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_IDX_DONE))
    f:close()

    LaunchBg(TMP_IDX_PS1)
    M.state     = "fetching_index"
    M.message   = "Fetching package index..."
    _last_check = 0
end

-- Drive the state machine. Call this every frame from the main loop.
function M.Tick()
    if M.state == "idle" or M.state == "done" or M.state == "error" then return end

    local now = reaper.time_precise()
    if now - _last_check < POLL then return end
    _last_check = now

    -- ── Phase 1: index fetched ────────────────────────────────────────────────
    if M.state == "fetching_index" then
        local done = io.open(TMP_IDX_DONE, "r")
        if not done then return end
        done:close()

        local f   = io.open(TMP_IDX_TXT, "r")
        local xml = f and f:read("*a") or ""
        if f then f:close() end

        os.remove(TMP_IDX_DONE)
        os.remove(TMP_IDX_TXT)
        os.remove(TMP_IDX_PS1)

        if xml == "" then
            M.state   = "error"
            M.message = "Failed to download index XML (no content)."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end

        local idx_name, files = ParseIndex(xml)
        if not idx_name then
            M.state   = "error"
            M.message = "Failed to parse index XML: " .. (files or "unknown error")
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end

        _files = files

        -- Persist the index.xml to cache so GetCachedVersion can compare versions later
        local cache_dir  = _res .. "\\Scripts\\DM_ReaperToolkit\\cache"
        local cache_file = cache_dir .. "\\" .. idx_name .. ".xml"
        os.execute('mkdir "' .. cache_dir .. '" 2>nul')
        local wf = io.open(cache_file, "w")
        if wf then wf:write(xml); wf:close() end

        -- Write curl config file: one url/output pair per file (used for parallel download)
        local cf = io.open(TMP_DL_CFG, "w")
        if not cf then
            M.state   = "error"
            M.message = "Could not write curl config file."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end
        for _, entry in ipairs(_files) do
            -- curl config files treat '\' as an escape character, so use forward slashes
            -- for output paths (Windows accepts both separators)
            local dest_fwd = entry.dest:gsub('\\', '/')
            cf:write(string.format('url = "%s"\r\noutput = "%s"\r\n', entry.url, dest_fwd))
        end
        cf:close()

        -- Build download PS1: deduplicated mkdirs + single parallel curl call + sentinel
        os.remove(TMP_DL_DONE)
        local df = io.open(TMP_DL_PS1, "w")
        if not df then
            M.state   = "error"
            M.message = "Could not write download script."
            M.results[_pkg_key] = { state = "error", message = M.message }
            M.active_url = nil
            return
        end
        local seen_dirs = {}
        for _, entry in ipairs(_files) do
            local dir = entry.dest:match('^(.*[/\\])')
            if dir and not seen_dirs[dir] then
                seen_dirs[dir] = true
                df:write(string.format(
                    'New-Item -ItemType Directory -Force -Path "%s" | Out-Null\r\n', dir))
            end
        end
        df:write(string.format(
            'curl.exe --parallel --parallel-immediate -sSL4 -K "%s"\r\n', TMP_DL_CFG))
        df:write(string.format(
            'Remove-Item -Path "%s" -ErrorAction SilentlyContinue\r\n', TMP_DL_CFG))
        df:write(string.format(
            'New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_DL_DONE))
        df:close()

        LaunchBg(TMP_DL_PS1)
        M.state     = "downloading"
        M.message   = string.format("Downloading %d file(s)...", #_files)
        _last_check = 0

    -- ── Phase 2: files downloaded ─────────────────────────────────────────────
    elseif M.state == "downloading" then
        local done = io.open(TMP_DL_DONE, "r")
        if not done then return end
        done:close()

        os.remove(TMP_DL_DONE)
        os.remove(TMP_DL_PS1)
        os.remove(TMP_DL_CFG)

        -- Debug: log curl stderr to REAPER console
        local err_file = _tmp .. "\\dm_inst_curl_err.txt"
        local ef = io.open(err_file, "r")
        if ef then
            local curl_err = ef:read("*a") or ""
            ef:close()
            reaper.ShowConsoleMsg("[DM_Installer] curl stderr:\n" .. curl_err .. "\n")
        else
            reaper.ShowConsoleMsg("[DM_Installer] No curl stderr file found.\n")
        end

        -- Debug: log downloaded file info to REAPER console
        reaper.ShowConsoleMsg("[DM_Installer] Download complete. Checking files:\n")
        for _, entry in ipairs(_files) do
            local fh = io.open(entry.dest, "r")
            if fh then
                local head = fh:read(200) or ""
                local size = fh:seek("end") or 0
                fh:close()
                reaper.ShowConsoleMsg(string.format(
                    "  [OK] %s (%d bytes)\n  First 200 chars: %s\n",
                    entry.dest, size, head:gsub("\n", "\\n")))
            else
                reaper.ShowConsoleMsg(string.format(
                    "  [MISSING] %s — file does not exist!\n", entry.dest))
            end
        end

        -- Register REAPER actions for all main scripts
        local registered = 0
        for _, entry in ipairs(_files) do
            M.log[#M.log + 1] = entry.dest
            if entry.is_main then
                local cmd_id = reaper.AddRemoveReaScript(true, 0, entry.dest, true)
                if cmd_id and cmd_id ~= 0 then
                    registered = registered + 1
                else
                    M.log[#M.log + 1] = "  (warning: could not register action for " .. entry.name .. ")"
                end
            end
        end

        M.state   = "done"
        M.message = string.format(
            "Done. %d file(s) installed, %d action(s) registered.", #_files, registered)
        M.results[_pkg_key] = { state = "done", message = M.message }
        M.active_url = nil
    end
end

-- Synchronously remove all files installed for a package and unregister their REAPER actions.
-- For reapack packages, index_name is the <index name="..."> value from the index cache.
-- For drive packages (reapack_url == "None"), index_name is ignored.
function M.StartUninstall(pkg, index_name)
    if M.state == "fetching_index" or M.state == "downloading" then return end

    -- ── Drive package: delete single known file ───────────────────────────────
    if IsDrivePkg(pkg) then
        local pkg_key = pkg.drive_url
        local dest    = DriveDest(pkg)
        reaper.AddRemoveReaScript(false, 0, dest, true)
        if os.remove(dest) then
            M.results[pkg_key] = { state = "done", message = "Uninstalled." }
        else
            M.results[pkg_key] = { state = "error", message = "File not found or could not be removed." }
        end
        return
    end

    -- ── Reapack package: reconstruct file list from cached index XML ──────────
    local pkg_key   = pkg.reapack_url
    local dm_cache  = _res .. "\\Scripts\\DM_ReaperToolkit\\cache\\" .. index_name .. ".xml"
    local rp_cache  = _res .. "\\ReaPack\\cache\\" .. index_name .. ".xml"
    local cache_xml = nil
    for _, path in ipairs({ dm_cache, rp_cache }) do
        local f = io.open(path, "r")
        if f then cache_xml = f:read("*a"); f:close(); break end
    end

    if not cache_xml then
        M.results[pkg_key] = { state = "error", message = "Cannot find cached index; try reinstalling first." }
        return
    end

    local idx_name, files = ParseIndex(cache_xml)
    if not idx_name then
        M.results[pkg_key] = { state = "error", message = "Failed to parse index for uninstall." }
        return
    end

    local removed = 0
    local unreg   = 0
    for _, entry in ipairs(files) do
        if entry.is_main then
            reaper.AddRemoveReaScript(false, 0, entry.dest, true)
            unreg = unreg + 1
        end
        if os.remove(entry.dest) then removed = removed + 1 end
    end
    os.remove(dm_cache)  -- clear DM version cache so status checks reflect the removal

    M.results[pkg_key] = {
        state   = "done",
        message = string.format("Uninstalled. %d file(s) removed, %d action(s) unregistered.", removed, unreg),
    }
end

-- Reset to idle so the user can retry or install a different package.
function M.Reset()
    if _pkg_key then M.results[_pkg_key] = nil end
    M.state      = "idle"
    M.message    = ""
    M.log        = {}
    M.active_url = nil
    _files       = nil
    _pkg_key     = nil
end

return M
