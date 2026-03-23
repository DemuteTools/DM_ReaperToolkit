---@diagnostic disable: undefined-global, need-check-nil, undefined-field

-- ─── Module Imports ───

local _dir = debug.getinfo(1, 'S').source:match("^@(.*[/\\])")
local _mod = _dir .. "Modules/"
dofile(_mod .. "DM_ToolkitFunctionsLibrary.lua")

local Fetch           = dofile(_mod .. "DM_AsyncFetch.lua")

-- Load packages: prefer the cached remote version, fall back to bundled
local _pkg_cache_path = _dir .. "cache\\dm_packages_remote.lua"
local function _load_pkg_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("*a"); f:close()
    local fn = load(src)
    return fn and fn()
end
local _pkg_data     = _load_pkg_file(_pkg_cache_path) or dofile(_mod .. "DM_Packages.lua")
local packages      = _pkg_data.packages
local _toolkit_info = _pkg_data.toolkit
local MD              = dofile(_mod .. "DM_Markdown.lua")
local PkgStatus       = dofile(_mod .. "DM_PackageStatus.lua")
local DirectInstaller = dofile(_mod .. "DM_DirectInstaller.lua")
local UI              = dofile(_mod .. "DM_UIHelperFunctions.lua")

-- Strip the first top-level heading (# Title) from markdown since the title is already shown in the UI
local function StripH1(md)
    return md:gsub("^%s*#[^#][^\n]*\n?", "", 1)
end

local DEMUTE_ROOT = _dir
local COMMON      = DEMUTE_ROOT .. "Common/Scripts/"
dofile(COMMON .. "DM_Theme.lua")

-- ─── Constants ───

-- Layout
local COLS        = 1
local SPACING     = 15
local VSPACING    = 8
local PAD_X       = 20
local PAD_Y       = 0
local SCROLLBAR_W = 14   -- added so the scrollbar in ##card_scroll doesn't eat into right PAD_X
local SPLITTER_W  = 6    -- width of the draggable divider between panels
local LOGO_W      = 160  -- rendered width of the bottom logo in pixels; change to resize it
local LOGO_PAD_Y  = 20   -- vertical space above and below the logo
local BTN_ROUNDING     = 4   -- corner rounding for normal buttons
local INSPECTOR_PAD_X  = 16  -- horizontal WindowPadding inside the right inspector panel
local INSPECTOR_PAD_Y  = 12  -- vertical WindowPadding inside the right inspector panel
local README_PAD_X     = 10  -- extra horizontal indent for the README body
local README_PAD_Y     = 8   -- extra vertical gap above the README body

-- Card image
local TEXT_PAD  = 20
local TEXT_SIZE_MAX = 30
local TEXT_SIZE = TEXT_SIZE_MAX
local CARD_REF_W = 500  -- reference card width for text scaling
local BAR_H     = TEXT_SIZE_MAX + TEXT_PAD * 2 + 23  -- extra 23 px to accommodate version/update text

-- Card overlay
local CARD_ROUNDING    = 6
local CARD_BORDER_ACTIVE = 2
local CARD_BORDER_HOVER  = 1.5
local CARD_BORDER_IDLE   = 1

-- Badge (top-right dot on installed/imported cards)
local BADGE_SIZE     = 11  -- square width/height
local BADGE_MARGIN_X = 3   -- gap from card right edge
local BADGE_MARGIN_Y = 3   -- gap from card top edge
local BADGE_ROUNDING = 3
-- Update-available arrow (drawn left of the badge)
local ARROW_OFFSET_X    = 23  -- distance from card right edge to arrow centre
local ARROW_HALF_W      = 4   -- half-width of triangle base
local ARROW_H           = 7   -- triangle height
local ARROW_STEM_HALF_W = 1   -- half-width of the vertical stem
local ARROW_STEM_Y      = 8   -- y offset where the stem begins (from card top)

-- Toolbar (above cards)
local TOOLBAR_H       = 20   -- height of the support/contact/settings bar
local TOOLBAR_BTN_PAD_X = 8
local TOOLBAR_BTN_PAD_Y = 2
local TOOLBAR_BTN_GAP   = 2
local GEAR_BTN_SZ       = 30  -- gear icon button size

-- Window
local WIN_INIT_W      = 1200
local WIN_INIT_H      = 700

-- Icon buttons
local ICON_SIZE        = 30  -- display size (px) for icon buttons
local ICON_TINT_NORMAL = 0xFFFFFFFF
local ICON_TINT_HOVER  = 0xCCCCCCFF
local ICON_TINT_ACTIVE = 0xAAAAAAAA

-- Detail panel
local DETAIL_TITLE_FONT_SZ = 24
local DETAIL_BTN_GAP       = 6
local DETAIL_BTN_PAD_X     = 10
local DETAIL_BTN_PAD_Y     = 5
local DETAIL_BTN_FONT_SZ   = 17

-- Detail tabs
local TAB_FRAME_PAD_X = 16
local TAB_FRAME_PAD_Y = 8
local TAB_FONT_SZ     = 16

-- YouTube thumbnail
local YT_THUMB_MAX_W    = 480
local YT_CAPTION_FONT_SZ = 12

-- ─── State ───

local ctx      = reaper.ImGui_CreateContext("DM ReaperToolkit")
local font_big = reaper.ImGui_CreateFont("sans-serif", 28)
local font_h2  = reaper.ImGui_CreateFont("sans-serif", 18)
reaper.ImGui_Attach(ctx, font_big)
reaper.ImGui_Attach(ctx, font_h2)

Fetch.Init(ctx)
MD.Init(ctx, font_big, font_h2)
PkgStatus.Init(Fetch)

for _, pkg in ipairs(packages) do
    Fetch.QueueIndexFetch(pkg)
end
Fetch.StartIndexBatch()

-- Kick off remote packages fetch; on completion, swap the live package list
reaper.RecursiveCreateDirectory(_dir .. "cache", 0)
Fetch.StartPackagesFetch(_pkg_cache_path, function(content)
    local new_data = load(content)
    if not new_data then return end
    new_data = new_data()
    if not new_data or not new_data.packages then return end
    -- Replace packages table in-place so all existing references stay valid
    for k in pairs(packages) do packages[k] = nil end
    for i, p in ipairs(new_data.packages) do packages[i] = p end
    for k, v in pairs(new_data.toolkit) do _toolkit_info[k] = v end
    -- Queue index fetches for any new packages
    for _, pkg in ipairs(packages) do
        if pkg.reapack_url and not Fetch.index_cache[pkg.reapack_url] then
            Fetch.QueueIndexFetch(pkg)
        end
    end
    Fetch.StartIndexBatch()
end)

-- Logo image (bottom of left panel)
local _logo      = nil
local _logo_path = DEMUTE_ROOT .. "Common\\Resources\\Demute_Home_Logo.png"
do
    local lf = io.open(_logo_path, "rb")
    if lf then
        lf:close()
        ---@diagnostic disable-next-line: undefined-global
        local limg = reaper.ImGui_CreateImage(_logo_path)
        if limg then
            ---@diagnostic disable-next-line: undefined-global
            reaper.ImGui_Attach(ctx, limg)
            local lw, lh = GetPNGSize(_logo_path)
            if not lw then lw, lh = 4, 1 end
            _logo = { img = limg, w = lw, h = lh }
        end
    end
end

-- Dynamic layout state (recalculated each frame)
local card_w = PAD_X * 2 + 500 * COLS + SPACING * (COLS - 1) + SCROLLBAR_W  -- initial estimate
local logo_h = 0
local left_w = PAD_X * 2 + 500 * COLS + SPACING * (COLS - 1) + SCROLLBAR_W

local selected              = nil
local first_frame           = true
local _open                 = true
local _prev_installer_state = "idle"  -- used to detect DirectInstaller "done" transition

-- ─── Thumbnail Cache ───
-- Thumbnails are fetched from GitHub and persisted to disk so they survive restarts.
-- Only one thumbnail is loaded or promoted per frame to avoid UI freezes.

local THUMB_RAW_BASE = "https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/main/Resources/Thumbnails/"
local _thumb_cache_dir = _dir .. "cache\\thumbnails\\"
local _thumb_cache   = {}     -- pkg.name -> {img, w, h} or false
local _thumb_state   = {}     -- pkg.name -> "pending_disk" / "pending_fetch" / "done"
local _thumb_queue   = {}     -- ordered list of pkg.name waiting to be processed
local _thumb_dir_created = false

local function EnsureThumbCacheDir()
    if _thumb_dir_created then return end
    reaper.RecursiveCreateDirectory(_thumb_cache_dir, 0)
    _thumb_dir_created = true
end

-- Copy a fetched image to the persistent cache
local function PersistThumbnail(pkg, entry)
    if not entry or not entry.path then return end
    EnsureThumbCacheDir()
    local ext = entry.path:match("%.(%w+)$") or "png"
    local dest = _thumb_cache_dir .. pkg.name .. "." .. ext
    local src = io.open(entry.path, "rb")
    if not src then return end
    local data = src:read("*a")
    src:close()
    local dst = io.open(dest, "wb")
    if dst then dst:write(data); dst:close() end
end

-- Called once per frame from the main loop: load at most one thumbnail from disk or promote one fetch result
local function TickThumbnails()
    for i, name in ipairs(_thumb_queue) do
        if _thumb_cache[name] ~= nil then
            -- Already resolved (memory cache hit or error), remove from queue
            table.remove(_thumb_queue, i)
            return
        end
        local state = _thumb_state[name]

        -- Stage 1: try loading from persistent disk cache (one per frame)
        if state == "pending_disk" then
            for _, ext in ipairs({ ".png", ".jpg" }) do
                local path = _thumb_cache_dir .. name .. ext
                local f = io.open(path, "rb")
                if f then
                    f:close()
                    local ok, img = pcall(reaper.ImGui_CreateImage, path)
                    if ok and img then
                        reaper.ImGui_Attach(ctx, img)
                        local w, h = GetImageSize(path)
                        _thumb_cache[name] = { img = img, w = w or 0, h = h or 0 }
                        _thumb_state[name] = "done"
                        table.remove(_thumb_queue, i)
                        return  -- one per frame
                    end
                end
            end
            -- Not on disk — move to fetch stage
            _thumb_state[name] = "pending_fetch"
            local encoded = name:gsub(" ", "%%20")
            Fetch.QueueImageFetch(THUMB_RAW_BASE .. encoded .. ".png")
            Fetch.QueueImageFetch(THUMB_RAW_BASE .. encoded .. ".jpg")
            return  -- give fetch a frame to start
        end

        -- Stage 2: check if the fetch has completed (one per frame)
        if state == "pending_fetch" then
            local encoded = name:gsub(" ", "%%20")
            local url_png = THUMB_RAW_BASE .. encoded .. ".png"
            local url_jpg = THUMB_RAW_BASE .. encoded .. ".jpg"
            for _, url in ipairs({ url_png, url_jpg }) do
                local entry = Fetch.image_cache[url]
                if entry and entry.status == "ready" then
                    -- Find the pkg table so we can persist
                    local pkg
                    for _, p in ipairs(packages) do
                        if p.name == name then pkg = p; break end
                    end
                    if pkg then PersistThumbnail(pkg, entry) end
                    _thumb_cache[name] = { img = entry.img, w = entry.w, h = entry.h }
                    _thumb_state[name] = "done"
                    table.remove(_thumb_queue, i)
                    return  -- one per frame
                end
            end
            -- Check if both failed
            local pe = Fetch.image_cache[url_png]
            local je = Fetch.image_cache[url_jpg]
            if pe and pe.status == "error" and je and je.status == "error" then
                _thumb_cache[name] = false
                _thumb_state[name] = "done"
                table.remove(_thumb_queue, i)
            end
            return  -- wait for fetch
        end
    end
end

local function GetThumbnail(pkg)
    -- Memory cache hit (instant)
    if _thumb_cache[pkg.name] ~= nil then
        return _thumb_cache[pkg.name] or nil
    end
    -- Enqueue if not already queued
    if not _thumb_state[pkg.name] then
        _thumb_state[pkg.name] = "pending_disk"
        _thumb_queue[#_thumb_queue + 1] = pkg.name
    end
    return nil  -- not ready yet
end

-- ─── Icon Cache ───
-- LoadIcon accepts either a toolbar icon name (no path separators → looked up in
-- the REAPER toolbar_icons/200 folder) or a full file path for custom images.

local _icon_cache = {}
local _icon_dir   = reaper.GetResourcePath():gsub("/", "\\") .. "\\Data\\toolbar_icons\\200\\"

-- Custom icon paths
local _ico_web = DEMUTE_ROOT .. "Common\\Resources\\Icons\\android-icon-72x72.png"
local _ico_gh  = DEMUTE_ROOT .. "Common\\Resources\\Icons\\GithubIcon.png"
local _ico_run = reaper.GetResourcePath():gsub("/", "\\") .. "\\Data\\toolbar_icons\\toolbar_misc_right_forward_next.png"

local function LoadIcon(path)
    if not path:find("[/\\]") then
        path = _icon_dir .. path .. ".png"
    end
    if _icon_cache[path] ~= nil then return _icon_cache[path] or nil end
    local img = reaper.ImGui_CreateImage(path)
    if not img then _icon_cache[path] = false; return nil end
    reaper.ImGui_Attach(ctx, img)
    _icon_cache[path] = img
    return img
end

-- Renders a clickable icon button that opens a URL on click.
local function DrawIconButton(id, path, tooltip, url)
    local ico = LoadIcon(path)
    if not ico then return end
    local bx, by  = reaper.ImGui_GetCursorScreenPos(ctx)
    local clicked = reaper.ImGui_InvisibleButton(ctx, id, ICON_SIZE, ICON_SIZE)
    local is_hov  = reaper.ImGui_IsItemHovered(ctx)
    local is_act  = reaper.ImGui_IsItemActive(ctx)
    local tint    = is_act and ICON_TINT_ACTIVE or (is_hov and ICON_TINT_HOVER or ICON_TINT_NORMAL)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddImage(draw_list, ico, bx, by, bx + ICON_SIZE, by + ICON_SIZE, 0, 0, 1, 1, tint)
    if clicked then reaper.CF_ShellExecute(url) end
    if is_hov  then reaper.ImGui_SetTooltip(ctx, tooltip) end
end

-- ─── Package Card ───

local function DrawCardImage(draw_list, thumb, x, y, bar_h)
    if thumb then
        -- Center-crop: compute UVs so the image fills the card without stretching
        local u0, v0, u1, v1 = 0, 0, 1, 1
        if thumb.w > 0 and thumb.h > 0 then
            local card_ar = card_w / bar_h
            local img_ar  = thumb.w / thumb.h
            if img_ar > card_ar then
                local u = card_ar / img_ar
                u0, u1 = (1 - u) / 2, (1 + u) / 2
            else
                local v = img_ar / card_ar
                v0, v1 = (1 - v) / 2, (1 + v) / 2
            end
        end
        reaper.ImGui_DrawList_AddImageRounded(draw_list, thumb.img,
            x, y, x + card_w, y + bar_h, u0, v0, u1, v1, Colors.white, CARD_ROUNDING)
    else
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + bar_h, Colors.blue, CARD_ROUNDING)
    end
    -- Dark bar at top so white title text is always legible
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
        x, y, x + card_w, y + bar_h, Colors.black_smoke, CARD_ROUNDING)
