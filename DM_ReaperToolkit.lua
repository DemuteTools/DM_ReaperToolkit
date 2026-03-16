---@diagnostic disable: undefined-global, need-check-nil, undefined-field

-- ─── Module Imports ───

local _dir = debug.getinfo(1, 'S').source:match("^@(.*[/\\])")
dofile(_dir .. "DM_ToolkitFunctionsLibrary.lua")

local packages        = dofile(_dir .. "DM_Packages.lua")
local Fetch           = dofile(_dir .. "DM_AsyncFetch.lua")
local MD              = dofile(_dir .. "DM_Markdown.lua")
local PkgStatus       = dofile(_dir .. "DM_PackageStatus.lua")
local DirectInstaller = dofile(_dir .. "DM_DirectInstaller.lua")
local UI              = dofile(_dir .. "DM_UIHelperFunctions.lua")

-- ─── Constants ───

-- Layout
local COLS        = 1
local SPACING     = 15
local VSPACING    = 8
local PAD_X       = 20
local PAD_Y       = 10
local SCROLLBAR_W = 14   -- added so the scrollbar in ##card_scroll doesn't eat into right PAD_X
local SPLITTER_W  = 6    -- width of the draggable divider between panels
local LOGO_W      = 160  -- rendered width of the bottom logo in pixels; change to resize it
local LOGO_PAD_Y  = 12   -- vertical space above and below the logo
local BTN_ROUNDING     = 4   -- corner rounding for normal buttons
local INSPECTOR_PAD_X  = 16  -- horizontal WindowPadding inside the right inspector panel
local INSPECTOR_PAD_Y  = 12  -- vertical WindowPadding inside the right inspector panel
local README_PAD_X     = 10  -- extra horizontal indent for the README body
local README_PAD_Y     = 8   -- extra vertical gap above the README body

-- Card image
local TEXT_PAD  = 20
local TEXT_SIZE = 30
local BAR_H     = TEXT_SIZE + TEXT_PAD * 2 + 23  -- extra 23 px to accommodate version/update text

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

-- Window
local WIN_INIT_W      = 1200
local WIN_INIT_H      = 700
local WIN_ROUNDING    = 10
local WIN_FOCUS_COLOR = 0xFFFFFF30  -- thin border when window is focused

-- Title bar
local TITLEBAR_H          = 30
local TITLEBAR_FONT_SZ    = 14
local TITLEBAR_TITLE_X    = 12   -- left x offset of the window title text
local TITLEBAR_TITLE_FSZ  = 16   -- font size of the window title
local TITLEBAR_BTN_PAD_X  = 10
local TITLEBAR_BTN_PAD_Y  = 5
local TITLEBAR_BTN_GAP    = 6
local TITLEBAR_DRAG_MIN_W = 120  -- minimum width of the invisible drag area
local CLOSE_BTN_SZ        = 22   -- close icon display size (px)
local CLOSE_BTN_LINE_W    = 1.5  -- thickness of the X lines

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

-- Licence gate popup
local LICENCE_FONT_SZ   = 14
local LICENCE_INPUT_W   = 300
local LICENCE_INPUT_MAX = 256
local LICENCE_BTN_GAP   = 10
local LICENCE_BTN_PAD_X = 20
local LICENCE_BTN_PAD_Y = 8

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

-- Logo image (bottom of left panel)
local _logo      = nil
local _logo_path = _dir .. "Resources\\Demute_Home_Logo.png"
do
    local lf = io.open(_logo_path, "rb")
    if lf then
        lf:close()
        ---@diagnostic disable-next-line: undefined-global
        local limg = reaper.ImGui_CreateImage(_logo_path)
        if limg then
            ---@diagnostic disable-next-line: undefined-global
            reaper.ImGui_Attach(ctx, limg)
            ---@diagnostic disable-next-line: undefined-global
            local lw, lh = GetImageSize(_logo_path)
            if not lw then lw, lh = 4, 1 end  -- fallback 4:1 ratio if header unreadable
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
local _open                 = true   -- controlled by our custom close button
local _drag_next_x, _drag_next_y = nil, nil   -- pending window reposition from drag
local _prev_installer_state = "idle"  -- used to detect DirectInstaller "done" transition

