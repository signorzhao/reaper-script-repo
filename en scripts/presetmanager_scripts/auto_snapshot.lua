-- @description Auto Snapshot - Automatically save plugin state on change
-- @version 1.0
-- @author Antigravity

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_path .. "?.lua;" .. script_path .. "modules/?.lua;" .. package.path

local saver = require("saver")
local preset_extractor = require("preset_name_extractor")

local ctx
local state = {
    track = nil,
    fx_index = nil,
    fx_name = "",
    last_chunk = "",
    snapshot_count = 0,
    save_folder = "",
    is_monitoring = false,
    last_save_time = 0,
    debounce_time = 0.5  -- 500ms debounce to avoid rapid parameter changes
}

local function GetSelectedFX()
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then return nil, nil, "" end
    
    local focus_ret, focus_track_idx, focus_item_idx, focus_fx_idx = reaper.GetFocusedFX()
    local fx_index = -1
    
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
    
    if fx_index < 0 then 
        if reaper.TrackFX_GetCount(track) > 0 then
            fx_index = 0
        else
            return nil, nil, ""
        end
    end
    
    local retval, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    fx_name = fx_name:gsub("^%w+: ", ""):gsub(" %(.+%)$", "")
    
    return track, fx_index, fx_name
end

local function GetPluginChunk(track, fx_index)
    if not track then return "" end
    local retval, chunk = reaper.TrackFX_GetNamedConfigParm(track, fx_index, "vst_chunk")
    return chunk or ""
end

local function GetPluginPresetName(track, fx_index)
    if not track then return nil end
    
    -- Try various Reaper API methods to get preset name
    
    -- Method 1: Try to get preset name via named config param
    local retval, name = reaper.TrackFX_GetNamedConfigParm(track, fx_index, "preset_name")
    if retval and name and name ~= "" then
        return name
    end
    
    -- Method 2: Try to get current preset index and name
    local preset_idx, preset_name = reaper.TrackFX_GetPreset(track, fx_index, "")
    if preset_name and preset_name ~= "" then
        return preset_name
    end
    
    -- Method 3: Try VST3 preset file path
    local ret3, path = reaper.TrackFX_GetNamedConfigParm(track, fx_index, "vst3_preset_file")
    if ret3 and path and path ~= "" then
        -- Extract filename from path
        local filename = path:match("([^/\\]+)%.%w+$")
        if filename then
            return filename
        end
    end
    
    return nil
end

