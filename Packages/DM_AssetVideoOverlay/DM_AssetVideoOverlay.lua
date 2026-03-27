-- Requires the ReaImGui extension (install via ReaPack if missing)
if not reaper.ImGui_CreateContext then
    reaper.MB("ReaImGui extension not found.\nInstall it via ReaPack: Extensions > ReaImGui.", "Video Overlay", 0)
    return
end

-- ── Common shared libraries ────────────────────────────────────────────────

local _script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local DEMUTE_ROOT = _script_dir
local COMMON      = DEMUTE_ROOT .. "Common/Scripts/"
dofile(COMMON .. "DM_Colors.lua")
dofile(COMMON .. "DM_Theme.lua")
local DM       = dofile(COMMON .. "DM_Library.lua")
local Settings = dofile(COMMON .. "DM_Settings.lua")

-- ── defaults & config ──────────────────────────────────────────────────────

local SECTION = "VideoOverlay"

local defaults = {
    fx_name     = "Video processor",
    fx_preset   = "Overlay: Text/Timecode",
    x_pos       = 0.02,
    y_pos       = 0.02,
    y_spacing   = 0.01,
    text_size   = 0.03,
    bg_pad      = 0.01,
    text_bright = 1.0,
    bg_bright   = 0.0,
    bg_alpha    = 0.50,
    bg_fit      = 1.0,
    logo_size   = 50.0,
}

-- cfg starts as a copy of defaults, then overwritten by saved state
local cfg = DM.Table.shallow_copy(defaults)

local ctx     = reaper.ImGui_CreateContext("Video Overlay")
local font_ui = reaper.ImGui_CreateFont("sans-serif", Theme.FONT_SIZE)
reaper.ImGui_Attach(ctx, font_ui)

local status      = ""
local track_input = "Montage"

local window_width = 420
local window_height = 660

-- ── settings persistence ───────────────────────────────────────────────────

local function save_settings()
    Settings.Save(SECTION, cfg)
    reaper.SetExtState(SECTION, "track_input", track_input, true)
end

local function load_settings()
    cfg = Settings.Load(SECTION, defaults)
    local ti = reaper.GetExtState(SECTION, "track_input")
    if ti ~= "" then track_input = ti end
end

local function reset_settings()
    cfg = DM.Table.shallow_copy(defaults)
    track_input = "Montage"
    save_settings()
    status = "Reset to defaults."
end

load_settings()

local logo_img, logo_native_w, logo_native_h = DM.Image.LoadDemuteLogo()
if logo_img then reaper.ImGui_Attach(ctx, logo_img) end

-- ── helpers ────────────────────────────────────────────────────────────────

local function ensure_vp(take)
    for j = reaper.TakeFX_GetCount(take) - 1, 0, -1 do
        local _, name = reaper.TakeFX_GetFXName(take, j, "")
        if name:lower():find(cfg.fx_name:lower(), 1, true) then
            reaper.TakeFX_Delete(take, j)
        end
    end
    local fx = reaper.TakeFX_AddByName(take, cfg.fx_name, 1, -1)
    return fx >= 0 and fx or nil
end

local function set_param(take, fx, param_name, value)
    for i = 0, reaper.TakeFX_GetNumParams(take, fx) - 1 do
        local _, name = reaper.TakeFX_GetParamName(take, fx, i, "")
        if name == param_name then
            reaper.TakeFX_SetParam(take, fx, i, value)
            return
        end
    end
end

local function clean_take_name(take)
    local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    local cleaned = name:gsub("%-imported%-?%d*", "")
    if cleaned ~= name then
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", cleaned, true)
    end
end

local function overlaps(a, b)
    return a.start < (b.start + b.len) and b.start < (a.start + a.len)
end

local function get_preset_y(take)
    for j = 0, reaper.TakeFX_GetCount(take) - 1 do
        local _, name = reaper.TakeFX_GetFXName(take, j, "")
        if name:lower():find(cfg.fx_name:lower(), 1, true) then
            local _, preset = reaper.TakeFX_GetPreset(take, j)
            if preset == cfg.fx_preset then
                for p = 0, reaper.TakeFX_GetNumParams(take, j) - 1 do
                    local _, pname = reaper.TakeFX_GetParamName(take, j, p, "")
                    if pname == "y position" then
                        return reaper.TakeFX_GetParam(take, j, p)
                    end
                end
            end
        end
    end
    return nil
end

-- ── apply core ─────────────────────────────────────────────────────────────

