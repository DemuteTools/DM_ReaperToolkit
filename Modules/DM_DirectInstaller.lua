--[[
@version 1.0
@noindex
@description Direct installer for Reaper Toolkit packages
--]]

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

-- ── Platform detection ────────────────────────────────────────────────────────
local OS     = reaper.GetOS()
local IS_WIN = OS:find("^Win") ~= nil
local SEP    = IS_WIN and "\\" or "/"
local CURL   = IS_WIN and "curl.exe" or "curl"

-- Does a ReaPack platform="" attribute match the running system?
local function PlatformMatches(p)
    if not p or p == "" or p == "all" then return true end
    if OS == "Win64"         then return p == "windows" or p == "win64" end
    if OS == "Win32"         then return p == "windows" or p == "win32" end
    if OS == "macOS-arm64"   then return p == "darwin"  or p == "darwin-arm64" end
    if OS == "OSX64"         then return p == "darwin"  or p == "darwin64" end
    if OS == "OSX32"         then return p == "darwin"  or p == "darwin32" end
    if OS:match("^linux") then
        if p == "linux" then return true end
        if OS:match("x86_64")  then return p == "linux64" end
        if OS:match("i686")    then return p == "linux32" end
        if OS:match("aarch64") then return p == "linux-aarch64" end
        if OS:match("armv7l")  then return p == "linux-armv7l" end
    end
    return false
end

-- ── Internals ─────────────────────────────────────────────────────────────────

local function FileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Resolve a writable temp directory.
-- On Windows, Lua 5.3 uses ANSI file APIs so paths with non-ASCII characters
-- (e.g. accented letters in the username) silently fail with io.open.
-- We probe each candidate with both a .tmp and a script file (.ps1 on Windows,
-- .sh on Mac) because AV software and AppLocker policies can block writing
-- script files while allowing .tmp files.
local function _resolve_tmp()
    local script_ext = IS_WIN and ".ps1" or ".sh"
    local function try(dir)
        if type(dir) ~= "string" or #dir == 0 then return false end
        dir = IS_WIN and dir:gsub("/",  "\\"):gsub("\\+$", "")
                     or  dir:gsub("\\", "/" ):gsub("/+$",  "")
        local p1 = dir .. SEP .. "dm_tk_probe.tmp"
        local p2 = dir .. SEP .. "dm_tk_probe" .. script_ext
        local f1 = io.open(p1, "w")
        local f2 = io.open(p2, "w")
        if f1 then f1:close(); os.remove(p1) end
        if f2 then f2:close(); os.remove(p2) end
        if f1 and f2 then return dir end
        return false
    end
    if IS_WIN then
        return try(os.getenv("TEMP"))
            or try(os.getenv("TMP"))
            or try("C:\\Windows\\Temp")
            or (function()
                   local fb = reaper.GetResourcePath():gsub("/", "\\") .. "\\dm_tmp"
                   reaper.RecursiveCreateDirectory(fb, 0)
                   return try(fb) or fb
               end)()
    else
        return try(os.getenv("TMPDIR"))
            or try("/tmp")
            or (function()
                   local fb = reaper.GetResourcePath():gsub("\\", "/") .. "/dm_tmp"
                   reaper.RecursiveCreateDirectory(fb, 0)
                   return try(fb) or fb
               end)()
    end
end

local _tmp = _resolve_tmp()
local _res = IS_WIN
    and reaper.GetResourcePath():gsub("/",  "\\")
    or  reaper.GetResourcePath():gsub("\\", "/")