local function ChunksAreDifferent(chunk1, chunk2)
    if chunk1 == chunk2 then return false end
    
    -- Calculate difference percentage (simple heuristic)
    local diff_threshold = 0.1  -- 10% difference threshold
    local len_diff = math.abs(#chunk1 - #chunk2) / math.max(#chunk1, #chunk2, 1)
    
    -- If length difference is significant, it's likely a preset change
    if len_diff > diff_threshold then
        return true
    end
    
    -- Count different bytes
    local diff_count = 0
    local min_len = math.min(#chunk1, #chunk2)
    for i = 1, min_len do
        if chunk1:byte(i) ~= chunk2:byte(i) then
            diff_count = diff_count + 1
        end
    end
    
    local diff_ratio = diff_count / min_len
    return diff_ratio > diff_threshold
end

local function MonitorAndSave()
    if not state.is_monitoring then return end
    if not state.track or not state.save_folder or state.save_folder == "" then return end
    
    local current_time = reaper.time_precise()
    local current_chunk = GetPluginChunk(state.track, state.fx_index)
    
    -- Check if chunk changed significantly (preset change, not just parameter tweak)
    if current_chunk ~= "" and ChunksAreDifferent(current_chunk, state.last_chunk) then
        -- Debounce: only save if enough time has passed since last save
        if current_time - state.last_save_time > state.debounce_time then
            state.snapshot_count = state.snapshot_count + 1
            
            -- Use simple numbered naming
            local filename = string.format("snapshot_%04d.fxp", state.snapshot_count)
            local save_path = state.save_folder .. "/" .. filename
            
            saver.SaveCurrentState(state.track, state.fx_index, save_path)
            state.last_chunk = current_chunk
            state.last_save_time = current_time
        end
    end
end

local function Draw()
    local visible, open = reaper.ImGui_Begin(ctx, "Auto Snapshot", true)
    
    if visible then
        local track, fx_idx, fx_name = GetSelectedFX()
        
        if not track then
            reaper.ImGui_Text(ctx, "Please select a track and focus an FX.")
        else
            -- Update context if plugin changed
            if fx_name ~= state.fx_name then
                state.fx_name = fx_name
                state.track = track
                state.fx_index = fx_idx
                state.is_monitoring = false
                state.snapshot_count = 0
                state.last_chunk = ""
            end
            
            reaper.ImGui_Text(ctx, "Plugin: " .. fx_name)
            reaper.ImGui_Separator(ctx)
            
            -- Save folder selection
            if state.save_folder ~= "" then
                reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, "Folder: " .. state.save_folder)
            else
                reaper.ImGui_Text(ctx, "No save folder selected")
            end
            
            if reaper.ImGui_Button(ctx, "Set Save Folder") then
                if reaper.JS_Dialog_BrowseForFolder then
                    local retval, path = reaper.JS_Dialog_BrowseForFolder("Select Snapshot Folder", "")
                    if retval and path and path ~= "" then
                        state.save_folder = path
                    end
                else
                    reaper.ShowMessageBox("Please install js_ReaScriptAPI.", "Missing Dependency", 0)
                end
            end
            
            reaper.ImGui_Separator(ctx)
            
            -- Monitoring controls
            if state.save_folder == "" then
                reaper.ImGui_BeginDisabled(ctx)
            end
            
            if state.is_monitoring then
                if reaper.ImGui_Button(ctx, "Stop Monitoring", 200, 40) then
                    state.is_monitoring = false
                end
                reaper.ImGui_TextColored(ctx, 0x00FF00FF, "● MONITORING")
            else
                if reaper.ImGui_Button(ctx, "Start Monitoring", 200, 40) then
                    state.is_monitoring = true
                    state.snapshot_count = 0
                    state.last_chunk = GetPluginChunk(state.track, state.fx_index)
                    state.last_save_time = reaper.time_precise()
                end
            end
            
            if state.save_folder == "" then
                reaper.ImGui_EndDisabled(ctx)
            end
            
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Text(ctx, "Snapshots saved: " .. state.snapshot_count)
            
            -- Snapshot list
            if state.save_folder ~= "" then
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Text(ctx, "Saved Snapshots:")
                
                if reaper.ImGui_BeginChild(ctx, "SnapshotList", 0, 200, 0) then
                    -- Scan for .fxp files in save folder
                    local i = 0
                    local snapshots = {}
                    
                    while true do
                        local file = reaper.EnumerateFiles(state.save_folder, i)
                        if not file then break end
                        
                        if file:match("%.fxp$") then
                            table.insert(snapshots, file)
                        end
                        i = i + 1
                    end
                    
                    -- Sort snapshots
                    table.sort(snapshots)
                    
                    -- Display as buttons
                    for _, filename in ipairs(snapshots) do
                        local display_name = filename:gsub("%.fxp$", "")
                        if reaper.ImGui_Button(ctx, display_name, 180, 0) then
                            local file_path = state.save_folder .. "/" .. filename
                            local loader = require("loader")
                            loader.LoadPreset(state.track, state.fx_index, file_path)
                        end
                    end
                    
                    if #snapshots == 0 then
                        reaper.ImGui_TextDisabled(ctx, "No snapshots yet")
                    end
                    
                    reaper.ImGui_EndChild(ctx)
                end
            end
            
            -- Monitor in background
            if state.is_monitoring then
                MonitorAndSave()
            end
        end
        
        reaper.ImGui_End(ctx)
    end
    
    if not open then
        reaper.ImGui_DestroyContext(ctx)
    end
    
    return open
end

local function Main()
    if Draw() then
        reaper.defer(Main)
    end
end

local function Init()
    if not reaper.APIExists("ImGui_CreateContext") then
        reaper.ShowMessageBox("Please install ReaImGui via ReaPack.", "Error", 0)
        return
    end
    
    ctx = reaper.ImGui_CreateContext("Auto Snapshot")
    Main()
end

Init()
