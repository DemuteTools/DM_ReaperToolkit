-- compareWaveform/peaks.lua
-- Peak detection algorithm (chunked for async processing)

function AddMarkersToItem(item, transients, color, pre_extension_offset)
    local take = reaper.GetActiveTake(item)
    if not take then return false, 0 end

    -- Clear existing markers
    for i = reaper.GetNumTakeMarkers(take) - 1, 0, -1 do
        reaper.DeleteTakeMarker(take, i)
    end

    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local offset = pre_extension_offset or 0  -- Offset for extended short edits

    local marker_color = color or 0
    local added = 0

    for _, transient in ipairs(transients) do
        -- Adjust transient time relative to original item (subtract pre_extension)
        local adjusted_time = transient.time - offset
        if adjusted_time >= 0 and adjusted_time <= item_length then
            if reaper.SetTakeMarker(take, -1, "", take_offset + adjusted_time, marker_color) >= 0 then
                added = added + 1
            end
        end
    end

    reaper.UpdateItemInProject(item)
    return true, added
end

-- PEAK DETECTION (CHUNKED FOR ASYNC PROCESSING)
-- Optimizations:
-- - Downsampling: 10x larger chunks (500k samples) - simple abs() operations
-- - Envelope: 5x larger chunks (250k samples) - simple math operations
-- - Smoothing: 4x larger chunks (200k samples) with O(n) sliding window
-- - Calc threshold: Sampling every Nth value to reduce sort array size
-- - Find maxima: 5x larger chunks (500k samples) - simple comparisons

