---@diagnostic disable: undefined-global, need-check-nil, undefined-field

-- DM_SubprojectManager.lua
-- Lists every unique subproject in the session with instance counts.
-- Select a subproject to view/navigate instances, rename it, or export its
-- sliced WAVs directly from the pre-rendered .rpp-PROX file.

-- ─── Common shared libraries ───────────────────────────────────────────────

local _script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local DEMUTE_ROOT = _script_dir
local COMMON      = DEMUTE_ROOT .. "Common/Scripts/"
dofile(COMMON .. "DM_Colors.lua")
dofile(COMMON .. "DM_Theme.lua")
local DM = dofile(COMMON .. "DM_Library.lua")

-- ─── Context & Fonts ───────────────────────────────────────────────────────

local ctx     = reaper.ImGui_CreateContext("DM Subproject Manager")
local font_ui = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font_ui)

-- ─── Logo ────────────────────────────────────────────────────────────────

local LOGO_W     = 120
local LOGO_PAD_Y = 8

local logo = nil
do
    local img, lw, lh = DM.Image.LoadDemuteLogo()
    if img then
        reaper.ImGui_Attach(ctx, img)
        if not lw then lw, lh = 4, 1 end
        logo = { img = img, w = lw, h = lh }
    end
end

-- ─── Colours ────────────────────────────────────────────────────────────────
-- Alias the shared palette so all existing C.* references keep working.

local C = Theme.C

-- ─── State ─────────────────────────────────────────────────────────────────

local subprojects  = {}
local selected_set = {}   -- { [idx] = true } for every highlighted row
local primary_idx  = 0    -- last-clicked row; drives detail panel + Rename
local open         = true

local renaming     = false
local rename_buf   = ""
local rename_err   = ""
local rename_focus = false

local export_msg    = ""
local export_is_err = false

local confirm_delete      = false   -- triggers OpenPopup on next frame
local delete_pending_list = {}      -- snapshot of sps to delete

local add_open       = false    -- triggers Add Subproject popup
local add_name_buf   = ""
local add_path_buf   = ""      -- destination folder for the .rpp file
local add_has_vars   = false
local add_num_vars   = 1
local add_sound_len  = 1.0
local add_copy_video = false
local add_pre_entry  = 0.0
local add_err        = ""
local add_focus      = false

local EXT_SECTION      = "DM_SubprojectManager"
local EXT_KEY_OUT      = "last_export_folder"
local export_path_buf  = reaper.GetExtState(EXT_SECTION, EXT_KEY_OUT)
local search_buf       = ""