-- Remove plugin files moved aside by a previous update/uninstall (they were
-- still loaded then). Matches both "x.dll.dm_old" and fallback "x.dll.dm_old<n>".
-- Files that are still loaded simply fail to delete and are retried next time.
do
    local base = _res .. SEP .. "UserPlugins"
    for _, dir in ipairs({ base, base .. SEP .. "FX" }) do
        local stale, i = {}, 0
        while true do
            local fn = reaper.EnumerateFiles(dir, i)
            if not fn then break end
            if fn:match("%.dm_old%d*$") then stale[#stale + 1] = fn end
            i = i + 1
        end
        for _, fn in ipairs(stale) do os.remove(dir .. SEP .. fn) end
    end
end

-- Move a (possibly loaded) plugin file out of the way so a new one can be written.
-- Windows can't overwrite or delete a loaded DLL, but it can rename it.
-- Returns the backup path, or nil if the file couldn't be moved.
local function MoveAside(path)
    local old = path .. ".dm_old"
    os.remove(old)                              -- fails harmlessly if still loaded
    if os.rename(path, old) then return old end
    old = path .. ".dm_old" .. os.time()        -- previous backup still locked
    if os.rename(path, old) then return old end
    return nil
end

local _script_ext  = IS_WIN and ".ps1" or ".sh"
local _vbs         = _tmp .. SEP .. "dm_inst_launcher.vbs"   -- Windows only
local TMP_IDX_TXT  = _tmp .. SEP .. "dm_inst_index.txt"
local TMP_IDX_DONE = _tmp .. SEP .. "dm_inst_index.done"
local TMP_IDX_SCR  = _tmp .. SEP .. "dm_inst_indexfetch" .. _script_ext
local TMP_DL_SCR   = _tmp .. SEP .. "dm_inst_download"   .. _script_ext
local TMP_DL_DONE  = _tmp .. SEP .. "dm_inst_download.done"
local TMP_DL_CFG   = _tmp .. SEP .. "dm_inst_download.cfg"   -- curl parallel config file

local POLL        = 0.05  -- seconds between sentinel checks
local _last_check = 0
local _files      = nil   -- [{url, dest, is_main, name, restart, old}] after index parse
local _pkg_key    = nil   -- M.results / M.active_url key for current install

-- ── Script-writing helpers ────────────────────────────────────────────────────
local function w_header(f)
    if not IS_WIN then f:write("#!/bin/bash\n") end
end

-- Empty sentinel file (used for the index fetch)
local function w_sentinel(f, path)
    if IS_WIN then
        f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', path))
    else
        f:write(string.format('touch "%s"\n', path))
    end
end

-- Capture curl's exit code. Must be written directly after the curl line.
local function w_capture_rc(f)
    if IS_WIN then
        f:write('$rc = $LASTEXITCODE\r\n')
    else
        f:write('rc=$?\n')
    end
end

-- Sentinel file containing the captured exit code (used for downloads)
local function w_sentinel_rc(f, path)
    if IS_WIN then
        f:write(string.format('Set-Content -Path "%s" -Value $rc\r\n', path))
    else
        f:write(string.format('echo $rc > "%s"\n', path))
    end
end

local function w_mkdir(f, dir)
    if IS_WIN then
        f:write(string.format('New-Item -ItemType Directory -Force -Path "%s" | Out-Null\r\n', dir))
    else
        f:write(string.format('mkdir -p "%s"\n', dir))
    end
end

local function w_remove(f, path)
    if IS_WIN then
        f:write(string.format('Remove-Item -Path "%s" -ErrorAction SilentlyContinue\r\n', path))
    else
        f:write(string.format('rm -f "%s"\n', path))
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function EnsureVBS()
    if not IS_WIN then return end
    local f = io.open(_vbs, "w")
    if not f then return end
    f:write('Set sh = CreateObject("WScript.Shell")\r\n')
    local ps = 'powershell -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File'
    f:write('sh.Run "' .. ps .. ' """ & WScript.Arguments(0) & """", 0, False\r\n')
    f:close()
end

local function LaunchBg(script_path)
    if IS_WIN then
        reaper.ExecProcess('wscript.exe //B //NoLogo "' .. _vbs .. '" "' .. script_path .. '"', -1)
    else
        reaper.ExecProcess('/bin/bash "' .. script_path .. '"', -1)
    end
end

-- Put the current install into the error state.
local function SetError(msg)
    M.state   = "error"
    M.message = msg
    if _pkg_key then M.results[_pkg_key] = { state = "error", message = msg } end
    M.active_url = nil
end

-- Collect empty directories walking up from each dir in the set, stopping before stop_path.
-- Returns an ordered list (deepest first) suitable for sequential removal.
local function CollectEmptyDirs(dirs, stop)
    local norm = IS_WIN
        and function(p) return p:gsub("/",  "\\") end
        or  function(p) return p:gsub("\\", "/")  end
    local sep_pat = IS_WIN and "^(.+)\\[^\\]+$" or "^(.+)/[^/]+$"
    stop = norm(stop)
    local seen = {}
    local ordered = {}
    for start_dir in pairs(dirs) do
        local dir = norm(start_dir)
        while dir ~= stop and #dir > #stop do
            if seen[dir] then break end
            seen[dir] = true
            ordered[#ordered + 1] = dir
            dir = dir:match(sep_pat) or ""
        end
    end
    -- Sort longest (deepest) first so children are removed before parents
    table.sort(ordered, function(a, b) return #a > #b end)
    return ordered
end

-- Remove a list of directories in a single hidden background process.
-- Uses PowerShell on Windows (checks empty before removing), rmdir on Mac.
local function RemoveEmptyDirsAsync(dir_list)
    if #dir_list == 0 then return end
    local script = _tmp .. SEP .. "dm_inst_rmdir" .. _script_ext
    local f = io.open(script, "w")
    if not f then return end
    w_header(f)
    if IS_WIN then
        EnsureVBS()
        for _, dir in ipairs(dir_list) do
            f:write(string.format(
                'if ((Get-ChildItem -LiteralPath "%s" -Force -EA SilentlyContinue | Measure).Count -eq 0)'
                .. ' { Remove-Item -LiteralPath "%s" -Force -EA SilentlyContinue }\r\n', dir, dir))
        end
    else
        for _, dir in ipairs(dir_list) do
            f:write(string.format('rmdir "%s" 2>/dev/null\n', dir))
        end
    end
    f:close()
    LaunchBg(script)
end

local function IsDrivePkg(pkg)
    return type(pkg.drive_url) == "string" and pkg.reapack_url == "None"
end

local PYTHON_SCRIPTS_DIR = IS_WIN
    and "Scripts\\Demute_toolkit\\pythonScripts"
    or  "Scripts/Demute_toolkit/pythonScripts"

local function DriveDest(pkg)
    return _res .. SEP .. PYTHON_SCRIPTS_DIR .. SEP .. pkg.main_script
end
M.DriveDest = DriveDest

-- Python dependency files bundled with every Drive-installed script
local _py_base = "https://raw.githubusercontent.com/DemuteStudio/"
    .. "DM_ReaperToolkit/main/Common/PythonScripts/"
local PYTHON_DEPS = {
    { file = "DM_ReaLibrary.py",  url = _py_base .. "DM_ReaLibrary.py" },
    { file = "sws_python.py",     url = _py_base .. "sws_python.py" },
    { file = "sws_python64.py",   url = _py_base .. "sws_python64.py" },
}

-- DM.String.VersionGT() is provided by DM_Library.lua, loaded by the calling script.

-- ── Index XML parser ──────────────────────────────────────────────────────────
-- Returns: index_name (string), files (table) or nil, err_msg
-- files[i] = { url, dest, is_main, name, restart }
-- Collects ALL version blocks per reapack, then picks the highest version number,
-- so the correct version is installed regardless of the ordering in the XML.
-- Sources whose platform="" doesn't match this system are skipped.
local function ParseIndex(xml)
    local index_name = xml:match('<index[^>]+name="([^"]*)"')
    if not index_name then return nil, "Could not find index name" end

    local files       = {}
    local cur_cat     = nil
    local cur_rp_name = nil
    local cur_rp_type = nil
    local cat_depth   = 0
    local rp_versions = {}
    local cur_ver_idx = nil

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
                local best_ver, best_sources = nil, nil
                for _, ventry in ipairs(rp_versions) do
                    if not best_ver or DM.String.VersionGT(ventry.name, best_ver) then
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
                local src_type  = tag:match('type="([^"]*)"') or cur_rp_type
                local platform  = tag:match('platform="([^"]*)"')
                local is_main   = main_val ~= nil and main_val ~= ""

                local url_s, url_e = xml:find('</source>', pos, true)
                local url = url_s and xml:sub(pos, url_s - 1):match('^%s*(.-)%s*$') or ""
                if url_s then pos = url_e + 1 end

                if url ~= "" and PlatformMatches(platform) then
                    -- Normalise relative path to the platform separator
                    local rel = (file_attr or cur_rp_name):gsub('[/\\]', SEP)
                    local dest
                    if src_type == 'data' then
                        dest = _res .. SEP .. rel
                    elseif src_type == 'extension' then
                        dest = _res .. SEP .. 'UserPlugins' .. SEP .. rel
                    elseif cur_cat ~= "" then
                        dest = _res .. SEP .. 'Scripts' .. SEP .. index_name .. SEP
                            .. cur_cat:gsub('[/\\]', SEP) .. SEP .. rel
                    else
                        dest = _res .. SEP .. 'Scripts' .. SEP .. index_name .. SEP .. rel
                    end
                    local src_list = rp_versions[cur_ver_idx].sources
                    src_list[#src_list + 1] = {
                        url     = url,
                        dest    = dest,
                        is_main = is_main and (src_type == 'script'),
                        name    = cur_rp_name,
                        restart = (src_type == 'extension'),
                    }
                end
            end
        end
    end

    if #files == 0 then return nil, "No source files found in index" end
    return index_name, files
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.StartInstall(pkg)
    if M.state == "fetching_index" or M.state == "downloading" then return end

    _files = nil
    M.log  = {}
    if IS_WIN then EnsureVBS() end

    -- ── Drive package: single file, skip index fetch ──────────────────────────
    if IsDrivePkg(pkg) then
        _pkg_key     = pkg.drive_url
        M.active_url = _pkg_key

        if not pkg.main_script then
            SetError("drive_url package is missing main_script field.")
            return
        end

        local file_id = pkg.drive_url:match('/file/d/([^/?#]+)')
        if not file_id then
            SetError("Could not extract file ID from drive_url.")
            return
        end

        local dl_url  = "https://drive.usercontent.google.com/download?id="
            .. file_id .. "&export=download&confirm=t"
        local dest    = DriveDest(pkg)
        local dir     = _res .. SEP .. PYTHON_SCRIPTS_DIR
        local ext     = pkg.main_script:match('%.(%w+)$') or ""
        local is_main = ext == "lua" or ext == "py"

        _files = {{ url = dl_url, dest = dest, is_main = is_main, name = pkg.name }}
        for _, dep in ipairs(PYTHON_DEPS) do
            _files[#_files + 1] = {
                url     = dep.url,
                dest    = dir .. SEP .. dep.file,
                is_main = false,
                name    = dep.file,
            }
        end

        -- Write curl config for all files (curl accepts forward slashes on all platforms)
        os.remove(TMP_DL_DONE)
        local cf = io.open(TMP_DL_CFG, "w")
        if not cf then
            SetError("Could not write curl config file.")
            return
        end
        for _, entry in ipairs(_files) do
            local d = entry.dest:gsub('\\', '/')
            cf:write(string.format('url = "%s"\noutput = "%s"\n', entry.url, d))
        end
        cf:close()

        local df = io.open(TMP_DL_SCR, "w")
        if not df then
            SetError("Could not write download script.")
            return
        end
        w_header(df)
        w_mkdir(df, dir)
        df:write(string.format(
            IS_WIN and 'curl.exe --parallel --parallel-immediate -fSL4 -K "%s"\r\n'
                    or 'curl --parallel --parallel-immediate -fSL4 -K "%s"\n',
            TMP_DL_CFG))
        w_capture_rc(df)
        w_remove(df, TMP_DL_CFG)
        w_sentinel_rc(df, TMP_DL_DONE)
        df:close()

        LaunchBg(TMP_DL_SCR)
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

    local f = io.open(TMP_IDX_SCR, "w")
    if not f then
        SetError("Could not write temp script.")
        return
    end
    w_header(f)
    if IS_WIN then
        f:write(string.format('curl.exe -fsSL4 "%s" -o "%s"\r\n', pkg.reapack_url, TMP_IDX_TXT))
    else
        f:write(string.format('curl -fsSL4 "%s" -o "%s"\n', pkg.reapack_url, TMP_IDX_TXT))
    end
    w_sentinel(f, TMP_IDX_DONE)
    f:close()

    LaunchBg(TMP_IDX_SCR)
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
        os.remove(TMP_IDX_SCR)

        if xml == "" then
            SetError("Failed to download index XML (no content).")
            return
        end

        local idx_name, files = ParseIndex(xml)
        if not idx_name then
            SetError("Failed to parse index XML: " .. (files or "unknown error"))
            return
        end

        _files = files

        -- Persist the index.xml to cache so GetCachedVersion can compare versions later
        local cache_dir  = _res .. SEP .. "Scripts" .. SEP .. "DM_ReaperToolkit" .. SEP .. "cache"
        local cache_file = cache_dir .. SEP .. idx_name .. ".xml"
        reaper.RecursiveCreateDirectory(cache_dir, 0)
        local wf = io.open(cache_file, "w")
        if wf then wf:write(xml); wf:close() end

        -- Write curl config file (forward slashes work on both platforms for curl)
        os.remove(TMP_DL_DONE)
        local cf = io.open(TMP_DL_CFG, "w")
        if not cf then
            SetError("Could not write curl config file.")
            return
        end
        for _, entry in ipairs(_files) do
            local dest_fwd = entry.dest:gsub('\\', '/')
            cf:write(string.format('url = "%s"\noutput = "%s"\n', entry.url, dest_fwd))
        end
        cf:close()

        -- Build download script: deduplicated mkdirs + single parallel curl call + sentinel
        local df = io.open(TMP_DL_SCR, "w")
        if not df then
            SetError("Could not write download script.")
            return
        end
        w_header(df)
        local seen_dirs = {}
        for _, entry in ipairs(_files) do
            local dir = entry.dest:match(IS_WIN and '^(.*[/\\])' or '^(.*/)')
            if dir and not seen_dirs[dir] then
                seen_dirs[dir] = true
                w_mkdir(df, dir)
            end
        end
        df:write(string.format(
            IS_WIN and 'curl.exe --parallel --parallel-immediate -fsSL4 -K "%s"\r\n'
                    or 'curl --parallel --parallel-immediate -fsSL4 -K "%s"\n',
            TMP_DL_CFG))
        w_capture_rc(df)
        w_remove(df, TMP_DL_CFG)
        w_sentinel_rc(df, TMP_DL_DONE)
        df:close()

        -- Move existing plugin files aside so curl can write the new ones.
        -- Done last, right before launching, so no early error can leave them renamed.
        -- If a move fails and the file is locked, curl fails and phase 2 reports it.
        for _, entry in ipairs(_files) do
            entry.old = nil
            if entry.restart and FileExists(entry.dest) then
                entry.old = MoveAside(entry.dest)
            end
        end

        LaunchBg(TMP_DL_SCR)
        M.state     = "downloading"
        M.message   = string.format("Downloading %d file(s)...", #_files)
        _last_check = 0

    -- ── Phase 2: files downloaded ─────────────────────────────────────────────
    elseif M.state == "downloading" then
        local done = io.open(TMP_DL_DONE, "r")
        if not done then return end
        local code = tonumber((done:read("*a") or ""):match("%d+")) or -1
        done:close()

        os.remove(TMP_DL_DONE)
        os.remove(TMP_DL_SCR)
        os.remove(TMP_DL_CFG)

        -- Put the previous plugin files back and enter the error state
        local function fail(msg)
            for _, e in ipairs(_files) do
                if e.old and FileExists(e.old) then
                    os.remove(e.dest)
                    os.rename(e.old, e.dest)
                    e.old = nil
                end
            end
            SetError(msg)
        end

        if code ~= 0 then
            fail("Download failed (curl exit code " .. code .. ").")
            return
        end

        for _, entry in ipairs(_files) do
            if not FileExists(entry.dest) then
                fail("Download failed: " .. entry.dest:match("[^/\\]+$"))
                return
            end
        end

        local registered = 0
        local restart = false
        local names, seen = {}, {}
        for _, entry in ipairs(_files) do
            M.log[#M.log + 1] = entry.dest
            if entry.restart then
                restart = true
                local plugin = entry.dest:match("[^/\\]+$")
                if not seen[plugin] then
                    seen[plugin] = true
                    names[#names + 1] = plugin
                end
            end

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
        M.message = string.format("Done. %d file(s) installed, %d action(s) registered.", #_files, registered)
        if restart then
            local list = table.concat(names, ", ")
            local verb = #names > 1 and "were" or "was"
            M.message = M.message .. " Restart REAPER to load " .. list .. "."
            reaper.MB(list .. " " .. verb .. " installed.\n\nRestart REAPER before it can work.",
                "Restart REAPER", 0)
        end
        M.results[_pkg_key] = { state = "done", message = M.message }
        M.active_url = nil
    end
end

-- Synchronously remove all files installed for a package and unregister their REAPER actions.
function M.StartUninstall(pkg, index_name)
    if M.state == "fetching_index" or M.state == "downloading" then return end

    local dir_sep_pat = IS_WIN and "^(.+)\\[^\\]+$" or "^(.+)/[^/]+$"

    -- ── Drive package: delete main script + python dependencies ────────────
    if IsDrivePkg(pkg) then
        local pkg_key = pkg.drive_url
        local dest    = DriveDest(pkg)
        local dir     = _res .. SEP .. PYTHON_SCRIPTS_DIR
        reaper.AddRemoveReaScript(false, 0, dest, true)
        local removed = 0
        if os.remove(dest) then removed = removed + 1 end
        for _, dep in ipairs(PYTHON_DEPS) do
            if os.remove(dir .. SEP .. dep.file) then
                removed = removed + 1
            end
        end
        RemoveEmptyDirsAsync(CollectEmptyDirs({ [dir] = true }, _res .. SEP .. "Scripts"))
        M.results[pkg_key] = {
            state   = "done",
            message = string.format("Uninstalled. %d file(s) removed.", removed),
        }
        return
    end

    -- ── Reapack package: reconstruct file list from cached index XML ──────────
    local pkg_key   = pkg.reapack_url
    local dm_cache  = _res .. SEP .. "Scripts" .. SEP .. "DM_ReaperToolkit" .. SEP .. "cache" .. SEP .. index_name .. ".xml"
    local rp_cache  = _res .. SEP .. "ReaPack"  .. SEP .. "cache" .. SEP .. index_name .. ".xml"
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
    local restart = false
    local dirs_seen = {}
    for _, entry in ipairs(files) do
        if entry.is_main then
            reaper.AddRemoveReaScript(false, 0, entry.dest, true)
            unreg = unreg + 1
        end
        local ok = os.remove(entry.dest)
        if not ok and entry.restart and FileExists(entry.dest) then
            -- Loaded DLL can't be deleted, but it can be renamed (cleaned up next load)
            ok = MoveAside(entry.dest) ~= nil
        end
        if ok then
            removed = removed + 1
            if entry.restart then restart = true end
            local dir = entry.dest:match(dir_sep_pat)
            if dir then dirs_seen[dir] = true end
        end
    end
    os.remove(dm_cache)  -- clear DM version cache so status checks reflect the removal

    RemoveEmptyDirsAsync(CollectEmptyDirs(dirs_seen, _res .. SEP .. "Scripts"))

    local msg = string.format("Uninstalled. %d file(s) removed, %d action(s) unregistered.", removed, unreg)
    if restart then
        msg = msg .. " Restart REAPER to finish unloading the plugin."
        reaper.MB("The plugin was uninstalled.\n\nRestart REAPER to finish unloading it.", "Restart REAPER", 0)
    end

    M.results[pkg_key] = { state = "done", message = msg }
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