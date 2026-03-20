---@diagnostic disable: undefined-global

local M = {}

local _ctx
local _tmp         = (os.getenv("TEMP") or reaper.GetResourcePath()):gsub("/", "\\")
local TMP_TXT      = _tmp .. "\\dm_tk_readme.txt"
local TMP_DONE     = _tmp .. "\\dm_tk_readme.done"
local TMP_BAT      = _tmp .. "\\dm_tk_fetch.ps1"
local TMP_IMG_BAT  = _tmp .. "\\dm_tk_imgfetch.ps1"
local TMP_IMG_DONE = _tmp .. "\\dm_tk_imgfetch.done"
local TMP_VBS      = _tmp .. "\\dm_tk_launcher.vbs"
local TMP_IDX_TXT  = _tmp .. "\\dm_tk_index.txt"
local TMP_IDX_DONE = _tmp .. "\\dm_tk_index.done"
local TMP_IDX_BAT  = _tmp .. "\\dm_tk_indexfetch.ps1"
local TMP_DESC_TXT  = _tmp .. "\\dm_tk_desc.txt"
local TMP_DESC_DONE = _tmp .. "\\dm_tk_desc.done"
local TMP_DESC_BAT  = _tmp .. "\\dm_tk_descfetch.ps1"
local TMP_DOC_TXT   = _tmp .. "\\dm_tk_doc.txt"
local TMP_DOC_DONE  = _tmp .. "\\dm_tk_doc.done"
local TMP_DOC_BAT   = _tmp .. "\\dm_tk_docfetch.ps1"

M.readme_cache = {}   -- key=github_url: string content or "Loading..."
M.image_cache  = {}   -- key=url: { status, path, img }
M.index_cache  = {}   -- key=reapack_url: "queued"/"Loading..."/{ category, name }/{ error=true }
M.desc_cache   = {}   -- key=pkg.name: string markdown content or "Loading..."
M.doc_cache    = {}   -- key=pkg.name: string markdown content or "Loading..."

local image_queue       = {}   -- URLs waiting to be downloaded
local active_imgs       = nil  -- array of {url,path} for the current batch, or nil
local pending_fetch     = nil  -- package whose README is being fetched
local index_queue       = {}   -- packages waiting for index XML fetch
local pending_index     = nil  -- package whose index is being fetched
local desc_queue        = {}   -- packages waiting for description fetch
local pending_desc      = nil  -- package whose description is being fetched
local doc_queue         = {}   -- packages waiting for documentation fetch
local pending_doc       = nil  -- package whose documentation is being fetched

local POLL_INTERVAL     = 0.1   -- seconds between sentinel file checks
local _fetch_last_check = 0
local _img_last_check   = 0
local _index_last_check = 0
local _desc_last_check  = 0
local _doc_last_check   = 0

-- Launch a ps1 script as a hidden background process via wscript.exe (GUI subsystem = no console window).
local function launch_bg(ps1_path)
    local t0 = reaper.time_precise()
    local cmd = 'wscript.exe //B //NoLogo "' .. TMP_VBS .. '" "' .. ps1_path .. '"'
    reaper.ExecProcess(cmd, -1)
    reaper.ShowConsoleMsg(string.format("[PROFILE] launch_bg: %.2f ms\n",
        (reaper.time_precise() - t0) * 1000))
end

function M.Init(ctx)
    _ctx = ctx
    -- Write the VBS shim that launches a PS1 silently (wscript is GUI subsystem, no console flash).
    local f = io.open(TMP_VBS, "w")
    if f then
        f:write('Set sh = CreateObject("WScript.Shell")\r\n')
        local ps = 'powershell -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File'
        f:write('sh.Run "' .. ps .. ' """ & WScript.Arguments(0) & """", 0, False\r\n')
        f:close()
    end
end

function M.StartReadmeFetch(pkg)
    if M.readme_cache[pkg.github_url] then return end
    if pending_fetch then return end

    M.readme_cache[pkg.github_url] = "Loading..."

    local url = pkg.github_url
        :gsub("https://github%.com/", "https://raw.githubusercontent.com/")
        .. "/main/README.md"

    os.remove(TMP_DONE)
    os.remove(TMP_TXT)

    local f = io.open(TMP_BAT, "w")
    if not f then
        M.readme_cache[pkg.github_url] = "Error: could not write temp script."
        return
    end
    f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', url, TMP_TXT))
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_DONE))
    f:close()

    launch_bg(TMP_BAT)
    pending_fetch = pkg
end