end

local function DrawCardBadge(draw_list, pkg, status, x, y)
    if status == "installed" then
        reaper.ImGui_DrawList_AddRectFilled(draw_list,
            x + card_w - BADGE_SIZE - BADGE_MARGIN_X, y + BADGE_MARGIN_Y,
            x + card_w - BADGE_MARGIN_X,              y + BADGE_MARGIN_Y + BADGE_SIZE,
            Colors.green, BADGE_ROUNDING)
        if PkgStatus.IsUpdateAvailable(pkg) then
            local ax = x + card_w - ARROW_OFFSET_X
            reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                ax,                y + BADGE_MARGIN_Y,
                ax - ARROW_HALF_W, y + BADGE_MARGIN_Y + ARROW_H,
                ax + ARROW_HALF_W, y + BADGE_MARGIN_Y + ARROW_H,
                Colors.amber)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
                ax - ARROW_STEM_HALF_W, y + ARROW_STEM_Y,
                ax + ARROW_STEM_HALF_W, y + BADGE_MARGIN_Y + BADGE_SIZE,
                Colors.amber, 0)
        end
    elseif status == "imported" then
        reaper.ImGui_DrawList_AddRectFilled(draw_list,
            x + card_w - BADGE_SIZE - BADGE_MARGIN_X, y + BADGE_MARGIN_Y,
            x + card_w - BADGE_MARGIN_X,              y + BADGE_MARGIN_Y + BADGE_SIZE,
            Colors.orange, BADGE_ROUNDING)
    end
