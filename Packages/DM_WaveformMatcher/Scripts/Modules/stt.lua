-- compareWaveform/stt.lua
-- Speech-to-text integration

local EXPORT_CHUNK_SIZE = 100000  -- samples per chunk to avoid reaper.new_array limits

function ExportItemToWav(item, start_offset, duration)
    local take = reaper.GetActiveTake(item)
    if not take then return nil end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil end

    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    -- Use provided start_offset or default to 0
    start_offset = start_offset or 0
    -- Use provided duration or remaining item length
    duration = duration or (item_len - start_offset)

    -- Cap duration to user-configured limit (reduces API costs & speeds up processing)
    if duration > TUNABLE.stt_max_duration then
        duration = TUNABLE.stt_max_duration
    end

    -- Ensure we don't exceed item bounds
    if start_offset + duration > item_len then
        duration = item_len - start_offset
    end

    if duration <= 0 then return nil end

    -- Create temp file path (use forward slash - works on Windows and avoids shell escaping issues)
    local temp_path = CONFIG.STT_TEMP_DIR .. "/stt_temp_" .. tostring(os.time()) .. "_" ..
                      tostring(math.random(10000)) .. ".wav"

    -- Use audio accessor to get samples at 16kHz
    local sr = CONFIG.STT_SAMPLE_RATE
    local num_samples = math.floor(duration * sr)

    if num_samples <= 0 then return nil end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return nil end

    -- Write WAV file (16-bit PCM mono)
    local f = io.open(temp_path, "wb")
    if not f then
        reaper.DestroyAudioAccessor(accessor)
        return nil
    end

    local data_size = num_samples * 2

    -- WAV header
    f:write("RIFF")
    f:write(string.pack("<I4", 36 + data_size))  -- File size - 8
    f:write("WAVEfmt ")
    f:write(string.pack("<I4", 16))   -- Subchunk1 size
    f:write(string.pack("<I2", 1))    -- Audio format (PCM)
    f:write(string.pack("<I2", 1))    -- Num channels (mono)
    f:write(string.pack("<I4", sr))   -- Sample rate
    f:write(string.pack("<I4", sr * 2))  -- Byte rate
    f:write(string.pack("<I2", 2))    -- Block align
    f:write(string.pack("<I2", 16))   -- Bits per sample
    f:write("data")
    f:write(string.pack("<I4", data_size))

    -- Export in chunks to avoid reaper.new_array size limits
    local samples_written = 0
    local buffer = reaper.new_array(EXPORT_CHUNK_SIZE)
    local max_sample_value = 0  -- Track if audio has actual content

    while samples_written < num_samples do
        local chunk_samples = math.min(EXPORT_CHUNK_SIZE, num_samples - samples_written)
        -- Read from the specified position relative to the take
        -- The audio accessor is already positioned relative to the take, not the raw source
        -- start_offset = where to start within the item
        local read_time = start_offset + (samples_written / sr)

        buffer.clear()
        reaper.GetAudioAccessorSamples(accessor, sr, 1, read_time, chunk_samples, buffer)

        -- Write samples as 16-bit
        for i = 1, chunk_samples do
            local sample = math.max(-1, math.min(1, buffer[i]))
            max_sample_value = math.max(max_sample_value, math.abs(sample))
            local int_sample = math.floor(sample * 32767)
            f:write(string.pack("<i2", int_sample))
        end

        samples_written = samples_written + chunk_samples
    end

    -- Warn if audio appears to be silent
    if max_sample_value < 0.01 then
        Log(string.format("  WARNING: Exported audio appears silent (max level: %.4f)", max_sample_value), COLORS.YELLOW)
    end

    reaper.DestroyAudioAccessor(accessor)
    f:close()
    return temp_path
end

-- MULTI-ENGINE STT FUNCTIONS

-- Get the directory path of the main script (parent of compareWaveform folder)
function GetScriptPath()
    local info = debug.getinfo(1, 'S')
    local script_path = info.source:match("@?(.*[/\\])")
    -- Normalize to forward slashes
    if script_path then
        script_path = script_path:gsub("\\", "/")
        -- Go up one level from compareWaveform/ folder to the main script directory
        script_path = script_path:gsub("compareWaveform/$", "")
    end
    return script_path or ""
