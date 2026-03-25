from reaper_python import *
from sws_python import*
from DM_ReaLibrary import *
import csv
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

azure_key = None

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

    saved_folder = csv_folder.get()
    saved_textrow = csv_textrowname.get()
    saved_keyrow = csv_keyrowname.get()
    saved_language = csv_language.get()
    saved_actorrow = csv_actorrowname.get()
    saved_useactor = csv_useactor.get()
    projectNotes = csv_folder.get() + "," + csv_textrowname.get() + "," + csv_keyrowname.get() + "," + csv_language.get() + "," + csv_actorrowname.get() + "," + str(csv_useactor.get())
    RPR_GetSetProjectNotes(0, True, projectNotes, 200)

    RPR_Undo_BeginBlock()
    DM_Log("Start import")
    try:
        global azure_key 
        azure_key = os.getenv("AZUREKEY")
        if azure_key == None:
            DM_Log("No Azure key found. Please set the environment variable AZUREKEY to your key.")
            return
        else:
            DM_Log("Azure key found.")
          
        
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
    # Load the audio file
    r = speech_recognition.Recognizer()
    DM_Log("Try open file " + audiofilepath)
    with speech_recognition.AudioFile(audiofilepath) as source:
        audio = r.record(source, duration, offset)
    

    #DM_Log("Loaded audio file")

    # transcribe = timeout(timeout=10)(r.recognize_google_cloud)

    # # Transcribe the audio
    # try:
    #     transcription = transcribe(audio, None, languageToDetect)
    # except speech_recognition.UnknownValueError:
    #     return("Could not transcribe audio.")
    # except Exception as e:
    #     DM_Log(e)
    #     return (str(e))

    transcription = "Could not transcribe audio."
    #DM_Log(azure_key)
    try:
        transcription = r.recognize_azure(audio_data=audio, language=languageToDetect, key=azure_key, location="germanywestcentral")
    except Exception as e:
        DM_Log(e)
        return (str(e))
    
    # Print the transcription
    return(transcription)

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

    #DM_Log(projectNotes)
    #Detect saved values in project notes
    if projectNotes.split(",").__len__() >= 6:
        #DM_Log("Found saved values in project notes")
        saved_folder = projectNotes.split(",")[0]
        saved_textrow = projectNotes.split(",")[1]
        saved_keyrow = projectNotes.split(",")[2]
        saved_language = projectNotes.split(",")[3]
        saved_actorrow = projectNotes.split(",")[4]
        saved_useactor = projectNotes.split(",")[5]=="True"


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

    ttk.Button(mainframe, text="Detect takes from CSV", command=ImportCSVs).grid(column=2, row=9, sticky=W)

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
    

