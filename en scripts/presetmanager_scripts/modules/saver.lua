local saver = {}

-- Save current plugin state as a preset file
function saver.SaveCurrentState(track, fx_index, save_path)
    if not track or not save_path then 
        reaper.ShowConsoleMsg("SaveCurrentState: Invalid arguments\n")
        return false 
    end
    
    -- Get current plugin chunk
    local retval, chunk = reaper.TrackFX_GetNamedConfigParm(track, fx_index, "vst_chunk")
    
    if not retval or not chunk or chunk == "" then
        reaper.ShowMessageBox("Failed to get plugin state.\nMake sure the plugin supports chunk export.", "Save Error", 0)
        return false
    end
    
    -- Write to file
    local f = io.open(save_path, "wb")
    if not f then
        reaper.ShowMessageBox("Failed to create file:\n" .. save_path, "Save Error", 0)
        return false
    end
    
    f:write(chunk)
    f:close()
    
    return true
end

return saver
