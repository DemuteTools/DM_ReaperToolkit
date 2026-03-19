---@diagnostic disable: undefined-global

-- DM_ImageUtils.lua
-- Image dimension detection and shared asset loading for all Demute tools.
-- Usage: dofile(COMMON .. "DM_ImageUtils.lua")

-- Resolve this file's own directory so LoadDemuteLogo can find the Resources folder.
local _imgutils_dir = debug.getinfo(1, "S").source:match("@?(.+[\\/])")

-- Read pixel dimensions from a PNG file header (first 24 bytes).
function GetPNGSize(path)
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

-- Read pixel dimensions from a PNG or JPEG file.
-- Tries PNG header first, then scans JPEG SOF markers. Reads at most 64 KB.
function GetImageSize(path)
    local w, h = GetPNGSize(path)
    if w then return w, h end
    -- Try JPEG: scan for SOF marker (FF C0/C1/C2... contain h/w)
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
        if m == 0xDA then break end  -- start of scan, no more headers
        if (m >= 0xC0 and m <= 0xC3) or (m >= 0xC5 and m <= 0xC7) or
           (m >= 0xC9 and m <= 0xCB) or (m >= 0xCD and m <= 0xCF) then
            if i + 8 <= #data then
                return data:byte(i+7)*256 + data:byte(i+8),  -- width
                       data:byte(i+5)*256 + data:byte(i+6)   -- height
            end
            break
        end
        if i + 3 > #data then break end
        i = i + 2 + (data:byte(i+2)*256 + data:byte(i+3))
    end
    return nil, nil
end

-- Load the shared Demute logo from Common/Resources/.
-- Creates an ImGui image handle and returns (img, width, height).
-- Returns (nil, 0, 0) if the file cannot be read.
-- The caller is responsible for calling reaper.ImGui_Attach(ctx, img) if needed.
--
-- @return img, width, height
function LoadDemuteLogo()
    local logo_path = _imgutils_dir .. "../Resources/Demute_Home_Logo.png"
    local w, h = GetImageSize(logo_path)
    if not w then return nil, 0, 0 end
    local img = reaper.ImGui_CreateImage(logo_path)
    return img, w, h
end