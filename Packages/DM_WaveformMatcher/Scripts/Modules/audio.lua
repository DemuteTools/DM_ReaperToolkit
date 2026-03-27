-- compareWaveform/audio.lua
-- Audio loading and chunked processing

function InitAudioLoading(item)
    local als = processing_state.audio_load_state

    local take = reaper.GetActiveTake(item)
    if not take then
        return false
    end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then
        return false
    end

    local source_sample_rate = reaper.GetMediaSourceSampleRate(source)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local num_channels = reaper.GetMediaSourceNumChannels(source)

    -- Extend short edits
    local read_duration = item_len
    local pre_extension = 0
    local post_extension = 0

    if item_len < TUNABLE.short_edit_threshold and not TUNABLE.stt_enabled and TUNABLE.extend_short_edits then
        local extension = TUNABLE.edited_extension  -- User-defined extension amount

        -- Check available source audio before item
        pre_extension = math.min(extension, take_offset)

        -- Check available source audio after item
        local source_len, _ = reaper.GetMediaSourceLength(source)
        local available_after = source_len - (take_offset + item_len)
        post_extension = math.min(extension, available_after)

        read_duration = pre_extension + item_len + post_extension
    end

    local num_samples = math.floor(read_duration * source_sample_rate)

    -- Validation
    if item_len <= 0 or num_samples <= 0 or num_channels <= 0 then
        return false
    end

    -- For extended short edits, temporarily adjust take offset to include pre-extension audio
    local original_take_offset = take_offset
    local original_item_length = item_len
    if pre_extension > 0 or post_extension > 0 then
        -- Temporarily adjust take to cover extended region
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", take_offset - pre_extension)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", read_duration)
    end

    local accessor = reaper.CreateTakeAudioAccessor(take)

    -- Restore original values immediately after creating accessor
    if pre_extension > 0 or post_extension > 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", original_take_offset)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_item_length)
    end

    if not accessor then
        return false
    end

    -- Initialize state
    als.item = item
    als.take = take
    als.accessor = accessor
    als.source_sample_rate = source_sample_rate
    als.num_channels = num_channels
    als.num_samples = num_samples
    als.current_chunk = 0
    als.total_chunks = math.ceil(num_samples / CONFIG.AUDIO_CHUNK_SIZE)
    als.audio = {}
    als.buffer = reaper.new_array(CONFIG.AUDIO_CHUNK_SIZE * num_channels)
    als.progress_percent = 0
    als.pre_extension = pre_extension
    als.post_extension = post_extension
    als.original_duration = item_len
    als.take_offset = take_offset

    processing_state.temp_sr = source_sample_rate
    processing_state.temp_offset = take_offset - pre_extension  -- Adjust for extension

    return true
end

function ProcessAudioLoadingChunk()
    local als = processing_state.audio_load_state

    local chunk_start = als.current_chunk * CONFIG.AUDIO_CHUNK_SIZE
    if chunk_start >= als.num_samples then
        -- Done loading
        reaper.DestroyAudioAccessor(als.accessor)
        processing_state.temp_audio = als.audio
        return true
    end

    local samples_to_read = math.min(CONFIG.AUDIO_CHUNK_SIZE, als.num_samples - chunk_start)
    als.buffer.clear()

    -- Read from time 0 - the accessor was created with adjusted take offset to include pre-extension
    local start_time = chunk_start / als.source_sample_rate
    reaper.GetAudioAccessorSamples(als.accessor, als.source_sample_rate, als.num_channels, start_time, samples_to_read, als.buffer)

    -- Convert to mono and store
    for i = 1, samples_to_read do
        if als.num_channels == 1 then
            als.audio[chunk_start + i] = als.buffer[i]
        else
            local sum = 0
            for ch = 0, als.num_channels - 1 do
                sum = sum + als.buffer[((i - 1) * als.num_channels) + ch + 1]
            end
            als.audio[chunk_start + i] = sum / als.num_channels
        end
    end

    als.current_chunk = als.current_chunk + 1
    als.progress_percent = (als.current_chunk / als.total_chunks) * 100

    return false  -- Not done yet
end
