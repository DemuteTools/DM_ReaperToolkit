---@diagnostic disable: undefined-global

local M = {}

local _ctx, _font_big, _font_h2

-- Parse state per key: { co=coroutine, tokens={}, status="parsing"|"done" }
local _parse_state   = {}
local LINES_PER_TICK = 100   -- lines processed per frame tick

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

-- Parse a string into an array of { t=string, bold=bool } spans.
-- Bold is **...** or __...__; everything else is stripped/kept as plain text.
local function parse_spans(s)
    -- Strip non-bold markers up front
    s = s:gsub("!%[.-%]%((.-)%)", "")
    s = s:gsub("%[(.-)%]%((.-)%)", "%1")
    s = s:gsub("`(.-)`", "%1")

    local spans = {}
    local pos   = 1
    while pos <= #s do
        local b1, e1 = s:find("%*%*(.-)%*%*", pos)
        local b2, e2 = s:find("__(.-)__",     pos)

        local bs, be, is_star
        if b1 and (not b2 or b1 < b2) then
            bs, be, is_star = b1, e1, true
        elseif b2 then
            bs, be, is_star = b2, e2, false
        end

        if bs then
            if bs > pos then
                local pre = s:sub(pos, bs - 1):gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
                if pre ~= "" then spans[#spans + 1] = { t = pre, bold = false } end
            end
            local inner = is_star and s:match("%*%*(.-)%*%*", bs) or s:match("__(.-)__", bs)
            inner = inner:gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
            if inner ~= "" then spans[#spans + 1] = { t = inner, bold = true } end
            pos = be + 1
        else
            local rest = s:sub(pos):gsub("%*(.-)%*", "%1"):gsub("_(.-)_", "%1")
            if rest ~= "" then spans[#spans + 1] = { t = rest, bold = false } end
            break
        end
    end
    return #spans > 0 and spans or { { t = s, bold = false } }
end

local function spans_has_bold(spans)
    for _, sp in ipairs(spans) do if sp.bold then return true end end
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

-- Render spans word-by-word, measuring each word to decide whether it fits on
-- the current line or needs to wrap. Preserves proper word-wrap for bold text.
local function render_word_wrapped_spans(spans)
    if not spans_has_bold(spans) then
        reaper.ImGui_TextWrapped(_ctx, spans_to_text(spans))
        return
    end

    local space_w    = reaper.ImGui_CalcTextSize(_ctx, " ")
    local left_x     = reaper.ImGui_GetCursorPosX(_ctx)
    local right_edge = left_x + reaper.ImGui_GetContentRegionAvail(_ctx)

    local words = {}
    for _, sp in ipairs(spans) do
        for word in sp.t:gmatch("%S+") do
            words[#words + 1] = { w = word, bold = sp.bold }
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

        if wt.bold then
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
        local line_count = 0

        for line in (text .. "\n"):gmatch("([^\n]*)\n") do

            -- Code fence
            if line:match("^```") then
                in_code = not in_code
                tokens[#tokens + 1] = { k = "sp" }
                goto continue
            end
            if in_code then
                tokens[#tokens + 1] = { k = "dis", t = "  " .. line }
                goto continue
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

                -- Table data row  |cell|cell|
                do
                    local trow = line:match("^|(.+)|%s*$")
                    if trow then
                        local cells = {}
                        for cell in trow:gmatch("[^|]+") do
                            local t = cell:match("^%s*(.-)%s*$")
                            if t ~= "" then cells[#cells + 1] = strip(t) end
                        end
                        if #cells > 0 then
                            tokens[#tokens + 1] = { k = "dis", t = table.concat(cells, "   ") }
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
    end)

    _parse_state[key] = { co = co, tokens = tokens, status = "parsing" }
end

-- Advance every in-progress parse by one tick. Call once per frame before ImGui_Begin.
function M.TickParse()
    for key, state in pairs(_parse_state) do
        if state.status == "parsing" then
            local t0 = reaper.time_precise()
            local ok = coroutine.resume(state.co)
            local dt = (reaper.time_precise() - t0) * 1000
            if dt > 1 then
                reaper.ShowConsoleMsg(string.format("[PROFILE] TickParse tick: %.2f ms  tokens=%d\n",
                    dt, #state.tokens))
            end
            if not ok or coroutine.status(state.co) == "dead" then
                state.status = "done"
                reaper.ShowConsoleMsg(string.format("[PROFILE] Parse DONE: %d tokens total\n",
                    #state.tokens))
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
        elseif k == "h1"  then
            reaper.ImGui_PushFont(_ctx, _font_big, 24)
            reaper.ImGui_Text(_ctx, tok.t)
            reaper.ImGui_PopFont(_ctx)
        elseif k == "h2"  then
            reaper.ImGui_PushFont(_ctx, _font_h2, 18)
            reaper.ImGui_Text(_ctx, tok.t)
            reaper.ImGui_PopFont(_ctx)
            reaper.ImGui_Separator(_ctx)
        elseif k == "h3"  then
            reaper.ImGui_Indent(_ctx, 4)
            reaper.ImGui_Text(_ctx, tok.t)
            reaper.ImGui_Unindent(_ctx, 4)
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