local _licence_accepted = false
local _licence_key      = ""
local _gate_needs_open  = true

-- ─── Thumbnail Cache ───

local _thumb_cache = {}  -- pkg.name -> {img, w, h} or false

local function GetThumbnail(pkg)
    if _thumb_cache[pkg.name] ~= nil then
        return _thumb_cache[pkg.name] or nil
    end
    local base = _dir .. "Resources/Thumbnails\\" .. pkg.name
    local path = nil
    for _, ext in ipairs({ ".png", ".jpg" }) do
        local candidate = base .. ext
        local tf = io.open(candidate, "rb")
        if tf then tf:close(); path = candidate; break end
    end
    if not path then
        ---@diagnostic disable-next-line: undefined-global
        reaper.ShowConsoleMsg("[THUMB] not found: " .. base .. ".{png,jpg}\n")
        _thumb_cache[pkg.name] = false
        return nil
    end
    ---@diagnostic disable-next-line: undefined-global
    local img = reaper.ImGui_CreateImage(path)
    if not img then
        ---@diagnostic disable-next-line: undefined-global
        reaper.ShowConsoleMsg("[THUMB] CreateImage failed: " .. path .. "\n")
        _thumb_cache[pkg.name] = false
        return nil
    end
    ---@diagnostic disable-next-line: undefined-global
    reaper.ImGui_Attach(ctx, img)
    ---@diagnostic disable-next-line: undefined-global
    local ok, w, h = pcall(GetImageSize, path)
    if not ok then w, h = 0, 0 end
    w, h = w or 0, h or 0
    ---@diagnostic disable-next-line: undefined-global
    reaper.ShowConsoleMsg("[THUMB] loaded " .. pkg.name .. " (" .. w .. "x" .. h .. ")\n")
    _thumb_cache[pkg.name] = { img = img, w = w, h = h }
    return _thumb_cache[pkg.name]
end

-- ─── Icon Cache ───
-- LoadIcon accepts either a toolbar icon name (no path separators → looked up in
-- the REAPER toolbar_icons/200 folder) or a full file path for custom images.

local _icon_cache = {}
local _icon_dir   = reaper.GetResourcePath():gsub("/", "\\") .. "\\Data\\toolbar_icons\\200\\"

-- Custom icon paths
local _ico_web = _dir .. "Resources\\Icons\\android-icon-72x72.png"
local _ico_gh  = _dir .. "Resources\\Icons\\GithubIcon.png"
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

local function DrawCardImage(draw_list, thumb, x, y)
    if thumb then
        -- Center-crop: compute UVs so the image fills the card without stretching
        local u0, v0, u1, v1 = 0, 0, 1, 1
        if thumb.w > 0 and thumb.h > 0 then
            local card_ar = card_w / BAR_H
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
            x, y, x + card_w, y + BAR_H, u0, v0, u1, v1, Colors.white, CARD_ROUNDING)
    else
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + BAR_H, Colors.blue, CARD_ROUNDING)
    end
    -- Dark bar at top so white title text is always legible
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
        x, y, x + card_w, y + BAR_H, Colors.black_smoke, 0)
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

local function DrawCardOverlay(draw_list, x, y, hov, act)
    if act then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + BAR_H, Colors.white_faint, CARD_ROUNDING)
        reaper.ImGui_DrawList_AddRect(draw_list,       x, y, x + card_w, y + BAR_H, Colors.white_bright, CARD_ROUNDING, nil, CARD_BORDER_ACTIVE)
    elseif hov then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + card_w, y + BAR_H, Colors.white_dim, CARD_ROUNDING)
        reaper.ImGui_DrawList_AddRect(draw_list,       x, y, x + card_w, y + BAR_H, Colors.white_soft, CARD_ROUNDING, nil, CARD_BORDER_HOVER)
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    else
        reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + card_w, y + BAR_H, Colors.white_ghost, CARD_ROUNDING, nil, CARD_BORDER_IDLE)
    end
end

