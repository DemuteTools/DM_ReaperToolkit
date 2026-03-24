--[[
@version 1.0
@noindex
@description Markdown parser and renderer for Reaper Toolkit README display
--]]

local M = {}

local _ctx, _font_big, _font_h2

-- Parse state per key: { co=coroutine, tokens={}, status="parsing"|"done" }
local _parse_state   = {}
local LINES_PER_TICK = 100   -- lines processed per frame tick
local LINK_COL       = 0xFFCC66FF  -- AABBGGRR: light gold for links
local _scroll_target = nil         -- slug string to scroll to on next frame

-- Convert heading text to a GitHub-style anchor slug
local function to_slug(text)
    return text:lower():gsub("[^%w%s%-]", ""):gsub("%s+", "-")
end

local function open_url(url)
    if reaper.CF_ShellExecute then
        reaper.CF_ShellExecute(url)
    else
        os.execute('start "" "' .. url .. '"')
    end
end

function M.Init(ctx, font_big, font_h2)
    _ctx = ctx; _font_big = font_big; _font_h2 = font_h2
end

-- Strip inline markdown markers from a string (used for headings / table cells)
local function strip(s)
    s = s:gsub("!%[.-%]%((.-)%)", "")
    s = s:gsub("%[(.-)%]%((.-)%)", "%1")
    s = s:gsub("%*%*(.-)%*%*", "%1")
    s = s:gsub("__(.-)__",     "%1")
    s = s:gsub("%*(.-)%*",     "%1")
    s = s:gsub("_(.-)_",       "%1")
    s = s:gsub("`(.-)`",       "%1")
    return s
end

