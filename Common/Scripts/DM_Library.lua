--[[
@version 1.0
@noindex
@description Generic utility library shared across Demute REAPER tools.
--]]

-- DM_Library.lua
--
-- Usage:
--   DM = dofile(COMMON .. "DM_Library.lua")
--
-- Categories:
--   DM.String   — split, NormalizePath, HashURL, PercentEncode, VersionGT
--   DM.Image    — GetPNGSize, GetImageSize, LoadDemuteLogo
--   DM.Math     — round, clamp, lerp, map_range
--   DM.Table    — shallow_copy, deep_copy, contains, keys, merge
--   DM.Track    — FindByName, GetOrCreate, GetPosition
--   DM.Item     — GetSelected, GetName, GetSourceFilename, GetNotes
--   DM.File     — Exists, ReadAll, PickFolder
--   DM.Time     — ToSample, FromSample
--   DM.Undo     — Wrap
--   DM.Script   — GetPaths
--   DM.Log      — Msg, Console

local DM = {}

-- Resolve this file's own directory for LoadDemuteLogo (Common/Resources/ is one level up).
local _lib_dir = debug.getinfo(1, "S").source:match("@?(.+[\\/])")

-- ═══════════════════════════════════════════════════════════════════════════════
-- String / Path
-- ═══════════════════════════════════════════════════════════════════════════════

DM.String = {}