local function DrawPackageCard(pkg)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local x, y     = reaper.ImGui_GetCursorScreenPos(ctx)
    local thumb     = GetThumbnail(pkg)
    local status    = PkgStatus.GetPackageStatus(pkg)

    DrawCardImage(draw_list, thumb, x, y)
    DrawCardBadge(draw_list, pkg, status, x, y)

    -- Title text overlaid on the dark bar
    reaper.ImGui_SetCursorScreenPos(ctx, x + TEXT_PAD, y + TEXT_PAD)
    UI.TextWithFont(ctx, pkg.name, font_big, TEXT_SIZE)

    -- Claim the full card area for layout and click detection
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    reaper.ImGui_Dummy(ctx, card_w, BAR_H)

    local hov = reaper.ImGui_IsItemHovered(ctx)
    local act = reaper.ImGui_IsItemActive(ctx)
    DrawCardOverlay(draw_list, x, y, hov, act)
end

-- ─── Detail Panel ───

local function DrawDetailHeader(status)
    reaper.ImGui_Spacing(ctx)
    local avail_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
    local inst_lbl   = (status == "installed")
                     and (PkgStatus.IsUpdateAvailable(selected) and "Update" or "Reinstall")
                     or "Install"

    local has_web       = selected.Website_url ~= nil
    local has_run       = (status == "installed")
    local has_uninstall = (status == "installed")

    -- Measure text button widths at the button font size
    reaper.ImGui_PushFont(ctx, font_big, DETAIL_BTN_FONT_SZ)
    local inst_tw = reaper.ImGui_CalcTextSize(ctx, inst_lbl)
    local un_tw   = reaper.ImGui_CalcTextSize(ctx, "Uninstall")
    reaper.ImGui_PopFont(ctx)
    local inst_bw = inst_tw + DETAIL_BTN_PAD_X * 2
    local un_bw   = un_tw   + DETAIL_BTN_PAD_X * 2

    local total_w = (has_web and (ICON_SIZE + DETAIL_BTN_GAP) or 0)
                  + ICON_SIZE + DETAIL_BTN_GAP   -- GitHub
                  + (has_run  and (ICON_SIZE + DETAIL_BTN_GAP) or 0)
                  + inst_bw
                  + (has_uninstall and (DETAIL_BTN_GAP + un_bw) or 0)

    UI.TextWithFont(ctx, selected.name, font_big, DETAIL_TITLE_FONT_SZ)

    if status == "installed" then
        reaper.ImGui_SameLine(ctx)
        local disp_v  = PkgStatus.GetCachedVersion(selected)
        local ver_str = disp_v and (" v" .. disp_v) or ""
        UI.TextColored(ctx, " \xe2\x9c\x93 Installed" .. ver_str, Colors.success)
    end

    reaper.ImGui_SameLine(ctx, avail_w - total_w, 0)

    if has_web then
        DrawIconButton("##web", _ico_web, "Website", selected.Website_url)
        reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
    end

    DrawIconButton("##gh", _ico_gh, "GitHub", selected.github_url)
    reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)

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

    local inst_btn = {
        color = Colors.grey, hovered = Colors.grey_hover, active = Colors.grey_press,
        pad_x = DETAIL_BTN_PAD_X, pad_y = DETAIL_BTN_PAD_Y, rounding = BTN_ROUNDING,
    }
    local un_btn = {
        color = Colors.grey, hovered = Colors.red_hover, active = Colors.red_press,
        pad_x = DETAIL_BTN_PAD_X, pad_y = DETAIL_BTN_PAD_Y, rounding = BTN_ROUNDING,
    }

    reaper.ImGui_PushFont(ctx, font_big, DETAIL_BTN_FONT_SZ)
    if UI.Button(ctx, inst_lbl .. "##inst", inst_btn) then
        DirectInstaller.StartInstall(selected)
    end

    if has_uninstall then
        reaper.ImGui_SameLine(ctx, 0, DETAIL_BTN_GAP)
        if UI.Button(ctx, "Uninstall##un", un_btn) then
            local idx_entry = Fetch.index_cache[selected.reapack_url]
            if type(idx_entry) == "table" and not idx_entry.error and idx_entry.index_name then
                DirectInstaller.StartUninstall(selected, idx_entry.index_name)
                PkgStatus.InvalidateFileCache()
                PkgStatus.InvalidateVersionCache()
            end
        end
    end
    reaper.ImGui_PopFont(ctx)