local function parse_rpp(rpp_path)
    local f = io.open(rpp_path, "r")
    if not f then return nil, 0 end

    local markers  = {}
    local proj_end = 0.0
    local item_pos = 0

    for line in f:lines() do
        local pos = line:match("^%s*MARKER%s+%d+%s+([%d%.]+)%s+%S")
        if pos then
            local is_region = line:match("^%s*MARKER%s+%d+%s+[%d%.]+%s+[%d%.]+%s+\"")
            if not is_region then
                markers[#markers + 1] = { pos = tonumber(pos) }
            end
        end
        local p = line:match("^%s*POSITION%s+([%d%.]+)")
        if p then item_pos = tonumber(p) or item_pos end
        local l = line:match("^%s*LENGTH%s+([%d%.]+)")
        if l then
            local e = item_pos + tonumber(l)
            if e > proj_end then proj_end = e end
        end
    end

    f:close()
    table.sort(markers, function(a, b) return a.pos < b.pos end)

    return markers, proj_end
end

-- ─── Export ────────────────────────────────────────────────────────────────

local function PickFolder(default_path)
    return DM.File.PickFolder(default_path, "Select export output folder")
end

local RENDER_TAIL_S = 0.1   -- seconds added to each item/region end (captures reverb tails)
local ITEM_GAP_S    = 0.5   -- gap between successive items on the temp track

local function ExportSubprojects(sp_list, out_folder)
    if #sp_list == 0 then return false, "Nothing to export." end

    reaper.RecursiveCreateDirectory(out_folder, 0)

    -- Parse all subprojects up front; collect jobs = { sp, segments }
    local jobs = {}
    for _, sp in ipairs(sp_list) do
        if sp.path ~= "" and #sp.items > 0 then
            local markers, proj_end = parse_rpp(sp.path)
            if markers then
                local segments = {}
                if #markers < 2 then
                    segments[1] = { start = 0, stop = proj_end, idx = 1 }
                else
                    for m = 1, #markers - 1 do
                        local s, e = markers[m].pos, markers[m + 1].pos
                        if e > s then
                            segments[#segments + 1] = { start = s, stop = e, idx = m }
                        end
                    end
                end
                if #segments > 0 then
                    jobs[#jobs + 1] = { sp = sp, segments = segments }
                end
            end
        end
    end

    if #jobs == 0 then return false, "No valid segments found in any subproject." end

    -- Save render settings and track mute states
    local _, old_file    = reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    "", false)
    local _, old_pattern = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
    local old_bounds     = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)

    local n_tracks    = reaper.CountTracks(0)
    local track_mutes = {}
    for i = 0, n_tracks - 1 do
        track_mutes[i] = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "B_MUTE")
    end

    local temp_track     = nil
    local region_ids     = {}
    local old_rgn_matrix = {}
    local total_files    = 0

    local function cleanup()
        if temp_track then reaper.DeleteTrack(temp_track) end
        for _, rid in ipairs(region_ids) do
            reaper.DeleteProjectMarker(0, rid, true)
        end
        local master = reaper.GetMasterTrack(0)
        for _, entry in ipairs(old_rgn_matrix) do
            reaper.SetRegionRenderMatrix(0, entry.rid, master, 1)
        end
        for i = 0, n_tracks - 1 do
            local t = reaper.GetTrack(0, i)
            if t then reaper.SetMediaTrackInfo_Value(t, "B_MUTE", track_mutes[i]) end
        end
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    old_file,    true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", old_pattern, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", old_bounds, true)
    end

    local pcall_ok, pcall_err = pcall(function()
        reaper.PreventUIRefresh(1)

        local master = reaper.GetMasterTrack(0)

        -- Strip Master Mix from ALL existing regions
        local num_markers = reaper.CountProjectMarkers(0)
        for i = 0, num_markers - 1 do
            local _, isrgn, _, _, _, rid = reaper.EnumProjectMarkers(i)
            if isrgn then
                local trk_idx = 0
                while true do
                    local trk = reaper.EnumRegionRenderMatrix(0, rid, trk_idx)
                    if not trk then break end
                    if trk == master then
                        old_rgn_matrix[#old_rgn_matrix + 1] = { rid = rid }
                        break
                    end
                    trk_idx = trk_idx + 1
                end
                reaper.SetRegionRenderMatrix(0, rid, master, -1)
            end
        end

        -- Mute all existing tracks, then create temp track (unmuted)
        for i = 0, n_tracks - 1 do
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "B_MUTE", 1)
        end
        reaper.InsertTrackAtIndex(n_tracks, true)
        temp_track = reaper.GetTrack(0, n_tracks)
        reaper.GetSetMediaTrackInfo_String(temp_track, "P_NAME", "[DM Render]", true)

        -- Place all variations from all subprojects sequentially on the temp track
        local cursor_pos = 0

        for _, job in ipairs(jobs) do
            local sp       = job.sp
            local segments = job.segments
            local ref_src  = reaper.GetMediaItemTake_Source(
                reaper.GetActiveTake(sp.items[1].item))

            for _, seg in ipairs(segments) do
                local seg_len  = seg.stop - seg.start
                local item_len = seg_len
                local take_name = (#segments == 1) and sp.name
                    or (sp.name .. "_" .. string.format("%02d", seg.idx))

                local new_item = reaper.AddMediaItemToTrack(temp_track)
                local new_take = reaper.AddTakeToMediaItem(new_item)
                reaper.SetMediaItemTake_Source(new_take, ref_src)
                reaper.SetMediaItemInfo_Value(new_item, "D_POSITION",      cursor_pos)
                reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", seg.start)
                reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH",        item_len)
                reaper.SetMediaItemInfo_Value(new_item, "D_VOL",           1.0)
                reaper.SetMediaItemInfo_Value(new_item, "D_PITCH",         0.0)
                reaper.SetMediaItemInfo_Value(new_item, "B_MUTE",          0)
                reaper.SetMediaItemTakeInfo_Value(new_take, "D_VOL",       1.0)
                reaper.SetMediaItemTakeInfo_Value(new_take, "D_PITCH",     0.0)
                reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", take_name, true)
                for fx = reaper.TakeFX_GetCount(new_take) - 1, 0, -1 do
                    reaper.TakeFX_Delete(new_take, fx)
                end

                local rid = reaper.AddProjectMarker2(0, true,
                    cursor_pos, cursor_pos + item_len, take_name, -1, 0)
                reaper.SetRegionRenderMatrix(0, rid, master, 1)
                region_ids[#region_ids + 1] = rid

                total_files = total_files + 1
                cursor_pos  = cursor_pos + item_len + ITEM_GAP_S
            end
        end

        reaper.TrackList_AdjustWindows(false)
        reaper.UpdateArrange()
        reaper.PreventUIRefresh(-1)

        -- Single render pass for all regions
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE",    out_folder, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$region",  true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 3, true)
        reaper.Main_OnCommand(41824, 0)
    end)

    cleanup()
    reaper.UpdateArrange()

    if not pcall_ok then
        return false, "Render error: " .. tostring(pcall_err)
    end
    return true, string.format("%d file(s) → %s", total_files, out_folder)
end

-- ─── Delete ────────────────────────────────────────────────────────────────

local function DeleteSubprojects(sp_list)
    local names = {}
    for _, sp in ipairs(sp_list) do names[#names + 1] = sp.name end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    for _, sp in ipairs(sp_list) do
        for _, inst in ipairs(sp.items) do
            local track = reaper.GetMediaItemTrack(inst.item)
            if track then reaper.DeleteTrackMediaItem(track, inst.item) end
        end
        if sp.path ~= "" then
            os.remove(sp.path)
            os.remove(sp.path .. "-PROX")
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.MarkProjectDirty(0)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Delete subproject(s): " .. table.concat(names, ", "), -1)
end

-- ─── Create Subproject ────────────────────────────────────────────────────

local function CreateSubprojectRPP(name, sp_dir, has_vars, num_vars, sound_len, pre_entry, video_info)
    if not sp_dir or sp_dir == "" then
        return nil, "Set a destination path first."
    end
    reaper.RecursiveCreateDirectory(sp_dir, 0)

    local rpp_path = sp_dir .. "\\" .. name .. ".rpp"
    if DM.File.Exists(rpp_path) then
        return nil, '"' .. name .. '.rpp" already exists.'
    end

    local vars      = has_vars and num_vars or 1
    local total_len = pre_entry + vars * sound_len

    -- Build .rpp content
    local lines = {}
    local function L(s) lines[#lines + 1] = s end

    L('<REAPER_PROJECT 0.1 "7.22/win64" ' .. tostring(os.time()))
    L('  SAMPLERATE 48000 0 0')
    L('  TEMPO 120 4 4')

    -- Variation markers: N+1 markers for N variations
    for m = 0, vars do
        local mpos = pre_entry + m * sound_len
        local mname = ""
        if m == 0 then
            mname = "=START"
        elseif m == vars then
            mname = "=END"
        end
        L(string.format('  MARKER %d %.10f "%s" 0', m, mpos, mname))
    end

    -- Video track (optional, not routed to master)
    if video_info and video_info.path ~= "" then
        local video_offset = video_info.cursor - video_info.item_pos
        L('  <TRACK {00000000-0000-0000-0000-000000000001}')
        L('    NAME "Video"')
        L('    MAINSEND 0')
        L('    <ITEM')
        L('      POSITION 0')
        L(string.format('      LENGTH %.10f', total_len))
        L(string.format('      SOFFS %.10f', math.max(0, video_offset)))
        L('      <SOURCE VIDEO')
        L('        FILE "' .. video_info.path:gsub('\\', '\\\\') .. '"')
        L('      >')
        L('    >')
        L('  >')
    end

    -- MIX bus track with 3 sub tracks
    L('  <TRACK {00000000-0000-0000-0000-000000000010}')
    L('    NAME "MIX"')
    L('    ISBUS 1 1')
    L('    BUSCOMP 1 0 -1 -1 0')
    L('  >')
    L('  <TRACK {00000000-0000-0000-0000-000000000011}')
    L('    NAME "SFX"')
    L('    ISBUS 0 0')
    L('  >')
    L('  <TRACK {00000000-0000-0000-0000-000000000012}')
    L('    NAME "SFX"')
    L('    ISBUS 0 0')
    L('  >')
    L('  <TRACK {00000000-0000-0000-0000-000000000013}')
    L('    NAME "SFX"')
    L('    ISBUS 2 -1')
    L('    BUSCOMP 2 0 -1 -1 0')
    L('  >')

    L('>')

    if not DM.File.WriteAll(rpp_path, table.concat(lines, "\n") .. "\n") then
        return nil, "Failed to write file."
    end
    return rpp_path, total_len
end

local function PlaceSubprojectItem(rpp_path, name, sound_len)
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
        return false, "No track selected."
    end

    local cursor_pos = DM.Track.GetPosition()

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local item = reaper.AddMediaItemToTrack(track)
    local take = reaper.AddTakeToMediaItem(item)
    local src  = reaper.PCM_Source_CreateFromFile(rpp_path)

    reaper.SetMediaItemTake_Source(take, src)
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name .. ".rpp", true)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", cursor_pos)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", sound_len)

    reaper.PreventUIRefresh(-1)
    reaper.MarkProjectDirty(0)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Add subproject: " .. name, -1)
    return true
end

-- ─── Rename ────────────────────────────────────────────────────────────────

local function RenameSubproject(sp, new_name)
    new_name = new_name:gsub("^%s*(.-)%s*$", "%1")

    if new_name == ""       then return false, "Name cannot be empty." end
    if new_name == sp.name  then return false, "Name is unchanged." end
    if new_name:match('[/\\:*?"<>|]') then return false, "Name contains invalid characters." end
    if sp.path == "" then return false, "No file path — cannot rename." end

    local dir      = sp.path:match("^(.*)[/\\]") or "."
    local new_path = dir .. "\\" .. new_name .. ".rpp"

    local existing = io.open(new_path, "rb")
    if existing then existing:close()
        return false, '"' .. new_name .. '.rpp" already exists.'
    end

    local ok, err = os.rename(sp.path, new_path)
    if not ok then return false, "File rename failed: " .. (err or "?") end

    local old_prox = sp.path .. "-PROX"
    local pchk = io.open(old_prox, "rb")
    if pchk then pchk:close() os.rename(old_prox, new_path .. "-PROX") end

    reaper.Undo_BeginBlock()
    for _, inst in ipairs(sp.items) do
        local take = reaper.GetActiveTake(inst.item)
        if take then
            local new_src = reaper.PCM_Source_CreateFromFile(new_path)
            if new_src then
                reaper.SetMediaItemTake_Source(take, new_src)
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name .. ".rpp", true)
            end
        end
    end
    reaper.Undo_EndBlock("Rename subproject: " .. sp.name .. " → " .. new_name, -1)

    reaper.MarkProjectDirty(0)
    reaper.UpdateArrange()
    return true
