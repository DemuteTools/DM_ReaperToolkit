---@diagnostic disable: undefined-global

-- DM_Theme.lua
-- Shared window-level and widget styling for all Demute tools (reaper.ImGui_* API).
-- Requires DM_Colors.lua to be loaded first (Colors global must exist).
--
-- Usage pattern:
--   dofile(COMMON .. "DM_Theme.lua")
--   local font_ui = reaper.ImGui_CreateFont("sans-serif", Theme.FONT_SIZE)
--   reaper.ImGui_Attach(ctx, font_ui)
--   ...
--   function Loop()
--       reaper.ImGui_PushFont(ctx, font_ui, Theme.FONT_SIZE)
--       Theme.PushWindow(ctx)
--       local vis, open = reaper.ImGui_Begin(ctx, "My Tool", true, Theme.WindowFlags())
--       Theme.PopWindow(ctx)
--       if vis then
--           Theme.PushUI(ctx)
--           ... widgets ...
--           Theme.PopUI(ctx)
--           reaper.ImGui_End(ctx)
--       end
--       reaper.ImGui_PopFont(ctx)
--   end

-- ─── Font size constants ────────────────────────────────────────────────────

Theme = {
    FONT_SIZE    = 14,   -- standard body text
    FONT_SIZE_SM = 12,   -- small / dim annotations

    -- ─── Semantic color palette (0xRRGGBBAA) ─────────────────────────────
    -- All tools share this table.  DM_SubProjectManager aliases it as local C.
    C = {
        -- Window chrome
        bg           = 0x1A1A1AFF,   -- window background
        border       = 0xFFFFFF1A,   -- window & child border (~10% white)
        separator    = 0xFFFFFF0D,   -- horizontal rules  (~5% white)
        titlebar     = 0x000000FF,   -- title bar inactive (black)
        titlebar_act = 0x404040FF,   -- title bar focused

        -- Panels / child windows
        child_bg     = 0x222222FF,   -- child-window background
        rename_bg    = 0x222222FF,   -- alias used by SubProjectManager
        input_bg     = 0x2A2A2AFF,   -- InputText / FrameBg
        input_bg_hov = 0x363636FF,   -- FrameBgHovered
        input_bg_act = 0x424242FF,   -- FrameBgActive

        -- Selectables / list headers
        item_hl      = 0x4A4A4AFF,   -- Header idle
        item_hl_hov  = 0x3A3A3AFF,   -- Header hovered
        item_hl_act  = 0x555555FF,   -- Header active

        -- Buttons — accent blue (primary action / default)
        accent       = 0x4488CCFF,
        accent_hov   = 0x5599DDFF,
        accent_act   = 0x2E6699FF,

        -- Buttons — confirm green (apply / OK)
        confirm      = 0x3A8A3AFF,
        confirm_hov  = 0x4AAA4AFF,
        confirm_act  = 0x2A6A2AFF,

        -- Buttons — export teal (write to disk / apply to track)
        export_btn   = 0x15856DFF,
        export_hov   = 0x2E9E86FF,
        export_act   = 0x006C54FF,

        -- Buttons — cancel grey (secondary / destructive / reset)
        cancel       = 0x555555FF,
        cancel_hov   = 0x777777FF,
        cancel_act   = 0x444444FF,

        -- Focus
        focus_border = 0xFFFFFF30,   -- thin white outline when window is focused

        -- Text
        text         = 0xEEEEEEFF,
        text_dim     = 0x888888FF,
        count_text   = 0x888888FF,   -- alias used by SubProjectManager
        text_good    = 0x55CC55FF,
        text_err     = 0xFF4444FF,
    },
}

-- ─── Window-level push / pop ────────────────────────────────────────────────
-- 5 colors + 2 vars.  Call immediately before reaper.ImGui_Begin().
-- Pop immediately after Begin() — the titlebar/bg values only need to be
-- set at Begin time; they don't need to stay on the stack during content.

function Theme.PushWindow(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),         Theme.C.bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),            Theme.C.border)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),           Theme.C.titlebar)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),     Theme.C.titlebar_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgCollapsed(),  Theme.C.titlebar)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_WindowRounding(),   10)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_WindowPadding(),    16, 6)
end

function Theme.PopWindow(ctx)
    reaper.ImGui_PopStyleVar  (ctx, 3)
    reaper.ImGui_PopStyleColor(ctx, 5)
end

-- Standard window flags shared by all Demute tools.
function Theme.WindowFlags()
    return 0