-- Parse a string into an array of { t=string, bold=bool, link=string|nil } spans.
-- Bold is **...** or __...__; link is [text](url).
local function parse_spans(s)
    -- Strip image markers and code spans up front
    s = s:gsub("!%[.-%]%((.-)%)", "")
    s = s:gsub("`(.-)`", "%1")

    -- First pass: split by links to preserve URLs
    local chunks = {}  -- { text=string, link=string|nil }
    local pos = 1
    while pos <= #s do
        local lb = s:find("[", pos, true)
        if not lb then
            chunks[#chunks + 1] = { text = s:sub(pos) }
            break
        end
        -- Find matching ](url)
        local re = s:find("%]%(", lb + 1)
        if not re then
            chunks[#chunks + 1] = { text = s:sub(pos) }
            break
        end
        local ue = s:find(")", re + 2, true)
        if not ue then
            chunks[#chunks + 1] = { text = s:sub(pos) }
            break
        end
        if lb > pos then
            chunks[#chunks + 1] = { text = s:sub(pos, lb - 1) }
        end
        local link_text = s:sub(lb + 1, re - 1)
        local link_url  = s:sub(re + 2, ue - 1)
        chunks[#chunks + 1] = { text = link_text, link = link_url }
        pos = ue + 1
    end

    -- Second pass: parse bold within each chunk
    local spans = {}
    for _, chunk in ipairs(chunks) do
        local cs = chunk.text
        local cpos = 1
        while cpos <= #cs do
            local b1, e1 = cs:find("%*%*(.-)%*%*", cpos)
            local b2, e2 = cs:find("__(.-)__",     cpos)

            local bs, be, is_star
            if b1 and (not b2 or b1 < b2) then
                bs, be, is_star = b1, e1, true
            elseif b2 then
                bs, be, is_star = b2, e2, false
            end

            if bs then
                if bs > cpos then
                    local pre = cs:sub(cpos, bs - 1):gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
                    if pre ~= "" then
                        spans[#spans + 1] = { t = pre, bold = false, link = chunk.link }
                    end
                end
                local inner = is_star and cs:match("%*%*(.-)%*%*", bs) or cs:match("__(.-)__", bs)
                inner = inner:gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
                if inner ~= "" then
                    spans[#spans + 1] = { t = inner, bold = true, link = chunk.link }
                end
                cpos = be + 1
            else
                local rest = cs:sub(cpos):gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
                if rest ~= "" then
                    spans[#spans + 1] = { t = rest, bold = false, link = chunk.link }
                end
                break
            end
        end
    end
    return #spans > 0 and spans or { { t = s, bold = false } }
end

local function spans_need_custom(spans)
    for _, sp in ipairs(spans) do
        if sp.bold or sp.link then return true end
    end
    return false
end

local function spans_to_text(spans)
    local t = {}
    for _, sp in ipairs(spans) do t[#t + 1] = sp.t end
    return table.concat(t)
end

-- Draw a thick horizontal rule spanning the content width.
local function draw_thick_separator()
    local dl      = reaper.ImGui_GetWindowDrawList(_ctx)
    local sx, sy  = reaper.ImGui_GetCursorScreenPos(_ctx)
    local avail_w = reaper.ImGui_GetContentRegionAvail(_ctx)
    local col     = reaper.ImGui_GetStyleColor(_ctx, reaper.ImGui_Col_Separator())
    reaper.ImGui_DrawList_AddLine(dl, sx, sy + 1, sx + avail_w, sy + 1, col, 3)
    reaper.ImGui_Dummy(_ctx, 0, 4)
end

-- Simulate bold weight by drawing text twice: once normally, once shifted 1px right.
local function draw_bold(text)
    local cx, cy = reaper.ImGui_GetCursorPos(_ctx)
    reaper.ImGui_Text(_ctx, text)
    reaper.ImGui_SetCursorPos(_ctx, cx + 1, cy)
    reaper.ImGui_Text(_ctx, text)
end

-- Render spans word-by-word, handling bold and clickable links.
local function render_word_wrapped_spans(spans)
    if not spans_need_custom(spans) then
        reaper.ImGui_TextWrapped(_ctx, spans_to_text(spans))
        return
    end

    local space_w    = reaper.ImGui_CalcTextSize(_ctx, " ")
    local left_x     = reaper.ImGui_GetCursorPosX(_ctx)
    local right_edge = left_x + reaper.ImGui_GetContentRegionAvail(_ctx)

    local words = {}
    for _, sp in ipairs(spans) do
        for word in sp.t:gmatch("%S+") do
            words[#words + 1] = { w = word, bold = sp.bold, link = sp.link }
        end
    end
    if #words == 0 then return end

    local cur_x    = left_x
    local is_first = true

    for _, wt in ipairs(words) do
        local word_w = reaper.ImGui_CalcTextSize(_ctx, wt.w)
        if is_first then
            is_first = false
        elseif cur_x + space_w + word_w <= right_edge then
            reaper.ImGui_SameLine(_ctx, 0, space_w)
            cur_x = cur_x + space_w
        else
            cur_x = left_x  -- wrapped: next word starts at left margin
        end

        if wt.link then
            reaper.ImGui_PushStyleColor(_ctx, reaper.ImGui_Col_Text(), LINK_COL)
            reaper.ImGui_Text(_ctx, wt.w)
            reaper.ImGui_PopStyleColor(_ctx)
            if reaper.ImGui_IsItemHovered(_ctx) then
                reaper.ImGui_SetMouseCursor(_ctx, reaper.ImGui_MouseCursor_Hand())
                if reaper.ImGui_IsItemClicked(_ctx) then
                    if wt.link:match("^https?://") then
                        open_url(wt.link)
                    elseif wt.link:match("^#") then
                        _scroll_target = wt.link:sub(2)
                    end
                end
            end
        elseif wt.bold then
            draw_bold(wt.w)
        else
            reaper.ImGui_Text(_ctx, wt.w)
        end
        cur_x = cur_x + word_w
    end
end

-- Start an async (coroutine-based) parse for the given key.
-- tokens is filled incrementally; the coroutine yields every LINES_PER_TICK lines.
function M.StartParse(key, text, base_raw_url)
    if _parse_state[key] then return end  -- already started or done

    local tokens = {}

    local co = coroutine.create(function()
        local in_code    = false
        local in_table   = nil   -- nil or { k="tbl", headers={}, rows={}, ncols=N }
        local line_count = 0

        for line in (text .. "\n"):gmatch("([^\n]*)\n") do

            -- Code fence
            if line:match("^```") then
                in_code = not in_code
                if in_table then
                    tokens[#tokens + 1] = in_table
                    in_table = nil
                end
                tokens[#tokens + 1] = { k = "sp" }
                goto continue
            end
            if in_code then
                tokens[#tokens + 1] = { k = "dis", t = "  " .. line }
                goto continue
            end

            -- Flush table if the current line is not a table row
            if in_table and not line:match("^|") then
                tokens[#tokens + 1] = in_table
                in_table = nil
            end

            -- Remaining cases all declare locals. Wrap in do..end so that the
            -- early goto continue (above) does not jump over any local declarations.
            -- Gotos inside this block jump OUT to ::continue:: below, which is valid.
            do
                -- Headings (any level via #+ prefix)
                local h_marks, h_txt = line:match("^(#+)%s+(.+)")
                if h_marks then
                    local level = #h_marks
                    tokens[#tokens + 1] = { k = "sp" }
                    if level == 1 then
                        tokens[#tokens + 1] = { k = "h1",  t = strip(h_txt) }
                        tokens[#tokens + 1] = { k = "sep" }
                    elseif level == 2 then
                        tokens[#tokens + 1] = { k = "h2",  t = strip(h_txt) }
                    else
                        tokens[#tokens + 1] = { k = "h3",  t = strip(h_txt) }
                    end
                    goto continue
                end

                -- Table separator  |---|---|  → skip
                if line:match("^|[%s%-:|]+|") then goto continue end

                -- Table row  |cell|cell|
                do
                    local trow = line:match("^|(.+)|%s*$")
                    if trow then
                        local cells = {}
                        for cell in trow:gmatch("[^|]+") do
                            cells[#cells + 1] = cell:match("^%s*(.-)%s*$") or ""
                        end
                        if not in_table then
                            in_table = { k = "tbl", headers = cells,
                                         rows = {}, ncols = #cells }
                        else
                            while #cells < in_table.ncols do
                                cells[#cells + 1] = ""
                            end
                            in_table.rows[#in_table.rows + 1] = cells
                        end
                        goto continue
                    end
                end

                -- Horizontal rule  ---  ***
                if line:match("^%-%-%-+%s*$") or line:match("^%*%*%*+%s*$") then
                    tokens[#tokens + 1] = { k = "sep" }
                    goto continue
                end

                -- Blockquote
                do
                    local bq = line:match("^>%s*(.+)")
                    if bq then
                        tokens[#tokens + 1] = { k = "bq", spans = parse_spans(bq) }
                        goto continue
                    end
                end

                -- Unordered list  - / * / +
                do
                    local ul_sp   = line:match("^(%s*)[%-%*%+] ")
                    local ul_text = line:match("^%s*[%-%*%+] (.+)")
                    if ul_text then
                        tokens[#tokens + 1] = { k = "li", prefix = "- ",
                                                spans  = parse_spans(ul_text),
                                                indent = 10 + #ul_sp * 4 }
                        goto continue
                    end
                end

                -- Ordered list  1. / 2. etc.
                do
                    local num, ol = line:match("^%s*(%d+)%. (.+)")
                    if ol then
                        tokens[#tokens + 1] = { k = "li", prefix = num .. ". ",
                                                spans  = parse_spans(ol),
                                                indent = 10 }
                        goto continue
                    end
                end

                -- Markdown image  ![alt](path)
                do
                    local alt, path = line:match("^!%[(.-)%]%((.-)%)")
                    if alt and path and base_raw_url then
                        path = path:gsub("^%./", "")
                        tokens[#tokens + 1] = { k = "img", alt = alt,
                                                url = base_raw_url .. path }
                        goto continue
                    end
                end

                -- HTML img tag  <img ... src="..." ... />
                if line:match("<img") then
                    local src = line:match('src="(https?://[^"]+)"')
                    if src then
                        tokens[#tokens + 1] = {
                            k       = "img",
                            alt     = line:match('alt="([^"]*)"') or "image",
                            url     = src,
                            fixed_w = tonumber(line:match('width="(%d+)"')),
                            fixed_h = tonumber(line:match('height="(%d+)"')),
                        }
                        goto continue
                    end
                end

                -- Empty line
                if line:match("^%s*$") then
                    tokens[#tokens + 1] = { k = "sp" }
                    goto continue
                end

                -- Regular paragraph
                tokens[#tokens + 1] = { k = "par", spans = parse_spans(line) }
            end  -- do: all locals above are now out of scope at ::continue::

            ::continue::

            line_count = line_count + 1
            if line_count % LINES_PER_TICK == 0 then
                coroutine.yield()
            end
        end
        -- Flush any pending table at end of input
        if in_table then
            tokens[#tokens + 1] = in_table
        end
    end)

    _parse_state[key] = { co = co, tokens = tokens, status = "parsing" }
end

-- Advance every in-progress parse by one tick. Call once per frame before ImGui_Begin.
function M.TickParse()
    for key, state in pairs(_parse_state) do
        if state.status == "parsing" then
            local ok = coroutine.resume(state.co)
            if not ok or coroutine.status(state.co) == "dead" then
                state.status = "done"
            end
        end
    end
end

-- Render README content. Auto-starts parse; shows placeholder while parsing.
function M.Render(text, base_raw_url, image_cache, queue_fn)
    local key   = base_raw_url .. "\0" .. text
    local state = _parse_state[key]

    if not state then
        M.StartParse(key, text, base_raw_url)
        reaper.ImGui_TextDisabled(_ctx, "Rendering...")
        return
    end

    if state.status == "parsing" then
        reaper.ImGui_TextDisabled(_ctx, "Rendering...")
        return
    end

    -- Render the fully-parsed token list (pure ImGui calls, no string work)
    for _, tok in ipairs(state.tokens) do
        local k = tok.k

        if     k == "sp"  then reaper.ImGui_Spacing(_ctx)
        elseif k == "sep" then draw_thick_separator()
        elseif k == "h1" or k == "h2" or k == "h3" then
            -- Scroll here if this heading is the anchor target
            if _scroll_target and to_slug(tok.t) == _scroll_target then
                reaper.ImGui_SetScrollHereY(_ctx, 0.0)
                _scroll_target = nil
            end
            if k == "h1" then
                reaper.ImGui_PushFont(_ctx, _font_big, 24)
                reaper.ImGui_Text(_ctx, tok.t)
                reaper.ImGui_PopFont(_ctx)
            elseif k == "h2" then
                reaper.ImGui_PushFont(_ctx, _font_h2, 18)
                reaper.ImGui_Text(_ctx, tok.t)
                reaper.ImGui_PopFont(_ctx)
                reaper.ImGui_Separator(_ctx)
            else
                reaper.ImGui_Indent(_ctx, 4)
                reaper.ImGui_Text(_ctx, tok.t)
                reaper.ImGui_Unindent(_ctx, 4)
            end
        elseif k == "dis" then
            reaper.ImGui_TextDisabled(_ctx, tok.t)
        elseif k == "par" then
            render_word_wrapped_spans(tok.spans)
        elseif k == "bq"  then
            reaper.ImGui_Indent(_ctx, 16)
            render_word_wrapped_spans(tok.spans)
            reaper.ImGui_Unindent(_ctx, 16)
        elseif k == "li"  then
            reaper.ImGui_Indent(_ctx, tok.indent)
            reaper.ImGui_Text(_ctx, tok.prefix)
            reaper.ImGui_SameLine(_ctx, 0, 0)
            render_word_wrapped_spans(tok.spans)
            reaper.ImGui_Unindent(_ctx, tok.indent)
        elseif k == "tbl" then
            local flags = reaper.ImGui_TableFlags_Borders()
                        + reaper.ImGui_TableFlags_RowBg()
                        + reaper.ImGui_TableFlags_SizingStretchProp()
            if reaper.ImGui_BeginTable(_ctx, "mdtbl" .. tostring(tok), tok.ncols, flags) then
                for _, hdr in ipairs(tok.headers) do
                    reaper.ImGui_TableSetupColumn(_ctx, strip(hdr))
                end
                reaper.ImGui_TableHeadersRow(_ctx)
                for _, row in ipairs(tok.rows) do
                    reaper.ImGui_TableNextRow(_ctx)
                    for ci = 1, tok.ncols do
                        reaper.ImGui_TableSetColumnIndex(_ctx, ci - 1)
                        local spans = parse_spans(row[ci] or "")
                        if spans_need_custom(spans) then
                            render_word_wrapped_spans(spans)
                        else
                            reaper.ImGui_TextWrapped(_ctx, spans_to_text(spans))
                        end
                    end
                end
                reaper.ImGui_EndTable(_ctx)
            end
        elseif k == "img" then
            local cached = image_cache[tok.url]
            if not cached then
                queue_fn(tok.url)
                reaper.ImGui_TextDisabled(_ctx, "[Loading: " .. tok.alt .. "]")
            elseif cached.status == "queued" or cached.status == "downloading" then
                reaper.ImGui_TextDisabled(_ctx, "[Loading: " .. tok.alt .. "]")
            elseif cached.status == "ready" then
                local avail_w = reaper.ImGui_GetContentRegionAvail(_ctx)
                local iw = tok.fixed_w or cached.w or 300
                local ih = tok.fixed_h or cached.h or 150
                if iw > avail_w then ih = ih * avail_w / iw; iw = avail_w end
                reaper.ImGui_Image(_ctx, cached.img, iw, ih)
            else
                reaper.ImGui_TextDisabled(_ctx, "[Image: " .. tok.alt .. "]")
            end
        end
    end
end

return M