end

local function DrawCardOverlay(draw_list, x, y, bar_h, hov, act)
    if act then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + bar_h, Colors.white_faint, CARD_ROUNDING)
        reaper.ImGui_DrawList_AddRect(draw_list,       x, y, x + card_w, y + bar_h, Colors.white_bright, CARD_ROUNDING, nil, CARD_BORDER_ACTIVE)
    elseif hov then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + bar_h, Colors.white_dim, CARD_ROUNDING)
        reaper.ImGui_DrawList_AddRect(draw_list,       x, y, x + card_w, y + bar_h, Colors.white_soft, CARD_ROUNDING, nil, CARD_BORDER_HOVER)
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    else
        reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + card_w, y + bar_h, Colors.white_ghost, CARD_ROUNDING, nil, CARD_BORDER_IDLE)
    end
end

local function DrawPackageCard(pkg)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local x, y     = reaper.ImGui_GetCursorScreenPos(ctx)
    local thumb     = GetThumbnail(pkg)
    local status    = PkgStatus.GetPackageStatus(pkg)

    -- Pre-compute wrapped text height by simulating word-wrap
    local wrap_w = card_w - TEXT_PAD * 2
    reaper.ImGui_PushFont(ctx, font_big, TEXT_SIZE)
    local line_h = reaper.ImGui_GetFontSize(ctx)
    local lines = 1
    local cur_line = ""
    for w in pkg.name:gmatch("%S+") do
        local test = (cur_line == "") and w or (cur_line .. " " .. w)
        local tw = reaper.ImGui_CalcTextSize(ctx, test)
        if tw > wrap_w and cur_line ~= "" then
            lines = lines + 1
            cur_line = w
        else
            cur_line = test
        end
    end
    local text_h = lines * line_h
    reaper.ImGui_PopFont(ctx)
    local bar_h = math.max(BAR_H, text_h + TEXT_PAD * 2)

    -- Draw card background (DrawList renders on top of prior widgets, so draw first)
    DrawCardImage(draw_list, thumb, x, y, bar_h)
    DrawCardBadge(draw_list, pkg, status, x, y)

    -- Title text overlaid on the dark bar (same draw list, drawn after image)
    local text_dl = draw_list
    reaper.ImGui_PushFont(ctx, font_big, TEXT_SIZE)
    local text_x = x + TEXT_PAD
    local text_y = y + TEXT_PAD
    -- Word-wrap manually: split and draw with DrawList so it renders on top
    local words = {}
    for w in pkg.name:gmatch("%S+") do words[#words + 1] = w end
    local line = ""
    local cy = text_y
    for _, w in ipairs(words) do
        local test = (line == "") and w or (line .. " " .. w)
        local tw = reaper.ImGui_CalcTextSize(ctx, test)
        if tw > wrap_w and line ~= "" then
            reaper.ImGui_DrawList_AddText(text_dl, text_x, cy, Colors.white, line)
            cy = cy + line_h
            line = w
        else
            line = test
        end
    end
    if line ~= "" then
        reaper.ImGui_DrawList_AddText(text_dl, text_x, cy, Colors.white, line)
    end
    reaper.ImGui_PopFont(ctx)

    -- Claim the full card area for layout and click detection
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    reaper.ImGui_Dummy(ctx, card_w, bar_h)

    local hov = reaper.ImGui_IsItemHovered(ctx)
    local act = reaper.ImGui_IsItemActive(ctx)
    DrawCardOverlay(draw_list, x, y, bar_h, hov, act)
end

-- ─── Toolkit info (shown when no card is selected) ───

local function DrawToolkitInfo()
    reaper.ImGui_Spacing(ctx)
    UI.TextWithFont(ctx, _toolkit_info.name, font_big, DETAIL_TITLE_FONT_SZ)

    local avail_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
    local has_gh = _toolkit_info.github_url ~= ""

    if has_gh then
        reaper.ImGui_SameLine(ctx, avail_w - ICON_SIZE + INSPECTOR_PAD_X, 0)
        DrawIconButton("##tk_gh", _ico_gh, "GitHub", _toolkit_info.github_url)
    end

    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_Dummy(ctx, 0, README_PAD_Y)
    reaper.ImGui_Indent(ctx, README_PAD_X)
    reaper.ImGui_PushFont(ctx, font_big, TAB_FONT_SZ)
    if _toolkit_info.description and _toolkit_info.description ~= "" then
        reaper.ImGui_TextWrapped(ctx, _toolkit_info.description)
        reaper.ImGui_Spacing(ctx)
    end

    -- Show toolkit README
    Fetch.StartReadmeFetch(_toolkit_info)
    local readme = Fetch.readme_cache[_toolkit_info.github_url] or "Loading..."
    if readme == "Loading..." then
        reaper.ImGui_TextDisabled(ctx, "Loading...")
    else
        local base_raw_url = _toolkit_info.github_url
            :gsub("https://github%.com/", "https://raw.githubusercontent.com/")
            .. "/main/"
        MD.Render(StripH1(readme), base_raw_url, Fetch.image_cache, Fetch.QueueImageFetch)
    end
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_Unindent(ctx, README_PAD_X)
end

-- ─── Detail Panel ───

-- Returns the key used to look up results/active_url in DirectInstaller.
-- Drive packages use drive_url; reapack packages use reapack_url.
local function PkgKey(pkg)
    return (type(pkg.drive_url) == "string" and pkg.reapack_url == "None")
        and pkg.drive_url or pkg.reapack_url
end

local function DrawDetailHeader(status)
    reaper.ImGui_Spacing(ctx)
    local avail_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
    local has_reapack   = selected.reapack_url ~= nil and selected.reapack_url ~= "None"
    local rp_registered = has_reapack and IsRepoRegistered(selected.reapack_url)
    local rp_installed  = status == "installed" and rp_registered

    -- Determine which buttons to show
    local mgr_lbl       = "Manage in ReaPack"
    local inst_lbl      = (status == "installed")
                        and (PkgStatus.IsUpdateAvailable(selected) and "Update" or "Reinstall")
                        or "Direct Install"
    local rp_lbl        = "ReaPack Install"

    local has_web       = selected.Website_url ~= nil and selected.Website_url ~= "None"
    local has_gh        = selected.github_url  ~= nil and selected.github_url  ~= "None"
    local has_run       = (status == "installed")
    -- If installed via ReaPack, show "Manage in ReaPack" instead of install/uninstall
    local show_manage   = rp_installed
    local has_uninstall = (status == "installed") and not rp_installed

    -- Measure text button widths at the button font size
    reaper.ImGui_PushFont(ctx, font_big, DETAIL_BTN_FONT_SZ)
    local inst_tw = reaper.ImGui_CalcTextSize(ctx, inst_lbl)
    local un_tw   = reaper.ImGui_CalcTextSize(ctx, "Uninstall")
    local rp_tw   = reaper.ImGui_CalcTextSize(ctx, rp_lbl)
    local mgr_tw  = reaper.ImGui_CalcTextSize(ctx, mgr_lbl)
    reaper.ImGui_PopFont(ctx)
    local inst_bw = inst_tw + DETAIL_BTN_PAD_X * 2
    local un_bw   = un_tw   + DETAIL_BTN_PAD_X * 2
    local rp_bw   = rp_tw   + DETAIL_BTN_PAD_X * 2
    local mgr_bw  = mgr_tw  + DETAIL_BTN_PAD_X * 2

    local total_w = (has_web and (ICON_SIZE + DETAIL_BTN_GAP) or 0)
                  + (has_gh  and (ICON_SIZE + DETAIL_BTN_GAP) or 0)
                  + (has_run and (ICON_SIZE + DETAIL_BTN_GAP) or 0)
    if show_manage then
        total_w = total_w + mgr_bw
    else
        total_w = total_w + inst_bw
                  + (has_reapack and (DETAIL_BTN_GAP + rp_bw) or 0)
                  + (has_uninstall and (DETAIL_BTN_GAP + un_bw) or 0)
    end

    UI.TextWithFont(ctx, selected.name, font_big, DETAIL_TITLE_FONT_SZ)
    reaper.ImGui_SameLine(ctx, avail_w - total_w, 0)

    if has_web then
        DrawIconButton("##web", _ico_web, "Website", selected.Website_url)
        reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
    end

    if has_gh then
        DrawIconButton("##gh", _ico_gh, "GitHub", selected.github_url)
        reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
    end

    if has_run then
        local ico_run     = LoadIcon(_ico_run)
        local script_path = PkgStatus.GetScriptPath(selected)
        if ico_run and UI.ImageButton(ctx, "##run", ico_run, ICON_SIZE, ICON_SIZE,
                { three_state = true }) then
            local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
            if cmd_id ~= 0 then
                reaper.Main_OnCommand(cmd_id, 0)
            else
                reaper.ShowConsoleMsg("[ReaperToolkit] Could not register: " .. script_path .. "\n")
            end
        end
        if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Run") end
        reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
    end

    local teal_btn = {
        color = Colors.teal_btn, hovered = Colors.teal_btn_hover, active = Colors.teal_btn_press,
        pad_x = DETAIL_BTN_PAD_X, pad_y = DETAIL_BTN_PAD_Y, rounding = BTN_ROUNDING,
    }

    reaper.ImGui_PushFont(ctx, font_big, DETAIL_BTN_FONT_SZ)

    if show_manage then
        -- Installed via ReaPack: single "Manage in ReaPack" button
        if UI.Button(ctx, mgr_lbl .. "##mgr", teal_btn) then
            local manage_action = reaper.NamedCommandLookup("_REAPACK_MANAGE")
            if manage_action > 0 then
                reaper.Main_OnCommand(manage_action, 0)
            end
        end
    else
        -- Not installed via ReaPack: show Direct Install + ReaPack Install + Uninstall
        if UI.Button(ctx, inst_lbl .. "##inst", teal_btn) then
            DirectInstaller.StartInstall(selected)
        end

        if has_reapack then
            reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
            if UI.Button(ctx, rp_lbl .. "##rp", teal_btn) then
                ImportReapackRepo(selected.reapack_url, selected.name)
            end
        end

        if has_uninstall then
            reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
            local un_btn = {
                color = Colors.grey, hovered = Colors.red_hover, active = Colors.red_press,
                pad_x = DETAIL_BTN_PAD_X, pad_y = DETAIL_BTN_PAD_Y, rounding = BTN_ROUNDING,
            }
            if UI.Button(ctx, "Uninstall##un", un_btn) then
                if type(selected.drive_url) == "string" and selected.reapack_url == "None" then
                    DirectInstaller.StartUninstall(selected, nil)
                else
                    local idx_entry = Fetch.index_cache[selected.reapack_url]
                    if type(idx_entry) == "table" and not idx_entry.error and idx_entry.index_name then
                        DirectInstaller.StartUninstall(selected, idx_entry.index_name)
                    end
                end
                PkgStatus.InvalidateFileCache()
                PkgStatus.InvalidateVersionCache()
            end
        end
    end

    reaper.ImGui_PopFont(ctx)

    if status == "installed" then
        local disp_v  = PkgStatus.GetCachedVersion(selected)
        local ver_str = disp_v and (" v" .. disp_v) or ""
        local via_str = rp_registered and " (ReaPack)" or ""
        UI.TextColored(ctx, "\xe2\x9c\x93 Installed" .. ver_str .. via_str, Colors.success)
    end
end

local function DrawInstallStatus(di_busy, pkg_result, status)
    local pkg_is_active = DirectInstaller.active_url == PkgKey(selected)
    if di_busy and pkg_is_active then
        reaper.ImGui_Spacing(ctx)
        UI.TextColored(ctx, DirectInstaller.message, Colors.grey_mid)
    elseif pkg_result and pkg_result.state == "done" then
        reaper.ImGui_Spacing(ctx)
        UI.TextColored(ctx, pkg_result.message, Colors.success)
    elseif pkg_result and pkg_result.state == "error" then
        reaper.ImGui_Spacing(ctx)
        UI.TextColored(ctx, pkg_result.message, Colors.red_light)
    elseif status == "installed" then
        local online_v = PkgStatus.GetOnlineVersion(selected)
        if online_v and PkgStatus.IsUpdateAvailable(selected) then
            reaper.ImGui_Spacing(ctx)
            UI.TextColored(ctx, "  \xe2\x86\x91 Update available: v" .. online_v, Colors.amber)
        end
    end
end

local function DrawYouTubeThumbnail()
    if not selected.youtube_url then return end
    local vid_id = selected.youtube_url:match("[?&]v=([%w_%-]+)")
    if not vid_id then return end

    local thumb_url = "https://img.youtube.com/vi/" .. vid_id .. "/mqdefault.jpg"
    Fetch.QueueImageFetch(thumb_url)
    local entry = Fetch.image_cache[thumb_url]
    if entry and entry.status == "ready" and entry.img then
        local tab_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
        local disp_w   = math.min(tab_w, YT_THUMB_MAX_W)
        local aspect   = (entry.w and entry.w > 0) and (entry.h / entry.w) or (9 / 16)
        local disp_h   = math.floor(disp_w * aspect)

        -- Capture screen pos before the button for the play-icon overlay
        local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)

        if UI.ImageButton(ctx, "##yt_thumb", entry.img, disp_w, disp_h,
            { hovered = Colors.dark_tint, active = Colors.dark_tint_sub }) then
            reaper.CF_ShellExecute(selected.youtube_url)
        end
        UI.PlayIconOverlay(ctx, bx, by, disp_w, disp_h)

        -- Caption below thumbnail
        UI.TextColored(ctx, "\xe2\x96\xb6 Watch Tutorial", Colors.grey_mid, font_big, YT_CAPTION_FONT_SZ)
        reaper.ImGui_Spacing(ctx)
    elseif not (entry and entry.status == "error") then
        reaper.ImGui_TextDisabled(ctx, "Loading preview...")
        reaper.ImGui_Spacing(ctx)
    end
