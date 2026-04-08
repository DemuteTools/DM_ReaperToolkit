from reaper_python import *
from sws_python import*
from DM_ReaLibrary import *
import csv
import json
from pathlib import *
from tkinter import *
from tkinter import ttk
import fuzzywuzzy.fuzz
try:
    import speech_recognition
except Exception as e:
    DM_Log(e)


current_iterable = None
current_func = None
current_callback = None

# STT engine settings
STT_ENGINES = ["azure", "google", "google_cloud", "whisper", "vosk"]
stt_engine = "azure"
stt_engine_config = {}  # engine-specific config (keys, model paths, etc.)

def process():
    RPR_Undo_BeginBlock
    global current_iterable
    global current_func
    global current_callback
    if current_iterable.__len__() == 0:
        current_callback()
    else:
        current_func(current_iterable.pop(0))
        RPR_defer("process()")
    RPR_Undo_EndBlock("Process item", 0)



def async_forloop(iterable, func, callback):
    global current_iterable
    global current_func
    global current_callback
    current_iterable = list(iterable)
    current_func = func
    current_callback = callback
    RPR_defer("process()")

def ImportCSVs():
    #Save values of variables in project notes
    global saved_folder
    global saved_textrow
    global saved_keyrow
    global saved_language
    global saved_actorrow
    global saved_useactor
    global stt_engine
    global stt_engine_config

    saved_folder = csv_folder.get()
    saved_textrow = csv_textrowname.get()
    saved_keyrow = csv_keyrowname.get()
    saved_language = csv_language.get()
    saved_actorrow = csv_actorrowname.get()
    saved_useactor = csv_useactor.get()
    stt_engine = stt_engine_var.get()

    # Gather engine-specific config
    stt_engine_config = {}
    if stt_engine == "azure":
        stt_engine_config["key"] = stt_azure_key.get()
        stt_engine_config["region"] = stt_azure_region.get()
    elif stt_engine == "google_cloud":
        stt_engine_config["credentials_json"] = stt_gcloud_creds.get()
    elif stt_engine == "whisper":
        stt_engine_config["model"] = stt_whisper_model.get()
    elif stt_engine == "vosk":
        stt_engine_config["model_path"] = stt_vosk_model_path.get()

    projectNotes = csv_folder.get() + "," + csv_textrowname.get() + "," + csv_keyrowname.get() + "," + csv_language.get() + "," + csv_actorrowname.get() + "," + str(csv_useactor.get()) + "," + stt_engine
    RPR_GetSetProjectNotes(0, True, projectNotes, 200)

    RPR_Undo_BeginBlock()
    DM_Log("Start import")
    try:
        # Validate engine-specific config
        if stt_engine == "azure":
            if not stt_engine_config.get("key"):
                key = os.getenv("AZUREKEY")
                if not key:
                    DM_Log("No Azure key found. Set AZUREKEY env var or enter it in the field.")
                    return
                stt_engine_config["key"] = key
            if not stt_engine_config.get("region"):
                stt_engine_config["region"] = "germanywestcentral"
            DM_Log("Using Azure STT (region: " + stt_engine_config["region"] + ")")
        elif stt_engine == "google":
            DM_Log("Using Google STT (free, no auth required)")
        elif stt_engine == "google_cloud":
            if not stt_engine_config.get("credentials_json"):
                DM_Log("Google Cloud credentials JSON path is required.")
                return
            DM_Log("Using Google Cloud STT")
        elif stt_engine == "whisper":
            if not stt_engine_config.get("model"):
                stt_engine_config["model"] = "base"
            DM_Log("Using Whisper STT (model: " + stt_engine_config["model"] + ")")
        elif stt_engine == "vosk":
            if not stt_engine_config.get("model_path"):
                DM_Log("Vosk model path is required.")
                return
            DM_Log("Using Vosk STT")

        CSVFiles = GetCSVFilesInFolder(Path(saved_folder))
        for filepath, csvname in CSVFiles:
            DetectLines(filepath)
        root.destroy()
    except Exception as e:
        DM_Log(e)
        root.destroy()
    RPR_Undo_EndBlock("Detect Takes from CSV", 0)

