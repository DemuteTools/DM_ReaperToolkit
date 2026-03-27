-- compareWaveform/config.lua
-- Configuration, settings, and shared state

-- Default values for TUNABLE parameters (used for reset functionality)
TUNABLE_DEFAULTS = {
    peak_prominence = 0.3,
    min_peak_distance_ms = 30,
    num_match_tracks = 3,
    min_score = 0.0,
    stt_enabled = false,
    stt_weight = 0.5,
    stt_peak_threshold = 0.7,
    stt_max_duration = 10,
    mark_peaks = false,
    align_peaks = true,
    extend_short_edits = true,
    short_edit_threshold = 3.0,
    edited_extension = 4.0,
    require_pre_silence = false
}

TUNABLE = {
    -- Peak Detection
    peak_prominence = 0.3,
    min_peak_distance_ms = 30,
    num_match_tracks = 3,
    -- Minimum Score Thresholds
    min_score = 0.0,
    -- Speech-to-Text
    stt_enabled = false,
    stt_weight = 0.5,  -- 0 = peaks only, 1 = STT only
    stt_peak_threshold = 0.7,  -- Minimum peak score to trigger STT verification
    stt_max_duration = 10,  -- Maximum seconds to transcribe per STT call
    -- Short Edit Extension (always enabled)
    extend_short_edits = true,
    short_edit_threshold = 3.0,  -- Extend items shorter than this (seconds)
    edited_extension = 4.0,  -- Amount to extend before and after (seconds)
    --debug
    mark_peaks = false,  -- Whether to add markers at detected peaks
    align_peaks = true,  -- Align matched items by first peak position
    -- Pre-silence filter
    require_pre_silence = false  -- Disqualify matches with peaks before match position
}

TOOLTIPS = {
    peak_prominence = "How prominent peaks need to be (0-1). Lower = more peaks detected, higher = only strong peaks.",
    num_match_tracks = "Number of matched items/tracks to create.",
    min_peak_distance_ms = "Minimum time between peaks in milliseconds. Higher = fewer peaks, ignores rapid articulations.",
    min_score = "Minimum score required to accept match.",
    stt_enabled = "Enable speech-to-text comparison",
    stt_weight = "Balance between peak matching (0) and text matching (1).",
    stt_peak_threshold = "Minimum peak match score required before doing STT verification. Higher = fewer API calls, lower = more thorough.",
    stt_max_duration = "Maximum audio duration (seconds) to transcribe per STT call. Shorter = faster & cheaper. Recommended: 5-15s for voice lines.",
    extend_short_edits = "Extend short edited items for better matching.",
    short_edit_threshold = "Items shorter than this will read extended audio for better matching. Default: 3s.",
    edited_extension = "Amount of audio (in seconds) to read before AND after short items. Default: 4 seconds.",
    mark_peaks = "If enabled, adds markers at detected peak positions in the audio items.",
    align_peaks = "Shift matched audio so first peaks align. Items start at same position but may be trimmed.",
    require_pre_silence = "Disqualify matches that have peaks before the match position (uses the same gap as the edited item's pre-peak silence)."
}

