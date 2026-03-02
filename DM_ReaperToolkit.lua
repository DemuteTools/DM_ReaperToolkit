---@diagnostic disable: undefined-global

local _dir = debug.getinfo(1, 'S').source:match("^@(.*[/\\])")
dofile(_dir .. "DM_ToolkitFunctionsLibrary.lua")

local packages  = dofile(_dir .. "DM_Packages.lua")
local Fetch     = dofile(_dir .. "DM_AsyncFetch.lua")
local MD        = dofile(_dir .. "DM_Markdown.lua")
local PkgStatus = dofile(_dir .. "DM_PackageStatus.lua")

local CARD_W  = 500
local IMG_H   = 180
local COLS    = 1
local SPACING  = 15
local VSPACING = 15
local PAD_X       = 20
local PAD_Y       = 10
local SCROLLBAR_W = 14   -- added so the scrollbar in ##card_scroll doesn't eat into right PAD_X
local SPLITTER_W  = 6    -- width of the draggable divider between panels
local LOGO_W      = 160  -- rendered width of the bottom logo in pixels; change to resize it
local LOGO_PAD_Y  = 12   -- vertical space above and below the logo
local INSPECTOR_PAD_X = 16   -- horizontal WindowPadding inside the right inspector panel
local INSPECTOR_PAD_Y = 12   -- vertical WindowPadding inside the right inspector panel
local README_PAD_X    = 10   -- extra horizontal indent for the README body
local README_PAD_Y    = 8    -- extra vertical gap above the README body
local left_w      = PAD_X * 2 + CARD_W * COLS + SPACING * (COLS - 1) + SCROLLBAR_W

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
local LOGO_H = _logo and math.floor(LOGO_W * _logo.h / _logo.w) or 0
local _open  = true   -- controlled by our custom close button

local selected    = nil
local first_frame = true
local _drag_next_x, _drag_next_y = nil, nil   -- pending window reposition from drag

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

local function DrawPackageCard(pkg)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local x, y     = reaper.ImGui_GetCursorScreenPos(ctx)

    local thumb = GetThumbnail(pkg)
    if thumb then
        -- Center-crop: compute UVs so the image fills the card without stretching
        local u0, v0, u1, v1 = 0, 0, 1, 1
        if thumb.w > 0 and thumb.h > 0 then
            local card_ar = CARD_W / IMG_H
            local img_ar  = thumb.w / thumb.h
            if img_ar > card_ar then
                -- Image wider than card: crop left/right
                local u = card_ar / img_ar
                u0, u1 = (1 - u) / 2, (1 + u) / 2
            else
                -- Image taller than card: crop top/bottom
                local v = img_ar / card_ar
                v0, v1 = (1 - v) / 2, (1 + v) / 2
            end
        end
        reaper.ImGui_DrawList_AddImageRounded(draw_list, thumb.img,
            x, y, x + CARD_W, y + IMG_H, u0, v0, u1, v1, 0xFFFFFFFF, 6)
    else
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + CARD_W, y + IMG_H, 0x4488CCFF, 6)
    end
    -- Dark bar at top so white title text is always legible
    local TEXT_PAD = 10
    local TEXT_SIZE = 30
    local BAR_H = TEXT_SIZE + TEXT_PAD * 2 + 23  -- extra 23 px to accommodate version/update text below the title
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
        x, y, x + CARD_W, y + BAR_H, 0x000000BB, 0)

    local status = PkgStatus.GetPackageStatus(pkg)
    if status == "installed" then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x + CARD_W - 14, y + 3, x + CARD_W - 3, y + 14, 0x44FF44FF, 3)
        if PkgStatus.IsUpdateAvailable(pkg) then
            local ax = x + CARD_W - 23  -- centre x of the arrow
            reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                ax,     y + 2,
                ax - 4, y + 9,
                ax + 4, y + 9,
                0xFFAA00FF)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
                ax - 1, y + 8, ax + 1, y + 14, 0xFFAA00FF, 0)
        end
    elseif status == "imported" then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x + CARD_W - 14, y + 3, x + CARD_W - 3, y + 14, 0xFF8800FF, 3)
    end

    -- Title text overlaid on the dark bar

    reaper.ImGui_SetCursorScreenPos(ctx, x + TEXT_PAD, y + TEXT_PAD)
    reaper.ImGui_PushFont(ctx, font_big, TEXT_SIZE)
    reaper.ImGui_Text(ctx, pkg.name)
    reaper.ImGui_PopFont(ctx)

    -- Claim the full card area for layout and click detection
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    reaper.ImGui_Dummy(ctx, CARD_W, IMG_H)

    -- Hover / press overlay + outline (drawn on top because draw list is ordered)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local active  = reaper.ImGui_IsItemActive(ctx)
    if active then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + CARD_W, y + IMG_H, 0xFFFFFF1A, 6)
        reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + CARD_W, y + IMG_H, 0xFFFFFFCC, 6, nil, 2)
    elseif hovered then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + CARD_W, y + IMG_H, 0xFFFFFF0D, 6)
        reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + CARD_W, y + IMG_H, 0xFFFFFF99, 6, nil, 1.5)
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    else
        reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + CARD_W, y + IMG_H, 0xFFFFFF33, 6, nil, 1)
    end
