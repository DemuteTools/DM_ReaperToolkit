-- Voice Line Finder with ReaImGui
-- Matches edited clips to clean recording using local peak detection
-- Modified to prevent freezing with progress bar

-- Check if ReaImGui is available
if not reaper.ImGui_GetVersion then
    reaper.ShowMessageBox("ReaImGui extension is not installed!\n\nPlease install it from ReaPack.", "Error", 0)
    return
end

-- Load Common shared libraries
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local DEMUTE_ROOT = script_path
local COMMON      = DEMUTE_ROOT .. "Common/Scripts/"
dofile(COMMON .. "DM_Colors.lua")
dofile(COMMON .. "DM_Theme.lua")
DM = dofile(COMMON .. "DM_Library.lua")

-- Load modules
dofile(script_path .. "Modules/config.lua")
dofile(script_path .. "Modules/helpers.lua")
dofile(script_path .. "Modules/audio.lua")
dofile(script_path .. "Modules/peaks.lua")
dofile(script_path .. "Modules/matching.lua")
dofile(script_path .. "Modules/stt.lua")

-- LOCAL STATE

local ctx     = reaper.ImGui_CreateContext('Waveform Matcher')
local font_ui = reaper.ImGui_CreateFont("sans-serif", Theme.FONT_SIZE)
reaper.ImGui_Attach(ctx, font_ui)

local edited_items = {}
local clean_items = {}
local is_processing = false
local cancel_requested = false
local window_first_open = true

-- logo
local logo_image, logo_width, logo_height = DM.Image.LoadDemuteLogo()
logo_width  = logo_width  or 0
logo_height = logo_height or 0

-- UI Style constants
local UI = {
    BUTTON_WIDTH = 180,
    BUTTON_HEIGHT = 28,
    INPUT_WIDTH = 180,
    SLIDER_WIDTH = -1,  -- -1 = stretch to fill
    SECTION_SPACING = 8,
    ITEM_SPACING = 4,
}

-- SELECTION HANDLERS

