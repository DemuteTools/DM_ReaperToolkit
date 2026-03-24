--[[
@version 1.0
@noindex
@description Generic ExtState load/save helpers for all Demute tools.
--]]

-- DM_Settings.lua
-- Usage: Settings = dofile(COMMON .. "DM_Settings.lua")
--
-- Example:
--   local DEFAULTS = { volume = 1.0, enabled = true, name = "default" }
--   local cfg = Settings.Load("MyTool", DEFAULTS)
--   cfg.volume = 0.8
--   Settings.Save("MyTool", cfg)

local Settings = {}

-- Load settings from ExtState, falling back to the provided defaults table.
-- Automatically converts saved strings back to the correct type based on defaults:
--   number  → tonumber()
--   boolean → compare to "true"
--   string  → raw value
--
-- @param section  string  ExtState section name (unique per tool)
-- @param defaults table   Key/value pairs of default settings
-- @return table  Settings table with saved or default values
function Settings.Load(section, defaults)
    local result = {}
    for key, default_val in pairs(defaults) do
        local saved = reaper.GetExtState(section, key)
        if saved ~= "" then
            local t = type(default_val)
            if t == "number" then
                result[key] = tonumber(saved) or default_val
            elseif t == "boolean" then
                result[key] = (saved == "true")
            else
                result[key] = saved
            end
        else
            result[key] = default_val
        end
    end
    return result
end

-- Save a settings table to ExtState (persist = true, survives REAPER restart).
-- All values are converted to strings via tostring().
--
-- @param section  string  ExtState section name
-- @param data     table   Key/value pairs to save
function Settings.Save(section, data)
    for key, val in pairs(data) do
        reaper.SetExtState(section, key, tostring(val), true)
    end
end

-- Delete specific keys from ExtState for a given section.
--
-- @param section  string    ExtState section name
-- @param keys     string[]  Array of key names to delete
function Settings.Clear(section, keys)
    for _, key in ipairs(keys) do
        reaper.DeleteExtState(section, key, true)
    end
end

return Settings