end

local function DrawDetailPanel()
    if not selected then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "Select a package to see details.")
        return
    end

    local status     = PkgStatus.GetPackageStatus(selected)
    local inst_label = (status == "installed") and "Reinstall" or "Install"

    -- Header: package name (left) + Website / GitHub / Install buttons (right)
    reaper.ImGui_Spacing(ctx)
    local avail_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
    local btn_pad_x  = 20
    local btn_pad_y  = 10
    local btn_gap    = 8

    local web_label  = "Website"
    local gh_label   = "GitHub"
    local run_label  = "Run"

    -- Push button font before CalcTextSize so widths are accurate for the rendered size
    reaper.ImGui_PushFont(ctx, font_big, 16)

    local web_tw,  _ = reaper.ImGui_CalcTextSize(ctx, web_label)
    local gh_tw,   _ = reaper.ImGui_CalcTextSize(ctx, gh_label)
    local inst_tw, _ = reaper.ImGui_CalcTextSize(ctx, inst_label)
    local web_w      = web_tw  + btn_pad_x * 2
    local gh_w       = gh_tw   + btn_pad_x * 2
    local inst_w     = inst_tw + btn_pad_x * 2

    local run_tw,  _ = reaper.ImGui_CalcTextSize(ctx, run_label)
    local run_w      = run_tw + btn_pad_x * 2

    local has_web    = selected.Website_url ~= nil
    local has_run    = (status == "installed")
    local total_w    = (has_web and (web_w + btn_gap) or 0)
                     + gh_w + btn_gap
                     + (has_run and (run_w + btn_gap) or 0)
                     + inst_w

    reaper.ImGui_PushFont(ctx, font_big, 24)
    reaper.ImGui_Text(ctx, selected.name)
    reaper.ImGui_PopFont(ctx)

    if status == "installed" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55CC55FF)
        local disp_v  = PkgStatus.GetCachedVersion(selected)
        local ver_str = disp_v and (" v" .. disp_v) or ""
        reaper.ImGui_Text(ctx, " ✓ Installed" .. ver_str)
        reaper.ImGui_PopStyleColor(ctx)
    elseif status == "imported" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8800FF)
        reaper.ImGui_Text(ctx, " ⚠ Imported")
        reaper.ImGui_PopStyleColor(ctx)
    end

    reaper.ImGui_SameLine(ctx, avail_w - total_w, 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        Colors.grey)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x777777FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  Colors.grey_mid)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), btn_pad_x, btn_pad_y)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8) -- 👈 add this

    if has_web then
        if reaper.ImGui_Button(ctx, web_label) then
            reaper.CF_ShellExecute(selected.Website_url)
        end
        reaper.ImGui_SameLine(ctx, 0, btn_gap)
    end

    if reaper.ImGui_Button(ctx, gh_label) then
        reaper.CF_ShellExecute(selected.github_url)
    end
    reaper.ImGui_SameLine(ctx, 0, btn_gap)

    if has_run then
        local script_path = PkgStatus.GetScriptPath(selected)
        if reaper.ImGui_Button(ctx, run_label) then
            local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
            if cmd_id ~= 0 then
                reaper.Main_OnCommand(cmd_id, 0)
            else
                reaper.ShowConsoleMsg("[ReaperToolkit] Could not register script: " .. script_path .. "\n")
            end
        end
        reaper.ImGui_SameLine(ctx, 0, btn_gap)
    end

    if reaper.ImGui_Button(ctx, inst_label) then
        ImportReapackRepo(selected.reapack_url, selected.name)
        ---@diagnostic disable-next-line: undefined-global
        InvalidateRepoCache()
        PkgStatus.InvalidateFileCache()
        PkgStatus.InvalidateVersionCache()
    end

    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 3)
    reaper.ImGui_PopFont(ctx)

    if status == "installed" then
        local online_v = PkgStatus.GetOnlineVersion(selected)
        if online_v and PkgStatus.IsUpdateAvailable(selected) then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA00FF)
            reaper.ImGui_Text(ctx, "  \xe2\x86\x91 Update available: v" .. online_v)
            reaper.ImGui_PopStyleColor(ctx)
        end
    end

    reaper.ImGui_Spacing(ctx)

    -- Tab bar styling: larger boxes, larger text, light-grey palette
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FramePadding(),           16, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(),                   Colors.grey)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(),            0x777777FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(),           Colors.grey_mid)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmed(),             Colors.grey)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmedSelected(),     Colors.grey_mid)
    reaper.ImGui_PushFont(ctx, font_big, 16)

    if reaper.ImGui_BeginTabBar(ctx, "##detail_tabs") then
        -- Description tab
        if reaper.ImGui_BeginTabItem(ctx, "Description") then
            reaper.ImGui_Dummy(ctx, 0, README_PAD_Y)
            reaper.ImGui_Indent(ctx, README_PAD_X)

            -- YouTube tutorial thumbnail (if the package has a youtube_url)
            if selected.youtube_url then
                local vid_id = selected.youtube_url:match("[?&]v=([%w_%-]+)")
                if vid_id then
                    local thumb_url = "https://img.youtube.com/vi/" .. vid_id .. "/mqdefault.jpg"
                    Fetch.QueueImageFetch(thumb_url)
                    local entry = Fetch.image_cache[thumb_url]
                    if entry and entry.status == "ready" and entry.img then
                        local tab_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
                        local disp_w = math.min(tab_w, 480)
                        local aspect = (entry.w and entry.w > 0) and (entry.h / entry.w) or (9 / 16)
                        local disp_h = math.floor(disp_w * aspect)

                        -- Capture screen pos before the button for the play-icon overlay
                        local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)

                        reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x22222244)
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x11111133)
                        if reaper.ImGui_ImageButton(ctx, "##yt_thumb", entry.img, disp_w, disp_h) then
                            reaper.CF_ShellExecute(selected.youtube_url)
                        end
                        reaper.ImGui_PopStyleColor(ctx, 3)
                        reaper.ImGui_PopStyleVar(ctx)

                        -- Play-icon overlay (always visible, brighter on hover)
                        local hov = reaper.ImGui_IsItemHovered(ctx)
                        local cx  = bx + disp_w * 0.5
                        local cy  = by + disp_h * 0.5
                        local r   = math.min(disp_w, disp_h) * 0.1
                        local dl2 = reaper.ImGui_GetWindowDrawList(ctx)
                        reaper.ImGui_DrawList_AddCircleFilled(dl2, cx, cy, r,
                            hov and 0x000000BB or 0x00000066)
                        reaper.ImGui_DrawList_AddTriangleFilled(dl2,
                            cx - r * 0.35, cy - r * 0.6,
                            cx + r * 0.7,  cy,
                            cx - r * 0.35, cy + r * 0.6,
                            hov and 0xFFFFFFFF or 0xFFFFFFCC)
                        if hov then
                            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
                        end

                        -- Caption below thumbnail
                        reaper.ImGui_PushFont(ctx, font_big, 12)
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), Colors.grey_mid)
                        reaper.ImGui_Text(ctx, "\xe2\x96\xb6 Watch Tutorial")
                        reaper.ImGui_PopStyleColor(ctx)
                        reaper.ImGui_PopFont(ctx)
                        reaper.ImGui_Spacing(ctx)
                    elseif not (entry and entry.status == "error") then
                        reaper.ImGui_TextDisabled(ctx, "Loading preview...")
                        reaper.ImGui_Spacing(ctx)
                    end
                end
            end

            reaper.ImGui_TextWrapped(ctx, selected.description or "No description yet.")
            reaper.ImGui_Unindent(ctx, README_PAD_X)
            reaper.ImGui_EndTabItem(ctx)
        end

        -- Documentation tab (README)
        if reaper.ImGui_BeginTabItem(ctx, "Documentation") then
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

        reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_PopStyleColor(ctx, 5)
    reaper.ImGui_PopStyleVar(ctx)