function InitPeakDetection(audio, sample_rate, prominence)
    local pds = processing_state.peak_detect_state

    -- Reset state
    pds.phase = "downsample"
    pds.chunk_index = 1
    pds.downsampled = {}
    pds.envelope = nil
    pds.smoothed = nil
    pds.all_peaks = nil
    pds.ds_sample_rate = sample_rate / CONFIG.DOWNSAMPLE_FACTOR
    pds.prominence = prominence
    -- Calculate based on larger downsample chunk size
    local downsample_chunk_size = pds.chunk_size * 10
    pds.total_chunks = math.ceil(#audio / (CONFIG.DOWNSAMPLE_FACTOR * downsample_chunk_size))
    pds.progress_percent = 0
    pds.smooth_window_sum = 0
    pds.smooth_window_count = 0
    pds.find_peaks_subphase = "calc_threshold"
    pds.sorted_envelope = nil
    pds.threshold = nil
    pds.max_val = 0
end

function ProcessPeakDetectionChunk()
    local pds = processing_state.peak_detect_state
    local audio = processing_state.temp_audio

    -- Phase 1: Downsample (optimized with larger chunks)
    if pds.phase == "downsample" then
        -- Use much larger chunks for downsampling since it's just simple abs() operations
        local downsample_chunk_size = pds.chunk_size * 10  -- 500k samples per chunk

        local start_idx = (pds.chunk_index - 1) * downsample_chunk_size * CONFIG.DOWNSAMPLE_FACTOR + 1
        local end_idx = math.min(start_idx + downsample_chunk_size * CONFIG.DOWNSAMPLE_FACTOR - 1, #audio)

        for i = start_idx, end_idx, CONFIG.DOWNSAMPLE_FACTOR do
            pds.downsampled[#pds.downsampled + 1] = math.abs(audio[i])
        end

        local downsample_total_chunks = math.ceil(#audio / (CONFIG.DOWNSAMPLE_FACTOR * downsample_chunk_size))
        pds.progress_percent = (pds.chunk_index / downsample_total_chunks) * 20  -- 0-20%

        if end_idx >= #audio then
            pds.phase = "envelope"
            pds.chunk_index = 1
            pds.total_chunks = math.ceil(#pds.downsampled / pds.chunk_size)
            -- Initialize envelope with first value
            pds.envelope = {pds.downsampled[1]}
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false  -- Not done yet
    end

    -- Phase 2: Create envelope (optimized with larger chunks)
    if pds.phase == "envelope" then
        local attack_coef = math.exp(-1.0 / (CONFIG.ENVELOPE_ATTACK_TIME * pds.ds_sample_rate))
        local release_coef = math.exp(-1.0 / (CONFIG.ENVELOPE_RELEASE_TIME * pds.ds_sample_rate))

        -- Use larger chunks for envelope since it's just simple math operations
        local envelope_chunk_size = pds.chunk_size * 5  -- 250k samples per chunk

        local start_idx = (pds.chunk_index - 1) * envelope_chunk_size + 2
        local end_idx = math.min(start_idx + envelope_chunk_size - 1, #pds.downsampled)

        for i = start_idx, end_idx do
            local input = pds.downsampled[i]
            local prev_env = pds.envelope[i - 1]

            if input > prev_env then
                pds.envelope[i] = attack_coef * prev_env + (1 - attack_coef) * input
            else
                pds.envelope[i] = release_coef * prev_env + (1 - release_coef) * input
            end
        end

        local envelope_total_chunks = math.ceil(#pds.downsampled / envelope_chunk_size)
        pds.progress_percent = 20 + (pds.chunk_index / envelope_total_chunks) * 30  -- 20-50%

        if end_idx >= #pds.downsampled then
            pds.phase = "smooth"
            pds.chunk_index = 1
            pds.total_chunks = math.ceil(#pds.envelope / pds.chunk_size)
            pds.smoothed = {}
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false
    end

    -- Phase 3: Smooth envelope (optimized with sliding window)
    if pds.phase == "smooth" then
        local smooth_window = math.floor(pds.ds_sample_rate * CONFIG.SMOOTH_WINDOW_MS / 1000)

        -- Use larger chunk size for smoothing since it's now optimized
        local smooth_chunk_size = pds.chunk_size * 4  -- 4x larger chunks

        -- First chunk: initialize the sliding window
        if pds.chunk_index == 1 then
            -- Calculate first window sum
            local window_sum = 0
            local window_count = 0
            local start_j = math.max(1, 1 - smooth_window)
            local end_j = math.min(#pds.envelope, 1 + smooth_window)

            for j = start_j, end_j do
                window_sum = window_sum + pds.envelope[j]
                window_count = window_count + 1
            end

            pds.smoothed[1] = window_sum / window_count

            -- Store state for next chunks
            pds.smooth_window_sum = window_sum
            pds.smooth_window_count = window_count
        end

        local start_idx = (pds.chunk_index - 1) * smooth_chunk_size + 2
        local end_idx = math.min(start_idx + smooth_chunk_size - 1, #pds.envelope)

        local window_sum = pds.smooth_window_sum
        local window_count = pds.smooth_window_count

        for i = start_idx, end_idx do
            -- Remove element leaving the window (on the left)
            local left_edge = i - smooth_window - 1
            if left_edge > 0 and left_edge <= #pds.envelope then
                window_sum = window_sum - pds.envelope[left_edge]
                window_count = window_count - 1
            end

            -- Add element entering the window (on the right)
            local right_edge = i + smooth_window
            if right_edge > 0 and right_edge <= #pds.envelope then
                window_sum = window_sum + pds.envelope[right_edge]
                window_count = window_count + 1
            end

            pds.smoothed[i] = window_sum / window_count
        end

        -- Store state for next chunk
        pds.smooth_window_sum = window_sum
        pds.smooth_window_count = window_count

        -- Recalculate progress based on actual smooth_chunk_size
        local smooth_total_chunks = math.ceil(#pds.envelope / smooth_chunk_size)
        pds.progress_percent = 50 + (pds.chunk_index / smooth_total_chunks) * 30  -- 50-80%

        if end_idx >= #pds.envelope then
            pds.phase = "find_peaks"
            pds.chunk_index = 1
            pds.find_peaks_subphase = "calc_threshold"
            pds.envelope = pds.smoothed  -- Replace envelope with smoothed version
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false
    end

    -- Phase 4: Find peaks (broken into sub-phases)
    if pds.phase == "find_peaks" then

        -- Sub-phase: Calculate threshold (optimized with sampling)
        if pds.find_peaks_subphase == "calc_threshold" then
            pds.progress_percent = 80

            -- Find max value
            pds.max_val = 0
            for i = 1, #pds.envelope do
                pds.max_val = math.max(pds.max_val, pds.envelope[i])
            end

            -- Filter out noise floor and SAMPLE for faster percentile calculation
            local noise_floor = pds.max_val * 0.005
            local filtered_envelope = {}
            local sample_rate = math.max(1, math.floor(#pds.envelope / 50000))  -- Sample to max 50k points

            for i = 1, #pds.envelope, sample_rate do
                if pds.envelope[i] > noise_floor then
                    filtered_envelope[#filtered_envelope + 1] = pds.envelope[i]
                end
            end

            if #filtered_envelope == 0 then
                pds.phase = "done"
                pds.all_peaks = {}
                return true
            end

            -- Sort only the sampled/filtered data (much smaller array)
            table.sort(filtered_envelope)

            -- Calculate threshold from sampled data
            local percentile_25 = filtered_envelope[math.floor(#filtered_envelope * 0.25)]
            local percentile_75 = filtered_envelope[math.floor(#filtered_envelope * 0.75)]
            local range = percentile_75 - percentile_25
            pds.threshold = percentile_25 + range * pds.prominence

            pds.find_peaks_subphase = "find_maxima"
            pds.chunk_index = 1  -- Reset for find_maxima chunks
            pds.progress_percent = 85
            return false
        end

        -- Sub-phase: Find local maxima (optimized with larger chunks)
        if pds.find_peaks_subphase == "find_maxima" then
            -- Initialize peaks array on first chunk
            if pds.chunk_index == 1 then
                pds.all_peaks = {}
            end

            -- Use larger chunks since peak detection is simple comparison
            local find_maxima_chunk_size = 500000  -- 500k samples per chunk
            local start_idx = math.max(2, (pds.chunk_index - 1) * find_maxima_chunk_size + 2)
            local end_idx = math.min(start_idx + find_maxima_chunk_size - 1, #pds.envelope - 1)

            for i = start_idx, end_idx do
                if pds.envelope[i] > pds.envelope[i - 1] and
                   pds.envelope[i] > pds.envelope[i + 1] and
                   pds.envelope[i] > pds.threshold then
                    pds.all_peaks[#pds.all_peaks + 1] = {
                        index = i,
                        amplitude = pds.envelope[i]
                    }
                end
            end

            local total_chunks = math.ceil(math.max(1, #pds.envelope - 2) / find_maxima_chunk_size)
            pds.progress_percent = 85 + (pds.chunk_index / total_chunks) * 5  -- 85-90%

            if end_idx >= #pds.envelope - 1 then
                pds.phase = "filter_peaks"
                pds.chunk_index = 1
                pds.progress_percent = 90
            else
                pds.chunk_index = pds.chunk_index + 1
            end
            return false
        end
    end

    -- Phase 5: Filter close peaks
    if pds.phase == "filter_peaks" then
        pds.progress_percent = 95

        if #pds.all_peaks == 0 then
            pds.phase = "done"
            return true
        end

        local min_distance = math.floor(pds.ds_sample_rate * TUNABLE.min_peak_distance_ms / 1000)
        local kept_peaks = {}

        for i = 1, #pds.all_peaks do
            local peak = pds.all_peaks[i]
            local should_keep = true

            for j = 1, #kept_peaks do
                local distance = math.abs(peak.index - kept_peaks[j].index)
                if distance < min_distance then
                    if peak.amplitude > kept_peaks[j].amplitude then
                        kept_peaks[j] = peak
                    end
                    should_keep = false
                    break
                end
            end

            if should_keep then
                kept_peaks[#kept_peaks + 1] = peak
            end
        end

        table.sort(kept_peaks, function(a, b) return a.index < b.index end)
        pds.all_peaks = kept_peaks
        pds.phase = "done"
        pds.progress_percent = 100
        return true  -- Done!
    end

    return pds.phase == "done"
end

function FinalizePeakDetection()
    local pds = processing_state.peak_detect_state
    local peaks = {}

    -- Convert to output format
    for i = 1, #pds.all_peaks do
        local original_sample = (pds.all_peaks[i].index - 1) * CONFIG.DOWNSAMPLE_FACTOR + 1
        peaks[#peaks + 1] = {
            time = DM.Time.FromSample(original_sample, processing_state.temp_sr),
            amplitude = pds.all_peaks[i].amplitude
        }
    end

    -- Create envelope data
    local envelope_data = {
        envelope = pds.envelope,
        sample_rate = pds.ds_sample_rate,
        downsample_factor = CONFIG.DOWNSAMPLE_FACTOR,
        original_sample_rate = processing_state.temp_sr
    }

    return peaks, envelope_data
end