end

local function DrawDescriptionTab()
    if not reaper.ImGui_BeginTabItem(ctx, "Description") then return end

    reaper.ImGui_Dummy(ctx, 0, README_PAD_Y)
    reaper.ImGui_Indent(ctx, README_PAD_X)
    DrawYouTubeThumbnail()

    -- Fetch and render description markdown from the toolkit repo
    Fetch.StartDescFetch(selected)
    local desc = Fetch.desc_cache[selected.name]
    if desc == "Loading..." or desc == "queued" then
        reaper.ImGui_TextDisabled(ctx, "Loading...")
    elseif desc and desc ~= "" then
        local base_raw_url = "https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/main/Resources/Descriptions/"
        MD.Render(StripH1(desc), base_raw_url, Fetch.image_cache, Fetch.QueueImageFetch)
    else
        reaper.ImGui_TextWrapped(ctx, "No description yet.")
    end

    reaper.ImGui_Unindent(ctx, README_PAD_X)
    reaper.ImGui_EndTabItem(ctx)
end

local function DrawDocumentationTab()
    if not reaper.ImGui_BeginTabItem(ctx, "Documentation") then return end

    reaper.ImGui_Dummy(ctx, 0, README_PAD_Y)
    reaper.ImGui_Indent(ctx, README_PAD_X)

    local has_gh = selected.github_url ~= nil and selected.github_url ~= "None"
    if has_gh then
        -- Fetch README from the package's GitHub repo
        local readme = Fetch.readme_cache[selected.github_url] or "Loading..."
        if readme == "Loading..." then
            reaper.ImGui_TextDisabled(ctx, "Loading...")
        else
            local base_raw_url = selected.github_url
                :gsub("https://github%.com/", "https://raw.githubusercontent.com/")
                .. "/main/"
            MD.Render(StripH1(readme), base_raw_url, Fetch.image_cache, Fetch.QueueImageFetch)
        end
    else
        -- No GitHub repo: fetch from Resources/Documentation/{name}.md
        Fetch.StartDocFetch(selected)
        local doc = Fetch.doc_cache[selected.name]
        if doc == "Loading..." or doc == "queued" then
            reaper.ImGui_TextDisabled(ctx, "Loading...")
        elseif doc and doc ~= "" then
            local base_raw_url = "https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/main/Resources/Documentation/"
            MD.Render(StripH1(doc), base_raw_url, Fetch.image_cache, Fetch.QueueImageFetch)
        else
            reaper.ImGui_TextWrapped(ctx, "No documentation yet.")
        end
    end

    reaper.ImGui_Unindent(ctx, README_PAD_X)
    reaper.ImGui_EndTabItem(ctx)
