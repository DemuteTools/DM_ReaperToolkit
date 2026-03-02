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

M.readme_cache = {}   -- key=github_url: string content or "Loading..."
M.image_cache  = {}   -- key=url: { status, path, img }
M.index_cache  = {}   -- key=reapack_url: "queued"/"Loading..."/{ category, name }/{ error=true }

local image_queue       = {}   -- URLs waiting to be downloaded
local active_imgs       = nil  -- array of {url,path} for the current batch, or nil
local pending_fetch     = nil  -- package whose README is being fetched
local index_queue       = {}   -- packages waiting for index XML fetch
local pending_index     = nil  -- package whose index is being fetched

local POLL_INTERVAL     = 0.1   -- seconds between sentinel file checks
local _fetch_last_check = 0
local _img_last_check   = 0
local _index_last_check = 0

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
            local ext  = url:match("%.(%a+)$") or "png"
            local path = _tmp .. "\\dm_tk_img_" .. HashURL(url) .. "." .. ext
            M.image_cache[url] = { status = "downloading", path = path }
            f:write(string.format('curl.exe -sSL4 "%s" -o "%s"\r\n', url, path))
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
        local t_png = reaper.time_precise()
        local iw, ih = GetImageSize(path)
        reaper.ShowConsoleMsg(string.format("[PROFILE] GetPNGSize (%dx%d): %.2f ms\n",
            iw or 0, ih or 0, (reaper.time_precise() - t_png) * 1000))
        local t_img = reaper.time_precise()
        local ok, img = pcall(reaper.ImGui_CreateImage, path)
        reaper.ShowConsoleMsg(string.format("[PROFILE] ImGui_CreateImage: %.2f ms  ok=%s\n",
            (reaper.time_precise() - t_img) * 1000, tostring(ok)))
        if ok and img then
            reaper.ImGui_Attach(_ctx, img)
            M.image_cache[url] = { status = "ready", img = img, path = path, w = iw, h = ih }
        else
            M.image_cache[url] = { status = "error" }
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

return M