local function apply_items(items, undo_label)
    local applying = {}
    for _, e in ipairs(items) do applying[e.item] = true end

    local step = cfg.text_size + cfg.y_spacing

    -- Collect anchors with their ACTUAL ranks read from the FX y position.
    -- This prevents sort-order non-determinism from assigning wrong ranks.
    local anchors = {}
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        if not applying[item] then
            local take = reaper.GetActiveTake(item)
            if take then
                local y = get_preset_y(take)
                if y ~= nil then
                    local rank = (step > 0)
                        and math.max(0, math.floor((y - cfg.y_pos) / step + 0.5))
                        or  0
                    anchors[#anchors + 1] = {
                        item  = item,
                        take  = take,
                        start = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                        len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                        rank  = rank,
                        fixed = true,   -- do not recompute rank in the loop below
                    }
                end
            end
        end
    end

    -- Build unified list and sort by start time
    local all_items = {}
    for _, e in ipairs(anchors) do all_items[#all_items + 1] = e end
    for _, e in ipairs(items)   do all_items[#all_items + 1] = e end
    table.sort(all_items, function(a, b) return a.start < b.start end)

    -- Assign ranks for new items only; anchors keep their fixed rank
    for i, entry in ipairs(all_items) do
        if not entry.fixed then
            local taken = {}

            -- 1. Block ranks from ALL anchors (order independent)
            for _, other in ipairs(all_items) do
                if other.fixed and overlaps(entry, other) then
                    taken[other.rank] = true
                end
            end

            -- 2. Block ranks from ALL already-processed items (fixed OR not)
            for j = 1, i - 1 do
                local other = all_items[j]
                if overlaps(entry, other) then
                    taken[other.rank] = true
                end
            end

            -- 3. Pick first free rank
            local rank = 0
            while taken[rank] do
                rank = rank + 1
            end

            entry.rank = rank
        end
    end

    -- Apply parameters only to the requested items
    reaper.Undo_BeginBlock()
    for _, e in ipairs(items) do
        clean_take_name(e.take)
        local fx = ensure_vp(e.take)
        if fx then
            if cfg.fx_preset ~= "" then
                reaper.TakeFX_SetPreset(e.take, fx, cfg.fx_preset)
            end
            set_param(e.take, fx, "x position",     cfg.x_pos)
            set_param(e.take, fx, "y position",     math.min(cfg.y_pos + e.rank * step, 0.95))
            set_param(e.take, fx, "text height",    cfg.text_size)
            set_param(e.take, fx, "bg pad",         cfg.bg_pad)
            set_param(e.take, fx, "text bright",    cfg.text_bright)
            set_param(e.take, fx, "bg bright",      cfg.bg_bright)
            set_param(e.take, fx, "bg alpha",       cfg.bg_alpha)
            set_param(e.take, fx, "fit bg to text", cfg.bg_fit)
        end
    end
    reaper.Undo_EndBlock(undo_label, -1)
end

-- ── clear ─────────────────────────────────────────────────

local function clear_selected()
    local sel_count = reaper.CountSelectedMediaItems(0)
    if sel_count == 0 then status = "No items selected." return end

    reaper.Undo_BeginBlock()
    for i = 0, sel_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take then
            for j = reaper.TakeFX_GetCount(take) - 1, 0, -1 do
                local _, name = reaper.TakeFX_GetFXName(take, j, "")
                if name:lower():find(cfg.fx_name:lower(), 1, true) then
                    local _, preset = reaper.TakeFX_GetPreset(take, j)
                    if preset == cfg.fx_preset then
                        reaper.TakeFX_Delete(take, j)
                    end
                end
            end
        end
    end
    reaper.Undo_EndBlock("Clear video processors from selected items", -1)
    status = "Cleared from " .. sel_count .. " item(s)."
end

local function clear_track()
    local query = track_input:match("^%s*(.-)%s*$")
    if query == "" then status = "Enter a track name." return end

    local n = reaper.CountTracks(0)

    local matched = {}
    for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(tr, "")
        if name:lower():find(query:lower(), 1, true) then
            matched[tr] = true
        end
    end

    if not next(matched) then
        status = "No track matching '" .. query .. "' found."
        return
    end

    local function in_scope(tr)
        if matched[tr] then return true end
        local parent = reaper.GetParentTrack(tr)
        while parent do
            if matched[parent] then return true end
            parent = reaper.GetParentTrack(parent)
        end
        return false
    end

    for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        if in_scope(tr) then
            for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
                local item = reaper.GetTrackMediaItem(tr, j)
                local take = reaper.GetActiveTake(item)
                if take then
                    for k = reaper.TakeFX_GetCount(take) - 1, 0, -1 do
                        local _, name = reaper.TakeFX_GetFXName(take, k, "")
                        if name:lower():find(cfg.fx_name:lower(), 1, true) then
                            local _, preset = reaper.TakeFX_GetPreset(take, k)
                            if preset == cfg.fx_preset then
                                reaper.TakeFX_Delete(take, k)
                            end
                        end
                    end
                end
            end
        end
    end
end


-- ── apply (selected items) ─────────────────────────────────────────────────

local function apply()
    local sel_count = reaper.CountSelectedMediaItems(0)
    if sel_count == 0 then status = "No items selected." return end

    local items = {}
    for i = 0, sel_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            local take = reaper.GetActiveTake(item)
            if take then
                local _, tname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                if tname ~= "" and tname ~= " " then
                    reaper.ShowConsoleMsg(tname .. "\n")
                    items[#items + 1] = {
                        item  = item,
                        take  = take,
                        start = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                        len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                        rank  = 0,
                    }
                end
            end
        end
    end

    apply_items(items, "Apply video overlays")
    status = "Applied to " .. #items .. " item(s)."
end

-- ── apply (by track name) ──────────────────────────────────────────────────

local function apply_to_track()
    local query = track_input:match("^%s*(.-)%s*$")
    if query == "" then status = "Enter a track name." return end

    local n = reaper.CountTracks(0)

    local matched = {}
    for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(tr, "")
        if name:lower():find(query:lower(), 1, true) then
            matched[tr] = true
        end
    end

    if not next(matched) then
        status = "No track matching '" .. query .. "' found."
        return
    end

    local function in_scope(tr)
        if matched[tr] then return true end
        local parent = reaper.GetParentTrack(tr)
        while parent do
            if matched[parent] then return true end
            parent = reaper.GetParentTrack(parent)
        end
        return false
    end

    local items = {}
    for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        if in_scope(tr) then
            for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
                local item = reaper.GetTrackMediaItem(tr, j)
                local take = reaper.GetActiveTake(item)
                if take then
                    local _, tname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                    if tname ~= "" and tname ~= " " then
                        items[#items + 1] = {
                            item  = item,
                            take  = take,
                            start = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                            len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                            rank  = 0,
                        }
                    end
                end
            end
        end
    end

    if #items == 0 then status = "No items on matching track(s)." return end

    apply_items(items, "Apply video overlays (track)")
    status = "Applied to " .. #items .. " item(s) on track '" .. query .. "'."
end

-- ── helpers ────────────────────────────────────────────────────────────────

local function gray_rgba(b)
    local i = math.floor(math.max(0, math.min(1, b)) * 255)
    return (i * 0x1000000) + (i * 0x10000) + (i * 0x100) + 0xFF
end

-- ── GUI loop ───────────────────────────────────────────────────────────────

local function gui_loop()
    reaper.ImGui_SetNextWindowSize(ctx, window_width, window_height, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_PushFont(ctx, font_ui, Theme.FONT_SIZE)
    Theme.PushWindow(ctx)
    local vis, open = reaper.ImGui_Begin(ctx, "Asset Video Overlay", true, Theme.WindowFlags())
    Theme.PopWindow(ctx)

    if vis then
        Theme.DrawFocusBorder(ctx)
        Theme.PushUI(ctx)

        -- ── Layout ───────────────────────────────────────────────────────────
        local sec_layout = Theme.SectionBegin(ctx, "Layout", true)
        if sec_layout then
            _, cfg.x_pos     = reaper.ImGui_SliderDouble(ctx, "X Position", cfg.x_pos,     0.0, 1.0, "%.3f")
            _, cfg.y_pos     = reaper.ImGui_SliderDouble(ctx, "Y Position", cfg.y_pos,     0.0, 1.0, "%.3f")
            _, cfg.y_spacing = reaper.ImGui_SliderDouble(ctx, "Y Gap",      cfg.y_spacing, 0.0, 0.5, "%.3f")
        end
        Theme.SectionEnd(ctx, sec_layout)

        -- ── Text ─────────────────────────────────────────────────────────────
        local sec_text = Theme.SectionBegin(ctx, "Text", true)
        if sec_text then
            _, cfg.text_size   = reaper.ImGui_SliderDouble(ctx, "Text Size",      cfg.text_size,   0.0, 0.3,  "%.3f")
            _, cfg.text_bright = reaper.ImGui_SliderDouble(ctx, "Text Color##tc", cfg.text_bright, 0.0, 1.0, "%.2f")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_ColorButton(ctx, "##tcp", gray_rgba(cfg.text_bright), reaper.ImGui_ColorEditFlags_NoTooltip(), 20, 20)
        end
        Theme.SectionEnd(ctx, sec_text)

        -- ── Background ───────────────────────────────────────────────────────
        local sec_bg = Theme.SectionBegin(ctx, "Background", true)
        if sec_bg then
            _, cfg.bg_bright = reaper.ImGui_SliderDouble(ctx, "BG Color  ##bc", cfg.bg_bright, 0.0, 1.0, "%.2f")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_ColorButton(ctx, "##bcp", gray_rgba(cfg.bg_bright), reaper.ImGui_ColorEditFlags_NoTooltip(), 20, 20)
            _, cfg.bg_alpha  = reaper.ImGui_SliderDouble(ctx, "BG Alpha", cfg.bg_alpha, 0.0, 1.0, "%.2f")
            _, cfg.bg_pad    = reaper.ImGui_SliderDouble(ctx, "BG Pad",   cfg.bg_pad,   0.0, 1.0, "%.2f")
            local bg_fit_bool = cfg.bg_fit >= 0.5
            _, bg_fit_bool   = reaper.ImGui_Checkbox(ctx, "Fit BG to text", bg_fit_bool)
            cfg.bg_fit = bg_fit_bool and 1.0 or 0.0
        end
        Theme.SectionEnd(ctx, sec_bg)

        -- Reset button above Apply section
        -- ── Apply ────────────────────────────────────────────────────────────
        local sec_apply = Theme.SectionBegin(ctx, "Apply", true)
        if sec_apply then
            _, track_input = reaper.ImGui_InputText(ctx, "Track name##trk", track_input)
            local avail_w  = reaper.ImGui_GetContentRegionAvail(ctx)
            local sp       = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
            if Theme.StyledBtn(ctx, "Apply to track (+ children)", Theme.C.export_btn, Theme.C.export_hov, Theme.C.export_act, avail_w - sp - 100, 0) then
                apply_to_track()
                save_settings()
            end
            reaper.ImGui_SameLine(ctx)
            if Theme.StyledBtn(ctx, "Clear Track", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, -1, 0) then
                clear_track()
            end

            Theme.Separator(ctx)

            local avail_w2 = reaper.ImGui_GetContentRegionAvail(ctx)
            local sp2      = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
            if Theme.StyledBtn(ctx, "Apply to selected items", Theme.C.export_btn, Theme.C.export_hov, Theme.C.export_act, avail_w2 - sp2 - 100, 0) then
                apply()
                save_settings()
            end
            reaper.ImGui_SameLine(ctx)
            if Theme.StyledBtn(ctx, "Clear Selected", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, -1, 0) then
                clear_selected()
            end

            if status ~= "" then
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, status)
            end
        end
        Theme.SectionEnd(ctx, sec_apply)

        -- ── How to use (collapsed by default) ────────────────────────────────
        local sec_how = Theme.SectionBegin(ctx, "How to use", false)
        if sec_how then
            reaper.ImGui_TextDisabled(ctx, "1. Adjust settings above.")
            reaper.ImGui_TextDisabled(ctx, "2a. Enter a track name and click 'Apply to track'.")
            reaper.ImGui_TextDisabled(ctx, "   Child tracks are included automatically.")
            reaper.ImGui_TextDisabled(ctx, "2b. Or select items and click 'Apply to selected items'.")
        end
        Theme.SectionEnd(ctx, sec_how)

        -- Logo (pinned to bottom of window, adapts on resize)
        if logo_img then
            local img_w = 120
            local img_h = (logo_native_w and logo_native_h and logo_native_w > 0)
                          and math.floor(img_w * logo_native_h / logo_native_w)
                          or  math.floor(img_w / 4)

            -- separator (1px) + 2 Spacing() calls ≈ 24px overhead
            local logo_block_h = img_h + 24
            local _, avail_h   = reaper.ImGui_GetContentRegionAvail(ctx)
            if avail_h > logo_block_h then
                reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + avail_h - logo_block_h)
            end

            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)

            local content_w, _ = reaper.ImGui_GetContentRegionAvail(ctx)
            local offset = (content_w - img_w) / 2
            if offset > 0 then
                reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + offset)
            end
            reaper.ImGui_Image(ctx, logo_img, img_w, img_h)
            reaper.ImGui_SameLine(ctx)
            local btn_w = 50
            local rw, _ = reaper.ImGui_GetContentRegionAvail(ctx)
            reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + rw - btn_w)
            reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + img_h / 2 - 10)
            if Theme.StyledBtn(ctx, "Reset##rst", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, btn_w, 0) then
                reset_settings()
            end
        end

        Theme.PopUI(ctx)
        reaper.ImGui_End(ctx)
    end

    reaper.ImGui_PopFont(ctx)

    if open then
        reaper.defer(gui_loop)
    else
        save_settings()  -- save on close
    end
end

reaper.defer(gui_loop)
