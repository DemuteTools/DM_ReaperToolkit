import os
import pathlib
import shutil
import string
import traceback
from reaper_python import *
from sws_python import*
from typing import NamedTuple, List
from threading import Thread
import functools
import logging

def timeout(timeout):
    def deco(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            res = [Exception('function [%s] timeout [%s seconds] exceeded!' % (func.__name__, timeout))]
            def newFunc():
                try:
                    res[0] = func(*args, **kwargs)
                except Exception as e:
                    res[0] = e
            t = Thread(target=newFunc)
            t.daemon = True
            try:
                t.start()
                t.join(timeout)
            except Exception as je:
                print ('error starting thread')
                raise je
            ret = res[0]
            if isinstance(ret, BaseException):
                raise ret
            return ret
        return wrapper
    return deco


def DM_ClearRenderQueue():
    #DM_Log("Clearing Render Queue")
    resourcePath = pathlib.Path(RPR_GetResourcePath())
    #DM_Log("Resource Path: " + str(resourcePath))
    renderqueuePath = resourcePath / "QueuedRenders"
    if renderqueuePath.exists():
        shutil.rmtree(renderqueuePath)

def DM_GetTrackFromName(trackName):
    
    track = None
    for i in range(RPR_CountTracks(0)):
        track = RPR_GetTrack(0, i)
        parameter = "P_NAME"
        retName = ""
        setNewValue = False
        retval, track, parameter, retName, setNewValue = RPR_GetSetMediaTrackInfo_String(track, parameter, trackName, setNewValue)
        if trackName == retName:
            break
        else:
            track = None
    return track

def DM_GetAllTracksFromName(trackName):
    tracks = []
    for i in range(RPR_CountTracks(0)):
        track = RPR_GetTrack(0, i)
        parameter = "P_NAME"
        retName = ""
        setNewValue = False
        retval, track, parameter, retName, setNewValue = RPR_GetSetMediaTrackInfo_String(track, parameter, trackName, setNewValue)
        if trackName == retName:
            tracks.append(track)
    return tracks

def DM_InsertMedia(file, mode):
    """Inserts a Media Item and returns a pointer to the item just created"""
    itemsBeforeInsertion = set(DM_GetAllMediaItems(0))
    RPR_InsertMedia(file, mode)
    return (set(DM_GetAllMediaItems(0)) - itemsBeforeInsertion).pop()


def DM_GetAllMediaItems(proj):

    items = []
    for i in range(RPR_CountMediaItems(proj)):
        items.append(RPR_GetMediaItem(proj, i))
    return items

def DM_GetAllRegions(proj):

    regions: List[Region] = list()
    for i in range(RPR_CountProjectMarkers(proj, 0, 0)[0]):
        marker = Region(*RPR_EnumProjectMarkers2(proj, i, 0, 0, 0, "", 0))
        if marker.isrgn == True:
            fs = SNM_CreateFastString("")
            SNM_GetProjectMarkerName(proj, marker.markrgnindexnumber, marker.isrgn, fs)
            faststringname = SNM_GetFastString(fs)
            SNM_DeleteFastString(fs)
            region = marker._replace(name=faststringname)
            regions.append(region)
    return regions

def DM_GetAllMarkers(proj):

    markers: List[Region] = list()
    for i in range(RPR_CountProjectMarkers(proj, 0, 0)[0]):
        marker = Region(*RPR_EnumProjectMarkers2(proj, i, 0, 0, 0, "", 0))
        if marker.isrgn == False:
            fs = SNM_CreateFastString("")
            SNM_GetProjectMarkerName(proj, marker.markrgnindexnumber, marker.isrgn, fs)
            faststringname = SNM_GetFastString(fs)
            SNM_DeleteFastString(fs)
            marker = marker._replace(name=faststringname)
            markers.append(marker)
    return markers

def DM_Log(message, printToConsole = True):
    logging.debug(str(message))
    if printToConsole:
        RPR_ShowConsoleMsg(str(message) + "\n")


def DM_ClearRegionRenderMatrix(proj: int, regionindex: int):

    for i in range(RPR_CountTracks(proj)):
      track = RPR_GetTrack(proj, i)
      RPR_SetRegionRenderMatrix(proj, regionindex, track, -1)
      
    mastertrack = RPR_GetMasterTrack(proj)
    RPR_SetRegionRenderMatrix(proj, regionindex, mastertrack, -1)


def DM_SetRegionRenderMatrixFromTrackNames(proj: int, regionindex: int, tracknames: List[str]):

    DM_ClearRegionRenderMatrix(proj, regionindex)
    
    for name in tracknames :
        track = DM_GetTrackFromName(name)
        RPR_SetRegionRenderMatrix(proj, regionindex, track, 1)


def DM_WipeRegionRenderMatrix(proj: int):

    regions = DM_GetAllRegions(proj)
    region: Region
    for region in regions:
        DM_ClearRegionRenderMatrix(proj, region.markrgnindexnumber)

def DM_GetMediaItemAtPositionOnTrack(track, pos: float):
    
    mediaItem = None
    for i in range(RPR_CountTrackMediaItems(track)):
        mediaItem = RPR_GetTrackMediaItem(track, i)
        position = RPR_GetMediaItemInfo_Value(mediaItem, "D_POSITION")
        if position == pos : 
            break
        else:
            mediaItem = None
    
    return mediaItem

def DM_GetMediaItemsInRegionOnTrack(track, region):

    region = Region(*region)
    mediaItems = []
    for i in range(RPR_CountTrackMediaItems(track)):
        mediaItem = RPR_GetTrackMediaItem(track, i)
        startposition = RPR_GetMediaItemInfo_Value(mediaItem, "D_POSITION")
        endposition = RPR_GetMediaItemInfo_Value(mediaItem, "D_LENGTH") + startposition
        if region.pos <= startposition <= region.rgnend or region.pos <= endposition <= region.rgnend:
            mediaItems.append(mediaItem)
    
    return mediaItems

def DM_GetAllMediaItemsInRegion(proj, region):
    #DM_Log("Getting all media items in region")
    region = Region(*region)
    mediaItems = []
    for i in range(RPR_CountTracks(proj)):
        #DM_Log("Getting media items in track " + str(i))
        track = RPR_GetTrack(proj, i)
        mediaItems.extend(DM_GetMediaItemsInRegionOnTrack(track, region))  
    #DM_Log("Got all media items in region")
    return mediaItems

def DM_GetRegionAtCursorPosition(proj: int):
    currentRegionIndex = RPR_GetLastMarkerAndCurRegion(0, RPR_GetCursorPosition()+0.0001, 0, 0)[3] #compensate rounding error
    region = Region(*RPR_EnumProjectMarkers2(proj, currentRegionIndex, 0, 0, 0, "", 0))
    return region

def DM_GetNextMediaItemOnTrack(track, pos: float):
        
    bestItem = None
    bestPosition = -1
    for i in range(RPR_CountTrackMediaItems(track)):
        currentItem = RPR_GetTrackMediaItem(track, i)
        position = RPR_GetMediaItemInfo_Value(currentItem, "D_POSITION")
        if position > pos and (position < bestPosition or bestPosition == -1): 
            bestPosition = position
            bestItem = currentItem
    
    return bestItem

def DM_GetRegionFromName(regionname, proj):
    regions = DM_GetAllRegions(proj)
    region : Region = next(filter(lambda x: x.name == regionname, regions), None)
    return region

def DM_GetMarkerFromName(markername, proj):
    markers = DM_GetAllMarkers(proj)
    marker : Region = next(filter(lambda x: x.name == markername, markers), None)
    return marker

def DM_GetAllRegionsInRegionRenderMatrix(proj):
    regions = DM_GetAllRegions(proj)
    renderedRegions : List[Region] = list()
    for region in regions:
        renderedTrack = RPR_EnumRegionRenderMatrix(proj, region.markrgnindexnumber, 0)
        if renderedTrack != "(MediaTrack*)0x0000000000000000":
            renderedRegions.append(region)
            #DM_Log(renderedTrack)
    
    return renderedRegions

def DM_GetProjectMasterFolder(proj):

    projectPath = ""
    projectPath_size = 512
    
    mediafilesFolder = RPR_GetProjectPath(projectPath, projectPath_size)
    projectPathString = mediafilesFolder[0]
    projectPurePath = pathlib.PureWindowsPath(projectPathString)
    masterFolder = projectPurePath.parents[1]
    
    return masterFolder

def DM_GetReceivedFilesFolder(proj):

    masterFldrPath = pathlib.Path(DM_GetProjectMasterFolder(proj))
    receivedFilesPath = masterFldrPath / "ReceivedFiles"

    return receivedFilesPath

def DM_Error(message, exception):
    if exception is not None:
        message += "\n\n"
        message += traceback.format_exc()
    
    DM_Log('Error' + message)

def DM_TkInterCallbackError(self, *args):
    message = 'Generic error:\n\n'
    message += traceback.format_exc()

    DM_Log('Error' + message)

#print(DM_AudioFileTranscript("Y:\Shared drives\Test\AutoEdit\Media Files\PaintingVRLines_MelodyMuze-glued.wav"))

class Region(NamedTuple):
    retval: int
    proj: int
    idx: int
    isrgn: bool
    pos: float
    rgnend: float
    name: str
    markrgnindexnumber: int

#If directory doesn't exist, create it
logPath = os.getenv('APPDATA')+'\Demute'
if not os.path.exists(logPath):
        os.makedirs(logPath)

logging.basicConfig(filename=logPath + '\DM_ReaLibrary.log', level=logging.DEBUG, format='%(asctime)s %(levelname)s %(name)s %(message)s')
logging.debug('Starting DM_ReaLibrary ------------------------------------------')
