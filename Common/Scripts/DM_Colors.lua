---@diagnostic disable: undefined-global, lowercase-global

-- DM_Colors.lua
-- Shared color palette for all Demute tools.
-- Colors are in 0xRRGGBBAA format (last byte = opacity, FF = opaque).
-- Usage: dofile(COMMON .. "DM_Colors.lua")  →  Colors.white, Colors.teal_btn, etc.

Colors = {
    -- Neutrals
    white        = 0xFFFFFFFF,
    black        = 0x000000FF,
    transparent  = 0x00000000,

    -- Greys
    grey_dark    = 0x1A1A1AFF,
    grey         = 0x555555FF,
    grey_mid     = 0x888888FF,
    grey_light   = 0xCCCCCCFF,

    -- Accent
    red          = 0xFF3333FF,
    orange       = 0xFF8800FF,
    amber        = 0xFFAA00FF,
    yellow       = 0xFFFF00FF,
    green        = 0x44FF44FF,
    green_dark   = 0x226622FF,
    teal         = 0x00CCAAFF,
    blue         = 0x4488CCFF,
    blue_dark    = 0x1A1A2EFF,
    purple       = 0x8844CCFF,
    pink         = 0xFF44AAFF,

    -- Semantic
    success      = 0x55CC55FF,
    warning      = 0xFF8800FF,
    error        = 0xFF3333FF,
    info         = 0x4488CCFF,

    -- Semi-transparent whites (overlays, borders, splitters)
    white_dim    = 0xFFFFFF0D,   -- ~5%
    white_faint  = 0xFFFFFF1A,   -- ~10%
    white_ghost  = 0xFFFFFF33,   -- ~20%
    white_mid    = 0xFFFFFF88,   -- ~53%
    white_soft   = 0xFFFFFF99,   -- ~60%
    white_bright = 0xFFFFFFCC,   -- ~80%

    -- Semi-transparent blacks (dark bars, overlays)
    black_glass  = 0x00000066,   -- ~40%
    black_smoke  = 0x000000BB,   -- ~73%

    -- Near-black image tints (for darkening image overlays)
    dark_tint     = 0x22222244,
    dark_tint_sub = 0x11111133,

    -- Widget interaction colours
    grey_hover   = 0x777777FF,
    grey_press   = 0x444444FF,
    red_hover    = 0xCC3333FF,
    red_press    = 0x993333FF,
    red_light    = 0xFF4444FF,   -- softer error / warning text

    -- Teal button family (Demute primary button colour)
    teal_btn       = 0x15856DFF,   -- base
    teal_btn_hover = 0x2E9E86FF,   -- base + 25 per channel
    teal_btn_press = 0x006C54FF,   -- base − 25 per channel
}