def GetCSVFilesInFolder(folderpath):
    all_csv_files = []
    for path in sorted(folderpath.glob('**/*.csv')):
        data = (path, path.relative_to(folderpath))
        all_csv_files.append(data)

    if all_csv_files.__len__() == 0:
        raise Exception("No CSV files found in folder")

    return all_csv_files


def DetectLines(filepath):
    
    # selectedMediaItem = RPR_GetSelectedMediaItem(0,0)

    # RPR_Main_OnCommand(40315, 0) #Item: Auto trim/split items (remove silence)...
    #RPR_Main_OnCommand(41999, 0) #Item: Render items to new take

    #Need to put the items into a list before moving them cause it causes issues.

    itemList = []

    for x in range(RPR_CountSelectedMediaItems(0)):
        # Get the selected audio item
        item = RPR_GetSelectedMediaItem(0, x)
        if not item:
            DM_Log("Error : couldn't get first item selected")
            return
        itemList.append(item)

    async_forloop(itemList, lambda x: TranscribeAndMatchLine(x, filepath, saved_language), lambda: DM_Log("Done"))

    # for item in itemList:
    #     TranscribeAndMatchLine(item,filepath, saved_language)


def TranscribeAndMatchLine(item, filepath, languageToTranscribe = "en-US"):
    RPR_Undo_BeginBlock()
    # Get the take for the audio item
    take = RPR_GetActiveTake(item)
    if not take:
        DM_Log("Error : couldn't get item take")
        return

    # Get the audio file for the take
    file = ""
    source = RPR_GetMediaItemTake_Source(take)
    file = RPR_GetMediaSourceFileName(source, file, 512)[1]
    if not file:
        DM_Log("Error : couldn't get source file path")
        return

    #Get the track name of the item
    track = RPR_GetMediaItem_Track(item)
    trackName = ""
    trackName = RPR_GetSetMediaTrackInfo_String(track, "P_NAME", trackName, False)[3]

    # DM_Log(file)
    offset = RPR_GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    duration =  RPR_GetMediaItemInfo_Value(item, "D_LENGTH")+1
    # DM_Log(offset)
    # DM_Log(duration)
    DM_Log("Transcribing in " + languageToTranscribe, True)
    transcription = DM_AudioFileTranscript(file, offset, duration, None, languageToTranscribe)[0]
    DM_Log(transcription)
    with open(filepath, newline='', encoding='utf-8') as csvfile:
        DM_Log("Opened CSV file", False)
        reader = csv.DictReader(csvfile, delimiter=',', quotechar='"')
        if not (saved_textrow in reader.fieldnames):
            DM_Log("Couldn't find specified header for dialogue text.")
            return    
        if not (saved_keyrow in reader.fieldnames):
            DM_Log("Couldn't find specified header for line key.")
            return
        if saved_useactor:
            if not (saved_actorrow in reader.fieldnames):
                DM_Log("Couldn't find specified header for actor name.")
                return
        bestMatch = None
        bestMatch_ratio = 0
        DM_Log("Searching for best match", False)
        try:
            for row in reader:
                if saved_useactor:
                    if row[saved_actorrow] != trackName:
                        continue
                ratio = fuzzywuzzy.fuzz.ratio(transcription, row[saved_textrow])
                if ratio > bestMatch_ratio:
                    bestMatch = row
                    bestMatch_ratio = ratio
        except Exception as e:
            DM_Log(e)
        
        if transcription == "Could not transcribe audio.":
            DM_Log("No match found.")
            FindOrCreateMatchingRegion(item, transcription)
        elif bestMatch:
            DM_Log("Best match found. " + str(bestMatch[saved_textrow])  + " " + str(bestMatch_ratio) + "%")
            FindOrCreateMatchingRegion(item, bestMatch[saved_keyrow])
        else:
            DM_Log("No match found.")
            FindOrCreateMatchingRegion(item, transcription)

    RPR_Undo_EndBlock("Transcribe line", 0)