-- Keep non-tunable config separate
CONFIG = {
    short_clip_threshold = 20, --Max number of peaks in edited clip to be considered 'short'.
    -- Matching Tolerances
    max_tolerance_short = 0.03, --Max time error (seconds) for peak matching in short clips. Lower = stricter timing required.
    max_tolerance_long = 0.15, --Max time error (seconds) for peak matching in long clips. Lower = stricter timing required.
    -- Penalties
    missing_peak_penalty_short = 1.7, --Score penalty when an edited peak has no match in clean (short clips). Higher = stricter.
    missing_peak_penalty_long = 0.5, --Score penalty when an edited peak has no match in clean (long clips). Higher = stricter.
    extra_peak_penalty_short = 1.5, --Score penalty per extra clean peak not in edited (short clips). Higher = penalizes noise more.
    extra_peak_penalty_long = 0.2, --Score penalty per extra clean peak not in edited (long clips). Higher = penalizes noise more.
    extra_peak_penalty_very_short = 1.5, --Score penalty per extra peak in very short clips (≤2 peaks). Usually kept low.
    envelope_mismatch_penalty = 0.5, --Score penalty when one recording is loud but the other is silent. Higher = stricter.

    DOWNSAMPLE_FACTOR = 4,
    ENVELOPE_ATTACK_TIME = 0.003,
    ENVELOPE_RELEASE_TIME = 0.050,
    SMOOTH_WINDOW_MS = 20,
    VERY_SHORT_CLIP_THRESHOLD = 2,
    ENVELOPE_CHECK_SAMPLES = 5,
    ENVELOPE_WINDOW_MS = 150,
    ENVELOPE_MISMATCH_THRESHOLD = 0.6,
    MIN_PEAKS_RATIO_SHORT = 0.75, -- Minimum ratio of matched peaks to total peaks for short clips
    MIN_PEAKS_RATIO_LONG = 0.5,
    FILTER_DISTANCE_SHORT = 1.0,
    FILTER_DISTANCE_LONG = 1.0,
    MAX_LOG_ENTRIES = 50,
    AUDIO_CHUNK_SIZE = 1000000,
    TOLERANCE_BUFFER_SHORT = 0.02,
    TOLERANCE_BUFFER_LONG = 0.3,
    -- Envelope Detection
    ENVELOPE_SILENCE_THRESHOLD = 0.1,
    ENVELOPE_ACTIVE_THRESHOLD = 0.3,
    MAX_ENVELOPE_MISMATCH_SHORT = 0.5,
    MAX_ENVELOPE_MISMATCH_LONG = 1.0,
    -- Amplitude Weighting
    AMP_WEIGHT_SHORT = 0.4,
    AMP_WEIGHT_LONG = 0.15,
    POSITION_WEIGHT_SHORT = 1.5,
    POSITION_WEIGHT_LONG = 1.2,
    -- Speech-to-Text
    STT_TEMP_DIR = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/"):gsub("//+", "/"):gsub("/$", ""),
    STT_SAMPLE_RATE = 16000  -- preferred sample rate
}

-- STT settings (editable in UI, persisted via ExtState)
EXT_SECTION = "VoiceLineMatcher"  -- Section name for ExtState

COLORS = {
    RED = {1, 0.2, 0.2, 1},
    GREEN = {0.2, 1, 0.2, 1},
    YELLOW = {1, 1, 0.2, 1},
    CYAN = {0.2, 0.8, 1, 1},
    GRAY = {0.7, 0.7, 0.7, 1},
    WHITE = {1, 1, 1, 1},
    ORANGE = {1, 0.6, 0.2, 1}
}

-- Shared state for logging (used by Log function)
report_log = {}

-- Helper function to create fresh state structures
function create_audio_load_state()
    return {
        item = nil, take = nil, accessor = nil,
        source_sample_rate = nil, num_channels = nil, num_samples = 0,
        current_chunk = 0, total_chunks = 0, audio = nil, buffer = nil,
        progress_percent = 0
    }
end

function create_peak_detect_state()
    return {
        phase = "downsample", chunk_index = 1, chunk_size = 50000,
        downsampled = nil, envelope = nil, smoothed = nil, all_peaks = nil,
        ds_sample_rate = nil, prominence = nil, total_chunks = 0,
        progress_percent = 0, smooth_window_sum = 0, smooth_window_count = 0,
        find_peaks_subphase = "calc_threshold", sorted_envelope = nil,
        threshold = nil, max_val = 0
    }
end

-- Progress tracking state (shared across all modules)
processing_state = {
    active = false, current_item = 0, total_items = 0,
    current_phase = "", current_item_name = "",
    -- Clean recordings data (arrays for multiple clean items)
    current_clean_item = 0,
    clean_items_peaks = {},
    clean_items_envelope_data = {},
    clean_items_sr = {},
    -- STT data for current edited item
    edited_stt = nil,  -- {text: "...", confidence: 0.0}
    -- STT verification state (for progress tracking)
    stt_all_matches = nil,           -- All matches found for current item
    stt_candidates_to_verify = 0,    -- How many to verify with STT
    stt_current_candidate = 0,       -- Current candidate being verified
    stt_edited_duration = 0,         -- Duration of edited item (for region export)
    target_tracks = nil, success_count = 0, fail_count = 0, undo_started = false,
    temp_audio = nil, temp_sr = nil, temp_offset = nil,
    temp_peaks = nil, temp_envelope_data = nil,
    audio_load_state = create_audio_load_state(),
    peak_detect_state = create_peak_detect_state()
}