end

-- Get engine index from engine ID for UI dropdown
function GetEngineIndex(engine_id, engine_ids)
    for i, id in ipairs(engine_ids) do
        if id == engine_id then
            return i
        end
    end
    return 3  -- Default to Azure (index 3) if not found
end

-- Build STT command based on engine type
function BuildSTTCommand(python, script, wav, config)
    -- Normalize all paths to forward slashes to avoid shell escaping issues
    local norm_script = DM.String.NormalizePath(script)
    local norm_wav = DM.String.NormalizePath(wav)

    local args = {
        python,  -- Don't quote executable - cmd.exe needs unquoted command name
        string.format('"%s"', norm_script),
        "--engine", config.engine,
        "--wav", string.format('"%s"', norm_wav),
        "--language", config.language
    }

    -- Add engine-specific arguments
    if config.engine == "azure" then
        table.insert(args, "--subscription_key")
        table.insert(args, string.format('"%s"', config.azure_key))
        table.insert(args, "--region")
        table.insert(args, config.region)
    elseif config.engine == "google_cloud" then
        table.insert(args, "--credentials_json")
        table.insert(args, string.format('"%s"', config.google_credentials_path))
    elseif config.engine == "whisper" then
        table.insert(args, "--model")
        table.insert(args, config.whisper_model or "base")
    elseif config.engine == "vosk" then
        table.insert(args, "--model_path")
        table.insert(args, string.format('"%s"', config.vosk_model_path))
    end
    -- Note: google engine needs no additional args

    return table.concat(args, " ")
end

-- Parse STT JSON response from Python script
function ParseSTTResponse(json_str, exit_code, engine)
    if not json_str or json_str == "" then
        Log(string.format("ERROR: Empty response from STT engine '%s'", engine), COLORS.RED)
        return nil
    end

    -- Simple JSON parsing (looking for success, text, confidence fields)
    local success = json_str:match('"success"%s*:%s*true')

    if not success then
        local error_msg = json_str:match('"error"%s*:%s*"([^"]*)"')
        if error_msg then
            Log(string.format("  STT Error (%s): %s", engine, error_msg), COLORS.YELLOW)
        else
            -- Try to extract useful error from output (limit to 200 chars)
            local preview = json_str:sub(1, 200):gsub("\n", " ")
            Log(string.format("  STT failed (%s): %s", engine, preview), COLORS.YELLOW)
        end
        return nil
    end

    local text = json_str:match('"text"%s*:%s*"([^"]*)"')
    local confidence = tonumber(json_str:match('"confidence"%s*:%s*([%d%.]+)')) or 0

    if not text or text == "" then
        return nil
    end

    return {
        text = text:lower(),
        confidence = confidence
    }
end

-- Generic STT transcription function that works with multiple engines
-- @param wav_path: Path to 16kHz WAV file
-- @param engine_config: Optional override config (defaults to STT_SETTINGS)
-- @return: {text=string, confidence=number} or nil on error
function TranscribeWithEngine(wav_path, engine_config)
    local config = engine_config or STT_SETTINGS
    local engine = config.engine or "azure"

    -- Build Python command based on engine type
    local python_path = config.python_path or "python"
    local script_path = GetScriptPath() .. "stt_transcribe.py"

    -- Normalize WAV path to forward slashes (defense-in-depth)
    local normalized_wav_path = DM.String.NormalizePath(wav_path)

    -- Build command args based on engine
    local cmd = BuildSTTCommand(python_path, script_path, normalized_wav_path, config)

    -- Log the engine being used (without sensitive data)
    Log(string.format("  Calling STT engine: %s", engine), COLORS.GRAY)

    -- Execute and capture stdout/stderr
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        Log(string.format("ERROR: Failed to execute STT command for engine '%s'", engine), COLORS.RED)
        return nil
    end

    local result = handle:read("*a")
    local success, exit_type, exit_code = handle:close()

    -- Parse JSON result
    return ParseSTTResponse(result, exit_code, engine)
end