end

local function DrawInstallStatus(di_busy, pkg_result, status)
    local pkg_is_active = DirectInstaller.active_url == selected.reapack_url
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
    reaper.ImGui_TextWrapped(ctx, selected.description or "No description yet.")
    reaper.ImGui_Unindent(ctx, README_PAD_X)
    reaper.ImGui_EndTabItem(ctx)
end

local function DrawDocumentationTab()
    if not reaper.ImGui_BeginTabItem(ctx, "Documentation") then return end

    local readme = Fetch.readme_cache[selected.github_url] or "Loading..."
    reaper.ImGui_Dummy(ctx, 0, README_PAD_Y)
    reaper.ImGui_Indent(ctx, README_PAD_X)
    if readme == "Loading..." then
        reaper.ImGui_TextDisabled(ctx, "Loading...")
    else
        local base_raw_url = selected.github_url
            :gsub("https://github%.com/", "https://raw.githubusercontent.com/")
            .. "/main/"
        MD.Render(readme, base_raw_url, Fetch.image_cache, Fetch.QueueImageFetch)
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
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "Select a package to see details.")
        return
    end

    local status     = PkgStatus.GetPackageStatus(selected)
    local di_state   = DirectInstaller.state
    local di_busy    = di_state == "fetching_index" or di_state == "downloading"
    local pkg_result = DirectInstaller.results[selected.reapack_url]

    DrawDetailHeader(status)
    DrawInstallStatus(di_busy, pkg_result, status)
    reaper.ImGui_Spacing(ctx)
    DrawDetailTabs()
end

-- ─── Profiler ───

local function _prof(label, t0)
    local dt = (reaper.time_precise() - t0) * 1000
    if dt > 1 then
        reaper.ShowConsoleMsg(string.format("[PROFILE] %-30s %.2f ms\n", label, dt))
    end
end

-- ─── Title Bar ───