end

local function DrawDetailTabs()
    -- Tab bar styling: larger boxes, larger text, light-grey palette
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FramePadding(),         TAB_FRAME_PAD_X, TAB_FRAME_PAD_Y)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(),               Colors.grey)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(),        Colors.grey_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(),       Colors.grey_mid)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmed(),         Colors.grey)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmedSelected(), Colors.grey_mid)
    reaper.ImGui_PushFont(ctx, font_big, TAB_FONT_SZ)

    if reaper.ImGui_BeginTabBar(ctx, "##detail_tabs") then
        DrawDescriptionTab()
        DrawDocumentationTab()
        reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_PopStyleColor(ctx, 5)
    reaper.ImGui_PopStyleVar(ctx)
end

local function DrawDetailPanel()
    if not selected then
        DrawToolkitInfo()
        return
    end

    local status     = PkgStatus.GetPackageStatus(selected)
    local di_state   = DirectInstaller.state
    local di_busy    = di_state == "fetching_index" or di_state == "downloading"
    local pkg_result = DirectInstaller.results[PkgKey(selected)]

    DrawDetailHeader(status)
    DrawInstallStatus(di_busy, pkg_result, status)
    reaper.ImGui_Spacing(ctx)
    DrawDetailTabs()
end

-- ─── Toolbar (Support / Contact / Settings) ───

