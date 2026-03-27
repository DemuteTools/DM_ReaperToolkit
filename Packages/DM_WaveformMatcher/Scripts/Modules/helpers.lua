-- compareWaveform/helpers.lua
-- Utility functions used across modules
-- DM (global) is loaded by WaveformMatcher.lua before this file.
-- Provides: DM.Time.ToSample, DM.Time.FromSample, DM.Track.GetOrCreate, DM.Item.GetName

function Log(message, color)
    local timestamp = os.date("%H:%M:%S")
    local colored_msg = timestamp .. " - " .. message

    table.insert(report_log, {
        text = colored_msg,
        color = color or COLORS.WHITE
    })

    if #report_log > CONFIG.MAX_LOG_ENTRIES then
        table.remove(report_log, 1)
    end
end

-- Global aliases so existing module code (matching.lua, peaks.lua) keeps working
time_to_sample = DM.Time.ToSample
sample_to_time = DM.Time.FromSample