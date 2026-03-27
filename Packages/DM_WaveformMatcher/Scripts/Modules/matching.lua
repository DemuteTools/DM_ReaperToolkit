-- compareWaveform/matching.lua
-- Pattern matching algorithm

local function get_envelope_at_time(envelope_data, time_seconds)
    if not envelope_data then return 0 end

    local sample_index = DM.Time.ToSample(time_seconds, envelope_data.sample_rate)
    sample_index = math.max(1, math.min(#envelope_data.envelope, sample_index))

    return envelope_data.envelope[sample_index] or 0
end

local function check_envelope_mismatch(clean_env_data, edited_env_data, clean_time, edited_time, window_size)
    if not clean_env_data or not edited_env_data then
        return false, 0
    end

    local mismatches = {}

    -- Sample envelope at multiple points
    for i = 0, CONFIG.ENVELOPE_CHECK_SAMPLES - 1 do
        local progress = i / (CONFIG.ENVELOPE_CHECK_SAMPLES - 1) - 0.5  -- -0.5 to 0.5
        local offset = progress * window_size

        local clean_val = get_envelope_at_time(clean_env_data, clean_time + offset)
        local edited_val = get_envelope_at_time(edited_env_data, edited_time + offset)

        -- Check if either is active (loud)
        if clean_val > CONFIG.ENVELOPE_ACTIVE_THRESHOLD or edited_val > CONFIG.ENVELOPE_ACTIVE_THRESHOLD then
            mismatches[#mismatches + 1] = math.abs(clean_val - edited_val)
        end
    end

    if #mismatches == 0 then return false, 0 end

    -- Calculate average mismatch
    local sum = 0
    for _, val in ipairs(mismatches) do
        sum = sum + val
    end
    local avg_mismatch = sum / #mismatches
    local mismatch_ratio = #mismatches / CONFIG.ENVELOPE_CHECK_SAMPLES

    return mismatch_ratio > CONFIG.ENVELOPE_MISMATCH_THRESHOLD, avg_mismatch
end

local function normalize_amplitudes(transients)
    -- Find max amplitude
    local max_amp = 0
    for _, t in ipairs(transients) do
        max_amp = math.max(max_amp, t.amplitude or 1.0)
    end
    max_amp = math.max(max_amp, 1.0)  -- Avoid division by zero

    -- Normalize
    local normalized = {}
    for _, t in ipairs(transients) do
        normalized[#normalized + 1] = {
            time = t.time,
            amplitude = (t.amplitude or 1.0) / max_amp,
            original = t
        }
    end
    return normalized
end

function CompareTransientPatterns(clean_transients, edited_transients, clean_envelope_data, edited_envelope_data)
    if #edited_transients < 1 or #clean_transients < 1 then
        return nil
    end

    local matches = {}
    local edited_duration = edited_transients[#edited_transients].time - edited_transients[1].time
    local edited_start_offset = edited_transients[1].time

    -- Adaptive parameters based on clip length
    local is_short_clip = #edited_transients <= CONFIG.short_clip_threshold
    local is_very_short = #edited_transients <= CONFIG.VERY_SHORT_CLIP_THRESHOLD

    local max_tolerance = is_short_clip and CONFIG.max_tolerance_short or CONFIG.max_tolerance_long
    local tolerance_buffer = is_short_clip and CONFIG.TOLERANCE_BUFFER_SHORT or CONFIG.TOLERANCE_BUFFER_LONG
    local missing_peak_penalty = is_short_clip and CONFIG.missing_peak_penalty_short or CONFIG.missing_peak_penalty_long
    local extra_peak_penalty = is_short_clip and CONFIG.extra_peak_penalty_short or CONFIG.extra_peak_penalty_long

    if is_very_short then
        extra_peak_penalty = CONFIG.extra_peak_penalty_very_short
    end

    local clean_normalized = normalize_amplitudes(clean_transients)
    local edited_normalized = normalize_amplitudes(edited_transients)

    -- Try every clean peak as a potential starting position
    for start_idx = 1, #clean_normalized do
        local match_start_time = clean_normalized[start_idx].time
        local match_end_time = match_start_time + edited_duration + tolerance_buffer

        -- Check for peaks before match position (pre-silence filter)
        if TUNABLE.require_pre_silence and edited_start_offset > 0 then
            local pre_region_start = match_start_time - edited_start_offset
            local has_pre_peak = false
            for j = 1, start_idx - 1 do
                if clean_normalized[j].time >= pre_region_start and clean_normalized[j].time < match_start_time then
                    has_pre_peak = true
                    break
                end
            end
            if has_pre_peak then
                goto continue
            end
        end

        -- Get all clean peaks within this potential match region
        local clean_peaks_in_region = {}
        for j = start_idx, #clean_normalized do
            if clean_normalized[j].time >= match_start_time and clean_normalized[j].time <= match_end_time then
                clean_peaks_in_region[#clean_peaks_in_region + 1] = clean_normalized[j]
            elseif clean_normalized[j].time > match_end_time then
                break
            end
        end

        -- Check peak count ratio
        local min_peaks_ratio = is_short_clip and CONFIG.MIN_PEAKS_RATIO_SHORT or CONFIG.MIN_PEAKS_RATIO_LONG
        if #clean_peaks_in_region < #edited_normalized * min_peaks_ratio then
            goto continue
        end

        -- Envelope mismatch check
        local envelope_check_points = math.min(8, #edited_normalized + 2)
        local envelope_mismatches = 0
        local envelope_window = CONFIG.ENVELOPE_WINDOW_MS / 1000

        for i = 1, envelope_check_points do
            local progress = (i - 1) / (envelope_check_points - 1)
            local edited_time = edited_start_offset + (edited_duration * progress)
            local clean_time = match_start_time + (edited_duration * progress)

            local is_mismatch, mismatch_severity = check_envelope_mismatch(
                clean_envelope_data,
                edited_envelope_data,
                clean_time,
                edited_time,
                envelope_window
            )

            if is_mismatch then
                envelope_mismatches = envelope_mismatches + mismatch_severity
            end
        end

        -- Reject if too many envelope mismatches
        local max_envelope_mismatch = is_short_clip and CONFIG.MAX_ENVELOPE_MISMATCH_SHORT or CONFIG.MAX_ENVELOPE_MISMATCH_LONG
        if envelope_mismatches > max_envelope_mismatch then
            goto continue
        end

        -- Score peak matches
        local score = 0
        local matched_clean_indices = {}
        local amplitude_bonus = 0

        for i = 1, #edited_normalized do
            local edited_peak = edited_normalized[i]
            local time_offset_in_edited = edited_peak.time - edited_start_offset
            local expected_clean_time = match_start_time + time_offset_in_edited

            -- Find closest clean peak
            local closest_clean_idx = nil
            local smallest_time_error = math.huge

            for k = 1, #clean_peaks_in_region do
                local time_error = math.abs(clean_peaks_in_region[k].time - expected_clean_time)
                if time_error < smallest_time_error then
                    smallest_time_error = time_error
                    closest_clean_idx = k
                end
            end

            if smallest_time_error < max_tolerance then
                -- Good match
                local match_quality = 1.0 - (smallest_time_error / max_tolerance)

                -- Amplitude similarity bonus
                if closest_clean_idx then
                    local amp_diff = math.abs(clean_peaks_in_region[closest_clean_idx].amplitude - edited_peak.amplitude)
                    local amp_similarity = 1.0 - math.min(1.0, amp_diff)
                    local amp_weight = is_short_clip and CONFIG.AMP_WEIGHT_SHORT or CONFIG.AMP_WEIGHT_LONG
                    amplitude_bonus = amplitude_bonus + (amp_similarity * amp_weight)
                end

                -- Position weighting (first and last peaks more important)
                local position_weight = 1.0
                if i == 1 or i == #edited_normalized then
                    position_weight = is_short_clip and CONFIG.POSITION_WEIGHT_SHORT or CONFIG.POSITION_WEIGHT_LONG
                end

                score = score + (match_quality * position_weight)
                matched_clean_indices[closest_clean_idx] = true
            else
                score = score - missing_peak_penalty
            end
        end

        -- Count unmatched clean peaks
        local unmatched_clean_count = 0
        for k = 1, #clean_peaks_in_region do
            if not matched_clean_indices[k] then
                unmatched_clean_count = unmatched_clean_count + 1
            end
        end

        score = score - (unmatched_clean_count * extra_peak_penalty)
        score = score + amplitude_bonus
        score = score - (envelope_mismatches * CONFIG.envelope_mismatch_penalty)

        -- Normalize peak score and clamp to 1.0 (position weights + amplitude bonuses can exceed 1.0)
        local peak_score = math.min(1.0, score / #edited_normalized)

        -- Apply minimum score threshold (using peak score only - STT applied later)
        if peak_score > TUNABLE.min_score then
            matches[#matches + 1] = {
                time = match_start_time - edited_start_offset,
                score = peak_score,  -- Will be updated with STT if enabled
                position_time = match_start_time,
                edited_duration = edited_duration,  -- Store for STT region extraction
                debug_info = {
                    total_edited_peaks = #edited_normalized,
                    clean_peaks_in_region = #clean_peaks_in_region,
                    extra_clean_peaks = unmatched_clean_count,
                    envelope_mismatches = envelope_mismatches,
                    raw_score = score,
                    is_short_clip = is_short_clip,
                    peak_score = peak_score
                }
            }
        end

        ::continue::
    end

    local filter_distance = is_short_clip and CONFIG.FILTER_DISTANCE_SHORT or CONFIG.FILTER_DISTANCE_LONG
    -- When STT is enabled, keep more matches for verification (limit applied after STT re-sorting)
    local max_matches = TUNABLE.stt_enabled and 100 or TUNABLE.num_match_tracks
    return FilterCloseMatches(matches, filter_distance, max_matches)
end

function FilterCloseMatches(matches, min_distance, max_results)
    if not matches or #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return a.score > b.score end)

    local filtered = {}
    for i = 1, #matches do
        local too_close = false

        for j = 1, #filtered do
            if math.abs(matches[i].time - filtered[j].time) < min_distance then
                too_close = true
                break
            end
        end

        if not too_close then
            filtered[#filtered + 1] = matches[i]
            if #filtered >= max_results then
                break
            end
        end
    end

    return filtered
end

function CreateMatchedItem(clean_item, start_time, duration, edited_item, target_track, edited_peaks, clean_peaks)
    local clean_take = reaper.GetActiveTake(clean_item)
    local clean_source = reaper.GetMediaItemTake_Source(clean_take)
    local edited_pos = reaper.GetMediaItemInfo_Value(edited_item, "D_POSITION")

    -- IMPORTANT: Account for the clean item's own take offset
    -- start_time is relative to the clean item's start, but we need it relative to the source file
    local clean_take_offset = reaper.GetMediaItemTakeInfo_Value(clean_take, "D_STARTOFFS")
    local absolute_start_time = clean_take_offset + start_time

    -- Calculate peak alignment offset
    local alignment_offset = 0
    local alignment_applied = false

    if TUNABLE.align_peaks and edited_peaks and clean_peaks and #edited_peaks > 0 and #clean_peaks > 0 then
        local first_edited_peak_time = edited_peaks[1].time

        -- Find first peak in matched clean region
        -- Peaks are relative to clean item start, match region is [start_time, start_time + duration)
        local first_clean_peak_in_region = nil
        for _, peak in ipairs(clean_peaks) do
            if peak.time >= start_time and peak.time < (start_time + duration) then
                first_clean_peak_in_region = peak
                break
            end
        end

        if first_clean_peak_in_region then
            -- Calculate relative position within match region
            local first_clean_peak_relative = first_clean_peak_in_region.time - start_time
            alignment_offset = first_clean_peak_relative - first_edited_peak_time

            -- Safety checks
            if alignment_offset > 0 and alignment_offset < duration then
                alignment_applied = true
            elseif alignment_offset < 0 then
                alignment_offset = 0
            else
                alignment_offset = 0
            end
        end
    end

    local new_item = reaper.AddMediaItemToTrack(target_track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", edited_pos)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", duration)

    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, clean_source)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", absolute_start_time + alignment_offset)
    reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME",
        alignment_applied and "Matched (aligned)" or "Matched", true)
    reaper.SetActiveTake(new_take)

    -- Copy take FX from clean item to matched item
    local fx_count = reaper.TakeFX_GetCount(clean_take)
    if fx_count > 0 then
        for i = 0, fx_count - 1 do
            reaper.TakeFX_CopyToTake(clean_take, i, new_take, -1, false)
        end
    end

    -- Copy markers from clean item (adjusted for the match position and alignment)
    local markers_copied = 0
    local adjusted_start = absolute_start_time + alignment_offset
    for i = 0, reaper.GetNumTakeMarkers(clean_take) - 1 do
        local srcpos, name, color = reaper.GetTakeMarker(clean_take, i)
        -- Check if marker falls within the matched region (relative to source file, accounting for alignment)
        if srcpos >= adjusted_start and srcpos < (adjusted_start + duration) then
            -- Set marker in new take (relative to new take's start offset)
            if reaper.SetTakeMarker(new_take, -1, name or "", srcpos, color or 0) >= 0 then
                markers_copied = markers_copied + 1
            end
        end
    end

    -- Trim extended matches back to original length
    if processing_state.edited_pre_extension and processing_state.edited_pre_extension > 0 or
    processing_state.edited_post_extension and processing_state.edited_post_extension > 0 then
        local pre_ext = processing_state.edited_pre_extension
        local original_dur = processing_state.edited_original_duration

        -- Adjust start position forward
        local current_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION")
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_pos)

        -- Set original duration
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", original_dur)

        -- Adjust take offset
        local new_take_obj = reaper.GetActiveTake(new_item)
        if new_take_obj then
            local take_off = reaper.GetMediaItemTakeInfo_Value(new_take_obj, "D_STARTOFFS")
            reaper.SetMediaItemTakeInfo_Value(new_take_obj, "D_STARTOFFS", take_off + pre_ext)
        end
    end

    reaper.UpdateItemInProject(new_item)
    return new_item
end