local _tb_support_hov = false
local _tb_contact_hov = false

local function DrawToolbar()
    local tb_link = {
        rounding = 2, pad_x = TOOLBAR_BTN_PAD_X, pad_y = TOOLBAR_BTN_PAD_Y,
        color = Colors.transparent, hovered = Colors.transparent, active = Colors.transparent,
    }
    reaper.ImGui_SetCursorPosX(ctx, PAD_X)

    local pushed_support = _tb_support_hov
    if pushed_support then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), Theme.C.accent)
    end
    if UI.Button(ctx, "Ask for Support##tb", tb_link) then
        reaper.CF_ShellExecute("https://www.demute.studio/support")
    end
    if pushed_support then reaper.ImGui_PopStyleColor(ctx) end
    _tb_support_hov = reaper.ImGui_IsItemHovered(ctx)
    if _tb_support_hov then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end

    reaper.ImGui_SameLine(ctx, 0, TOOLBAR_BTN_GAP)

    local pushed_contact = _tb_contact_hov
    if pushed_contact then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), Theme.C.accent)
    end
    if UI.Button(ctx, "Contact Us##tb", tb_link) then
        reaper.CF_ShellExecute("https://www.demute.studio/contact")
    end
    if pushed_contact then reaper.ImGui_PopStyleColor(ctx) end
    _tb_contact_hov = reaper.ImGui_IsItemHovered(ctx)
    if _tb_contact_hov then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end

    if Fetch.packages_fetch_state == "fetching" then
        reaper.ImGui_SameLine(ctx, 0, TOOLBAR_BTN_GAP)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
        reaper.ImGui_Text(ctx, "Fetching packages\xe2\x80\xa6")
        reaper.ImGui_PopStyleColor(ctx)
    end

    -- Home button (deselects card → shows toolkit info)
    reaper.ImGui_SameLine(ctx, left_w - GEAR_BTN_SZ * 2 - PAD_X - TOOLBAR_BTN_GAP, 0)
    local home_style = {
        rounding = 4, pad_x = 0, pad_y = 0,
        color = Colors.transparent, hovered = 0x444444FF, active = 0x555555FF,
    }
    reaper.ImGui_PushFont(ctx, font_big, 17)
    if UI.Button(ctx, "\xe2\x8c\x82##home", home_style) then
        selected = nil
    end
    reaper.ImGui_PopFont(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Home")
    end

    -- Settings gear button (text-based)
    reaper.ImGui_SameLine(ctx, left_w - GEAR_BTN_SZ - PAD_X, 0)
    local gear_style = {
        rounding = 4, pad_x = 0, pad_y = 0,
        color = Colors.transparent, hovered = 0x444444FF, active = 0x555555FF,
    }
    reaper.ImGui_PushFont(ctx, font_big, 17)
    if UI.Button(ctx, "\xe2\x9a\x99##gear", gear_style) then
        reaper.ImGui_OpenPopup(ctx, "##settings_popup")
    end
    reaper.ImGui_PopFont(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Settings")
    end
end

local function DrawSettingsPopup()
    -- Anchor popup to the top-right of the left panel (near the gear button)
    local parent_sx, parent_sy = reaper.ImGui_GetWindowPos(ctx)
    reaper.ImGui_SetNextWindowPos(ctx, parent_sx + left_w - PAD_X, parent_sy + TOOLBAR_H,
        reaper.ImGui_Cond_Appearing())

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), Theme.C.child_bg)
    if reaper.ImGui_BeginPopup(ctx, "##settings_popup") then
        reaper.ImGui_Text(ctx, "Cards per row")
        reaper.ImGui_Spacing(ctx)
        for n = 1, 4 do
            if n > 1 then reaper.ImGui_SameLine(ctx, 0, 4) end
            local is_active = (COLS == n)
            local col = is_active and Theme.C.accent or Theme.C.cancel
            local hov = is_active and Theme.C.accent_hov or Theme.C.cancel_hov
            local act = is_active and Theme.C.accent_act or Theme.C.cancel_act
            if Theme.StyledBtn(ctx, tostring(n) .. "##cols", col, hov, act, 28, 0) then
                COLS = n
            end
        end
        reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx)