function M.CheckPendingFetch()
    if not pending_fetch then return end
    local now = reaper.time_precise()
    if now - _fetch_last_check < POLL_INTERVAL then return end
    _fetch_last_check = now

    local t_sentinel = reaper.time_precise()
    local done = io.open(TMP_DONE, "r")
    reaper.ShowConsoleMsg(string.format("[PROFILE] CheckPendingFetch io.open(done): %.2f ms\n",
        (reaper.time_precise() - t_sentinel) * 1000))
    if not done then return end
    done:close()

    local t_read = reaper.time_precise()
    local cf      = io.open(TMP_TXT, "r")
    local content = cf and cf:read("*a") or ""
    if cf then cf:close() end
    reaper.ShowConsoleMsg(string.format("[PROFILE] README read (%d bytes): %.2f ms\n",
        #content, (reaper.time_precise() - t_read) * 1000))

    M.readme_cache[pending_fetch.github_url] =
        (#content > 0) and content or "No README found."

    os.remove(TMP_DONE)
    os.remove(TMP_TXT)
    os.remove(TMP_BAT)
    pending_fetch = nil
end

-- Drain the entire image_queue into one batch script and launch a single background process.
-- Called once; all images download in that one process, then sentinel appears.
local function StartBatchImageFetch()
    if active_imgs or #image_queue == 0 then return end

    local items = {}
    os.remove(TMP_IMG_DONE)

    local f = io.open(TMP_IMG_BAT, "w")
    if not f then
        while #image_queue > 0 do
            M.image_cache[table.remove(image_queue, 1)] = { status = "error" }
        end
        return
    end

    while #image_queue > 0 do
        local url = table.remove(image_queue, 1)
        if M.image_cache[url] and M.image_cache[url].status == "queued" then
            local path = _tmp .. "\\dm_tk_img_" .. HashURL(url) .. ".png"
            M.image_cache[url] = { status = "downloading", path = path }
            local dl_path = path:gsub("%.png$", ".dl")
            f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', url, dl_path))
            -- If already PNG or JPEG just move; otherwise convert to PNG
            -- via WPF/WIC (supports WebP natively on Windows 10/11).
            f:write(string.format(
                'if (Test-Path "%s") {\r\n'
                .. '  $b = [byte[]](Get-Content "%s" -Encoding Byte -TotalCount 4)\r\n'
                .. '  if (($b[0] -eq 0x89 -and $b[1] -eq 0x50) -or'
                .. '      ($b[0] -eq 0xFF -and $b[1] -eq 0xD8)) {\r\n'
                .. '    Move-Item -Force "%s" "%s"\r\n'
                .. '  } else {\r\n'
                .. '    try {\r\n'
                .. '      Add-Type -AssemblyName PresentationCore\r\n'
                .. '      $s = [System.IO.File]::OpenRead("%s")\r\n'
                .. '      $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create('
                .. '$s,'
                .. '[System.Windows.Media.Imaging.BitmapCreateOptions]::None,'
                .. '[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)\r\n'
                .. '      $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder\r\n'
                .. '      $enc.Frames.Add('
                .. '[System.Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))\r\n'
                .. '      $out = [System.IO.File]::Create("%s")\r\n'
                .. '      $enc.Save($out)\r\n'
                .. '      $out.Close(); $s.Close()\r\n'
                .. '      Remove-Item -Force "%s"\r\n'
                .. '    } catch { Move-Item -Force "%s" "%s" }\r\n'
                .. '  }\r\n'
                .. '}\r\n',
                dl_path,       -- Test-Path
                dl_path,       -- Get-Content header
                dl_path, path, -- PNG/JPEG: move directly
                dl_path,       -- OpenRead source
                path,          -- Create PNG output
                dl_path,       -- Remove temp
                dl_path, path  -- catch fallback: move as-is
            ))
            items[#items + 1] = { url = url, path = path }
        end
    end
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_IMG_DONE))
    f:close()

    reaper.ShowConsoleMsg(string.format("[PROFILE] StartBatchImageFetch: %d image(s)\n", #items))
    launch_bg(TMP_IMG_BAT)
    active_imgs = items
end

function M.QueueImageFetch(url)
    if M.image_cache[url] then return end
    M.image_cache[url] = { status = "queued" }
    image_queue[#image_queue + 1] = url
end

function M.CheckImageFetch()
    if not active_imgs then StartBatchImageFetch(); return end
    local now = reaper.time_precise()
    if now - _img_last_check < POLL_INTERVAL then return end
    _img_last_check = now

    local t_sentinel = reaper.time_precise()
    local done = io.open(TMP_IMG_DONE, "r")
    reaper.ShowConsoleMsg(string.format("[PROFILE] CheckImageFetch io.open(done): %.2f ms\n",
        (reaper.time_precise() - t_sentinel) * 1000))
    if not done then return end
    done:close()

    for _, item in ipairs(active_imgs) do
        local url, path = item.url, item.path
        local dl_path = path:gsub("%.png$", ".dl")
        local png_exists = io.open(path, "rb") ~= nil
        local dl_exists  = io.open(dl_path, "rb") ~= nil
        reaper.ShowConsoleMsg(string.format(
            "[IMG DEBUG] url=%s\n  png=%s exists=%s\n  dl=%s exists=%s\n",
            url, path, tostring(png_exists), dl_path, tostring(dl_exists)))
        if dl_exists and not png_exists then
            local hf = io.open(dl_path, "rb")
            if hf then
                local hdr = hf:read(16) or ""
                hf:close()
                local hex = {}
                for i = 1, math.min(#hdr, 16) do
                    hex[#hex + 1] = string.format("%02X", hdr:byte(i))
                end
                reaper.ShowConsoleMsg(string.format(
                    "[IMG DEBUG] .dl header bytes: %s\n", table.concat(hex, " ")))
            end
        end
        if not png_exists then
            reaper.ShowConsoleMsg("[IMG DEBUG] Skipping — .png file not found\n")
            M.image_cache[url] = { status = "error" }
        else
            local t_png = reaper.time_precise()
            local iw, ih = GetImageSize(path)
            reaper.ShowConsoleMsg(string.format("[PROFILE] GetPNGSize (%dx%d): %.2f ms\n",
                iw or 0, ih or 0, (reaper.time_precise() - t_png) * 1000))
            local t_img = reaper.time_precise()
            local ok, img = pcall(reaper.ImGui_CreateImage, path)
            reaper.ShowConsoleMsg(string.format(
                "[PROFILE] ImGui_CreateImage: %.2f ms  ok=%s  err=%s\n",
                (reaper.time_precise() - t_img) * 1000, tostring(ok),
                ok and "none" or tostring(img)))
            if ok and img then
                reaper.ImGui_Attach(_ctx, img)
                M.image_cache[url] = { status = "ready", img = img, path = path, w = iw, h = ih }
            else
                M.image_cache[url] = { status = "error" }
            end
        end
    end

    os.remove(TMP_IMG_DONE)
    os.remove(TMP_IMG_BAT)
    active_imgs = nil
    StartBatchImageFetch()  -- pick up any newly queued images
end

local function StartNextIndexFetch()
    if pending_index or #index_queue == 0 then return end
    local pkg = table.remove(index_queue, 1)
    M.index_cache[pkg.reapack_url] = "Loading..."
    os.remove(TMP_IDX_DONE)
    os.remove(TMP_IDX_TXT)

    local f = io.open(TMP_IDX_BAT, "w")
    if not f then
        M.index_cache[pkg.reapack_url] = { error = true }
        StartNextIndexFetch()
        return
    end
    f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', pkg.reapack_url, TMP_IDX_TXT))
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_IDX_DONE))
    f:close()

    launch_bg(TMP_IDX_BAT)
    pending_index = pkg
end

function M.QueueIndexFetch(pkg)
    if M.index_cache[pkg.reapack_url] then return end
    M.index_cache[pkg.reapack_url] = "queued"
    index_queue[#index_queue + 1] = pkg
    StartNextIndexFetch()
end

function M.CheckPendingIndexFetch()
    if not pending_index then StartNextIndexFetch(); return end
    local now = reaper.time_precise()
    if now - _index_last_check < POLL_INTERVAL then return end
    _index_last_check = now

    local done = io.open(TMP_IDX_DONE, "r")
    if not done then return end
    done:close()

    local f = io.open(TMP_IDX_TXT, "r")
    local xml = f and f:read("*a") or ""
    if f then f:close() end

    local index_name     = xml:match('<index[^>]+name="([^"]*)"')
    local first_category = xml:match('<category[^>]+name="([^"]*)"')
    local first_name     = xml:match('<reapack[^>]+name="([^"]*)"')

    -- Single-pass tag scan: build reapack_name -> category_name map and
    -- reapack_name -> latest version string map.
    -- Tracks nesting depth so inner <category> (e.g. <category>Library</category>
    -- inside a <reapack> block) does not reset the outer top-level category.
    local scripts     = {}
    local versions    = {}   -- reapack_name -> latest version string
    local cur_cat     = nil
    local cur_reapack = nil
    local cat_depth   = 0
    for tag in xml:gmatch('<([^>]+)>') do
        if tag:find('^/category') then
            cat_depth = cat_depth - 1
            if cat_depth <= 0 then cat_depth = 0; cur_cat = nil end
        elseif tag:find('^/reapack') then
            cur_reapack = nil
        elseif not tag:find('^/') then
            if tag:find('^category') then
                cat_depth = cat_depth + 1
                if cat_depth == 1 then
                    cur_cat = tag:match('^category%s.-name="([^"]*)"')
                end
            elseif cur_cat then
                local r = tag:match('^reapack%s.-name="([^"]*)"')
                if r then
                    scripts[r] = cur_cat
                    cur_reapack = r
                elseif cur_reapack then
                    local v = tag:match('^version%s.-name="([^"]*)"')
                    if v then versions[cur_reapack] = v end
                end
            end
        end
    end
    local online_commit = xml:match('<index[^>]+commit="([^"]*)"')

    if index_name and first_category and first_name then
        M.index_cache[pending_index.reapack_url] = {
            index_name    = index_name,
            category      = first_category,
            name          = first_name,
            scripts       = scripts,
            versions      = versions,
            online_commit = online_commit,
        }
    else
        M.index_cache[pending_index.reapack_url] = { error = true }
    end

    os.remove(TMP_IDX_DONE)
    os.remove(TMP_IDX_TXT)
    os.remove(TMP_IDX_BAT)
    pending_index = nil
    StartNextIndexFetch()
end

-- Description markdown fetch (from Resources/Descriptions/{name}.md in the toolkit repo)
local DESC_RAW_BASE = "https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/main/Resources/Descriptions/"

local function StartNextDescFetch()
    if pending_desc or #desc_queue == 0 then return end
    local pkg = table.remove(desc_queue, 1)
    M.desc_cache[pkg.name] = "Loading..."
    os.remove(TMP_DESC_DONE)
    os.remove(TMP_DESC_TXT)

    local url = DESC_RAW_BASE .. pkg.name:gsub(" ", "%%20") .. ".md"

    local f = io.open(TMP_DESC_BAT, "w")
    if not f then
        M.desc_cache[pkg.name] = ""
        StartNextDescFetch()
        return
    end
    f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', url, TMP_DESC_TXT))
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_DESC_DONE))
    f:close()

    launch_bg(TMP_DESC_BAT)
    pending_desc = pkg
end

function M.StartDescFetch(pkg)
    if M.desc_cache[pkg.name] then return end
    M.desc_cache[pkg.name] = "queued"
    desc_queue[#desc_queue + 1] = pkg
    StartNextDescFetch()
end

function M.CheckPendingDescFetch()
    if not pending_desc then StartNextDescFetch(); return end
    local now = reaper.time_precise()
    if now - _desc_last_check < POLL_INTERVAL then return end
    _desc_last_check = now

    local done = io.open(TMP_DESC_DONE, "r")
    if not done then return end
    done:close()

    local f = io.open(TMP_DESC_TXT, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    -- A 404 from raw.githubusercontent returns "404: Not Found"
    if #content == 0 or content:find("^404") then
        M.desc_cache[pending_desc.name] = ""
    else
        M.desc_cache[pending_desc.name] = content
    end

    os.remove(TMP_DESC_DONE)
    os.remove(TMP_DESC_TXT)
    os.remove(TMP_DESC_BAT)
    pending_desc = nil
    StartNextDescFetch()
end

-- Documentation markdown fetch (from Resources/Documentation/{name}.md in the toolkit repo)
-- Used for packages without a github_url (e.g. Drive packages)
local DOC_RAW_BASE = "https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/main/Resources/Documentation/"

local function StartNextDocFetch()
    if pending_doc or #doc_queue == 0 then return end
    local pkg = table.remove(doc_queue, 1)
    M.doc_cache[pkg.name] = "Loading..."
    os.remove(TMP_DOC_DONE)
    os.remove(TMP_DOC_TXT)

    local url = DOC_RAW_BASE .. pkg.name:gsub(" ", "%%20") .. ".md"

    local f = io.open(TMP_DOC_BAT, "w")
    if not f then
        M.doc_cache[pkg.name] = ""
        StartNextDocFetch()
        return
    end
    f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', url, TMP_DOC_TXT))
    f:write(string.format('New-Item -Path "%s" -ItemType File -Force | Out-Null\r\n', TMP_DOC_DONE))
    f:close()

    launch_bg(TMP_DOC_BAT)
    pending_doc = pkg
end

function M.StartDocFetch(pkg)
    if M.doc_cache[pkg.name] then return end
    M.doc_cache[pkg.name] = "queued"
    doc_queue[#doc_queue + 1] = pkg
    StartNextDocFetch()
end

function M.CheckPendingDocFetch()
    if not pending_doc then StartNextDocFetch(); return end
    local now = reaper.time_precise()
    if now - _doc_last_check < POLL_INTERVAL then return end
    _doc_last_check = now

    local done = io.open(TMP_DOC_DONE, "r")
    if not done then return end
    done:close()

    local f = io.open(TMP_DOC_TXT, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    if #content == 0 or content:find("^404") then
        M.doc_cache[pending_doc.name] = ""
    else
        M.doc_cache[pending_doc.name] = content
    end

    os.remove(TMP_DOC_DONE)
    os.remove(TMP_DOC_TXT)
    os.remove(TMP_DOC_BAT)
    pending_doc = nil
    StartNextDocFetch()
end

return M
