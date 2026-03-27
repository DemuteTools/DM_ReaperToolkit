#!/usr/bin/env python3
"""
Multi-engine Speech-to-Text wrapper for REAPER compareWaveform.lua
Supports: Google (free), Google Cloud, Azure, Whisper, Vosk
"""

import sys
import json
import argparse
import os
from pathlib import Path

def transcribe_google(wav_path, language="en-US"):
    """Google Speech Recognition (free, no auth)"""
    import speech_recognition as sr
    recognizer = sr.Recognizer()

    with sr.AudioFile(wav_path) as source:
        audio = recognizer.record(source)

    text = recognizer.recognize_google(audio, language=language)
    # Google doesn't return confidence for free API
    return {"text": text, "confidence": 0.9}

def transcribe_google_cloud(wav_path, credentials_json, language="en-US"):
    """Google Cloud Speech-to-Text"""
    import speech_recognition as sr

    # Set credentials environment variable
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = credentials_json

    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_path) as source:
        audio = recognizer.record(source)

    result = recognizer.recognize_google_cloud(audio, language=language, show_all=True)

    # Parse confidence from result
    if result and 'results' in result and len(result['results']) > 0:
        alternative = result['results'][0]['alternatives'][0]
        return {
            "text": alternative.get('transcript', ''),
            "confidence": alternative.get('confidence', 0.0)
        }

    raise sr.UnknownValueError("No results returned")

def transcribe_azure(wav_path, subscription_key, region, language="en-US"):
    """Azure Cognitive Services Speech-to-Text"""
    import speech_recognition as sr

    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_path) as source:
        audio = recognizer.record(source)

    result = recognizer.recognize_azure(
        audio,
        key=subscription_key,
        language=language,
        location=region
    )

    # Azure returns tuple (text, confidence) or just text
    if isinstance(result, tuple):
        return {"text": result[0], "confidence": result[1]}
    else:
        return {"text": result, "confidence": 0.9}

def transcribe_whisper(wav_path, model="base", language=None):
    """OpenAI Whisper (local inference)"""
    import speech_recognition as sr

    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_path) as source:
        audio = recognizer.record(source)

    # Whisper model parameter: "tiny", "base", "small", "medium", "large"
    result = recognizer.recognize_whisper(audio, model=model, language=language)

    return {"text": result, "confidence": 0.95}

def transcribe_vosk(wav_path, model_path):
    """Vosk (offline speech recognition)"""
    import speech_recognition as sr

    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_path) as source:
        audio = recognizer.record(source)

    result = recognizer.recognize_vosk(audio, model_path=model_path)

    # Parse Vosk JSON result
    vosk_result = json.loads(result)
    text = vosk_result.get('text', '')

    # Vosk doesn't provide confidence in SpeechRecognition wrapper
    return {"text": text, "confidence": 0.85}

def main():
    parser = argparse.ArgumentParser(description="Multi-engine STT transcription")
    parser.add_argument("--engine", required=True,
                       choices=["google", "google_cloud", "azure", "whisper", "vosk"],
                       help="STT engine to use")
    parser.add_argument("--wav", required=True, help="Path to WAV file")
    parser.add_argument("--language", default="en-US", help="Language code")

    # Engine-specific arguments
    parser.add_argument("--subscription_key", help="Azure subscription key")
    parser.add_argument("--region", help="Azure region")
    parser.add_argument("--credentials_json", help="Google Cloud credentials JSON path")
    parser.add_argument("--model", help="Whisper model size or Vosk model path")
    parser.add_argument("--model_path", help="Vosk model directory path")

    args = parser.parse_args()

    # Validate WAV file exists
    if not Path(args.wav).exists():
        output_error(
            f"WAV file not found: {args.wav} "
            f"(if path looks corrupted, check Lua path handling)",
            args.engine
        )
        sys.exit(3)

    try:
        # Import speech_recognition
        try:
            import speech_recognition as sr
        except ImportError:
            output_error(
                "SpeechRecognition library not installed. Run: pip install SpeechRecognition",
                args.engine
            )
            sys.exit(1)

        # Call appropriate engine
        result = None

        if args.engine == "google":
            result = transcribe_google(args.wav, args.language)

        elif args.engine == "google_cloud":
            if not args.credentials_json:
                output_error("--credentials_json required for Google Cloud", args.engine)
                sys.exit(2)
            result = transcribe_google_cloud(args.wav, args.credentials_json, args.language)

        elif args.engine == "azure":
            if not args.subscription_key or not args.region:
                output_error("--subscription_key and --region required for Azure", args.engine)
                sys.exit(2)
            result = transcribe_azure(args.wav, args.subscription_key, args.region, args.language)

        elif args.engine == "whisper":
            model = args.model or "base"
            # Language code conversion (en-US -> en)
            whisper_lang = args.language.split('-')[0] if args.language else None
            result = transcribe_whisper(args.wav, model, whisper_lang)

        elif args.engine == "vosk":
            if not args.model_path:
                output_error("--model_path required for Vosk", args.engine)
                sys.exit(2)
            result = transcribe_vosk(args.wav, args.model_path)

        # Output success
        output_success(result["text"], result["confidence"], args.engine)
        sys.exit(0)

    except sr.UnknownValueError:
        output_error("No speech detected in audio", args.engine)
        sys.exit(4)

    except sr.RequestError as e:
        if "credential" in str(e).lower() or "auth" in str(e).lower():
            output_error(f"Authentication failed: {e}", args.engine)
            sys.exit(5)
        else:
            output_error(f"Network/API error: {e}", args.engine)
            sys.exit(6)

    except Exception as e:
        output_error(f"Unexpected error: {e}", args.engine)
        sys.exit(1)

def output_success(text, confidence, engine):
    """Output success JSON to stdout"""
    result = {
        "success": True,
        "text": text,
        "confidence": confidence,
        "engine": engine
    }
    print(json.dumps(result))

def output_error(error_msg, engine):
    """Output error JSON to stdout"""
    result = {
        "success": False,
        "error": error_msg,
        "engine": engine
    }
    print(json.dumps(result))

if __name__ == "__main__":
    main()