def FindOrCreateMatchingRegion(item, key):
    region = DM_GetRegionFromName(key, 0)
    if region :
        DM_Log("Found exisiting region")
        #Make some space for new item by moving others to alts
        itemTrack = RPR_GetMediaItem_Track(item)
        mediaItemsInRegion = DM_GetMediaItemsInRegionOnTrack(itemTrack, region)
        for mediaItem in mediaItemsInRegion:
            freeChildTrack = None
            index = int(RPR_GetMediaTrackInfo_Value(itemTrack, "IP_TRACKNUMBER"))
            while freeChildTrack == None and index <= RPR_CountTracks(0):
                testTrack = RPR_GetTrack(0, index)
                if itemTrack == RPR_GetParentTrack(testTrack): 
                    if DM_GetMediaItemsInRegionOnTrack(testTrack, region).__len__() == 0:
                        freeChildTrack = testTrack
                        break
                    else:
                        index += 1
                        continue
                else: #No more children tracks of the rec tracks  
                    RPR_InsertTrackAtIndex(index, False)
                    newTrack = RPR_GetTrack(0, index)
                    recDepth = RPR_GetMediaTrackInfo_Value(itemTrack, "I_FOLDERDEPTH")
                    if recDepth != 1: #First dump track
                        RPR_SetMediaTrackInfo_Value(itemTrack, "I_FOLDERDEPTH", 1)
                        RPR_SetMediaTrackInfo_Value(newTrack, "I_FOLDERDEPTH", recDepth-1)
                    else :
                        previousTrack = RPR_GetTrack(0, index-1)
                        previousDepth = RPR_GetMediaTrackInfo_Value(previousTrack, "I_FOLDERDEPTH")
                        RPR_SetMediaTrackInfo_Value(previousTrack, "I_FOLDERDEPTH", 0)
                        RPR_SetMediaTrackInfo_Value(newTrack, "I_FOLDERDEPTH", previousDepth)
                        newDepth = RPR_GetMediaTrackInfo_Value(newTrack, "I_FOLDERDEPTH")
                        #Set name of new tracks to Take + index

                    RPR_SetMediaTrackInfo_Value(newTrack, "B_MUTE", 1)
                    freeChildTrack = newTrack
                    break
            
            RPR_MoveMediaItemToTrack(mediaItem, freeChildTrack)
        RPR_SetMediaItemPosition(item, region.pos, True)
        itemEnd = RPR_GetMediaItemInfo_Value(item, "D_POSITION") + RPR_GetMediaItemInfo_Value(item, "D_LENGTH")
        if region.rgnend < itemEnd:
            RPR_SetProjectMarker(region.markrgnindexnumber, region.isrgn, region.pos, itemEnd, region.name)
    else:
        DM_Log("Creating new region")
        RPR_AddProjectMarker(0, True, RPR_GetMediaItemInfo_Value(item, "D_POSITION"), RPR_GetMediaItemInfo_Value(item, "D_POSITION") + RPR_GetMediaItemInfo_Value(item, "D_LENGTH"), key, -1)