-- Settings load/save functions
function LoadSettings()
    local settings = {
        -- Common settings
        engine = "azure",  -- Default to azure for backward compatibility
        language = "en-US",
        python_path = "python",

        -- Azure settings
        azure_key = "",
        region = "westeurope",

        -- Google Cloud settings
        google_credentials_path = "",

        -- Whisper settings
        whisper_model = "base",

        -- Vosk settings
        vosk_model_path = ""
    }

    -- Try to load from ExtState first (user-entered values)
    local saved_engine = reaper.GetExtState(EXT_SECTION, "stt_engine")
    local saved_python_path = reaper.GetExtState(EXT_SECTION, "python_path")
    local saved_key = reaper.GetExtState(EXT_SECTION, "azure_key")
    local saved_lang = reaper.GetExtState(EXT_SECTION, "language")
    local saved_region = reaper.GetExtState(EXT_SECTION, "region")
    local saved_google_creds = reaper.GetExtState(EXT_SECTION, "google_credentials_path")
    local saved_whisper_model = reaper.GetExtState(EXT_SECTION, "whisper_model")
    local saved_vosk_model_path = reaper.GetExtState(EXT_SECTION, "vosk_model_path")

    local saved_peak_prominence = reaper.GetExtState(EXT_SECTION, "peak_prominence")
    local saved_min_peak_distance_ms = reaper.GetExtState(EXT_SECTION, "min_peak_distance_ms")
    local saved_num_match_tracks = reaper.GetExtState(EXT_SECTION, "num_match_tracks")
    local saved_min_score = reaper.GetExtState(EXT_SECTION, "min_score")
    local saved_stt_enabled = false
    local saved_stt_weight = reaper.GetExtState(EXT_SECTION, "stt_weight")
    local saved_stt_peak_threshold = reaper.GetExtState(EXT_SECTION, "stt_peak_threshold")
    local saved_stt_max_duration = reaper.GetExtState(EXT_SECTION, "stt_max_duration")
    local saved_mark_peaks = reaper.GetExtState(EXT_SECTION, "mark_peaks")
    local saved_align_peaks = reaper.GetExtState(EXT_SECTION, "align_peaks")
    local saved_short_edit_threshold = reaper.GetExtState(EXT_SECTION, "short_edit_threshold")
    local saved_edited_extension = reaper.GetExtState(EXT_SECTION, "edited_extension")
    local saved_require_pre_silence = reaper.GetExtState(EXT_SECTION, "require_pre_silence")

    -- Use saved values if they exist, otherwise fall back to env var / defaults
    if saved_key ~= "" then
        settings.azure_key = saved_key
    else
        settings.azure_key = os.getenv("AZUREKEY") or ""
    end

    if saved_lang ~= "" then
        settings.language = saved_lang
    end

    if saved_region ~= "" then
        settings.region = saved_region
    end

    -- Load new engine settings
    if saved_engine ~= "" then
        settings.engine = saved_engine
    end

    if saved_python_path ~= "" then
        settings.python_path = saved_python_path
    end

    if saved_google_creds ~= "" then
        settings.google_credentials_path = saved_google_creds
    end

    if saved_whisper_model ~= "" then
        settings.whisper_model = saved_whisper_model
    end

    if saved_vosk_model_path ~= "" then
        settings.vosk_model_path = saved_vosk_model_path
    end

    if saved_peak_prominence ~= "" then
        TUNABLE.peak_prominence = tonumber(saved_peak_prominence) or TUNABLE.peak_prominence
    end
    if saved_min_peak_distance_ms ~= "" then
        TUNABLE.min_peak_distance_ms = tonumber(saved_min_peak_distance_ms) or TUNABLE.min_peak_distance_ms
    end
    if saved_num_match_tracks ~= "" then
        TUNABLE.num_match_tracks = tonumber(saved_num_match_tracks) or TUNABLE.num_match_tracks
    end
    if saved_min_score ~= "" then
        TUNABLE.min_score = tonumber(saved_min_score) or TUNABLE.min_score
    end
    if saved_stt_enabled ~= "" then
        TUNABLE.stt_enabled = (saved_stt_enabled == "true")
    end
    if saved_stt_weight ~= "" then
        TUNABLE.stt_weight = tonumber(saved_stt_weight) or TUNABLE.stt_weight
    end
    if saved_stt_peak_threshold ~= "" then
        TUNABLE.stt_peak_threshold = tonumber(saved_stt_peak_threshold) or TUNABLE.stt_peak_threshold
    end
    if saved_stt_max_duration ~= "" then
        TUNABLE.stt_max_duration = tonumber(saved_stt_max_duration) or TUNABLE.stt_max_duration
    end
    if saved_mark_peaks ~= "" then
        TUNABLE.mark_peaks = (saved_mark_peaks == "true")
    end
    if saved_align_peaks ~= "" then
        TUNABLE.align_peaks = (saved_align_peaks == "true")
    end
    if saved_short_edit_threshold ~= "" then
        TUNABLE.short_edit_threshold = tonumber(saved_short_edit_threshold) or TUNABLE.short_edit_threshold
    end
    if saved_edited_extension ~= "" then
        TUNABLE.edited_extension = tonumber(saved_edited_extension) or TUNABLE.edited_extension
    end
    if saved_require_pre_silence ~= "" then
        TUNABLE.require_pre_silence = (saved_require_pre_silence == "true")
    end

    return settings