end

-- ─── Scan ──────────────────────────────────────────────────────────────────

local function ScanProject()
    local map   = {}
    local order = {}

    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take then
            local src       = reaper.GetMediaItemTake_Source(take)
            local fpath     = src and reaper.GetMediaSourceFileName(src, "") or ""
            local take_name = reaper.GetTakeName(take) or ""
            local is_rpp    = fpath:lower():match("%.rpp$") or take_name:lower():match("%.rpp$")

            if is_rpp then
                local key  = (fpath ~= "" and fpath) or take_name
                local name = key:match("([^/\\]+)%.rpp$") or key

                local pos      = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local track    = reaper.GetMediaItemTrack(item)
                local _, tname = reaper.GetTrackName(track)

                if not map[key] then
                    local vars = 1
                    if fpath ~= "" then
                        local mkrs = parse_rpp(fpath)
                        if mkrs then vars = math.max(1, #mkrs > 1 and #mkrs - 1 or #mkrs) end
                    end
                    map[key] = { path = fpath, name = name, items = {}, variations = vars }
                    order[#order + 1] = key
                end
                map[key].items[#map[key].items + 1] = {
                    item = item, pos = pos, track_name = tname or "?",
                }
            end
        end
    end

    for _, entry in pairs(map) do
        table.sort(entry.items, function(a, b) return a.pos < b.pos end)
    end
    table.sort(order, function(a, b) return map[a].name:lower() < map[b].name:lower() end)

    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = map[k] end
    return out
end

-- ─── Navigate ──────────────────────────────────────────────────────────────

local function JumpToItem(item, pos)
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetEditCurPos(pos, true, false)
    reaper.Main_OnCommand(40913, 0)
    reaper.UpdateArrange()
end

local function UpdateREAPERSelection()
    reaper.SelectAllMediaItems(0, false)
    for idx in pairs(selected_set) do
        local sp = subprojects[idx]
        if sp then
            for _, inst in ipairs(sp.items) do
                reaper.SetMediaItemSelected(inst.item, true)
            end
        end
    end
    if primary_idx > 0 and subprojects[primary_idx] then
        local first = subprojects[primary_idx].items[1]
        if first then
            reaper.SetEditCurPos(first.pos, true, false)
            reaper.Main_OnCommand(40913, 0)
        end
    end
    reaper.UpdateArrange()
end

-- ─── UI helpers ────────────────────────────────────────────────────────────

local function StyledBtn(label, col, hov, act, w, h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  act)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
    local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
    reaper.ImGui_PopStyleVar  (ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 3)
    return clicked
end

local function DisabledBtn(disabled, label, col, hov, act, w, h)
    if disabled then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = StyledBtn(label, col, hov, act, w, h)
    if disabled then reaper.ImGui_EndDisabled(ctx) end
    return clicked
end

local function PushInputStyle()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        C.input_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), C.input_bg_hov)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
end