end

local function _prof(label, t0)
    local dt = (reaper.time_precise() - t0) * 1000
    if dt > 1 then
        reaper.ShowConsoleMsg(string.format("[PROFILE] %-30s %.2f ms\n", label, dt))
    end
end

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

    if first_frame then
        reaper.ImGui_SetNextWindowSize(ctx, 800, 400, reaper.ImGui_Cond_Always())
        first_frame = false
    end
    if _drag_next_x then
        reaper.ImGui_SetNextWindowPos(ctx, _drag_next_x, _drag_next_y)
        _drag_next_x, _drag_next_y = nil, nil
    end

    -- Window style: dark background, rounded corners, no native title bar (custom drawn)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), Colors.grey_dark)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 10)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local visible, _ = reaper.ImGui_Begin(ctx, "DM ReaperToolkit", true,
        reaper.ImGui_WindowFlags_NoTitleBar())
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx)
    if visible then
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

        -- Keep CARD_W and LOGO_H in sync with the current left panel width
        CARD_W = math.max(100, left_w - PAD_X * 2 - SCROLLBAR_W - SPACING * (COLS - 1))
        LOGO_H = _logo and math.floor(LOGO_W * _logo.h / _logo.w) or 0

        -- Custom title bar (drawn as first window content; replaces native title bar)
        do
            local TITLEBAR_H  = 40
            local tb_font_sz  = 13
            local tb_pad_x    = 10
            local tb_pad_y    = 5
            local tb_gap      = 6
            local support_lbl = "Ask for Support"
            local contact_lbl = "Contact Us"

            local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
            local win_w, _     = reaper.ImGui_GetWindowSize(ctx)

            -- Background rect: top corners rounded to match window, bottom edge flat
            local dl = reaper.ImGui_GetWindowDrawList(ctx)
            reaper.ImGui_DrawList_AddRectFilled(dl,
                win_x, win_y, win_x + win_w, win_y + TITLEBAR_H, Colors.grey, 10)
            reaper.ImGui_DrawList_AddRectFilled(dl,
                win_x, win_y + math.floor(TITLEBAR_H / 2),
                win_x + win_w, win_y + TITLEBAR_H, Colors.grey, 0)

            -- Measure button widths with font pushed (so CalcTextSize is accurate)
            reaper.ImGui_PushFont(ctx, font_big, tb_font_sz)
            local tw_sup = reaper.ImGui_CalcTextSize(ctx, support_lbl)
            local tw_con = reaper.ImGui_CalcTextSize(ctx, contact_lbl)
            local tw_cls = reaper.ImGui_CalcTextSize(ctx, "X")
            local bw_sup = tw_sup + tb_pad_x * 2
            local bw_con = tw_con + tb_pad_x * 2
            local bw_cls = tw_cls + tb_pad_x * 2
            -- total width: buttons + gaps + 8px right margin
            local btns_w = bw_sup + tb_gap + bw_con + tb_gap + bw_cls + 16
            local drag_w = math.max(120, win_w - btns_w)
            local btn_h  = tb_font_sz + tb_pad_y * 2

            -- Invisible button over left/title area — handles window drag
            reaper.ImGui_SetCursorPos(ctx, 0, 0)
            reaper.ImGui_InvisibleButton(ctx, "##tb_drag", drag_w, TITLEBAR_H)
            if reaper.ImGui_IsItemActive(ctx) then
                local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
                _drag_next_x, _drag_next_y = win_x + dx, win_y + dy
            end

            -- Title text rendered on top of the drag area (Text is non-interactive)
            reaper.ImGui_SetCursorPos(ctx, 12, math.floor((TITLEBAR_H - 16) / 2))
            reaper.ImGui_PushFont(ctx, font_big, 16)
            reaper.ImGui_Text(ctx, "DM ReaperToolkit")
            reaper.ImGui_PopFont(ctx)

            -- Button style
            reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
            reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FramePadding(),  tb_pad_x, tb_pad_y)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        Colors.grey_mid)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x777777FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x444444FF)

            -- Buttons: right-aligned, vertically centred in the title bar
            local btn_y = math.floor((TITLEBAR_H - btn_h) / 2)
            reaper.ImGui_SetCursorPos(ctx, drag_w + 8, btn_y)
            if reaper.ImGui_Button(ctx, support_lbl) then
                reaper.CF_ShellExecute("https://www.demute.studio/support")
            end
            reaper.ImGui_SameLine(ctx, 0, tb_gap)
            if reaper.ImGui_Button(ctx, contact_lbl) then
                reaper.CF_ShellExecute("https://www.demute.studio/contact")
            end
            reaper.ImGui_SameLine(ctx, 0, tb_gap)
            -- Close button: red tint on hover
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xCC3333FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x993333FF)
            if reaper.ImGui_Button(ctx, "X##close") then
                _open = false
            end
            reaper.ImGui_PopStyleColor(ctx, 2)

            reaper.ImGui_PopStyleColor(ctx, 3)
            reaper.ImGui_PopStyleVar  (ctx, 2)
            reaper.ImGui_PopFont(ctx)

            -- Advance cursor below the title bar; reduce height budget for children
            reaper.ImGui_SetCursorPos(ctx, 0, TITLEBAR_H)
            avail_h = avail_h - TITLEBAR_H
        end

        local _nsb = reaper.ImGui_WindowFlags_NoScrollbar()      ---@diagnostic disable-line: undefined-global
        local _nsm = reaper.ImGui_WindowFlags_NoScrollWithMouse() ---@diagnostic disable-line: undefined-global
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
        reaper.ImGui_BeginChild(ctx, "##cards", left_w, avail_h, nil, _nsb | _nsm)
        reaper.ImGui_PopStyleVar(ctx)

        local logo_area_h = LOGO_H > 0 and (LOGO_H + LOGO_PAD_Y * 2) or 0
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

            -- vertical gap after each completed row
            if (i - 1) % COLS == COLS - 1 or i == #packages then
                reaper.ImGui_Dummy(ctx, 0, VSPACING)
            end
        end
        reaper.ImGui_EndChild(ctx)  -- ##card_scroll

        if _logo then
            local logo_x = math.floor((left_w - LOGO_W) / 2)
            reaper.ImGui_SetCursorPos(ctx, logo_x, reaper.ImGui_GetCursorPosY(ctx) + LOGO_PAD_Y)
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00000000)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x00000000)
            if reaper.ImGui_ImageButton(ctx, "##logo", _logo.img, LOGO_W, LOGO_H) then
                reaper.CF_ShellExecute("https://www.demute.studio/")
            end
            reaper.ImGui_PopStyleColor(ctx, 3)
            reaper.ImGui_PopStyleVar(ctx)
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
            end
        end

        reaper.ImGui_EndChild(ctx)  -- ##cards

        -- Draggable splitter
        reaper.ImGui_SameLine(ctx, 0, 0)
        local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
        reaper.ImGui_InvisibleButton(ctx, "##splitter", SPLITTER_W, avail_h)
        local sp_hov = reaper.ImGui_IsItemHovered(ctx)
        local sp_act = reaper.ImGui_IsItemActive(ctx)
        if sp_hov or sp_act then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
        end
        if sp_act then
            local dx = reaper.ImGui_GetMouseDelta(ctx)
            left_w = math.max(PAD_X * 2 + SCROLLBAR_W + 150, left_w + dx)
        end
        local sp_col = (sp_hov or sp_act) and 0xFFFFFF88 or 0xFFFFFF33
        local win_dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(win_dl,
            sx + (SPLITTER_W - 2) / 2, sy,
            sx + (SPLITTER_W + 2) / 2, sy + avail_h,
            sp_col, 0)
        reaper.ImGui_SameLine(ctx, 0, 0)

        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), INSPECTOR_PAD_X, INSPECTOR_PAD_Y)
        reaper.ImGui_BeginChild(ctx, "##detail", 0, avail_h)
        DrawDetailPanel()
        reaper.ImGui_EndChild(ctx)
        reaper.ImGui_PopStyleVar(ctx)

        reaper.ImGui_End(ctx)
    end

    if _open then
        reaper.defer(loop)
    end
end

reaper.defer(loop)