local function DrawTitleBar()
    local support_lbl = "Ask for Support"
    local contact_lbl = "Contact Us"

    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, _     = reaper.ImGui_GetWindowSize(ctx)

    -- Background rect: top corners rounded to match window, bottom edge flat
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
        win_x, win_y, win_x + win_w, win_y + TITLEBAR_H, Colors.grey, WIN_ROUNDING)
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
        win_x, win_y + math.floor(TITLEBAR_H / 2),
        win_x + win_w, win_y + TITLEBAR_H, Colors.grey, 0)

    -- Measure text-link widths with font pushed (so CalcTextSize is accurate)
    reaper.ImGui_PushFont(ctx, font_big, TITLEBAR_FONT_SZ)
    local tw_sup = reaper.ImGui_CalcTextSize(ctx, support_lbl)
    local tw_con = reaper.ImGui_CalcTextSize(ctx, contact_lbl)
    local bw_sup = tw_sup + TITLEBAR_BTN_PAD_X * 2
    local bw_con = tw_con + TITLEBAR_BTN_PAD_X * 2
    local btns_w = bw_sup + TITLEBAR_BTN_GAP + bw_con + TITLEBAR_BTN_GAP + CLOSE_BTN_SZ + 16
    local drag_w = math.max(TITLEBAR_DRAG_MIN_W, win_w - btns_w)
    local btn_h  = TITLEBAR_FONT_SZ + TITLEBAR_BTN_PAD_Y * 2

    -- Invisible button over left/title area — handles window drag
    reaper.ImGui_SetCursorPos(ctx, 0, 0)
    reaper.ImGui_InvisibleButton(ctx, "##tb_drag", drag_w, TITLEBAR_H)
    if reaper.ImGui_IsItemActive(ctx) then
        local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
        _drag_next_x, _drag_next_y = win_x + dx, win_y + dy
    end

    -- Title text rendered on top of the drag area (Text is non-interactive)
    reaper.ImGui_SetCursorPos(ctx, TITLEBAR_TITLE_X, math.floor((TITLEBAR_H - TITLEBAR_TITLE_FSZ) / 2))
    UI.TextWithFont(ctx, "DM ReaperToolkit", font_big, TITLEBAR_TITLE_FSZ)

    -- Text-link style: no visible background, hover/active stay transparent
    local tb_link = {
        rounding = 2, pad_x = TITLEBAR_BTN_PAD_X, pad_y = TITLEBAR_BTN_PAD_Y,
        color = Colors.transparent, hovered = Colors.transparent, active = Colors.transparent,
    }
    local btn_y = math.floor((TITLEBAR_H - btn_h) / 2)
    reaper.ImGui_SetCursorPos(ctx, drag_w + 8, btn_y)
    if UI.Button(ctx, support_lbl, tb_link) then
        reaper.CF_ShellExecute("https://www.demute.studio/support")
    end
    reaper.ImGui_SameLine(ctx, 0, TITLEBAR_BTN_GAP)
    if UI.Button(ctx, contact_lbl, tb_link) then
        reaper.CF_ShellExecute("https://www.demute.studio/contact")
    end
    reaper.ImGui_SameLine(ctx, 0, TITLEBAR_BTN_GAP)

    -- Close button: InvisibleButton + hand-drawn X cross
    reaper.ImGui_SetCursorPosY(ctx, math.floor((TITLEBAR_H - CLOSE_BTN_SZ) / 2))
    local cls_bx, cls_by = reaper.ImGui_GetCursorScreenPos(ctx)
    if reaper.ImGui_InvisibleButton(ctx, "##close", CLOSE_BTN_SZ, CLOSE_BTN_SZ) then
        _open = false
    end
    local cls_hov = reaper.ImGui_IsItemHovered(ctx)
    local cls_act = reaper.ImGui_IsItemActive(ctx)
    local cls_col = cls_act and Colors.red_press or (cls_hov and Colors.red_hover or Colors.white_mid)
    local m       = CLOSE_BTN_SZ * 0.28  -- inset margin for the X lines
    reaper.ImGui_DrawList_AddLine(draw_list,
        cls_bx + m,                cls_by + m,
        cls_bx + CLOSE_BTN_SZ - m, cls_by + CLOSE_BTN_SZ - m, cls_col, CLOSE_BTN_LINE_W)
    reaper.ImGui_DrawList_AddLine(draw_list,
        cls_bx + CLOSE_BTN_SZ - m, cls_by + m,
        cls_bx + m,                cls_by + CLOSE_BTN_SZ - m, cls_col, CLOSE_BTN_LINE_W)
    reaper.ImGui_PopFont(ctx)

    reaper.ImGui_SetCursorPos(ctx, 0, TITLEBAR_H)
    return TITLEBAR_H
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
    reaper.ImGui_SetCursorPos(ctx, logo_x, reaper.ImGui_GetCursorPosY(ctx) + LOGO_PAD_Y)
    if UI.ImageButton(ctx, "##logo", _logo.img, LOGO_W, logo_h) then
        reaper.CF_ShellExecute("https://www.demute.studio/")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end
end

local function DrawLeftPanel(avail_h)
    local _nsb = reaper.ImGui_WindowFlags_NoScrollbar()       ---@diagnostic disable-line: undefined-global
    local _nsm = reaper.ImGui_WindowFlags_NoScrollWithMouse() ---@diagnostic disable-line: undefined-global
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    reaper.ImGui_BeginChild(ctx, "##cards", left_w, avail_h, nil, _nsb | _nsm)
    reaper.ImGui_PopStyleVar(ctx)

    local logo_area_h = logo_h > 0 and (logo_h + LOGO_PAD_Y * 2) or 0
    DrawCardList(avail_h, logo_area_h)
    DrawLogo()

    reaper.ImGui_EndChild(ctx)  -- ##cards
end

-- ─── Licence Gate ───