local function PopInputStyle()
    reaper.ImGui_PopStyleVar  (ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 2)
end

local function PushListStyle()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),       C.child_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        C.item_hl)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), C.item_hl_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  C.item_hl_act)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_ChildRounding(), 4)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_ItemSpacing(),   4, 2)
end

local function PopListStyle()
    reaper.ImGui_PopStyleVar  (ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 4)
end

local function StyledSeparator()
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), C.separator)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
end

local function ResetUIState()
    renaming   = false
    rename_err = ""
    export_msg = ""
    add_err    = ""
end

local function FormatTime(secs)
    return DM.Time.Format(secs)
end

-- ─── Initial scan ──────────────────────────────────────────────────────────

subprojects = ScanProject()

-- ─── Render: Toolbar ───────────────────────────────────────────────────────

local function RenderToolbar(sel_count, sel_sp, has_path, one_sel)
    if StyledBtn("Refresh", C.accent, C.accent_hov, C.accent_act) then
        subprojects  = ScanProject()
        selected_set = {}
        primary_idx  = 0
        ResetUIState()
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if StyledBtn("Add##addbtn", C.confirm, C.confirm_hov, C.confirm_act) then
        add_open       = true
        add_name_buf   = ""
        add_has_vars   = false
        add_num_vars   = 1
        add_sound_len  = 1.0
        add_copy_video = false
        add_pre_entry  = 0.0
        add_err        = ""
        add_focus      = true
        -- Default path: <media_dir>\SubProjects
        local media_dir = reaper.GetProjectPath("")
        add_path_buf = (media_dir and media_dir ~= "") and (media_dir .. "\\SubProjects") or ""
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if DisabledBtn(#subprojects == 0, "Select All##selall", C.cancel, C.cancel_hov, C.cancel_act) then
        selected_set = {}
        for i = 1, #subprojects do selected_set[i] = true end
        primary_idx = 1
        ResetUIState()
        UpdateREAPERSelection()
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if DisabledBtn(not one_sel, renaming and "Cancel##ren" or "Rename", C.cancel, C.cancel_hov, C.cancel_act) then
        if renaming then
            renaming   = false
            rename_err = ""
        else
            renaming     = true
            rename_buf   = sel_sp and sel_sp.name or ""
            rename_err   = ""
            rename_focus = true
            export_msg   = ""
        end
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if DisabledBtn(not one_sel, "Open##openbtn", C.accent, C.accent_hov, C.accent_act) then
        reaper.Main_OnCommand(40859, 0)
        reaper.Main_openProject("noprompt:" .. sel_sp.path)
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if DisabledBtn(sel_count == 0, "Export##expbtn", C.export_btn, C.export_hov, C.export_act) then
        renaming   = false
        rename_err = ""
        local out_folder = export_path_buf:gsub("^%s*(.-)%s*$", "%1")
        if out_folder == "" then
            export_msg    = "Set an export path first."
            export_is_err = true
        else
            local sp_list = {}
            for idx in pairs(selected_set) do
                local sp = subprojects[idx]
                if sp and sp.path ~= "" then
                    sp_list[#sp_list + 1] = sp
                end
            end
            local ok, msg = ExportSubprojects(sp_list, out_folder)
            -- Rescan so item references are fresh after temp track deletion
            subprojects = ScanProject()
            if ok then
                export_msg    = msg
                export_is_err = false
            else
                export_msg    = msg or "?"
                export_is_err = true
            end
        end
    end

    reaper.ImGui_SameLine(ctx, 0, 8)

    if DisabledBtn(sel_count == 0, "Delete##delbtn", C.cancel, C.cancel_hov, C.cancel_act) then
        delete_pending_list = {}
        for idx in pairs(selected_set) do
            local sp = subprojects[idx]
            if sp then delete_pending_list[#delete_pending_list + 1] = sp end
        end
        confirm_delete = true
    end

    -- Summary text
    reaper.ImGui_SameLine(ctx, 0, 10)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    if #subprojects == 0 then
        reaper.ImGui_Text(ctx, "No subprojects found.")
    else
        local total = 0
        for _, sp in ipairs(subprojects) do total = total + #sp.items end
        reaper.ImGui_Text(ctx, ("%d subproject(s)   %d instance(s) total"):format(#subprojects, total))
    end
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Export path row
    reaper.ImGui_Spacing(ctx)
    local ep_avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local browse_w = 64

    PushInputStyle()
    reaper.ImGui_SetNextItemWidth(ctx, ep_avail - browse_w - 8)
    local ep_changed, ep_new = reaper.ImGui_InputText(ctx, "##export_path", export_path_buf)
    if ep_changed then
        export_path_buf = ep_new
        reaper.SetExtState(EXT_SECTION, EXT_KEY_OUT, export_path_buf, true)
        export_msg = ""
    end
    PopInputStyle()

    reaper.ImGui_SameLine(ctx, 0, 6)
    if StyledBtn("Browse##expbrowse", C.cancel, C.cancel_hov, C.cancel_act, browse_w) then
        local picked = PickFolder(export_path_buf ~= "" and export_path_buf or nil)
        if picked then
            export_path_buf = picked
            reaper.SetExtState(EXT_SECTION, EXT_KEY_OUT, export_path_buf, true)
            export_msg = ""
        end
    end

    -- Export status line
    if export_msg ~= "" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            export_is_err and C.text_err or C.text_good)
        reaper.ImGui_Text(ctx, (export_is_err and "  ✕  " or "  ✓  ") .. export_msg)
        reaper.ImGui_PopStyleColor(ctx, 1)
    end
end

-- ─── Render: Rename Panel ──────────────────────────────────────────────────

local function RenderRenamePanel(sel_sp)
    if not (renaming and sel_sp) then return end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.rename_bg)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_ChildRounding(), 4)
    reaper.ImGui_BeginChild    (ctx, "##rename_panel", 0, 54)

    reaper.ImGui_Spacing(ctx)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local btn_w   = 74

    PushInputStyle()
    reaper.ImGui_SetNextItemWidth(ctx, avail_w - btn_w - 10)

    if rename_focus then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        rename_focus = false
    end

    local changed, new_buf = reaper.ImGui_InputText(ctx, "##rename_input", rename_buf)
    if changed then rename_buf = new_buf; rename_err = "" end

    local confirm_enter = reaper.ImGui_IsItemFocused(ctx)
                       and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
    PopInputStyle()

    reaper.ImGui_SameLine(ctx, 0, 6)
    local do_rename = StyledBtn("Apply##renok", C.confirm, C.confirm_hov, C.confirm_act, btn_w)

    if (do_rename or confirm_enter) and sel_sp then
        local ok, err = RenameSubproject(sel_sp, rename_buf)
        if ok then
            renaming     = false
            rename_err   = ""
            subprojects  = ScanProject()
            selected_set = {}
            primary_idx  = 0
            local trimmed = rename_buf:gsub("^%s*(.-)%s*$", "%1")
            for i, sp in ipairs(subprojects) do
                if sp.name == trimmed then
                    selected_set = {[i] = true}
                    primary_idx  = i
                    break
                end
            end
        else
            rename_err = err or "Unknown error."
        end
    end

    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleVar  (ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 1)

    if rename_err ~= "" then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_err)
        reaper.ImGui_Text(ctx, "  " .. rename_err)
        reaper.ImGui_PopStyleColor(ctx, 1)
    end
end

-- ─── Render: Search Bar ────────────────────────────────────────────────────

local function RenderSearchBar()
    PushInputStyle()
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local changed, new_val = reaper.ImGui_InputTextWithHint(ctx, "##search", "Search...", search_buf)
    PopInputStyle()
    if changed then search_buf = new_val end
    reaper.ImGui_Spacing(ctx)
    return search_buf:lower()
end

-- ─── Render: Subproject List ───────────────────────────────────────────────

local function RenderSubprojectList(search_lc, list_h)
    PushListStyle()
    reaper.ImGui_BeginChild(ctx, "##splist", 0, list_h)

    for i, sp in ipairs(subprojects) do
        if search_lc ~= "" and not sp.name:lower():find(search_lc, 1, true) then
            goto continue
        end

        local is_sel  = selected_set[i] == true
        local start_x = reaper.ImGui_GetCursorPosX(ctx)
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)

        if reaper.ImGui_Selectable(ctx, sp.name .. "##sp" .. i, is_sel, 0, 0, 0) then
            local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl())
                      or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
            if ctrl then
                if selected_set[i] then
                    selected_set[i] = nil
                    if primary_idx == i then primary_idx = next(selected_set) or 0 end
                else
                    selected_set[i] = true
                    primary_idx     = i
                end
            else
                selected_set = {[i] = true}
                primary_idx  = i
            end
            ResetUIState()
            UpdateREAPERSelection()
        end

        local badge = string.format("%dv  ×%d", sp.variations, #sp.items)
        local bw, _ = reaper.ImGui_CalcTextSize(ctx, badge)
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetCursorPosX(ctx, start_x + avail_w - bw - 4)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.count_text)
        reaper.ImGui_Text(ctx, badge)
        reaper.ImGui_PopStyleColor(ctx, 1)
        ::continue::
    end

    reaper.ImGui_EndChild(ctx)
    PopListStyle()
