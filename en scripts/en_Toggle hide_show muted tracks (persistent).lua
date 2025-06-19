-- @description Toggle hide/show muted or fully-muted-item tracks (persistent)
-- @version 2.0
-- @author GPT 4o
-- @about Hides muted tracks or tracks whose items are all muted, and remembers state even after REAPER is closed.

local EXT_SECTION = "ToggleMutedTrackHider"
local EXT_KEY = "hidden_track_guids"

function GetTrackGUID(track)
  local retval, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  return guid
end

function GetTrackByGUID(guid)
  local trackCount = reaper.CountTracks(0)
  for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    if GetTrackGUID(track) == guid then return track end
  end
  return nil
end

function GetAllTracksToHide()
  local tracksToHide = {}
  local trackCount = reaper.CountTracks(0)
  for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local isMuted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
    if isMuted == 1 then
      table.insert(tracksToHide, track)
    else
      local itemCount = reaper.CountTrackMediaItems(track)
      if itemCount > 0 then
        local allItemsMuted = true
        for j = 0, itemCount - 1 do
          local item = reaper.GetTrackMediaItem(track, j)
          if reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
            allItemsMuted = false
            break
          end
        end
        if allItemsMuted then
          table.insert(tracksToHide, track)
        end
      end
    end
  end
  return tracksToHide
end

function HideTracks(tracks)
  local guids = {}
  for _, track in ipairs(tracks) do
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
    table.insert(guids, GetTrackGUID(track))
  end

  local serialized = table.concat(guids, "\n")
  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, serialized)
end

function RestoreTracks()
  local retval, serialized = reaper.GetProjExtState(0, EXT_SECTION, EXT_KEY)
  if retval == 1 then
    for guid in string.gmatch(serialized, "[^\n]+") do
      local track = GetTrackByGUID(guid)
      if track then
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
      end
    end
    reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, "") -- clear state
  end
end

function HasStoredTracks()
  local retval, serialized = reaper.GetProjExtState(0, EXT_SECTION, EXT_KEY)
  return retval == 1 and serialized ~= ""
end

----------------------------------

reaper.Undo_BeginBlock()

if HasStoredTracks() then
  RestoreTracks()
else
  local tracks = GetAllTracksToHide()
  if #tracks > 0 then
    HideTracks(tracks)
  end
end

reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Toggle hide/show muted tracks (persistent)", -1)