-- Validate STT setup (Python, dependencies, script)
function ValidateSTTSetup()
    local python = STT_SETTINGS.python_path or "python"
    local script_path = GetScriptPath() .. "stt_transcribe.py"

    -- Check if Python is available
    local handle = io.popen(python .. " --version 2>&1")
    if not handle then
        Log("ERROR: Cannot execute Python. Check python_path in settings.", COLORS.RED)
        return false
    end

    local version = handle:read("*a")
    local success = handle:close()

    if not success then
        Log("ERROR: Python not found. Install Python or set correct path in settings.", COLORS.RED)
        return false
    end

    Log("  Python found: " .. version:gsub("\n", ""), COLORS.GRAY)

    -- Check if script exists
    local f = io.open(script_path, "r")
    if not f then
        Log("ERROR: stt_transcribe.py not found. Place it in the same directory as this script.", COLORS.RED)
        return false
    end
    f:close()

    -- Check if SpeechRecognition is installed
    handle = io.popen(python .. " -c \"import speech_recognition\" 2>&1")
    if not handle then
        Log("WARNING: Cannot check SpeechRecognition installation.", COLORS.YELLOW)
        return true  -- Continue anyway
    end

    local result = handle:read("*a")
    success = handle:close()

    if not success then
        Log("WARNING: SpeechRecognition not installed. Run: pip install SpeechRecognition", COLORS.YELLOW)
        Log("  " .. result:gsub("\n", " "):sub(1, 200), COLORS.GRAY)
        return false
    end

    Log("  SpeechRecognition library found", COLORS.GRAY)
    return true
end

-- TEXT SIMILARITY FUNCTIONS