def DM_AudioFileTranscript(audiofilepath, offset = None, duration = None, preferredphrases = None, languageToDetect = "en-US"):
    r = speech_recognition.Recognizer()
    DM_Log("Try open file " + audiofilepath)
    with speech_recognition.AudioFile(audiofilepath) as source:
        audio = r.record(source, duration, offset)

    transcription = "Could not transcribe audio."
    engine = stt_engine
    config = stt_engine_config

    try:
        if engine == "azure":
            transcription = r.recognize_azure(
                audio_data=audio,
                language=languageToDetect,
                key=config.get("key"),
                location=config.get("region", "germanywestcentral")
            )
            # Azure may return a tuple (text, details)
            if isinstance(transcription, tuple):
                transcription = transcription[0]

        elif engine == "google":
            transcription = r.recognize_google(audio, language=languageToDetect)

        elif engine == "google_cloud":
            creds_path = config.get("credentials_json", "")
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = creds_path
            result = r.recognize_google_cloud(audio, language=languageToDetect, show_all=True)
            if result and 'results' in result and len(result['results']) > 0:
                transcription = result['results'][0]['alternatives'][0].get('transcript', '')
            else:
                transcription = r.recognize_google_cloud(audio, language=languageToDetect)

        elif engine == "whisper":
            model = config.get("model", "base")
            whisper_lang = languageToDetect.split('-')[0] if languageToDetect else None
            transcription = r.recognize_whisper(audio, model=model, language=whisper_lang)

        elif engine == "vosk":
            model_path = config.get("model_path", "")
            result = r.recognize_vosk(audio, model_path=model_path)
            vosk_result = json.loads(result)
            transcription = vosk_result.get('text', '')

    except speech_recognition.UnknownValueError:
        DM_Log("Speech not recognized by " + engine)
        return ("Could not transcribe audio.",)
    except Exception as e:
        DM_Log(engine + " error: " + str(e))
        return (str(e),)

    return (transcription,)