end

-- ─── Left Panel ───

local function DrawCardList(avail_h, logo_area_h)
    reaper.ImGui_BeginChild(ctx, "##card_scroll", left_w, avail_h - logo_area_h)
    reaper.ImGui_SetCursorPosY(ctx, PAD_Y)
    for i, pkg in ipairs(packages) do
        local col = (i - 1) % COLS
        if col == 0 then
            reaper.ImGui_SetCursorPosX(ctx, PAD_X)
        else
            reaper.ImGui_SameLine(ctx, 0, SPACING)
        end
        reaper.ImGui_BeginGroup(ctx)
        DrawPackageCard(pkg)
        reaper.ImGui_EndGroup(ctx)
        if reaper.ImGui_IsItemClicked(ctx) then
            selected = pkg
            Fetch.StartReadmeFetch(pkg)
        end
        if (i - 1) % COLS == COLS - 1 or i == #packages then
            reaper.ImGui_Dummy(ctx, 0, VSPACING)
        end
    end
    reaper.ImGui_EndChild(ctx)
end

local function DrawLogo()
    if not _logo then return end
    local logo_x = math.floor((left_w - LOGO_W) / 2)
    reaper.ImGui_SetCursorPos(ctx, logo_x, reaper.ImGui_GetCursorPosY(ctx))
    if UI.ImageButton(ctx, "##logo", _logo.img, LOGO_W, logo_h) then
        reaper.CF_ShellExecute("https://www.demute.studio/")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end
    reaper.ImGui_Dummy(ctx, 0, LOGO_PAD_Y)