local function DrawLicenceGate()
    if _licence_accepted then return end

    if _gate_needs_open then
        reaper.ImGui_OpenPopup(ctx, "Licence Key##gate")
        _gate_needs_open = false
    end

    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SetNextWindowPos(ctx,
        win_x + win_w * 0.5, win_y + win_h * 0.5,
        reaper.ImGui_Cond_Always(), 0.5, 0.5)

    local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
                | reaper.ImGui_WindowFlags_NoMove()

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(), Colors.black_smoke)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),          Colors.grey_dark)
    local open = reaper.ImGui_BeginPopupModal(ctx, "Licence Key##gate", nil, flags)
    reaper.ImGui_PopStyleColor(ctx, 2)

    if open then
        reaper.ImGui_PushFont(ctx, font_big, LICENCE_FONT_SZ)
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Text(ctx, "Please enter your Licence Key to continue:")
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_PushItemWidth(ctx, LICENCE_INPUT_W)
        local changed, new_key = reaper.ImGui_InputText(ctx, "##licence_key", _licence_key, LICENCE_INPUT_MAX)
        if changed then _licence_key = new_key end
        reaper.ImGui_PopItemWidth(ctx)

        reaper.ImGui_Spacing(ctx)

        if UI.Button(ctx, "OK", {
            color = Colors.grey_mid, hovered = Colors.grey_hover, active = Colors.grey_press,
            pad_x = LICENCE_BTN_PAD_X, pad_y = LICENCE_BTN_PAD_Y,
        }) then
            _licence_accepted = true
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx, 0, LICENCE_BTN_GAP)
        if UI.Button(ctx, "Cancel", {
            color = Colors.grey, hovered = Colors.red_hover, active = Colors.red_press,
            pad_x = LICENCE_BTN_PAD_X, pad_y = LICENCE_BTN_PAD_Y,
        }) then
            _open = false
            reaper.ImGui_CloseCurrentPopup(ctx)
        end

        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_EndPopup(ctx)
    end
end

-- ─── Main Loop ───

local function loop()
    local _t = reaper.time_precise()
    Fetch.CheckPendingFetch()
    _prof("CheckPendingFetch", _t)

    _t = reaper.time_precise()
    Fetch.CheckImageFetch()
    _prof("CheckImageFetch", _t)

    _t = reaper.time_precise()
    Fetch.CheckPendingIndexFetch()
    _prof("CheckPendingIndexFetch", _t)

    _t = reaper.time_precise()
    MD.TickParse()
    _prof("TickParse", _t)

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
    if _drag_next_x then
        reaper.ImGui_SetNextWindowPos(ctx, _drag_next_x, _drag_next_y)
        _drag_next_x, _drag_next_y = nil, nil
    end

    -- Recalculate dynamic layout values
    card_w = math.max(100, left_w - PAD_X * 2 - SCROLLBAR_W - SPACING * (COLS - 1))
    logo_h = _logo and math.floor(LOGO_W * _logo.h / _logo.w) or 0

    -- Window style: dark background, rounded corners, no native title bar (custom drawn)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), Colors.grey_dark)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), WIN_ROUNDING)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local visible, _ = reaper.ImGui_Begin(ctx, "DM ReaperToolkit", true,
        reaper.ImGui_WindowFlags_NoTitleBar())
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx)

    if visible then
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

        -- Draw a thin border when the window is focused
        if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
            local wx, wy = reaper.ImGui_GetWindowPos(ctx)
            local ww, wh = reaper.ImGui_GetWindowSize(ctx)
            local draw_list = reaper.ImGui_GetForegroundDrawList(ctx)
            reaper.ImGui_DrawList_AddRect(draw_list, wx, wy, wx + ww, wy + wh, WIN_FOCUS_COLOR, WIN_ROUNDING, nil, 1)
        end

        avail_h = avail_h - DrawTitleBar()

        DrawLeftPanel(avail_h)
        reaper.ImGui_SameLine(ctx, 0, 0)
        local sp_dx = UI.Splitter(ctx, "##splitter", SPLITTER_W, avail_h)
        if sp_dx then
            left_w = math.max(PAD_X * 2 + SCROLLBAR_W + 150, left_w + sp_dx)
        end
        reaper.ImGui_SameLine(ctx, 0, 0)

        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), INSPECTOR_PAD_X, INSPECTOR_PAD_Y)
        reaper.ImGui_BeginChild(ctx, "##detail", 0, avail_h)
        DrawDetailPanel()
        reaper.ImGui_EndChild(ctx)
        reaper.ImGui_PopStyleVar(ctx)

        DrawLicenceGate()
        reaper.ImGui_End(ctx)
    end

    if _open then reaper.defer(loop) end
end

reaper.defer(loop)