end

function SaveSettings(settings)
    -- persist = true means save to reaper.ini (survives restart)
    if settings then
        -- Save common settings
        reaper.SetExtState(EXT_SECTION, "stt_engine", settings.engine, true)
        reaper.SetExtState(EXT_SECTION, "python_path", settings.python_path, true)
        reaper.SetExtState(EXT_SECTION, "language", settings.language, true)

        -- Save Azure settings
        reaper.SetExtState(EXT_SECTION, "azure_key", settings.azure_key, true)
        reaper.SetExtState(EXT_SECTION, "region", settings.region, true)

        -- Save Google Cloud settings
        reaper.SetExtState(EXT_SECTION, "google_credentials_path", settings.google_credentials_path, true)

        -- Save Whisper settings
        reaper.SetExtState(EXT_SECTION, "whisper_model", settings.whisper_model, true)

        -- Save Vosk settings
        reaper.SetExtState(EXT_SECTION, "vosk_model_path", settings.vosk_model_path, true)
    end

    reaper.SetExtState(EXT_SECTION, "peak_prominence", tostring(TUNABLE.peak_prominence), true)
    reaper.SetExtState(EXT_SECTION, "min_peak_distance_ms", tostring(TUNABLE.min_peak_distance_ms), true)
    reaper.SetExtState(EXT_SECTION, "num_match_tracks", tostring(TUNABLE.num_match_tracks), true)
    reaper.SetExtState(EXT_SECTION, "min_score", tostring(TUNABLE.min_score), true)
    reaper.SetExtState(EXT_SECTION, "stt_enabled", tostring(TUNABLE.stt_enabled), true)
    reaper.SetExtState(EXT_SECTION, "stt_weight", tostring(TUNABLE.stt_weight), true)
    reaper.SetExtState(EXT_SECTION, "stt_peak_threshold", tostring(TUNABLE.stt_peak_threshold), true)
    reaper.SetExtState(EXT_SECTION, "stt_max_duration", tostring(TUNABLE.stt_max_duration), true)
    reaper.SetExtState(EXT_SECTION, "mark_peaks", tostring(TUNABLE.mark_peaks), true)
    reaper.SetExtState(EXT_SECTION, "align_peaks", tostring(TUNABLE.align_peaks), true)
    reaper.SetExtState(EXT_SECTION, "short_edit_threshold", tostring(TUNABLE.short_edit_threshold), true)
    reaper.SetExtState(EXT_SECTION, "edited_extension", tostring(TUNABLE.edited_extension), true)
    reaper.SetExtState(EXT_SECTION, "require_pre_silence", tostring(TUNABLE.require_pre_silence), true)
end

-- Load settings on module load
STT_SETTINGS = LoadSettings()

function ResetToDefaults()
    -- Reset all TUNABLE parameters to default values
    for key, default_value in pairs(TUNABLE_DEFAULTS) do
        if key ~= "stt_enabled" then
            TUNABLE[key] = default_value
        end
    end

    -- Save the reset values
    SaveSettings(STT_SETTINGS)

    Log("All settings reset to default values", COLORS.GREEN)
end