--- Split a string by a delimiter and return an array of parts.
--- Example: DM.String.split("a,b,c", ",")  →  {"a", "b", "c"}
--- @param str       string
--- @param delimiter string
--- @return table
function DM.String.split(str, delimiter)
    local result = {}
    for match in (str .. delimiter):gmatch("(.-)" .. delimiter) do
        result[#result + 1] = match
    end
    return result
end

--- Normalize path separators to forward slashes.
--- Removes duplicate slashes and trailing slash.
--- @param path string
--- @return string
function DM.String.NormalizePath(path)
    if not path then return "" end
    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("//+", "/")
    normalized = normalized:gsub("/$", "")
    return normalized
end

--- djb2 hash of a string → 8-char hex fragment safe for use in temp filenames.
--- @param url string
--- @return string
function DM.String.HashURL(url)
    local h = 5381
    for i = 1, #url do h = ((h * 33) + url:byte(i)) % 0x100000000 end
    return string.format("%08x", h)
end

--- Percent-encode a string for safe use in URLs.
--- Encodes everything except unreserved characters (A-Z, a-z, 0-9, -, _, ., ~).
--- @param str string
--- @return string
function DM.String.PercentEncode(str)
    return (str:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Returns true if version string a is numerically greater than b.
--- Compares dot-separated numeric segments (e.g. "1.2.3" > "1.2.0").
--- @param a string
--- @param b string
--- @return boolean
function DM.String.VersionGT(a, b)
    local function nums(v)
        local t = {}
        for n in (v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local na, nb = nums(a), nums(b)
    for i = 1, math.max(#na, #nb) do
        local x, y = na[i] or 0, nb[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Image
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Image = {}

--- Read pixel dimensions from a PNG file header (first 24 bytes).
--- @param path string
--- @return number|nil width, number|nil height
function DM.Image.GetPNGSize(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local hdr = f:read(24)
    f:close()
    if not hdr or #hdr < 24 then return nil, nil end
    if hdr:byte(1) ~= 0x89 or hdr:sub(2, 4) ~= "PNG" then return nil, nil end
    local w = hdr:byte(17)*16777216 + hdr:byte(18)*65536 + hdr:byte(19)*256 + hdr:byte(20)
    local h = hdr:byte(21)*16777216 + hdr:byte(22)*65536 + hdr:byte(23)*256 + hdr:byte(24)
    return w, h
end

--- Read pixel dimensions from a PNG or JPEG file.
--- Tries PNG header first, then scans JPEG SOF markers. Reads at most 64 KB.
--- @param path string
--- @return number|nil width, number|nil height
function DM.Image.GetImageSize(path)
    local w, h = DM.Image.GetPNGSize(path)
    if w then return w, h end
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local data = f:read(65536)
    f:close()
    if not data or #data < 4 then return nil, nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, nil end
    local i = 3
    while i <= #data - 1 do
        if data:byte(i) ~= 0xFF then break end
        local m = data:byte(i + 1)
        if m == 0xDA then break end
        if (m >= 0xC0 and m <= 0xC3) or (m >= 0xC5 and m <= 0xC7) or
           (m >= 0xC9 and m <= 0xCB) or (m >= 0xCD and m <= 0xCF) then
            if i + 8 <= #data then
                return data:byte(i+7)*256 + data:byte(i+8),
                       data:byte(i+5)*256 + data:byte(i+6)
            end
            break
        end
        if i + 3 > #data then break end
        i = i + 2 + (data:byte(i+2)*256 + data:byte(i+3))
    end
    return nil, nil
end

--- Load the shared Demute logo from Common/Resources/.
--- Creates an ImGui image handle and returns (img, width, height).
--- Returns (nil, 0, 0) if the file cannot be read.
--- The caller is responsible for calling reaper.ImGui_Attach(ctx, img) if needed.
--- @return userdata|nil img, number width, number height
function DM.Image.LoadDemuteLogo()
    local logo_path = _lib_dir .. "../Resources/Demute_Home_Logo.png"
    local w, h = DM.Image.GetImageSize(logo_path)
    ---@diagnostic disable-next-line: return-type-mismatch
    if not w then return nil, 0, 0 end
    local img = reaper.ImGui_CreateImage(logo_path)
    return img, w, h
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Math
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Math = {}

--- Round a number to the given number of decimal places.
--- @param num number
--- @param decimal_places number|nil  (default 0)
--- @return number
function DM.Math.round(num, decimal_places)
    local mult = 10 ^ (decimal_places or 0)
    return math.floor(num * mult + 0.5) / mult
end

--- Clamp a value between min and max.
--- @param val number
--- @param lo  number
--- @param hi  number
--- @return number
function DM.Math.clamp(val, lo, hi)
    return math.max(lo, math.min(hi, val))
end

--- Linear interpolation between a and b by factor t (0..1).
--- @param a number
--- @param b number
--- @param t number
--- @return number
function DM.Math.lerp(a, b, t)
    return a + (b - a) * t
end

--- Map a value from one range to another.
--- @param val      number  Input value
--- @param in_lo    number  Input range lower bound
--- @param in_hi    number  Input range upper bound
--- @param out_lo   number  Output range lower bound
--- @param out_hi   number  Output range upper bound
--- @return number
function DM.Math.map_range(val, in_lo, in_hi, out_lo, out_hi)
    if in_hi == in_lo then return out_lo end
    local t = (val - in_lo) / (in_hi - in_lo)
    return out_lo + (out_hi - out_lo) * t
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Table
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Table = {}

--- Shallow copy of a table (one level deep).
--- @param t table
--- @return table
function DM.Table.shallow_copy(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

--- Deep copy of a table (recursive, handles nested tables).
--- Does not copy metatables.
--- @param t table
--- @return table
function DM.Table.deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DM.Table.deep_copy(v)
    end
    return copy
end

--- Check if a sequential table contains a value.
--- @param t   table
--- @param val any
--- @return boolean
function DM.Table.contains(t, val)
    for _, v in ipairs(t) do
        if v == val then return true end
    end
    return false
end

--- Return an array of all keys in a table.
--- @param t table
--- @return table
function DM.Table.keys(t)
    local result = {}
    for k in pairs(t) do result[#result + 1] = k end
    return result
end

--- Merge source table into dest (shallow). Source values overwrite dest values.
--- @param dest   table
--- @param source table
--- @return table  dest (modified in-place)
function DM.Table.merge(dest, source)
    for k, v in pairs(source) do dest[k] = v end
    return dest
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Track
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Track = {}

--- Find the first track whose name matches the given string.
--- @param name string  Track name to search for
--- @return MediaTrack|nil
function DM.Track.FindByName(name)
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, tr_name = reaper.GetTrackName(tr)
        if tr_name == name then return tr end
    end
    return nil
end

--- Find a track by name (case-insensitive).
--- @param name string  Track name to search for
--- @return MediaTrack|nil
function DM.Track.FindByNameCI(name)
    local lower = name:lower()
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, tr_name = reaper.GetTrackName(tr)
        if tr_name:lower() == lower then return tr end
    end
    return nil
end

--- Get existing track at index with matching name, or create one.
--- @param track_idx  number  0-based track index
--- @param track_name string  Expected track name
--- @return MediaTrack track, boolean created
function DM.Track.GetOrCreate(track_idx, track_name)
    local track = reaper.GetTrack(0, track_idx)
    if track then
        local _, existing = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if existing == track_name then
            return track, false
        end
    end
    reaper.InsertTrackAtIndex(track_idx, false)
    track = reaper.GetTrack(0, track_idx)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
    return track, true
end

--- Get the current playback or edit cursor position.
--- Returns play position during playback, cursor position otherwise.
--- @return number  position in seconds
function DM.Track.GetPosition()
    if (reaper.GetPlayState() & 1) == 1 then
        return reaper.GetPlayPosition()
    else
        return reaper.GetCursorPosition()
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Item
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Item = {}

--- Get all currently selected media items in the project.
--- @return table  Array of MediaItem handles
function DM.Item.GetSelected()
    local items = {}
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        if reaper.IsMediaItemSelected(item) then
            items[#items + 1] = item
        end
    end
    return items
end

--- Get the display name of a media item (from its active take).
--- @param item MediaItem
--- @return string
function DM.Item.GetName(item)
    local take = reaper.GetActiveTake(item)
    if take then
        local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        return name
    end
    return "Unnamed"
end

--- Get the source filename of a media item (without path or extension).
--- Returns nil for MIDI items or items without a source.
--- @param item MediaItem
--- @return string|nil
function DM.Item.GetSourceFilename(item)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then return nil end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then return nil end
    local buf = reaper.GetMediaSourceFileName(src, "")
    local filename = buf:match("[^\\/]+$")
    local name_no_ext = filename:match("(.+)%..+$") or filename
    return name_no_ext
end

--- Get the source file's full path for a media item.
--- Returns nil for MIDI items or items without a source.
--- @param item MediaItem
--- @return string|nil
function DM.Item.GetSourcePath(item)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then return nil end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then return nil end
    return reaper.GetMediaSourceFileName(src, "")
end

--- Get the P_NOTES string of a media item.
--- @param item MediaItem
--- @return string
function DM.Item.GetNotes(item)
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    return notes
end

--- Set the P_NOTES string of a media item.
--- @param item  MediaItem
--- @param notes string
function DM.Item.SetNotes(item, notes)
    reaper.GetSetMediaItemInfo_String(item, "P_NOTES", notes, true)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- File
-- ═══════════════════════════════════════════════════════════════════════════════

DM.File = {}

--- Check if a file exists at the given path.
--- @param path string
--- @return boolean
function DM.File.Exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

--- Read an entire file into a string. Returns nil on failure.
--- @param path string
--- @return string|nil
function DM.File.ReadAll(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Write a string to a file (overwrite). Returns true on success.
--- @param path    string
--- @param content string
--- @return boolean
function DM.File.WriteAll(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

--- Open a Windows folder-picker dialog.
--- Uses js_ReaScriptAPI native dialog if available, otherwise falls back to VBScript.
--- Blocks until the user selects a folder or cancels.
--- Returns the selected folder path, or nil if cancelled.
--- @param default_path string|nil  Initial folder to display
--- @param prompt       string|nil  Dialog prompt text
--- @return string|nil
function DM.File.PickFolder(default_path, prompt)
    -- Fast path: js_ReaScriptAPI native dialog (instant, no subprocess)
    if reaper.JS_Dialog_BrowseForFolder then
        local ok, path = reaper.JS_Dialog_BrowseForFolder(
            prompt or "Select folder",
            default_path or "")
        return (ok == 1 and path ~= "") and path or nil
    end

    -- Fallback: VBScript (slower due to subprocess + shell namespace enumeration)
    local tmp_vbs = os.getenv("TEMP") .. "\\dm_pick_folder.vbs"
    local tmp_out = os.getenv("TEMP") .. "\\dm_pick_folder.txt"
    os.remove(tmp_out)

    local vbs = string.format([[
Set sh = CreateObject("Shell.Application")
Set f = sh.BrowseForFolder(0, "%s", &H51, "%s")
If Not (f Is Nothing) Then
    Dim fs : Set fs = CreateObject("Scripting.FileSystemObject")
    Dim tf : Set tf = fs.CreateTextFile("%s", True, False)
    tf.Write f.Self.Path
    tf.Close
End If
]], prompt or "Select folder", default_path or "", tmp_out)

    local vf = io.open(tmp_vbs, "w")
    if not vf then return nil end
    vf:write(vbs); vf:close()

    os.execute('wscript //B //Nologo "' .. tmp_vbs .. '"')
    os.remove(tmp_vbs)

    local rf = io.open(tmp_out, "r")
    if not rf then return nil end
    local folder = rf:read("*a"):gsub("^\239\187\191", ""):gsub("^%s*(.-)%s*$", "%1")
    rf:close(); os.remove(tmp_out)
    return folder ~= "" and folder or nil
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Time / Sample conversion
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Time = {}

--- Convert a time in seconds to a 1-based sample index.
--- @param time        number  Time in seconds
--- @param sample_rate number  Samples per second
--- @return number  1-based sample index
function DM.Time.ToSample(time, sample_rate)
    return math.floor(time * sample_rate) + 1
end

--- Convert a 1-based sample index to time in seconds.
--- @param sample      number  1-based sample index
--- @param sample_rate number  Samples per second
--- @return number  Time in seconds
function DM.Time.FromSample(sample, sample_rate)
    return (sample - 1) / sample_rate
end

--- Format seconds as "MM:SS.mmm" string.
--- @param seconds number
--- @return string
function DM.Time.Format(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60
    return string.format("%02d:%06.3f", m, s)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Undo
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Undo = {}

--- Wrap a function in an undo block. Calls UpdateArrange after.
--- @param description string  Undo point description
--- @param fn          function  The function to execute inside the block
--- @param ...         any  Arguments forwarded to fn
--- @return any  Return values from fn
function DM.Undo.Wrap(description, fn, ...)
    reaper.Undo_BeginBlock()
    local result = { fn(...) }
    reaper.UpdateArrange()
    reaper.Undo_EndBlock(description, -1)
    return table.unpack(result)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Script path helpers
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Script = {}

--- Derive common paths from a calling script's location.
--- Call from your main script file like:
---   local paths = DM.Script.GetPaths(debug.getinfo(1, "S").source)
---
--- Returns a table with:
---   script_dir  — directory containing the calling script
---   demute_root — the Demute/ root folder (parent of the tool folder)
---   common      — path to Common/Scripts/
---
--- @param source string  debug.getinfo(1,"S").source from the caller
--- @return table  { script_dir, demute_root, common }
function DM.Script.GetPaths(source)
    local script_dir  = source:match("@?(.*[/\\])")
    local demute_root = script_dir:match("^(.*[/\\])[^/\\]+[/\\]$")
    -- If script is nested (e.g. tool/scripts/), go up one more level
    if not demute_root or not DM.File.Exists(demute_root .. "Common/Scripts/DM_Library.lua") then
        local parent = script_dir:match("^(.*[/\\])[^/\\]+[/\\]$")
        if parent then
            demute_root = parent:match("^(.*[/\\])[^/\\]+[/\\]$")
        end
    end
    local common = demute_root and (demute_root .. "Common/Scripts/") or ""
    return {
        script_dir  = script_dir,
        demute_root = demute_root or "",
        common      = common,
    }
end

--- Detect the current OS and return the shared library extension.
--- @return string  "dll" on Windows, "so" on Linux/macOS
function DM.Script.GetLibExtension()
    local os_name = reaper.GetOS()
    return os_name:match("Win") and "dll" or "so"
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Logging
-- ═══════════════════════════════════════════════════════════════════════════════

DM.Log = {}

--- Print a message to the REAPER console (with newline).
--- @param ...  any  Values to print (concatenated with spaces)
function DM.Log.Console(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    reaper.ShowConsoleMsg(table.concat(parts, " ") .. "\n")
end

--- Show a message box.
--- @param msg   string  Message text
--- @param title string  Window title (default "Demute")
function DM.Log.MsgBox(msg, title)
    reaper.ShowMessageBox(msg, title or "Demute", 0)
end

return DM