end

-- ─── Render: Logo ──────────────────────────────────────────────────────────

local function LogoHeight()
    if not logo then return 0 end
    return math.floor(LOGO_W * logo.h / logo.w) + LOGO_PAD_Y * 2
end

local function RenderLogo()
    if not logo then return end
    local logo_h  = math.floor(LOGO_W * logo.h / logo.w)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local logo_x  = math.floor((avail_w - LOGO_W) / 2)
    reaper.ImGui_Dummy(ctx, 0, LOGO_PAD_Y)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + logo_x)
    reaper.ImGui_Image(ctx, logo.img, LOGO_W, logo_h)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if reaper.ImGui_IsItemClicked(ctx) then
        reaper.CF_ShellExecute("https://www.demute.studio/")
    end
end

-- ─── Render: Detail Panel ──────────────────────────────────────────────────

local function RenderDetailPanel()
    local sp = subprojects[primary_idx]
    if not sp then return end

    StyledSeparator()

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, ("%d instance(s)  ·  %d variation(s)  —  %s"):format(
        #sp.items, sp.variations, sp.name))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)

    local _, detail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    detail_h = detail_h - LogoHeight()

    PushListStyle()
    reaper.ImGui_BeginChild(ctx, "##spdetail", 0, math.max(20, detail_h))

    for j, inst in ipairs(sp.items) do
        local label = string.format("%d.  [%s]   @ %s##inst%d",
            j, inst.track_name, FormatTime(inst.pos), j)
        if reaper.ImGui_Selectable(ctx, label, false, 0, 0, 0) then
            JumpToItem(inst.item, inst.pos)
        end
    end

    reaper.ImGui_EndChild(ctx)
    PopListStyle()
end

-- ─── Video Detection ──────────────────────────────────────────────────────

local VIDEO_EXTS = { mp4=1, mov=1, avi=1, mkv=1, webm=1, wmv=1 }

local function FindVideoAtCursor()
    local cursor = DM.Track.GetPosition()
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if pos <= cursor and (pos + len) > cursor then
            local take = reaper.GetActiveTake(item)
            if take then
                local src = reaper.GetMediaItemTake_Source(take)
                if src then
                    local fpath = reaper.GetMediaSourceFileName(src, "")
                    local ext   = fpath:match("%.([^%.]+)$")
                    if ext and VIDEO_EXTS[ext:lower()] then
                        return {
                            path     = fpath,
                            item_pos = pos,
                            cursor   = cursor,
                        }
                    end
                end
            end
        end
    end
    return nil
end

-- ─── Main Loop ─────────────────────────────────────────────────────────────

local function Loop()
    if not open then return end

    reaper.ImGui_PushFont(ctx, font_ui, 14)

    reaper.ImGui_SetNextWindowSize           (ctx, 480, 460, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 300, 240, 1000, 1000)
    Theme.PushWindow(ctx)
    local visible, p_open = reaper.ImGui_Begin(
        ctx, "Subproject Manager##dm_spov", true, Theme.WindowFlags())
    Theme.PopWindow(ctx)

    if not p_open then open = false end

    if visible then
        Theme.DrawFocusBorder(ctx)
        local sel_count = 0
        for _ in pairs(selected_set) do sel_count = sel_count + 1 end
        local has_sel  = primary_idx >= 1 and primary_idx <= #subprojects
        local sel_sp   = has_sel and subprojects[primary_idx] or nil
        local has_path = sel_sp ~= nil and sel_sp.path ~= ""
        local one_sel  = sel_count == 1 and has_path

        RenderToolbar(sel_count, sel_sp, has_path, one_sel)
        RenderRenamePanel(sel_sp)
        StyledSeparator()

        local logo_reserve = LogoHeight()

        if #subprojects == 0 then
            RenderLogo()
        else
            local search_lc = RenderSearchBar()
            local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
            avail_h = avail_h - logo_reserve
            local list_h = math.max(40, has_sel and math.floor(avail_h * 0.52) or avail_h)

            RenderSubprojectList(search_lc, list_h)
            if has_sel then RenderDetailPanel() end
            RenderLogo()
        end

        -- ── Delete confirmation popup ───────────────────────────────────────
        if confirm_delete then
            reaper.ImGui_OpenPopup(ctx, "Delete Subprojects?##delpopup")
            confirm_delete = false
        end

        reaper.ImGui_SetNextWindowSize(ctx, 340, 0, reaper.ImGui_Cond_Always())
        if reaper.ImGui_BeginPopupModal(ctx, "Delete Subprojects?##delpopup", nil,
                reaper.ImGui_WindowFlags_NoResize()) then

            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_err)
            reaper.ImGui_Text(ctx, "This will permanently delete:")
            reaper.ImGui_PopStyleColor(ctx, 1)
            reaper.ImGui_Spacing(ctx)

            for _, sp in ipairs(delete_pending_list) do
                reaper.ImGui_Bullet(ctx)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, sp.name .. ".rpp")
                if sp.path ~= "" then
                    reaper.ImGui_SameLine(ctx, 0, 6)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
                    local inst_count = #sp.items
                    reaper.ImGui_Text(ctx, string.format("(%d instance%s)",
                        inst_count, inst_count == 1 and "" or "s"))
                    reaper.ImGui_PopStyleColor(ctx, 1)
                end
            end

            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
            reaper.ImGui_Text(ctx, "File deletion cannot be undone.")
            reaper.ImGui_PopStyleColor(ctx, 1)
            reaper.ImGui_Spacing(ctx)

            local btn_w = 100
            if StyledBtn("Delete##delconfirm", C.cancel, C.cancel_hov, C.cancel_act, btn_w) then
                reaper.ImGui_CloseCurrentPopup(ctx)
                DeleteSubprojects(delete_pending_list)
                delete_pending_list = {}
                subprojects  = ScanProject()
                selected_set = {}
                primary_idx  = 0
                ResetUIState()
            end
            reaper.ImGui_SameLine(ctx, 0, 8)
            if StyledBtn("Cancel##delcancel", C.accent, C.accent_hov, C.accent_act, btn_w) then
                reaper.ImGui_CloseCurrentPopup(ctx)
                delete_pending_list = {}
            end

            reaper.ImGui_EndPopup(ctx)
        end

        -- ── Add Subproject popup ─────────────────────────────────────────
        if add_open then
            reaper.ImGui_OpenPopup(ctx, "Add Subproject##addpopup")
            add_open = false
        end

        reaper.ImGui_SetNextWindowSize(ctx, 380, 0, reaper.ImGui_Cond_Always())
        if reaper.ImGui_BeginPopupModal(ctx, "Add Subproject##addpopup", nil,
                reaper.ImGui_WindowFlags_NoResize()) then

            -- Name
            reaper.ImGui_Text(ctx, "Subproject Name")
            PushInputStyle()
            reaper.ImGui_SetNextItemWidth(ctx, -1)
            if add_focus then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                add_focus = false
            end
            local name_chg, name_new = reaper.ImGui_InputText(ctx, "##add_name", add_name_buf)
            if name_chg then add_name_buf = name_new; add_err = "" end
            PopInputStyle()
            reaper.ImGui_Spacing(ctx)

            -- Destination Path
            reaper.ImGui_Text(ctx, "Destination Folder")
            local browse_w = 64
            PushInputStyle()
            reaper.ImGui_SetNextItemWidth(ctx, -browse_w - 8)
            local path_chg, path_new = reaper.ImGui_InputText(ctx, "##add_path", add_path_buf)
            if path_chg then add_path_buf = path_new; add_err = "" end
            PopInputStyle()
            reaper.ImGui_SameLine(ctx, 0, 6)
            if StyledBtn("Browse##addbrowse", C.cancel, C.cancel_hov, C.cancel_act, browse_w) then
                local picked = PickFolder(add_path_buf ~= "" and add_path_buf or nil)
                if picked then add_path_buf = picked; add_err = "" end
            end
            reaper.ImGui_Spacing(ctx)

            -- Has Variations
            local var_chg, var_new = reaper.ImGui_Checkbox(ctx, "Has Variations", add_has_vars)
            if var_chg then add_has_vars = var_new end

            -- Number of Variations
            if not add_has_vars then reaper.ImGui_BeginDisabled(ctx) end
            reaper.ImGui_Text(ctx, "Number of Variations")
            PushInputStyle()
            reaper.ImGui_SetNextItemWidth(ctx, -1)
            local nv_chg, nv_new = reaper.ImGui_InputInt(ctx, "##add_numvars", add_num_vars)
            if nv_chg then add_num_vars = math.max(1, nv_new) end
            PopInputStyle()
            if not add_has_vars then reaper.ImGui_EndDisabled(ctx) end
            reaper.ImGui_Spacing(ctx)

            -- Sound Length
            reaper.ImGui_Text(ctx, "Sound Length per Variation (sec)")
            PushInputStyle()
            reaper.ImGui_SetNextItemWidth(ctx, -1)
            local sl_chg, sl_new = reaper.ImGui_InputDouble(ctx, "##add_soundlen", add_sound_len, 0.1, 1.0, "%.2f")
            if sl_chg then add_sound_len = math.max(0.01, sl_new) end
            PopInputStyle()
            reaper.ImGui_Spacing(ctx)

            -- Pre-Entry Length
            reaper.ImGui_Text(ctx, "Pre-Entry Length (sec)")
            PushInputStyle()
            reaper.ImGui_SetNextItemWidth(ctx, -1)
            local pe_chg, pe_new = reaper.ImGui_InputDouble(ctx, "##add_preentry", add_pre_entry, 0.1, 1.0, "%.2f")
            if pe_chg then add_pre_entry = math.max(0.0, pe_new) end
            PopInputStyle()
            reaper.ImGui_Spacing(ctx)

            -- Copy Current Video
            local vc_chg, vc_new = reaper.ImGui_Checkbox(ctx, "Copy Current Video", add_copy_video)
            if vc_chg then add_copy_video = vc_new end
            reaper.ImGui_Spacing(ctx)

            -- Error
            if add_err ~= "" then
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_err)
                reaper.ImGui_Text(ctx, "  " .. add_err)
                reaper.ImGui_PopStyleColor(ctx, 1)
                reaper.ImGui_Spacing(ctx)
            end

            -- Buttons
            local btn_w = 100
            if StyledBtn("Create##addconfirm", C.confirm, C.confirm_hov, C.confirm_act, btn_w) then
                local trimmed = add_name_buf:gsub("^%s*(.-)%s*$", "%1")
                local vars_count = add_has_vars and add_num_vars or 1

                if trimmed == "" then
                    add_err = "Name cannot be empty."
                elseif trimmed:match('[/\\:*?"<>|]') then
                    add_err = "Name contains invalid characters."
                elseif add_sound_len <= 0 then
                    add_err = "Sound length must be greater than 0."
                elseif add_has_vars and add_num_vars < 1 then
                    add_err = "Need at least 1 variation."
                elseif not reaper.GetSelectedTrack(0, 0) then
                    add_err = "No track selected."
                else
                    local video_info = nil
                    if add_copy_video then
                        video_info = FindVideoAtCursor()
                        if not video_info then
                            add_err = "No video item found at cursor."
                        end
                    end

                    if add_err == "" then
                        local sp_dir = add_path_buf:gsub("^%s*(.-)%s*$", "%1")
                        local rpp_path, result2 = CreateSubprojectRPP(
                            trimmed, sp_dir, add_has_vars, vars_count,
                            add_sound_len, add_pre_entry, video_info)

                        if not rpp_path then
                            add_err = result2
                        else
                            local ok, place_err = PlaceSubprojectItem(rpp_path, trimmed, add_sound_len)
                            if not ok then
                                add_err = place_err
                            else
                                reaper.ImGui_CloseCurrentPopup(ctx)
                                subprojects  = ScanProject()
                                selected_set = {}
                                primary_idx  = 0
                                for i, sp in ipairs(subprojects) do
                                    if sp.name == trimmed then
                                        selected_set = {[i] = true}
                                        primary_idx  = i
                                        break
                                    end
                                end
                                ResetUIState()
                            end
                        end
                    end
                end
            end

            reaper.ImGui_SameLine(ctx, 0, 8)
            if StyledBtn("Cancel##addcancel", C.cancel, C.cancel_hov, C.cancel_act, btn_w) then
                reaper.ImGui_CloseCurrentPopup(ctx)
            end

            reaper.ImGui_EndPopup(ctx)
        end

        reaper.ImGui_End(ctx)
    end

    reaper.ImGui_PopFont(ctx)
    if open then reaper.defer(Loop) end
end

reaper.defer(Loop)