-- Prefix-weighted similarity: prioritizes matching first words (for sync detection)
-- Combines prefix score (60%) with overall Jaccard score (40%)
-- Filters out filler words before comparison
function TextSimilarity(text1, text2)
    if not text1 or not text2 or text1 == "" or text2 == "" then
        return 0
    end

    -- Normalize: lowercase, remove punctuation
    local t1 = text1:lower():gsub("[^%w%s]", "")
    local t2 = text2:lower():gsub("[^%w%s]", "")

    -- Build word arrays (ordered) and sets (for Jaccard)
    local words1 = {}
    local set1 = {}
    for word in t1:gmatch("%S+") do
        words1[#words1 + 1] = word
        set1[word] = true
    end

    local words2 = {}
    local set2 = {}
    for word in t2:gmatch("%S+") do
        words2[#words2 + 1] = word
        set2[word] = true
    end

    if #words1 == 0 or #words2 == 0 then return 0 end

    -- 1. PREFIX SCORE: Check first N words match in order
    local prefix_len = math.min(4, #words1, #words2)  -- Check first 4 words
    local prefix_matches = 0
    for i = 1, prefix_len do
        if words1[i] == words2[i] then
            prefix_matches = prefix_matches + 1
        else
            break  -- Stop at first mismatch (order matters)
        end
    end
    local prefix_score = prefix_matches / prefix_len

    -- 2. JACCARD SCORE: Overall word overlap
    local intersection = 0
    for word in pairs(set1) do
        if set2[word] then
            intersection = intersection + 1
        end
    end
    local union = #words1 + #words2 - intersection
    local jaccard_score = union > 0 and (intersection / union) or 0

    -- 3. COMBINE: Prefix is more important (60% prefix, 40% Jaccard)
    local PREFIX_WEIGHT = 0.2
    local combined = (prefix_score * PREFIX_WEIGHT) + (jaccard_score * (1 - PREFIX_WEIGHT))

    return combined
end

-- UI HELPER FUNCTIONS FOR STT CONFIGURATION

function RenderAzureSettings(ctx)
    -- API Key
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "API Key:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local key_changed, new_key = reaper.ImGui_InputText(ctx, "##azure_key",
        STT_SETTINGS.azure_key, reaper.ImGui_InputTextFlags_Password())
    if key_changed then
        STT_SETTINGS.azure_key = new_key
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Your Azure Speech Services API key")
    end

    -- Region
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Region:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local region_changed, new_region = reaper.ImGui_InputText(ctx, "##azure_region", STT_SETTINGS.region)
    if region_changed then
        STT_SETTINGS.region = new_region
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Azure region (e.g., westeurope, eastus)")
    end
end

function RenderGoogleCloudSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Credentials JSON:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local path_changed, new_path = reaper.ImGui_InputText(ctx, "##google_creds",
        STT_SETTINGS.google_credentials_path)
    if path_changed then
        STT_SETTINGS.google_credentials_path = new_path
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Path to Google Cloud service account JSON file")
    end
end

function RenderWhisperSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Model Size:")
    reaper.ImGui_TableNextColumn(ctx)

    local models = {"tiny", "base", "small", "medium", "large"}
    local current_model = STT_SETTINGS.whisper_model or "base"
    local current_idx = 2  -- default to base

    for i, model in ipairs(models) do
        if model == current_model then
            current_idx = i
            break
        end
    end

    reaper.ImGui_SetNextItemWidth(ctx, -1)
    if reaper.ImGui_BeginCombo(ctx, "##whisper_model", current_model) then
        for i, model in ipairs(models) do
            local is_selected = (i == current_idx)
            if reaper.ImGui_Selectable(ctx, model, is_selected) then
                STT_SETTINGS.whisper_model = model
                SaveSettings(STT_SETTINGS)
            end
            if is_selected then
                reaper.ImGui_SetItemDefaultFocus(ctx)
            end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Larger models = more accurate but slower. First use downloads model.")
    end
end

function RenderVoskSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Model Path:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local path_changed, new_path = reaper.ImGui_InputText(ctx, "##vosk_model",
        STT_SETTINGS.vosk_model_path)
    if path_changed then
        STT_SETTINGS.vosk_model_path = new_path
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Path to Vosk model directory (download from alphacephei.com/vosk/models)")
    end
end

function RenderEngineSettings(ctx, engine)
    if reaper.ImGui_BeginTable(ctx, "engine_settings", 2) then
        reaper.ImGui_TableSetupColumn(ctx, "label", reaper.ImGui_TableColumnFlags_WidthFixed(), 140)
        reaper.ImGui_TableSetupColumn(ctx, "input", reaper.ImGui_TableColumnFlags_WidthStretch())

        if engine == "azure" then
            RenderAzureSettings(ctx)
        elseif engine == "google_cloud" then
            RenderGoogleCloudSettings(ctx)
        elseif engine == "whisper" then
            RenderWhisperSettings(ctx)
        elseif engine == "vosk" then
            RenderVoskSettings(ctx)
        elseif engine == "google" then
            reaper.ImGui_TableNextRow(ctx)
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_TextWrapped(ctx, "No configuration needed!")
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_TextWrapped(ctx, "Uses free Google Speech Recognition API")
        end

        reaper.ImGui_EndTable(ctx)
    end
end

function RenderCommonSTTSettings(ctx, avail_width, slicerRightSpece)
    reaper.ImGui_Spacing(ctx)

    -- Language setting
    if reaper.ImGui_BeginTable(ctx, "common_settings", 2) then
        reaper.ImGui_TableSetupColumn(ctx, "label", reaper.ImGui_TableColumnFlags_WidthFixed(), 140)
        reaper.ImGui_TableSetupColumn(ctx, "input", reaper.ImGui_TableColumnFlags_WidthStretch())

        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, "Language:")
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local lang_changed, new_lang = reaper.ImGui_InputText(ctx, "##language", STT_SETTINGS.language)
        if lang_changed then
            STT_SETTINGS.language = new_lang
            SaveSettings(STT_SETTINGS)
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Language code (e.g., en-US, de-DE)")
        end

        reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    -- Sliders
    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local weight_changed, new_weight = reaper.ImGui_SliderDouble(ctx, "STT Weight", TUNABLE.stt_weight, 0.0, 1.0, "%.2f")
    if weight_changed then
        TUNABLE.stt_weight = new_weight
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_weight)
    end

    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local threshold_changed, new_threshold = reaper.ImGui_SliderDouble(ctx, "Peak Threshold", TUNABLE.stt_peak_threshold, 0.0, 1.0, "%.2f")
    if threshold_changed then
        TUNABLE.stt_peak_threshold = new_threshold
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_peak_threshold)
    end

    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local max_dur_changed, new_max_dur = reaper.ImGui_SliderInt(ctx, "Max Duration (s)", TUNABLE.stt_max_duration, 1, 60)
    if max_dur_changed then
        TUNABLE.stt_max_duration = new_max_dur
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_max_duration)
    end
end
