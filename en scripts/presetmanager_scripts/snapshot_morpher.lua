-- @description Snapshot Morpher - Interpolate between plugin states
-- @version 1.0
-- @author Antigravity

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_path .. "?.lua;" .. script_path .. "modules/?.lua;" .. package.path

local ctx
local state = {
    track = nil,
    fx_index = nil,
    fx_name = "",
    
    slots = {}, -- Stores parameter snapshots: { [1] = { params = {0.1, 0.5, ...} }, ... }
    morph_time = 2.0, -- Seconds
    
    -- Morphing state
    is_morphing = false,
    morph_start_time = 0,
    morph_source_params = {}, -- Values at start of morph
    morph_target_params = {}, -- Target values
    
    param_count = 0
}

-- Initialize 16 slots
for i = 1, 16 do state.slots[i] = nil end

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

local function GetAllParams(track, fx_index)
    local count = reaper.TrackFX_GetNumParams(track, fx_index)
    local params = {}
    for i = 0, count - 1 do
        local val, minval, maxval = reaper.TrackFX_GetParam(track, fx_index, i)
        params[i] = val
    end
    return params, count
end

local function SaveSlot(slot_idx)
    if not state.track then return end
    local params, count = GetAllParams(state.track, state.fx_index)
    state.slots[slot_idx] = {
        params = params,
        count = count
    }
end

local function StartMorph(target_slot_idx)
    if not state.track or not state.slots[target_slot_idx] then return end
    
    -- Capture current state as start point (handles interruption seamlessly)
    local current_params, count = GetAllParams(state.track, state.fx_index)
    
    state.morph_source_params = current_params
    state.morph_target_params = state.slots[target_slot_idx].params
    state.param_count = count
    
    state.morph_start_time = reaper.time_precise()
    state.is_morphing = true
end

local function UpdateMorph()
    if not state.is_morphing then return end
    
    local now = reaper.time_precise()
    local elapsed = now - state.morph_start_time
    local t = elapsed / state.morph_time
    
    if t >= 1.0 then
        t = 1.0
        state.is_morphing = false
    end
    
    -- Apply easing (optional, using linear for now)
    -- t = t * t * (3 - 2 * t) -- Smoothstep
    
    for i = 0, state.param_count - 1 do
        local start_val = state.morph_source_params[i]
        local end_val = state.morph_target_params[i]
        
        if start_val and end_val then
            -- Interpolate
            local current_val = start_val + (end_val - start_val) * t
            reaper.TrackFX_SetParam(state.track, state.fx_index, i, current_val)
        end
    end
end

local function Draw()
    local visible, open = reaper.ImGui_Begin(ctx, "Snapshot Morpher", true)
    
    if visible then
        local track, fx_idx, fx_name = GetSelectedFX()
        
        if not track then
            reaper.ImGui_Text(ctx, "Please select a track and focus an FX.")
        else
            -- Update context
            if fx_name ~= state.fx_name then
                state.fx_name = fx_name
                state.track = track
                state.fx_index = fx_idx
                -- Clear slots on plugin change? Or keep them? 
                -- For safety, let's clear to avoid applying wrong params
                -- But user might want to keep if it's same plugin instance re-selected
                -- For now, we reset if name changes
                for i = 1, 16 do state.slots[i] = nil end
                state.is_morphing = false
            end
            
            reaper.ImGui_Text(ctx, "Plugin: " .. fx_name)
            
            -- Morph Time Slider
            local changed, val = reaper.ImGui_SliderDouble(ctx, "Morph Time (s)", state.morph_time, 0.0, 10.0, "%.2f")
            if changed then state.morph_time = val end
            
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Text(ctx, "Shift + Click to Save | Click to Morph")
            
            -- 4x4 Grid
            local cols = 4
            local rows = 4
            local btn_size = 60
            
            for r = 0, rows - 1 do
                for c = 0, cols - 1 do
                    local idx = r * cols + c + 1
                    local has_data = state.slots[idx] ~= nil
                    
                    if c > 0 then reaper.ImGui_SameLine(ctx) end
                    
                    local label = tostring(idx)
                    if has_data then label = "[" .. idx .. "]" end
                    
                    -- Color button if has data
                    if has_data then
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x44AA44AA)
                    end
                    
                    if reaper.ImGui_Button(ctx, label, btn_size, btn_size) then
                        if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) then
                            SaveSlot(idx)
                        else
                            if has_data then
                                StartMorph(idx)
                            end
                        end
                    end
                    
                    if has_data then
                        reaper.ImGui_PopStyleColor(ctx)
                    end
                end
            end
            
            -- Progress bar
            if state.is_morphing then
                local progress = (reaper.time_precise() - state.morph_start_time) / state.morph_time
                reaper.ImGui_ProgressBar(ctx, math.min(progress, 1.0), -1, 0, "Morphing...")
                UpdateMorph()
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
    
    ctx = reaper.ImGui_CreateContext("Snapshot Morpher")
    Main()
end

Init()