function SelectEditedFiles()
    local num_selected = reaper.CountSelectedMediaItems(0)

    if num_selected == 0 then
        Log("ERROR: No items selected", COLORS.RED)
        return
    end

    -- Check all items are on the same track
    local first_track = reaper.GetMediaItem_Track(reaper.GetSelectedMediaItem(0, 0))

    edited_items = {}
    for i = 0, num_selected - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)

        if track ~= first_track then
            Log("ERROR: All edited items must be on the same track", COLORS.RED)
            edited_items = {}
            return
        end

        edited_items[#edited_items + 1] = item
    end

    Log(string.format("Selected %d edited item(s)", #edited_items), COLORS.GREEN)
end

function SelectCleanFiles()
    local num_selected = reaper.CountSelectedMediaItems(0)

    if num_selected == 0 then
        Log("ERROR: No items selected", COLORS.RED)
        return
    end

    clean_items = {}
    for i = 0, num_selected - 1 do
        clean_items[#clean_items + 1] = reaper.GetSelectedMediaItem(0, i)
    end

    Log(string.format("Selected %d clean recording(s)", #clean_items), COLORS.GREEN)
end

-- ASYNC PROCESSING LOGIC

local function start_load_audio(item, item_type)
    processing_state.current_item_name = DM.Item.GetName(item)
    Log(string.format("Loading %s: %s...", item_type, processing_state.current_item_name))

    if not InitAudioLoading(item) then
        Log(string.format("ERROR: Failed to initialize loading for %s", item_type), COLORS.RED)
        return false
    end

    return true
end

local function start_detect_peaks(prominence, item_type)
    Log(string.format("Detecting peaks in %s...", item_type))
    InitPeakDetection(processing_state.temp_audio, processing_state.temp_sr, prominence)
    return true
end

local function finalize_peak_detection(item)
    local peaks, envelope_data = FinalizePeakDetection()
    Log(string.format("Found %d peaks", #peaks), COLORS.CYAN)

    if #peaks < 1 then
        Log("ERROR: Not enough peaks. Try lowering prominence.", COLORS.RED)
        return nil, nil, nil
    end

    if TUNABLE.mark_peaks then
        -- Pass pre_extension offset so markers are placed relative to original item
        local pre_ext = processing_state.audio_load_state.pre_extension or 0
        AddMarkersToItem(item, peaks, nil, pre_ext)
    end
    return peaks, envelope_data, processing_state.temp_sr
end

local function setup_match_tracks(first_edited_item)
    local edited_track = reaper.GetMediaItem_Track(first_edited_item)
    local edited_track_idx = reaper.GetMediaTrackInfo_Value(edited_track, "IP_TRACKNUMBER") - 1

    local target_tracks = {}
    for i = 1, TUNABLE.num_match_tracks do
        local track, is_new = DM.Track.GetOrCreate(edited_track_idx + i, "Match #" .. i)
        target_tracks[i] = track

        local status = is_new and "Created" or "Reusing"
        local color = is_new and COLORS.GREEN or COLORS.GRAY
        Log(string.format("%s track: Match #%d", status, i), color)
    end

    return target_tracks
end


-- Initialize processing
function StartProcessing()
    -- Validate inputs
    if #edited_items == 0 then
        Log("ERROR: No edited items selected", COLORS.RED)
        return
    end
    if #clean_items == 0 then
        Log("ERROR: No clean recordings selected", COLORS.RED)
        return
    end

    -- Reset state using helper functions
    processing_state = {
        active = true, current_item = 0, total_items = #edited_items,
        current_phase = "loading_clean", current_item_name = "",
        current_clean_item = 0,
        clean_items_peaks = {},
        clean_items_envelope_data = {},
        clean_items_sr = {},
        -- STT state
        clean_items_stt = {},
        edited_stt = nil,
        target_tracks = nil, success_count = 0, fail_count = 0, undo_started = false,
        temp_audio = nil, temp_sr = nil, temp_offset = nil,
        temp_peaks = nil, temp_envelope_data = nil,
        audio_load_state = create_audio_load_state(),
        peak_detect_state = create_peak_detect_state()
    }

    is_processing = true
    cancel_requested = false  -- Reset cancel flag
    Log(string.format("Starting matching process with %d clean recording(s)...", #clean_items))
    reaper.defer(ProcessNextStep)
end

-- Cancel the current processing operation
function CancelProcessing()
    if not is_processing then
        return
    end

    cancel_requested = true
    Log("Cancelling...", COLORS.YELLOW)
end

-- Process one step at a time
function ProcessNextStep()
    if not processing_state.active then
        return
    end

    -- Check for cancellation request
    if cancel_requested then
        Log("Processing cancelled by user", COLORS.YELLOW)
        is_processing = false
        cancel_requested = false
        processing_state.active = false

        -- Clean up any undo state
        if processing_state.undo_started then
            reaper.Undo_EndBlock("Waveform Matcher (Cancelled)", -1)
        end

        return
    end

    -- Start undo block
    if not processing_state.undo_started then
        reaper.Undo_BeginBlock()
        processing_state.undo_started = true
    end

    -- Phase: Initialize clean recording loading
    if processing_state.current_phase == "loading_clean" then
        processing_state.current_clean_item = 1
        processing_state.current_phase = "loading_clean_audio"
        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: Load clean recording audio
    if processing_state.current_phase == "loading_clean_audio" then
        local clean_item = clean_items[processing_state.current_clean_item]
        if not start_load_audio(clean_item, string.format("clean recording %d/%d", processing_state.current_clean_item, #clean_items)) then
            FinishProcessing()
            return
        end
        processing_state.current_phase = "loading_clean_audio_chunked"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "loading_clean_audio_chunked" then
        local done = ProcessAudioLoadingChunk()

        if done then
            processing_state.current_phase = "detecting_clean_peaks"
        end

        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "detecting_clean_peaks" then
        if not start_detect_peaks(TUNABLE.peak_prominence, string.format("clean recording %d/%d", processing_state.current_clean_item, #clean_items)) then
            FinishProcessing()
            return
        end

        processing_state.current_phase = "processing_clean_peaks_chunked"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "processing_clean_peaks_chunked" then
        local done = ProcessPeakDetectionChunk()

        if done then
            local clean_item = clean_items[processing_state.current_clean_item]
            local peaks, envelope_data, sr = finalize_peak_detection(clean_item)

            if not peaks then
                FinishProcessing()
                return
            end

            -- Store results for this clean recording
            processing_state.clean_items_peaks[processing_state.current_clean_item] = peaks
            processing_state.clean_items_envelope_data[processing_state.current_clean_item] = envelope_data
            processing_state.clean_items_sr[processing_state.current_clean_item] = sr

            -- Move to next clean item or setup tracks (STT is done per-match now)
            if processing_state.current_clean_item < #clean_items then
                processing_state.current_clean_item = processing_state.current_clean_item + 1
                processing_state.current_phase = "loading_clean_audio"
            else
                processing_state.current_phase = "setup_tracks"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "setup_tracks" then
        processing_state.target_tracks = setup_match_tracks(edited_items[1])
        processing_state.current_phase = "processing_item"
        processing_state.current_item = 1
        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: Process each edited item
    if processing_state.current_phase == "processing_item" then
        if processing_state.current_item > #edited_items then
            FinishProcessing()
            return
        end

        processing_state.current_phase = "loading_edited_audio"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "loading_edited_audio" then
        local edited_item = edited_items[processing_state.current_item]
        Log(string.format("Processing item %d/%d", processing_state.current_item, #edited_items), COLORS.YELLOW)

        if not start_load_audio(edited_item, "edited item") then
            processing_state.fail_count = processing_state.fail_count + 1
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
            reaper.defer(ProcessNextStep)
            return
        end

        processing_state.current_phase = "loading_edited_audio_chunked"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "loading_edited_audio_chunked" then
        local done = ProcessAudioLoadingChunk()

        if done then
            processing_state.current_phase = "detecting_edited_peaks"
        end

        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "detecting_edited_peaks" then
        if not start_detect_peaks(TUNABLE.peak_prominence, "edited item") then
            processing_state.fail_count = processing_state.fail_count + 1
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
            reaper.defer(ProcessNextStep)
            return
        end

        processing_state.current_phase = "processing_edited_peaks_chunked"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "processing_edited_peaks_chunked" then
        local done = ProcessPeakDetectionChunk()

        if done then
            -- If STT enabled, transcribe edited item before matching
            if TUNABLE.stt_enabled then
                processing_state.current_phase = "stt_edited"
            else
                processing_state.current_phase = "matching"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: STT for edited item
    if processing_state.current_phase == "stt_edited" then
        local edited_item = edited_items[processing_state.current_item]
        Log("  Transcribing edited item...", COLORS.CYAN)

        local wav_path = ExportItemToWav(edited_item)
        if wav_path then
            local stt_result = TranscribeWithEngine(wav_path)
            os.remove(wav_path)

            if stt_result and stt_result.text ~= "" then
                processing_state.edited_stt = stt_result
                Log(string.format("  Transcribed: '%s'", stt_result.text), COLORS.GREEN)
            else
                processing_state.edited_stt = nil
                Log("  STT returned no text", COLORS.YELLOW)
            end
        else
            processing_state.edited_stt = nil
            Log("  Failed to export audio for STT", COLORS.YELLOW)
        end

        processing_state.current_phase = "matching"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "matching" then
        local edited_item = edited_items[processing_state.current_item]
        local edited_peaks, edited_envelope_data, edited_sr = finalize_peak_detection(edited_item)
        -- Store edited peaks for later use in CreateMatchedItem (peak alignment)
        processing_state.edited_peaks = edited_peaks
        -- Calculate first peak offset (audio content before first peak)
        local edited_first_peak_offset = (edited_peaks and edited_peaks[1]) and edited_peaks[1].time or 0
        processing_state.edited_first_peak_offset = edited_first_peak_offset
        local edited_duration = reaper.GetMediaItemInfo_Value(edited_item, "D_LENGTH")
        -- Store extension info for trimming matched items later
        local als = processing_state.audio_load_state
        processing_state.edited_pre_extension = als.pre_extension or 0
        processing_state.edited_post_extension = als.post_extension or 0
        processing_state.edited_original_duration = als.original_duration or edited_duration

        -- Calculate extended duration for creating matched items (will be trimmed back later)
        local extended_duration = processing_state.edited_pre_extension + edited_duration + processing_state.edited_post_extension
        processing_state.stt_edited_duration_extended = extended_duration

        -- Try matching against all clean recordings (peak matching only)
        local all_matches = {}

        for clean_idx = 1, #clean_items do
            local matches = CompareTransientPatterns(
                processing_state.clean_items_peaks[clean_idx],
                edited_peaks,
                processing_state.clean_items_envelope_data[clean_idx],
                edited_envelope_data
            )

            if matches and #matches > 0 then
                -- Tag each match with which clean recording it came from
                for _, match in ipairs(matches) do
                    match.clean_item_index = clean_idx
                    all_matches[#all_matches + 1] = match
                end
            end
        end

        if #all_matches == 0 then
            Log("  ERROR: No matches found in any clean recording", COLORS.RED)
            processing_state.fail_count = processing_state.fail_count + 1
            -- Move to next item
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
        else
            -- Sort all matches by peak score first
            table.sort(all_matches, function(a, b) return a.score > b.score end)

            -- Store matches for potential STT verification
            processing_state.stt_all_matches = all_matches
            -- Use extended duration if extension was applied, otherwise original
            processing_state.stt_edited_duration = processing_state.stt_edited_duration_extended or edited_duration

            -- STT verification for all candidates above threshold (if enabled)
            if TUNABLE.stt_enabled and processing_state.edited_stt and processing_state.edited_stt.text ~= "" then
                -- Count how many matches exceed the STT peak threshold
                local candidates_above_threshold = 0
                for _, match in ipairs(all_matches) do
                    if match.debug_info.peak_score >= TUNABLE.stt_peak_threshold then
                        candidates_above_threshold = candidates_above_threshold + 1
                    end
                end

                processing_state.stt_candidates_to_verify = candidates_above_threshold
                processing_state.stt_current_candidate = 1
                Log(string.format("  Verifying %d matches (peak >= %.2f) with STT...",
                    processing_state.stt_candidates_to_verify, TUNABLE.stt_peak_threshold), COLORS.CYAN)
                processing_state.current_phase = "stt_verify"
            else
                -- No STT, go directly to creating matches
                processing_state.current_phase = "create_matches"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: STT verification (one candidate per cycle for progress updates)
    if processing_state.current_phase == "stt_verify" then
        local i = processing_state.stt_current_candidate
        local all_matches = processing_state.stt_all_matches
        local edited_text = processing_state.edited_stt.text
        local edited_duration = processing_state.stt_edited_duration
        -- Use original duration for STT (not extended duration used for peak matching)
        local stt_duration = processing_state.edited_original_duration or edited_duration

        if i <= #all_matches then
            local match = all_matches[i]
            local peak_score = match.debug_info.peak_score

            -- Only do STT if peak score is above threshold
            if peak_score >= TUNABLE.stt_peak_threshold then
                local clean_item = clean_items[match.clean_item_index]

                -- Export the matching region from clean recording
                -- match.time = where extended audio starts in clean (already adjusted for first peak)
                -- Add pre_ext to get to where the ORIGINAL item starts
                -- Subtract first_peak_in_original to capture audio before first peak in original item
                local pre_ext = processing_state.edited_pre_extension or 0
                local first_peak_in_original = math.max(0, processing_state.edited_first_peak_offset - pre_ext)
                local clean_export_start = match.time + pre_ext - first_peak_in_original
                local wav_path = ExportItemToWav(clean_item, clean_export_start, stt_duration)
                if wav_path then
                    local clean_stt = TranscribeWithEngine(wav_path)
                    os.remove(wav_path)

                    if clean_stt and clean_stt.text and clean_stt.text ~= "" then
                        local stt_score = TextSimilarity(edited_text, clean_stt.text)

                        -- Combine scores
                        local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                        match.score = combined_score
                        match.debug_info.stt_score = stt_score
                        match.debug_info.edited_text = edited_text
                        match.debug_info.matched_clean_text = clean_stt.text

                        Log(string.format("    Match %d (of %d above threshold): Peak=%.2f, STT=%.2f -> Combined=%.2f",
                            i, processing_state.stt_candidates_to_verify, peak_score, stt_score, combined_score), COLORS.GRAY)
                    else
                        -- STT failed, recalculate score with stt_score = 0 (penalizes the match)
                        local stt_score = 0
                        local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                        match.score = combined_score
                        match.debug_info.stt_score = stt_score
                        match.debug_info.edited_text = edited_text
                        match.debug_info.matched_clean_text = "(STT failed)"
                        Log(string.format("    Match %d: STT failed, Peak=%.2f -> Combined=%.2f (penalized)",
                            i, peak_score, combined_score), COLORS.YELLOW)
                    end
                else
                    -- WAV export failed, penalize the match
                    local stt_score = 0
                    local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                    match.score = combined_score
                    match.debug_info.stt_score = stt_score
                    match.debug_info.edited_text = edited_text
                    match.debug_info.matched_clean_text = "(Export failed)"
                    Log(string.format("    Match %d: WAV export failed, Peak=%.2f -> Combined=%.2f (penalized)",
                        i, peak_score, combined_score), COLORS.RED)
                end
            else
                -- Match below threshold, set STT score to 0 and recalculate (penalizes the match)
                local stt_score = 0
                local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                match.score = combined_score
                match.debug_info.stt_score = stt_score
                match.debug_info.edited_text = edited_text
                match.debug_info.matched_clean_text = "(Below threshold)"
            end

            -- Move to next candidate
            processing_state.stt_current_candidate = i + 1
        else
            -- Done with STT verification, re-sort and create matches
            table.sort(all_matches, function(a, b) return a.score > b.score end)
            processing_state.current_phase = "create_matches"
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: Create matched items
    if processing_state.current_phase == "create_matches" then
        local all_matches = processing_state.stt_all_matches
        local edited_item = edited_items[processing_state.current_item]
        local edited_duration = processing_state.stt_edited_duration

        local num_matches_to_create = math.min(TUNABLE.num_match_tracks, #all_matches)
        Log(string.format("n/  Found %d total matches across %d clean recording(s):", #all_matches, #clean_items), COLORS.GREEN)

        for match_idx = 1, num_matches_to_create do
            local match = all_matches[match_idx]
            local clean_item = clean_items[match.clean_item_index]
            local clean_name = DM.Item.GetName(clean_item)

            Log(string.format("    Match #%d: %.3fs (score: %.3f) from '%s'",
                match_idx, match.time, match.score, clean_name), COLORS.CYAN)

            if match.debug_info and match.debug_info.envelope_mismatches > 0 then
                Log(string.format("      Envelope mismatches: %.2f", match.debug_info.envelope_mismatches), COLORS.ORANGE)
            end

            -- Show STT debug info if available
            if TUNABLE.stt_enabled and match.debug_info then
                if match.debug_info.stt_score and match.debug_info.stt_score > 0 then
                    Log(string.format("      Peak: %.2f, STT: %.2f",
                        match.debug_info.peak_score or 0, match.debug_info.stt_score), COLORS.GRAY)
                    if match.debug_info.edited_text and match.debug_info.edited_text ~= "" then
                        local edited_preview = string.sub(match.debug_info.edited_text, 1, 50)
                        Log(string.format("      Edited: '%s'%s", edited_preview,
                            #match.debug_info.edited_text > 50 and "..." or ""), COLORS.GRAY)
                    end
                    if match.debug_info.matched_clean_text and match.debug_info.matched_clean_text ~= "" then
                        local clean_preview = string.sub(match.debug_info.matched_clean_text, 1, 50)
                        Log(string.format("      Clean: '%s'%s", clean_preview,
                            #match.debug_info.matched_clean_text > 50 and "..." or ""), COLORS.GRAY)
                    end
                elseif match.debug_info.peak_score then
                    Log(string.format("      Peak score: %.2f (no STT)", match.debug_info.peak_score), COLORS.GRAY)
                end
            end

            -- Get peak data for alignment
            local edited_peaks = processing_state.edited_peaks
            local clean_peaks = processing_state.clean_items_peaks[match.clean_item_index]

            CreateMatchedItem(clean_item, match.time, edited_duration, edited_item,
                              processing_state.target_tracks[match_idx], edited_peaks, clean_peaks)
        end

        processing_state.success_count = processing_state.success_count + 1

        -- Clean up STT state
        processing_state.stt_all_matches = nil
        processing_state.stt_current_candidate = 0
        processing_state.stt_candidates_to_verify = 0

        -- Move to next item
        processing_state.current_item = processing_state.current_item + 1
        processing_state.current_phase = "processing_item"
        reaper.defer(ProcessNextStep)
        return
    end
end

function FinishProcessing()
    processing_state.current_phase = "complete"

    if processing_state.undo_started then
        reaper.Undo_EndBlock("Match waveforms", -1)
        reaper.UpdateArrange()
    end

    Log("=== Completed ===", COLORS.WHITE)
    if processing_state.success_count > 0 then
        Log(string.format("Success: %d", processing_state.success_count), COLORS.GREEN)
    end
    if processing_state.fail_count > 0 then
        Log(string.format("Failed: %d", processing_state.fail_count), COLORS.RED)
    end

    is_processing = false
    processing_state.active = false
end

-- ─── Section card helpers ────────────────────────────────────────────────────
-- Each collapsible section is wrapped in a bordered child panel so the
-- CollapsingHeader and its content form a single visual card.
-- SectionBegin returns true when expanded; always call SectionEnd regardless.

-- Section card helpers delegated to DM_Theme (shared with other tools).
local function SectionBegin(label, default_open) return Theme.SectionBegin(ctx, label, default_open) end
local function SectionEnd(open)                  Theme.SectionEnd(ctx, open)                         end

-- GUI

function Loop()
    -- Set initial window size on first open
    if window_first_open then
        reaper.ImGui_SetNextWindowSize(ctx, 500, 650, reaper.ImGui_Cond_FirstUseEver())
        window_first_open = false
    end

    -- Set minimum window size to prevent button overlap
    -- Match Waveforms (200) + Cancel (100) + Reset Settings (150) + spacing/padding (~50) = 500
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 500, 400, math.huge, math.huge)

    reaper.ImGui_PushFont(ctx, font_ui, Theme.FONT_SIZE)
    Theme.PushWindow(ctx)
    local visible, open = reaper.ImGui_Begin(ctx, 'Waveform Matcher', true,
        Theme.WindowFlags() | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
    Theme.PopWindow(ctx)

    if visible then
        Theme.DrawFocusBorder(ctx)
        Theme.PushUI(ctx)
        -- Check for ESC key to cancel processing
        if is_processing and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
            CancelProcessing()
        end

        local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        local slicerRightSpece = 160

        -- ─── Input Selection ─────────────────────────────────────────────────

        local sec_input = SectionBegin("Input Selection", true)
        if sec_input then
            if reaper.ImGui_BeginTable(ctx, "input_table", 3, reaper.ImGui_TableFlags_None()) then
                reaper.ImGui_TableSetupColumn(ctx, "btn", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.BUTTON_WIDTH)
                reaper.ImGui_TableSetupColumn(ctx, "status", reaper.ImGui_TableColumnFlags_WidthStretch())
                reaper.ImGui_TableSetupColumn(ctx, "clear", reaper.ImGui_TableColumnFlags_WidthFixed(), 50)

                -- Row 1: Edited Items
                reaper.ImGui_TableNextRow(ctx)
                reaper.ImGui_TableNextColumn(ctx)
                if reaper.ImGui_Button(ctx, "Load Edited Item(s)", UI.BUTTON_WIDTH, UI.BUTTON_HEIGHT) then
                    SelectEditedFiles()
                end

                reaper.ImGui_TableNextColumn(ctx)
                local edited_color = #edited_items > 0 and COLORS.GREEN or COLORS.GRAY
                local edited_icon = #edited_items > 0 and "[OK]" or "[--]"
                reaper.ImGui_TextColored(ctx, reaper.ImGui_ColorConvertDouble4ToU32(table.unpack(edited_color)),
                    string.format(" %s %d item(s)", edited_icon, #edited_items))

                reaper.ImGui_TableNextColumn(ctx)
                if #edited_items > 0 then
                    if Theme.StyledBtn(ctx, "Clear##edited", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, 0, UI.BUTTON_HEIGHT) then
                        edited_items = {}
                        Log("Cleared edited items", COLORS.GRAY)
                    end
                end

                -- Row 2: Clean Recording
                reaper.ImGui_TableNextRow(ctx)
                reaper.ImGui_TableNextColumn(ctx)
                if reaper.ImGui_Button(ctx, "Load Clean Item(s)", UI.BUTTON_WIDTH, UI.BUTTON_HEIGHT) then
                    SelectCleanFiles()
                end

                reaper.ImGui_TableNextColumn(ctx)
                local clean_color = #clean_items > 0 and COLORS.GREEN or COLORS.GRAY
                local clean_icon = #clean_items > 0 and "[OK]" or "[--]"
                reaper.ImGui_TextColored(ctx, reaper.ImGui_ColorConvertDouble4ToU32(table.unpack(clean_color)),
                    string.format(" %s %d item(s)", clean_icon, #clean_items))

                reaper.ImGui_TableNextColumn(ctx)
                if #clean_items > 0 then
                    if Theme.StyledBtn(ctx, "Clear##clean", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, 0, UI.BUTTON_HEIGHT) then
                        clean_items = {}
                        Log("Cleared clean items", COLORS.GRAY)
                    end
                end

                reaper.ImGui_EndTable(ctx)
            end
        end
        SectionEnd(sec_input)

        -- ─── Matching Settings ────────────────────────────────────────────────

        local sec_match = SectionBegin("Matching Settings", true)
        if sec_match then
            -- Peak Prominence
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local changed, new_val = reaper.ImGui_SliderDouble(ctx, "Peak Prominence", TUNABLE.peak_prominence, 0.0, 1.0, "%.2f")
            if changed then
                TUNABLE.peak_prominence = new_val
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.peak_prominence)
            end

            -- Number of matches
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local changed2, new_val2 = reaper.ImGui_SliderInt(ctx, "Nr Of matches", TUNABLE.num_match_tracks, 1, 10)
            if changed2 then
                TUNABLE.num_match_tracks = new_val2
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.num_match_tracks)
            end
        end
        SectionEnd(sec_match)

        -- ─── Speech-to-Text (STT) ─────────────────────────────────────────────

        if CONFIG.HIDE_STT_SETTINGS then
            local sec_stt = SectionBegin("Speech-to-Text Configuration", true)
            if sec_stt then
                -- Enable checkbox with validation
                local stt_changed, stt_enabled = reaper.ImGui_Checkbox(ctx, "Enable STT Comparison", TUNABLE.stt_enabled)
                if stt_changed then
                    TUNABLE.stt_enabled = stt_enabled
                    if stt_enabled then
                        if ValidateSTTSetup() then
                            Log("STT enabled", COLORS.GREEN)
                        else
                            Log("STT enabled but setup incomplete - check messages above", COLORS.YELLOW)
                        end
                    else
                        Log("STT disabled", COLORS.GRAY)
                    end
                    SaveSettings(MY_SETTINGS)
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_enabled)
                end

                if TUNABLE.stt_enabled then
                    reaper.ImGui_Spacing(ctx)
                    reaper.ImGui_Indent(ctx, 10)

                    -- Engine Selection Dropdown
                    local engines = {"Google (Free)", "Google Cloud", "Azure", "Whisper (Local)", "Vosk (Local)"}
                    local engine_ids = {"google", "google_cloud", "azure", "whisper", "vosk"}
                    local current_idx = GetEngineIndex(MY_SETTINGS.engine, engine_ids)

                    reaper.ImGui_Text(ctx, "STT Engine:")
                    reaper.ImGui_SameLine(ctx)
                    reaper.ImGui_SetNextItemWidth(ctx, 200)
                    if reaper.ImGui_BeginCombo(ctx, "##engine", engines[current_idx]) then
                        for i, name in ipairs(engines) do
                            local is_selected = (i == current_idx)
                            if reaper.ImGui_Selectable(ctx, name, is_selected) then
                                MY_SETTINGS.engine = engine_ids[i]
                                SaveSettings(MY_SETTINGS)
                                Log(string.format("STT engine changed to: %s", name), COLORS.GREEN)
                            end
                            if is_selected then
                                reaper.ImGui_SetItemDefaultFocus(ctx)
                            end
                        end
                        reaper.ImGui_EndCombo(ctx)
                    end
                    if reaper.ImGui_IsItemHovered(ctx) then
                        reaper.ImGui_SetTooltip(ctx, "Choose which speech-to-text engine to use")
                    end

                    reaper.ImGui_Spacing(ctx)

                    -- Dynamic engine-specific settings
                    RenderEngineSettings(ctx, MY_SETTINGS.engine)

                    -- Common settings (language, sliders)
                    RenderCommonSTTSettings(ctx, avail_width, slicerRightSpece)

                    reaper.ImGui_Unindent(ctx, 10)
                end
            end
            SectionEnd(sec_stt)
        end

        -- ─── Advanced Settings ────────────────────────────────────────────────

        local sec_adv = SectionBegin("Advanced Settings", false)
        if sec_adv then
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local c1, v1 = reaper.ImGui_SliderDouble(ctx, "Min peak distance(ms)", TUNABLE.min_peak_distance_ms, 10, 100, "%.0f")
            if c1 then
                TUNABLE.min_peak_distance_ms = v1
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.min_peak_distance_ms)
            end

            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local c3, v3 = reaper.ImGui_SliderDouble(ctx, "Min Score", TUNABLE.min_score, 0.0, 1.0, "%.2f")
            if c3 then
                TUNABLE.min_score = v3
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.min_score)
            end

            local makrPeaks_changed, makrPeaks_enabled = reaper.ImGui_Checkbox(ctx, "Show Debug Peak Markers", TUNABLE.mark_peaks)
            if makrPeaks_changed then
                TUNABLE.mark_peaks = makrPeaks_enabled
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.mark_peaks)
            end

            local alignPeaks_changed, alignPeaks_enabled = reaper.ImGui_Checkbox(ctx, "Align First Peaks", TUNABLE.align_peaks)
            if alignPeaks_changed then
                TUNABLE.align_peaks = alignPeaks_enabled
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.align_peaks)
            end

            local preSilence_changed, preSilence_enabled = reaper.ImGui_Checkbox(ctx, "Allow no peaks before first edited peak", TUNABLE.No_peaks_before_first)
            if preSilence_changed then
                TUNABLE.No_peaks_before_first = preSilence_enabled
                SaveSettings(MY_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.No_peaks_before_first)
            end
        end
        SectionEnd(sec_adv)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Run Button & Progress
        -- ═══════════════════════════════════════════════════════════════════════

        local can_match = #edited_items > 0 and #clean_items > 0 and not is_processing

        -- Match Waveforms button (disabled when processing)
        if not can_match then
            reaper.ImGui_BeginDisabled(ctx)
        end
        if Theme.StyledBtn(ctx, "Match Waveforms", Theme.C.export_btn, Theme.C.export_hov, Theme.C.export_act, 200, 40) then
            StartProcessing()
        end
        if not can_match then
            reaper.ImGui_EndDisabled(ctx)
        end

        -- Cancel button (only shown during processing)
        if is_processing then
            reaper.ImGui_SameLine(ctx)
            if Theme.StyledBtn(ctx, "Cancel", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, 100, 40) then
                CancelProcessing()
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, "Cancel the current matching process")
            end
        end

        -- Reset to Defaults button (right-aligned)
        reaper.ImGui_SameLine(ctx)
        local cursor_x = reaper.ImGui_GetCursorPosX(ctx)
        local log_avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_SetCursorPosX(ctx, cursor_x + log_avail_width - 150)
        if Theme.StyledBtn(ctx, "Reset Settings", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act, 150, 40) then
            ResetToDefaults()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Reset all settings to their default values")
        end

        -- Progress bar
        if is_processing and processing_state.active then
            reaper.ImGui_Spacing(ctx)

            -- Progress allocation configuration (adjust these to rebalance)
            local PROGRESS_CONFIG = {
                loading_clean_start = 0.01,
                loading_clean_range = 0.09,      -- 1-10%
                detecting_clean_start = 0.10,
                detecting_clean_range = 0.60,    -- 10-70%
                setup_tracks = 0.70,
                items_start = 0.70,
                items_range = 0.30,              -- 70-100%
                item_audio_portion = 0.08,       -- Within each item
                item_peaks_portion = 0.12,       -- Within each item
                item_match_portion = 0.02,       -- Within each item (matching peak patterns)
                item_stt_portion = 0.06,         -- Within each item (STT verification)
                item_create_portion = 0.02       -- Within each item (creating matched items)
            }

            local progress = 0
            local phase_desc = ""
            local cp = processing_state.current_phase

            -- Calculate progress based on current phase
            if cp == "loading_clean" then
                progress = PROGRESS_CONFIG.loading_clean_start
                phase_desc = "Initializing"

            elseif cp == "loading_clean_audio" or cp == "loading_clean_audio_chunked" then
                -- Calculate which portion of the total clean processing range this item occupies
                local per_item_loading = PROGRESS_CONFIG.loading_clean_range / #clean_items
                local per_item_detecting = PROGRESS_CONFIG.detecting_clean_range / #clean_items

                -- Base progress for this clean item (accounts for all previous items)
                local item_base = PROGRESS_CONFIG.loading_clean_start
                item_base = item_base + ((processing_state.current_clean_item - 1) * (per_item_loading + per_item_detecting))

                -- Add progress within the loading phase for this item
                local als = processing_state.audio_load_state
                local within_phase = (als.progress_percent / 100) * per_item_loading
                progress = item_base + within_phase
                phase_desc = string.format("Loading clean audio (%d/%d)", processing_state.current_clean_item, #clean_items)

            elseif cp == "detecting_clean_peaks" or cp == "processing_clean_peaks_chunked" then
                local pds = processing_state.peak_detect_state
                local phase_names = {
                    downsample = "Downsampling",
                    envelope = "Creating envelope",
                    smooth = "Smoothing",
                    filter_peaks = "Filtering peaks"
                }
                phase_desc = phase_names[pds.phase] or "Detecting peaks"

                if pds.phase == "find_peaks" then
                    phase_desc = pds.find_peaks_subphase == "calc_threshold" and "Calculating threshold" or "Finding peaks"
                end

                phase_desc = string.format("%s (%d/%d)", phase_desc, processing_state.current_clean_item, #clean_items)

                -- Calculate which portion of the total clean processing range this item occupies
                local per_item_loading = PROGRESS_CONFIG.loading_clean_range / #clean_items
                local per_item_detecting = PROGRESS_CONFIG.detecting_clean_range / #clean_items

                -- Base progress for this clean item (includes loading phase for this item)
                local item_base = PROGRESS_CONFIG.loading_clean_start
                item_base = item_base + ((processing_state.current_clean_item - 1) * (per_item_loading + per_item_detecting))
                item_base = item_base + per_item_loading  -- Add the completed loading phase

                -- Add progress within the detecting phase for this item
                local within_phase = (pds.progress_percent / 100) * per_item_detecting
                progress = item_base + within_phase

            elseif cp == "setup_tracks" then
                progress = PROGRESS_CONFIG.setup_tracks
                phase_desc = "Setting up tracks"

            else
                -- All item processing phases (edited items)
                local base = PROGRESS_CONFIG.items_start
                local item_idx = processing_state.current_item - 1
                local total = processing_state.total_items

                -- Calculate per-item range allocation
                local per_item_range = PROGRESS_CONFIG.items_range / total
                local per_item_audio = PROGRESS_CONFIG.item_audio_portion / total
                local per_item_peaks = PROGRESS_CONFIG.item_peaks_portion / total
                local per_item_match = PROGRESS_CONFIG.item_match_portion / total
                local per_item_stt = PROGRESS_CONFIG.item_stt_portion / total

                -- Base progress accounting for all completed items
                local item_base = base + (item_idx * per_item_range)

                if cp == "processing_item" then
                    progress = item_base
                    phase_desc = string.format("Item %d/%d", processing_state.current_item, total)

                elseif cp == "loading_edited_audio" or cp == "loading_edited_audio_chunked" then
                    local als = processing_state.audio_load_state
                    local within_phase = (als.progress_percent / 100) * per_item_audio
                    progress = item_base + within_phase
                    phase_desc = string.format("Loading audio (%d/%d)", processing_state.current_item, total)

                elseif cp == "detecting_edited_peaks" or cp == "processing_edited_peaks_chunked" then
                    local pds = processing_state.peak_detect_state

                    -- Base includes completed audio loading phase
                    local subphase_base = item_base + per_item_audio
                    local within_phase = (pds.progress_percent / 100) * per_item_peaks
                    progress = subphase_base + within_phase

                    local phase_names = {
                        downsample = "Downsampling",
                        envelope = "Creating envelope",
                        smooth = "Smoothing"
                    }
                    phase_desc = phase_names[pds.phase] or "Detecting peaks"

                    if pds.phase == "find_peaks" then
                        phase_desc = pds.find_peaks_subphase == "calc_threshold" and "Calculating threshold" or "Finding peaks"
                    end
                    phase_desc = string.format("%s (%d/%d)", phase_desc, processing_state.current_item, total)

                elseif cp == "stt_edited" then
                    -- Transcribing edited item (happens once per item before matching)
                    local base_progress = item_base + per_item_audio + per_item_peaks
                    progress = base_progress
                    phase_desc = string.format("Transcribing edited item (%d/%d)", processing_state.current_item, total)

                elseif cp == "matching" then
                    -- Base includes completed audio loading and peak detection phases
                    progress = item_base + per_item_audio + per_item_peaks
                    phase_desc = string.format("Matching item %d/%d", processing_state.current_item, total)

                elseif cp == "stt_verify" then
                    -- STT verification in progress
                    local base_progress = item_base + per_item_audio + per_item_peaks + per_item_match
                    local stt_progress = 0
                    local total_matches = processing_state.stt_all_matches and #processing_state.stt_all_matches or 1
                    if total_matches > 0 then
                        stt_progress = (processing_state.stt_current_candidate / total_matches) * per_item_stt
                    end
                    progress = base_progress + stt_progress
                    phase_desc = string.format("STT verification: %d above threshold (%d/%d)",
                        processing_state.stt_candidates_to_verify,
                        processing_state.current_item,
                        total)

                elseif cp == "create_matches" then
                    -- Creating matched items
                    progress = item_base + per_item_audio + per_item_peaks + per_item_match + per_item_stt
                    phase_desc = string.format("Creating matches (%d/%d)", processing_state.current_item, total)

                elseif cp == "complete" then
                    progress = 1.0
                    phase_desc = "Complete"
                end
            end

            local progress_text = string.format("%s: %d%%", phase_desc, math.floor(progress * 100))
            reaper.ImGui_ProgressBar(ctx, progress, avail_width, 0, progress_text)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Log (expands to fill remaining space)
        -- ═══════════════════════════════════════════════════════════════════════
        reaper.ImGui_Text(ctx, "Log:")
        reaper.ImGui_SameLine(ctx)

        -- Clear log button (right-aligned)
        local cursor_x = reaper.ImGui_GetCursorPosX(ctx)
        local log_avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_SetCursorPosX(ctx, cursor_x + log_avail_width - 45)
        if Theme.StyledBtn(ctx, "Clear##log", Theme.C.cancel, Theme.C.cancel_hov, Theme.C.cancel_act) then
            report_log = {}
        end

        -- Build log text for selectable display
        local log_text = ""
        for i = #report_log, 1, -1 do
            log_text = log_text .. report_log[i].text .. "\n"
        end

        -- Use remaining height for the log (minimum 100px)
        local log_width, log_height = reaper.ImGui_GetContentRegionAvail(ctx)
        log_height = math.max(log_height, 100)

        -- logo size calculation
        local avail = reaper.ImGui_GetContentRegionAvail(ctx)
        local logo_display_width = 120
        local logo_display_height = logo_display_width * (logo_height / logo_width)

        -- Use InputTextMultiline with ReadOnly flag for selectable/copyable text
        reaper.ImGui_InputTextMultiline(ctx, "##log", log_text, log_width, log_height - logo_display_height,
            reaper.ImGui_InputTextFlags_ReadOnly())

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Logo
        -- ═══════════════════════════════════════════════════════════════════════

        if logo_image then

            
            reaper.ImGui_SetCursorPosX(ctx, (avail - logo_display_width) / 2)
            reaper.ImGui_Image(ctx, logo_image, logo_display_width, logo_display_height)
            reaper.ImGui_Spacing(ctx)
        end
        Theme.PopUI(ctx)
        reaper.ImGui_End(ctx)
    end

    reaper.ImGui_PopFont(ctx)

    if open then
        reaper.defer(Loop)
    end
end

-- INITIALIZATION

Log("Waveform Matcher v1.0")
Log("Load edited items and clean recording(s), then click Match.")

reaper.defer(Loop)