end

-- Draw a thin white border around the window when focused.
-- Call once inside the window, immediately after Begin().
function Theme.DrawFocusBorder(ctx)
    if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
        local wx, wy = reaper.ImGui_GetWindowPos(ctx)
        local ww, wh = reaper.ImGui_GetWindowSize(ctx)
        local dl = reaper.ImGui_GetForegroundDrawList(ctx)
        reaper.ImGui_DrawList_AddRect(dl, wx, wy, wx + ww, wy + wh, Theme.C.focus_border, 10, nil, 2)
    end
end

-- ─── Widget-level push / pop ────────────────────────────────────────────────
-- 12 colors + 4 vars.  Call once inside the window after ImGui_Begin().
-- Covers: FrameBg family, Button (default = accent-blue), SliderGrab,
-- Header/Selectable, CheckMark, FrameRounding, GrabRounding, FramePadding,
-- ItemSpacing.
-- Override individual buttons with Theme.StyledBtn() for semantic colours.

function Theme.PushUI(ctx)
    -- Input / frame backgrounds
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        Theme.C.input_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), Theme.C.input_bg_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  Theme.C.input_bg_act)
    -- Default buttons → accent blue
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),         Theme.C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  Theme.C.accent_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   Theme.C.accent_act)
    -- Slider grab
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),       Theme.C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), Theme.C.accent_hov)
    -- Selectables / combo / list headers
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        Theme.C.item_hl)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), Theme.C.item_hl_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  Theme.C.item_hl_act)
    -- Checkmark
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), Theme.C.accent)
    -- Shape / spacing
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),  4)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  5, 3)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),   7, 4)
end

function Theme.PopUI(ctx)
    reaper.ImGui_PopStyleVar  (ctx, 4)
    reaper.ImGui_PopStyleColor(ctx, 12)
end

-- ─── Styled button ──────────────────────────────────────────────────────────
-- Temporarily overrides button colours for a single button, then restores.
-- col/hov/act: use Theme.C.accent/confirm/export_btn/cancel families.
-- w, h: optional pixel dimensions (0 = auto-size).
-- Returns true when clicked.

function Theme.StyledBtn(ctx, label, col, hov, act, w, h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  act)
    local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
    reaper.ImGui_PopStyleColor(ctx, 3)
    return clicked
end

-- ─── Panel / child-window helpers ───────────────────────────────────────────
-- Sets child background and corner rounding around BeginChild / EndChild.

function Theme.PushPanel(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), Theme.C.child_bg)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_ChildRounding(), 4)
end

function Theme.PopPanel(ctx)
    reaper.ImGui_PopStyleVar  (ctx)
    reaper.ImGui_PopStyleColor(ctx)
end

-- ─── Styled separator ───────────────────────────────────────────────────────

function Theme.Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), Theme.C.separator)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
end

-- ─── Collapsible section card ────────────────────────────────────────────────
-- Wraps a CollapsingHeader + content in a BeginGroup/EndGroup, then draws a
-- border outline whose x extents match the header's rendered background exactly.
-- Always call SectionEnd even when SectionBegin returns false (collapsed).
--
-- Usage:
--   local open = Theme.SectionBegin(ctx, "My Section", true)
--   if open then ... widgets ... end
--   Theme.SectionEnd(ctx, open)

Theme._sx0, Theme._sx1 = 0, 0  -- internal: header x extents for border drawing

function Theme.SectionBegin(ctx, label, default_open)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        Theme.C.child_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), Theme.C.titlebar_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x494949FF)
    reaper.ImGui_BeginGroup(ctx)
    if default_open ~= nil then
        reaper.ImGui_SetNextItemOpen(ctx, default_open, reaper.ImGui_Cond_Once())
    end
    local open = reaper.ImGui_CollapsingHeader(ctx, label)
    Theme._sx0, _ = reaper.ImGui_GetItemRectMin(ctx)
    Theme._sx1, _ = reaper.ImGui_GetItemRectMax(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    if open then
        reaper.ImGui_Dummy(ctx, 0, 3)
        reaper.ImGui_Indent(ctx, 8)
    end
    return open
end

function Theme.SectionEnd(ctx, open)
    if open then
        reaper.ImGui_Unindent(ctx, 8)
        reaper.ImGui_Dummy(ctx, 0, 4)
    end
    reaper.ImGui_EndGroup(ctx)
    local _, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRect(dl, Theme._sx0, y0, Theme._sx1, y1, Theme.C.border, 4)
end
