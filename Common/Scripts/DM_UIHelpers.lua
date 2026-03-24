--[[
@version 1.0
@noindex
@description Reusable ImGui UI helpers shared across Demute tools.
--]]

-- DM_UIHelpers.lua
-- Requires Colors (global) to be loaded first via DM_Colors.lua.
-- Usage: UI = dofile(COMMON .. "DM_UIHelpers.lua")

local UI = {}

--- Draw a styled button that manages its own push/pop style lifecycle.
---
--- @param ctx      any       ImGui context
--- @param label    string    Button label; supports "Text##id" for unique IDs
--- @param opts     table|nil Optional style overrides:
---   opts.color    number  Background colour   (default: Colors.grey_mid)
---   opts.hovered  number  Hovered colour      (default: Colors.grey_hover)
---   opts.active   number  Pressed colour      (default: Colors.grey_press)
---   opts.pad_x    number  Horizontal padding  (default: 10)
---   opts.pad_y    number  Vertical padding    (default: 5)
---   opts.rounding number  Corner rounding     (default: 4)
--- @return boolean  true when clicked this frame
function UI.Button(ctx, label, opts)
    opts = opts or {}
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        opts.color   or Colors.grey_mid)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), opts.hovered or Colors.grey_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  opts.active  or Colors.grey_press)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FrameRounding(), opts.rounding or 4)
    reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FramePadding(),  opts.pad_x or 10, opts.pad_y or 5)

    local clicked = reaper.ImGui_Button(ctx, label)

    reaper.ImGui_PopStyleVar  (ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 3)
    return clicked
end

--- Render text in a specific colour, handling its own push/pop lifecycle.
--- Optionally wraps the text in a font push/pop when font and font_size are given.
---
--- @param ctx       any     ImGui context
--- @param text      string  Text to display
--- @param color     number  RGBA colour (use a Colors.* entry)
--- @param font      any|nil ImGui font handle (optional)
--- @param font_size number|nil Font size in pixels (optional, required when font is set)
function UI.TextColored(ctx, text, color, font, font_size)
    if font and font_size then reaper.ImGui_PushFont(ctx, font, font_size) end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopStyleColor(ctx)
    if font and font_size then reaper.ImGui_PopFont(ctx) end
end

--- Render text at a specific font size, handling its own push/pop lifecycle.
---
--- @param ctx       any    ImGui context
--- @param text      string Text to display
--- @param font      any    ImGui font handle
--- @param font_size number Font size in pixels
function UI.TextWithFont(ctx, text, font, font_size)
    reaper.ImGui_PushFont(ctx, font, font_size)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopFont(ctx)
end

--- Draw an image button with configurable overlay colours and optional padding/rounding.
--- Returns true when clicked. Hover cursor must be set by the caller if needed.
---
--- @param ctx  any       ImGui context
--- @param id   string    Widget ID (e.g. "##logo")
--- @param img  any       ImGui image handle
--- @param w    number    Display width in pixels
--- @param h    number    Display height in pixels
--- @param opts table|nil Optional style overrides:
---   opts.color      number   Background colour        (default: Colors.transparent)
---   opts.hovered    number   Hovered bg colour        (default: Colors.transparent)
---   opts.active     number   Pressed bg colour        (default: Colors.transparent)
---   opts.pad_x      number   Horizontal padding       (default: 0)
---   opts.pad_y      number   Vertical padding         (default: 0)
---   opts.rounding   number   Corner rounding          (default: 0)
---   opts.three_state boolean REAPER toolbar strip     (default: false)
---                            When true, the image is a horizontal 3-slice strip
---                            [normal | highlighted | active] and UV coords are
---                            chosen per frame based on hover/active state.
--- @return boolean  true when clicked this frame
function UI.ImageButton(ctx, id, img, w, h, opts)
    opts = opts or {}
    local pad_x    = opts.pad_x    or 0
    local pad_y    = opts.pad_y    or 0
    local rounding = opts.rounding or 0

    if opts.three_state then
        local bx, by  = reaper.ImGui_GetCursorScreenPos(ctx)
        local total_w = w + pad_x * 2
        local total_h = h + pad_y * 2

        local clicked = reaper.ImGui_InvisibleButton(ctx, id, total_w, total_h)
        local is_hov  = reaper.ImGui_IsItemHovered(ctx)
        local is_act  = reaper.ImGui_IsItemActive(ctx)

        local bg_col = is_act and (opts.active  or Colors.transparent)
                    or is_hov and (opts.hovered or Colors.transparent)
                    or            (opts.color   or Colors.transparent)
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl,
            bx, by, bx + total_w, by + total_h, bg_col, rounding)

        -- UV slice: strip is [normal(0..1/3) | highlighted(1/3..2/3) | active(2/3..1)]
        local uv0_x = is_act and (2/3) or (is_hov and (1/3) or 0)
        local uv1_x = is_act and  1    or (is_hov and (2/3) or (1/3))
        reaper.ImGui_DrawList_AddImage(dl, img,
            bx + pad_x, by + pad_y,
            bx + pad_x + w, by + pad_y + h,
            uv0_x, 0, uv1_x, 1, 0xFFFFFFFF)

        return clicked
    else
        reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FrameRounding(), rounding)
        reaper.ImGui_PushStyleVar  (ctx, reaper.ImGui_StyleVar_FramePadding(),  pad_x, pad_y)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        opts.color   or Colors.transparent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), opts.hovered or Colors.transparent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  opts.active  or Colors.transparent)

        local clicked = reaper.ImGui_ImageButton(ctx, id, img, w, h)

        reaper.ImGui_PopStyleColor(ctx, 3)
        reaper.ImGui_PopStyleVar  (ctx, 2)
        return clicked
    end
end

--- Draw a vertical draggable splitter line between two panels.
--- Call between SameLine pairs. Returns the mouse x-delta when dragged, nil otherwise.
--- The caller is responsible for clamping and applying the delta to the panel width.
---
--- @param ctx any    ImGui context
--- @param id  string Widget ID (e.g. "##splitter")
--- @param w   number Width of the invisible hit area in pixels
--- @param h   number Height of the splitter in pixels (usually avail_h)
--- @return number|nil  x-delta when actively dragged, nil otherwise
function UI.Splitter(ctx, id, w, h)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, id, w, h)
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local act = reaper.ImGui_IsItemActive(ctx)
    if hov or act then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
    end
    local col = (hov or act) and Colors.white_mid or Colors.white_ghost
    local dl  = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl,
        sx + (w - 2) / 2, sy,
        sx + (w + 2) / 2, sy + h,
        col, 0)
    return act and reaper.ImGui_GetMouseDelta(ctx) or nil
end

--- Draw a centered play-icon (circle + triangle) overlay on the last-drawn image button.
--- Call immediately after UI.ImageButton so IsItemHovered still refers to that button.
--- Also sets the hand cursor when hovered.
---
--- @param ctx any    ImGui context
--- @param bx  number Screen x of the button's top-left corner
--- @param by  number Screen y of the button's top-left corner
--- @param w   number Button display width in pixels
--- @param h   number Button display height in pixels
function UI.PlayIconOverlay(ctx, bx, by, w, h)
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local cx  = bx + w * 0.5
    local cy  = by + h * 0.5
    local r   = math.min(w, h) * 0.1
    local dl  = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, r,
        hov and Colors.black_smoke or Colors.black_glass)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
        cx - r * 0.35, cy - r * 0.6,
        cx + r * 0.7,  cy,
        cx - r * 0.35, cy + r * 0.6,
        hov and Colors.white or Colors.white_bright)
    if hov then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end
end

return UI