end

local function DrawLeftPanel(avail_h)
    local _nsb = reaper.ImGui_WindowFlags_NoScrollbar()       ---@diagnostic disable-line: undefined-global
    local _nsm = reaper.ImGui_WindowFlags_NoScrollWithMouse() ---@diagnostic disable-line: undefined-global
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    reaper.ImGui_BeginChild(ctx, "##cards", left_w, avail_h, nil, _nsb | _nsm)
    reaper.ImGui_PopStyleVar(ctx)

    DrawToolbar()
    DrawSettingsPopup()
    local logo_area_h = logo_h > 0 and (logo_h + LOGO_PAD_Y) or 0
    DrawCardList(avail_h - TOOLBAR_H, logo_area_h)
    DrawLogo()

    reaper.ImGui_EndChild(ctx)  -- ##cards
end

-- ─── Main Loop ��──

local function loop()
    Fetch.CheckPendingFetch()
    Fetch.CheckImageFetch()
    Fetch.CheckPendingIndexFetch()
    Fetch.CheckPendingDescFetch()
    Fetch.CheckPendingDocFetch()
    Fetch.CheckPendingPackagesFetch()
    MD.TickParse()

    TickThumbnails()

    DirectInstaller.Tick()
    if _prev_installer_state ~= "done" and DirectInstaller.state == "done" then
        PkgStatus.InvalidateFileCache()
        PkgStatus.InvalidateVersionCache()
    end
    _prev_installer_state = DirectInstaller.state

    if first_frame then
        reaper.ImGui_SetNextWindowSize(ctx, WIN_INIT_W, WIN_INIT_H, reaper.ImGui_Cond_Always())
        first_frame = false
    end

    -- Recalculate dynamic layout values
    card_w = math.max(100, (left_w - PAD_X * 2 - SCROLLBAR_W - SPACING * (COLS - 1)) / COLS)
    TEXT_SIZE = math.max(16, math.floor(TEXT_SIZE_MAX * math.min(1, card_w / (CARD_REF_W * 0.8))))
    logo_h = _logo and math.floor(LOGO_W * _logo.h / _logo.w) or 0

    Theme.PushWindow(ctx)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local visible, p_open = reaper.ImGui_Begin(ctx, "DM ReaperToolkit", true, Theme.WindowFlags())
    if not p_open then _open = false end
    reaper.ImGui_PopStyleVar(ctx)
    Theme.PopWindow(ctx)

    if visible then
        Theme.DrawFocusBorder(ctx)
        Theme.PushUI(ctx)
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local win_w = reaper.ImGui_GetWindowWidth(ctx)
        left_w = math.max(PAD_X * 2 + SCROLLBAR_W + 150, math.min(left_w, win_w - SPLITTER_W - 50))

        DrawLeftPanel(avail_h)
        reaper.ImGui_SameLine(ctx, 0, 0)
        local sp_dx = UI.Splitter(ctx, "##splitter", SPLITTER_W, avail_h)
        if sp_dx then
            left_w = math.max(PAD_X * 2 + SCROLLBAR_W + 150, math.min(left_w + sp_dx, win_w - SPLITTER_W - 50))
        end
        reaper.ImGui_SameLine(ctx, 0, 0)

        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), INSPECTOR_PAD_X, INSPECTOR_PAD_Y)
        if reaper.ImGui_BeginChild(ctx, "##detail", 0, avail_h, reaper.ImGui_ChildFlags_AlwaysUseWindowPadding()) then
            DrawDetailPanel()
            reaper.ImGui_EndChild(ctx)
        end
        reaper.ImGui_PopStyleVar(ctx)

        Theme.PopUI(ctx)
        reaper.ImGui_End(ctx)
    end

    if _open then reaper.defer(loop) end
end

reaper.defer(loop)
