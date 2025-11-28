local loader = {}

-- Helper to read binary file
local function ReadFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

function loader.LoadPreset(track, fx_index, file_path)
    if not track or not file_path then return end
    
    local ext = file_path:match("^.+(%..+)$"):sub(2):lower()
    
    -- Strategy 1: VST3 Native Loading
    if ext == "vstpreset" then
        local ok = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst3_preset_file", file_path)
        if not ok then
            reaper.ShowMessageBox("Failed to load VST3 preset.\nMake sure the plugin is VST3.", "Error", 0)
        end
        return
    end
    
    -- Strategy 2: VST2 Chunk Injection
    if ext == "fxp" or ext == "fxb" then
        local content = ReadFile(file_path)
        if not content then
            reaper.ShowMessageBox("Could not read file.", "Error", 0)
            return
        end
        
        -- Try setting the chunk directly
        -- Note: Some plugins might need header stripping, but let's try raw first.
        -- Reaper's vst_chunk usually expects the raw blob. 
        -- However, .fxp files HAVE a header. 
        -- If this fails, we might need to strip the first 60 bytes (standard header).
        
        local ok = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst_chunk", content)
        
        if not ok then
             -- Fallback: Try stripping header (approx 60 bytes for standard fxp)
             -- This is experimental.
             if #content > 60 then
                 local raw_chunk = content:sub(61)
                 ok = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst_chunk", raw_chunk)
             end
        end
        
        if not ok then
            reaper.ShowMessageBox("Failed to load VST2 preset.\nPlugin might not support chunk injection.", "Error", 0)
        end
        return
    end
    
    -- Fallback: Try Best Effort for unknown extensions
    
    -- Try 1: Treat as VST3 preset path
    local ok_vst3 = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst3_preset_file", file_path)
    if ok_vst3 then return end
    
    -- Try 2: Treat as binary chunk (VST2 style)
    local content = ReadFile(file_path)
    if content then
        local ok_chunk = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst_chunk", content)
        if ok_chunk then return end
        
        -- Try 3: Chunk with header stripped (common for fxp)
        if #content > 60 then
             local raw_chunk = content:sub(61)
             local ok_strip = reaper.TrackFX_SetNamedConfigParm(track, fx_index, "vst_chunk", raw_chunk)
             if ok_strip then return end
        end
    end
    
    reaper.ShowMessageBox("Failed to load preset.\nThis file format may not be supported.", "Load Error", 0)
end

return loader