try:
    
    Tk.report_callback_exception = DM_TkInterCallbackError        

    projectNotes = ""
    projectNotes = RPR_GetSetProjectNotes(0, False, projectNotes, 200)[2]

    saved_folder = ""
    saved_textrow = ""
    saved_keyrow = ""
    saved_language = ""
    saved_actorrow = ""
    saved_useactor = False
    saved_engine = "azure"

    #Detect saved values in project notes
    parts = projectNotes.split(",")
    if len(parts) >= 6:
        saved_folder = parts[0]
        saved_textrow = parts[1]
        saved_keyrow = parts[2]
        saved_language = parts[3]
        saved_actorrow = parts[4]
        saved_useactor = parts[5] == "True"
    if len(parts) >= 7:
        saved_engine = parts[6]


    root = Tk()
    root.title("Import voice lines csv parameters")

    mainframe = ttk.Frame(root, padding="3 3 12 12")
    mainframe.grid(column=0, row=0, sticky=(N,W,E,S))
    root.columnconfigure(0,weight=1)
    root.rowconfigure(0, weight=1)

    csv_folder = StringVar(root, saved_folder)
    folder_entry = ttk.Entry(mainframe, textvariable=csv_folder)
    folder_entry.grid(column=2, row=1, sticky=(W,E))

    csv_textrowname = StringVar(root, saved_textrow)
    text_entry = ttk.Entry(mainframe, textvariable=csv_textrowname)
    text_entry.grid(column=2, row=3, sticky=(W,E))

    csv_keyrowname = StringVar(root, saved_keyrow)
    key_entry = ttk.Entry(mainframe, textvariable=csv_keyrowname)
    key_entry.grid(column=2, row=4, sticky=(W,E))

    csv_language = StringVar(root, saved_language)
    language_entry = ttk.Entry(mainframe, textvariable=csv_language)
    language_entry.grid(column=2, row=5, sticky=(W,E))

    csv_actorrowname = StringVar(root, saved_actorrow)
    actor_entry = ttk.Entry(mainframe, textvariable=csv_actorrowname)
    actor_entry.grid(column=2, row=6, sticky=(W,E))

    csv_useactor = BooleanVar(root, saved_useactor)
    useactor_entry = ttk.Checkbutton(mainframe, text="Filter lines with actor matching track name", variable=csv_useactor)
    useactor_entry.grid(column=2, row=7, sticky=(W,E))

    # --- STT Engine selection ---
    ttk.Label(mainframe, text="STT Engine").grid(column=1, row=8, sticky=E)
    stt_engine_var = StringVar(root, saved_engine)
    engine_combo = ttk.Combobox(mainframe, textvariable=stt_engine_var, values=STT_ENGINES, state="readonly")
    engine_combo.grid(column=2, row=8, sticky=(W,E))

    # Engine-specific config frames
    engine_config_frame = ttk.Frame(mainframe)
    engine_config_frame.grid(column=1, row=9, columnspan=2, sticky=(W,E))

    # Azure config
    azure_frame = ttk.Frame(engine_config_frame)
    stt_azure_key = StringVar(root, os.getenv("AZUREKEY", ""))
    stt_azure_region = StringVar(root, "germanywestcentral")
    ttk.Label(azure_frame, text="Azure Key").grid(column=0, row=0, sticky=E, padx=5, pady=2)
    ttk.Entry(azure_frame, textvariable=stt_azure_key, width=40).grid(column=1, row=0, sticky=(W,E), padx=5, pady=2)
    ttk.Label(azure_frame, text="Azure Region").grid(column=0, row=1, sticky=E, padx=5, pady=2)
    ttk.Entry(azure_frame, textvariable=stt_azure_region, width=40).grid(column=1, row=1, sticky=(W,E), padx=5, pady=2)

    # Google Cloud config
    gcloud_frame = ttk.Frame(engine_config_frame)
    stt_gcloud_creds = StringVar(root, "")
    ttk.Label(gcloud_frame, text="Credentials JSON path").grid(column=0, row=0, sticky=E, padx=5, pady=2)
    ttk.Entry(gcloud_frame, textvariable=stt_gcloud_creds, width=40).grid(column=1, row=0, sticky=(W,E), padx=5, pady=2)

    # Whisper config
    whisper_frame = ttk.Frame(engine_config_frame)
    stt_whisper_model = StringVar(root, "base")
    ttk.Label(whisper_frame, text="Whisper model").grid(column=0, row=0, sticky=E, padx=5, pady=2)
    whisper_model_combo = ttk.Combobox(whisper_frame, textvariable=stt_whisper_model, values=["tiny", "base", "small", "medium", "large"], state="readonly")
    whisper_model_combo.grid(column=1, row=0, sticky=(W,E), padx=5, pady=2)

    # Vosk config
    vosk_frame = ttk.Frame(engine_config_frame)
    stt_vosk_model_path = StringVar(root, "")
    ttk.Label(vosk_frame, text="Vosk model folder").grid(column=0, row=0, sticky=E, padx=5, pady=2)
    ttk.Entry(vosk_frame, textvariable=stt_vosk_model_path, width=40).grid(column=1, row=0, sticky=(W,E), padx=5, pady=2)

    # Google free needs no config - just show a label
    google_frame = ttk.Frame(engine_config_frame)
    ttk.Label(google_frame, text="No configuration needed (free, rate-limited)").grid(column=0, row=0, padx=5, pady=2)

    engine_frames = {
        "azure": azure_frame,
        "google": google_frame,
        "google_cloud": gcloud_frame,
        "whisper": whisper_frame,
        "vosk": vosk_frame,
    }

    def on_engine_changed(*args):
        for frame in engine_frames.values():
            frame.grid_forget()
        selected = stt_engine_var.get()
        if selected in engine_frames:
            engine_frames[selected].grid(column=0, row=0, sticky=(W,E))

    stt_engine_var.trace_add("write", on_engine_changed)
    on_engine_changed()  # show initial engine config

    ttk.Button(mainframe, text="Detect takes from CSV", command=ImportCSVs).grid(column=2, row=10, sticky=W)

    ttk.Label(mainframe, text="Folder with CSVs").grid(column=1, row=1, sticky=E)
    ttk.Label(mainframe, text="Dialogue text header").grid(column=1, row=3, sticky=E)
    ttk.Label(mainframe, text="Line key header").grid(column=1, row=4, sticky=E)
    ttk.Label(mainframe, text="Language code").grid(column=1, row=5, sticky=E)
    ttk.Label(mainframe, text="Actor name header").grid(column=1, row=6, sticky=E)

    for child in mainframe.winfo_children():
        child.grid_configure(padx=5, pady=5)

    folder_entry.focus()
    root.bind("<Return>", ImportCSVs)

    root.mainloop()

except Exception as e:
    DM_Error('Generic error:', e)
    root.destroy()
    #del speech_recognition
    

