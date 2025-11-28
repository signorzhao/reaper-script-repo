local utils = {}

function utils.GetSelectedFX()
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then return nil, nil, "No Track Selected" end
    
    -- Get focused FX
    local focus_ret, focus_track_idx, focus_item_idx, focus_fx_idx = reaper.GetFocusedFX()
    local fx_index = -1
    
    -- Check if the focused FX is on the selected track
    -- GetFocusedFX: 1=track FX, 2=take/item FX
    if focus_ret == 1 then
        local focused_track
        if focus_track_idx == 0 then
            focused_track = reaper.GetMasterTrack(0)
        else
            focused_track = reaper.GetTrack(0, focus_track_idx - 1)
        end
        
        if focused_track == track then
            fx_index = focus_fx_idx
        end
    end
    
    -- If no FX is focused on this track, default to the first one
    if fx_index < 0 then 
        if reaper.TrackFX_GetCount(track) > 0 then
            fx_index = 0
        else
            return nil, nil, "No FX on Track"
        end
    end
    
    local retval, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    -- Clean up name (remove "VST3: ", "VST: ", etc)
    fx_name = fx_name:gsub("^%w+: ", ""):gsub(" %(.+%)$", "")
    
    return track, fx_index, fx_name
end

-- Config Management
local SECTION = "Antigravity_PresetManager"
local KEY = "PluginPaths"

function utils.LoadPath(plugin_name)
    if not plugin_name then return nil end
    return reaper.GetExtState(SECTION, plugin_name)
end

function utils.SavePath(plugin_name, path)
    if not plugin_name or not path then return end
    reaper.SetExtState(SECTION, plugin_name, path, true) -- true = persist
end

function utils.LoadExtensions(plugin_name)
    if not plugin_name then return "vstpreset, fxp, ffp" end -- Default
    local ext = reaper.GetExtState(SECTION, plugin_name .. "_EXT")
    if ext == "" then return "vstpreset, fxp, ffp" end
    return ext
end

function utils.SaveExtensions(plugin_name, extensions)
    if not plugin_name then return end
    reaper.SetExtState(SECTION, plugin_name .. "_EXT", extensions or "", true)
end

return utils
